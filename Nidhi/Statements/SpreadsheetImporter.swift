import Foundation
import Compression

/// Imports bank statements exported as CSV/TSV, .xlsx, or HTML-table ".xls".
/// Maps columns by header names → exact narration + amount + sign. Pure Foundation
/// (+Compression for xlsx), so it's testable off-device.
enum SpreadsheetImporter {

    static func parse(url: URL) throws -> [SyncedTxn] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let rows: [[String]]
        if ext == "xlsx" { rows = try xlsxRows(data) }
        else if looksLikeHTML(data) { rows = htmlRows(data) }   // many bank ".xls" are HTML
        else { rows = csvRows(String(decoding: data, as: UTF8.self)) }

        let txns = rowsToTransactions(rows)
        guard !txns.isEmpty else { throw StatementError.noTransactions }
        return txns
    }

    // MARK: - column mapping (shared by all formats)
    static func rowsToTransactions(_ rows: [[String]]) -> [SyncedTxn] {
        guard let hi = headerIndex(rows) else { return [] }
        let header = rows[hi].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func find(_ keys: [String]) -> Int? { header.firstIndex { h in keys.contains { h.contains($0) } } }
        let cDate = find(["transaction date", "txn date", "date"])
        let cNarr = find(["narration", "description", "particulars", "remarks", "details", "transaction"])
        let cWdr  = find(["withdrawal", "debit"])
        let cDep  = find(["deposit", "credit"])
        let cAmt  = find(["amount"])
        let cBal  = find(["balance"])
        let cType = find(["dr / cr", "dr/cr", "cr/dr", "type"])
        guard cDate != nil, (cNarr != nil || cAmt != nil || cWdr != nil || cBal != nil) else { return [] }

        var out: [SyncedTxn] = []
        var seen = Set<String>()
        var prevBal: Double?
        for r in rows[(hi + 1)...] {
            func cell(_ i: Int?) -> String { (i.flatMap { $0 < r.count ? r[$0] : nil }) ?? "" }
            let dateStr = cell(cDate)
            guard let date = parseAnyDate(dateStr) else { continue }
            let narr = cell(cNarr).trimmingCharacters(in: .whitespaces)

            var amount: Double?
            if cWdr != nil || cDep != nil {
                let w = num(cell(cWdr)) ?? 0, d = num(cell(cDep)) ?? 0
                if w != 0 || d != 0 { amount = d - w }
            }
            if amount == nil, let a = cAmt {
                let raw = cell(a); let mag = abs(num(raw) ?? 0)
                if mag != 0 {
                    let typ = cell(cType).uppercased(), up = raw.uppercased()
                    if typ.contains("DR") || up.contains("DR") || raw.contains("-") { amount = -mag }
                    else if typ.contains("CR") || up.contains("CR") { amount = mag }
                    else { amount = -mag }   // assume debit if unspecified
                }
            }
            let bal = num(cell(cBal))
            if (amount == nil || amount == 0), let b = bal, let pb = prevBal { amount = b - pb }
            if let b = bal { prevBal = b }

            guard let amt = amount, abs(amt) > 0.004 else { continue }
            let ext = "csv:\(dateStr):\(narr.prefix(18)):\(amt)"
            guard !seen.contains(ext) else { continue }; seen.insert(ext)
            out.append(SyncedTxn(externalId: ext, narration: narr.isEmpty ? "Transaction" : narr,
                                 amount: amt, date: date, accountMask: "", merchant: cleanMerchant(narr)))
        }
        return out
    }

    private static func headerIndex(_ rows: [[String]]) -> Int? {
        for (i, r) in rows.enumerated() {
            let cells = r.map { $0.lowercased() }
            let hasDate = cells.contains { $0.contains("date") }
            let hasCol = cells.contains { c in ["narration", "description", "particulars", "withdrawal", "deposit", "amount", "balance", "debit", "credit"].contains { c.contains($0) } }
            if hasDate && hasCol { return i }
        }
        return nil
    }

    private static func cleanMerchant(_ n: String) -> String {
        if n.isEmpty { return "Transaction" }
        if let vpa = n.split(whereSeparator: { " -/".contains($0) }).first(where: { $0.contains("@") }) { return String(vpa) }
        let up = n.uppercased()
        for p in ["UPI-", "UPI/", "NEFT-", "NEFT/", "IMPS-", "IMPS/", "POS ", "ACH-"] where up.hasPrefix(p) {
            let rest = n.dropFirst(p.count)
            if let seg = rest.split(separator: "-").first ?? rest.split(separator: "/").first, seg.count > 1 { return seg.trimmingCharacters(in: .whitespaces).capitalized }
        }
        return n.split(separator: " ").prefix(5).joined(separator: " ")
    }

    private static func num(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var neg = false
        if t.hasPrefix("(") && t.hasSuffix(")") { neg = true; t = String(t.dropFirst().dropLast()) }
        for sym in ["₹", "$", "INR", "Rs.", "Rs", ",", " "] { t = t.replacingOccurrences(of: sym, with: "") }
        let up = t.uppercased()
        if up.hasSuffix("CR") || up.hasSuffix("DR") { t = String(t.dropLast(2)) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard let v = Double(t) else { return nil }
        return neg ? -v : v
    }

    private static let dateFormats = ["dd/MM/yyyy","dd-MM-yyyy","dd/MM/yy","dd-MM-yy","dd MMM yyyy",
                                      "dd-MMM-yyyy","dd-MMM-yy","yyyy-MM-dd","MM/dd/yyyy","dd.MM.yyyy"]
    private static func parseAnyDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, t.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
            if fmt.contains("MMM") {
                let titled = t.split(separator: "-").map { $0.count == 3 ? $0.prefix(1).uppercased() + $0.dropFirst().lowercased() : String($0) }.joined(separator: "-")
                if let d = f.date(from: titled) { return d }
            }
        }
        return nil
    }

    // MARK: - CSV / TSV
    static func csvRows(_ text: String) -> [[String]] {
        let sample = text.prefix(4000)
        let delim: Character = sample.filter { $0 == "\t" }.count > sample.filter { $0 == "," }.count ? "\t"
            : (sample.filter { $0 == ";" }.count > sample.filter { $0 == "," }.count ? ";" : ",")
        var rows: [[String]] = []
        var field = "", row: [String] = [], inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" { if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false } }
                else { field.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == delim { row.append(field); field = "" }
                else if c == "\n" || c == "\r" {
                    if c == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }
                    row.append(field); rows.append(row); field = ""; row = []
                } else { field.append(c) }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    // MARK: - HTML table (".xls" that's really HTML)
    private static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<html") || head.contains("<table") || head.contains("<!doctype html")
    }
    static func htmlRows(_ data: Data) -> [[String]] {
        let html = String(decoding: data, as: UTF8.self)
        var rows: [[String]] = []
        let trRe = try! NSRegularExpression(pattern: #"<tr[^>]*>(.*?)</tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let tdRe = try! NSRegularExpression(pattern: #"<t[dh][^>]*>(.*?)</t[dh]>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        for tr in trRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: tr.range(at: 1))
            let innerNS = inner as NSString
            var cells: [String] = []
            for td in tdRe.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)) {
                cells.append(stripTags(innerNS.substring(with: td.range(at: 1))))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows
    }
    private static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (e, r) in ["&amp;": "&", "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            t = t.replacingOccurrences(of: e, with: r)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - XLSX (zip → shared strings + first sheet)
    static func xlsxRows(_ data: Data) throws -> [[String]] {
        let files = MiniZip.entries(data)
        let shared = files["xl/sharedStrings.xml"].map { SharedStringsParser.parse($0) } ?? []
        let sheetName = files.keys.first { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") } ?? "xl/worksheets/sheet1.xml"
        guard let sheet = files[sheetName] else { throw StatementError.noText }
        return SheetParser.parse(sheet, shared: shared)
    }
}

// MARK: - Minimal ZIP reader (central directory + raw DEFLATE via Compression)
enum MiniZip {
    static func entries(_ data: Data) -> [String: Data] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o+1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < b.count ? Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 : 0 }
        // find End Of Central Directory (sig 50 4B 05 06)
        var eocd = -1
        var i = b.count - 22
        while i >= 0 {
            if b[i] == 0x50, b[i+1] == 0x4B, b[i+2] == 0x05, b[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [:] }
        var p = u32(eocd + 16)                      // central dir offset
        let count = u16(eocd + 10)
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= b.count, b[p] == 0x50, b[p+1] == 0x4B, b[p+2] == 0x01, b[p+3] == 0x02 else { break }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let localOff = u32(p + 42)
            let name = String(decoding: b[(p+46)..<(p+46+nameLen)], as: UTF8.self)
            // local header → data start
            if localOff + 30 <= b.count, b[localOff] == 0x50, b[localOff+1] == 0x4B {
                let lNameLen = u16(localOff + 26), lExtraLen = u16(localOff + 28)
                let dataStart = localOff + 30 + lNameLen + lExtraLen
                if dataStart + compSize <= b.count {
                    let comp = Array(b[dataStart..<dataStart + compSize])
                    if method == 0 { out[name] = Data(comp) }
                    else if method == 8, let inflated = inflate(comp, uncompSize) { out[name] = inflated }
                }
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    private static func inflate(_ src: [UInt8], _ dstSize: Int) -> Data? {
        guard dstSize > 0 else { return Data() }
        let cap = dstSize
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                compression_decode_buffer(dp.baseAddress!, cap, sp.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? Data(dst[0..<n]) : nil
    }
}

// MARK: - tiny XML parsers for xlsx
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inT = false
    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser(); let xp = XMLParser(data: data); xp.delegate = p; xp.parse(); return p.strings
    }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
        if e == "si" { current = "" }; if e == "t" { inT = true }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inT { current += s } }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        if e == "t" { inT = false }; if e == "si" { strings.append(current) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private var rows: [[String]] = []
    private var row: [String] = []
    private var shared: [String] = []
    private var cellType = ""; private var cellRef = ""; private var value = ""; private var inV = false; private var inIs = false
    static func parse(_ data: Data, shared: [String]) -> [[String]] {
        let p = SheetParser(); p.shared = shared; let xp = XMLParser(data: data); xp.delegate = p; xp.parse(); return p.rows
    }
    private func colIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref where ch.isLetter { n = n * 26 + (Int(ch.uppercased().unicodeScalars.first!.value) - 64) }
        return max(0, n - 1)
    }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
        switch e {
        case "row": row = []
        case "c": cellType = a["t"] ?? ""; cellRef = a["r"] ?? ""; value = ""
        case "v": inV = true
        case "is": inIs = true
        default: break
        }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inV || inIs { value += s } }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        switch e {
        case "v": inV = false
        case "is": inIs = false
        case "c":
            let text: String = (cellType == "s" ? (Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? "") : value)
            let idx = colIndex(cellRef)
            while row.count <= idx { row.append("") }
            row[idx] = text
        case "row": rows.append(row)
        default: break
        }
    }
}
