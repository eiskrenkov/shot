import AppKit
import AVKit
import ImageIO

final class PreviewViewController: NSViewController {
    private enum Mode { case empty, image, video, grid }

    private let contentView = NSView()
    private let imageView = DraggableImageView()
    private let playerView = AVPlayerView()
    private let grid = SelectionGridView()
    private let emptyLabel = NSTextField(labelWithString: "No Selection")
    private let infoBar = InfoBarView()

    private var displayed: [Screenshot] = []
    private var displayedSignature: [String] = []
    private var loadGeneration = 0

    override func loadView() {
        let root = NSView()

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.toolTip = "Drag to copy the file anywhere. Double-click to open."
        imageView.onDoubleClick = { [weak self] in
            guard let self else { return }
            ScreenshotActions.open(self.displayed)
        }

        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect

        emptyLabel.font = .systemFont(ofSize: 20, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor

        for subview in [imageView, playerView, grid, emptyLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)
        root.addSubview(infoBar)

        let inset: CGFloat = 20
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: infoBar.topAnchor),

            infoBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            infoBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            infoBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),

            playerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),

            grid.topAnchor.constraint(equalTo: contentView.topAnchor),
            grid.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        grid.onOpen = { ScreenshotActions.open([$0]) }

        view = root
        setMode(.empty)
    }

    /// Shows the selected rows. A single group shows its contents in the grid.
    func show(_ entries: [LibraryEntry]) {
        let items = Screenshot.flatten(entries)
        let signature = entries.map(\.url.pathKey)
            + items.map { "\($0.url.pathKey)|\($0.modificationDate.timeIntervalSinceReferenceDate)" }
        guard signature != displayedSignature else { return }

        displayedSignature = signature
        displayed = items
        loadGeneration += 1
        playerView.player?.pause()
        playerView.player = nil

        if entries.count == 1, let folder = entries.first as? ScreenshotFolder {
            imageView.image = nil
            grid.items = items
            infoBar.configure(folder: folder)
            setMode(.grid)
            return
        }

        switch items.count {
        case 0:
            imageView.image = nil
            setMode(.empty)
        case 1:
            let item = items[0]
            infoBar.configure(item: item, detail: baseDetail(for: item))
            if item.kind == .image {
                showImage(item)
            } else {
                showVideo(item)
            }
        default:
            imageView.image = nil
            grid.items = items
            infoBar.configure(items: items)
            setMode(.grid)
        }
    }

    private func setMode(_ mode: Mode) {
        imageView.isHidden = mode != .image
        playerView.isHidden = mode != .video
        grid.isHidden = mode != .grid
        emptyLabel.isHidden = mode != .empty
        infoBar.isHidden = mode == .empty
    }

    private func baseDetail(for item: Screenshot) -> [String] {
        [DateText.byteCount(item.fileSize), DateText.fullString(item.creationDate)]
    }

    // MARK: - Image

    private func showImage(_ item: Screenshot) {
        setMode(.image)
        imageView.fileURLs = [item.url]
        // Show a cached thumbnail immediately; swap in the full image once decoded.
        imageView.image = ThumbnailProvider.shared.cachedThumbnail(for: item, side: ThumbnailProvider.Side.grid)
            ?? ThumbnailProvider.shared.cachedThumbnail(for: item, side: ThumbnailProvider.Side.list)

        let token = loadGeneration
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Self.loadImage(at: url)
            DispatchQueue.main.async {
                guard let self, token == self.loadGeneration else { return }
                if let loaded {
                    self.imageView.image = loaded.image
                    let dimensions = "\(loaded.pixelWidth) × \(loaded.pixelHeight)"
                    self.infoBar.configure(item: item, detail: [dimensions] + self.baseDetail(for: item))
                } else {
                    self.imageView.image = NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
    }

    private struct LoadedImage {
        let image: NSImage
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Decodes off the main thread and sizes the image in points using its DPI,
    /// so Retina screenshots display at 1:1.
    private static func loadImage(at url: URL) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = max(dpi / 72, 1)
        let size = NSSize(width: Double(cgImage.width) / scale, height: Double(cgImage.height) / scale)
        return LoadedImage(
            image: NSImage(cgImage: cgImage, size: size),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
    }

    // MARK: - Video

    private func showVideo(_ item: Screenshot) {
        setMode(.video)
        let asset = AVURLAsset(url: item.url)
        playerView.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))

        let token = loadGeneration
        Task { @MainActor [weak self] in
            async let duration = try? asset.load(.duration)
            async let tracks = try? asset.loadTracks(withMediaType: .video)
            let (loadedDuration, videoTracks) = await (duration, tracks)
            var size: CGSize?
            if let track = videoTracks?.first, let natural = try? await track.load(.naturalSize) {
                size = natural
            }
            guard let self, token == self.loadGeneration else { return }

            var detail: [String] = []
            if let size { detail.append("\(Int(size.width)) × \(Int(size.height))") }
            if let loadedDuration, loadedDuration.isNumeric {
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = loadedDuration.seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
                formatter.zeroFormattingBehavior = .pad
                if let text = formatter.string(from: loadedDuration.seconds.rounded()) { detail.append(text) }
            }
            self.infoBar.configure(item: item, detail: detail + self.baseDetail(for: item))
        }
    }
}

