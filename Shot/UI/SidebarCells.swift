import AppKit

/// A sidebar row that reacts to the pointer hovering over it.
protocol SidebarEntryCell: NSTableCellView {
    var isHovered: Bool { get set }
    func setFavorite(_ favorite: Bool)
}

/// The heart shown at the end of a row: always visible for favorites, otherwise on hover.
final class FavoriteHeartButton: NSButton {
    var isFavorite = false { didSet { update() } }
    var isHovered = false { didSet { update() } }
    var isEmphasized = false { didSet { update() } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 12, weight: .medium)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update() {
        image = .symbol(isFavorite ? "heart.fill" : "heart", "Favorite")
        alphaValue = isFavorite || isHovered ? 1 : 0
        if isFavorite {
            contentTintColor = isEmphasized ? .white : .systemPink
        } else {
            contentTintColor = isEmphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
                : .tertiaryLabelColor
        }
        toolTip = isFavorite ? "Remove from Favorites" : "Add to Favorites"
        setAccessibilityLabel(toolTip)
    }
}

/// Leading padding for screenshots shown inside an expanded group.
private let nestedIndent: CGFloat = 20

/// A screenshot row: thumbnail, file name, time/size, and a favorite heart.
final class ScreenshotCellView: NSTableCellView, SidebarEntryCell {
    static let identifier = NSUserInterfaceItemIdentifier("ScreenshotCell")

    var onToggleFavorite: (() -> Void)?

    var isHovered = false {
        didSet { heartButton.isHovered = isHovered }
    }

    private let thumbnailView = ThumbnailView()
    private let videoBadge = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let heartButton = FavoriteHeartButton()
    private var leadingConstraint: NSLayoutConstraint!
    private var representedURL: URL?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = nameField

        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        videoBadge.image = .symbol("video.fill", "Screen recording")
        videoBadge.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        videoBadge.contentTintColor = .white
        videoBadge.wantsLayer = true
        videoBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        videoBadge.layer?.cornerRadius = 3
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.addSubview(videoBadge)

        heartButton.target = self
        heartButton.action = #selector(heartClicked)

        let textStack = NSStackView(views: [nameField, detailField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [thumbnailView, textStack, heartButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        leadingConstraint = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            leadingConstraint,
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 42),
            thumbnailView.heightAnchor.constraint(equalToConstant: 30),
            videoBadge.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -2),
            videoBadge.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -2),
            videoBadge.widthAnchor.constraint(equalToConstant: 14),
            videoBadge.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: Screenshot, isFavorite: Bool, showsThumbnail: Bool, showsDate: Bool,
                   isNested: Bool) {
        representedURL = item.url
        nameField.stringValue = item.displayName
        toolTip = item.url.lastPathComponent
        leadingConstraint.constant = isNested ? 2 + nestedIndent : 2

        var parts: [String] = []
        if item.kind == .video { parts.append("Recording") }
        parts.append(showsDate ? DateText.shortDateTimeString(item.creationDate) : DateText.timeString(item.creationDate))
        parts.append(DateText.byteCount(item.fileSize))
        detailField.stringValue = parts.joined(separator: " · ")

        thumbnailView.isHidden = !showsThumbnail
        videoBadge.isHidden = item.kind != .video
        if showsThumbnail {
            thumbnailView.image = ThumbnailProvider.shared.cachedThumbnail(for: item, side: ThumbnailProvider.Side.list)
            if thumbnailView.image == nil {
                let url = item.url
                ThumbnailProvider.shared.thumbnail(
                    for: item, side: ThumbnailProvider.Side.list,
                    scale: window?.backingScaleFactor ?? 2
                ) { [weak self] image in
                    guard let self, self.representedURL == url else { return }
                    self.thumbnailView.image = image
                }
            }
        }

        setFavorite(isFavorite)
    }

    func setFavorite(_ favorite: Bool) {
        heartButton.isFavorite = favorite
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            detailField.textColor = backgroundStyle == .emphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
                : .secondaryLabelColor
            heartButton.isEmphasized = backgroundStyle == .emphasized
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        thumbnailView.image = nil
        representedURL = nil
    }

    @objc private func heartClicked() {
        onToggleFavorite?()
    }
}

