import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Scans the screenshots folder and keeps the list current by watching it for changes.
///
/// Subfolders that contain screenshots are groups. Only one level is scanned:
/// screenshots in a subfolder's own subfolders are ignored.
final class ScreenshotLibrary {
    static let didChange = Notification.Name("ShotLibraryDidChange")

    private(set) var folderURL: URL
    /// Screenshots directly in the folder.
    private(set) var items: [Screenshot] = []
    /// Subfolders (groups) that contain screenshots.
    private(set) var folders: [ScreenshotFolder] = []
    private(set) var folderExists = true
    private(set) var isLoaded = false

    var screenshotCount: Int { items.count + folders.reduce(0) { $0 + $1.items.count } }

    private let scanQueue = DispatchQueue(label: "com.eiskrenkov.Shot.scan", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private var pendingReload: DispatchWorkItem?
    private var generation = 0

    init(folderURL: URL) {
        self.folderURL = folderURL
        startWatching()
        reload()
    }

    deinit {
        stopWatching()
    }

    func setFolder(_ url: URL) {
        guard url.standardizedFileURL != folderURL.standardizedFileURL else { return }
        folderURL = url
        items = []
        folders = []
        isLoaded = false
        startWatching()
        reload()
    }

    func folder(at url: URL) -> ScreenshotFolder? {
        folders.first { $0.url.pathKey == url.pathKey }
    }

    func reload() {
        generation += 1
        let token = generation
        let folder = folderURL
        scanQueue.async { [weak self] in
            let result = Self.scan(folder)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                let existedBefore = self.folderExists
                self.items = result.items
                self.folders = result.folders
                self.folderExists = result.exists
                self.isLoaded = true
                // The folder may have been created or recreated since we started watching.
                if result.exists && (!existedBefore || self.stream == nil) {
                    self.startWatching()
                }
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    // MARK: - Scanning

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .creationDateKey, .contentModificationDateKey,
        .fileSizeKey, .contentTypeKey, .localizedNameKey,
    ]

    private static func scan(_ folder: URL) -> (items: [Screenshot], folders: [ScreenshotFolder], exists: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return ([], [], false) }

        var items: [Screenshot] = []
        var folders: [ScreenshotFolder] = []
        for url in contents(of: folder) {
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            if values.isDirectory == true && values.isPackage != true {
                let children = contents(of: url).compactMap(screenshot(at:))
                guard !children.isEmpty else { continue }
                folders.append(ScreenshotFolder(
                    url: url,
                    displayName: values.localizedName ?? url.lastPathComponent,
                    creationDate: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                    items: children
                ))
            } else if let item = screenshot(at: url) {
                items.append(item)
            }
        }
        return (items, folders, true)
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
    }

    private static func screenshot(at url: URL) -> Screenshot? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
              values.isRegularFile == true,
              let type = values.contentType
        else { return nil }

        let kind: Screenshot.Kind
        if type.conforms(to: .image) {
            kind = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            kind = .video
        } else {
            return nil
        }

        let modified = values.contentModificationDate ?? .distantPast
        return Screenshot(
            url: url,
            displayName: values.localizedName ?? url.lastPathComponent,
            creationDate: values.creationDate ?? modified,
            modificationDate: modified,
            fileSize: Int64(values.fileSize ?? 0),
            kind: kind,
            contentType: type
        )
    }

    // MARK: - Watching

    /// Watches the folder and its subfolders with FSEvents.
    private func startWatching() {
        stopWatching()

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let library = Unmanaged<ScreenshotLibrary>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            library.handleEvents(paths: paths, flags: flags)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folderURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Reloads for changes in the folder or in a direct subfolder, ignoring anything deeper
    /// (the folder might be somewhere busy, like the Desktop).
    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let roots = Set([folderURL.path, folderURL.resolvingSymlinksInPath().path].map(Self.trimmed))
        let forceFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs
        )
        let relevant = zip(paths, flags).contains { path, flag in
            if flag & forceFlags != 0 { return true }
            let path = Self.trimmed(path)
            return roots.contains(path) || roots.contains(Self.trimmed((path as NSString).deletingLastPathComponent))
        }
        if relevant { scheduleReload() }
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Coalesces bursts of file system events (e.g. a screenshot being written then renamed).
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
