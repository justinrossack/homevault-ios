import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FolderRoute: Hashable {
    let path: String
    let name: String
}

struct FilesView: View {
    var body: some View {
        NavigationStack {
            FolderView(route: FolderRoute(path: "", name: "Dateien"))
                .updateBanner()
                .navigationDestination(for: FolderRoute.self) { FolderView(route: $0) }
        }
    }
}

struct FolderView: View {
    let route: FolderRoute

    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var opening: String?
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var importing = false
    @State private var uploading = false
    @State private var toDelete: Entry?

    private var isRoot: Bool { route.path.isEmpty }

    var body: some View {
        List {
            ForEach(entries) { e in
                row(e)
                    .swipeActions {
                        if !isRoot {
                            Button(role: .destructive) { toDelete = e } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                    .contextMenu {
                        if !e.isDir {
                            Button { Task { await open(e, share: true) } } label: { Label("Teilen / Sichern", systemImage: "square.and.arrow.up") }
                        }
                        if !isRoot {
                            Button(role: .destructive) { toDelete = e } label: { Label("In den Papierkorb", systemImage: "trash") }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !loaded {
                ProgressView()
            } else if let error, entries.isEmpty {
                ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if entries.isEmpty {
                ContentUnavailableView("Ordner ist leer", systemImage: "folder")
            }
        }
        .overlay(alignment: .bottom) {
            if uploading || opening != nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(uploading ? "Wird hochgeladen …" : "\(opening ?? "") wird geladen …").lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding()
            }
        }
        .navigationTitle(route.name)
        .toolbar {
            if !isRoot {
                Menu {
                    Button { newFolder = true } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
                    Button { importing = true } label: { Label("Dateien hochladen", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .quickLookPreview($previewURL)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]).presentationDetents([.medium, .large]) }
        .alert("Neuer Ordner", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Abbrechen", role: .cancel) { folderName = "" }
            Button("Anlegen") { Task { await createFolder() } }
        }
        .confirmationDialog("„\(toDelete?.name ?? "")“ in den Papierkorb verschieben?", isPresented: .constant(toDelete != nil), titleVisibility: .visible) {
            Button("In den Papierkorb", role: .destructive) { Task { await delete() } }
            Button("Abbrechen", role: .cancel) { toDelete = nil }
        } message: {
            Text("Der Papierkorb lässt sich in der Weboberfläche wiederherstellen.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await upload(urls) } }
        }
        .alert("Fehler", isPresented: .constant(error != nil && loaded && !entries.isEmpty)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private func row(_ e: Entry) -> some View {
        if e.isDir {
            NavigationLink(value: FolderRoute(path: e.path, name: e.name)) {
                HStack(spacing: 12) {
                    Image(systemName: icon(e))
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                    Text(e.name)
                }
            }
        } else {
            Button { Task { await open(e, share: false) } } label: {
                HStack(spacing: 12) {
                    Group {
                        if e.hasThumb {
                            RemoteImage(path: e.path, fallbackIcon: icon(e))
                        } else {
                            Image(systemName: icon(e)).font(.title2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).lineLimit(2)
                        Text("\(Format.bytes(e.size)) · \(Format.date(e.modified))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private func icon(_ e: Entry) -> String {
        if e.isDir {
            switch e.path {
            case "Privat": return "person.crop.square.fill"
            case "Gemeinsam": return "person.2.fill"
            default: return "folder.fill"
            }
        }
        if e.isImage { return "photo" }
        if e.isVideo { return "film" }
        switch e.doc {
        case "pdf": return "doc.richtext"
        case "office": return "doc.text"
        case "text": return "doc.plaintext"
        case "audio": return "music.note"
        default: break
        }
        switch (e.name as NSString).pathExtension.lowercased() {
        case "zip", "tar", "gz", "tgz", "7z", "rar": return "doc.zipper"
        default: return "doc"
        }
    }

    private func load() async {
        guard let api = AppModel.shared.api else { return }
        do {
            let r: ListResponse = try await api.get("api/list", ["path": route.path])
            entries = r.entries
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func open(_ e: Entry, share: Bool) async {
        guard opening == nil, let api = AppModel.shared.api else { return }
        opening = e.name
        defer { opening = nil }
        do {
            let url = try await Downloads.fetch(api: api, path: e.path, name: e.name)
            if share { shareURL = url } else { previewURL = url }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        folderName = ""
        guard !name.isEmpty, let api = AppModel.shared.api else { return }
        do {
            try await api.send("POST", "api/folder", json: ["path": route.path + "/" + name])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let e = toDelete, let api = AppModel.shared.api else { return }
        toDelete = nil
        do {
            try await api.delete("api/file", query: ["path": e.path])
            entries.removeAll { $0.path == e.path }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func upload(_ urls: [URL]) async {
        guard let api = AppModel.shared.api, !urls.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (u, ok) in scoped where ok { u.stopAccessingSecurityScopedResource() } }
            let boundary = "hv-\(UUID().uuidString)"
            try Multipart.write(files: urls.map { ($0.lastPathComponent, $0) }, to: tmp, boundary: boundary)
            _ = try await api.upload(multipartFile: tmp, boundary: boundary, folder: route.path)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
