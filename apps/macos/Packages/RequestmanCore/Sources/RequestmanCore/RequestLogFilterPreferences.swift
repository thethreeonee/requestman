import Foundation

/// A saved snapshot also represents the opt-in; removing it disables restoration.
public enum RequestLogFilterPreferences {
    private static let key = "requestLog.savedFilter.v1"

    public static func load(from defaults: UserDefaults = .standard) -> CaptureRecordFilter? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CaptureRecordFilter.self, from: data)
    }

    public static func save(_ filter: CaptureRecordFilter?, to defaults: UserDefaults = .standard) {
        guard let filter else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(filter) else { return }
        defaults.set(data, forKey: key)
    }
}
