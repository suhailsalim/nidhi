import Foundation
import PDFKit

/// Best-effort parser for Indian salary slips (payslips). Reads the common earning/deduction labels
/// from the PDF text layer. Anything it can't find stays 0 for the user to fill in by hand.
enum PayslipParser {

    /// Parse a payslip PDF (optionally password-protected) into a `Payslip`.
    static func parse(data: Data, password: String? = nil) -> Payslip? {
        guard let doc = PDFDocument(data: data) else { return nil }
        if doc.isLocked, let pw = password { _ = doc.unlock(withPassword: pw) }
        guard !doc.isLocked else { return nil }
        var text = ""
        for i in 0..<doc.pageCount { text += (doc.page(at: i)?.string ?? "") + "\n" }
        return parse(text: text)
    }

    static func parse(text: String) -> Payslip? {
        guard !text.isEmpty else { return nil }
        var p = Payslip()
        p.employer = cap(#"(?:Company|Employer)\s*(?:Name)?\s*:?\s*([A-Za-z0-9 .&'()\-]{2,50})"#, text)?
            .trimmingCharacters(in: .whitespaces) ?? company(text) ?? ""
        p.period = payPeriod(text) ?? Date()
        p.basic = amount([#"Basic\s*(?:Salary|Pay)?"#, #"Basic"#], text)
        p.hra = amount([#"H\.?R\.?A\.?"#, #"House Rent Allowance"#], text)
        p.pf = amount([#"(?:Employee )?(?:EPF|Provident Fund|PF)\b"#], text)
        p.profTax = amount([#"(?:Professional Tax|Prof\.? Tax|PTAX|P\.Tax)"#], text)
        p.tds = amount([#"(?:Income Tax|TDS|Tax Deducted)"#], text)
        p.grossEarnings = amount([#"Gross\s*(?:Earnings|Salary|Pay)"#, #"Total Earnings"#], text)
        p.netPay = amount([#"Net\s*(?:Pay|Salary|Amount|Pay(?:able)?)"#, #"Take Home"#], text)
        // Special/other allowances = gross − (basic + hra) when gross is known, else direct read.
        let special = amount([#"Special Allowance"#, #"Other Allowances?"#], text)
        if p.grossEarnings > 0 {
            p.allowances = max(special, max(0, p.grossEarnings - p.basic - p.hra))
        } else {
            p.allowances = special
            p.grossEarnings = p.basic + p.hra + special
        }
        // Require at least one meaningful signal to accept the parse.
        guard p.grossEarnings > 0 || p.netPay > 0 || p.basic > 0 else { return nil }
        return p
    }

    // MARK: helpers
    private static func amount(_ labels: [String], _ text: String) -> Double {
        for l in labels {
            // label … number on the same line (allow Rs/₹ and thousands separators)
            if let m = cap("\(l)[^\\d\\n-]{0,30}(?:Rs\\.?|₹|INR)?\\s*([\\d,]+(?:\\.\\d{1,2})?)", text),
               let v = money(m), v > 0 { return v }
        }
        return 0
    }
    private static func company(_ text: String) -> String? {
        // First non-empty line that looks like a company (has "Ltd"/"Pvt"/"Technologies" etc.)
        for line in text.components(separatedBy: .newlines).prefix(6) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.range(of: #"(?i)\b(Ltd|Limited|Pvt|Private|LLP|Technologies|Solutions|Services|Inc)\b"#, options: .regularExpression) != nil {
                return l
            }
        }
        return nil
    }
    private static func payPeriod(_ text: String) -> Date? {
        // "Pay slip for the month of May 2026", "Salary Slip - May-2026", "Month: 05/2026"
        if let m = cap(#"(?:for the month of|Pay Period|Month)\s*:?\s*([A-Za-z]{3,9})[ ,\-]+(\d{4})"#, text),
           let y = cap(#"(?:for the month of|Pay Period|Month)\s*:?\s*[A-Za-z]{3,9}[ ,\-]+(\d{4})"#, text) {
            return monthYear(m, y)
        }
        if let mm = cap(#"\b(\d{2})[/\-](\d{4})\b"#, text), let yy = cap(#"\b\d{2}[/\-](\d{4})\b"#, text),
           let mi = Int(mm), (1...12).contains(mi), let yi = Int(yy) {
            return Calendar.current.date(from: DateComponents(year: yi, month: mi, day: 1))
        }
        return nil
    }
    private static func monthYear(_ monthName: String, _ year: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM yyyy"
        if let d = f.date(from: "\(monthName) \(year)") { return d }
        f.dateFormat = "MMM yyyy"
        return f.date(from: "\(monthName.prefix(3)) \(year)")
    }
    private static func money(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    private static func cap(_ pattern: String, _ s: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
              m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
