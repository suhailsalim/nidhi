import Foundation

/// A search result for the add-investment autocomplete.
struct InstrumentHit: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var identifier: String     // Yahoo symbol (e.g. RELIANCE.NS) or AMFI scheme code
    var subtitle: String       // exchange / scheme detail
    var price: Double?
}

/// Live prices + instrument search. Mutual funds use AMFI's free NAV feed; stocks use
/// Yahoo Finance's free public endpoints (no key). Never throws into the UI.
actor QuoteProvider {
    static let shared = QuoteProvider()

    private var navCache: [String: Double] = [:]          // scheme code → NAV
    private var mfList: [(code: String, name: String)] = [] // for search
    private var navFetchedAt: Date?

    // MARK: refresh held investments
    func refresh(_ investments: [Investment]) async -> [Investment] {
        var out: [Investment] = []
        let mfs = investments.filter { $0.kind == .mutualFund && !$0.identifier.isEmpty }
        if !mfs.isEmpty {
            await ensureNAV()
            for inv in mfs {
                if let nav = navCache[inv.identifier.trimmingCharacters(in: .whitespaces)], nav > 0 {
                    var x = inv; x.lastPrice = nav; x.lastUpdated = Date(); out.append(x)
                }
            }
        }
        for inv in investments where inv.kind != .mutualFund && !inv.identifier.isEmpty {
            if let price = await stockQuote(inv.identifier), price > 0 {
                var x = inv; x.lastPrice = price; x.lastUpdated = Date(); out.append(x)
            }
        }
        return out
    }

    // MARK: autocomplete search
    func search(_ query: String, kind: InvestmentKind, market: Market? = nil) async -> [InstrumentHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return kind == .mutualFund ? await searchMF(q) : await searchYahoo(q, kind: kind, market: market)
    }

    /// Yahoo search for stocks/ETFs, filtered to the chosen exchange (by symbol suffix or
    /// exchange short-code) and to the right quoteType (EQUITY vs ETF).
    private func searchYahoo(_ q: String, kind: InvestmentKind, market: Market?) async -> [InstrumentHit] {
        guard let url = yahoo("https://query2.finance.yahoo.com/v1/finance/search", ["q": q, "quotesCount": "25", "newsCount": "0"]) else { return [] }
        guard let obj = await getJSON(url) as? [String: Any],
              let quotes = obj["quotes"] as? [[String: Any]] else { return [] }
        // Yahoo marks US ETFs as "ETF" but many Indian ETFs as "EQUITY", so ETF search accepts both.
        let allowed: Set<String> = kind == .etf ? ["ETF", "EQUITY"] : ["EQUITY"]
        return quotes.compactMap { item -> InstrumentHit? in
            guard let sym = item["symbol"] as? String else { return nil }
            let exch = (item["exchange"] as? String) ?? ""
            let type = (item["quoteType"] as? String) ?? ""
            guard allowed.contains(type) else { return nil }
            if let m = market {
                let matches = m.codes.contains(exch)
                    || (!m.suffix.isEmpty && sym.hasSuffix(m.suffix))
                    || (m.suffix.isEmpty && !sym.contains("."))   // US: plain symbols, no suffix
                guard matches else { return nil }
            }
            let name = (item["shortname"] as? String) ?? (item["longname"] as? String) ?? sym
            let disp = (item["exchDisp"] as? String) ?? exch
            return InstrumentHit(name: name, identifier: sym, subtitle: "\(sym) · \(disp)", price: nil)
        }
    }

    private func searchMF(_ q: String) async -> [InstrumentHit] {
        await ensureNAV()
        let terms = q.lowercased().split(separator: " ").map(String.init)
        return mfList.filter { item in
            let n = item.name.lowercased(); return terms.allSatisfy { n.contains($0) }
        }
        .prefix(15)
        .map { InstrumentHit(name: $0.name, identifier: $0.code, subtitle: "AMFI \($0.code)", price: navCache[$0.code]) }
    }

    // MARK: AMFI NAV (free)
    private func ensureNAV() async {
        if let t = navFetchedAt, Date().timeIntervalSince(t) < 6 * 3600, !navCache.isEmpty { return }
        guard let url = URL(string: "https://www.amfiindia.com/spages/NAVAll.txt") else { return }
        do {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (Nidhi)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let text = String(data: data, encoding: .utf8) else { return }
            var map: [String: Double] = [:]; var list: [(String, String)] = []
            for line in text.split(separator: "\n") {     // SchemeCode;ISIN;ISIN;Name;NAV;Date
                let cols = line.split(separator: ";", omittingEmptySubsequences: false)
                guard cols.count >= 5 else { continue }
                let code = cols[0].trimmingCharacters(in: .whitespaces)
                let name = cols[3].trimmingCharacters(in: .whitespaces)
                if let nav = Double(cols[4].trimmingCharacters(in: .whitespaces)), !code.isEmpty {
                    map[code] = nav; if !name.isEmpty { list.append((code, name)) }
                }
            }
            if !map.isEmpty { navCache = map; mfList = list; navFetchedAt = Date() }
        } catch {}
    }

    // MARK: Yahoo stock quote (free, no key)
    private func stockQuote(_ symbol: String) async -> Double? {
        // Identifiers are full Yahoo symbols from search (e.g. RELIANCE.NS, VOO, VUSA.L) — use as-is.
        let sym = symbol.trimmingCharacters(in: .whitespaces)
        guard !sym.isEmpty, let url = yahoo("https://query1.finance.yahoo.com/v8/finance/chart/\(sym)", ["interval": "1d", "range": "1d"]) else { return nil }
        guard let obj = await getJSON(url) as? [String: Any],
              let chart = obj["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any] else { return nil }
        return (meta["regularMarketPrice"] as? NSNumber)?.doubleValue ?? (meta["regularMarketPrice"] as? Double)
    }

    private func yahoo(_ base: String, _ items: [String: String]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = items.map { URLQueryItem(name: $0, value: $1) }
        return c?.url
    }
    private func getJSON(_ url: URL) async -> Any? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do { let (data, _) = try await URLSession.shared.data(for: req); return try? JSONSerialization.jsonObject(with: data) }
        catch { return nil }
    }
}
