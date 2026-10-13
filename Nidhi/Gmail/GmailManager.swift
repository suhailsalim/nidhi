import SwiftUI
import AuthenticationServices
import CryptoKit

/// A presentation anchor for ASWebAuthenticationSession that avoids the deprecated `UIWindow()`
/// init — returns the active scene's key window (or a windowScene-based window).
@MainActor func nidhiPresentationAnchor() -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    // A foreground web-auth session always has a window scene; build one only if no window exists.
    return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? UIWindow(windowScene: scenes.first!)
}

/// Links a Gmail account (OAuth 2.0 + PKCE, read-only) and scans bank/card alert
/// emails into transactions. Uses a user-supplied Google OAuth iOS client ID.
@MainActor
final class GmailManager: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, working(String), success(Int), failed(String) }
    @Published var phase: Phase = .idle
    /// Public OAuth client ID, configured at build time in Info.plist (key GIDClientID).
    let clientID: String = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String) ?? ""
    @Published var connected: Bool = Keychain.get("gmail_refresh") != nil
    @Published var scanDays: Int = (UserDefaults.standard.object(forKey: "gmail_days") as? Int) ?? 60
    @Published var autoScan: Bool = (UserDefaults.standard.object(forKey: "gmail_autoscan") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoScan, forKey: "gmail_autoscan") }
    }
    @Published var statementAutoScan: Bool = (UserDefaults.standard.object(forKey: "gmail_stmt_autoscan") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(statementAutoScan, forKey: "gmail_stmt_autoscan") }
    }
    @Published var pending: [PendingStatement] = GmailManager.dedupe(GmailManager.loadPending())
    @Published var stmtPhase: Phase = .idle
    /// Keys (messageId:attachmentId) of statement emails already imported or dismissed — so a
    /// re-scan never re-imports (duplicates) or re-queues them.
    private var processed: Set<String> = GmailManager.loadProcessed()
    /// Message ids of alert emails already scanned — so we never re-download/re-parse them.
    private var processedMsgs: Set<String> = GmailManager.loadProcessedMsgs()

    private var session: ASWebAuthenticationSession?
    private var verifier = ""

    var lastScan: Date? { UserDefaults.standard.object(forKey: "gmail_last") as? Date }
    var lastStatementScan: Date? { UserDefaults.standard.object(forKey: "gmail_stmt_last") as? Date }
    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// Reversed-DNS scheme Google requires for iOS OAuth, derived from the client ID.
    private var scheme: String {
        let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(id)"
    }
    private var redirectURI: String { "\(scheme):/oauth2redirect" }

    func saveConfig() {
        UserDefaults.standard.set(scanDays, forKey: "gmail_days")
    }
    func disconnect() { Keychain.set(nil, for: "gmail_refresh"); connected = false; phase = .idle }

    /// Full reset for "Clear all data": forget the account, saved passwords, pending statements
    /// (incl. cached PDFs), all Gmail preferences and in-memory state.
    func reset() {
        disconnect()
        StatementVault.clear()
        for p in pending { try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent(p.cacheFile)) }
        // sweep any stray cached statement PDFs
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.cacheDir, includingPropertiesForKeys: nil) {
            for u in files where u.lastPathComponent.hasPrefix("stmt_") { try? FileManager.default.removeItem(at: u) }
        }
        pending = []; processed = []; processedMsgs = []
        let d = UserDefaults.standard
        ["gmail_days", "gmail_autoscan", "gmail_stmt_autoscan", "gmail_last", "gmail_stmt_last", "gmail_pending_stmts", "gmail_done_stmts", "gmail_done_msgs"].forEach { d.removeObject(forKey: $0) }
        scanDays = 60; autoScan = true; statementAutoScan = true
        phase = .idle; stmtPhase = .idle
    }

    func connect() { Task { await runConnect() } }
    func scan(into store: Store) { guard !isWorking else { return }; Task { await runScan(store) } }
    func scanStatements(into store: Store) { Task { await runStatementScan(store) } }

    /// Background / on-launch scan: runs quietly when connected, enabled, and stale (>1h). Re-scans
    /// are cheap — the processed-message ledger means only genuinely new emails are downloaded.
    func backgroundScanIfDue(into store: Store) async {
        guard connected, autoScan, isConfigured, !isWorking else { return }
        if let last = lastScan, Date().timeIntervalSince(last) < 3600 { return }
        await runScan(store)
    }
    /// Background statement scan: connected + enabled + stale (>12h).
    func statementScanIfDue(into store: Store) async {
        guard connected, statementAutoScan, isConfigured else { return }
        if let last = lastStatementScan, Date().timeIntervalSince(last) < 12 * 3600 { return }
        await runStatementScan(store)
    }

    // MARK: statement PDFs from Gmail
    private func runStatementScan(_ store: Store) async {
        guard connected else { stmtPhase = .failed("Connect Gmail first."); return }
        do {
            stmtPhase = .working("Looking for statements…")
            let token = try await accessToken()
            let mails = try await GmailProvider.fetchStatements(accessToken: token, days: max(scanDays, 90))
            let vault = StatementVault.passwords()
            var imported = 0
            let pendingCountBefore = pending.count
            for m in mails {
                let key = "\(m.messageId):\(m.attachmentId)"
                if processed.contains(key) || pending.contains(where: { $0.messageId == m.messageId && $0.attachmentId == m.attachmentId }) { continue }
                let data = try await GmailProvider.downloadAttachment(accessToken: token, messageId: m.messageId, attachmentId: m.attachmentId)
                if StatementImporter.isUnsupportedDocument(data: data) {
                    markProcessed(key)                   // loan foreclosure/pre-payment doc — never a statement
                } else {
                    switch tryImport(data: data, passwords: vault) {
                    case .parsed(let r):
                        let rec = StatementRecord(fileName: m.filename.isEmpty ? "Statement" : m.filename,
                                                  source: "Gmail", importedAt: Date(), gmailKey: key)
                        store.mergeImport(r, record: rec); markProcessed(key); imported += 1
                    case .unlockedButEmpty:
                        markProcessed(key)               // a password opened it but there was nothing to import — not a password problem, so don't queue it
                    case .needsPassword:
                        addPending(m, data: data)        // genuinely locked: no saved password opened it
                    }
                }
            }
            UserDefaults.standard.set(Date(), forKey: "gmail_stmt_last")
            if pending.count > pendingCountBefore { NotificationManager.notifyPendingStatements(total: pending.count) }
            stmtPhase = .success(imported)
        } catch {
            stmtPhase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
    private enum ImportAttempt { case parsed(ImportResult); case unlockedButEmpty; case needsPassword }
    /// Try no-password then each saved password. Distinguishes "a password opened it but we couldn't
    /// parse anything" (`.unlockedButEmpty` — *not* a password problem) from "nothing opened it"
    /// (`.needsPassword`). The old code conflated the two, so an unlockable-but-unparseable PDF got
    /// stuck forever in "needs password" (see bug-019).
    private func tryImport(data: Data, passwords: [String]) -> ImportAttempt {
        var unlocked = false
        for pw in [nil] + passwords.map(Optional.some) {
            do {
                let r = try StatementImporter.parse(data: data, password: pw)
                if !(r.txns.isEmpty && r.accounts.isEmpty && r.deposits.isEmpty) { return .parsed(r) }
                unlocked = true                          // opened, but produced nothing
            } catch StatementError.locked, StatementError.wrongPassword {
                continue                                 // this candidate password didn't open it
            } catch {
                unlocked = true                          // opened, but parsing / this doc-type failed
            }
        }
        return unlocked ? .unlockedButEmpty : .needsPassword
    }
    /// Import a previously-pending statement with a user-entered password. Returns nil on success, or
    /// the reason it failed: `.wrongPassword`/`.locked` keep it queued so the user can retry; any
    /// other error means it *opened* but couldn't be parsed — so it's dropped from the queue (it was
    /// never a password problem) and the real reason is surfaced instead of a bogus "wrong password".
    @discardableResult
    func importPending(_ p: PendingStatement, password: String, into store: Store) -> StatementError? {
        guard let data = try? Data(contentsOf: Self.cacheDir.appendingPathComponent(p.cacheFile)) else { return .cannotOpen }
        do {
            let r = try StatementImporter.parse(data: data, password: password)
            guard !(r.txns.isEmpty && r.accounts.isEmpty && r.deposits.isEmpty) else {
                markProcessed(p.id); removePending(p); return .noTransactions   // opened, but nothing to import
            }
            store.mergeImport(r, record: StatementRecord(fileName: p.filename.isEmpty ? "Statement" : p.filename,
                                                         source: "Gmail", importedAt: Date(), gmailKey: p.id))
            StatementVault.add(password)                 // remember it for next time
            markProcessed(p.id)                          // never re-fetch/re-queue it
            removePending(p)
            return nil
        } catch StatementError.wrongPassword { return .wrongPassword }
        catch StatementError.locked { return .locked }
        catch {
            markProcessed(p.id); removePending(p)        // opened but unparseable — stop nagging for a password
            return (error as? StatementError) ?? .noTransactions
        }
    }
    /// Dismiss a pending statement without importing — and remember it so it doesn't return.
    func dismissPending(_ p: PendingStatement) { markProcessed(p.id); removePending(p) }

    private func addPending(_ m: GmailProvider.StatementMail, data: Data) {
        let key = "\(m.messageId):\(m.attachmentId)"
        guard !processed.contains(key), !pending.contains(where: { $0.id == key }) else { return }
        let file = "stmt_\(m.messageId)_\(m.attachmentId).pdf"
        try? data.write(to: Self.cacheDir.appendingPathComponent(file))
        pending.append(PendingStatement(messageId: m.messageId, attachmentId: m.attachmentId, filename: m.filename,
                                        sender: m.sender, date: m.date, cacheFile: file))
        savePending()
    }
    func removePending(_ p: PendingStatement) {
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent(p.cacheFile))
        pending.removeAll { $0.id == p.id }; savePending()
    }
    private func savePending() {
        if let d = try? JSONEncoder().encode(pending) { UserDefaults.standard.set(d, forKey: "gmail_pending_stmts") }
    }
    private static func loadPending() -> [PendingStatement] {
        guard let d = UserDefaults.standard.data(forKey: "gmail_pending_stmts"),
              let a = try? JSONDecoder().decode([PendingStatement].self, from: d) else { return [] }
        return a
    }
    private static func dedupe(_ ps: [PendingStatement]) -> [PendingStatement] {
        var seen = Set<String>(); return ps.filter { seen.insert($0.id).inserted }
    }

    // MARK: processed-statement ledger
    private func markProcessed(_ key: String) { processed.insert(key); saveProcessed() }
    private func saveProcessed() { UserDefaults.standard.set(Array(processed), forKey: "gmail_done_stmts") }
    private static func loadProcessed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "gmail_done_stmts") ?? [])
    }

    // MARK: processed alert-email ledger
    /// Bumped whenever `EmailTransactionParser` learns new formats. A scan that sees a stored
    /// version older than this ignores the processed-message ledger once, so alerts the old
    /// parser skipped (NEFT salary credits, ACH/NACH EMI debits) are backfilled. Store-side
    /// externalId dedup ("gmail:<id>") keeps the re-merge idempotent.
    /// v3: patterns rebuilt from a survey of every real alert format in the mailbox (HDFC
    /// standing-instruction/EMI debits, deposit & salary credits, NetBanking transfers, IMPS,
    /// debit-card spends, ICICI + Axis cards, Scapia rewards) — a full re-scan is what surfaces
    /// years of transactions the old patterns walked past.
    private static let parserVersion = 3
    private static let parserVersionKey = "gmail_parser_version"
    private var needsBackfillScan: Bool {
        UserDefaults.standard.integer(forKey: Self.parserVersionKey) < Self.parserVersion
    }
    private func markMailBackfilled() {
        UserDefaults.standard.set(Self.parserVersion, forKey: Self.parserVersionKey)
    }
    private func markProcessedMsgs(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        processedMsgs.formUnion(ids)
        // Soft cap so the ledger can't grow without bound over years of alerts.
        if processedMsgs.count > 8000 { processedMsgs = Set(processedMsgs.prefix(6000)) }
        UserDefaults.standard.set(Array(processedMsgs), forKey: "gmail_done_msgs")
    }
    private static func loadProcessedMsgs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "gmail_done_msgs") ?? [])
    }
    private static var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    private func runConnect() async {
        guard isConfigured else { phase = .failed("Enter your Google OAuth client ID first."); return }
        do {
            verifier = Self.randomString(64)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent")
            ]
            phase = .working("Waiting for Google sign-in…")
            let callback = try await authorize(url: c.url!)
            guard let code = URLComponents(string: callback.absoluteString)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                throw GmailError.tokenFailed
            }
            try await exchange(code: code)
            connected = true; phase = .idle
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Sign-in cancelled.")
        }
    }

    /// Re-scan every matching email, ignoring the processed-message ledger (e.g. after a parser
    /// improvement). Still de-dups at the store via stable externalIds.
    func rescanAll(into store: Store) { guard !isWorking else { return }; Task { await runScan(store, force: true) } }

    private func runScan(_ store: Store, force: Bool = false) async {
        guard connected else { phase = .failed("Connect Gmail first."); return }
        do {
            phase = .working("Reading transaction emails…")
            let token = try await accessToken()
            let (txns, balances, scanned) = try await GmailProvider.fetchTransactions(
                accessToken: token, days: scanDays, skip: (force || needsBackfillScan) ? [] : processedMsgs)
            let n = store.mergeSynced(accounts: [], txns: txns, adjustBalances: true)
            store.applyBalances(balances)
            markProcessedMsgs(scanned)
            markMailBackfilled()
            UserDefaults.standard.set(Date(), forKey: "gmail_last")
            phase = .success(n)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: tokens
    private func exchange(code: String) async throws {
        let form = ["code": code, "client_id": clientID, "redirect_uri": redirectURI,
                    "grant_type": "authorization_code", "code_verifier": verifier]
        let json = try await postToken(form)
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, for: "gmail_refresh") }
        guard json["access_token"] is String else { throw GmailError.tokenFailed }
    }
    private func accessToken() async throws -> String {
        guard let refresh = Keychain.get("gmail_refresh") else { throw GmailError.notConnected }
        let json = try await postToken(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        guard let token = json["access_token"] as? String else { throw GmailError.tokenFailed }
        return token
    }
    private func postToken(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $1)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw GmailError.tokenFailed }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: OAuth web step
    private func authorize(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { cb, err in
                if let cb { cont.resume(returning: cb) } else { cont.resume(throwing: err ?? GmailError.tokenFailed) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: GmailError.tokenFailed) }
        }
    }

    private static func randomString(_ n: Int) -> String {
        let cs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in cs[Int.random(in: 0..<cs.count)] })
    }
    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension GmailManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { nidhiPresentationAnchor() }
}
