import Foundation

/// A small Keychain-backed list of candidate statement passwords the user saves once.
/// The statement scanner tries each against locked PDFs; anything that won't open lands
/// in the pending list for a one-off manual unlock.
enum StatementVault {
    private static let key = "stmt_passwords"

    static func passwords() -> [String] {
        guard let s = Keychain.get(key), let d = s.data(using: .utf8),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return a
    }
    static func add(_ p: String) {
        let t = p.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        var a = passwords(); guard !a.contains(t) else { return }
        a.append(t); save(a)
    }
    static func remove(_ p: String) { save(passwords().filter { $0 != p }) }
    static func clear() { Keychain.set(nil, for: key) }
    private static func save(_ a: [String]) {
        if let d = try? JSONEncoder().encode(a), let s = String(data: d, encoding: .utf8) { Keychain.set(s, for: key) }
    }
}

/// A statement PDF fetched from Gmail that couldn't be opened with any saved password.
struct PendingStatement: Identifiable, Codable, Hashable {
    var id: String { messageId + ":" + attachmentId }
    var messageId: String
    var attachmentId: String
    var filename: String
    var sender: String
    var date: Date
    var cacheFile: String   // file name under Caches holding the encrypted PDF bytes
}
