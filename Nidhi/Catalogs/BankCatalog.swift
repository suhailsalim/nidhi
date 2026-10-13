import Foundation

/// Factual directory of Indian banks (names + public IFSC prefixes) with brand-approximate
/// colours for monogram tiles. No logos/trademarked artwork are bundled — banks render as
/// colour + monogram (or a user-supplied image). Colours are app-chosen approximations.
struct BankInfo: Hashable {
    var code: String        // short monogram, e.g. HDFC
    var name: String
    var colorHex: String
    var ifscPrefix: String  // first 4 chars of IFSC
    var type: String        // Public / Private / SFB / Payments / Foreign
}

enum BankCatalog {
    static let all: [BankInfo] = [
        // Private
        .init(code: "HDFC",  name: "HDFC Bank",            colorHex: "004C8F", ifscPrefix: "HDFC", type: "Private"),
        .init(code: "ICICI", name: "ICICI Bank",           colorHex: "AE282E", ifscPrefix: "ICIC", type: "Private"),
        .init(code: "AXIS",  name: "Axis Bank",            colorHex: "97144D", ifscPrefix: "UTIB", type: "Private"),
        .init(code: "KOTAK", name: "Kotak Mahindra Bank",  colorHex: "EF3E23", ifscPrefix: "KKBK", type: "Private"),
        .init(code: "FED",   name: "Federal Bank",         colorHex: "F6A600", ifscPrefix: "FDRL", type: "Private"),
        .init(code: "IDFC",  name: "IDFC First Bank",      colorHex: "9C1D26", ifscPrefix: "IDFB", type: "Private"),
        .init(code: "INDUS", name: "IndusInd Bank",        colorHex: "9B1B30", ifscPrefix: "INDB", type: "Private"),
        .init(code: "YES",   name: "Yes Bank",             colorHex: "00518F", ifscPrefix: "YESB", type: "Private"),
        .init(code: "RBL",   name: "RBL Bank",             colorHex: "8C1D40", ifscPrefix: "RATN", type: "Private"),
        .init(code: "BANDH", name: "Bandhan Bank",         colorHex: "B7202E", ifscPrefix: "BDBL", type: "Private"),
        .init(code: "DBS",   name: "DBS Bank India",       colorHex: "E02020", ifscPrefix: "DBSS", type: "Private"),
        .init(code: "IDBI",  name: "IDBI Bank",            colorHex: "006B3F", ifscPrefix: "IBKL", type: "Private"),
        .init(code: "JK",    name: "Jammu & Kashmir Bank", colorHex: "B8232F", ifscPrefix: "JAKA", type: "Private"),
        .init(code: "KVB",   name: "Karur Vysya Bank",     colorHex: "00529B", ifscPrefix: "KVBL", type: "Private"),
        .init(code: "SIB",   name: "South Indian Bank",    colorHex: "00529B", ifscPrefix: "SIBL", type: "Private"),
        .init(code: "CSB",   name: "CSB Bank",             colorHex: "00467F", ifscPrefix: "CSBK", type: "Private"),
        .init(code: "DCB",   name: "DCB Bank",             colorHex: "005CAB", ifscPrefix: "DCBL", type: "Private"),
        .init(code: "TMB",   name: "Tamilnad Mercantile",  colorHex: "0E5AA7", ifscPrefix: "TMBL", type: "Private"),
        // Public sector
        .init(code: "SBI",   name: "State Bank of India",  colorHex: "22409A", ifscPrefix: "SBIN", type: "Public"),
        .init(code: "PNB",   name: "Punjab National Bank", colorHex: "A6271F", ifscPrefix: "PUNB", type: "Public"),
        .init(code: "BOB",   name: "Bank of Baroda",       colorHex: "F37021", ifscPrefix: "BARB", type: "Public"),
        .init(code: "CANARA",name: "Canara Bank",          colorHex: "00539B", ifscPrefix: "CNRB", type: "Public"),
        .init(code: "UNION", name: "Union Bank of India",  colorHex: "B11116", ifscPrefix: "UBIN", type: "Public"),
        .init(code: "BOI",   name: "Bank of India",        colorHex: "F58220", ifscPrefix: "BKID", type: "Public"),
        .init(code: "INDIANB",name: "Indian Bank",         colorHex: "00558C", ifscPrefix: "IDIB", type: "Public"),
        .init(code: "CBI",   name: "Central Bank of India",colorHex: "9C1D26", ifscPrefix: "CBIN", type: "Public"),
        .init(code: "IOB",   name: "Indian Overseas Bank", colorHex: "00488D", ifscPrefix: "IOBA", type: "Public"),
        .init(code: "UCO",   name: "UCO Bank",             colorHex: "00529B", ifscPrefix: "UCBA", type: "Public"),
        .init(code: "BOM",   name: "Bank of Maharashtra",  colorHex: "F49D1A", ifscPrefix: "MAHB", type: "Public"),
        .init(code: "PSB",   name: "Punjab & Sind Bank",   colorHex: "B11116", ifscPrefix: "PSIB", type: "Public"),
        // Small finance
        .init(code: "AU",    name: "AU Small Finance Bank",colorHex: "5A2D81", ifscPrefix: "AUBL", type: "SFB"),
        .init(code: "EQUI",  name: "Equitas SFB",          colorHex: "E4002B", ifscPrefix: "ESFB", type: "SFB"),
        .init(code: "UJJI",  name: "Ujjivan SFB",          colorHex: "00A14B", ifscPrefix: "UJVN", type: "SFB"),
        .init(code: "JANA",  name: "Jana SFB",             colorHex: "ED1C24", ifscPrefix: "JSFB", type: "SFB"),
        .init(code: "SURYA", name: "Suryoday SFB",         colorHex: "F47920", ifscPrefix: "SURY", type: "SFB"),
        // Payments
        .init(code: "PAYTM", name: "Paytm Payments Bank",  colorHex: "00B9F1", ifscPrefix: "PYTM", type: "Payments"),
        .init(code: "AIRTEL",name: "Airtel Payments Bank", colorHex: "ED1C24", ifscPrefix: "AIRP", type: "Payments"),
        .init(code: "FINO",  name: "Fino Payments Bank",   colorHex: "00529B", ifscPrefix: "FINO", type: "Payments"),
        .init(code: "IPPB",  name: "India Post Payments",  colorHex: "C8102E", ifscPrefix: "IPOS", type: "Payments"),
        .init(code: "JIO",   name: "Jio Payments Bank",    colorHex: "0A2885", ifscPrefix: "JIOP", type: "Payments"),
        // Foreign
        .init(code: "CITI",  name: "Citibank",             colorHex: "003B70", ifscPrefix: "CITI", type: "Foreign"),
        .init(code: "HSBC",  name: "HSBC India",           colorHex: "DB0011", ifscPrefix: "HSBC", type: "Foreign"),
        .init(code: "SC",    name: "Standard Chartered",   colorHex: "0072CE", ifscPrefix: "SCBL", type: "Foreign"),
        .init(code: "DEUT",  name: "Deutsche Bank",        colorHex: "0018A8", ifscPrefix: "DEUT", type: "Foreign"),
    ]

    static let byCode: [String: BankInfo] = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    static let byIFSC: [String: BankInfo] = Dictionary(all.map { ($0.ifscPrefix, $0) }, uniquingKeysWith: { a, _ in a })

    static func match(ifsc: String?) -> BankInfo? {
        guard let p = ifsc?.uppercased().prefix(4), p.count == 4 else { return nil }
        return byIFSC[String(p)]
    }
    static func match(name: String) -> BankInfo? {
        let n = name.uppercased()
        return all.first { n.contains($0.name.uppercased()) || n.contains($0.code) }
    }
    static func info(_ code: String?) -> BankInfo? { code.flatMap { byCode[$0] } }

    /// Sorted for pickers (by type then name).
    static var sorted: [BankInfo] { all.sorted { $0.name < $1.name } }
}
