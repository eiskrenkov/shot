import Foundation

enum SortKey: String, CaseIterable {
    case dateCreated, name, size

    var title: String {
        switch self {
        case .dateCreated: "Date Created"
        case .name: "Name"
        case .size: "Size"
        }
    }

    var ascendingTitle: String {
        switch self {
        case .dateCreated: "Oldest First"
        case .name: "A to Z"
        case .size: "Smallest First"
        }
    }

    var descendingTitle: String {
        switch self {
        case .dateCreated: "Newest First"
        case .name: "Z to A"
        case .size: "Largest First"
        }
    }
}

enum Grouping: String, CaseIterable {
    case day, week, month, none

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .none: "None"
        }
    }
}

enum KindFilter: String, CaseIterable {
    case all, screenshots, recordings

    var title: String {
        switch self {
        case .all: "All Items"
        case .screenshots: "Screenshots"
        case .recordings: "Screen Recordings"
        }
    }
}

/// User-facing settings, persisted in `UserDefaults`.
final class Preferences {
    static let shared = Preferences()

    /// Posted whenever any list-affecting preference changes.
    static let didChange = Notification.Name("ShotPreferencesDidChange")
    /// Posted when the screenshots folder changes.
    static let folderDidChange = Notification.Name("ShotFolderDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let folderPath = "FolderPath"
        static let sortKey = "SortKey"
        static let ascending = "SortAscending"
        static let grouping = "Grouping"
        static let kindFilter = "KindFilter"
        static let favoritesOnly = "FavoritesOnly"
        static let showThumbnails = "ShowThumbnails"
    }

    private init() {
        defaults.register(defaults: [
            Key.sortKey: SortKey.dateCreated.rawValue,
            Key.ascending: false,
            Key.grouping: Grouping.day.rawValue,
            Key.kindFilter: KindFilter.all.rawValue,
            Key.favoritesOnly: false,
            Key.showThumbnails: true,
        ])
    }

    var folderURL: URL {
        get {
            if let path = defaults.string(forKey: Key.folderPath) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultFolderURL
        }
        set {
            guard newValue.standardizedFileURL != folderURL.standardizedFileURL else { return }
            defaults.set(newValue.standardizedFileURL.path, forKey: Key.folderPath)
            NotificationCenter.default.post(name: Self.folderDidChange, object: self)
            changed()
        }
    }

    var sortKey: SortKey {
        get { SortKey(rawValue: defaults.string(forKey: Key.sortKey) ?? "") ?? .dateCreated }
        set { defaults.set(newValue.rawValue, forKey: Key.sortKey); changed() }
    }

    var ascending: Bool {
        get { defaults.bool(forKey: Key.ascending) }
        set { defaults.set(newValue, forKey: Key.ascending); changed() }
    }

    var grouping: Grouping {
        get { Grouping(rawValue: defaults.string(forKey: Key.grouping) ?? "") ?? .day }
        set { defaults.set(newValue.rawValue, forKey: Key.grouping); changed() }
    }

    var kindFilter: KindFilter {
        get { KindFilter(rawValue: defaults.string(forKey: Key.kindFilter) ?? "") ?? .all }
        set { defaults.set(newValue.rawValue, forKey: Key.kindFilter); changed() }
    }

    var favoritesOnly: Bool {
        get { defaults.bool(forKey: Key.favoritesOnly) }
        set { defaults.set(newValue, forKey: Key.favoritesOnly); changed() }
    }

    var showThumbnails: Bool {
        get { defaults.bool(forKey: Key.showThumbnails) }
        set { defaults.set(newValue, forKey: Key.showThumbnails); changed() }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Folder discovery

    /// The folder macOS currently saves screenshots to (Screenshot app ▸ Options ▸ Save to).
    static var systemScreenshotFolderURL: URL? {
        guard let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
              !location.isEmpty
        else { return nil }
        let expanded = (location as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static var defaultFolderURL: URL {
        if let system = systemScreenshotFolderURL { return system }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pictures = home.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        if FileManager.default.fileExists(atPath: pictures.path) { return pictures }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }
}
