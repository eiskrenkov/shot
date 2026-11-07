import AppKit

/// Outline view that supports dragging out of a background window (like Finder)
/// and Quick Look on the space bar.
final class SidebarOutlineView: NSOutlineView {
    fileprivate var didBeginDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let wasInBackground = !(NSApp.isActive && window?.isKeyWindow == true)
        didBeginDrag = false
        if wasInBackground {
            // Don't bring the window forward yet: the click might be the start of a drag.
            NSApp.preventWindowOrdering()
        }
        super.mouseDown(with: event)  // Tracks until mouse up or until a drag begins.
        if wasInBackground && !didBeginDrag {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers == " " && modifiers.isEmpty {
            NSApp.sendAction(#selector(MainWindowController.toggleQuickLook(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: event)
    }

    /// Group rows draw their own chevron.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        item(atRow: row) is ScreenshotFolder ? .zero : super.frameOfOutlineCell(atRow: row)
    }
}

final class SidebarViewController: NSViewController {
    let library: ScreenshotLibrary

    var onSelectionChange: (([LibraryEntry]) -> Void)?
    var onContentChange: ((ListContent) -> Void)?

    var searchQuery = "" {
        didSet { if oldValue != searchQuery { rebuild() } }
    }

    let outlineView = SidebarOutlineView()

    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private var content = ListContent.empty
    private var collapsedGroupIDs = Set<String>()
    /// Groups (folders) the user expanded, by `URL.pathKey`.
    private var expandedFolders = Set<String>()
    private var isReloading = false
    private var needsInitialSelection = true
    private var urlsToSelectAfterReload: [URL]?
    private var lastReportedSelection: [URL] = []
    private var contextMenuTargets: [LibraryEntry] = []

