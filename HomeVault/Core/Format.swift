import Foundation

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func date(_ unix: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "gerade eben" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        return f.localizedString(for: date, relativeTo: .now)
    }

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f
    }()
}

/// Ablaufdatum des eingebetteten Provisioning-Profils (Ad-Hoc-Installation).
/// Danach startet die App nicht mehr und muss neu installiert werden.
enum ProfileInfo {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>") else { return nil }
        let xml = Data(raw[start.lowerBound..<end.upperBound].utf8)
        let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()
}
