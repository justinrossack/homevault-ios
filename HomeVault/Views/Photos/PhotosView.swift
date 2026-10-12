import SwiftUI

struct PhotosView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case timeline = "Zeitleiste", favorites = "Favoriten", albums = "Alben"
        var id: String { rawValue }
    }

    @State private var mode = Mode.timeline

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .timeline: PhotoTimeline()
                case .favorites: FavoritesGrid()
                case .albums: AlbumsList()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Ansicht", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .updateBanner()
            .navigationDestination(for: Album.self) { AlbumDetail(album: $0) }
        }
    }
}

// MARK: Zeitleiste

@MainActor
@Observable
final class TimelineModel {
    var entries: [Entry] = []
    var next: String?
    var loading = false
    var loaded = false
    var indexing = false
    var error: String?

    func reload() async {
        next = nil
        await load(reset: true)
    }

    func loadMore() async {
        guard next != nil, !loading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard let api = AppModel.shared.api else { return }
        loading = true
        defer { loading = false }
        do {
            var q: [String: String] = [:]
            if !reset, let next { q["cursor"] = next }
            let page: TimelineResponse = try await api.get("api/timeline", q)
            entries = reset ? page.entries : entries + page.entries
            next = page.next
            indexing = page.indexing
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

struct PhotoTimeline: View {
    @State private var model = TimelineModel()

    var body: some View {
        PhotoGrid(entries: $model.entries, sectioned: true) {
            Task { await model.loadMore() }
        }
        .overlay {
            if !model.loaded {
                ProgressView()
            } else if let error = model.error, model.entries.isEmpty {
                ContentUnavailableView("Keine Verbindung", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if model.entries.isEmpty {
                ContentUnavailableView(
                    model.indexing ? "Fotos werden eingelesen …" : "Noch keine Fotos",
                    systemImage: "photo.on.rectangle",
                    description: Text("Schalte im Tab „Backup“ die Sicherung ein, dann erscheinen deine iPhone-Fotos hier.")
                )
            }
        }
        .refreshable { await model.reload() }
        .task { if !model.loaded { await model.reload() } }
    }
}

struct FavoritesGrid: View {
    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        PhotoGrid(entries: $entries, sectioned: false)
            .overlay {
                if !loaded {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if entries.isEmpty {
                    ContentUnavailableView("Keine Favoriten", systemImage: "heart",
                                           description: Text("Tippe beim Ansehen eines Fotos auf das Herz."))
                }
            }
            .refreshable { await load() }
            .task { await load() }
    }

    private func load() async {
        guard let api = AppModel.shared.api else { return }
        do {
            let r: EntriesResponse = try await api.get("api/favorites")
            entries = r.entries
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

// MARK: Alben

struct AlbumsList: View {
    @State private var albums: [Album] = []
    @State private var loaded = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            Color(.secondarySystemBackground)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    if let cover = album.cover {
                                        RemoteImage(path: cover.path)
                                    } else {
                                        Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.tertiary)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(album.count) Objekte").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if let error {
                ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if albums.isEmpty {
                ContentUnavailableView("Keine Alben", systemImage: "rectangle.stack",
                                       description: Text("Alben legst du in der Weboberfläche an."))
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let api = AppModel.shared.api else { return }
        do {
            let r: AlbumsResponse = try await api.get("api/albums")
            albums = r.albums
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

struct AlbumDetail: View {
    let album: Album
    @State private var entries: [Entry] = []
    @State private var loaded = false

    var body: some View {
        PhotoGrid(entries: $entries, sectioned: false)
            .overlay { if !loaded { ProgressView() } }
            .navigationTitle(album.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task { await load() }
    }

    private func load() async {
        guard let api = AppModel.shared.api else { return }
        if let r: AlbumResponse = try? await api.get("api/albums/\(album.id)") {
            entries = r.entries
        }
        loaded = true
    }
}
