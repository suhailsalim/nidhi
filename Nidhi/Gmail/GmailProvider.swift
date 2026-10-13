import Foundation

enum GmailError: LocalizedError {
    case notConnected, http(Int, String), tokenFailed
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect your Gmail account first."
        case .http(let c, _): return "Gmail error \(c)."
        case .tokenFailed: return "Couldn't refresh Gmail access — reconnect."
        }
    }
}

/// Gmail REST: lists bank/card alert emails and parses them into transactions.
enum GmailProvider {
    /// Senders for Indian bank/card alerts; broad `from:` substrings + content keywords.
    /// The sender list must spell out **both** each issuer's legacy domain and its `<bank>.bank.in`
    /// migration — `from:axisbank` does not match `alerts@axis.bank.in`, which silently hid every
    /// Axis alert once they migrated. Keywords cover the wordings that carry no issuer name:
    /// `deducted` (standing-instruction auto-debits, i.e. loan EMIs) and the deposit/salary alerts.
    static func query(days: Int) -> String {
        let senders = ["hdfcbank", "axisbank", "axis.bank.in", "icicibank", "scapia",
                       "federalbank", "federal.bank.in", "kotak", "sbicard"]
            .map { "from:\($0)" }.joined(separator: " OR ")
        let phrases = ["\"has been debited\"", "\"has been credited\"", "\"is debited\"", "\"is credited\"",
                       "\"is deducted\"", "\"has been deducted\"", "\"successfully credited\"",
                       "\"amount received\"", "\"credited/received\"", "\"received a credit\"",
                       "\"Transaction Amount\"", "\"has been used for a transaction\"",
                       "\"available balance\"", "\"Credit Card\""].joined(separator: " OR ")
        return "newer_than:\(days)d (\(senders) OR \(phrases))"
    }

