import AppKit

final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.contentViewController = SettingsViewController()
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SettingsViewController: NSViewController {
    private let pathControl = NSPathControl()
    private let useSystemButton = NSButton(title: "Use System Screenshot Location", target: nil, action: nil)
    private let systemLocationField = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let label = NSTextField(labelWithString: "Screenshots folder:")

        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.backgroundColor = .clear
        pathControl.target = self
        pathControl.doubleAction = #selector(pathDoubleClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder(_:)))
        useSystemButton.target = self
        useSystemButton.action = #selector(useSystemLocation(_:))

        let buttons = NSStackView(views: [chooseButton, useSystemButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        systemLocationField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        systemLocationField.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label, pathControl],
            [NSGridCell.emptyContentView, buttons],
            [NSGridCell.emptyContentView, systemLocationField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 0).rowAlignment = .none
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            pathControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            systemLocationField.widthAnchor.constraint(equalTo: pathControl.widthAnchor),
        ])
        view = root

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Preferences.folderDidChange, object: nil)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()  // The system location may have changed in the Screenshot app.
    }

    @objc private func refresh() {
        let folder = Preferences.shared.folderURL
        pathControl.url = folder

        if let system = Preferences.systemScreenshotFolderURL {
            let path = (system.path as NSString).abbreviatingWithTildeInPath
            systemLocationField.stringValue = "macOS saves new screenshots to \(path)."
            useSystemButton.isEnabled = system.standardizedFileURL != folder.standardizedFileURL
        } else {
            systemLocationField.stringValue = "macOS saves new screenshots to the Desktop."
            useSystemButton.isEnabled = true
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        FolderPicker.run(attachedTo: view.window)
    }

    @objc private func useSystemLocation(_ sender: Any?) {
        Preferences.shared.folderURL = Preferences.systemScreenshotFolderURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    @objc private func pathDoubleClicked(_ sender: NSPathControl) {
        if let url = sender.clickedPathItem?.url ?? sender.url {
            NSWorkspace.shared.open(url)
        }
    }
}
