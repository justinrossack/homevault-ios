import AVKit
import Combine
import SwiftUI
import UIKit

/// Vollbild-Ansicht: seitlich blättern, nach unten wischen zum Schließen,
/// Zoomen, Videos, Live Photos, Favorit und Teilen.
struct PhotoViewer: View {
    @Binding var entries: [Entry]
    @Environment(\.dismiss) private var dismiss

    /// Pfad des angezeigten Eintrags (für die Scroll-Position)
    @State private var position: String?
    @State private var index: Int
    @State private var chrome = true
    @State private var zoomed = false
    @State private var drag: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var shareURL: URL?
    @State private var busy = false
    @State private var error: String?

    init(entries: Binding<[Entry]>, index: Int) {
        _entries = entries
        _index = State(initialValue: index)
        let list = entries.wrappedValue
        _position = State(initialValue: list.indices.contains(index) ? list[index].path : nil)
    }

    private var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    /// 0 … 1, wie weit nach unten gezogen wurde
    private var dragProgress: CGFloat { min(drag / 300, 1) }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dragProgress * 0.8)
                .ignoresSafeArea()

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(entries) { e in
                        MediaPage(entry: e, active: e.path == position, zoomed: $zoomed) {
                            withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .scrollDisabled(zoomed || dragAxis == .vertical)
            .ignoresSafeArea()
            .offset(y: drag)
            .scaleEffect(1 - dragProgress * 0.25)
            .simultaneousGesture(dismissGesture)

            if chrome && drag == 0 {
                bars.transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
        .preferredColorScheme(.dark)
        .onChange(of: position) { _, p in
            if let p, let i = entries.firstIndex(where: { $0.path == p }) { index = i }
        }
        .alert("Fehler", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url]).presentationDetents([.medium, .large])
        }
    }

    /// Nach unten ziehen schließt die Ansicht (nicht beim Zoomen).
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard !zoomed else { return }
                if dragAxis == nil {
                    dragAxis = abs(v.translation.height) > abs(v.translation.width) * 1.2 ? .vertical : .horizontal
                }
                if dragAxis == .vertical { drag = max(v.translation.height, 0) }
            }
            .onEnded { v in
                defer { dragAxis = nil }
                guard dragAxis == .vertical else { return }
                if v.translation.height > 120 || v.predictedEndTranslation.height > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { drag = 0 }
                }
            }
    }

    private var bars: some View {
        VStack {
            HStack(alignment: .center) {
                CircleButton(systemImage: "xmark") { dismiss() }
                Spacer()
                if let e = current {
                    VStack(spacing: 0) {
                        Text(e.date.formatted(date: .long, time: .omitted)).font(.subheadline.weight(.semibold))
                        Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal)
            Spacer()
            HStack {
                CircleButton(systemImage: "square.and.arrow.up", busy: busy) { Task { await share() } }
                Spacer()
                if let e = current {
                    Text(Format.bytes(e.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                CircleButton(systemImage: current?.isFavorite == true ? "heart.fill" : "heart") {
                    Task { await toggleFavorite() }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func toggleFavorite() async {
        guard let e = current, let api = AppModel.shared.api else { return }
        let fav = !e.isFavorite
        struct Body: Encodable { let paths: [String]; let favorite: Bool }
        do {
            try await api.send("POST", "api/favorites", json: Body(paths: [e.path], favorite: fav))
            if let i = entries.firstIndex(where: { $0.path == e.path }) { entries[i].favorite = fav }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Lädt das Original und öffnet das Teilen-Menü (Sichern, AirDrop, …).
    private func share() async {
        guard !busy, let e = current, let api = AppModel.shared.api else { return }
        busy = true
        defer { busy = false }
        do {
            shareURL = try await Downloads.fetch(api: api, path: e.path, name: e.name)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CircleButton: View {
    let systemImage: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView() } else { Image(systemName: systemImage).font(.body.weight(.semibold)) }
            }
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
        .disabled(busy)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Eine Seite: Foto (zoombar), Video oder Live Photo.
struct MediaPage: View {
    let entry: Entry
    let active: Bool
    @Binding var zoomed: Bool
    let onTap: () -> Void

    @State private var livePlayer: AVPlayer?
    @State private var livePlaying = false
    @State private var livePlayedOnce = false

    var body: some View {
        if entry.isVideo {
            VideoPage(path: entry.path, name: entry.name, active: active)
        } else {
            ZoomableRemoteImage(path: entry.path, endpoint: entry.preview == true ? "api/preview" : "api/file",
                                zoomed: $zoomed, onTap: onTap)
                .overlay {
                    if livePlaying, let livePlayer {
                        PlayerLayerView(player: livePlayer)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if entry.live != nil, active {
                        liveBadge
                            .padding(.top, 70)
                            .padding(.leading, 16)
                    }
                }
                .onChange(of: active, initial: true) { _, isActive in
                    // wie in der Weboberfläche: beim ersten Öffnen einmal kurz abspielen
                    if isActive, entry.live != nil, !livePlayedOnce {
                        livePlayedOnce = true
                        playLive()
                    } else if !isActive {
                        stopLive()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { n in
                    if (n.object as? AVPlayerItem) === livePlayer?.currentItem { livePlaying = false }
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
            let p = AVPlayer(playerItem: AVPlayerItem(asset: VideoAsset.make(api: api, endpoint: "api/file", path: live)))
            p.isMuted = true
            livePlayer = p
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

enum VideoAsset {
    /// Sitzung als Cookie und zusätzlich als Header, damit es auch bei
    /// Servern unter einer IP-Adresse zuverlässig ankommt.
    static func make(api: APIClient, endpoint: String, path: String) -> AVURLAsset {
        var options: [String: Any] = [AVURLAssetHTTPCookiesKey: api.cookies]
        if let cookie = api.cookieHeader {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Cookie": cookie]
        }
        return AVURLAsset(url: api.url(endpoint, ["path": path]), options: options)
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

/// Video mit System-Steuerung. Klappt das Original nicht (Format, Verbindung),
/// wird die vom Server umgewandelte Fassung versucht.
struct VideoPage: View {
    let path: String
    let name: String
    let active: Bool

    @State private var player: AVPlayer?
    @State private var message: String?
    @State private var triedWeb = false
    @State private var statusWatch: AnyCancellable?

    var body: some View {
        ZStack {
            if let player {
                // Platz für die eigenen Knöpfe oben und unten, damit die Video-Steuerung frei bleibt
                VideoPlayer(player: player)
                    .padding(.top, 110)
                    .padding(.bottom, 100)
            } else if let message {
                VStack(spacing: 14) {
                    ContentUnavailableView(message, systemImage: "film")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Erneut versuchen") {
                        self.message = nil
                        triedWeb = false
                        Task { await prepare() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                RemoteImage(path: path, contentMode: .fit)
                ProgressView().tint(.white)
            }
        }
        .task(id: active) {
            if active {
                if player == nil { await prepare() } else { player?.play() }
            } else {
                player?.pause()
            }
        }
        .onDisappear { player?.pause() }
    }

    private func prepare() async {
        guard let api = AppModel.shared.api else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        // Formate, die iOS nicht abspielt, direkt in der umgewandelten Fassung
        if !["mov", "mp4", "m4v", "3gp"].contains(ext) {
            await playWeb(api: api)
            return
        }
        play(VideoAsset.make(api: api, endpoint: "api/file", path: path), api: api)
    }

    private func play(_ asset: AVURLAsset, api: APIClient) {
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        statusWatch = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                guard status == .failed else { return }
                player = nil
                if !triedWeb {
                    Task { await playWeb(api: api) }
                } else {
                    message = item.error?.localizedDescription ?? "Video kann nicht abgespielt werden"
                }
            }
        player = p
        if active { p.play() }
    }

    private func playWeb(api: APIClient) async {
        triedWeb = true
        struct VideoStatus: Decodable { let mode: String }
        let status: VideoStatus? = try? await api.get("api/video", ["path": path])
        switch status?.mode {
        case "original", "web":
            play(VideoAsset.make(api: api, endpoint: status?.mode == "web" ? "api/video/web" : "api/file", path: path), api: api)
        case "pending":
            message = "Video wird auf dem Server umgewandelt. Gleich nochmal versuchen."
        default:
            message = "Video kann nicht abgespielt werden"
        }
    }
}

/// Lädt erst das Vorschaubild, dann die große Fassung; Zoom per Pinch/Doppeltipp.
struct ZoomableRemoteImage: View {
    let path: String
    let endpoint: String
    @Binding var zoomed: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, zoomed: $zoomed, onTap: onTap)
            } else {
                RemoteImage(path: path, contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
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
    @Binding var zoomed: Bool
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        // ungezoomt nimmt die Bildansicht keine Wischgesten an (Blättern, Schließen)
        scroll.isScrollEnabled = false
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = scroll.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(iv)
        context.coordinator.imageView = iv
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?

        init(parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > 1.01
            scrollView.isScrollEnabled = isZoomed
            if parent.zoomed != isZoomed { parent.zoomed = isZoomed }
        }

        @objc func singleTap() { parent.onTap() }

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

/// Heruntergeladene Dateien liegen im Cache.
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
