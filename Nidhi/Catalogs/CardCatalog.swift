import Foundation

/// Factual reference of popular Indian credit cards (issuer, product name, network, tier)
/// for the add-card picker and statement/email matching. No card artwork is bundled —
/// covers are app-generated gradients (or a user-supplied image). Gradient colours are
/// app-chosen, not the issuers' designs.
struct CardInfo: Hashable, Identifiable {
    var id: String { "\(bankCode)·\(name)·\(network)" }
    var bankCode: String
    var name: String
    var network: String     // Visa / Mastercard / RuPay / Amex / Diners
    var tier: String
    var gradient: [String]  // two hex stops for the generated cover
}

enum CardCatalog {
    static let all: [CardInfo] = [
        .init(bankCode: "HDFC", name: "HDFC Millennia",        network: "Visa",       tier: "Cashback",       gradient: ["3A4A5A", "1C2530"]),
        .init(bankCode: "HDFC", name: "HDFC Regalia Gold",     network: "Visa",       tier: "Premium",        gradient: ["B8902E", "6E5418"]),
        .init(bankCode: "HDFC", name: "HDFC Diners Black",     network: "Diners",     tier: "Super-premium",  gradient: ["1A1A1A", "000000"]),
        .init(bankCode: "HDFC", name: "HDFC Infinia",          network: "Visa",       tier: "Super-premium",  gradient: ["2B2B2B", "0E0E0E"]),
        .init(bankCode: "HDFC", name: "HDFC Swiggy",           network: "Mastercard", tier: "Co-brand",       gradient: ["E8732A", "B5471A"]),
        .init(bankCode: "AXIS", name: "Axis Magnus",           network: "Mastercard", tier: "Super-premium",  gradient: ["2C2C2C", "111111"]),
        .init(bankCode: "AXIS", name: "Axis Atlas",            network: "Visa",       tier: "Travel",         gradient: ["8C1D40", "4E0F24"]),
        .init(bankCode: "AXIS", name: "Axis ACE",              network: "Visa",       tier: "Cashback",       gradient: ["1F6F6F", "0E4040"]),
        .init(bankCode: "AXIS", name: "Axis Flipkart",         network: "Mastercard", tier: "Co-brand",       gradient: ["1565C0", "0D3F80"]),
        .init(bankCode: "ICICI",name: "ICICI Amazon Pay",      network: "Visa",       tier: "Co-brand",       gradient: ["232F3E", "121821"]),
        .init(bankCode: "ICICI",name: "ICICI Sapphiro",        network: "Visa",       tier: "Premium",        gradient: ["1B4F72", "0E2A3D"]),
        .init(bankCode: "ICICI",name: "ICICI Coral",          network: "RuPay",      tier: "Entry",          gradient: ["C56B4A", "8A4630"]),
        .init(bankCode: "SBI",  name: "SBI Cashback",          network: "Visa",       tier: "Cashback",       gradient: ["22409A", "152A6B"]),
        .init(bankCode: "SBI",  name: "SBI SimplyCLICK",       network: "Visa",       tier: "Entry",          gradient: ["2E5BBC", "1A3B82"]),
        .init(bankCode: "SBI",  name: "SBI Elite",             network: "Visa",       tier: "Premium",        gradient: ["3A3A3A", "1A1A1A"]),
        .init(bankCode: "FED",  name: "Scapia Federal",        network: "Visa",       tier: "Travel",         gradient: ["12B5A5", "0A6F66"]),
        .init(bankCode: "FED",  name: "Scapia Federal",        network: "RuPay",      tier: "Travel",         gradient: ["12B5A5", "0A6F66"]),
        .init(bankCode: "KOTAK",name: "Kotak 811",             network: "Visa",       tier: "Entry",          gradient: ["C0392B", "7B241C"]),
        .init(bankCode: "KOTAK",name: "Kotak White Reserve",   network: "Visa",       tier: "Super-premium",  gradient: ["2B2B2B", "0E0E0E"]),
        .init(bankCode: "IDFC", name: "IDFC First Select",     network: "Visa",       tier: "Premium",        gradient: ["9C1D26", "5E1117"]),
        .init(bankCode: "INDUS",name: "IndusInd Legend",       network: "Visa",       tier: "Premium",        gradient: ["6E1228", "3C0A16"]),
        .init(bankCode: "RBL",  name: "RBL World Safari",      network: "Mastercard", tier: "Travel",         gradient: ["8C1D40", "4E0F24"]),
        .init(bankCode: "AMEX", name: "Amex Platinum Travel",  network: "Amex",       tier: "Travel",         gradient: ["6E7B8B", "3A434E"]),
        .init(bankCode: "AMEX", name: "Amex Membership Rewards",network: "Amex",      tier: "Rewards",        gradient: ["6E7B8B", "3A434E"]),
        .init(bankCode: "AU",   name: "AU LIT",                network: "Visa",       tier: "Customisable",   gradient: ["5A2D81", "33184C"]),
        .init(bankCode: "YES",  name: "Yes Marquee",           network: "Mastercard", tier: "Super-premium",  gradient: ["00518F", "002F53"]),
    ]

    static func cards(for bankCode: String?) -> [CardInfo] {
        guard let code = bankCode else { return all }
        return all.filter { $0.bankCode == code }
    }
    /// Best gradient for a card: catalog match by name, else single colour, else network default.
    static func gradient(name: String?, network: String?, colorHex: String?) -> [String] {
        if let n = name, let hit = all.first(where: { $0.name == n }) { return hit.gradient }
        if let c = colorHex { return [c, c] }
        return networkGradient(network)
    }
    static func networkGradient(_ network: String?) -> [String] {
        switch (network ?? "").lowercased() {
        case "amex": return ["6E7B8B", "3A434E"]
        case "rupay": return ["0E7C5A", "094A37"]
        case "mastercard": return ["3A3F4A", "1A1D24"]
        case "diners": return ["1A1A1A", "000000"]
        default: return ["2B3A55", "16203A"]   // visa-ish default
        }
    }
}
