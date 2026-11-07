import AppKit

/// Layer-backed image view that can aspect-fill and round its corners.
final class ThumbnailView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var contentsGravity: CALayerContentsGravity = .resizeAspectFill { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 4 { didSet { needsDisplay = true } }
    var showsBorder = true { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.contentsGravity = contentsGravity
        layer.contents = image?.layerContents(forContentsScale: scale)
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = showsBorder ? 1 / scale : 0
        layer.borderColor = NSColor.separatorColor.cgColor
        layer.backgroundColor = image == nil ? NSColor.quaternaryLabelColor.cgColor : nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// An image view that drags the files it represents, like a Finder icon.
///
/// It accepts the first mouse and does not bring the window forward while dragging,
/// so files can be dragged out of Shot even when it is in the background.
final class DraggableImageView: NSImageView, NSDraggingSource {
    var fileURLs: [URL] = []
    var onDoubleClick: (() -> Void)?
    /// Large images are shrunk around the cursor to this size while dragging.
    var maximumDragImageSide: CGFloat = 240

    private var mouseDownEvent: NSEvent?
    private var activateOnMouseUp = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        allowsCutCopyPaste = false
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        activateOnMouseUp = !(NSApp.isActive && window?.isKeyWindow == true)
        if activateOnMouseUp {
            NSApp.preventWindowOrdering()
        }
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !fileURLs.isEmpty else { return }
        let start = down.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 3 else { return }
        mouseDownEvent = nil
        activateOnMouseUp = false

        let anchor = convert(start, from: nil)
        let items = fileURLs.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let picture = (index == 0 ? image : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
            var frame = dragFrame(for: picture, anchor: anchor)
            frame = frame.offsetBy(dx: CGFloat(index) * 6, dy: CGFloat(-index) * 6)
            item.setDraggingFrame(frame, contents: picture)
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        if items.count > 1 {
            session.draggingFormation = .pile
        }
    }

    override func mouseUp(with event: NSEvent) {
        if activateOnMouseUp {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
        activateOnMouseUp = false
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// The on-screen rect of the image, shrunk around `anchor` if it is large.
    private func dragFrame(for picture: NSImage, anchor: NSPoint) -> NSRect {
        var rect = displayedImageRect(for: picture)
        let longest = max(rect.width, rect.height)
        if longest > maximumDragImageSide {
            let factor = maximumDragImageSide / longest
            let anchorInRect = rect.contains(anchor) ? anchor : NSPoint(x: rect.midX, y: rect.midY)
            rect = NSRect(
                x: anchorInRect.x + (rect.minX - anchorInRect.x) * factor,
                y: anchorInRect.y + (rect.minY - anchorInRect.y) * factor,
                width: rect.width * factor,
                height: rect.height * factor
            )
        }
        return rect
    }

    private func displayedImageRect(for picture: NSImage) -> NSRect {
        let size = picture.size
        guard size.width > 0, size.height > 0 else { return bounds }
        var scale = min(bounds.width / size.width, bounds.height / size.height)
        if imageScaling == .scaleProportionallyDown {
            scale = min(scale, 1)
        }
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

/// Centered title, message and optional button.
final class EmptyStateView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var buttonHandler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .center

        messageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .center
        messageField.isSelectable = false

        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = self
        button.action = #selector(buttonClicked)

        let stack = NSStackView(views: [titleField, messageField, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: messageField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, message: String?, buttonTitle: String? = nil, action: (() -> Void)? = nil) {
        titleField.stringValue = title
        messageField.stringValue = message ?? ""
        messageField.isHidden = message == nil
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil
        buttonHandler = action
    }

    @objc private func buttonClicked() {
        buttonHandler?()
    }
}

extension NSImage {
    static func symbol(_ name: String, _ description: String? = nil) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }
}
