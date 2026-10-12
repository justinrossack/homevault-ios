import Foundation
import Observation
import UIKit

/// Prüft auf der Installationsseite (GitHub Pages), ob eine neuere Version
/// veröffentlicht ist. Die Adresse setzt scripts/release.sh beim Bauen.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Decodable, Equatable {
        let version: String
        let build: String
        let manifest: String
        let notes: String?
    }

    private(set) var available: Release?
    /// Banner mit „x“ geschlossen (bis zum nächsten App-Start)
    var dismissed = false
    private var lastCheck: Date?

    private init() {}

    static var pagesURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "HVUpdateURL") as? String else { return nil }
        #if DEBUG
        // lokale Testseite erlaubt
        guard s.hasPrefix("https://") || s.hasPrefix("http://") else { return nil }
        #else
        // itms-services funktioniert nur mit HTTPS
        guard s.hasPrefix("https://") else { return nil }
        #endif
        return URL(string: s)
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Höchstens alle 30 Minuten, außer `force`.
    func check(force: Bool = false) async {
        guard let base = Self.pagesURL else { return }
        if !force, let lastCheck, lastCheck.timeIntervalSinceNow > -1800 { return }
        lastCheck = .now
        var req = URLRequest(url: base.appendingPathComponent("version.json"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
        let newer = release.build.compare(Self.currentBuild, options: .numeric) == .orderedDescending
        available = newer ? release : nil
    }

    /// iOS fragt dann „homevault installieren?“ und ersetzt die App.
    func install() {
        guard let release = available,
              var comps = URLComponents(string: "itms-services://") else { return }
        comps.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: release.manifest),
        ]
        if let url = comps.url { UIApplication.shared.open(url) }
    }
}
