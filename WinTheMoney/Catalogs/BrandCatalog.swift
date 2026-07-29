import SwiftUI

/// Factual mapping of common merchant/brand names to a budget category + facet tags. Matching
/// is fuzzy: the raw merchant/narration is normalised (boilerplate, "WWW", city suffixes and
/// ref numbers stripped) then tested against case-insensitive regex/substring patterns. Rules
/// are ordered most-specific-first; the first match wins. Easy to expand — add a `BrandRule`.
struct BrandRule {
    var patterns: [String]      // uppercase regex/substrings (matched against the normalised text)
    var brand: String
    var category: String
    var tags: [String]
    var icon: String? = nil     // Assets.xcassets image name (small CC0 vector mark), nil = fall back to the category's SF Symbol
}

enum BrandCatalog {
    static let all: [BrandRule] = [
        // ── Online food delivery ──
        .init(patterns: ["SWIGGY(?!.*INSTAMART)", "BUNDL TECH", "SWIGGY FOOD"], brand: "Swiggy", category: "Online food delivery", tags: ["Food delivery"], icon: "brand_swiggy"),
        .init(patterns: ["ZOMATO", "ETERNAL", "BLINK COMMERCE.*FOOD"], brand: "Zomato", category: "Online food delivery", tags: ["Food delivery"], icon: "brand_zomato"),
        .init(patterns: ["EATCLUB", "BOX8", "FAASOS", "EATFIT"], brand: "EatClub", category: "Online food delivery", tags: ["Food delivery"]),
        .init(patterns: ["\\bDUNZO\\b"], brand: "Dunzo", category: "Groceries", tags: ["Quick commerce"], icon: "brand_dunzo"),
        // ── Groceries / quick-commerce (before generic Amazon/Swiggy-Instamart) ──
        .init(patterns: ["BLINKIT", "GROFERS"], brand: "Blinkit", category: "Groceries", tags: ["Quick commerce"]),
        .init(patterns: ["ZEPTO"], brand: "Zepto", category: "Groceries", tags: ["Quick commerce"]),
        .init(patterns: ["INSTAMART"], brand: "Swiggy Instamart", category: "Groceries", tags: ["Quick commerce"]),
        .init(patterns: ["BIGBASKET", "BB ?NOW", "BB ?DAILY", "INNOVATIVE RETAIL"], brand: "BigBasket", category: "Groceries", tags: ["Quick commerce"], icon: "brand_bigbasket"),
        .init(patterns: ["AMAZON.{0,10}GROCERY", "AMAZON ?FRESH", "AMAZON.{0,6}NOW"], brand: "Amazon Fresh", category: "Groceries", tags: ["Quick commerce"]),
        // ── Kerala grocery/retail chains (before the generic Supermarket catch-all) ──
        .init(patterns: ["\\bLULU\\b"], brand: "Lulu Hypermarket", category: "Groceries", tags: ["Groceries"]),
        .init(patterns: ["\\bMILMA\\b"], brand: "Milma", category: "Groceries", tags: ["Groceries"]),
        .init(patterns: ["MARGIN ?FREE"], brand: "Margin Free Market", category: "Groceries", tags: ["Groceries"]),
        .init(patterns: ["JIOMART", "D ?MART", "DMART", "RELIANCE FRESH", "RELIANCE SMART", "MORE ?(SUPER|RETAIL)", "SPENCER", "STAR ?BAZAAR", "SUPERMARKET", "SUPER MARKET", "GROCER", "SUPPLY ?CO", "NILGIRIS"], brand: "Supermarket", category: "Groceries", tags: ["Groceries"]),
        // ── Eating out (dine-in / cafes / restaurants) ──
        .init(patterns: ["MC ?DONALD", "MCD\\b"], brand: "McDonald's", category: "Eating out", tags: ["Dining"], icon: "brand_mcdonalds"),
        .init(patterns: ["\\bKFC\\b"], brand: "KFC", category: "Eating out", tags: ["Dining"], icon: "brand_kfc"),
        .init(patterns: ["STARBUCKS"], brand: "Starbucks", category: "Eating out", tags: ["Coffee"], icon: "brand_starbucks"),
        .init(patterns: ["DOMINO"], brand: "Domino's", category: "Eating out", tags: ["Dining"]),
        .init(patterns: ["BURGER ?KING"], brand: "Burger King", category: "Eating out", tags: ["Dining"], icon: "brand_burgerking"),
        .init(patterns: ["DINEOUT", "EAZYDINER"], brand: "Dineout", category: "Eating out", tags: ["Dining"]),
        .init(patterns: ["\\bCCD\\b", "CAFE COFFEE DAY", "THIRD WAVE", "BLUE TOKAI", "\\bCAFE\\b", "COFFEE", "RESTAURAN", "BAKER", "BREW", "BISTRO", "KITCHEN", "PIZZA", "BIRYANI", "BARBEQUE", "BAR ?B ?Q"], brand: "Cafe & dining", category: "Eating out", tags: ["Dining"]),
        // ── Shopping & marketplaces ──
        .init(patterns: ["AMAZON ?PAY", "E ?COMMERC", "AMAZON\\b", "\\bAMZN\\b"], brand: "Amazon", category: "Shopping", tags: ["Online shopping"]),
        .init(patterns: ["FLIPKART"], brand: "Flipkart", category: "Shopping", tags: ["Online shopping"]),
        .init(patterns: ["MYNTRA"], brand: "Myntra", category: "Shopping", tags: ["Fashion"]),
        .init(patterns: ["\\bAJIO\\b"], brand: "Ajio", category: "Shopping", tags: ["Fashion"]),
        .init(patterns: ["NYKAA"], brand: "Nykaa", category: "Shopping", tags: ["Beauty"]),
        .init(patterns: ["GYFTR", "GIFT ?CARD", "WOOHOO"], brand: "Gyftr", category: "Shopping", tags: ["Gift cards"]),
        .init(patterns: ["MALABAR ?GOLD"], brand: "Malabar Gold & Diamonds", category: "Shopping", tags: ["Jewellery"]),
        .init(patterns: ["KALYAN ?JEWELL"], brand: "Kalyan Jewellers", category: "Shopping", tags: ["Jewellery"]),
        .init(patterns: ["\\bBEVCO\\b"], brand: "BEVCO", category: "Shopping", tags: ["Shopping"]),
        .init(patterns: ["MEESHO", "SNAPDEAL", "TATA ?CLIQ", "RELIANCE ?DIGITAL", "\\bCROMA\\b", "VIJAY ?SALES", "LIFESTYLE", "MAX ?FASHION", "WESTSIDE", "DECATHLON", "PEPPERFRY", "URBAN ?LADDER"], brand: "Retail & shopping", category: "Shopping", tags: ["Shopping"]),
        .init(patterns: ["ZARA"], brand: "Zara", category: "Shopping", tags: ["Fashion"], icon: "brand_zara"),
        .init(patterns: ["H ?& ?M"], brand: "H&M", category: "Shopping", tags: ["Fashion"], icon: "brand_hm"),
        .init(patterns: ["UNIQLO"], brand: "Uniqlo", category: "Shopping", tags: ["Fashion"], icon: "brand_uniqlo"),
        .init(patterns: ["\\bIKEA\\b"], brand: "IKEA", category: "Shopping", tags: ["Home"], icon: "brand_ikea"),
        .init(patterns: ["\\bNIKE\\b"], brand: "Nike", category: "Shopping", tags: ["Fashion"], icon: "brand_nike"),
        .init(patterns: ["ADIDAS"], brand: "Adidas", category: "Shopping", tags: ["Fashion"], icon: "brand_adidas"),
        // ── Transport (rides / commute) ──
        .init(patterns: ["\\bUBER\\b"], brand: "Uber", category: "Transport", tags: ["Ride-hailing"], icon: "brand_uber"),
        .init(patterns: ["\\bOLA\\b", "OLACABS", "ANI ?TECH"], brand: "Ola", category: "Transport", tags: ["Ride-hailing"]),
        .init(patterns: ["RAPIDO"], brand: "Rapido", category: "Transport", tags: ["Ride-hailing"]),
        .init(patterns: ["FASTAG", "\\bNETC\\b", "PAYTM ?FASTAG", "\\bTOLL\\b"], brand: "FASTag", category: "Transport", tags: ["Commute"]),
        .init(patterns: ["\\bKSRTC\\b"], brand: "KSRTC", category: "Transport", tags: ["Commute"]),
        .init(patterns: ["\\bMETRO\\b", "\\bDMRC\\b", "\\bBMRCL\\b", "\\bBMTC\\b", "\\bBEST\\b ?UNDERTAKING"], brand: "Public transit", category: "Transport", tags: ["Commute"]),
        // ── Fuel ──
        .init(patterns: ["\\bHPCL\\b", "\\bIOCL\\b", "\\bBPCL\\b", "INDIAN ?OIL", "\\bSHELL\\b", "\\bFUEL\\b", "PETROL", "FILLING ?STATION", "PETROLEUM", "FUEL ?STATION"], brand: "Fuel", category: "Fuel", tags: ["Fuel"]),
        // ── Travel ──
        .init(patterns: ["IRCTC", "\\bRAILWAY"], brand: "IRCTC", category: "Travel", tags: ["Train"]),
        .init(patterns: ["CONFIRMTKT", "CONFIRM ?TKT", "RAILYATRI"], brand: "ConfirmTkt", category: "Travel", tags: ["Train"]),
        .init(patterns: ["MAKEMYTRIP", "GOIBIBO", "CLEARTRIP", "\\bIXIGO\\b", "EASEMYTRIP", "\\bYATRA\\b"], brand: "Travel booking", category: "Travel", tags: ["Travel"]),
        .init(patterns: ["INDIGO", "VISTARA", "AIR ?INDIA", "SPICEJET", "\\bAKASA\\b", "AIRLINE", "AIRWAYS"], brand: "Airlines", category: "Travel", tags: ["Flights"]),
        .init(patterns: ["\\bOYO\\b", "\\bHOTEL\\b", "MARRIOTT", "TAJ ?HOTEL", "RESORT", "AIRBNB", "TREEBO", "FABHOTEL"], brand: "Hotels", category: "Travel", tags: ["Stay"]),
        // ── Bills & Utilities ──
        .init(patterns: ["ELECTRIC", "\\bKSEB\\b", "BESCOM", "TANGEDCO", "ADANI ?ELEC", "TATA ?POWER", "\\bBSES\\b", "\\bMSEB\\b", "POWER ?(BILL|CORP)", "PZELECTRIC"], brand: "Electricity", category: "Bills & Utilities", tags: ["Utility"]),
        .init(patterns: ["\\bJIO\\b", "RELIANCE ?JIO"], brand: "Jio", category: "Bills & Utilities", tags: ["Telecom"], icon: "brand_jio"),
        .init(patterns: ["AIRTEL"], brand: "Airtel", category: "Bills & Utilities", tags: ["Telecom"], icon: "brand_airtel"),
        .init(patterns: ["VODAFONE", "\\bVI\\b"], brand: "Vodafone Idea", category: "Bills & Utilities", tags: ["Telecom"], icon: "brand_vodafone"),
        .init(patterns: ["\\bBSNL\\b", "BROADBAND", "ACT ?FIBER", "HATHWAY", "\\bWATER ?BILL", "GAS ?BILL", "INDANE", "\\bGAIL\\b", "\\bDTH\\b", "TATA ?SKY", "RECHARGE"], brand: "Utilities", category: "Bills & Utilities", tags: ["Utility"]),
        .init(patterns: ["\\bRENT\\b", "NOBROKER", "NESTAWAY", "MAINTENANCE"], brand: "Rent & housing", category: "Bills & Utilities", tags: ["Housing"]),
        // ── Subscriptions / tech ──
        .init(patterns: ["NETFLIX"], brand: "Netflix", category: "Subscriptions", tags: ["Entertainment", "Streaming"], icon: "brand_netflix"),
        .init(patterns: ["SPOTIFY"], brand: "Spotify", category: "Subscriptions", tags: ["Entertainment", "Music"], icon: "brand_spotify"),
        .init(patterns: ["HOTSTAR", "JIOHOTSTAR", "DISNEY"], brand: "Hotstar", category: "Subscriptions", tags: ["Entertainment", "Streaming"]),
        .init(patterns: ["PRIME ?VIDEO", "AMAZON ?PRIME", "PRIMEVIDEO"], brand: "Prime Video", category: "Subscriptions", tags: ["Entertainment", "Streaming"]),
        .init(patterns: ["YOUTUBE"], brand: "YouTube", category: "Subscriptions", tags: ["Entertainment", "Streaming"], icon: "brand_youtube"),
        .init(patterns: ["SONYLIV", "ZEE5", "JIOCINEMA", "JIO ?CINEMA"], brand: "OTT", category: "Subscriptions", tags: ["Entertainment", "Streaming"]),
        .init(patterns: ["MANORAMA"], brand: "Manorama", category: "Subscriptions", tags: ["Media"]),
        .init(patterns: ["ICLOUD", "APPLE\\.COM", "APPLE ?(SERVICES|ONE)", "ITUNES", "\\bAPPLE\\b"], brand: "Apple", category: "Subscriptions", tags: ["Tech", "Utility"], icon: "brand_apple"),
        .init(patterns: ["GOOGLE ?ONE", "GOOGLE ?STORAGE", "GOOGLE ?\\*"], brand: "Google One", category: "Subscriptions", tags: ["Tech", "Utility"]),
        .init(patterns: ["GITHUB"], brand: "GitHub", category: "Subscriptions", tags: ["Tech", "Software"], icon: "brand_github"),
        .init(patterns: ["NOTION"], brand: "Notion", category: "Subscriptions", tags: ["Tech", "Software"], icon: "brand_notion"),
        .init(patterns: ["FIGMA"], brand: "Figma", category: "Subscriptions", tags: ["Tech", "Software"], icon: "brand_figma"),
        .init(patterns: ["OPENAI", "CHATGPT", "ANTHROPIC", "\\bCLAUDE\\b", "ADOBE", "MICROSOFT ?365", "OFFICE ?365", "CANVA", "LINKEDIN ?PREMIUM"], brand: "Software", category: "Subscriptions", tags: ["Tech", "Software"]),
        // ── Entertainment ──
        .init(patterns: ["BOOKMYSHOW", "BOOK ?MY ?SHOW"], brand: "BookMyShow", category: "Entertainment", tags: ["Entertainment"], icon: "brand_bookmyshow"),
        .init(patterns: ["\\bPVR\\b", "\\bINOX\\b", "CINEPOLIS", "CINEMA"], brand: "Movies & events", category: "Entertainment", tags: ["Entertainment"]),
        .init(patterns: ["\\bSTEAM\\b"], brand: "Steam", category: "Entertainment", tags: ["Gaming"], icon: "brand_steam"),
        .init(patterns: ["PLAYSTATION"], brand: "PlayStation", category: "Entertainment", tags: ["Gaming"], icon: "brand_playstation"),
        .init(patterns: ["EPIC ?GAMES"], brand: "Epic Games", category: "Entertainment", tags: ["Gaming"], icon: "brand_epicgames"),
        .init(patterns: ["\\bXBOX\\b", "NINTENDO"], brand: "Gaming", category: "Entertainment", tags: ["Gaming"]),
        // ── Health ──
        .init(patterns: ["PHARMEASY", "\\b1MG\\b", "TATA ?1MG", "NETMEDS", "APOLLO", "PHARMAC", "MEDPLUS", "WELLNESS ?FOREVER", "\\bDDRC\\b", "\\bSRL\\b", "\\bLAL ?PATH", "METROPOLIS", "DIAGNOSTIC", "HOSPITAL", "CLINIC", "\\bLAB\\b", "PRACTO", "CULT\\.?FIT", "CUREFIT", "MEDICAL"], brand: "Health & pharmacy", category: "Health", tags: ["Health"]),
        // ── Insurance ──
        .init(patterns: ["\\bLIC\\b", "HDFC ?LIFE", "ICICI ?PRU", "SBI ?LIFE", "MAX ?LIFE", "STAR ?HEALTH", "NIVA ?BUPA", "\\bACKO\\b", "\\bDIGIT\\b", "POLICYBAZAAR", "TATA ?AIG", "BAJAJ ?ALLIANZ", "INSURANCE", "\\bPREMIUM\\b ?(PAY|LIC)"], brand: "Insurance", category: "Insurance", tags: ["Insurance"]),
        // ── Taxes (CBDT = Central Board of Direct Taxes → income tax; CBIC/GST → indirect) ──
        .init(patterns: ["\\bCBDT\\b", "INCOME ?TAX", "DIRECT ?TAX", "\\bOLTAS\\b", "\\bITNS\\b", "TIN ?NSDL", "ADVANCE ?TAX", "SELF ?ASSESS"], brand: "Income Tax", category: "Tax", tags: ["Direct tax"]),
        .init(patterns: ["\\bGSTN?\\b", "\\bCBIC\\b", "\\b[ICSU]GST\\b", "\\bUTGST\\b"], brand: "GST", category: "Tax", tags: ["Indirect tax"]),
        .init(patterns: ["ICEGATE", "CUSTOMS? ?DUTY"], brand: "Customs duty", category: "Tax", tags: ["Indirect tax"]),
        // ── EMI & Loans ──
        // Recurring-deposit instalments must precede the generic EMI rule: their narration says
        // "RD Installment", which the EMI rule's \bINSTALLMENT\b pattern would otherwise claim. An RD
        // instalment is money moving into the user's own deposit, not borrowing costs.
        .init(patterns: ["\\bRD ?INSTAL", "RECURRING ?DEPOSIT"], brand: "Recurring deposit", category: "Investments", tags: ["Deposit"]),
        .init(patterns: ["MUTHOOT"], brand: "Muthoot Finance", category: "EMI & Loans", tags: ["Loan"]),
        .init(patterns: ["\\bEMI\\b", "\\bLOAN\\b", "BAJAJ ?FIN", "\\bNBFC\\b", "EARLYSALARY", "KREDITBEE", "MONEYVIEW", "HOME ?CREDIT", "INSTALLMENT", "\\bEMANDATE.*LOAN"], brand: "EMI / loan", category: "EMI & Loans", tags: ["Loan"]),
        // ── Education ──
        .init(patterns: ["\\bBYJU", "UNACADEMY", "VEDANTU", "WHITEHAT", "\\bUDEMY\\b", "COURSERA", "TUITION", "SCHOOL ?FEE", "COLLEGE ?FEE", "\\bACADEMY\\b", "EDTECH", "PHYSICSWALLAH"], brand: "Education", category: "Education", tags: ["Education"]),
        // ── Investments ──
        .init(patterns: ["GROWW", "ZERODHA", "INDMONEY", "IND ?MONEY", "PAYTM ?MONEY", "KUVERA", "\\bCOIN\\b", "UPSTOX", "SMALLCASE", "MUTUAL ?FU", "\\bSIP\\b", "GROW ?WEALTH"], brand: "Investments", category: "Investments", tags: ["Investing"]),
    ]

