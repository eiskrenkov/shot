import Foundation

/// Persisted set of favorite screenshot and group (folder) paths.
final class Favorites {
    static let shared = Favorites()
    static let didChange = Notification.Name("ShotFavoritesDidChange")

    private let key = "FavoritePaths"
    private var paths: Set<String>

    private init() {
        paths = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func contains(_ url: URL) -> Bool {
        paths.contains(url.pathKey)
    }

    func allFavorite(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy(contains)
    }

    func set(_ favorite: Bool, for urls: [URL]) {
        let normalized = urls.map(\.pathKey)
        if favorite {
            paths.formUnion(normalized)
        } else {
            paths.subtract(normalized)
        }
        save()
    }

    /// Favorites all items, unless every one of them is already a favorite.
    func toggle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        set(!allFavorite(urls), for: urls)
    }

    /// Forgets `urls` and, for folders, everything inside them.
    func remove(_ urls: [URL]) {
        let removed = urls.map(\.pathKey)
        let before = paths
        paths = paths.filter { path in !removed.contains { path == $0 || path.hasPrefix($0 + "/") } }
        if paths != before { save() }
    }

    /// Keeps favorites attached to files and folders that were moved or renamed.
    func move(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        let before = paths
        for move in moves {
            let old = move.from.pathKey
            let new = move.to.pathKey
            paths = Set(paths.map { path in
                if path == old { return new }
                if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
                return path
            })
        }
        if paths != before { save() }
    }

    private func save() {
        UserDefaults.standard.set(Array(paths).sorted(), forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
