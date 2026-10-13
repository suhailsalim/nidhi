import Foundation

/// Automatic backups. Always writes a JSON backup to the app's Documents folder
/// (exposed in the Files app via UIFileSharingEnabled and included in the device's
/// iCloud device-backup). When the iCloud Drive ubiquity container is available
/// (iCloud entitlement + signed-in user), it ALSO writes there so device migration
/// is automatic. Falls back gracefully on the free dev team (no iCloud entitlement).
///
/// Two files per location, by design:
///   * `Nidhi-backup.json` — the stable "latest" copy. `latestData()` and older builds
///     read this path, so the name must never change.
///   * `Backups/Nidhi-backup-YYYYMMDD-HHmmss.json` — rotating history, pruned to the
///     newest `keepTimestamped`. This is what survives a bad state overwriting the stable copy.
enum BackupManager {
    static let filename = "Nidhi-backup.json"
    static let folder = "Backups"
    /// How many rotating files to keep per location.
    static let keepTimestamped = 10
    private static let lastKey = "nidhi_last_backup"
    private static let prefix = "Nidhi-backup-"
    private static let preRestoreSuffix = "-prerestore"

    enum Source: String { case local = "Files", iCloud = "iCloud Drive" }

    struct BackupInfo: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let date: Date
        let source: Source
        let byteSize: Int
        /// Written automatically just before a restore replaced the live data.
        let isPreRestore: Bool
        /// The stable `Nidhi-backup.json` rather than a rotating file.
        let isStable: Bool
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var localURL: URL { documentsURL.appendingPathComponent(filename) }

    /// The iCloud Documents dir, or nil when iCloud is unavailable (every caller must no-op then).
    static func iCloudDocs() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let docs = container.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    static func iCloudURL() -> URL? { iCloudDocs()?.appendingPathComponent(filename) }

    static var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil && iCloudURL() != nil
    }

    static var lastBackup: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    // MARK: rotating filenames

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func timestampedName(_ date: Date, preRestore: Bool) -> String {
        "\(prefix)\(stamp.string(from: date))\(preRestore ? preRestoreSuffix : "").json"
    }

    /// Date encoded in a rotating filename, or nil if `name` isn't one of ours.
    /// Pruning and listing both order by THIS, never by file mtime — iCloud sync rewrites mtimes.
    static func parseStamp(_ name: String) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        var core = String(name.dropFirst(prefix.count).dropLast(".json".count))
        if core.hasSuffix(preRestoreSuffix) { core = String(core.dropLast(preRestoreSuffix.count)) }
        return stamp.date(from: core)
    }

    // MARK: write

    /// Writes the backup; returns a human label of where it landed.
    /// `preRestore` snapshots the state about to be replaced — it joins the rotation but never
    /// becomes the stable "latest" copy (restoring must not overwrite the file you restored from).
    @discardableResult
    static func write(_ data: Data, preRestore: Bool = false) -> String {
        let now = Date()
        var locations: [String] = []
        if writeSet(root: documentsURL, data: data, now: now, preRestore: preRestore) {
            locations.append(Source.local.rawValue)
        }
        if let docs = iCloudDocs(), writeSet(root: docs, data: data, now: now, preRestore: preRestore) {
            locations.append(Source.iCloud.rawValue)
        }
        if !locations.isEmpty, !preRestore { UserDefaults.standard.set(now, forKey: lastKey) }
        return locations.isEmpty ? "—" : locations.joined(separator: " + ")
    }

    private static func writeSet(root: URL, data: Data, now: Date, preRestore: Bool) -> Bool {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(folder)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = (try? data.write(to: dir.appendingPathComponent(timestampedName(now, preRestore: preRestore)),
                                  options: .atomic)) != nil
        if !preRestore,
           (try? data.write(to: root.appendingPathComponent(filename), options: .atomic)) != nil { ok = true }
        prune(dir: dir)
        return ok
    }

    /// Keep only the newest `keepTimestamped` rotating files, ordered by the timestamp parsed from
    /// the filename. Only ever touches files matching our own naming scheme.
    private static func prune(dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let dated = files
            .compactMap { u in parseStamp(u.lastPathComponent).map { (url: u, date: $0) } }
            .sorted { $0.date > $1.date }
        for f in dated.dropFirst(keepTimestamped) { try? fm.removeItem(at: f.url) }
    }

    // MARK: read

    /// Reads the most recent backup (prefers iCloud, falls back to local Documents).
    static func latestData() -> Data? {
        if let url = iCloudURL(), let d = data(at: url) { return d }
        return try? Data(contentsOf: localURL)
    }

    /// Per-file read. iCloud files can be listed but not yet materialised, so kick off a download
    /// and tolerate failure for THIS file rather than failing the whole listing.
    static func data(at url: URL) -> Data? {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return try? Data(contentsOf: url)
    }

    /// Every backup we can see, newest first, merging both locations.
    static func list() -> [BackupInfo] {
        var out: [BackupInfo] = []
        func scan(root: URL, source: Source) {
            let fm = FileManager.default
            let stable = root.appendingPathComponent(filename)
            if fm.fileExists(atPath: stable.path) {
                let v = try? stable.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                // The stable file carries no timestamp in its name, so mtime is the only date available.
                out.append(BackupInfo(url: stable, date: v?.contentModificationDate ?? .distantPast,
                                      source: source, byteSize: v?.fileSize ?? 0,
                                      isPreRestore: false, isStable: true))
            }
            let dir = root.appendingPathComponent(folder)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            else { return }
            for u in files {
                guard let d = parseStamp(u.lastPathComponent) else { continue }
                let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                out.append(BackupInfo(url: u, date: d, source: source, byteSize: size,
                                      isPreRestore: u.lastPathComponent.contains(preRestoreSuffix),
                                      isStable: false))
            }
        }
        scan(root: documentsURL, source: .local)
        if let docs = iCloudDocs() { scan(root: docs, source: .iCloud) }
        return out.sorted { $0.date > $1.date }
    }

    static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
            || (iCloudURL().map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }
}
