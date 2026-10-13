import SwiftUI
import AuthenticationServices

@MainActor
final class SyncManager: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, working(String), success(Int), failed(String)
    }
    @Published var phase: Phase = .idle
    @Published var config: SetuConfig = SetuConfig.load()
    @Published var phone: String = UserDefaults.standard.string(forKey: "setu_phone") ?? ""

    private var webSession: ASWebAuthenticationSession?

    var isWorking: Bool { if case .working = phase { return true } else { return false } }
    var isConfigured: Bool { config.isComplete }
    private var provider: TransactionProvider { SetuAAClient(config: config) }

    func saveConfig() { config.save(); UserDefaults.standard.set(phone, forKey: "setu_phone") }
    func setSecret(_ s: String) { Keychain.set(s.isEmpty ? nil : s, for: "setu_client_secret") }

    /// Full reset for "Clear all data": forget the Setu secret, config and phone.
    func reset() {
        Keychain.set(nil, for: "setu_client_secret")
        let d = UserDefaults.standard
        ["setu_base", "setu_client_id", "setu_pi", "setu_scheme", "setu_phone"].forEach { d.removeObject(forKey: $0) }
        config = SetuConfig.load()
        phone = ""
        phase = .idle
    }

    func sync(into store: Store) {
        // Account Aggregator never runs unless the user explicitly opted in.
        guard store.accountAggregatorEnabled else {
            phase = .failed("Turn on Account Aggregator in Settings to sync.")
            return
        }
        guard !isWorking else { return }
        Task { await run(into: store) }
    }

    private func run(into store: Store) async {
        // The Setu sandbox returns fictitious demo accounts/transactions — never merge those
        // into the user's real finances.
        if config.baseURL.localizedCaseInsensitiveContains("sandbox") {
            phase = .failed("Sandbox mode returns demo data and won't be imported. Set a production endpoint in Bank sync settings to import real transactions.")
            return
        }
        do {
            phase = .working("Requesting consent…")
            let handle = try await provider.startConsent(phone: phone)

            if let url = handle.approvalURL {
                phase = .working("Waiting for approval…")
                try await openConsent(url)
                phase = .working("Confirming consent…")
                try await pollActive(handle.consentId)
            }

            phase = .working("Fetching transactions…")
            let (accounts, txns) = try await provider.fetch(consentId: handle.consentId)
            let added = store.mergeSynced(accounts: accounts, txns: txns)
            phase = .success(added)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func pollActive(_ consentId: String) async throws {
        for _ in 0..<40 {                       // ~2 min @ 3s
            switch try await provider.consentState(consentId) {
            case .active: return
            case .rejected: throw BankSyncError.consentRejected
            case .pending: try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw BankSyncError.consentTimedOut
    }

    // ASWebAuthenticationSession as async
    private func openConsent(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: config.redirectScheme) { _, error in
                if let error {
                    let code = (error as NSError).code
                    if code == ASWebAuthenticationSessionError.canceledLogin.rawValue { cont.resume(throwing: BankSyncError.cancelled) }
                    else { cont.resume(throwing: error) }
                } else {
                    cont.resume()      // returned to our scheme = consent flow finished
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() { cont.resume(throwing: BankSyncError.cancelled) }
        }
    }
}

extension SyncManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { nidhiPresentationAnchor() }
}
