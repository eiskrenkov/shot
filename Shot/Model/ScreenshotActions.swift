import AppKit

/// File operations shared by the menu bar, toolbar and context menus.
enum ScreenshotActions {
    static func open(_ items: [Screenshot]) {
        // Group by default app so e.g. several images open in a single Preview window.
        var byApp: [URL: [URL]] = [:]
        for item in items {
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) else { continue }
            byApp[app, default: []].append(item.url)
        }
        for (app, urls) in byApp {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    static func open(_ items: [Screenshot], withApplicationAt app: URL) {
        NSWorkspace.shared.open(items.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    static func revealInFinder(_ entries: [LibraryEntry]) {
        NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.url))
    }

    /// Puts file URLs on the pasteboard. A single image also carries its image data,
    /// so it can be pasted into apps that only accept images.
    static func copy(_ items: [Screenshot]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if items.count == 1, let item = items.first, item.kind == .image,
           let type = item.contentType, let data = try? Data(contentsOf: item.url) {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
            pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            pasteboard.writeObjects([pasteboardItem])
        } else {
            pasteboard.writeObjects(items.map { $0.url as NSURL })
        }
    }

    static func moveToTrash(_ entries: [LibraryEntry], completion: @escaping () -> Void) {
        let urls = entries.map(\.url)
        NSWorkspace.shared.recycle(urls) { trashed, error in
            DispatchQueue.main.async {
                if let error {
                    NSApp.presentError(error)
                }
                Favorites.shared.remove(Array(trashed.keys))
                completion()
            }
        }
    }

    static func toggleFavorite(_ entries: [LibraryEntry]) {
        Favorites.shared.toggle(entries.map(\.url))
    }

    /// Applications that can open every one of `items`, default app first.
    static func applications(toOpen items: [Screenshot]) -> [URL] {
        guard let first = items.first else { return [] }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first.url)
        for item in items.dropFirst() {
            let other = Set(NSWorkspace.shared.urlsForApplications(toOpen: item.url))
            apps.removeAll { !other.contains($0) }
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.lastPathComponent).inserted }
    }

    // MARK: - Groups (subfolders)

    /// Creates a subfolder of `root` named `name` and moves `items` into it.
    /// Folders in `emptiedFolders` are deleted if nothing is left in them.
    /// Returns the new folder.
    static func group(_ items: [Screenshot], named name: String, in root: URL,
                      emptiedFolders: [URL]) throws -> URL {
        let fileManager = FileManager.default
        let folder = uniqueURL(in: root, name: name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)

        var moves: [(from: URL, to: URL)] = []
        defer {
            Favorites.shared.move(moves)
            emptiedFolders.forEach(removeIfEmpty)
        }
        for item in items {
            let destination = uniqueURL(in: folder, name: item.url.lastPathComponent, isDirectory: false)
            try fileManager.moveItem(at: item.url, to: destination)
            moves.append((item.url, destination))
        }
        return folder
    }

    /// Moves everything in `folders` back to `root` and deletes the emptied folders.
    /// Returns the new locations of the moved screenshots.
    static func ungroup(_ folders: [ScreenshotFolder], into root: URL) throws -> [URL] {
        var moves: [(from: URL, to: URL)] = []
        defer {
            Favorites.shared.move(moves)
            Favorites.shared.remove(folders.map(\.url))
            folders.map(\.url).forEach(removeIfEmpty)
        }
        for folder in folders {
            for item in folder.items {
                let destination = uniqueURL(in: root, name: item.url.lastPathComponent, isDirectory: false)
                try FileManager.default.moveItem(at: item.url, to: destination)
                moves.append((item.url, destination))
            }
        }
        return moves.map(\.to)
    }

    /// Renames a group's folder. Returns its new URL.
    static func rename(_ folder: ScreenshotFolder, to name: String) throws -> URL {
        let parent = folder.url.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard destination.pathKey != folder.url.pathKey else { return folder.url }

        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = destination.pathKey.lowercased() == folder.url.pathKey.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [
                NSLocalizedDescriptionKey: "A folder named “\(name)” already exists.",
                NSLocalizedRecoverySuggestionErrorKey: "Choose a different name.",
            ])
        }
        try FileManager.default.moveItem(at: folder.url, to: destination)
        Favorites.shared.move([(folder.url, destination)])
        return destination
    }

    /// Turns user input into a valid folder name, or nil if nothing usable is left.
    static func sanitizedFolderName(_ input: String) -> String? {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(255))
    }

    /// `name` in `folder`, or "name 2", "name 3"… if it is taken.
    private static func uniqueURL(in folder: URL, name: String, isDirectory: Bool) -> URL {
        let base = isDirectory ? name : (name as NSString).deletingPathExtension
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name, isDirectory: isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(number)"
            candidate = folder.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)",
                                                      isDirectory: isDirectory)
            number += 1
        }
        return candidate
    }

    /// Deletes `folder` if it only contains Finder metadata.
    private static func removeIfEmpty(_ folder: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: folder.path),
              contents.allSatisfy({ $0 == ".DS_Store" })
        else { return }
        try? fileManager.removeItem(at: folder)
    }
}

/// Asks for a group name in a sheet.
enum NamePrompt {
    static func run(title: String, message: String, defaultName: String, confirmTitle: String,
                    window: NSWindow, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(ScreenshotActions.sanitizedFolderName(field.stringValue) ?? defaultName)
        }
        field.selectText(nil)
    }
}
