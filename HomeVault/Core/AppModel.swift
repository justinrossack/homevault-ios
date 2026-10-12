import Foundation
import Observation

/// Gespeicherte Einstellungen (UserDefaults), auch aus dem Hintergrund lesbar.
enum Settings {
    static let defaults = UserDefaults.standard

    static var server: String? {
        get { defaults.string(forKey: "server") }
        set { defaults.set(newValue, forKey: "server") }
    }
    static var username: String? {
        get { defaults.string(forKey: "username") }
        set { defaults.set(newValue, forKey: "username") }
    }

    /// Client aus den gespeicherten Zugangsdaten, nil wenn nicht angemeldet.
    static func client(wifiOnly: Bool = false) -> APIClient? {
        guard let s = server, let url = URL(string: s), let user = username else { return nil }
        return APIClient(baseURL: url, username: user, token: Keychain.get("session"), wifiOnly: wifiOnly)
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var api: APIClient?
    private(set) var me: Me?

    var isAdmin: Bool { me?.user?.admin ?? false }
    var serverName: String { me?.server_name ?? "homevault" }

    private init() {
        api = Settings.client()
    }

    func login(server: String, username: String, password: String) async throws {
        guard let url = APIClient.normalize(server) else {
            throw APIError.server(0, "Bitte eine gültige Server-Adresse eingeben, z. B. 192.168.1.10")
        }
        let user = username.trimmingCharacters(in: .whitespaces).lowercased()
        let client = APIClient(baseURL: url, username: user, token: nil)
        let status: Me = try await client.get("api/me")
        if status.setup_needed {
            throw APIError.server(0, "Der Server ist noch nicht eingerichtet. Bitte zuerst im Browser den Einrichtungsassistenten durchlaufen.")
        }
        try await client.login(password: password)
        Keychain.set(password, for: "password")
        Settings.server = url.absoluteString
        Settings.username = user
        api = client
        me = try await client.get("api/me")
    }

    func refreshMe() async {
        guard let api else { return }
        do {
            let status: Me = try await api.get("api/me")
            if status.authenticated {
                me = status
            } else {
                // Sitzung abgelaufen: eine geschützte Anfrage meldet neu an
                let _: StorageOverview = try await api.get("api/storage")
                me = try await api.get("api/me")
            }
        } catch APIError.unauthorized {
            logout()
        } catch {
            // Server gerade nicht erreichbar (z. B. unterwegs): angemeldet bleiben
        }
    }

    func logout() {
        if let api { Task { await api.logout() } }
        Keychain.set(nil, for: "session")
        Keychain.set(nil, for: "password")
        Settings.username = nil
        BackupSettings.enabled = false
        api = nil
        me = nil
    }
}
