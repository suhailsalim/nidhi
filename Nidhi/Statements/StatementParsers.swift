import Foundation

/// A positioned word from a PDF page (page coords; y increases upward).
struct PDFWord: Hashable { let text: String; let x: Double; let y: Double; let w: Double }

/// Pure-Foundation statement text → transactions. Bank-specific parsers for Federal
/// and HDFC, with a generic heuristic fallback. (Kept free of PDFKit/UIKit/Vision so
/// it is independently testable.)
enum StatementParser {

    enum Bank { case federal, hdfc, generic }

    static func detectBank(_ text: String) -> Bank {
        // Use issuer-specific markers — counterparty UPI handles contain other banks' codes.
        if text.contains("HDFC BANK LIMITED") || text.contains("RTGS/NEFT IFSC: HDFC") || text.contains("HDFC Bank Ltd") { return .hdfc }
        if text.contains("Federal Bank") || text.contains("IFSC : FDRL") { return .federal }
        return .generic
    }

    /// True if the PDF is a loan **foreclosure / pre-closure / pre-payment / settlement**
    /// statement rather than an account or card statement. These list payable figures
    /// (outstanding principal, termination interest, prepayment charges) — never running
    /// transactions — so they must be rejected before any parser turns those amounts into
    /// bogus txns. Each marker below is loan-closure-specific and never appears in a
    /// savings / current / credit-card statement, so a single hit is conclusive.
    static func isLoanClosureStatement(_ text: String) -> Bool {
        // A real foreclosure/pre-payment statement is *about* closing a loan. A credit-card or
        // combined bank statement can legitimately carry "pre-closure"/"principal outstanding" inside
        // a Merchant EMI / loan-summary block (HDFC prints one for any card with an active EMI) — those
        // are genuine statements, so never reject them here, or they get stuck "needs password".
        if CardStatementParser.isCardStatement(text) || isCombinedHDFC(text) { return false }
        let t = text.lowercased()
        let markers = [
            "foreclosure", "fore closure", "fore-closure",
            "pre-closure", "preclosure", "pre closure",
            "per day interest on termination", "interest on termination",
            "interest till date of prepayment", "prepayment charges",
            "outstanding principal", "principal outstanding",
            "pending installments", "pending instalments",
        ]
        return markers.contains { t.contains($0) }
    }

    static func parse(_ text: String) -> [SyncedTxn] {
        let result: [SyncedTxn]
        switch detectBank(text) {
        case .federal: result = parseFederal(text)
        case .hdfc:    result = parseHDFC(text)
        case .generic: result = []
        }
        return result.isEmpty ? parseGeneric(text) : result
    }

