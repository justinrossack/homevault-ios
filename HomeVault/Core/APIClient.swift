import Foundation

enum APIError: LocalizedError {
    case server(Int, String)
    case unauthorized
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(_, let msg): msg
        case .unauthorized: "Nicht angemeldet"
        case .invalidResponse: "Unerwartete Antwort vom Server"
        }
    }

    var status: Int? {
        switch self {
        case .server(let s, _): s
        case .unauthorized: 401
        case .invalidResponse: nil
        }
    }
}

/// Zugriff auf die homevault-API. Die Sitzung steckt im Cookie `hv_session`,
/// das wir selbst setzen (kein geteilter Cookie-Speicher). Läuft die Sitzung
/// ab (30 Tage), meldet sich der Client mit dem gespeicherten Passwort neu an.
final class APIClient: @unchecked Sendable {
    static let cookieName = "hv_session"

    let baseURL: URL
    let username: String
    private let lock = NSLock()
    private var token: String?
    private let session: URLSession

    init(baseURL: URL, username: String, token: String?, wifiOnly: Bool = false) {
        self.baseURL = baseURL
        self.username = username
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = !wifiOnly
        cfg.allowsExpensiveNetworkAccess = !wifiOnly
        // Thumbnails sind beim Server "immutable", der Cache spart viel Ladezeit
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
        cfg.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: cfg)
    }

    /// "192.168.1.10" -> http://192.168.1.10:8080
    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else { return nil }
        if comps.port == nil && comps.scheme == "http" { comps.port = 8080 }
        comps.path = ""
        return comps.url
    }

    var currentToken: String? {
        lock.withLock { token }
    }

    var cookieHeader: String? {
        currentToken.map { "\(Self.cookieName)=\($0)" }
    }

    /// Für AVPlayer (AVURLAssetHTTPCookiesKey)
    var cookies: [HTTPCookie] {
        guard let token = currentToken, let host = baseURL.host else { return [] }
        return [HTTPCookie(properties: [
            .name: Self.cookieName, .value: token, .domain: host, .path: "/",
        ])].compactMap { $0 }
    }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // "+" würde der Server als Leerzeichen lesen
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url!
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let c = cookieHeader { req.setValue(c, forHTTPHeaderField: "Cookie") }
        return req
    }

    // MARK: Anmeldung

    func login(password: String) async throws {
        var req = URLRequest(url: url("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, resp) = try await session.data(for: req)
        let http = try check(data, resp)
        guard let header = http.value(forHTTPHeaderField: "Set-Cookie"),
              let token = Self.parseToken(header) else { throw APIError.invalidResponse }
        lock.withLock { self.token = token }
        Keychain.set(token, for: "session")
    }

    static func parseToken(_ setCookie: String) -> String? {
        setCookie.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(cookieName + "=") }
            .map { String($0.dropFirst(cookieName.count + 1)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func logout() async {
        _ = try? await perform(request(url("api/logout"), method: "POST"), retry: false)
        lock.withLock { token = nil }
    }

    // MARK: Anfragen

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await perform(request(url(path, query)))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Anfrage mit JSON-Body, Antwort wird ignoriert.
    func send(_ method: String, _ path: String, query: [String: String] = [:], json: some Encodable) async throws {
        var req = request(url(path, query), method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(json)
        _ = try await perform(req)
    }

    func delete(_ path: String, query: [String: String]) async throws {
        _ = try await perform(request(url(path, query), method: "DELETE"))
    }

    func data(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        try await perform(request(url(path, query))).0
    }

    /// Lädt eine Datei herunter und legt sie unter `dest` ab.
    func download(_ path: String, _ query: [String: String], to dest: URL) async throws {
        try await withRelogin { [self] in
            let (tmp, resp) = try await session.download(for: request(url(path, query)))
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = (try? Data(contentsOf: tmp)) ?? Data()
                _ = try check(body, resp)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }

    /// Schickt einen fertigen Multipart-Body (Datei) an /api/upload.
    /// Gibt die gespeicherten Pfade zurück.
    /// `progress` bekommt die seit dem letzten Aufruf gesendeten Bytes.
    func upload(multipartFile: URL, boundary: String, folder: String,
                progress: (@Sendable (Int64) -> Void)? = nil) async throws -> [String] {
        struct Saved: Decodable { let saved: [String] }
        let data = try await withRelogin { [self] in
            var req = request(url("api/upload", ["path": folder]), method: "POST")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 600
            let delegate = progress.map(UploadProgress.init)
            let (data, resp) = try await session.upload(for: req, fromFile: multipartFile, delegate: delegate)
            _ = try check(data, resp)
            return data
        }
        return try JSONDecoder().decode(Saved.self, from: data).saved
    }

    @discardableResult
    private func perform(_ req: URLRequest, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var req = req
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, try check(data, resp))
        } catch APIError.unauthorized where retry {
            try await relogin()
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            return try await perform(req, retry: false)
        }
    }

    private func withRelogin<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch APIError.unauthorized {
            try await relogin()
            return try await body()
        }
    }

    private func relogin() async throws {
        guard let password = Keychain.get("password") else { throw APIError.unauthorized }
        try await login(password: password)
    }

    private func check(_ data: Data, _ resp: URLResponse) throws -> HTTPURLResponse {
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if (200..<300).contains(http.statusCode) { return http }
        if http.statusCode == 401 { throw APIError.unauthorized }
        struct Err: Decodable { let error: String }
        let msg = (try? JSONDecoder().decode(Err.self, from: data).error)
            ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        throw APIError.server(http.statusCode, msg)
    }
}

/// Meldet den Upload-Fortschritt in Häppchen (nicht bei jedem Paket).
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64) -> Void
    private var reported: Int64 = 0

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let delta = totalBytesSent - reported
        if delta >= 512 << 10 || totalBytesSent == totalBytesExpectedToSend {
            reported = totalBytesSent
            report(delta)
        }
    }
}

/// Multipart-Body als Datei, damit auch große Videos nicht im Speicher landen.
enum Multipart {
    static func head(name: String, boundary: String) -> Data {
        let safeName = name.replacingOccurrences(of: "\"", with: "_")
        return Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n" +
            "Content-Type: application/octet-stream\r\n\r\n").utf8)
    }

    static func tail(boundary: String) -> Data {
        Data("--\(boundary)--\r\n".utf8)
    }

    static func write(files: [(name: String, url: URL)], to out: URL, boundary: String) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        for file in files {
            try handle.write(contentsOf: head(name: file.name, boundary: boundary))
            let input = try FileHandle(forReadingFrom: file.url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: tail(boundary: boundary))
    }
}
