import Foundation

/// Parses **credit-card** statements (distinct from bank passbooks). Extracts the card's
/// last-4, credit limit and total amount due (→ exact outstanding), plus spend transactions.
/// Verified against real HDFC (Diners), Axis (Atlas), ICICI (Amazon Pay) and Scapia (Federal)
/// June statements — each issuer has its own layout, handled by a dedicated parser.
enum CardStatementParser {
    enum Issuer: String { case hdfc = "HDFC", axis = "AXIS", icici = "ICICI", federal = "FED", generic = "" }

    static func isCardStatement(_ text: String) -> Bool {
        let t = text.lowercased()
        let cardish = t.contains("credit card") || t.contains("card number") || t.contains("card no")
        let dueish = t.contains("total amount due") || t.contains("total dues") || t.contains("total payment due") ||
                     t.contains("total due") || t.contains("minimum amount due") || t.contains("minimum due") ||
                     t.contains("payment due date") || t.contains("credit limit")
        let bankish = t.contains("opening balance") && t.contains("closing balance")
        return cardish && dueish && !bankish
    }

    static func detectIssuer(_ text: String) -> Issuer {
        let t = text.lowercased()
        if t.contains("scapia") || (t.contains("federal") && !t.contains("hdfc")) { return .federal }
        if t.contains("hdfc") { return .hdfc }
        if t.contains("axis bank") || t.contains("axis credit") { return .axis }
        if t.contains("icici") { return .icici }
        return .generic
    }

    static func parse(text: String, pages: [[PDFWord]] = []) -> (account: SyncedAccount, txns: [SyncedTxn])? {
        guard isCardStatement(text) else { return nil }
        switch detectIssuer(text) {
        case .hdfc:    return parseHDFC(text)
        case .axis:    return parseAxis(text)
        case .icici:   return parseICICI(text)
        case .federal: return parseScapia(text)
        case .generic: return nil
        }
    }

