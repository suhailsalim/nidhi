import Foundation

/// Stock/ETF exchanges by country, with the Yahoo Finance symbol suffix + the exchange
/// short-codes Yahoo returns in search results (used to filter to the chosen exchange).
struct Market: Hashable {
    var country: String
    var exchange: String      // display name
    var suffix: String        // Yahoo symbol suffix (e.g. ".NS"; "" for US)
    var codes: [String]       // Yahoo `exchange` short codes for this venue
    var currency: String
}

enum MarketCatalog {
    static let all: [Market] = [
        .init(country: "India", exchange: "NSE", suffix: ".NS", codes: ["NSI"], currency: "INR"),
        .init(country: "India", exchange: "BSE", suffix: ".BO", codes: ["BSE"], currency: "INR"),
        .init(country: "United States", exchange: "NASDAQ", suffix: "", codes: ["NMS", "NGM", "NCM"], currency: "USD"),
        .init(country: "United States", exchange: "NYSE", suffix: "", codes: ["NYQ", "PCX", "ASE", "BTS"], currency: "USD"),
        .init(country: "United Kingdom", exchange: "LSE", suffix: ".L", codes: ["LSE"], currency: "GBP"),
        .init(country: "Canada", exchange: "TSX", suffix: ".TO", codes: ["TOR"], currency: "CAD"),
        .init(country: "Germany", exchange: "XETRA", suffix: ".DE", codes: ["GER"], currency: "EUR"),
        .init(country: "Japan", exchange: "TSE", suffix: ".T", codes: ["JPX"], currency: "JPY"),
        .init(country: "Hong Kong", exchange: "HKEX", suffix: ".HK", codes: ["HKG"], currency: "HKD"),
        .init(country: "Singapore", exchange: "SGX", suffix: ".SI", codes: ["SES"], currency: "SGD"),
        .init(country: "Australia", exchange: "ASX", suffix: ".AX", codes: ["ASX"], currency: "AUD"),
    ]
    /// Countries in catalog order (deduped).
    static var countries: [String] {
        var seen = Set<String>(); return all.map(\.country).filter { seen.insert($0).inserted }
    }
    static func exchanges(_ country: String) -> [Market] { all.filter { $0.country == country } }
    static let `default` = all[0]   // India · NSE
}