    /// Extracts account identity (bank, last-4, IFSC, branch, type, tier) from a statement header.
    /// Balance is left 0 — statements are historical, so the live balance isn't overwritten.
    static func account(_ text: String) -> SyncedAccount? {
        let bank = detectBank(text)
        let ifsc = cap(#"IFSC\s*:?\s*([A-Z]{4}0[A-Z0-9]{6})"#, text)
        var mask = "", branch: String? = nil, type = "Savings", tier: String? = nil
        switch bank {
        case .federal:
            if let acc = cap(#"Account Number\s*:\s*(\d+)"#, text) { mask = String(acc.suffix(4)) }
            branch = cap(#"Branch\s*(?:Name)?\s*:\s*([A-Za-z0-9 ./&'-]{2,40})"#, text)?.trimmingCharacters(in: .whitespaces)
            // Capture at most two words so "Savings Account Account Status…" doesn't bleed into the type.
            type = cap(#"Type of Account\s*:\s*([A-Za-z]+(?:\s[A-Za-z]+)?)"#, text)?.trimmingCharacters(in: .whitespaces) ?? type
            tier = cap(#"Scheme\s*:?\s*([A-Za-z]+(?:\s[A-Za-z]+)?)"#, text)?.trimmingCharacters(in: .whitespaces)
        case .hdfc:
            if let acc = cap(#"Account No\s*:?\s*(\d{3,})"#, text) { mask = String(acc.suffix(4)) }
            branch = cap(#"(?:Account Branch|Branch)\s*:?\s*([A-Za-z0-9 .&'-]{2,40})"#, text)?.trimmingCharacters(in: .whitespaces)
            if let t = cap(#"(?:Account Type|A/C Type)\s*:?\s*([A-Za-z ]{3,40})"#, text)?.trimmingCharacters(in: .whitespaces) {
                type = t
                for k in ["IMPERIA", "PREFERRED", "PREMIUM", "CLASSIC", "MAX", "PRIME"] where t.uppercased().contains(k) { tier = k.capitalized }
            }
        case .generic:
            return nil
        }
        guard !mask.isEmpty else { return nil }
        var balance = cap(#"(?:Available|Closing) Balance\s*:?\s*([\d,]+\.\d{2})"#, text).flatMap(money) ?? 0
        // Federal statements carry no "Closing Balance:" label — the closing figure is the last running
        // balance in the transaction table (each amount row ends "<amount> <balance> Cr|Dr").
        if balance == 0, bank == .federal {
            balance = scan(#"([\d,]+\.\d{2})\s+(?:Cr|Dr)\b"#, text).last.flatMap { money($0[1]) } ?? 0
        }
        let info = BankCatalog.match(ifsc: ifsc) ?? (bank == .federal ? BankCatalog.info("FED") : BankCatalog.info("HDFC"))
        return SyncedAccount(bank: info?.name ?? "Bank", mask: mask, type: type, balance: balance,
                             kind: .bank, bankCode: info?.code, ifsc: ifsc, branch: branch, tier: tier,
                             asOf: statementAsOf(text))
    }

    /// The date a statement's closing balance is stated *as of* — the statement period's end date.
    /// Used to reconstruct the live balance by adding transactions dated after it. Ordered most-
    /// specific first; the loose "to" form is anchored so it can't match a date inside a narration.
    static func statementAsOf(_ text: String) -> Date? {
        let ymd = ["yyyy-MM-dd", "yyyy/MM/dd"]
        let dmy = ["dd/MM/yyyy", "dd-MMM-yyyy", "dd-MM-yyyy"]
        let patterns: [(String, [String])] = [
            // Federal: "Statement of Account for the period 2025-11-06 to 2026-05-05"
            (#"for the period\s+\d{4}[-/]\d{2}[-/]\d{2}\s+to\s+(\d{4}[-/]\d{2}[-/]\d{2})"#, ymd),
            (#"Date of Issue\s*:?\s*(\d{2}[-/][A-Za-z0-9]{2,3}[-/]\d{4})"#, dmy),
            (#"(?:Statement Period|Period)[^\d]{0,20}\d{2}[-/][A-Za-z0-9]{2,3}[-/]\d{2,4}\s*(?:to|-|–|—)\s*(\d{2}[-/][A-Za-z0-9]{2,3}[-/]\d{2,4})"#, dmy + ["dd/MM/yy"]),
            (#"(?:as on|As On|Generated on)\s*:?\s*(\d{2}[-/][A-Za-z0-9]{2,3}[-/]\d{4})"#, dmy),
            // Loose "To : <date>" — must not be preceded by a digit/dash (avoids "27-12-2025 To 25-12-2025").
            (#"(?<![\d-])\b[Tt]o\s*:\s*(\d{2}[-/][A-Za-z0-9]{2,3}[-/]\d{4})"#, dmy),
        ]
        for (p, fmts) in patterns {
            if let s = cap(p, text), let d = parseDate(s, fmts) { return d }
        }
        return nil
    }

    // MARK: - HDFC Combined Account SmartStatement (multiple accounts + FDs/RDs)
    static func isCombinedHDFC(_ text: String) -> Bool {
        if text.contains("Account Relationship Summary") || text.contains("Combined Account SmartStatement") { return true }
        guard text.localizedCaseInsensitiveContains("hdfc") else { return false }
        return Set(scan(#"\b(5\d{13})\b"#, text).map { $0[1] }).count >= 2
    }

    private enum PageKind { case bank, fd, rd, other }
    private static func pageKind(_ t: String) -> PageKind {
        if t.contains("Savings Account Details") || t.contains("Current Account Details") { return .bank }
        if t.contains("RECURRING DEPOSIT") || t.contains("RD ACCOUNT SUMMARY") { return .rd }
        if t.contains("Term Deposit") || (t.contains("Principal") && t.contains("Maturity")) { return .fd }
        return .other
    }
    /// HDFC account numbers are 14 digits starting with 5; on two-column statement pages the
    /// number sits in a values block away from its label, so just take the first such number.
    private static func acctNumber(_ t: String) -> String? { cap(#"\b(5\d{13})\b"#, t) }

    /// Parses an HDFC combined statement: every savings/current account (with its own
    /// transactions + closing balance) plus the fixed- and recurring-deposit tables.
    static func parseCombined(pageTexts: [String], pageWords: [[PDFWord]]) -> (accounts: [SyncedAccount], txns: [SyncedTxn], deposits: [Deposit]) {
        var accounts: [SyncedAccount] = [], txns: [SyncedTxn] = [], deposits: [Deposit] = []
        let info = BankCatalog.info("HDFC")
        var i = 0
        while i < pageTexts.count {
            guard pageKind(pageTexts[i]) == .bank, let acc = acctNumber(pageTexts[i]) else { i += 1; continue }
            // group consecutive pages of the same bank account
            var sec: [[PDFWord]] = [], secText = "", j = i
            while j < pageTexts.count, pageKind(pageTexts[j]) == .bank, acctNumber(pageTexts[j]) == acc {
                sec.append(pageWords[j]); secText += pageTexts[j] + "\n"; j += 1
            }
            let mask = String(acc.suffix(4))
            let type = secText.contains("Current Account Details") ? "Current" : "Savings"
            let opening = cap(#"Opening Balance\s*:?\s*([\d,]+\.\d{2})"#, secText).flatMap(money)
            let ifsc = cap(#"IFSC\s*:?\s*([A-Z]{4}0[A-Z0-9]{6})"#, secText)
            let branch = cap(#"Account Branch\s*:?\s*([A-Za-z0-9 .&'-]{2,40})"#, secText)?.trimmingCharacters(in: .whitespaces)
            // exact month-end balance from the per-account SUMMARY block
            let summaryClosing = cap(#"SUMMARY[\s\S]*?Closing Balance\s+([\d,]+\.\d{2})"#, secText).flatMap(money)
            // Try coordinate reconstruction, but only trust it if it reconciles to the closing
            // balance (this combined layout often obfuscates glyph positions — then drop txns
            // rather than import wrong amounts; Gmail alerts still cover those transactions).
            var acctTxns = reconstructHDFCRows(sec, mask: mask, opening: opening)
            let reconClosing = (opening ?? 0) + acctTxns.map(\.amount).reduce(0, +)
            if acctTxns.isEmpty || (summaryClosing.map { abs($0 - reconClosing) > 1 } ?? false) { acctTxns = [] }
            let balance = summaryClosing ?? (acctTxns.isEmpty ? (opening ?? 0) : reconClosing)
            // As-of date for balance reconstruction: the statement period end, else this account's
            // latest reconstructed transaction. Without it, June Gmail alerts can't offset a May closing.
            let asOf = statementAsOf(secText) ?? acctTxns.map(\.date).max()
            accounts.append(SyncedAccount(bank: info?.name ?? "HDFC Bank", mask: mask, type: type,
                                          balance: balance, kind: .bank, bankCode: "HDFC", ifsc: ifsc, branch: branch,
                                          asOf: asOf))
            txns += acctTxns
            i = j
        }
        let fdText = pageTexts.enumerated().filter { pageKind($0.element) == .fd }.map(\.element).joined(separator: "\n")
        deposits += parseHDFCFDs(fdText)
        let rdText = pageTexts.enumerated().filter { pageKind($0.element) == .rd }.map(\.element).joined(separator: "\n")
        deposits += parseHDFCRDs(rdText)
        return (accounts, txns, deposits)
    }

    /// Term-deposit table rows: `<acctNo> INR <principal> <maturityAmt> <start> <maturity> <rate>`.
    private static func parseHDFCFDs(_ text: String) -> [Deposit] {
        scan(#"(\d{11,})\s+INR\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(\d{2}/\d{2}/\d{4})\s+(\d{2}/\d{2}/\d{4})\s+(\d+\.\d{1,2})"#, text)
            .compactMap { g in
                guard let principal = money(g[2]),
                      let start = parseDate(g[4], ["dd/MM/yyyy"]), let mat = parseDate(g[5], ["dd/MM/yyyy"]) else { return nil }
                return Deposit(bank: "HDFC", tag: "FD", symbol: "lock.fill", rate: Double(g[6]) ?? 0,
                               current: principal, startDate: start, maturityDate: mat, identifier: g[1])
            }
    }
    /// Recurring-deposit summary: `<acctNo> <installment> <start> <months> <roi> <maturityDate> <maturityAmt>`,
    /// plus an "Account bal … Monthly" line for the amount deposited so far.
    private static func parseHDFCRDs(_ text: String) -> [Deposit] {
        scan(#"(\d{11,})\s+([\d,]+\.\d{2})\s+(\d{2}/\d{2}/\d{4})\s+(\d+)\s+(\d+\.\d{1,2})\s+(\d{2}/\d{2}/\d{4})\s+([\d,]+\.\d{2})"#, text)
            .compactMap { g in
                guard let start = parseDate(g[3], ["dd/MM/yyyy"]), let mat = parseDate(g[6], ["dd/MM/yyyy"]) else { return nil }
                let bal = cap(#"([\d,]+\.\d{2})[^\n]*\bMonthly\b"#, text).flatMap(money) ?? (money(g[2]) ?? 0)
                return Deposit(bank: "HDFC", tag: "RD", symbol: "calendar", rate: Double(g[5]) ?? 0,
                               current: bal, startDate: start, maturityDate: mat, identifier: g[1])
            }
    }

    /// All capture-group matches of a pattern (group 0 = whole match).
    private static func scan(_ pattern: String, _ text: String) -> [[String]] {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        return r.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    /// Preferred entry point when positioned words are available (rebuilds real rows).
    static func parse(text: String, pages: [[PDFWord]]) -> [SyncedTxn] {
        if detectBank(text) == .hdfc {
            let columned = parseColumns(pages, text: text)
            if !columned.isEmpty { return columned }
        }
        return parse(text)
    }

    // MARK: - Column reconstruction (coordinate-based; recovers narration)
    /// Rebuilds rows from positioned words. Uses the Narration column for merchant text
    /// and the rightmost money on each row as the running balance (amounts = balance
    /// delta, exact). Wrapped narration on continuation rows is appended.
    static func parseColumns(_ pages: [[PDFWord]], text: String) -> [SyncedTxn] {
        let opening = cap(#"Opening Balance[\s\S]{0,80}?([\d,]+\.\d{2})"#, text).flatMap(money)
        var mask = ""
        if let acc = cap(#"Account No\s*:?\s*(\d{3,})"#, text) { mask = String(acc.suffix(4)) }
        return reconstructHDFCRows(pages, mask: mask, opening: opening)
    }

    /// Coordinate row reconstruction with an explicit mask + opening balance — shared by the
    /// single-account path and the combined-statement parser (whose headers differ).
    static func reconstructHDFCRows(_ pages: [[PDFWord]], mask: String, opening: Double?) -> [SyncedTxn] {
        // locate the narration column band from the header row
        var nLeft: Double?, nRight: Double?
        for page in pages {
            for row in clusterRows(page) {
                guard let nWord = row.first(where: { $0.text == "Narration" }),
                      row.contains(where: { $0.text.contains("Balance") || $0.text == "Closing" }) else { continue }
                nLeft = nWord.x
                nRight = row.filter { $0.x > nWord.x + 5 }.map(\.x).min()
                break
            }
            if nLeft != nil { break }
        }
        guard let bandL = nLeft, let bandR = nRight else { return [] }
        let lo = bandL - 14, hi = bandR - 8

        struct Row { var date: Date?; var narration: String; var balance: Double }
        var rows: [Row] = []
        var carryDate: Date?
        for page in pages {
            for r in clusterRows(page) {
                let joined = r.map(\.text).joined(separator: " ")
                if hdfcNoise(joined) { continue }
                let balanceWord = r.filter { isMoney($0.text) }.max(by: { $0.x < $1.x })
                let narr = r.filter { $0.x >= lo && $0.x <= hi && !isMoney($0.text) && !isDate($0.text) }
                    .sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
                if let bw = balanceWord, let bal = money(bw.text) {
                    let dw = r.first { isDate($0.text) && $0.x < bandL }
                    let d = dw.flatMap { parseDate($0.text, ["dd/MM/yy", "dd/MM/yyyy"]) } ?? carryDate
                    carryDate = d ?? carryDate
                    rows.append(Row(date: d, narration: narr, balance: bal))
                } else if !narr.isEmpty, !rows.isEmpty {
                    rows[rows.count - 1].narration += " " + narr
                }
            }
        }
        guard !rows.isEmpty else { return [] }
        // If narration couldn't be recovered (e.g. an obfuscated PDF whose glyph
        // positions are themselves scrambled), bail so the caller falls back to the
        // balance-chain parser rather than emit empty labels.
        let withNarr = rows.filter { !$0.narration.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if Double(withNarr) / Double(rows.count) < 0.5 { return [] }

        var out: [SyncedTxn] = []
        var prev = opening ?? rows[0].balance
        var have = opening != nil
        var lastDate: Date? = nil
        for row in rows {
            let amount = have ? row.balance - prev : 0
            prev = row.balance; have = true
            if abs(amount) < 0.005 { continue }
            let narration = row.narration.trimmingCharacters(in: .whitespaces)
            let (date, dateOK) = bestDate(row.date, carrying: &lastDate)
            out.append(SyncedTxn(externalId: "hdfc:\(row.balance):\(amount)",
                                 narration: narration.isEmpty ? "HDFC transaction" : narration,
                                 amount: amount, date: date, accountMask: mask,
                                 merchant: hdfcNarrationMerchant(narration, credit: amount > 0),
                                 dateResolved: dateOK, merchantResolved: !narration.isEmpty, rawContext: narration))
        }
        return out
    }

    private static func clusterRows(_ words: [PDFWord]) -> [[PDFWord]] {
        let sorted = words.sorted { $0.y > $1.y }
        var rows: [[PDFWord]] = []
        for w in sorted {
            if let i = rows.indices.last, let first = rows[i].first, abs(first.y - w.y) <= 3 { rows[i].append(w) }
            else { rows.append([w]) }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }

    private static func isMoney(_ s: String) -> Bool { s.range(of: #"^[\d,]+\.\d{2}$"#, options: .regularExpression) != nil }
    private static func isDate(_ s: String) -> Bool { s.range(of: #"^\d{2}/\d{2}/\d{2,4}$"#, options: .regularExpression) != nil }

    private static func hdfcNarrationMerchant(_ n: String, credit: Bool) -> String {
        let up = n.uppercased()
        if up.hasPrefix("UPI-") || up.hasPrefix("UPI ") {
            // UPI-<NAME>-<vpa>-<...> → take the name segment
            let segs = n.dropFirst(4).split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if let name = segs.first, name.count > 1 { return name.capitalized }
        }
        if up.hasPrefix("NEFT") || up.hasPrefix("IMPS") || up.hasPrefix("RTGS")
            || up.hasPrefix("ACH") || up.hasPrefix("NACH") || up.hasPrefix("ECS") {
            // …-<PAYEE>-… : pick the longest mostly-alphabetic segment (ACH D-<LENDER>-<ref>
            // rows — loan EMI mandates — name the lender the same way NEFT names the payee)
            let segs = n.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if let best = segs.filter({ $0.rangeOfCharacter(from: .letters) != nil && $0.count > 3 }).max(by: { $0.count < $1.count }) {
                return best.capitalized
            }
        }
        if let vpa = n.split(whereSeparator: { " -/".contains($0) }).first(where: { $0.contains("@") }) { return String(vpa) }
        let cleaned = n.split(separator: " ").prefix(4).joined(separator: " ")
        return cleaned.isEmpty ? "HDFC \(credit ? "credit" : "debit")" : cleaned.capitalized
    }

    // MARK: - Federal Bank (split-column layout)
    // Federal's PDF emits a block of "date  value-date  particulars" rows, then a
    // separate block of "TranType TranID amount balance Cr/Dr" rows (same order).
    // Some rows are combined on one line. We pair them in order and sign each amount
    // by the running balance delta (balances are absolute & sequential).
    static func parseFederal(_ text: String) -> [SyncedTxn] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var mask = ""
        if let acc = cap(#"Account Number\s*:\s*(\d+)"#, text) { mask = String(acc.suffix(4)) }
        var prevBal = cap(#"Opening Balance\s+([\d,]+\.\d{2})"#, text).flatMap(money) ?? 0

        let combinedRe = re(#"^(\d{2}-[A-Z]{3}-\d{4})\s+\d{2}-[A-Z]{3}-\d{4}\s+(.*?)\s+[A-Z]{2,5}\s+([A-Z]?\d+)\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(?:Cr|Dr)$"#)
        let dateRe     = re(#"^(\d{2}-[A-Z]{3}-\d{4})\s+\d{2}-[A-Z]{3}-\d{4}\s+(.*)$"#)
        let amountRe   = re(#"^[A-Z]{2,5}\s+([A-Z]?\d+)\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(?:Cr|Dr)$"#)

        struct Amt { var date: String?; var particulars: String?; var amount: Double; var balance: Double; var tranId: String }
        struct DE { var date: String; var particulars: String }
        var amounts: [Amt] = []
        var dateQueue: [DE] = []
        var curIdx: Int? = nil

        for l in lines where !l.isEmpty {
            if let g = match(combinedRe, l) {
                amounts.append(Amt(date: g[1], particulars: g[2], amount: money(g[4]) ?? 0, balance: money(g[5]) ?? 0, tranId: g[3]))
                curIdx = nil
            } else if let g = match(dateRe, l) {
                dateQueue.append(DE(date: g[1], particulars: g[2])); curIdx = dateQueue.count - 1
            } else if let g = match(amountRe, l) {
                amounts.append(Amt(date: nil, particulars: nil, amount: money(g[2]) ?? 0, balance: money(g[3]) ?? 0, tranId: g[1]))
                curIdx = nil
            } else if let i = curIdx, !federalNoise(l) {
                dateQueue[i].particulars += " " + l
            }
        }

        var out: [SyncedTxn] = []
        var qi = 0
        var lastDate: Date? = nil
        for a in amounts {
            let dateStr: String, particulars: String
            if let d = a.date { dateStr = d; particulars = a.particulars ?? "" }
            else if qi < dateQueue.count { dateStr = dateQueue[qi].date; particulars = dateQueue[qi].particulars; qi += 1 }
            else { continue }
            let signed = a.balance + 0.001 >= prevBal ? a.amount : -a.amount
            prevBal = a.balance
            let narration = particulars.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let m = federalMerchant(narration)
            let (date, dateOK) = bestDate(parseDate(dateStr, ["dd-MMM-yyyy"]), carrying: &lastDate)
            out.append(SyncedTxn(externalId: "fed:\(dateStr):\(a.tranId):\(a.balance)",
                                 narration: narration, amount: signed,
                                 date: date,
                                 accountMask: mask, merchant: m,
                                 source: .bank, counterparty: m, bankCode: "FED",
                                 dateResolved: dateOK, rawContext: narration))
        }
        return out.isEmpty ? parseFederalChain(text, mask: mask) : out
    }

    /// Newer Federal eStatement layout (dd/MM/yyyy, column-batched): the
    /// "TranType TranID amount balance Cr/Dr" rows are the reliable anchor — sign by the running
    /// balance delta; attach posting dates (every other date token) and best-effort merchants.
    private static func parseFederalChain(_ text: String, mask: String) -> [SyncedTxn] {
        var region = text
        if let r1 = text.range(of: "Balance Dr") ?? text.range(of: "Opening Balance"),
           let r2 = text.range(of: "GRAND TOTAL") ?? text.range(of: "END OF STATEMENT") {
            region = String(text[r1.lowerBound..<r2.lowerBound])
        }
        let rows = scan(#"\b([A-Z]{2,6})\s+([A-Z]\d{3,})\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s+(?i:cr|dr)\b"#, region)
        guard !rows.isEmpty else { return [] }
        var prev = cap(#"Opening Balance[\s\S]{0,20}?([\d,]+\.\d{2})"#, text).flatMap(money) ?? (money(rows[0][4]) ?? 0)
        let dates = scan(#"\b(\d{2}/\d{2}/\d{4})\b"#, region).map { $0[1] }
        let posting = stride(from: 0, to: dates.count, by: 2).map { dates[$0] }   // skip value dates
        var vpas = scan(#"([A-Za-z0-9._-]+@[A-Za-z]+)"#, region).map { $0[1] }
        let hasCharge = region.range(of: #"CHRG|ALERT|\bSMS\b"#, options: .regularExpression) != nil
        var out: [SyncedTxn] = []
        var lastDate: Date? = nil
        for (i, g) in rows.enumerated() {
            let amt = money(g[3]) ?? 0, bal = money(g[4]) ?? 0
            let signed = bal + 0.001 >= prev ? amt : -amt
            prev = bal
            let (date, dateOK) = bestDate(parseDate(i < posting.count ? posting[i] : (posting.last ?? ""), ["dd/MM/yyyy"]), carrying: &lastDate)
            let m: String = !vpas.isEmpty ? vpas.removeFirst()
                : (signed < 0 && hasCharge ? "Bank charge" : "Federal \(signed > 0 ? "credit" : "debit")")
            out.append(SyncedTxn(externalId: "fed:\(g[2]):\(bal)", narration: m, amount: signed,
                                 date: date, accountMask: mask, merchant: m,
                                 source: .bank, counterparty: m, bankCode: "FED",
                                 dateResolved: dateOK, rawContext: m))
        }
        return out
    }

    private static func federalNoise(_ l: String) -> Bool {
        ["Federal Bank", "Statement of Account", "Page ", "Account Number", "Customer ID",
         "Branch", "IFSC", "MICR", "SWIFT", "Currency", "Nomination", "Mode of Operation",
         "Type of Account", "Scheme", "Regd. Mobile", "Email", "Communication Address",
         "Date of Issue", "Effective Available", "Opening Balance", "Closing Balance",
         "Withdrawals Deposits", "Value Date", "Tran ID", "/CR"].contains { l.contains($0) }
    }

    /// Best-effort readable counterparty from a Federal particulars string.
    static func federalMerchant(_ p: String) -> String {
        let parts = p.split(whereSeparator: { "/ ".contains($0) }).map(String.init)
        if let vpa = parts.first(where: { $0.contains("@") }) { return vpa }       // UPI counterparty
        // trailing alphabetic name (e.g. "QUANT MUTUAL FU", "HDFC BANK")
        let words = p.replacingOccurrences(of: "/", with: " ").split(separator: " ").map(String.init)
        let tail = words.suffix(4).filter { $0.rangeOfCharacter(from: .letters) != nil && !$0.contains("@") }
        if !tail.isEmpty, tail.joined().count > 3 { return tail.joined(separator: " ").capitalized }
        return (parts.first ?? p).capitalized
    }

    // MARK: - HDFC (column-scrambled layout → balance-chain reconstruction)
    // HDFC's text layer splits each row across column blocks (dates, then narrations,
    // then value-date/amount/balance), so rows can't be read directly. But the closing
    // balance is the last money token on each data line and forms a clean running chain.
    // We seed from "Opening Balance" and reconstruct each transaction's signed amount as
    // the balance delta — exact. Dates carry from each line's value date (month-accurate).
    // Merchant names can't be reliably paired from this scrambled text → left generic.
    static func parseHDFC(_ text: String) -> [SyncedTxn] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var mask = ""
        if let acc = cap(#"Account No\s*:?\s*(\d{3,})"#, text) { mask = String(acc.suffix(4)) }
        let opening = cap(#"Opening Balance[\s\S]{0,80}?([\d,]+\.\d{2})"#, text).flatMap(money)

        // transaction region: after the first column header, before the summary block
        var start = 0, end = lines.count
        for (i, l) in lines.enumerated() where l.contains("Narration") && l.contains("Closing Balance") { start = i + 1; break }
        for i in stride(from: lines.count - 1, through: start, by: -1) where lines[i].contains("Opening Balance") { end = i; break }

        let dateRe = re(#"\b(\d{2}/\d{2}/\d{2,4})\b"#)
        let fromDate = parseDate(cap(#"From\s*:\s*(\d{2}/\d{2}/\d{4})"#, text) ?? "", ["dd/MM/yyyy"])
        let toDate = parseDate(cap(#"To\s*:\s*(\d{2}/\d{2}/\d{4})"#, text) ?? "", ["dd/MM/yyyy"])
        var prev = opening ?? 0
        var haveOpening = opening != nil
        var currentDate = fromDate
        var out: [SyncedTxn] = []
        var seen = Set<String>()

        func inRange(_ d: Date) -> Bool {
            (fromDate.map { d >= $0.addingTimeInterval(-86400) } ?? true) &&
            (toDate.map { d <= $0.addingTimeInterval(86400) } ?? true)
        }

        for i in start..<end {
            let l = lines[i]
            if hdfcNoise(l) { continue }
            let monies = allMoney(l)
            guard let bal = monies.last?.0 else { continue }
            if let dtok = match(dateRe, l), let d = parseDate(dtok[1], ["dd/MM/yy", "dd/MM/yyyy"]), inRange(d) { currentDate = d }

            let amount: Double
            if haveOpening { amount = bal - prev }
            else if monies.count >= 2 { amount = -(monies[monies.count - 2].0) }   // first row, no opening: assume debit
            else { amount = 0 }
            prev = bal; haveOpening = true
            if abs(amount) < 0.005 { continue }                                     // skip duplicate-balance lines

            let merchant = hdfcMerchant(l) ?? "HDFC \(amount > 0 ? "credit" : "debit")"
            let ext = "hdfc:\(bal):\(amount)"
            guard !seen.contains(ext) else { continue }; seen.insert(ext)
            out.append(SyncedTxn(externalId: ext, narration: merchant, amount: amount,
                                 date: currentDate ?? Date(), accountMask: mask, merchant: merchant,
                                 source: .bank, counterparty: merchant, bankCode: "HDFC",
                                 dateResolved: currentDate != nil, rawContext: l))
        }
        return out
    }

    private static func hdfcNoise(_ l: String) -> Bool {
        ["Page No", "HDFC BANK", "Closing balance includes", "Statement of account", "Narration",
         "Withdrawal Amt", "Registered Office", "GSTN", "considered correct", "HDFC Bank GSTIN",
         "OD Limit", "Account No", "Cust ID", "IFSC", "MICR", "Branch", "Currency", "Email",
         "Phone no", "Nomination", "A/C Open", "Account Type", "Account Status", "JOINT HOLDERS",
         "Address", "City :", "State :"].contains { l.contains($0) }
    }

    private static func hdfcMerchant(_ l: String) -> String? {
        let words = l.replacingOccurrences(of: "/", with: " ").split(separator: " ").map(String.init)
        if let vpa = words.first(where: { $0.contains("@") }) { return vpa }
        if let up = l.range(of: #"UPI-[A-Za-z ]{3,}"#, options: .regularExpression) {
            return String(l[up]).replacingOccurrences(of: "UPI-", with: "").trimmingCharacters(in: .whitespaces).capitalized
        }
        return nil
    }

    // MARK: - Generic fallback (date + Dr/Cr or amount+balance heuristics)
    static func parseGeneric(_ text: String) -> [SyncedTxn] {
        let dateRegex = re(#"(\d{1,2}[-/ ](?:\d{1,2}|[A-Za-z]{3})[-/ ]\d{2,4})"#)
        var out: [SyncedTxn] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 8, let dm = firstRange(dateRegex, line) else { continue }
            let dateStr = (line as NSString).substring(with: dm)
            guard let date = parseDate(dateStr, ["dd/MM/yyyy","dd-MM-yyyy","dd/MM/yy","dd-MM-yy","dd MMM yyyy","dd-MMM-yyyy","yyyy-MM-dd"]) else { continue }
            let after = NSRange(location: dm.location + dm.length, length: (line as NSString).length - (dm.location + dm.length))
            let monies = allMoney((line as NSString).substring(with: after))
            guard let amtStr = (monies.count >= 2 ? monies[monies.count-2].0 : monies.first?.0) else { continue }
            let upper = line.uppercased()
            let isCredit = upper.range(of: #"\bCR\b"#, options: .regularExpression) != nil
                || ["SALARY","CREDIT","REFUND","INTEREST","CASHBACK","REVERSAL"].contains { upper.contains($0) }
            let narration = "Transaction"
            let ext = "pdf:\(dateStr):\(amtStr)"
            guard !seen.contains(ext) else { continue }; seen.insert(ext)
            out.append(SyncedTxn(externalId: ext, narration: narration, amount: isCredit ? amtStr : -amtStr,
                                 date: date, accountMask: ""))
        }
        return out
    }

    // MARK: - helpers
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static func match(_ rx: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
    private static func cap(_ p: String, _ s: String) -> String? { match(re(p), s).flatMap { $0.count > 1 ? $0[1] : nil } }
    private static func firstRange(_ rx: NSRegularExpression, _ s: String) -> NSRange? {
        let ns = s as NSString
        let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        return m?.range
    }
    /// All money tokens as (value, location) in a string, in order.
    private static func allMoney(_ s: String) -> [(Double, Int)] {
        let rx = re(#"\d{1,3}(?:,\d{2,3})*(?:\.\d{1,2})|\d+\.\d{2}"#)
        let ns = s as NSString
        var out: [(Double, Int)] = []
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if let v = money(ns.substring(with: m.range)) { out.append((v, m.range.location)) }
        }
        return out
    }
    private static func money(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    /// Resolve a row date: use `candidate` if present (and remember it), else carry the last good
    /// date forward as a best-guess placeholder. Returns `resolved == false` whenever the row had no
    /// date of its own, so the caller can flag it for review instead of silently stamping today.
    static func bestDate(_ candidate: Date?, carrying last: inout Date?) -> (date: Date, resolved: Bool) {
        if let d = candidate { last = d; return (d, true) }
        return (last ?? Date(), false)
    }
    private static func parseDate(_ s: String, _ formats: [String]) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = s.replacingOccurrences(of: "  ", with: " ")
        // normalise UPPERCASE month (e.g. NOV → Nov) for MMM parsing
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
            if fmt.contains("MMM") {
                let titled = cleaned.split(separator: "-").map { $0.count == 3 ? $0.prefix(1).uppercased() + $0.dropFirst().lowercased() : String($0) }.joined(separator: "-")
                if let d = f.date(from: titled) { return d }
            }
        }
        return nil
    }
}
