import AppKit
import Quartz

final class MainSplitViewController: NSSplitViewController {
    let sidebar: SidebarViewController
    let preview = PreviewViewController()

    init(library: ScreenshotLibrary) {
        sidebar = SidebarViewController(library: library)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 700
        sidebarItem.canCollapse = true

        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 320

        addSplitViewItem(sidebarItem)
        addSplitViewItem(previewItem)

        // Remembers the sidebar width between launches.
        hasSavedLayout = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.autosaveName)") != nil
        splitView.autosaveName = Self.autosaveName
    }

    private static let autosaveName = "MainSplitView"
    private var hasSavedLayout = true

    override func viewDidAppear() {
        super.viewDidAppear()
        if !hasSavedLayout {
            hasSavedLayout = true
            splitView.setPosition(330, ofDividerAt: 0)
        }
    }
}

extension NSToolbarItem.Identifier {
    static let filter = Self("Filter")
    static let viewOptions = Self("ViewOptions")
    static let favorite = Self("Favorite")
    static let share = Self("Share")
    static let quickLook = Self("QuickLook")
    static let search = Self("Search")
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let library: ScreenshotLibrary
    private let splitViewController: MainSplitViewController
    private var sidebar: SidebarViewController { splitViewController.sidebar }
    private var preview: PreviewViewController { splitViewController.preview }

    private weak var searchItem: NSSearchToolbarItem?
    private weak var filterItem: NSToolbarItemGroup?

    /// Selected screenshots, including the contents of selected groups.
    private var selection: [Screenshot] { sidebar.selectedScreenshots }
    /// Selected rows: screenshots and groups.
    private var selectedEntries: [LibraryEntry] { sidebar.selectedEntries }