    /// Lists matching alert emails and parses the ones not already seen. `skip` holds message ids
    /// from a previous scan (the processed-message ledger) so we don't re-download their bodies.
    /// `scanned` is the ids actually fetched this run (caller adds them to the ledger).
    static func fetchTransactions(accessToken: String, days: Int, skip: Set<String> = []) async throws
        -> (txns: [SyncedTxn], balances: [BalanceUpdate], scanned: [String]) {
        var ids: [String] = []
        var pageToken: String?
        // Gmail lists newest-first, so a fixed cap makes a wide window pointless — every scan would
        // re-read the same newest N and never reach the older mail the window was widened for. The
        // ceiling therefore scales with the window (listing is one cheap call per 100 ids; the
        // expensive body fetches are still bounded by the processed-message ledger).
        let idCeiling = min(20_000, max(600, days * 20))
        repeat {
            var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            c.queryItems = [.init(name: "q", value: query(days: days)), .init(name: "maxResults", value: "100")]
            if let pt = pageToken { c.queryItems?.append(.init(name: "pageToken", value: pt)) }
            let json = try await get(c.url!, accessToken) as? [String: Any] ?? [:]
            ids += (json["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && ids.count < idCeiling

        var out: [SyncedTxn] = []
        var balances: [BalanceUpdate] = []
        var scanned: [String] = []
        for id in ids where !skip.contains(id) {
            guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full"),
                  let msg = try? await get(url, accessToken) as? [String: Any] else { continue }
            scanned.append(id)   // only mark ids we actually fetched, so transient failures retry next scan
            let payload = msg["payload"] as? [String: Any] ?? [:]
            let headers = payload["headers"] as? [[String: Any]] ?? []
            func h(_ n: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == n.lowercased() }?["value"] as? String ?? "" }
            let src = EmailTransactionParser.Source(id: id, sender: h("From"), subject: h("Subject"),
                                                    dateHeader: h("Date"), body: bodyText(payload))
            // Both, not either: a transaction alert also states the balance *after* the movement,
            // which is a fresher anchor than the daily balance mail.
            let t = EmailTransactionParser.parse(src)
            if let t { out.append(t) }
            if let b = EmailTransactionParser.balance(src, txn: t) { balances.append(b) }
        }
        return (out, balances, scanned)
    }

    // MARK: statement PDFs (attachments)
    struct StatementMail: Hashable {
        var messageId: String; var attachmentId: String; var filename: String; var sender: String; var date: Date
    }

    static func statementQuery(days: Int) -> String {
        // Require a known BANK/CARD issuer sender AND statement wording, so brokerage /
        // investment statements (IND Money, Paytm Money, Groww, Zerodha, CAMS, …) are excluded.
        let issuers = ["hdfcbank", "axisbank", "axis.bank.in", "icicibank", "federalbank",
                       "federal.bank.in", "scapia", "sbicard", "sbi",
                       "kotak", "idfcfirstbank", "yesbank", "rblbank", "indusind", "aubank", "hsbc",
                       "standardchartered", "americanexpress", "amex"]
        let from = issuers.map { "from:\($0)" }.joined(separator: " OR ")
        let exclude = ["indmoney", "paytmmoney", "groww", "zerodha", "kuvera", "smallcase", "cams", "kfintech",
                       "camsonline", "mfcentral", "nsdl", "cdsl"].map { "-from:\($0)" }.joined(separator: " ")
        // Loan foreclosure / pre-payment statements carry "Statement" in the subject but list
        // payable figures, not transactions — exclude them here too (content guard backstops this).
        // EasyEMI amortisation schedules also arrive as "statement"-ish PDFs from a card sender but
        // list a repayment plan, not transactions.
        let closure = "-subject:foreclosure -subject:foreclose -subject:\"pre-payment\" " +
                      "-subject:prepayment -subject:\"pre-closure\" -subject:preclosure " +
                      "-subject:amortization -subject:amortisation"
        return "newer_than:\(days)d has:attachment filename:pdf (\(from)) " +
               "subject:(statement OR e-statement OR \"account statement\" OR \"credit card statement\") " +
               "\(exclude) \(closure) -subject:portfolio -subject:holdings -subject:\"capital gains\""
    }

    static func fetchStatements(accessToken token: String, days: Int) async throws -> [StatementMail] {
        var ids: [String] = []; var pageToken: String?
        repeat {
            var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            c.queryItems = [.init(name: "q", value: statementQuery(days: days)), .init(name: "maxResults", value: "100")]
            if let pt = pageToken { c.queryItems?.append(.init(name: "pageToken", value: pt)) }
            let json = try await get(c.url!, token) as? [String: Any] ?? [:]
            ids += (json["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && ids.count < 300

        var out: [StatementMail] = []
        for id in ids {
            guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full"),
                  let msg = try? await get(url, token) as? [String: Any] else { continue }
            let payload = msg["payload"] as? [String: Any] ?? [:]
            let headers = payload["headers"] as? [[String: Any]] ?? []
            let sender = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let ms = Double(msg["internalDate"] as? String ?? "") ?? 0
            let date = Date(timeIntervalSince1970: ms / 1000)
            for (fn, aid) in attachments(payload) where fn.lowercased().hasSuffix(".pdf") {
                out.append(StatementMail(messageId: id, attachmentId: aid, filename: fn, sender: sender, date: date))
            }
        }
        return out
    }

    private static func attachments(_ payload: [String: Any]) -> [(String, String)] {
        var res: [(String, String)] = []
        func walk(_ p: [String: Any]) {
            let fn = p["filename"] as? String ?? ""
            if !fn.isEmpty, let body = p["body"] as? [String: Any], let aid = body["attachmentId"] as? String { res.append((fn, aid)) }
            for sub in (p["parts"] as? [[String: Any]]) ?? [] { walk(sub) }
        }
        walk(payload); return res
    }

    static func downloadAttachment(accessToken token: String, messageId: String, attachmentId: String) async throws -> Data {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)") else {
            throw GmailError.http(0, "bad url")
        }
        let json = try await get(url, token) as? [String: Any] ?? [:]
        guard let b = json["data"] as? String, let data = decodeB64URLData(b) else { throw GmailError.http(0, "no attachment data") }
        return data
    }
    private static func decodeB64URLData(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    private static func get(_ url: URL, _ token: String) async throws -> Any {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GmailError.http(code, String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private static func bodyText(_ payload: [String: Any]) -> String {
        var plain = "", html = ""
        func walk(_ p: [String: Any]) {
            let mime = p["mimeType"] as? String ?? ""
            if let b = (p["body"] as? [String: Any])?["data"] as? String, !b.isEmpty {
                if mime == "text/plain", plain.isEmpty { plain = decodeB64URL(b) }
                else if mime == "text/html", html.isEmpty { html = decodeB64URL(b) }
            }
            for sub in (p["parts"] as? [[String: Any]]) ?? [] { walk(sub) }
        }
        walk(payload)
        return !plain.isEmpty ? plain : html
    }

    private static func decodeB64URL(_ s: String) -> String {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
