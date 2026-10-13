import Foundation

/// Transaction export — pure functions over `[Txn]`, no `Store` and no UI, so the exact same code
/// serves a filtered list and the whole ledger.
///
/// Deliberately separate from `Store.exportBundle()`: that is a backup meant to be re-imported by
/// this app, this is an interchange format for a spreadsheet, an accountant, or a tax tool.
enum TxnExporter {
    static let columns = ["date", "merchant", "category", "account", "amount", "currency", "tags",
                          "counterparty", "transfer", "reward", "rewardUnit", "forexAmount",
                          "forexCurrency", "source"]

    private static var isoDay: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// RFC-4180 quoting: a field containing a comma, a quote or a newline is wrapped in quotes and
    /// its inner quotes doubled. Statement narrations genuinely contain all three.
    static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Never locale-formatted — "1,234.56" would silently split a column.
    private static func num(_ d: Double) -> String { String(format: "%.2f", d) }

    static func csvText(_ txns: [Txn]) -> String {
        let df = isoDay
        var rows = [columns.joined(separator: ",")]
        for t in txns.sorted(by: { $0.date < $1.date }) {
            rows.append([
                df.string(from: t.date),
                escape(t.merchant),
                escape(t.category),
                escape(t.account),
                num(t.amount),                              // signed: negative = spend, positive = income
                "INR",                                      // `amount` is always the INR value
                escape(t.tags.joined(separator: "|")),      // '|' not ',' so tags stay one field
                escape(t.counterparty ?? ""),
                t.transfer ? "true" : "false",
                t.reward.map(num) ?? "",
                escape(t.rewardCurrency ?? ""),
                t.forexAmount.map(num) ?? "",
                escape(t.forexCurrency ?? ""),
                escape(t.source.rawValue),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\r\n")
    }

    /// UTF-8 **with a BOM**. Without it Excel renders ₹ and Indian merchant names as mojibake;
    /// with it Numbers and Google Sheets are still fine.
    static func csv(_ txns: [Txn]) -> Data {
        var d = Data([0xEF, 0xBB, 0xBF])
        d.append(Data(csvText(txns).utf8))
        return d
    }

    /// A dedicated export DTO rather than `Txn` itself, so the interchange format can never be
    /// entangled with persistence's tolerant CodingKeys.
    struct Row: Codable, Equatable {
        var date: Date
        var merchant: String
        var category: String
        var account: String
        var amount: Double
        var currency: String
        var tags: [String]
        var counterparty: String?
        var transfer: Bool
        var reward: Double?
        var rewardUnit: String?
        var forexAmount: Double?
        var forexCurrency: String?
        var source: String
    }

    static func rows(_ txns: [Txn]) -> [Row] {
        txns.sorted { $0.date < $1.date }.map {
            Row(date: $0.date, merchant: $0.merchant, category: $0.category, account: $0.account,
                amount: $0.amount, currency: "INR", tags: $0.tags,
                counterparty: $0.counterparty, transfer: $0.transfer,
                reward: $0.reward, rewardUnit: $0.rewardCurrency,
                forexAmount: $0.forexAmount, forexCurrency: $0.forexCurrency,
                source: $0.source.rawValue)
        }
    }

    static func json(_ txns: [Txn]) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(rows(txns))) ?? Data()
    }
}
