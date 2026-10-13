import Foundation
import PDFKit

/// Extracts positioned words from each PDF page using glyph bounds, so scrambled
/// text layers can be rebuilt into real table rows by (y, x). PDFKit + Foundation
/// only (no UIKit/Vision) so it's testable off-device.
enum PDFTableReader {
    static func words(_ doc: PDFDocument) -> [[PDFWord]] {
        var pages: [[PDFWord]] = []
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { pages.append([]); continue }
            let ns = (page.string ?? "") as NSString
            let count = min(page.numberOfCharacters, ns.length)
            var words: [PDFWord] = []
            var text = ""
            var rect = CGRect.null
            var lastMaxX: CGFloat = 0, lastMidY: CGFloat = 0

            func flush() {
                let t = text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, rect != .null {
                    words.append(PDFWord(text: t, x: Double(rect.midX), y: Double(rect.midY), w: Double(rect.width)))
                }
                text = ""; rect = .null
            }

            for i in 0..<count {
                let ch = ns.substring(with: NSRange(location: i, length: 1))
                let r = page.characterBounds(at: i)
                if ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush(); lastMaxX = r.maxX; lastMidY = r.midY; continue }
                if r.isNull || r.isEmpty { text += ch; continue }
                if !text.isEmpty {
                    let gap = r.minX - lastMaxX
                    let dy = abs(r.midY - lastMidY)
                    if gap > 6 || dy > 4 { flush() }   // big horizontal gap = new column; y change = new line
                }
                text += ch; rect = rect.union(r); lastMaxX = r.maxX; lastMidY = r.midY
            }
            flush()
            pages.append(words)
        }
        return pages
    }
}
