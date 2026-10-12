import Foundation

enum BackupSettings {
    private static var d: UserDefaults { .standard }

    static var enabled: Bool {
        get { d.bool(forKey: "backup.enabled") }
        set { d.set(newValue, forKey: "backup.enabled") }
    }
    /// Nur im WLAN hochladen (Standard: an)
    static var wifiOnly: Bool {
        get { d.object(forKey: "backup.wifiOnly") as? Bool ?? true }
        set { d.set(newValue, forKey: "backup.wifiOnly") }
    }
    static var includeVideos: Bool {
        get { d.object(forKey: "backup.videos") as? Bool ?? true }
        set { d.set(newValue, forKey: "backup.videos") }
    }
    /// nil = ganze Mediathek, sonst erst Fotos ab diesem Tag
    static var since: Date? {
        get { d.object(forKey: "backup.since") as? Date }
        set { d.set(newValue, forKey: "backup.since") }
    }
    static var lastRun: Date? {
        get { d.object(forKey: "backup.lastRun") as? Date }
        set { d.set(newValue, forKey: "backup.lastRun") }
    }

    /// Zielordner auf dem Server, z. B. "Privat/iPhone/2026/10"
    static func folder(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "Privat/iPhone/%04d/%02d", c.year ?? 1970, c.month ?? 1)
    }
}

/// Merkt sich, welche Fotos (localIdentifier) schon gesichert sind.
/// Eine Zeile pro Foto, nur angehängt; getrennt je Server und Benutzer.
final class BackupLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var ids: Set<String>
    private var handle: FileHandle?

    init(server: String, user: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = "\(user)@\(server)".map { $0.isLetter || $0.isNumber ? $0 : "_" }
        url = dir.appendingPathComponent("backup-\(String(key)).log")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        ids = Set(text.split(separator: "\n").map(String.init))
    }

    static func current() -> BackupLog? {
        guard let s = Settings.server, let u = Settings.username else { return nil }
        return BackupLog(server: s, user: u)
    }

    var count: Int { lock.withLock { ids.count } }

    func contains(_ id: String) -> Bool {
        lock.withLock { ids.contains(id) }
    }

    func add(_ id: String) {
        lock.withLock {
            guard ids.insert(id).inserted else { return }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data((id + "\n").utf8))
        }
    }

    func reset() {
        lock.withLock {
            try? handle?.close()
            handle = nil
            ids.removeAll()
            try? FileManager.default.removeItem(at: url)
        }
    }
}