    // MARK: - HDFC (Diners etc.) — "C" rupee glyph, multi-line rows, credits flagged by keyword
    private static func parseHDFC(_ text: String) -> (SyncedAccount, [SyncedTxn]) {
        let mask = cap(#"X{2,}(\d{4})"#, text) ?? ""
        let limit = headerMoney(["TOTAL CREDIT LIMIT"], text, gap: 50)
        let due = headerMoney(["TOTAL AMOUNT DUE"], text, gap: 50)
        let minDue = headerMoney(["MINIMUM AMOUNT DUE"], text, gap: 50)
        let dueOn = dueDate(["Payment Due Date", "PAYMENT DUE DATE"], text)
        let product = pickProduct(.hdfc, text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // HDFC groups spend under an ALL-CAPS cardholder header (primary listed first, then each
        // add-on card). Assemble multi-line rows like `records` does, but carry the holder each row
        // falls under so add-on spends can be attributed + tagged. A header is a 2–4 word ALL-CAPS
        // name whose next non-empty line is a transaction row — which separates a real cardholder
        // from summary labels like "TOTAL AMOUNT" / "IMPORTANT INFORMATION".
        // domestic rows: "dd/MM/yyyy|", international rows: "dd/MM/yyyy |" (space before pipe)
        func isDateRow(_ l: String) -> Bool { matches(#"^\d{2}/\d{2}/\d{4}\s*\|"#, l) }
        func nextNonEmpty(after i: Int) -> String? {
            var j = i + 1
            while j < lines.count { if !lines[j].isEmpty { return lines[j] }; j += 1 }
            return nil
        }
        func isHolderHeader(_ l: String, _ i: Int) -> Bool {
            guard matches(#"^[A-Z][A-Z]+(?: [A-Z]+){1,3}$"#, l), let n = nextNonEmpty(after: i) else { return false }
            return isDateRow(n)
        }
        // HDFC splits spend into "Domestic Transactions" and "International Transactions" sections;
        // carry which section each row falls under so forex rows can be flagged + their original
        // currency/amount captured. The card-control summary on page 1 also names both, but it sits
        // before any transaction row, so the real section headers (which come later) win.
        var recs: [(text: String, holder: String?, intl: Bool)] = []
        var cur: String? = nil
        var primary: String? = nil, holder: String? = nil   // holder == nil ⇒ primary card
        var intl = false
        for (i, l) in lines.enumerated() where !l.isEmpty {
            if matches(#"(?i)international transaction"#, l) { if let c = cur { recs.append((c, holder, intl)); cur = nil }; intl = true; continue }
            if matches(#"(?i)domestic transaction"#, l)      { if let c = cur { recs.append((c, holder, intl)); cur = nil }; intl = false; continue }
            if isHolderHeader(l, i) {
                if let c = cur { recs.append((c, holder, intl)); cur = nil }
                if primary == nil { primary = l; holder = nil }   // first holder listed = primary card
                else { holder = (l == primary) ? nil : l }        // a later block under the primary name is still primary
                continue
            }
            if isDateRow(l) { if let c = cur { recs.append((c, holder, intl)) }; cur = l }
            else if hdfcNoise(l) { if let c = cur { recs.append((c, holder, intl)); cur = nil } }
            else if cur != nil { cur! += " " + l }
        }
        if let c = cur { recs.append((c, holder, intl)) }

        var txns: [SyncedTxn] = []
        var lastDate: Date? = nil
        for (g, rowHolder, isIntl) in recs {
            // first C-amount on the row (later "C…" tokens can be trailing summaries / refs)
            guard let amt = lastMoney(#"C\s*([\d,]+\.\d{2})"#, g, lazyFirst: true) else { continue }
            var m = replace(#"^\d{2}/\d{2}/\d{4}\s*\|\s*\d{2}:\d{2}\s*"#, in: g, with: "")
            // HDFC prefixes "EMI " on any domestic-spend row it thinks is *eligible* to convert to
            // EMI (see "Eligible for EMI TRANSACTIONS" / "CONVERT TO EMI" section) — it's an offer
            // marker, not part of the merchant name, and must not be confused with a genuine EMI/loan
            // charge (those read "EMI INTEREST/PRINCIPAL" or "MER EMI ,INT ...", never bare "EMI <name>").
            m = replace(#"^EMI\s+(?!(?:INTEREST|PRINCIPAL)\b)"#, in: m, with: "")
            m = replace(#"(?:[+\-]\s*\d+\s*)?C\s*[\d,]+\.\d{2}[\s\S]*$"#, in: m, with: "")
            m = replace(#"\(Ref#[^)]*\)"#, in: m, with: "")
            // reward points earned: the "+ N" sitting just before the row's C-amount ("+ 5 C 164.00").
            let pts = cap(#"\+\s*(\d+)\s*C\s*[\d,]+\.\d{2}"#, g).flatMap { Double($0) }
            // international rows carry the original currency + amount ("EUR 150.06") before the INR total.
            let fx = isIntl ? forex(g) : nil
            if let fx { m = replace(#"\s*\b\#(fx.currency)\s+[\d,]+\.\d{2}\s*$"#, in: m, with: "") }
            let merchant = tidy(m)
            let credit = creditByKeyword(g)
            let (date, dateOK) = resolveDate(parseDate(cap(#"^(\d{2}/\d{2}/\d{4})"#, g) ?? "", ["dd/MM/yyyy"]), &lastDate)
            txns.append(mk("hdfc", date, merchant, amt, credit, mask, "HDFC", dateResolved: dateOK, rawContext: g,
                           cardholder: rowHolder.map { $0.capitalized },
                           reward: pts, rewardCurrency: rewardUnit(.hdfc),
                           forexCurrency: fx?.currency, forexAmount: fx?.amount, isInternational: isIntl))
        }
        let rw = reward("Points", #"Reward Points[\s\S]{0,15}?([\d,]{2,})"#, text)
        return (cardAccount(.hdfc, mask: mask, due: due, limit: limit, product: product, reward: rw, minDue: minDue, dueDate: dueOn), txns)
    }
    private static func hdfcNoise(_ l: String) -> Bool {
        l.contains("Diners") || l.contains("Page ") || l.contains("HDFC Bank Credit Cards") ||
        l.contains("Domestic Transaction") || l.contains("Reward Points") || l.isEmpty
    }

    // MARK: - Axis (Atlas etc.) — single-line rows: date | details | MERCHANT CATEGORY | amount Dr/Cr
    private static func parseAxis(_ text: String) -> (SyncedAccount, [SyncedTxn]) {
        let mask = cap(#"(?:Credit Card Number|Card No:?)\s*\d{6}\*+(\d{4})"#, text) ?? cap(#"\*{2,}(\d{4})"#, text) ?? ""
        let limit = cap(#"Credit Limit\s+([\d,]+\.\d{2})\s+Available"#, text).flatMap(money)
        let availLimit = cap(#"Available Credit Limit\s+([\d,]+\.\d{2})"#, text).flatMap(money)
        let due = lastMoney(#"Total Payment Due[\s\S]{0,90}?\n\s*([\d,]+\.\d{2})"#, text, lazyFirst: true)
        let minDue = lastMoney(#"Minimum Payment Due[\s\S]{0,90}?\n\s*([\d,]+\.\d{2})"#, text, lazyFirst: true)
        let dueOn = dueDate(["Payment Due Date"], text)
        let product = pickProduct(.axis, text)
        var txns: [SyncedTxn] = []
        var lastDate: Date? = nil
        let rowRe = re(#"^(\d{2}/\d{2}/\d{4})\s+(.+?)\s+([\d,]+\.\d{2})\s+(Dr|Cr)$"#)
        for l in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let g = match(rowRe, l), let v = money(g[3]) else { continue }
            let credit = g[4] == "Cr"
            let (date, dateOK) = resolveDate(parseDate(g[1], ["dd/MM/yyyy"]), &lastDate)
            // The details cell carries an inline forex leg "( EUR 109.93 )" for international spends,
            // and the statement's own MCC "MERCHANT CATEGORY" column trails the merchant before the
            // amount. Peel both off so the merchant name is clean and the row is properly classified.
            var detail = g[2]
            let fx = axisForex(detail)
            if let fx { detail = fx.stripped }
            let (merchant, lexCat) = splitAxisCategory(detail)
            var category = lexCat ?? mapCategory(merchant)
            if matches(#"^EMI (INTEREST|PRINCIPAL)\b"#, merchant.uppercased()) { category = "EMI & Loans" }
            txns.append(mk("axis", date, tidy(merchant), v, credit, mask, "AXIS", category: category,
                           dateResolved: dateOK, rawContext: l,
                           forexCurrency: fx?.currency, forexAmount: fx?.amount, isInternational: fx != nil))
        }
        let rw = reward("Miles", #"eDGE MILES[\s\S]{0,600}?([\d,]{3,})\s+\d{2}-\d{2}-\d{4}"#, text)
        return (cardAccount(.axis, mask: mask, due: due, limit: limit, product: product, reward: rw, availableLimit: availLimit, minDue: minDue, dueDate: dueOn), txns)
    }

    /// Axis prints an MCC "MERCHANT CATEGORY" column as the trailing word(s) of each spend row (before
    /// the amount). It's a fixed vocabulary — strip the matched token off the merchant name and map the
    /// informative ones to a budget category. Catch-all buckets (MISCELLANEOUS / MISC STORE / SERVICES)
    /// are stripped for a clean name but left uncategorised so the brand classifier can decide. Charge
    /// rows (GST, fees, EMI legs) carry no category column, so nothing is stripped.
    private static let axisCategories: [(token: String, budget: String?)] = [
        ("RESTAURANTS", "Eating out"), ("FAST FOOD", "Eating out"), ("CATERERS", "Eating out"),
        ("BAKERIES", "Eating out"), ("BARS", "Eating out"),
        ("HOTELS", "Travel"), ("LODGING", "Travel"), ("AIRLINES", "Travel"),
        ("TRAVEL AGENCIES", "Travel"), ("RAILWAYS", "Travel"), ("TRAVEL", "Travel"),
        ("GROCERY STORES", "Groceries"), ("SUPERMARKETS", "Groceries"), ("FOOD PRODUCTS", "Groceries"),
        ("DEPARTMENT STORES", "Groceries"), ("DEPT STORES", "Groceries"),
        ("CLOTH STORES", "Shopping"), ("SHOE STORES", "Shopping"), ("BOOK STORES", "Shopping"),
        ("ELECTRONICS", "Shopping"), ("FURNITURE", "Shopping"), ("JEWELRY", "Shopping"),
        ("CAR RENTALS", "Transport"), ("AUTO SERVICES", "Transport"), ("TAXICABS", "Transport"),
        ("PARKING", "Transport"), ("TOLL", "Transport"),
        ("SERVICE STATIONS", "Fuel"), ("PETROL", "Fuel"), ("FUEL", "Fuel"),
        ("DRUG STORES", "Health"), ("HOSPITALS", "Health"), ("PHARMACIES", "Health"), ("MEDICAL", "Health"),
        ("UTILITIES", "Bills & Utilities"), ("TELECOM", "Bills & Utilities"),
        ("INSURANCE", "Insurance"), ("SCHOOLS", "Education"), ("EDUCATION", "Education"),
        ("MISCELLANEOUS", nil), ("MISC STORE", nil), ("SERVICES", nil),
    ].sorted { $0.token.count > $1.token.count }   // longest token wins (e.g. "DEPT STORES" before "STORES")

    private static func splitAxisCategory(_ detail: String) -> (merchant: String, budget: String?) {
        let upper = detail.uppercased()
        for (tok, budget) in axisCategories where upper.hasSuffix(tok) {
            let idx = detail.index(detail.endIndex, offsetBy: -tok.count)
            // require a word boundary before the token so we don't slice into a real merchant word
            guard idx == detail.startIndex || detail[detail.index(before: idx)] == " " else { continue }
            return (String(detail[..<idx]).trimmingCharacters(in: .whitespaces), budget)
        }
        return (detail, nil)
    }

    /// An Axis international row's original currency + amount, from the inline "( EUR 109.93 )" leg.
    private static func axisForex(_ detail: String) -> (currency: String, amount: Double, stripped: String)? {
        guard let g = cap2(#"\(\s*([A-Z]{3})\s+([\d,]+(?:\.\d{1,2})?)\s*\)"#, detail), let a = money(g.1) else { return nil }
        let stripped = tidy(replace(#"\(\s*[A-Z]{3}\s+[\d,]+(?:\.\d{1,2})?\s*\)"#, in: detail, with: " "))
        return (g.0, a, stripped)
    }

    // MARK: - ICICI (Amazon Pay etc.) — "`" rupee glyph; date+serno line then points+amount line
    private static func parseICICI(_ text: String) -> (SyncedAccount, [SyncedTxn]) {
        let mask = cap(#"\d{4}X{2,}(\d{4})"#, text) ?? ""
        // anchor to the ` (₹) glyph so MITC sample limits (e.g. "Credit Limit 35,000") aren't matched
        let limit = cap(#"Credit Limit \(Including cash\)[\s\S]{0,160}?`\s*([\d,]+\.\d{2})"#, text).flatMap(money)
        let due = cap(#"Total Amount due[\s\S]{0,160}?`\s*([\d,]+\.\d{2})"#, text).flatMap(money)
        let minDue = cap(#"Minimum Amount due[\s\S]{0,160}?`\s*([\d,]+\.\d{2})"#, text).flatMap(money)
        let dueOn = dueDate(["Payment Due Date", "Due Date"], text)
        let product = pickProduct(.icici, text)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let recs = records(lines, start: { matches(#"^\d{2}/\d{2}/\d{4}\s+\d{6,}\s"#, $0) },
                           stop: { $0.contains("Page ") || $0.lowercased().contains("statement period") })
        var txns: [SyncedTxn] = []
        var lastDate: Date? = nil
        for g in recs {
            guard let amt = lastMoney(#"([\d,]+\.\d{2})"#, g) else { continue }
            var m = replace(#"^\d{2}/\d{2}/\d{4}\s+\d{6,}\s*"#, in: g, with: "")
            m = replace(#"\s+\d+\s+[\d,]+\.\d{2}(\s+(?:IN|CR))?.*$"#, in: m, with: "")
            let credit = creditByKeyword(g) || g.uppercased().contains(" CR")
            // best-effort: the integer immediately before the amount is the row's reward points
            let pts = cap(#"\s(\d+)\s+[\d,]+\.\d{2}(?:\s+(?:IN|CR))?\s*$"#, g).flatMap { Double($0) }
            let (date, dateOK) = resolveDate(parseDate(cap(#"^(\d{2}/\d{2}/\d{4})"#, g) ?? "", ["dd/MM/yyyy"]), &lastDate)
            txns.append(mk("icici", date, tidy(m), amt, credit, mask, "ICICI", dateResolved: dateOK, rawContext: g,
                           reward: pts, rewardCurrency: rewardUnit(.icici)))
        }
        let rw = reward("Cashback", #"EARNINGS[\s\S]{0,200}?\b(\d{1,7})\s+\1\b"#, text)
        return (cardAccount(.icici, mask: mask, due: due, limit: limit, product: product, reward: rw, minDue: minDue, dueDate: dueOn), txns)
    }

    // MARK: - Scapia (Federal) — "₹" glyph, multi-line rows; credits shown as "+₹" / Payment / Refund
    private static func parseScapia(_ text: String) -> (SyncedAccount, [SyncedTxn]) {
        let mask = cap(#"X{2,}(\d{4})"#, text) ?? ""
        let limit = headerMoney(["Total Limit"], text, gap: 20)
        let due = headerMoney(["Total Due", "New balance"], text, gap: 20)
        let minDue = headerMoney(["Minimum Due", "Minimum Amount Due"], text, gap: 20)
        let dueOn = dueDate(["Payment Due Date", "Due Date"], text)
        // Scapia lists rows either inline ("date merchant ₹amount") or in columns
        // (merchant1, merchant2, …, then amount1, amount2, …). Collect merchants (each
        // opened by a date line) and amounts in document order, then zip — works for both.
        let dateRe = re(#"^(\d{2}-\d{2}-\d{4})\s*·\s*\d{2}:\d{2}\s*(.*)$"#)
        let amtRe = re(#"(\+)?₹\s*([\d,]+\.\d{2})"#)
        func isNoise(_ l: String) -> Bool {
            l.isEmpty || l.contains("Your Transactions") || l.contains("Billing Cycle") || l == "Suhail Salim"
                || l.hasPrefix("•") || matches(#"^\d{2} \w{3} \d{4} - "#, l)
        }
        func isStop(_ l: String) -> Bool {
            l.contains("Let’s talk") || l.contains("Let's talk") || l.contains("All about your")
                || l.contains("Most Important") || l.contains("GRIEVANCE") || l.contains("Illustration of")
        }
        // Gather the transactions section, then split on EVERY embedded date so multiple
        // transactions packed on one physical line become separate logical rows.
        var inSection = false; var blob = ""
        for l in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if !inSection { if l.contains("Your Transactions") { inSection = true }; continue }
            if isStop(l) { break }
            if isNoise(l) { continue }
            blob += " " + l
        }
        let split = replace(#"(?=\d{2}-\d{2}-\d{4}\s*·\s*\d{2}:\d{2})"#, in: blob, with: "\n")
        let lines = split.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        var txns: [SyncedTxn] = []
        var pending: [(date: Date, merchant: String, dateOK: Bool)] = []   // merchants awaiting an amount (FIFO)
        var lastDate: Date? = nil
        var n = 0
        // Scapia prefixes every credit with "+₹" and never a debit → sign comes from the token.
        func pop(_ v: Double, _ credit: Bool) {
            guard !pending.isEmpty else { return }
            let p = pending.removeFirst()
            txns.append(mk("scapia\(n)", p.date, p.merchant.isEmpty ? "Scapia Federal" : p.merchant, v, credit, mask, "FED",
                           dateResolved: p.dateOK, rawContext: p.merchant)); n += 1
        }
        func amts(_ s: String) -> [(Double, Bool)] {
            guard let r = amtRe else { return [] }
            let ns = s as NSString
            return r.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
                (money(ns.substring(with: $0.range(at: 2))) ?? 0, $0.range(at: 1).location != NSNotFound)
            }
        }
        for l in lines where !l.isEmpty {
            if let g = match(dateRe, l) {
                let (d, dateOK) = resolveDate(parseDate(g[1], ["dd-MM-yyyy"]), &lastDate)
                pending.append((d, tidy(replace(#"\+?₹\s*[\d,]+\.\d{2}.*$"#, in: g[2], with: "")), dateOK))
                for a in amts(l) { pop(a.0, a.1) }                 // FIFO: oldest merchant gets the next amount
            } else {
                let a = amts(l)
                if a.isEmpty, !pending.isEmpty {                   // wrapped merchant continuation
                    pending[pending.count - 1].merchant = tidy(pending[pending.count - 1].merchant + " " + l)
                } else { for x in a { pop(x.0, x.1) } }
            }
        }
        let rw = reward("Coins", #"into\s+([\d,]+)\s+Scapia Coins"#, text) ?? reward("Coins", #"([\d,]+)\s+Scapia Coins"#, text)
        return (cardAccount(.federal, mask: mask, due: due, limit: limit, product: "Scapia Federal", reward: rw, minDue: minDue, dueDate: dueOn), txns)
    }

    // MARK: - shared builders
    private static func cardAccount(_ issuer: Issuer, mask: String, due: Double?, limit: Double?,
                                    product: String?, reward: (String, Double)? = nil,
                                    availableLimit: Double? = nil,
                                    minDue: Double? = nil, dueDate: Date? = nil) -> SyncedAccount {
        let code = issuer == .generic ? nil : issuer.rawValue
        // Fallback: if the printed total limit is missing, derive it from available limit + outstanding
        // (total = available + spent). Keeps the card's limit populated across label variations.
        let resolvedLimit = limit ?? availableLimit.flatMap { av in due.map { av + $0 } }
        return SyncedAccount(bank: BankCatalog.info(code)?.name ?? "Card", mask: mask, type: "Credit card",
                             balance: due ?? 0, kind: .card, bankCode: code, limit: resolvedLimit, cardName: product,
                             rewardKind: reward?.0, rewardBalance: reward?.1,
                             totalDue: due, minDue: minDue, dueDate: dueDate)
    }

    /// Parse a "Payment Due Date" printed on a card statement. Indian statements use DD/MM/YYYY or
    /// DD-MM-YYYY (and occasionally "DD Mon YYYY"); we parse with an explicit format list under
    /// en_US_POSIX so the numeric day/month order is never reinterpreted by a US locale.
    private static func dueDate(_ labels: [String], _ text: String) -> Date? {
        for label in labels {
            let pat = #"\#(label)[\s:]*[\r\n ]{0,4}(\d{1,2}[/\-. ][A-Za-z0-9]{2,3}[/\-. ]\d{2,4})"#
            if let raw = cap(pat, text),
               let d = parseDate(raw.replacingOccurrences(of: ".", with: "/"),
                                 ["dd/MM/yyyy", "dd-MM-yyyy", "dd MMM yyyy", "d/M/yyyy", "d-M-yyyy", "dd/MM/yy"]) {
                return d
            }
        }
        return nil
    }
    private static func reward(_ kind: String, _ pattern: String, _ text: String) -> (String, Double)? {
        guard let v = cap(pattern, text).flatMap(money) else { return nil }
        return (kind, v)
    }
    private static func mk(_ tag: String, _ date: Date, _ merchant: String, _ v: Double, _ credit: Bool,
                           _ mask: String, _ code: String, category: String? = nil,
                           dateResolved: Bool = true, rawContext: String = "", cardholder: String? = nil,
                           reward: Double? = nil, rewardCurrency: String? = nil,
                           forexCurrency: String? = nil, forexAmount: Double? = nil,
                           isInternational: Bool = false) -> SyncedTxn {
        let name = merchant.isEmpty ? "\(code) card" : merchant
        // Add-on rows share the date/merchant/amount of the primary card, so fold the holder into the
        // externalId to keep them distinct (and dedupe-stable) from any identical primary-card spend.
        let holderKey = cardholder.map { ":\($0.prefix(8))" } ?? ""
        return SyncedTxn(externalId: "cc:\(tag):\(date.timeIntervalSince1970):\(name.prefix(14)):\(v)\(holderKey)",
                         narration: name, amount: credit ? v : -v, date: date,
                         accountMask: mask, merchant: name.capitalized,
                         source: .card, counterparty: name, bankCode: code, category: category,
                         cardholder: cardholder,
                         reward: reward, rewardCurrency: reward != nil ? rewardCurrency : nil,
                         forexCurrency: forexCurrency, forexAmount: forexAmount, isInternational: isInternational,
                         dateResolved: dateResolved, merchantResolved: !merchant.isEmpty,
                         rawContext: rawContext.isEmpty ? name : rawContext)
    }
    /// The loyalty unit an issuer's rewards are denominated in — used to label per-txn rewards.
    private static func rewardUnit(_ issuer: Issuer) -> String {
        switch issuer {
        case .hdfc:    return "Reward Points"
        case .axis:    return "EDGE Miles"
        case .icici:   return "Cashback"        // Amazon Pay cashback (₹)
        case .federal: return "Scapia Coins"
        case .generic: return "Reward"
        }
    }
    /// An international row's original currency + amount, captured from "<CCY> <amount>" sitting just
    /// before the (optional reward and) INR total — e.g. "EUR 150.06 + 560 C 16,889.41".
    private static func forex(_ s: String) -> (currency: String, amount: Double)? {
        guard let g = cap2(#"\b([A-Z]{3})\s+([\d,]+\.\d{2})\s*(?:\+\s*\d+\s*)?C\s*[\d,]+\.\d{2}"#, s),
              g.0 != "IST", g.0 != "GST" else { return nil }   // guard against stray all-caps tokens
        return money(g.1).map { (g.0, $0) }
    }
    /// Resolve a row date or carry the last good one forward (flagged unresolved), instead of
    /// silently stamping today — see DataConflict / the statement-date fix.
    private static func resolveDate(_ parsed: Date?, _ last: inout Date?) -> (date: Date, resolved: Bool) {
        if let d = parsed { last = d; return (d, true) }
        return (last ?? Date(), false)
    }
    /// Maps an issuer's merchant-category text to one of our budget categories (best-effort).
    private static func mapCategory(_ s: String) -> String? {
        let u = s.uppercased()
        func has(_ ks: [String]) -> Bool { ks.contains { u.contains($0) } }
        if has(["HOTEL", "RESTAURANT", "CAFE", "FOOD", "DINING", "BAKER", "BREW"]) { return "Eating out" }
        if has(["GROCER", "SUPERMARKET", "DEPT STORE", "DEPARTMENT"]) { return "Groceries" }
        if has(["CAR RENTAL", "UBER", "TRAVEL", "FUEL", "PETROL", "AIRLINE", "AUTO SERVICE", "TRANSPORT", "RAIL"]) { return "Transport" }
        if has(["MEDICAL", "PHARMAC", "HOSPITAL", "HEALTH", "CLINIC", "FITNESS", "GYM", "WELLNESS"]) { return "Health" }
        if has(["CLOTH", "APPAREL", "RETAIL", "STORE", "SHOP", "FASHION", "ELECTRONIC"]) { return "Shopping" }
        if has(["SUBSCRIPTION", "STREAM", "NETFLIX", "ENTERTAIN"]) { return "Subscriptions" }
        return nil
    }
    private static func pickProduct(_ issuer: Issuer, _ text: String) -> String? {
        let t = text.lowercased()
        switch issuer {
        case .hdfc:
            if t.contains("diners black") { return "HDFC Diners Black" }
            if t.contains("infinia") { return "HDFC Infinia" }
            if t.contains("regalia") { return "HDFC Regalia Gold" }
            if t.contains("millennia") { return "HDFC Millennia" }
            if t.contains("swiggy") { return "HDFC Swiggy" }
        case .axis:
            if t.contains("atlas") { return "Axis Atlas" }
            if t.contains("magnus") { return "Axis Magnus" }
            if t.contains("ace") { return "Axis ACE" }
        case .icici:
            if t.contains("amazon pay") { return "ICICI Amazon Pay" }
            if t.contains("sapphiro") { return "ICICI Sapphiro" }
            if t.contains("coral") { return "ICICI Coral" }
        case .federal: return "Scapia Federal"
        case .generic: break
        }
        return nil   // unknown product — never assume a variant
    }
    private static func creditByKeyword(_ s: String) -> Bool {
        let u = s.uppercased()
        return ["PAYMENT", "AUTOPAY", "THANK YOU", "REVERSAL", "REFUND", "CASHBACK", "RECEIVED"].contains { u.contains($0) }
    }

    // MARK: - multi-line record assembly
    private static func records(_ lines: [String], start: (String) -> Bool, stop: (String) -> Bool) -> [String] {
        var out: [String] = []; var cur: String? = nil
        for l in lines where !l.isEmpty {
            if start(l) { if let c = cur { out.append(c) }; cur = l }
            else if stop(l) { if let c = cur { out.append(c); cur = nil } }
            else if cur != nil { cur! += " " + l }
        }
        if let c = cur { out.append(c) }
        return out
    }

    // MARK: - regex / money helpers
    private static func headerMoney(_ labels: [String], _ text: String, gap: Int) -> Double? {
        for label in labels {
            let p = "\(NSRegularExpression.escapedPattern(for: label))[\\s\\S]{0,\(gap)}?(?:`|₹|Rs\\.?|INR|C)?\\s*([\\d,]+(?:\\.\\d{2})?)"
            if let v = cap(p, text).flatMap(money) { return v }
        }
        return nil
    }
    private static func lastMoney(_ pattern: String, _ s: String, lazyFirst: Bool = false) -> Double? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = s as NSString
        let ms = r.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard let m = (lazyFirst ? ms.first : ms.last), m.numberOfRanges > 1 else { return nil }
        return money(ns.substring(with: m.range(at: 1)))
    }
    private static func cap(_ pattern: String, _ text: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
    /// First match's first two capture groups (case-sensitive — callers need exact casing, e.g. a currency code).
    private static func cap2(_ pattern: String, _ text: String) -> (String, String)? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let m = r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 2 else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }
    private static func matches(_ pattern: String, _ s: String) -> Bool {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        return r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    private static func replace(_ pattern: String, in s: String, with t: String) -> String {
        guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
    private static func re(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p, options: []) }
    private static func match(_ r: NSRegularExpression?, _ s: String) -> [String]? {
        guard let r else { return nil }
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
    private static func money(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }
    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    private static func parseDate(_ s: String, _ formats: [String]) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats { f.dateFormat = fmt; if let d = f.date(from: s) { return d } }
        return nil
    }
}
