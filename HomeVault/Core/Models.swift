import Foundation

/// Datei oder Ordner, wie ihn Ordneransicht, Zeitleiste und Alben liefern.
struct Entry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let kind: String
    let size: Int64
    let modified: Int64
    /// Aufnahmedatum (nur Zeitleiste/Alben/Favoriten)
    let taken: Int64?
    /// Medien-ID aus dem Index (nur Zeitleiste/Alben/Favoriten)
    let mediaId: Int64?
    let preview: Bool?
    /// Pfad des Videos bei Live Photos
    let live: String?
    var favorite: Bool?
    let doc: String?

    var id: String { path }
    var isDir: Bool { kind == "dir" }
    var isImage: Bool { kind == "image" }
    var isVideo: Bool { kind == "video" }
    var isLive: Bool { live != nil }
    var isFavorite: Bool { favorite ?? false }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(taken ?? modified)) }
    /// Server kann ein Vorschaubild erzeugen
    var hasThumb: Bool { isImage || isVideo || doc == "pdf" || doc == "office" }

    enum CodingKeys: String, CodingKey {
        case name, path, kind, size, modified, taken, preview, live, favorite, doc
        case mediaId = "id"
    }
}

struct Me: Decodable {
    struct User: Decodable {
        let name: String
        let admin: Bool
    }
    let authenticated: Bool
    let user: User?
    let setup_needed: Bool
    let server_name: String
}

struct ListResponse: Decodable {
    let path: String
    let entries: [Entry]
}

struct TimelineResponse: Decodable {
    let entries: [Entry]
    let next: String?
    let indexing: Bool
}

struct EntriesResponse: Decodable {
    let entries: [Entry]
}

struct Album: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let count: Int
    let cover: Entry?
}

struct AlbumsResponse: Decodable {
    let albums: [Album]
}

struct AlbumResponse: Decodable {
    let id: Int64
    let name: String
    let entries: [Entry]
}

struct AreaUsage: Decodable {
    let bytes: Int64
    let files: Int64
    let photo_bytes: Int64
    let video_bytes: Int64
}

struct StorageOverview: Decodable {
    struct Disk: Decodable {
        let total: Int64
        let free: Int64
    }
    struct Mine: Decodable {
        let used: Int64
        let quota: Int64?
    }
    struct UserUsage: Decodable, Identifiable {
        let name: String
        let quota: Int64?
        let usage: AreaUsage
        var id: String { name }
    }
    let disk: Disk
    let warning: Bool
    let me: Mine
    let shared: AreaUsage
    let last_scan: Int64?
    let users: [UserUsage]?
    let trash: Int64?
}

struct DiskSummary: Decodable {
    /// none, ok, warning, degraded, unreachable
    let state: String
}

struct DiskStatus: Decodable {
    struct Pool: Decodable {
        struct Device: Decodable, Identifiable {
            let devid: Int64?
            let size: Int64?
            let path: String?
            let missing: Bool
            let errors: Int64?
            var id: String { "\(devid ?? 0)-\(path ?? "")" }
        }
        struct Scrub: Decodable {
            let running: Bool
            let status: String?
        }
        let profile: String?
        let mounted: Bool
        let degraded: Bool
        let devices: [Device]
        let size: Int64?
        let used: Int64?
        let free: Int64?
        let last_scrub: Int64?
        let scrub: Scrub?
    }
    struct Disk: Decodable, Identifiable {
        struct Smart: Decodable {
            let passed: Bool?
            let temperature: Int64?
            let power_on_hours: Int64?
        }
        let path: String
        let size: Int64?
        let model: String?
        let in_pool: Bool
        let smart: Smart?
        var id: String { path }
    }
    let available: Bool
    let reachable: Bool?
    let pool: Pool?
    let disks: [Disk]?
}

struct BackupsResponse: Decodable {
    struct Target: Decodable, Identifiable {
        struct Run: Decodable {
            let started_at: Int64
            let finished_at: Int64?
            let status: String
            let files: Int64
            let bytes: Int64
            let message: String?
        }
        let id: Int64
        let name: String
        let location: String?
        let enabled: Bool
        let schedule: String?
        let last_run: Run?
        let last_success: Int64?
        let next_run: Int64?
    }
    struct Progress: Decodable {
        let target_id: Int64
        let part: String
        let bytes: Int64
        let total_bytes: Int64
        let speed: Double
    }
    let targets: [Target]
    let running: Progress?
}