// MARK: - Info bar

/// Bottom bar with a draggable file icon, the name and file details.
final class InfoBarView: NSView {
    private let iconView = DraggableImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var representedURLs: [URL] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.maximumDragImageSide = 96
        iconView.toolTip = "Drag to copy the file anywhere"
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.isSelectable = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.isSelectable = true
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [titleField, detailField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [iconView, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            heightAnchor.constraint(equalToConstant: 54),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: Screenshot, detail: [String]) {
        titleField.stringValue = item.displayName
        detailField.stringValue = detail.joined(separator: "  ·  ")
        setURLs([item.url])
        let url = item.url
        ThumbnailProvider.shared.thumbnail(for: item, side: ThumbnailProvider.Side.list, scale: 2) { [weak self] image in
            guard let self, self.representedURLs == [url] else { return }
            self.iconView.image = image
        }
    }

    func configure(folder: ScreenshotFolder) {
        titleField.stringValue = folder.displayName
        detailField.stringValue = [
            DateText.itemCount(folder.items.count),
            DateText.byteCount(folder.totalSize) + " total",
            "Drag to copy the folder",
        ].joined(separator: "  ·  ")
        setURLs([folder.url])
    }

    func configure(items: [Screenshot]) {
        let total = items.reduce(Int64(0)) { $0 + $1.fileSize }
        titleField.stringValue = "\(items.count.formatted()) Items Selected"
        detailField.stringValue = DateText.byteCount(total) + " total  ·  Drag to copy them all"
        setURLs(items.map(\.url))
    }

    private func setURLs(_ urls: [URL]) {
        guard urls != representedURLs else { return }
        representedURLs = urls
        iconView.fileURLs = urls
        iconView.image = NSWorkspace.shared.icon(forFiles: urls.map(\.path))
    }
}

// MARK: - Multi-selection grid

final class SelectionGridView: NSScrollView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var items: [Screenshot] = [] {
        didSet { collectionView.reloadData() }
    }
    var onOpen: ((Screenshot) -> Void)?

    private let collectionView = GridCollectionView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 176, height: 150)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        collectionView.collectionViewLayout = layout
        collectionView.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([], forLocal: true)
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, indexPath.item < self.items.count else { return }
            self.onOpen?(self.items[indexPath.item])
        }

        documentView = collectionView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
        (cell as? GridItem)?.configure(with: items[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items[indexPath.item].url as NSURL
    }
}

private final class GridCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2,
           let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(indexPath)
            return
        }
        super.mouseDown(with: event)
    }
}

private final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridItem")

    private let thumbnailView = ThumbnailView()
    private let nameField = NSTextField(labelWithString: "")
    private var representedURL: URL?

    override func loadView() {
        thumbnailView.contentsGravity = .resizeAspect
        thumbnailView.showsBorder = false
        thumbnailView.cornerRadius = 0

        nameField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.alignment = .center

        let container = NSView()
        for subview in [thumbnailView, nameField] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: nameField.topAnchor, constant: -6),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nameField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    func configure(with item: Screenshot) {
        representedURL = item.url
        nameField.stringValue = item.displayName
        view.toolTip = item.displayName
        thumbnailView.image = nil
        let url = item.url
        ThumbnailProvider.shared.thumbnail(
            for: item, side: ThumbnailProvider.Side.grid,
            scale: view.window?.backingScaleFactor ?? 2
        ) { [weak self] image in
            guard let self, self.representedURL == url else { return }
            self.thumbnailView.image = image
        }
    }
}
