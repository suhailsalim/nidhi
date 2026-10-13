import Foundation

/// Live foreign-exchange rates → INR via Frankfurter (free, ECB-backed, no key).
/// Falls back to cached / built-in rates offline. Never throws into the UI.
actor FXProvider {
    static let shared = FXProvider()
    private var cache: [String: Double] = [:]
    private var fetchedAt: Date?

    /// Returns currency → INR for the requested currencies (INR always 1).
    func ratesToINR(_ currencies: [String]) async -> [String: Double] {
        var out: [String: Double] = ["INR": 1]
        let needed = Set(currencies).subtracting(["INR"])
        guard !needed.isEmpty else { return out }
        let fresh = fetchedAt.map { Date().timeIntervalSince($0) < 6 * 3600 } ?? false
        for c in needed {
            if fresh, let r = cache[c] { out[c] = r; continue }
            if let r = await fetchOne(c) { cache[c] = r; out[c] = r }
            else if let r = cache[c] { out[c] = r }                       // stale cache
            else if let r = Currencies.fallbackINR[c] { out[c] = r }      // offline default
        }
        fetchedAt = Date()
        return out
    }

    private func fetchOne(_ currency: String) async -> Double? {
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=\(currency)&symbols=INR") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = obj["rates"] as? [String: Any],
               let v = (rates["INR"] as? NSNumber)?.doubleValue { return v }
        } catch {}
        return nil
    }
}