/// A group (folder) row: disclosure chevron, folder icon, name, item count, and a favorite heart.
final class FolderCellView: NSTableCellView, SidebarEntryCell {
    static let identifier = NSUserInterfaceItemIdentifier("FolderCell")

    var onToggleFavorite: (() -> Void)?
    var onToggleExpanded: (() -> Void)?

    var isHovered = false {
        didSet { heartButton.isHovered = isHovered }
    }

    private let chevronButton = NSButton()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let heartButton = FavoriteHeartButton()
    private var iconWidth: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        chevronButton.isBordered = false
        chevronButton.bezelStyle = .regularSquare
        chevronButton.imagePosition = .imageOnly
        chevronButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.target = self
        chevronButton.action = #selector(chevronClicked)
        chevronButton.refusesFirstResponder = true

        iconView.image = .symbol("folder.fill", "Group")
        iconView.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        iconView.contentTintColor = .systemBlue
        iconView.imageScaling = .scaleProportionallyDown

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = nameField

        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        heartButton.target = self
        heartButton.action = #selector(heartClicked)

        let textStack = NSStackView(views: [nameField, detailField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        // The chevron sits in the thumbnail column's left edge so names line up with screenshot rows.
        let iconContainer = NSView()
        for subview in [chevronButton, iconView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.addSubview(subview)
        }

        let row = NSStackView(views: [iconContainer, textStack, heartButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        iconWidth = iconContainer.widthAnchor.constraint(equalToConstant: 42)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconContainer.heightAnchor.constraint(equalToConstant: 30),
            chevronButton.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            chevronButton.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 14),
            chevronButton.heightAnchor.constraint(equalToConstant: 20),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
        ])
        setExpanded(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with folder: ScreenshotFolder, isFavorite: Bool, isExpanded: Bool, showsThumbnail: Bool) {
        nameField.stringValue = folder.displayName
        toolTip = folder.url.lastPathComponent
        detailField.stringValue = DateText.itemCount(folder.items.count) + " · " + DateText.byteCount(folder.totalSize)
        iconView.symbolConfiguration = .init(pointSize: showsThumbnail ? 20 : 14, weight: .regular)
        iconWidth.constant = showsThumbnail ? 42 : 34
        setExpanded(isExpanded)
        setFavorite(isFavorite)
        setAccessibilityLabel("Group \(folder.displayName), \(DateText.itemCount(folder.items.count))")
    }

    func setExpanded(_ expanded: Bool) {
        chevronButton.image = .symbol(expanded ? "chevron.down" : "chevron.right", expanded ? "Collapse" : "Expand")
        chevronButton.toolTip = expanded ? "Collapse" : "Expand"
    }

    func setFavorite(_ favorite: Bool) {
        heartButton.isFavorite = favorite
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            let secondary = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
            detailField.textColor = emphasized ? secondary : .secondaryLabelColor
            chevronButton.contentTintColor = emphasized ? secondary : .secondaryLabelColor
            iconView.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .systemBlue
            heartButton.isEmphasized = emphasized
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    @objc private func heartClicked() { onToggleFavorite?() }
    @objc private func chevronClicked() { onToggleExpanded?() }
}

/// A date section header.
final class GroupHeaderCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GroupHeaderCell")

    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField

        countField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countField.textColor = .tertiaryLabelColor
        countField.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [titleField, countField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, count: Int) {
        titleField.stringValue = title
        countField.stringValue = count.formatted()
        setAccessibilityLabel("\(title), \(count) items")
    }
}

/// Row view that tells its cell when the pointer is over it, to reveal the heart.
final class HoverRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("HoverRow")

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { (view(atColumn: 0) as? SidebarEntryCell)?.isHovered = isHovered }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}