    /// Selected rows: screenshots and groups.
    var selectedEntries: [LibraryEntry] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? LibraryEntry }
    }

    /// Selected screenshots, with selected groups replaced by their (visible) contents.
    var selectedScreenshots: [Screenshot] {
        Screenshot.flatten(selectedEntries)
    }

    var selectedFolders: [ScreenshotFolder] {
        selectedEntries.compactMap { $0 as? ScreenshotFolder }
    }

    init(library: ScreenshotLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - View

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Screenshot"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.floatsGroupRows = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 0
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask([], forLocal: true)
        outlineView.setAccessibilityLabel("Screenshots")

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(libraryDidChange), name: ScreenshotLibrary.didChange, object: library)
        center.addObserver(self, selector: #selector(preferencesDidChange), name: Preferences.didChange, object: nil)
        center.addObserver(self, selector: #selector(folderDidChange), name: Preferences.folderDidChange, object: nil)
        center.addObserver(self, selector: #selector(favoritesDidChange), name: Favorites.didChange, object: nil)
        rebuild()
    }

    // MARK: - Observing

    @objc private func libraryDidChange() { rebuild() }
    @objc private func preferencesDidChange() { rebuild() }

    @objc private func folderDidChange() {
        needsInitialSelection = true
        expandedFolders.removeAll()
        outlineView.deselectAll(nil)
    }

    @objc private func favoritesDidChange() {
        if Preferences.shared.favoritesOnly {
            rebuild()
        } else {
            outlineView.enumerateAvailableRowViews { rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? SidebarEntryCell,
                      let entry = outlineView.item(atRow: row) as? LibraryEntry
                else { return }
                cell.setFavorite(Favorites.shared.contains(entry.url))
            }
        }
    }

    // MARK: - Content

    func rebuild() {
        guard isViewLoaded else { return }

        // Selects requested items as soon as they show up (e.g. a group that was just created),
        // otherwise keeps the current selection.
        var wanted = selectedEntries.map(\.url)
        let pending = urlsToSelectAfterReload

        content = ListBuilder.build(
            screenshots: library.items, folders: library.folders, query: searchQuery,
            preferences: .shared, favorites: .shared
        )

        if let pending, pending.contains(where: { content.lookup[$0.pathKey] != nil }) {
            wanted = pending
            urlsToSelectAfterReload = nil
            // Show selected screenshots that are inside a group.
            for url in pending {
                let parent = url.deletingLastPathComponent().pathKey
                if content.lookup[parent] is ScreenshotFolder {
                    expandedFolders.insert(parent)
                }
            }
        }

        isReloading = true
        outlineView.reloadData()
        if content.isGrouped {
            for group in content.sections where !collapsedGroupIDs.contains(group.id) {
                outlineView.expandItem(group)
            }
        }
        // Expand every group while searching, so matches are visible.
        let searching = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        for case let folder as ScreenshotFolder in content.entries
        where searching || expandedFolders.contains(folder.url.pathKey) {
            outlineView.expandItem(folder)
        }

        var rows = IndexSet()
        for url in wanted {
            guard let entry = content.lookup[url.pathKey] else { continue }
            let row = outlineView.row(forItem: entry)
            if row >= 0 { rows.insert(row) }
        }

        var scrollToTop = false
        if needsInitialSelection && library.isLoaded {
            needsInitialSelection = false
            scrollToTop = true
            if rows.isEmpty, let first = content.entries.first {
                let row = outlineView.row(forItem: first)
                if row >= 0 { rows.insert(row) }
            }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if scrollToTop, outlineView.numberOfRows > 0 {
            outlineView.scrollRowToVisible(0)
        } else if wanted == pending, let first = rows.first {
            outlineView.scrollRowToVisible(first)
        }
        isReloading = false

        updateEmptyState()
        // Always report: a selected group's contents may have changed.
        reportSelection(force: true)
        onContentChange?(content)
    }

    private func updateEmptyState() {
        let prefs = Preferences.shared
        let folderName = FileManager.default.displayName(atPath: library.folderURL.path)

        if library.isLoaded && !library.folderExists {
            emptyState.configure(
                title: "Folder Not Found",
                message: "“\(folderName)” doesn’t exist or can’t be opened.",
                buttonTitle: "Choose Folder…",
                action: { [weak self] in FolderPicker.run(attachedTo: self?.view.window) }
            )
        } else if !library.isLoaded || !content.entries.isEmpty {
            emptyState.isHidden = true
            return
        } else if library.screenshotCount == 0 {
            emptyState.configure(
                title: "No Screenshots",
                message: "Screenshots saved to “\(folderName)” will appear here."
            )
        } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState.configure(title: "No Results", message: "Nothing matches “\(searchQuery)”.")
        } else if prefs.favoritesOnly {
            emptyState.configure(
                title: "No Favorites",
                message: "Click the heart next to a screenshot or group to add it to your favorites.",
                buttonTitle: "Show All",
                action: { Preferences.shared.favoritesOnly = false }
            )
        } else {
            emptyState.configure(
                title: "No \(prefs.kindFilter.title)",
                message: nil,
                buttonTitle: "Show All Items",
                action: { Preferences.shared.kindFilter = .all }
            )
        }
        emptyState.isHidden = false
    }

    private func reportSelection(force: Bool = false) {
        let selection = selectedEntries
        let urls = selection.map(\.url)
        guard force || urls != lastReportedSelection else { return }
        lastReportedSelection = urls
        onSelectionChange?(selection)
    }

    // MARK: - Selection helpers

    func select(_ urls: [URL]) {
        var rows = IndexSet()
        for url in urls {
            guard let entry = content.lookup[url.pathKey] else { continue }
            let row = outlineView.row(forItem: entry)
            if row >= 0 { rows.insert(row) }
        }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { outlineView.scrollRowToVisible(first) }
    }

    /// Selects `urls` (and expands the group they are in) once they appear after the next reload.
    func selectAfterReload(_ urls: [URL]) {
        urlsToSelectAfterReload = urls
    }

    /// Expands the group at `url` once it appears.
    func expandFolder(at url: URL) {
        expandedFolders.insert(url.pathKey)
    }

    /// Remembers which row to select once `urls` disappear from the folder.
    func prepareForRemoval(of urls: Set<URL>) {
        let selected = outlineView.selectedRowIndexes
        guard let last = selected.last else { return }
        let removed = Set(urls.map(\.pathKey))

        func candidate(in rows: some Sequence<Int>) -> LibraryEntry? {
            for row in rows {
                guard let entry = outlineView.item(atRow: row) as? LibraryEntry,
                      !removed.contains(entry.url.pathKey),
                      !removed.contains(entry.url.deletingLastPathComponent().pathKey)
                else { continue }
                return entry
            }
            return nil
        }
        let next = candidate(in: (last + 1)..<outlineView.numberOfRows)
            ?? candidate(in: stride(from: (selected.first ?? 0) - 1, through: 0, by: -1))
        urlsToSelectAfterReload = next.map { [$0.url] }
    }

    /// Screen frame of an item's thumbnail, used for the Quick Look zoom animation.
    func screenFrame(for url: URL) -> NSRect? {
        guard let entry = content.lookup[url.pathKey] else { return nil }
        let row = outlineView.row(forItem: entry)
        guard row >= 0, let window = view.window else { return nil }
        let rowRect = outlineView.rect(ofRow: row)
        guard outlineView.visibleRect.intersects(rowRect) else { return nil }
        let indent: CGFloat = outlineView.parent(forItem: entry) is ScreenshotFolder ? 20 : 0
        let thumbRect = NSRect(x: rowRect.minX + 4 + indent, y: rowRect.midY - 15, width: 42, height: 30)
        return window.convertToScreen(outlineView.convert(thumbRect, to: nil))
    }

    func focusList() {
        view.window?.makeFirstResponder(outlineView)
        if outlineView.selectedRowIndexes.isEmpty, let first = content.entries.first {
            select([first.url])
        }
    }

    private func toggleExpanded(_ folder: ScreenshotFolder) {
        if outlineView.isItemExpanded(folder) {
            outlineView.collapseItem(folder)
        } else {
            outlineView.expandItem(folder)
        }
    }

    // MARK: - Actions

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        switch outlineView.item(atRow: row) {
        case let folder as ScreenshotFolder: toggleExpanded(folder)
        case let item as Screenshot: ScreenshotActions.open([item])
        default: break
        }
    }

    private var contextScreenshots: [Screenshot] { Screenshot.flatten(contextMenuTargets) }

    @objc private func contextOpen(_ sender: Any?) { ScreenshotActions.open(contextScreenshots) }

    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        ScreenshotActions.open(contextScreenshots, withApplicationAt: app)
    }

    @objc private func contextQuickLook(_ sender: Any?) {
        sendToWindow(#selector(MainWindowController.showQuickLook(_:)))
    }

    @objc private func contextReveal(_ sender: Any?) { ScreenshotActions.revealInFinder(contextMenuTargets) }
    @objc private func contextCopy(_ sender: Any?) { ScreenshotActions.copy(contextScreenshots) }
    @objc private func contextToggleFavorite(_ sender: Any?) { ScreenshotActions.toggleFavorite(contextMenuTargets) }
    @objc private func contextGroup(_ sender: Any?) { sendToWindow(#selector(MainWindowController.groupSelection(_:))) }
    @objc private func contextUngroup(_ sender: Any?) { sendToWindow(#selector(MainWindowController.ungroupSelection(_:))) }
    @objc private func contextRename(_ sender: Any?) { sendToWindow(#selector(MainWindowController.renameGroup(_:))) }

    @objc private func contextTrash(_ sender: Any?) {
        let targets = contextMenuTargets
        prepareForRemoval(of: Set(targets.map(\.url)))
        ScreenshotActions.moveToTrash(targets) { [weak self] in self?.library.reload() }
    }

    /// Selects the context menu's targets and performs a window-level action on them.
    private func sendToWindow(_ action: Selector) {
        select(contextMenuTargets.map(\.url))
        NSApp.sendAction(action, to: nil, from: self)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case let group as ScreenshotGroup: group.entries.count
        case let folder as ScreenshotFolder: folder.items.count
        case nil: content.isGrouped ? content.sections.count : content.entries.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let group as ScreenshotGroup: group.entries[index]
        case let folder as ScreenshotFolder: folder.items[index]
        default: content.isGrouped ? content.sections[index] : content.entries[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ScreenshotGroup || item is ScreenshotFolder
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = item as? LibraryEntry else { return nil }
        return entry.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        self.outlineView.didBeginDrag = true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is ScreenshotGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is LibraryEntry
    }

    func outlineView(_ outlineView: NSOutlineView,
                     selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        proposedSelectionIndexes.filteredIndexSet { outlineView.item(atRow: $0) is LibraryEntry }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is ScreenshotGroup { return 28 }
        return Preferences.shared.showThumbnails ? 44 : 36
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let prefs = Preferences.shared
        switch item {
        case let group as ScreenshotGroup:
            let cell = outlineView.makeView(withIdentifier: GroupHeaderCellView.identifier, owner: self)
                as? GroupHeaderCellView ?? GroupHeaderCellView()
            cell.configure(title: group.title, count: group.screenshotCount)
            return cell

        case let folder as ScreenshotFolder:
            let cell = outlineView.makeView(withIdentifier: FolderCellView.identifier, owner: self)
                as? FolderCellView ?? FolderCellView()
            cell.configure(
                with: folder,
                isFavorite: Favorites.shared.contains(folder.url),
                isExpanded: outlineView.isItemExpanded(folder),
                showsThumbnail: prefs.showThumbnails
            )
            cell.onToggleFavorite = { ScreenshotActions.toggleFavorite([folder]) }
            cell.onToggleExpanded = { [weak self] in self?.toggleExpanded(folder) }
            return cell

        case let item as Screenshot:
            let cell = outlineView.makeView(withIdentifier: ScreenshotCellView.identifier, owner: self)
                as? ScreenshotCellView ?? ScreenshotCellView()
            cell.configure(
                with: item,
                isFavorite: Favorites.shared.contains(item.url),
                showsThumbnail: prefs.showThumbnails,
                showsDate: prefs.grouping != .day || outlineView.parent(forItem: item) is ScreenshotFolder,
                isNested: outlineView.parent(forItem: item) is ScreenshotFolder
            )
            cell.onToggleFavorite = { ScreenshotActions.toggleFavorite([item]) }
            return cell

        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is LibraryEntry else { return nil }
        return outlineView.makeView(withIdentifier: HoverRowView.identifier, owner: self) as? HoverRowView
            ?? { let row = HoverRowView(); row.identifier = HoverRowView.identifier; return row }()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        reportSelection()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        let item = notification.userInfo?["NSObject"]
        if let folder = item as? ScreenshotFolder {
            folderCell(for: folder)?.setExpanded(true)
            if !isReloading { expandedFolders.insert(folder.url.pathKey) }
        } else if let group = item as? ScreenshotGroup, !isReloading {
            collapsedGroupIDs.remove(group.id)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        let item = notification.userInfo?["NSObject"]
        if let folder = item as? ScreenshotFolder {
            folderCell(for: folder)?.setExpanded(false)
            if !isReloading { expandedFolders.remove(folder.url.pathKey) }
        } else if let group = item as? ScreenshotGroup, !isReloading {
            collapsedGroupIDs.insert(group.id)
        }
        if !isReloading { reportSelection() }
    }

    private func folderCell(for folder: ScreenshotFolder) -> FolderCellView? {
        let row = outlineView.row(forItem: folder)
        guard row >= 0 else { return nil }
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FolderCellView
    }
}

// MARK: - Context menu

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clicked = outlineView.clickedRow
        if clicked >= 0, let entry = outlineView.item(atRow: clicked) as? LibraryEntry {
            contextMenuTargets = outlineView.selectedRowIndexes.contains(clicked) ? selectedEntries : [entry]
        } else {
            contextMenuTargets = []
        }
        let targets = contextMenuTargets
        guard !targets.isEmpty else { return }
        let screenshots = contextScreenshots
        let folders = targets.compactMap { $0 as? ScreenshotFolder }

        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        if !screenshots.isEmpty {
            _ = add("Open", #selector(contextOpen(_:)))

            let apps = ScreenshotActions.applications(toOpen: screenshots)
            if !apps.isEmpty {
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for app in apps {
                    let appItem = NSMenuItem(
                        title: FileManager.default.displayName(atPath: app.path),
                        action: #selector(contextOpenWith(_:)), keyEquivalent: ""
                    )
                    appItem.target = self
                    appItem.representedObject = app
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    appItem.image = icon
                    submenu.addItem(appItem)
                }
                openWith.submenu = submenu
                menu.addItem(openWith)
            }

            _ = add("Quick Look", #selector(contextQuickLook(_:)))
        }
        _ = add("Show in Finder", #selector(contextReveal(_:)))
        menu.addItem(.separator())

        let allFavorite = Favorites.shared.allFavorite(targets.map(\.url))
        _ = add(allFavorite ? "Remove from Favorites" : "Add to Favorites", #selector(contextToggleFavorite(_:)))
        menu.addItem(.separator())

        if !screenshots.isEmpty {
            _ = add(MainWindowController.groupTitle(count: screenshots.count), #selector(contextGroup(_:)))
        }
        if !folders.isEmpty {
            _ = add("Ungroup", #selector(contextUngroup(_:)))
        }
        if folders.count == 1 && targets.count == 1 {
            _ = add("Rename…", #selector(contextRename(_:)))
        }
        menu.addItem(.separator())

        if !screenshots.isEmpty {
            _ = add("Copy", #selector(contextCopy(_:)))
            let share = NSSharingServicePicker(items: screenshots.map(\.url)).standardShareMenuItem
            menu.addItem(share)
            menu.addItem(.separator())
        }

        _ = add("Move to Trash", #selector(contextTrash(_:)))
    }
}
