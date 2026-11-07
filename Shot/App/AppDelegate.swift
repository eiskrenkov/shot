import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var library: ScreenshotLibrary!
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        library = ScreenshotLibrary(folderURL: Preferences.shared.folderURL)
        NotificationCenter.default.addObserver(
            self, selector: #selector(folderDidChange),
            name: Preferences.folderDidChange, object: nil
        )
        showMainWindow(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    @objc private func folderDidChange() {
        library.setFolder(Preferences.shared.folderURL)
    }

    // MARK: - Actions

    @objc func showMainWindow(_ sender: Any?) {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(library: library)
        }
        mainWindowController?.showWindow(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func chooseFolder(_ sender: Any?) {
        FolderPicker.run(attachedTo: mainWindowController?.window)
    }
}

enum FolderPicker {
    static func run(attachedTo window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder that contains your screenshots."
        panel.directoryURL = Preferences.shared.folderURL

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Preferences.shared.folderURL = url
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}
