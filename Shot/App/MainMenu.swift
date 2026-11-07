import AppKit

enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(appMenu()))
        mainMenu.addItem(submenu(fileMenu()))
        mainMenu.addItem(submenu(editMenu()))
        mainMenu.addItem(submenu(viewMenu()))

        let window = windowMenu()
        mainMenu.addItem(submenu(window))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        mainMenu.addItem(submenu(help))
        NSApp.helpMenu = help

        return mainMenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open", #selector(MainWindowController.openSelection(_:)), "o"))
        menu.addItem(item("Quick Look", #selector(MainWindowController.toggleQuickLook(_:)), "y"))
        menu.addItem(item("Show in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Add to Favorites", #selector(MainWindowController.toggleFavorite(_:)), ".", []))
        menu.addItem(.separator())
        menu.addItem(item("Group Selection…", #selector(MainWindowController.groupSelection(_:)), "g"))
        menu.addItem(item("Ungroup", #selector(MainWindowController.ungroupSelection(_:)), "g", [.command, .shift]))
        menu.addItem(item("Rename Group…", #selector(MainWindowController.renameGroup(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Change Folder…", #selector(AppDelegate.chooseFolder(_:)), "o", [.command, .shift]))
        menu.addItem(item("Show Folder in Finder", #selector(MainWindowController.revealFolderInFinder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Move to Trash", #selector(MainWindowController.moveToTrash(_:)), "\u{8}"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find…", #selector(MainWindowController.focusSearch(_:)), "f"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("All Screenshots", #selector(MainWindowController.showAllItems(_:)), "1"))
        menu.addItem(item("Favorites", #selector(MainWindowController.showFavoritesOnly(_:)), "2"))
        menu.addItem(.separator())

        let sort = NSMenu(title: "Sort By")
        ViewOptionsMenu.sortItems().forEach(sort.addItem)
        menu.addItem(submenu(sort))

        let group = NSMenu(title: "Group By")
        ViewOptionsMenu.groupingItems().forEach(group.addItem)
        menu.addItem(submenu(group))

        let show = NSMenu(title: "Show")
        ViewOptionsMenu.kindItems().forEach(show.addItem)
        menu.addItem(submenu(show))

        menu.addItem(.separator())
        menu.addItem(ViewOptionsMenu.thumbnailsItem())
        menu.addItem(.separator())
        menu.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Screenshots", #selector(AppDelegate.showMainWindow(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

/// Sort, group and filter menu items, shared by the View menu and the toolbar.
enum ViewOptionsMenu {
    static func sortItems() -> [NSMenuItem] {
        var items = SortKey.allCases.map { key in
            let item = NSMenuItem(title: key.title, action: #selector(MainWindowController.setSortKey(_:)), keyEquivalent: "")
            item.representedObject = key.rawValue
            return item
        }
        items.append(.separator())
        // Titles are updated during validation to match the sort key ("Newest First", "A to Z"…).
        for tag in [1, 0] {
            let item = NSMenuItem(title: tag == 1 ? "Ascending" : "Descending",
                                  action: #selector(MainWindowController.setSortOrder(_:)), keyEquivalent: "")
            item.tag = tag
            items.append(item)
        }
        return items
    }

    static func groupingItems() -> [NSMenuItem] {
        Grouping.allCases.map { grouping in
            let item = NSMenuItem(title: grouping.title, action: #selector(MainWindowController.setGrouping(_:)), keyEquivalent: "")
            item.representedObject = grouping.rawValue
            return item
        }
    }

    static func kindItems() -> [NSMenuItem] {
        KindFilter.allCases.map { filter in
            let item = NSMenuItem(title: filter.title, action: #selector(MainWindowController.setKindFilter(_:)), keyEquivalent: "")
            item.representedObject = filter.rawValue
            return item
        }
    }

    static func thumbnailsItem() -> NSMenuItem {
        NSMenuItem(title: "Show Thumbnails", action: #selector(MainWindowController.toggleThumbnails(_:)), keyEquivalent: "")
    }

    static func toolbarMenu() -> NSMenu {
        let menu = NSMenu(title: "View Options")
        menu.addItem(.sectionHeader(title: "Sort By"))
        sortItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Group By"))
        groupingItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Show"))
        kindItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(thumbnailsItem())
        return menu
    }
}
