import Foundation

// MARK: - Setu config (non-secret in UserDefaults, secret in Keychain)
struct SetuConfig {
    var baseURL: String
    var clientId: String
    var productInstanceId: String
    var redirectScheme: String      // e.g. "nidhi" (ASWebAuthentication callback)

    var clientSecret: String { Keychain.get("setu_client_secret") ?? "" }
    var isComplete: Bool { !baseURL.isEmpty && !clientId.isEmpty && !productInstanceId.isEmpty && !clientSecret.isEmpty }

    static let sandboxBase = "https://fiu-sandbox.setu.co"
    static let prodBase = "https://fiu.setu.co"

    // persistence
    private static let d = UserDefaults.standard
    static func load() -> SetuConfig {
        SetuConfig(baseURL: d.string(forKey: "setu_base") ?? sandboxBase,
                   clientId: d.string(forKey: "setu_client_id") ?? "",
                   productInstanceId: d.string(forKey: "setu_pi") ?? "",
                   redirectScheme: d.string(forKey: "setu_scheme") ?? "nidhi")
    }
    func save() {
        let d = SetuConfig.d
        d.set(baseURL, forKey: "setu_base")
        d.set(clientId, forKey: "setu_client_id")
        d.set(productInstanceId, forKey: "setu_pi")
        d.set(redirectScheme, forKey: "setu_scheme")
    }
}

// MARK: - Setu Account Aggregator client (Data Gateway v2)
//
// Flow (RBI AA):  POST /v2/consents  →  user approves in AA app  →
//                 GET /v2/consents/:id (poll until ACTIVE)  →
//                 POST /v2/sessions  →  GET /v2/sessions/:id (FI data).
// Auth headers: x-client-id, x-client-secret, x-product-instance-id.
// Field names follow Setu's documented v2 shapes; the FI payload is ReBIT-standard
// and parsed by RebitFI. Endpoints/paths are centralised here so they're easy to tune.
struct SetuAAClient: TransactionProvider {
    let config: SetuConfig

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        guard config.isComplete, let url = URL(string: config.baseURL + path) else { throw BankSyncError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.clientId, forHTTPHeaderField: "x-client-id")
        req.setValue(config.clientSecret, forHTTPHeaderField: "x-client-secret")
        req.setValue(config.productInstanceId, forHTTPHeaderField: "x-product-instance-id")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw BankSyncError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    func startConsent(phone: String) async throws -> ConsentHandle {
        // Consent for 1 year of deposit transactions, periodic fetch.
        let now = ISO8601DateFormatter().string(from: Date())
        let yearLater = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .year, value: 1, to: Date())!)
        let body: [String: Any] = [
            "consentDuration": ["unit": "MONTH", "value": "12"],
            "vua": "\(phone)@onemoney",
            "dataRange": ["from": ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .month, value: -6, to: Date())!), "to": now],
            "context": [],
            "redirectUrl": "\(config.redirectScheme)://aa-callback",
            "consentMode": "STORE",
            "consentTypes": ["TRANSACTIONS", "PROFILE", "SUMMARY"],
            "fiTypes": ["DEPOSIT"],
            "purpose": ["code": "101", "text": "Personal finance management", "category": ["type": "string"], "refUri": "https://api.rebit.org.in/aa/purpose/101.xml"],
            "fetchType": "PERIODIC",
            "frequency": ["unit": "DAY", "value": 2],
            "expireTime": yearLater
        ]
        let json = try await request("POST", "/v2/consents", body: body)
        let obj = json as? [String: Any] ?? [:]
        guard let id = (obj["id"] as? String) ?? (obj["consentId"] as? String) else {
            throw BankSyncError.decode("no consent id in response")
        }
        let urlStr = (obj["url"] as? String) ?? (obj["redirectUrl"] as? String)
        return ConsentHandle(consentId: id, approvalURL: urlStr.flatMap(URL.init(string:)))
    }

    func consentState(_ consentId: String) async throws -> ConsentState {
        let json = try await request("GET", "/v2/consents/\(consentId)")
        let status = ((json as? [String: Any])?["status"] as? String ?? "").uppercased()
        switch status {
        case "ACTIVE": return .active
        case "REJECTED", "FAILED", "EXPIRED", "REVOKED": return .rejected
        default: return .pending
        }
    }

    func fetch(consentId: String) async throws -> (accounts: [SyncedAccount], txns: [SyncedTxn]) {
        // 1) create a data session
        let now = ISO8601DateFormatter().string(from: Date())
        let from = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .month, value: -6, to: Date())!)
        let sessionBody: [String: Any] = [
            "consentId": consentId,
            "dataRange": ["from": from, "to": now],
            "format": "json"
        ]
        let sess = try await request("POST", "/v2/sessions", body: sessionBody)
        guard let sid = (sess as? [String: Any])?["id"] as? String else {
            throw BankSyncError.decode("no session id")
        }
        // 2) poll the session for completed FI data
        for _ in 0..<10 {
            let data = try await request("GET", "/v2/sessions/\(sid)")
            let status = ((data as? [String: Any])?["status"] as? String ?? "").uppercased()
            if status == "COMPLETED" || status == "PARTIAL" {
                return RebitFI.parse(data)
            }
            if status == "FAILED" || status == "EXPIRED" { throw BankSyncError.decode("session \(status)") }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw BankSyncError.consentTimedOut
    }
}
