import AppKit

final class CanvasTextView: NSTextView {
    var onFinish: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(); return }
        super.keyDown(with: event)
    }
}

struct CanvasViewportAnchor {
    let pageID: UUID
    let fallbackPageIndex: Int
    let pointOnPage: CGPoint
}

final class CanvasView: NSView, NSTextViewDelegate {
    var document = PaperDocument()
    var selectedIDs = Set<UUID>()
    var activePage = 0
    var onWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?
    var onDropImages: (([URL], Int, CGPoint) -> Void)?
    var onNewText: ((Int, CGPoint) -> Void)?
    var onDelete: (() -> Void)?
    var textEditor: CanvasTextView?
    var editingID: UUID?
    var showMargins = true
    var isPanningMode = false {
        didSet { updatePanCursor() }
    }
    private var imageCache: [UUID: NSImage] = [:]
    private var imageCacheSizes: [UUID: Int] = [:]
    var cachedImageCount: Int { imageCache.count }
    /// Decoded pixel buffer sizes; the small NSImage/object overhead is excluded.
    var cachedImageBytes: Int { imageCacheSizes.values.reduce(0, +) }
    private var temporaryPan = false
    private var panDragLocation: CGPoint?
    private var isPanActive: Bool { isPanningMode || temporaryPan || panDragLocation != nil }
    private var dragStart = CGPoint.zero
    private var dragElements: [PaperElement] = []
    private var dragSourcePage = 0
    private var dragResize = false
    private var didDrag = false
    private var startingRect = CGRect.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    var zoom: CGFloat { document.zoom }
    var selectedElement: PaperElement? {
        guard selectedIDs.count == 1 else { return nil }
        return document.pages.flatMap(\.elements).first { selectedIDs.contains($0.id) }
    }
    func pageRect(_ index: Int) -> CGRect {
        CGRect(x: (bounds.width - paperWidth * zoom) / 2, y: 34 + CGFloat(index) * (paperHeight * zoom + document.pageGap + 24), width: paperWidth * zoom, height: paperHeight * zoom)
    }
    func pageIndex(at point: CGPoint) -> Int? { document.pages.indices.first { pageRect($0).contains(point) } }
    func localPoint(_ point: CGPoint, page: Int) -> CGPoint {
        let r = pageRect(page)
        return CGPoint(x: (point.x - r.minX) / zoom, y: (point.y - r.minY) / zoom)
    }
    func updateSize(viewport: CGSize) {
        // Leave room to pan sideways even when a zoomed-out sheet fits the viewport.
        let width = paperWidth * zoom + max(96, viewport.width)
        let height = max(viewport.height, 68 + CGFloat(document.pages.count) * (paperHeight * zoom + document.pageGap + 24) - document.pageGap - 24)
        setFrameSize(CGSize(width: width, height: height))
        positionEditor()
        needsDisplay = true
    }
    func captureViewportAnchor() -> CanvasViewportAnchor? {
        guard let clip = enclosingScrollView?.contentView, !document.pages.isEmpty else { return nil }
        let center = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let index = pageIndex(at: center) ?? document.pages.indices.min {
            abs(pageRect($0).midY - center.y) < abs(pageRect($1).midY - center.y)
        }!
        return CanvasViewportAnchor(pageID: document.pages[index].id, fallbackPageIndex: index, pointOnPage: localPoint(center, page: index))
    }
    func restoreViewportAnchor(_ anchor: CanvasViewportAnchor?) {
        guard let anchor, let clip = enclosingScrollView?.contentView, !document.pages.isEmpty else { return }
        let index = document.pages.firstIndex { $0.id == anchor.pageID } ?? min(max(0, anchor.fallbackPageIndex), document.pages.count - 1)
        let page = pageRect(index)
        let center = CGPoint(x: page.minX + anchor.pointOnPage.x * zoom, y: page.minY + anchor.pointOnPage.y * zoom)
        panViewport(by: CGPoint(x: center.x - clip.bounds.midX, y: center.y - clip.bounds.midY))
    }
    /// Positive deltas move the viewport right/down in the flipped canvas.
    func panViewport(by delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var target = clip.bounds
        target.origin.x += delta.x
        target.origin.y += delta.y
        target = clip.constrainBoundsRect(target)
        clip.scroll(to: target.origin)
        scroll.reflectScrolledClipView(clip)
    }
    private func updatePanCursor() {
        window?.invalidateCursorRects(for: self)
        if panDragLocation != nil { NSCursor.closedHand.set() }
        else if isPanActive { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isPanActive { addCursorRect(visibleRect, cursor: panDragLocation == nil ? .openHand : .closedHand) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // A hand drag may begin above an open text editor without changing its text.
        return isPanActive && hit != nil ? self : hit
    }
    override func resignFirstResponder() -> Bool {
        temporaryPan = false
        panDragLocation = nil
        updatePanCursor()
        return super.resignFirstResponder()
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.shift), event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
            panViewport(by: CGPoint(x: -event.scrollingDeltaY * multiplier, y: 0))
            return
        }
        super.scrollWheel(with: event)
    }
    func clearImageCache() { imageCache.removeAll(); imageCacheSizes.removeAll() }
    func invalidateImages() { clearImageCache(); needsDisplay = true }
    func rebuildImages() {
        let displayedRect = enclosingScrollView == nil ? bounds : visibleRect
        for (index, page) in document.pages.enumerated() where pageRect(index).intersects(displayedRect) {
            for item in page.elements where item.kind == .image && imageCache[item.id] == nil {
                if let cg = try? ImageTools.displayedImage(for: item) {
                    imageCache[item.id] = NSImage(cgImage: cg, size: .zero)
                    imageCacheSizes[item.id] = cg.bytesPerRow * cg.height
                }
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.95, alpha: 1).setFill(); dirtyRect.fill()
        rebuildImages()
        for (index, page) in document.pages.enumerated() {
            let rect = pageRect(index)
            guard rect.insetBy(dx: -15, dy: -30).intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12); shadow.shadowBlurRadius = 9; shadow.shadowOffset = CGSize(width: 0, height: -2); shadow.set()
            NSColor.white.setFill(); rect.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
            (transform as NSAffineTransform).concat()
            NSAffineTransform.scale(by: zoom)
            PageDrawing.draw(page, skipText: editingID, imageCache: imageCache)
            if showMargins {
                let guide = NSBezierPath(rect: document.contentRect)
                guide.lineWidth = 0.5 / zoom
                guide.setLineDash([3 / zoom, 4 / zoom], count: 2, phase: 0)
                NSColor(calibratedWhite: 0.75, alpha: 0.55).setStroke(); guide.stroke()
            }
            for item in page.elements where item.kind == .text && PageDrawing.overflows(item) {
                NSColor.systemRed.setStroke()
                let outline = NSBezierPath(rect: item.rect); outline.lineWidth = 1.5 / zoom; outline.stroke()
            }
            for item in page.elements where selectedIDs.contains(item.id) && item.id != editingID {
                NSColor.controlAccentColor.setStroke()
                let outline = NSBezierPath(rect: item.rect); outline.lineWidth = 1.6 / zoom; outline.stroke()
                let handle = CGRect(x: item.rect.maxX - 4 / zoom, y: item.rect.maxY - 4 / zoom, width: 8 / zoom, height: 8 / zoom)
                NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: handle).stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            let label = "\(index + 1)  /  \(document.pages.count)   ·   A4"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: index == activePage ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]
            NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: rect.minX, y: rect.minY - 21))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isPanActive {
            window?.makeFirstResponder(self)
            panDragLocation = event.locationInWindow
            dragElements = []; didDrag = false
            updatePanCursor()
            return
        }
        finishEditing()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = pageIndex(at: point) else { selectedIDs = []; onSelection?(); needsDisplay = true; return }
        activePage = page
        let local = localPoint(point, page: page)
        let elements = document.pages[page].elements
        let handleHit = elements.reversed().first { selectedIDs.contains($0.id) && CGRect(x: $0.rect.maxX - 9 / zoom, y: $0.rect.maxY - 9 / zoom, width: 18 / zoom, height: 18 / zoom).contains(local) }
        let hit = handleHit ?? elements.reversed().first { $0.rect.contains(local) }
        if let hit {
            if event.modifierFlags.contains(.shift) {
                if selectedIDs.contains(hit.id) { selectedIDs.remove(hit.id) } else { selectedIDs.insert(hit.id) }
            } else if !selectedIDs.contains(hit.id) { selectedIDs = [hit.id] }
            if event.clickCount == 2 && hit.kind == .text { selectedIDs = [hit.id]; startEditing(hit.id); return }
            dragStart = point
            dragSourcePage = page
            dragResize = handleHit != nil && selectedIDs.count == 1
            startingRect = hit.rect
            dragElements = elements.filter { selectedIDs.contains($0.id) }
            didDrag = false
        } else {
            selectedIDs = []
            dragElements = []
            if event.clickCount == 2 { onNewText?(page, local); return }
        }
        onSelection?(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let previous = panDragLocation {
            let point = event.locationInWindow
            panDragLocation = point
            panViewport(by: CGPoint(x: previous.x - point.x, y: point.y - previous.y))
            return
        }
        guard !dragElements.isEmpty else { return }
        if !didDrag { onWillChange?(); didDrag = true }
        let point = convert(event.locationInWindow, from: nil)
        let dx = (point.x - dragStart.x) / zoom
        let dy = (point.y - dragStart.y) / zoom
        for original in dragElements {
            guard let index = document.pages[dragSourcePage].elements.firstIndex(where: { $0.id == original.id }) else { continue }
            var rect = original.rect
            if dragResize {
                var width = max(24, original.width + dx)
                var height = max(24, original.height + dy)
                if original.kind == .image && !event.modifierFlags.contains(.shift) {
                    let ratio = original.width / original.height
                    if abs(dx) >= abs(dy * ratio) { height = width / ratio } else { width = height * ratio }
                    let fit = min(1, min((paperWidth - rect.minX) / width, (paperHeight - rect.minY) / height))
                    width *= fit; height *= fit
                }
                rect.size = CGSize(width: max(12, min(width, paperWidth - rect.minX)), height: max(12, min(height, paperHeight - rect.minY)))
            } else {
                rect.origin = CGPoint(x: original.x + dx, y: original.y + dy)
            }
            document.pages[dragSourcePage].elements[index].rect = rect
        }
        needsDisplay = true
        onChange?()
    }
    override func mouseUp(with event: NSEvent) {
        if panDragLocation != nil {
            panDragLocation = nil
            updatePanCursor()
            return
        }
        guard didDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let targetPage = pageIndex(at: point) ?? dragSourcePage
        if !dragResize && targetPage != dragSourcePage {
            let sourceRect = pageRect(dragSourcePage)
            let targetRect = pageRect(targetPage)
            let items = document.pages[dragSourcePage].elements.filter { selectedIDs.contains($0.id) }
            document.pages[dragSourcePage].elements.removeAll { selectedIDs.contains($0.id) }
            for var item in items {
                item.x += (sourceRect.minX - targetRect.minX) / zoom
                item.y += (sourceRect.minY - targetRect.minY) / zoom
                item.rect = clamped(item.rect)
                document.pages[targetPage].elements.append(item)
            }
            activePage = targetPage
        } else {
            for index in document.pages[dragSourcePage].elements.indices where selectedIDs.contains(document.pages[dragSourcePage].elements[index].id) {
                document.pages[dragSourcePage].elements[index].rect = clamped(document.pages[dragSourcePage].elements[index].rect)
            }
        }
        dragElements = []; didDrag = false
        onChange?(); onSelection?(); needsDisplay = true
    }
    func clamped(_ rect: CGRect) -> CGRect {
        CGRect(x: max(0, min(paperWidth - rect.width, rect.minX)), y: max(0, min(paperHeight - rect.height, rect.minY)), width: rect.width, height: rect.height)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            temporaryPan = true
            updatePanCursor()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if event.keyCode == 53 { selectedIDs = []; onSelection?(); needsDisplay = true; return }
        let steps: [UInt16: CGPoint] = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0), 125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)]
        if let direction = steps[event.keyCode], !selectedIDs.isEmpty {
            onWillChange?()
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            for p in document.pages.indices {
                for i in document.pages[p].elements.indices where selectedIDs.contains(document.pages[p].elements[i].id) {
                    let rect = document.pages[p].elements[i].rect.offsetBy(dx: direction.x * step, dy: direction.y * step)
                    document.pages[p].elements[i].rect = clamped(rect)
                }
            }
            onChange?(); onSelection?(); needsDisplay = true; return
        }
        if event.characters == "\r", let item = selectedElement, item.kind == .text { startEditing(item.id); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, temporaryPan {
            temporaryPan = false
            updatePanCursor()
            return
        }
        super.keyUp(with: event)
    }

    func startEditing(_ id: UUID) {
        finishEditing()
        guard let item = document.pages.flatMap(\.elements).first(where: { $0.id == id && $0.kind == .text }) else { return }
        onWillChange?()
        editingID = id
        selectedIDs = [id]
        let storage = NSTextStorage(attributedString: item.attributedText)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: item.width, height: 100000))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        let editor = CanvasTextView(frame: item.rect, textContainer: container)
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.drawsBackground = true
        editor.backgroundColor = .white
        editor.textColor = .black
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = .zero
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.delegate = self
        editor.onFinish = { [weak self] in self?.finishEditing(); self?.window?.makeFirstResponder(self) }
        textEditor = editor
        addSubview(editor)
        positionEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        onSelection?(); needsDisplay = true
    }
    func positionEditor() {
        guard let id = editingID, let editor = textEditor else { return }
        for (p, page) in document.pages.enumerated() {
            if let item = page.elements.first(where: { $0.id == id }) {
                let r = pageRect(p)
                editor.frame = CGRect(x: r.minX + item.x * zoom, y: r.minY + item.y * zoom, width: item.width * zoom, height: item.height * zoom)
                editor.bounds = CGRect(x: 0, y: 0, width: item.width, height: item.height)
                editor.textContainer?.containerSize = CGSize(width: item.width, height: 100000)
                break
            }
        }
    }
    func syncEditing() {
        guard let id = editingID, let editor = textEditor else { return }
        for p in document.pages.indices {
            if let i = document.pages[p].elements.firstIndex(where: { $0.id == id }) {
                document.pages[p].elements[i].setText(editor.attributedString())
                break
            }
        }
    }
    func finishEditing() {
        guard textEditor != nil else { return }
        syncEditing()
        textEditor?.delegate = nil
        textEditor?.removeFromSuperview()
        textEditor = nil; editingID = nil
        onChange?(); needsDisplay = true
    }
    func textDidChange(_ notification: Notification) {
        syncEditing(); onChange?(); needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let page = pageIndex(at: point) ?? activePage
        onDropImages?(urls, page, localPoint(point, page: page))
        return true
    }
}

private extension NSAffineTransform {
    static func scale(by factor: CGFloat) { let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat() }
}
