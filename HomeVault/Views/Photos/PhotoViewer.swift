import AVKit
import SwiftUI
import UIKit

/// Vollbild-Ansicht mit Wischen, Zoomen, Favorit und Teilen.
struct PhotoViewer: View {
    @Binding var entries: [Entry]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var busy = false
    @State private var error: String?
    @State private var chrome = true

    private var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(entries.indices, id: \.self) { i in
                    MediaPage(entry: entries[i], active: i == index)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .ignoresSafeArea()
            .onTapGesture { withAnimation { chrome.toggle() } }
            .toolbar(chrome ? .visible : .hidden, for: .navigationBar, .bottomBar)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .principal) {
                    if let e = current {
                        VStack(spacing: 0) {
                            Text(e.date.formatted(date: .long, time: .omitted)).font(.subheadline.weight(.semibold))
                            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { Task { await share() } } label: {
                        if busy { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(busy)
                    Spacer()
                    if let e = current {
                        Text(Format.bytes(e.size)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await toggleFavorite() } } label: {
                        Image(systemName: current?.isFavorite == true ? "heart.fill" : "heart")
                    }
                }
            }
            .alert("Fehler", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
        .preferredColorScheme(.dark)
    }

    private func toggleFavorite() async {
        guard let e = current, let api = AppModel.shared.api else { return }
        let fav = !e.isFavorite
        struct Body: Encodable { let paths: [String]; let favorite: Bool }
        do {
            try await api.send("POST", "api/favorites", json: Body(paths: [e.path], favorite: fav))
            if entries.indices.contains(index) { entries[index].favorite = fav }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Lädt das Original und öffnet das Teilen-Menü (Sichern, AirDrop, …).
    private func share() async {
        guard let e = current, let api = AppModel.shared.api else { return }
        busy = true
        defer { busy = false }
        do {
            shareURL = try await Downloads.fetch(api: api, path: e.path, name: e.name)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Eine Seite: Foto (zoombar), Video oder Live Photo.
struct MediaPage: View {
    let entry: Entry
    let active: Bool

    @State private var livePlayer: AVPlayer?
    @State private var livePlaying = false

    var body: some View {
        if entry.isVideo {
            VideoPage(path: entry.path, name: entry.name, active: active)
        } else {
            ZoomableRemoteImage(path: entry.path, endpoint: entry.preview == true ? "api/preview" : "api/file",
                                thumb: entry.path)
                .overlay {
                    if livePlaying, let livePlayer {
                        PlayerLayerView(player: livePlayer)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if entry.live != nil, active {
                        liveBadge
                            .padding(.top, 110)
                            .padding(.leading, 16)
                    }
                }
        }
    }

    /// Gedrückt halten spielt das Video des Live Photos ab.
    private var liveBadge: some View {
        Label("LIVE", systemImage: "livephoto")
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .onLongPressGesture(minimumDuration: 0.2, perform: {}, onPressingChanged: { pressing in
                pressing ? playLive() : stopLive()
            })
    }

    private func playLive() {
        guard let live = entry.live, let api = AppModel.shared.api else { return }
        if livePlayer == nil {
            let asset = AVURLAsset(url: api.url("api/file", ["path": live]),
                                   options: [AVURLAssetHTTPCookiesKey: api.cookies])
            livePlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        livePlayer?.seek(to: .zero)
        livePlayer?.play()
        livePlaying = true
    }

    private func stopLive() {
        livePlayer?.pause()
        livePlaying = false
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let v = View()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: View, context: Context) {
        v.playerLayer.player = player
    }
}

struct VideoPage: View {
    let path: String
    let name: String
    let active: Bool
    @State private var player: AVPlayer?
    @State private var message: String?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let message {
                ContentUnavailableView(message, systemImage: "film")
            } else {
                RemoteImage(path: path, contentMode: .fit)
            }
        }
        .task(id: active) {
            if active { await prepare() } else { player?.pause() }
        }
    }

    private func prepare() async {
        guard player == nil, let api = AppModel.shared.api else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        var endpoint = "api/file"
        // Formate, die iOS nicht abspielt: umgewandelte Fassung vom Server
        if !["mov", "mp4", "m4v", "3gp"].contains(ext) {
            struct VideoStatus: Decodable { let mode: String }
            let status: VideoStatus? = try? await api.get("api/video", ["path": path])
            guard status?.mode == "web" else {
                message = "Video wird auf dem Server umgewandelt …"
                return
            }
            endpoint = "api/video/web"
        }
        let asset = AVURLAsset(url: api.url(endpoint, ["path": path]), options: [AVURLAssetHTTPCookiesKey: api.cookies])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        p.play()
    }
}

/// Lädt erst das Vorschaubild, dann die große Fassung; mit Zoom per Pinch/Doppeltipp.
struct ZoomableRemoteImage: View {
    let path: String
    let endpoint: String
    let thumb: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image)
            } else {
                RemoteImage(path: thumb, contentMode: .fit)
                ProgressView().tint(.white)
            }
        }
        .task(id: path) {
            guard let api = AppModel.shared.api else { return }
            image = try? await ImagePipeline.shared.image(api: api, endpoint: endpoint, path: path)
        }
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = scroll.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(iv)
        context.coordinator.imageView = iv
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(origin: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), size: size), animated: true)
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Heruntergeladene Dateien liegen im Cache und werden beim Start aufgeräumt.
enum Downloads {
    static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("downloads", isDirectory: true)

    static func fetch(api: APIClient, path: String, name: String) async throws -> URL {
        let folder = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(name)
        try await api.download("api/file", ["path": path], to: dest)
        return dest
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}
