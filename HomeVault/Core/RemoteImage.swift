import SwiftUI
import UIKit

/// Lädt Bilder vom Server und hält sie im Speicher. Die Festplatten-Ablage
/// übernimmt der URLCache des Clients.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 150 << 20
    }

    func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func image(api: APIClient, endpoint: String, path: String) async throws -> UIImage {
        let key = "\(endpoint)|\(path)"
        if let img = cached(key) { return img }
        let data = try await api.data(endpoint, ["path": path])
        guard let raw = UIImage(data: data) else { throw APIError.invalidResponse }
        let img = await raw.byPreparingForDisplay() ?? raw
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        cache.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }
}

/// Vorschaubild eines Eintrags (quadratisch beschnitten oder eingepasst).
struct RemoteImage: View {
    let path: String
    var endpoint = "api/thumb"
    var contentMode: ContentMode = .fill
    /// Symbol, wenn der Server kein Vorschaubild liefern kann
    var fallbackIcon = "photo"

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: fallbackIcon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else if contentMode == .fit {
                ProgressView()
            }
        }
        .task(id: path + endpoint) {
            if let img = ImagePipeline.shared.cached("\(endpoint)|\(path)") {
                image = img
                return
            }
            guard let api = AppModel.shared.api else { return }
            do {
                image = try await ImagePipeline.shared.image(api: api, endpoint: endpoint, path: path)
            } catch is CancellationError {
            } catch {
                failed = true
            }
        }
    }
}
