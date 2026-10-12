import Foundation
import Observation
import Photos

/// Zustand für die Anzeige.
@MainActor
@Observable
final class BackupStatus {
    static let shared = BackupStatus()

    var running = false
    var total = 0
    var done = 0
    var skipped = 0
    var failed = 0
    var current: String?
    var lastError: String?
    var lastRun: Date? = BackupSettings.lastRun
    /// Anzahl gesicherter Fotos laut Protokoll
    var backedUp = BackupLog.current()?.count ?? 0
    /// Noch nicht gesichert (letzte Zählung)
    var pending: Int?

    private init() {}

    var remaining: Int { max(total - done - skipped - failed, 0) }
}

/// Sichert neue Fotos und Videos der Mediathek nach Privat/iPhone/<Jahr>/<Monat>.
/// Live Photos gehen als Foto + .MOV mit gleichem Namen hoch, so erkennt
/// homevault sie wieder. Schon vorhandene Dateien werden übersprungen.
actor BackupEngine {
    static let shared = BackupEngine()

    enum Trigger { case foreground, manual, background }

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
    private func ui(_ update: @escaping @MainActor @Sendable (BackupStatus) -> Void) async {
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

    private func perform(_ trigger: Trigger, onProgress: (@Sendable (Int, Int) -> Void)?) async {
        guard trigger == .manual || BackupSettings.enabled else { return }
        guard Self.authorized else {
            await ui { status in status.lastError = "Kein Zugriff auf die Fotos. Bitte in den Einstellungen erlauben." }
            return
        }
        guard let api = Settings.client(wifiOnly: BackupSettings.wifiOnly), let log = BackupLog.current() else {
            await ui { status in status.lastError = "Nicht angemeldet" }
            return
        }

        let assets = Self.fetchAssets()
        var pending: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in if !log.contains(a.localIdentifier) { pending.append(a) } }
        let total = pending.count
        await ui { status in
            status.running = true
            status.total = total
            status.done = 0
            status.skipped = 0
            status.failed = 0
            status.lastError = nil
            status.pending = total
        }
        onProgress?(0, total)

        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.removeItem(at: tmpRoot)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let folders = RemoteFolders(api: api)
        var stopError: String?
        var processed = 0

        for asset in pending {
            if Task.isCancelled { break }
            do {
                let uploaded = try await backup(asset, api: api, folders: folders, tmpRoot: tmpRoot)
                log.add(asset.localIdentifier)
                await ui { status in
                    if uploaded { status.done += 1 } else { status.skipped += 1 }
                    status.backedUp = log.count
                    status.pending = max((status.pending ?? 1) - 1, 0)
                }
            } catch is CancellationError {
                break
            } catch let e as APIError where e.status == 400 && (e.errorDescription ?? "").contains("Speicherlimit") {
                stopError = e.localizedDescription
                break
            } catch let e as APIError where [400, 404, 409, 415].contains(e.status ?? 0) {
                // nur dieses Foto: weiter mit dem nächsten
                let msg = "\(asset.creationDate.map { Format.monthYear.string(from: $0) } ?? "Foto"): \(e.localizedDescription)"
                await ui { status in
                    status.failed += 1
                    status.lastError = msg
                }
            } catch let e as URLError where e.code == .cancelled {
                break
            } catch let e as URLError {
                stopError = Self.describe(e)
                break
            } catch {
                // z. B. iCloud-Original nicht ladbar: Foto überspringen
                let msg = error.localizedDescription
                await ui { status in
                    status.failed += 1
                    status.lastError = msg
                }
            }
            processed += 1
            onProgress?(processed, total)
        }

        try? FileManager.default.removeItem(at: tmpRoot)
        let now = Date()
        BackupSettings.lastRun = now
        let finalError = stopError
        await ui { status in
            status.running = false
            status.current = nil
            status.lastRun = now
            if let finalError { status.lastError = finalError }
        }
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return BackupSettings.wifiOnly ? "Kein WLAN – Sicherung pausiert" : "Keine Verbindung"
        case .cannotConnectToHost, .cannotFindHost, .timedOut:
            return "Server nicht erreichbar (bist du im Heimnetz?)"
        default:
            return e.localizedDescription
        }
    }

    /// Sichert ein Foto/Video. false = war schon auf dem Server.
    private func backup(_ asset: PHAsset, api: APIClient, folders: RemoteFolders, tmpRoot: URL) async throws -> Bool {
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
        var name = Self.clean(main.originalFilename, fallback: asset.mediaType == .video ? "VID.MOV" : "IMG.JPG")
        let shown = name
        await ui { $0.current = shown }

        let remote = try await folders.listing(folder)
        let size = Self.fileSize(main)
        if let existing = remote[name.lowercased()] {
            if size == nil || existing == size { return false }
            // anderes Foto mit gleichem Namen (z. B. IMG_0001 nach 10.000 Fotos)
            name = Self.suffixed(name, asset.localIdentifier)
        }

        let dir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var files: [(name: String, url: URL)] = []
        let mainURL = dir.appendingPathComponent(name)
        try await Self.export(main, to: mainURL)
        files.append((name, mainURL))
        if let paired {
            // gleicher Name wie das Foto, damit homevault das Live Photo erkennt
            let ext = (paired.originalFilename as NSString).pathExtension
            let videoName = (name as NSString).deletingPathExtension + "." + (ext.isEmpty ? "MOV" : ext)
            let url = dir.appendingPathComponent(videoName)
            try await Self.export(paired, to: url)
            files.append((videoName, url))
        }
        try Task.checkCancellation()

        let boundary = "hv-\(UUID().uuidString)"
        let body = dir.appendingPathComponent(".body")
        try Multipart.write(files: files, to: body, boundary: boundary)
        _ = try await api.upload(multipartFile: body, boundary: boundary, folder: folder)
        await folders.record(folder, name: name, size: size)
        return true
    }

    static func export(_ resource: PHAssetResource, to url: URL) async throws {
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true // Originale aus iCloud laden
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
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

    init(api: APIClient) { self.api = api }

    func listing(_ folder: String) async throws -> [String: Int64] {
        if let c = cache[folder] { return c }
        var result: [String: Int64] = [:]
        do {
            let list: ListResponse = try await api.get("api/list", ["path": folder])
            for e in list.entries where !e.isDir { result[e.name.lowercased()] = e.size }
        } catch APIError.server(404, _) {
            try await create(folder)
        }
        cache[folder] = result
        return result
    }

    func record(_ folder: String, name: String, size: Int64?) {
        cache[folder, default: [:]][name.lowercased()] = size ?? 0
    }

    /// Legt "Privat/iPhone/2026/10" Stück für Stück an.
    private func create(_ folder: String) async throws {
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