    init(library: ScreenshotLibrary) {
        self.library = library
        splitViewController = MainSplitViewController(library: library)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = splitViewController
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1120, height: 740))

        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")

        sidebar.onSelectionChange = { [weak self] items in self?.selectionDidChange(items) }
        sidebar.onContentChange = { [weak self] content in self?.updateTitle(visibleCount: content.screenshotCount) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(preferencesDidChange), name: Preferences.didChange, object: nil)
        center.addObserver(self, selector: #selector(favoritesDidChange), name: Favorites.didChange, object: nil)

        updateTitle(visibleCount: 0)
        window.initialFirstResponder = sidebar.outlineView
        window.makeFirstResponder(sidebar.outlineView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - State

    private func updateTitle(visibleCount: Int) {
        guard let window else { return }
        let folder = library.folderURL
        window.title = FileManager.default.displayName(atPath: folder.path)
        window.representedURL = library.folderExists ? folder : nil

        let total = library.screenshotCount
        let noun = total == 1 ? "item" : "items"
        if !library.isLoaded {
            window.subtitle = ""
        } else if visibleCount == total {
            window.subtitle = "\(total.formatted()) \(noun)"
        } else {
            window.subtitle = "\(visibleCount.formatted()) of \(total.formatted()) \(noun)"
        }
    }

    private func selectionDidChange(_ entries: [LibraryEntry]) {
        preview.show(entries)
        window?.toolbar?.validateVisibleItems()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    @objc private func preferencesDidChange() {
        filterItem?.selectedIndex = Preferences.shared.favoritesOnly ? 1 : 0
    }

    @objc private func favoritesDidChange() {
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - File actions

    @objc func openSelection(_ sender: Any?) {
        ScreenshotActions.open(selection)
    }

    @objc func revealInFinder(_ sender: Any?) {
        ScreenshotActions.revealInFinder(selectedEntries)
    }

    @objc func revealFolderInFinder(_ sender: Any?) {
        NSWorkspace.shared.open(library.folderURL)
    }

    @objc func copy(_ sender: Any?) {
        ScreenshotActions.copy(selection)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        sidebar.prepareForRemoval(of: Set(entries.map(\.url)))
        ScreenshotActions.moveToTrash(entries) { [weak self] in self?.library.reload() }
    }

    @objc func toggleFavorite(_ sender: Any?) {
        ScreenshotActions.toggleFavorite(selectedEntries)
    }

    // MARK: - Groups

    static func groupTitle(count: Int) -> String {
        count == 1 ? "Group 1 Item…" : "Group \(count.formatted()) Items…"
    }

    /// Moves the selected screenshots (and the contents of selected groups) into a new folder.
    @objc func groupSelection(_ sender: Any?) {
        guard let window, !selection.isEmpty else { return }
        // Move everything in selected groups, not just what the current filter shows.
        let folders = sidebar.selectedFolders.map { library.folder(at: $0.url) ?? $0 }
        let loose = selectedEntries.compactMap { $0 as? Screenshot }
        let items = Screenshot.flatten(loose + folders)
        let noun = items.count == 1 ? "screenshot" : "screenshots"

        NamePrompt.run(
            title: "New Group",
            message: "Move \(items.count.formatted()) \(noun) into a new folder in “\(window.title)”.",
            defaultName: "New Group",
            confirmTitle: "Group",
            window: window
        ) { [weak self] name in
            guard let self else { return }
            do {
                let folder = try ScreenshotActions.group(
                    items, named: name, in: self.library.folderURL, emptiedFolders: folders.map(\.url)
                )
                self.sidebar.expandFolder(at: folder)
                self.sidebar.selectAfterReload([folder])
            } catch {
                self.showError(error)
            }
            self.library.reload()
        }
    }

    /// Moves the contents of the selected groups back to the screenshots folder and deletes them.
    @objc func ungroupSelection(_ sender: Any?) {
        let folders = sidebar.selectedFolders.map { library.folder(at: $0.url) ?? $0 }
        guard !folders.isEmpty else { return }
        do {
            let moved = try ScreenshotActions.ungroup(folders, into: library.folderURL)
            sidebar.selectAfterReload(moved)
        } catch {
            showError(error)
        }
        library.reload()
    }

    @objc func renameGroup(_ sender: Any?) {
        guard let window, selectedEntries.count == 1, let folder = sidebar.selectedFolders.first else { return }
        NamePrompt.run(
            title: "Rename Group",
            message: "Enter a new name for “\(folder.displayName)”.",
            defaultName: folder.url.lastPathComponent,
            confirmTitle: "Rename",
            window: window
        ) { [weak self] name in
            guard let self else { return }
            do {
                let renamed = try ScreenshotActions.rename(folder, to: name)
                self.sidebar.expandFolder(at: renamed)
                self.sidebar.selectAfterReload([renamed])
            } catch {
                self.showError(error)
            }
            self.library.reload()
        }
    }

    private func showError(_ error: Error) {
        guard let window else { NSApp.presentError(error); return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    @objc func focusSearch(_ sender: Any?) {
        if let searchItem {
            searchItem.beginSearchInteraction()
        }
    }

    // MARK: - View options

    @objc func setSortKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        Preferences.shared.sortKey = key
    }

    @objc func setSortOrder(_ sender: NSMenuItem) {
        Preferences.shared.ascending = sender.tag == 1
    }

    @objc func setGrouping(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let grouping = Grouping(rawValue: raw) else { return }
        Preferences.shared.grouping = grouping
    }

    @objc func setKindFilter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let filter = KindFilter(rawValue: raw) else { return }
        Preferences.shared.kindFilter = filter
    }

    @objc func toggleThumbnails(_ sender: Any?) {
        Preferences.shared.showThumbnails.toggle()
    }

    @objc func showAllItems(_ sender: Any?) {
        Preferences.shared.favoritesOnly = false
    }

    @objc func showFavoritesOnly(_ sender: Any?) {
        Preferences.shared.favoritesOnly = true
    }

    @objc private func filterChanged(_ sender: NSToolbarItemGroup) {
        Preferences.shared.favoritesOnly = sender.selectedIndex == 1
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        sidebar.searchQuery = sender.stringValue
    }

    // MARK: - Quick Look

    private var quickLookItems: [Screenshot] = []

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            showQuickLook(sender)
        }
    }

    @objc func showQuickLook(_ sender: Any?) {
        guard !selection.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Quick Look data source

extension MainWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems = selection
        return quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index < quickLookItems.count else { return nil }
        return quickLookItems[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel move the selection in the list.
        guard event.type == .keyDown, quickLookItems.count <= 1 else { return false }
        sidebar.outlineView.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return sidebar.screenFrame(for: url) ?? .zero
    }
}

// MARK: - Validation

extension MainWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let prefs = Preferences.shared
        let hasSelection = !selection.isEmpty
        let hasEntries = !selectedEntries.isEmpty

        switch menuItem.action {
        case #selector(setSortKey(_:)):
            menuItem.state = (menuItem.representedObject as? String) == prefs.sortKey.rawValue ? .on : .off
        case #selector(setSortOrder(_:)):
            let ascending = menuItem.tag == 1
            menuItem.title = ascending ? prefs.sortKey.ascendingTitle : prefs.sortKey.descendingTitle
            menuItem.state = ascending == prefs.ascending ? .on : .off
        case #selector(setGrouping(_:)):
            menuItem.state = (menuItem.representedObject as? String) == prefs.grouping.rawValue ? .on : .off
        case #selector(setKindFilter(_:)):
            menuItem.state = (menuItem.representedObject as? String) == prefs.kindFilter.rawValue ? .on : .off
        case #selector(toggleThumbnails(_:)):
            menuItem.state = prefs.showThumbnails ? .on : .off
        case #selector(showAllItems(_:)):
            menuItem.state = prefs.favoritesOnly ? .off : .on
        case #selector(showFavoritesOnly(_:)):
            menuItem.state = prefs.favoritesOnly ? .on : .off
        case #selector(toggleFavorite(_:)):
            let allFavorite = Favorites.shared.allFavorite(selectedEntries.map(\.url))
            menuItem.title = allFavorite ? "Remove from Favorites" : "Add to Favorites"
            // The shortcut has no modifier, so don't steal it from the search field.
            return hasEntries && !(window?.firstResponder is NSText)
        case #selector(groupSelection(_:)):
            menuItem.title = hasSelection ? Self.groupTitle(count: selection.count) : "Group Selection…"
            return hasSelection && library.folderExists
        case #selector(ungroupSelection(_:)):
            return !sidebar.selectedFolders.isEmpty
        case #selector(renameGroup(_:)):
            return selectedEntries.count == 1 && !sidebar.selectedFolders.isEmpty
        case #selector(revealInFinder(_:)), #selector(moveToTrash(_:)):
            return hasEntries
        case #selector(openSelection(_:)), #selector(copy(_:)),
             #selector(toggleQuickLook(_:)), #selector(showQuickLook(_:)):
            return hasSelection
        case #selector(revealFolderInFinder(_:)):
            return library.folderExists
        default:
            break
        }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .favorite:
            let items = selectedEntries
            let allFavorite = Favorites.shared.allFavorite(items.map(\.url))
            item.image = allFavorite ? Self.filledHeart : .symbol("heart", "Favorite")
            item.label = allFavorite ? "Unfavorite" : "Favorite"
            item.toolTip = allFavorite ? "Remove from Favorites" : "Add to Favorites"
            return !items.isEmpty
        case .share, .quickLook:
            return !selection.isEmpty
        default:
            return true
        }
    }

    private static let filledHeart: NSImage = {
        let base = NSImage.symbol("heart.fill", "Favorite")
        return base.withSymbolConfiguration(.init(paletteColors: [.systemPink])) ?? base
    }()
}

