import Foundation
import PDFKit
import Vision
import UIKit

enum StatementError: LocalizedError {
    case cannotOpen, locked, wrongPassword, noText, noTransactions, unsupportedDocument
    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "Couldn't open that PDF."
        case .locked: return "This PDF is password-protected. Enter its password."
        case .wrongPassword: return "Wrong password — try again."
        case .noText: return "No readable text found (it may be a scanned image)."
        case .noTransactions: return "Couldn't find any transactions in this statement."
        case .unsupportedDocument: return "This looks like a loan foreclosure / pre-payment statement, not an account or card statement — its payable amounts aren't transactions, so it wasn't imported."
        }
    }
}

/// Reads a bank-statement PDF (unlocking it with a password if needed) and parses
/// transactions heuristically. Works for common Indian statement layouts where each
/// row has a date, a narration, an amount, and a Dr/Cr marker or running balance.
enum StatementImporter {

    /// Throws `.locked` if the PDF needs a password and none/incorrect was supplied.
    static func parse(url: URL, password: String?) throws -> ImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { throw StatementError.cannotOpen }
        return try parse(document: doc, password: password)
    }

    /// Parse a PDF held in memory (e.g. a Gmail attachment).
    static func parse(data: Data, password: String?) throws -> ImportResult {
        guard let doc = PDFDocument(data: data) else { throw StatementError.cannotOpen }
        return try parse(document: doc, password: password)
    }

    /// True if the in-memory PDF needs a password.
    static func isLocked(data: Data) -> Bool { PDFDocument(data: data)?.isLocked ?? false }

    /// True if an (unlocked) PDF is a loan foreclosure / pre-payment statement we deliberately
    /// don't import. Lets the Gmail auto-scan mark it processed instead of re-downloading it
    /// every scan. Returns false for locked/unreadable PDFs (their text can't be inspected).
    static func isUnsupportedDocument(data: Data) -> Bool {
        guard let doc = PDFDocument(data: data), !doc.isLocked else { return false }
        var text = ""
        for i in 0..<doc.pageCount where text.count < 4000 { text += doc.page(at: i)?.string ?? "" }
        return StatementParser.isLoanClosureStatement(text)
    }

    private static func parse(document doc: PDFDocument, password: String?) throws -> ImportResult {
        if doc.isLocked {
            guard let password, !password.isEmpty else { throw StatementError.locked }
            guard doc.unlock(withPassword: password) else { throw StatementError.wrongPassword }
        }
        var text = ""
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.string { text += s + "\n" }
        }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Text-layer PDF → coordinate-based row reconstruction (recovers columns/narration).
        if hasText {
            // Loan foreclosure / pre-payment statements share the HDFC look-and-feel but list
            // payable figures, not transactions — reject before any parser fabricates txns.
            if StatementParser.isLoanClosureStatement(text) { throw StatementError.unsupportedDocument }
            // A present-but-unparseable text layer (e.g. obfuscated/mispositioned glyphs) returns nil
            // here so we fall through to OCR instead of giving up with .noTransactions.
            if let r = parseTextLayer(text: text, doc: doc) { return r }
        }
        // Scanned / image-only PDF, or a text layer nothing could parse → OCR with Vision, then parse.
        let ocr = ocrText(from: doc)
        guard !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw hasText ? StatementError.noTransactions : StatementError.noText
        }
        if StatementParser.isLoanClosureStatement(ocr) { throw StatementError.unsupportedDocument }
        if let card = CardStatementParser.parse(text: ocr) {
            return ImportResult(accounts: [card.account], txns: card.txns)
        }
        let txns = StatementParser.parse(ocr)
        let account = StatementParser.account(ocr)
        guard !txns.isEmpty || account != nil else { throw StatementError.noTransactions }
        return ImportResult(accounts: account.map { [$0] } ?? [], txns: txns)
    }

    /// Parse a non-empty text layer (combined → card → single bank). Returns nil when nothing could
    /// be extracted, so the caller can fall back to OCR rather than failing outright.
    private static func parseTextLayer(text: String, doc: PDFDocument) -> ImportResult? {
        let pages = PDFTableReader.words(doc)
        // HDFC combined statement → many accounts + FDs/RDs.
        if StatementParser.isCombinedHDFC(text) {
            let pageTexts = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
            let r = StatementParser.parseCombined(pageTexts: pageTexts, pageWords: pages)
            guard !r.accounts.isEmpty || !r.deposits.isEmpty else { return nil }
            return ImportResult(accounts: r.accounts, txns: r.txns, deposits: r.deposits)
        }
        // Credit-card statement? (extracts limit + total due even if the txn table is sparse.)
        if let card = CardStatementParser.parse(text: text, pages: pages) {
            return ImportResult(accounts: [card.account], txns: card.txns)
        }
        let txns = StatementParser.parse(text: text, pages: pages)
        var account = StatementParser.account(text)
        if account != nil, account!.asOf == nil { account!.asOf = txns.map(\.date).max() }
        guard !txns.isEmpty || account != nil else { return nil }
        return ImportResult(accounts: account.map { [$0] } ?? [], txns: txns)
    }

    /// On-device OCR for scanned statements: rasterise each page and recognise text.
    private static func ocrText(from doc: PDFDocument) -> String {
        var out = ""
        let maxPages = min(doc.pageCount, 25)
        for i in 0..<maxPages {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let cg = image.cgImage else { continue }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-IN", "en-US"]
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            out += lines.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// Whether a PDF at the URL needs a password (used to decide whether to prompt).
    static func isLocked(url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return PDFDocument(url: url)?.isLocked ?? false
    }
}
