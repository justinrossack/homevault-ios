import Foundation
import Observation
import Photos

/// Zustand für die Anzeige.
@MainActor
@Observable
final class BackupStatus {
    static let shared = BackupStatus()

    var running = false
    var paused = BackupSettings.paused
    var total = 0
    var done = 0
    var skipped = 0
    var failed = 0
    /// Gerade in Arbeit (bis zu drei gleichzeitig)
    var current: [String] = []
    var lastError: String?
    var lastRun: Date? = BackupSettings.lastRun
    /// Anzahl gesicherter Fotos laut Protokoll
    var backedUp = BackupLog.current()?.count ?? 0
    /// Noch nicht gesichert (letzte Zählung)
    var pending: Int?
    /// Hochgeladene Bytes und Startzeit des Laufs (für die Geschwindigkeit)
    var bytes: Int64 = 0
    var startedAt: Date?

    private init() {}

    var processed: Int { done + skipped + failed }

    /// Bytes pro Sekunde seit Beginn des Laufs
    var speed: Double? {
        guard let startedAt, bytes > 0 else { return nil }
        let t = Date().timeIntervalSince(startedAt)
        return t > 1 ? Double(bytes) / t : nil
    }
}

/// Sichert neue Fotos und Videos der Mediathek nach Privat/iPhone/<Jahr>/<Monat>.
/// Live Photos gehen als Foto + .MOV mit gleichem Namen hoch, so erkennt
/// homevault sie wieder. Schon vorhandene Dateien werden übersprungen.
actor BackupEngine {
    static let shared = BackupEngine()

    enum Trigger { case foreground, manual, background }

    /// Gleichzeitige Uploads. Mehr bringt im Heimnetz kaum etwas und
    /// belastet Fotos-Mediathek und Server unnötig.
    static let parallel = 3

    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Startet einen Lauf (oder hängt sich an den laufenden) und wartet auf das Ende.
    func run(_ trigger: Trigger, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async {
        if let task {
            await task.value
            return
        }
        let t = Task { await perform(trigger, onProgress: onProgress) }
        task = t
        await t.value
        task = nil
    }

    func cancel() {
        task?.cancel()
    }

    /// Hält die Sicherung an, bis sie fortgesetzt wird (auch keine automatischen Läufe).
    func pause() async {
        BackupSettings.paused = true
        await MainActor.run { BackupStatus.shared.paused = true }
        task?.cancel()
    }

    func resume() async {
        BackupSettings.paused = false
        await MainActor.run { BackupStatus.shared.paused = false }
    }

    /// Zählt, was noch fehlt, ohne hochzuladen.
    func countPending() async {
        guard Self.authorized, let log = BackupLog.current() else { return }
        let assets = Self.fetchAssets()
        var n = 0
        assets.enumerateObjects { a, _, _ in if !log.contains(a.localIdentifier) { n += 1 } }
        let count = n
        await MainActor.run {
            BackupStatus.shared.pending = count
            BackupStatus.shared.backedUp = log.count
        }
    }

    /// Änderungen an der Anzeige laufen auf dem Main Actor.
    private static func ui(_ update: @escaping @MainActor @Sendable (BackupStatus) -> Void) async {
        await MainActor.run { update(BackupStatus.shared) }
    }

    static var authorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func fetchAssets() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        // neueste zuerst: frische Fotos sind am schnellsten gesichert
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        var preds = [BackupSettings.includeVideos
            ? NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let since = BackupSettings.since {
            preds.append(NSPredicate(format: "creationDate >= %@", since as NSDate))
        }
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        return PHAsset.fetchAssets(with: opts)
    }

    // MARK: Ablauf

    private enum Outcome {
        case uploaded(Int64)
        case skipped
        case failed(String)
        /// ganzen Lauf beenden (Netz weg, Speicherlimit)
        case stop(String)
        case cancelled
    }

    private func perform(_ trigger: Trigger, onProgress: (@Sendable (Int, Int) -> Void)?) async {
        guard !BackupSettings.paused else { return }
        guard trigger == .manual || BackupSettings.enabled else { return }
        guard Self.authorized else {
            await Self.ui { $0.lastError = "Kein Zugriff auf die Fotos. Bitte in den Einstellungen erlauben." }
            return
        }
        guard let api = Settings.client(wifiOnly: BackupSettings.wifiOnly), let log = BackupLog.current() else {
            await Self.ui { $0.lastError = "Nicht angemeldet" }
            return
        }

        // Fotos zuerst (viele, klein), dann Videos; jeweils neueste zuerst
        var photos: [PHAsset] = []
        var videos: [PHAsset] = []
        Self.fetchAssets().enumerateObjects { a, _, _ in
            guard !log.contains(a.localIdentifier) else { return }
            if a.mediaType == .video { videos.append(a) } else { photos.append(a) }
        }
        let pending = photos + videos
        let total = pending.count
        let started = Date()
        await Self.ui { s in
            s.running = true
            s.total = total
            s.done = 0
            s.skipped = 0
            s.failed = 0
            s.bytes = 0
            s.startedAt = started
            s.current = []
            s.lastError = nil
            s.pending = total
        }
        onProgress?(0, total)

        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.removeItem(at: tmpRoot)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let folders = RemoteFolders(api: api)
        var stopError: String?
        var processed = 0

        await withTaskGroup(of: (String, Outcome).self) { group in
            var queue = pending.makeIterator()
            func addNext() {
                guard let asset = queue.next() else { return }
                group.addTask {
                    (asset.localIdentifier, await Self.process(asset, api: api, folders: folders, tmpRoot: tmpRoot))
                }
            }
            for _ in 0..<Self.parallel { addNext() }

            while let (id, outcome) = await group.next() {
                processed += 1
                switch outcome {
                case .uploaded:
                    log.add(id)
                    let count = log.count
                    await Self.ui { s in
                        s.done += 1
                        s.backedUp = count
                        s.pending = max((s.pending ?? 1) - 1, 0)
                    }
                case .skipped:
                    log.add(id)
                    let count = log.count
                    await Self.ui { s in
                        s.skipped += 1
                        s.backedUp = count
                        s.pending = max((s.pending ?? 1) - 1, 0)
                    }
                case .failed(let msg):
                    await Self.ui { s in
                        s.failed += 1
                        s.lastError = msg
                    }
                case .stop(let msg):
                    stopError = stopError ?? msg
                case .cancelled:
                    break
                }
                onProgress?(processed, total)
                if stopError != nil || Task.isCancelled {
                    group.cancelAll()
                } else {
                    addNext()
                }
            }
        }

        try? FileManager.default.removeItem(at: tmpRoot)
        let now = Date()
        BackupSettings.lastRun = now
        let finalError = stopError
        await Self.ui { s in
            s.running = false
            s.current = []
            s.lastRun = now
            if let finalError { s.lastError = finalError }
        }
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return BackupSettings.wifiOnly ? "Kein WLAN – Sicherung wartet" : "Keine Verbindung"
        case .cannotConnectToHost, .cannotFindHost, .timedOut:
            return "Server nicht erreichbar (bist du im Heimnetz?)"
        default:
            return e.localizedDescription
        }
    }

    /// Ein Foto/Video sichern und das Ergebnis einordnen.
    private static func process(_ asset: PHAsset, api: APIClient, folders: RemoteFolders, tmpRoot: URL) async -> Outcome {
        if Task.isCancelled { return .cancelled }
        do {
            if let bytes = try await backup(asset, api: api, folders: folders, tmpRoot: tmpRoot) {
                return .uploaded(bytes)
            }
            return .skipped
        } catch is CancellationError {
            return .cancelled
        } catch let e as URLError where e.code == .cancelled {
            return .cancelled
        } catch let e as URLError {
            return .stop(describe(e))
        } catch let e as APIError where e.status == 400 && (e.errorDescription ?? "").contains("Speicherlimit") {
            return .stop(e.localizedDescription)
        } catch let e as APIError where e.status == 401 {
            return .stop("Anmeldung abgelaufen. Bitte unter „Server“ ab- und wieder anmelden.")
        } catch let e as APIError where e.status == 503 {
            return .stop("Server ist gerade in Wartung")
        } catch {
            if Task.isCancelled { return .cancelled }
            // nur dieses Foto (z. B. iCloud-Original nicht ladbar): weiter mit dem nächsten
            let when = asset.creationDate.map { Format.monthYear.string(from: $0) } ?? "Foto"
            return .failed("\(when): \(error.localizedDescription)")
        }
    }

    /// Sichert ein Foto/Video. nil = war schon auf dem Server, sonst hochgeladene Bytes.
    private static func backup(_ asset: PHAsset, api: APIClient, folders: RemoteFolders, tmpRoot: URL) async throws -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        let main: PHAssetResource?
        var paired: PHAssetResource?
        if asset.mediaType == .video {
            main = resources.first { $0.type == .video } ?? resources.first { $0.type == .fullSizeVideo }
        } else {
            // Original, nicht die bearbeitete Fassung
            main = resources.first { $0.type == .photo } ?? resources.first { $0.type == .fullSizePhoto }
            paired = resources.first { $0.type == .pairedVideo } ?? resources.first { $0.type == .fullSizePairedVideo }
        }
        guard let main else { throw APIError.server(415, "Foto ohne Originaldatei") }

        let folder = BackupSettings.folder(for: asset.creationDate ?? .now)
        var name = clean(main.originalFilename, fallback: asset.mediaType == .video ? "VID.MOV" : "IMG.JPG")

        let remote = try await folders.listing(folder)
        let size = fileSize(main)
        if let existing = remote[name.lowercased()] {
            if size == nil || existing == size { return nil }
            // anderes Foto mit gleichem Namen (z. B. IMG_0001 nach 10.000 Fotos)
            name = suffixed(name, asset.localIdentifier)
        }

        let shown = name
        await ui { $0.current.append(shown) }
        defer { Task { await ui { s in if let i = s.current.firstIndex(of: shown) { s.current.remove(at: i) } } } }

        var files: [(name: String, resource: PHAssetResource)] = [(name, main)]
        if let paired {
            // gleicher Name wie das Foto, damit homevault das Live Photo erkennt
            let ext = (paired.originalFilename as NSString).pathExtension
            files.append(((name as NSString).deletingPathExtension + "." + (ext.isEmpty ? "MOV" : ext), paired))
        }

        // Multipart-Body direkt aus der Mediathek schreiben (eine Kopie statt zwei)
        let boundary = "hv-\(UUID().uuidString)"
        let body = tmpRoot.appendingPathComponent(UUID().uuidString + ".body")
        defer { try? FileManager.default.removeItem(at: body) }
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let handle = try FileHandle(forWritingTo: body)
        var bytes: Int64 = 0
        do {
            for file in files {
                try handle.write(contentsOf: Multipart.head(name: file.name, boundary: boundary))
                bytes += try await append(file.resource, to: handle)
                try handle.write(contentsOf: Data("\r\n".utf8))
            }
            try handle.write(contentsOf: Multipart.tail(boundary: boundary))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try Task.checkCancellation()

        _ = try await api.upload(multipartFile: body, boundary: boundary, folder: folder) { sent in
            Task { await ui { $0.bytes += sent } }
        }
        await folders.record(folder, name: name, size: size)
        return bytes
    }

    /// Schreibt eine Datei aus der Mediathek (ggf. aus iCloud) an das Ende von `handle`.
    private static func append(_ resource: PHAssetResource, to handle: FileHandle) async throws -> Int64 {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default()
        let request = DataRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
                request.id = manager.requestData(for: resource, options: opts, dataReceivedHandler: { data in
                    guard request.error == nil else { return }
                    do {
                        try handle.write(contentsOf: data)
                        request.written += Int64(data.count)
                    } catch {
                        request.error = error
                    }
                }, completionHandler: { error in
                    if let error = error ?? request.error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: request.written)
                    }
                })
            }
        } onCancel: {
            if let id = request.id { manager.cancelDataRequest(id) }
        }
    }

    private final class DataRequest: @unchecked Sendable {
        var id: PHAssetResourceDataRequestID?
        var written: Int64 = 0
        var error: Error?
    }

    /// Dateigröße ohne die Datei zu laden (nicht offiziell, aber seit Jahren stabil).
    static func fileSize(_ r: PHAssetResource) -> Int64? {
        guard r.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (r.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    static func clean(_ name: String, fallback: String) -> String {
        var n = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? fallback : n
    }

    /// "IMG_0001.HEIC" -> "IMG_0001_3F2A9C.HEIC"
    static func suffixed(_ name: String, _ id: String) -> String {
        let tag = String(id.filter { $0.isHexDigit }.prefix(6))
        let ns = name as NSString
        let ext = ns.pathExtension
        return ns.deletingPathExtension + "_" + tag + (ext.isEmpty ? "" : "." + ext)
    }
}

/// Inhalt der Zielordner (Name -> Größe), einmal pro Lauf geladen.
actor RemoteFolders {
    private let api: APIClient
    private var cache: [String: [String: Int64]] = [:]
    /// laufende Abfragen, damit parallele Uploads einen Ordner nur einmal laden
    private var loading: [String: Task<[String: Int64], Error>] = [:]

    init(api: APIClient) { self.api = api }

    func listing(_ folder: String) async throws -> [String: Int64] {
        if let c = cache[folder] { return c }
        if let t = loading[folder] { return try await t.value }
        let api = api
        let t = Task { () throws -> [String: Int64] in
            var result: [String: Int64] = [:]
            do {
                let list: ListResponse = try await api.get("api/list", ["path": folder])
                for e in list.entries where !e.isDir { result[e.name.lowercased()] = e.size }
            } catch APIError.server(404, _) {
                try await Self.create(folder, api: api)
            }
            return result
        }
        loading[folder] = t
        defer { loading[folder] = nil }
        let result = try await t.value
        cache[folder] = result
        return result
    }

    func record(_ folder: String, name: String, size: Int64?) {
        cache[folder, default: [:]][name.lowercased()] = size ?? 0
    }

    /// Legt "Privat/iPhone/2026/10" Stück für Stück an.
    private static func create(_ folder: String, api: APIClient) async throws {
        let parts = folder.split(separator: "/").map(String.init)
        for i in 2...parts.count {
            let path = parts[0..<i].joined(separator: "/")
            do {
                try await api.send("POST", "api/folder", json: ["path": path])
            } catch APIError.server(409, _) {
                // gibt es schon
            }
        }
    }
}