// MARK: - Toolbar

extension MainWindowController: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
         .filter, .viewOptions, .space, .favorite, .share, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .filter, .viewOptions, .favorite, .share,
         .quickLook, .search, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .filter:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                titles: ["All", "Favorites"],
                selectionMode: .selectOne,
                labels: ["All", "Favorites"],
                target: self,
                action: #selector(filterChanged(_:))
            )
            group.label = "Show"
            group.paletteLabel = "All / Favorites"
            group.toolTip = "Show all screenshots or only favorites"
            group.subitems.first?.toolTip = "All Screenshots"
            group.subitems.last?.toolTip = "Favorites"
            group.selectedIndex = Preferences.shared.favoritesOnly ? 1 : 0
            filterItem = group
            return group

        case .viewOptions:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = .symbol("line.3.horizontal.decrease.circle", "View Options")
            item.label = "View Options"
            item.paletteLabel = "Sort, Group & Filter"
            item.toolTip = "Sort, group and filter screenshots"
            item.menu = ViewOptionsMenu.toolbarMenu()
            return item

        case .favorite:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = .symbol("heart", "Favorite")
            item.label = "Favorite"
            item.paletteLabel = "Favorite"
            item.toolTip = "Add to Favorites"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleFavorite(_:))
            return item

        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Share"
            item.toolTip = "Share"
            item.delegate = self
            return item

        case .quickLook:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = .symbol("eye", "Quick Look")
            item.label = "Quick Look"
            item.toolTip = "Quick Look"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleQuickLook(_:))
            return item

        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item

        default:
            return nil
        }
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        selection.map(\.url)
    }

    /// Down arrow / Return in the search field moves focus to the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            sidebar.focusList()
            return true
        default:
            return false
        }
    }
}
