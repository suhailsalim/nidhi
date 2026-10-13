import Foundation

// MARK: - DTOs returned by any provider
struct SyncedAccount: Hashable {
    var bank: String
    var mask: String          // last 4 digits
    var type: String
    var balance: Double
    var kind: TxnSource = .bank   // .bank or .card
    var bankCode: String? = nil
    var ifsc: String? = nil
    var branch: String? = nil
    var tier: String? = nil
    var limit: Double? = nil      // for cards
    var cardName: String? = nil   // for cards (matched product, e.g. "HDFC Diners Black")
    var rewardKind: String? = nil
    var rewardBalance: Double? = nil
    // Credit-card bill figures printed on the statement (nil for banks / when not found).
    var totalDue: Double? = nil
    var minDue: Double? = nil
    var dueDate: Date? = nil
    /// The statement's closing/as-of date. `balance` is the figure *as of* this date — the live
    /// balance is reconstructed by adding any transactions dated after it. nil = treat as current.
    var asOf: Date? = nil
}

struct SyncedTxn: Hashable {
    var externalId: String    // stable id from the feed (txnId)
    var narration: String
    var amount: Double        // signed: + credit, − debit
    var date: Date
    var accountMask: String
    var merchant: String? = nil   // optional clean display name from a bank-specific parser
    var source: TxnSource = .unknown
    var counterparty: String? = nil
    var bankCode: String? = nil
    var category: String? = nil   // statement-provided category (e.g. Axis merchant category)
    var cardholder: String? = nil // add-on cardholder this row belongs to; nil = primary holder
    var reward: Double? = nil     // loyalty reward earned on this row (points/miles/coins/cashback)
    var rewardCurrency: String? = nil // unit for `reward` (varies by card)
    var forexCurrency: String? = nil  // original currency for an international row (e.g. "EUR"); nil = domestic
    var forexAmount: Double? = nil    // original-currency amount; `amount` is the INR value
    var isInternational: Bool = false // row sits in the statement's international section
    // Parser confidence flags (transient — not persisted). When a field couldn't be resolved the
    // row still imports with a best-guess value, but is flagged for review (see DataConflict).
    var dateResolved: Bool = true
    var amountResolved: Bool = true
    var merchantResolved: Bool = true
    var rawContext: String = ""   // narration/source snippet shown on the conflict card
    var hasConflict: Bool { !(dateResolved && amountResolved && merchantResolved) }
}

/// An exact balance reading (e.g. from an HDFC "available balance" email). `asOf` is *when* the
/// balance was true (end-of-day) — used to keep only the newest reading per account and to
/// reconstruct the live balance by adding transactions dated after it.
struct BalanceUpdate: Hashable { var mask: String; var balance: Double; var kind: TxnSource = .bank; var asOf: Date }

/// Result of parsing a statement PDF — one or many accounts/cards, their transactions, and
/// any fixed/recurring deposits (combined statements).
struct ImportResult {
    var accounts: [SyncedAccount] = []
    var txns: [SyncedTxn] = []
    var deposits: [Deposit] = []
}

enum BankSyncError: LocalizedError {
    case notConfigured
    case consentRejected
    case consentTimedOut
    case http(Int, String)
    case decode(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Setu Account Aggregator credentials in Settings first."
        case .consentRejected: return "Consent was declined in the Account Aggregator app."
        case .consentTimedOut: return "Timed out waiting for consent approval."
        case .http(let c, let m): return "Server error \(c): \(m)"
        case .decode(let m): return "Could not read the bank data: \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}

struct ConsentHandle {
    var consentId: String
    var approvalURL: URL?     // nil = no web step needed (mock)
}

enum ConsentState { case pending, active, rejected }

// MARK: - Provider protocol
protocol TransactionProvider {
    /// Create a consent request for the given mobile number.
    func startConsent(phone: String) async throws -> ConsentHandle
    /// Poll a consent's status.
    func consentState(_ consentId: String) async throws -> ConsentState
    /// Fetch accounts + transactions once consent is active.
    func fetch(consentId: String) async throws -> (accounts: [SyncedAccount], txns: [SyncedTxn])
}

// MARK: - ReBIT FI-data parser (standardised across all AA / TSPs)
//
// AA "deposit" Financial-Information is a ReBIT-standardised schema. TSPs wrap it
// slightly differently, so this walks the JSON defensively: it finds every object
// that looks like an account (has a masked number + a summary + transactions) and
// reads the ReBIT fields. This is the part that does NOT depend on Setu specifically.
enum RebitFI {
    static func parse(_ root: Any) -> (accounts: [SyncedAccount], txns: [SyncedTxn]) {
        var accounts: [SyncedAccount] = []
        var txns: [SyncedTxn] = []
        for acc in findAccounts(root) {
            let mask = last4(str(acc["maskedAccNumber"]) ?? str(acc["maskedAccountNumber"]) ?? "")
            let summary = dict(acc["summary"]) ?? dict(dig(acc, "Summary"))
            let balance = dbl(summary?["currentBalance"]) ?? 0
            let type = (str(summary?["type"]) ?? "Savings").capitalized
            let fip = str(acc["fipName"]) ?? str(acc["bank"]) ?? "Bank"
            accounts.append(SyncedAccount(bank: fip, mask: mask, type: type, balance: balance))

            for t in findTransactions(acc) {
                guard let amt = dbl(t["amount"]) else { continue }
                let isCredit = (str(t["type"]) ?? "").uppercased().hasPrefix("CRED")
                let id = str(t["txnId"]) ?? str(t["txnid"]) ?? UUID().uuidString
                let narration = str(t["narration"]) ?? str(t["reference"]) ?? "Transaction"
                let ts = str(t["transactionTimestamp"]) ?? str(t["valueDate"]) ?? ""
                txns.append(SyncedTxn(externalId: id, narration: narration,
                                      amount: isCredit ? amt : -amt,
                                      date: date(ts), accountMask: mask))
            }
        }
        return (accounts, txns)
    }

    // recursively collect account-like dictionaries
    private static func findAccounts(_ node: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let d = node as? [String: Any] {
            if d["maskedAccNumber"] != nil || d["maskedAccountNumber"] != nil { out.append(d) }
            for v in d.values { out += findAccounts(v) }
        } else if let a = node as? [Any] {
            for v in a { out += findAccounts(v) }
        }
        return out
    }

    private static func findTransactions(_ node: Any) -> [[String: Any]] {
        // ReBIT: transactions.transaction = [ ... ]
        if let d = node as? [String: Any] {
            if let tx = dict(d["transactions"]) {
                if let arr = tx["transaction"] as? [[String: Any]] { return arr }
                if let one = tx["transaction"] as? [String: Any] { return [one] }
            }
            var out: [[String: Any]] = []
            for v in d.values { out += findTransactions(v) }
            return out
        } else if let a = node as? [Any] {
            return a.flatMap { findTransactions($0) }
        }
        return []
    }

    // helpers
    private static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    private static func dig(_ d: [String: Any], _ k: String) -> Any? { d[k] }
    private static func str(_ v: Any?) -> String? { v as? String ?? (v as? NSNumber)?.stringValue }
    private static func dbl(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: "")) }
        return nil
    }
    private static func last4(_ s: String) -> String { String(s.suffix(4)) }
    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func date(_ s: String) -> Date {
        isoFull.date(from: s) ?? iso.date(from: s) ?? Date()
    }
}