    /// Strips payment boilerplate, "WWW", domain suffixes, ref numbers and trailing place names
    /// so messy statement strings still match.
    static func normalize(_ raw: String) -> String {
        var s = " " + raw.uppercased() + " "
        // payment-rail prefixes & boilerplate tokens
        for t in ["UPI", "UPILITE", "POS", "NEFT", "IMPS", "RTGS", "ACH", "MANDATE", "EMANDATE", "BIL", "INF", "ATW", "ECS", "MMT", "VPS", "NO REMARKS", "VALUE DT", "REF", "PVT LTD", "PVT", "LTD", "LIMITED", "INDIA", "WWW", "COM", "PAYMENT"] {
            s = s.replacingOccurrences(of: " \(t) ", with: " ", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: #"\.[A-Z]{2,3}\b"#, with: " ", options: .regularExpression)   // .com/.in
        s = s.replacingOccurrences(of: #"\b\d{4,}\b"#, with: " ", options: .regularExpression)        // long ref ids
        s = s.replacingOccurrences(of: #"[^A-Z0-9@&* ]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Canonical brand + category + tags for a transaction string (first matching rule wins).
    static func classify(_ text: String) -> (brand: String?, category: String?, tags: [String], icon: String?) {
        let n = normalize(text)
        for rule in all where rule.patterns.contains(where: { n.range(of: $0, options: [.regularExpression]) != nil }) {
            return (rule.brand, rule.category, rule.tags, rule.icon)
        }
        return (nil, nil, [], nil)
    }

    /// Icon asset name for raw transaction text (merchant + counterparty), if the matched rule has one.
    static func icon(for text: String) -> String? { classify(text).icon }
    /// Icon asset name for an already-resolved canonical brand string (e.g. from `Store.spendByBrand`).
    static func icon(forBrand brand: String) -> String? { all.first { $0.brand == brand }?.icon }
}

/// Detects transfers (credit-card bill payments / self-transfers) and refunds so they can be
/// excluded from, or netted against, spend.
enum Classifier {
    static func isCardBillPayment(_ text: String) -> Bool {
        let u = text.uppercased()
        let cc = ["CREDIT CARD", "CC PAYMENT", "CARD PAYMENT", "CARD BILL", "CC BILL", "CREDITCARD"]
        let pay = ["PAYMENT", "BILLPAY", "BILL PAY", "BBPS", "AUTOPAY", "PYMT", "PAID"]
        if cc.contains(where: { u.contains($0) }) && pay.contains(where: { u.contains($0) }) { return true }
        return false
    }
    /// Card-side payment credit ("AUTOPAY THANK YOU", "Bill payment", "Payment received").
    static func isCardPaymentCredit(_ text: String) -> Bool {
        let u = text.uppercased()
        return ["AUTOPAY", "THANK YOU", "PAYMENT RECEIVED", "BILL PAYMENT", "BBPS PAYMENT", "PAYMENT - THANK"].contains { u.contains($0) }
    }
    static func isRefund(_ text: String) -> Bool {
        let u = text.uppercased()
        return ["REFUND", "REVERSAL", "CASHBACK", "WAIVER", "REVERSED"].contains { u.contains($0) }
    }
}

/// Stable colour + icon for a tag (deterministic from its name; no persistence needed).
enum TagStyle {
    private static let palette: [Color] = [Zen.accent, Zen.green, Zen.accentDeep, Zen.greenDeep, Zen.caution]
    private static let known: [String: (Color, String)] = [
        "Refund": (Zen.greenDeep, "arrow.uturn.backward"),
        "Credit card bill": (Zen.caution, "creditcard"),
        "Subscription": (Zen.accentDeep, "repeat"),
        "Entertainment": (Zen.accent, "play.tv"),
        "Streaming": (Zen.accent, "play.rectangle"),
        "Tech": (Zen.accentDeep, "cpu"),
        "Utility": (Zen.caution, "bolt"),
        "Travel": (Zen.green, "airplane"),
        "Food delivery": (Zen.accent, "takeoutbag.and.cup.and.straw"),
        "Investing": (Zen.greenDeep, "chart.line.uptrend.xyaxis"),
    ]
    static func color(_ tag: String) -> Color {
        if let k = known[tag] { return k.0 }
        let h = abs(tag.hashValue) % palette.count
        return palette[h]
    }
    static func icon(_ tag: String) -> String { known[tag]?.1 ?? "tag" }
}
