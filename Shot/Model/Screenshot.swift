import Foundation
import UniformTypeIdentifiers

/// Something that appears as a row in the sidebar: a screenshot or a group (folder) of them.
protocol LibraryEntry: NSObject {
    var url: URL { get }
    var displayName: String { get }
    /// The date used for sorting and for date sections.
    var sortDate: Date { get }
    var totalSize: Int64 { get }
}

/// A screenshot or screen recording on disk.
///
/// A reference type so it can be used directly as an `NSOutlineView` item.
final class Screenshot: NSObject, LibraryEntry {
    enum Kind {
        case image
        case video
    }

    let url: URL
    let displayName: String
    let creationDate: Date
    let modificationDate: Date
    let fileSize: Int64
    let kind: Kind
    let contentType: UTType?

    var sortDate: Date { creationDate }
    var totalSize: Int64 { fileSize }

    init(url: URL, displayName: String, creationDate: Date, modificationDate: Date,
         fileSize: Int64, kind: Kind, contentType: UTType?) {
        self.url = url
        self.displayName = displayName
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.kind = kind
        self.contentType = contentType
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? Screenshot)?.url == url
    }

    override var hash: Int { url.hashValue }

    /// The screenshots in `entries`, with groups replaced by their contents, without duplicates.
    static func flatten(_ entries: [LibraryEntry]) -> [Screenshot] {
        var seen = Set<String>()
        var result: [Screenshot] = []
        for entry in entries {
            let items = (entry as? ScreenshotFolder)?.items ?? [entry as? Screenshot].compactMap { $0 }
            for item in items where seen.insert(item.url.pathKey).inserted {
                result.append(item)
            }
        }
        return result
    }
}

/// A group of screenshots: a subfolder of the screenshots folder.
final class ScreenshotFolder: NSObject, LibraryEntry {
    let url: URL
    let displayName: String
    let creationDate: Date
    /// Screenshots directly inside the folder.
    let items: [Screenshot]
    /// The newest screenshot's date, so a group sits next to its screenshots in the timeline.
    let sortDate: Date

    var totalSize: Int64 { items.reduce(0) { $0 + $1.fileSize } }

    init(url: URL, displayName: String, creationDate: Date, items: [Screenshot], sortDate: Date? = nil) {
        self.url = url
        self.displayName = displayName
        self.creationDate = creationDate
        self.items = items
        self.sortDate = sortDate ?? items.map(\.creationDate).max() ?? creationDate
    }

    /// A copy showing only `items` (after filtering), keeping its place in the timeline.
    func with(items: [Screenshot]) -> ScreenshotFolder {
        ScreenshotFolder(url: url, displayName: displayName, creationDate: creationDate,
                         items: items, sortDate: sortDate)
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ScreenshotFolder)?.url == url
    }

    override var hash: Int { url.hashValue }
}

/// A date section in the sidebar.
final class ScreenshotGroup: NSObject {
    let id: String
    let title: String
    let entries: [LibraryEntry]

    /// Number of screenshots in the section, counting those inside groups.
    var screenshotCount: Int {
        entries.reduce(0) { $0 + (($1 as? ScreenshotFolder)?.items.count ?? 1) }
    }

    init(id: String, title: String, entries: [LibraryEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ScreenshotGroup)?.id == id
    }

    override var hash: Int { id.hashValue }
}

extension URL {
    /// A stable string for comparing file URLs (ignores trailing slashes, `.` and `..`).
    ///
    /// Purely lexical: `standardizedFileURL` also drops a `/private` prefix, but only
    /// while the file exists, so the key would change once a file is moved away.
    var pathKey: String { standardized.path }
}
