import AppKit

final class CanvasTextView: NSTextView {
    var onFinish: (() -> Void)?
    // Undo actions retain their text-system targets. Keep each editing session isolated
    // from other text boxes and discard those actions before releasing the editor.
    private let sessionUndoManager = UndoManager()
    override var undoManager: UndoManager? { sessionUndoManager }
    /// Attribute edits made directly on NSTextStorage bypass NSTextView's native
    /// typing undo. Register complete rich-text values so mixed runs and selections
    /// round-trip through Undo/Redo instead of falling back to the project snapshot.
    @discardableResult func applyFormatting(_ value: NSAttributedString, selection: NSRange) -> Bool {
        let old = attributedString()
        let previousSelection = selectedRange()
        guard !hasMarkedText(), !old.isEqual(to: value) else { return false }
        let previous = NSAttributedString(attributedString: old)
        breakUndoCoalescing()
        // shouldChangeText may register its own whole-range undo. Suppress that
        // duplicate while this explicit attributed-text operation owns the inverse.
        let manager = undoManager
        manager?.disableUndoRegistration()
        let allowed = shouldChangeText(in: NSRange(location: 0, length: old.length), replacementString: nil)
        if allowed {
            textStorage?.setAttributedString(value)
            let location = min(max(0, selection.location), value.length)
            setSelectedRange(NSRange(location: location, length: min(max(0, selection.length), value.length - location)))
            didChangeText()
        }
        manager?.enableUndoRegistration()
        guard allowed else { return false }
        // Native event groups normally exist here. An explicit undo/redo invoked
        // in the same event can close them; create a group rather than registering
        // against an invalid zero-level manager (which raises an Obj-C exception).
        let needsGroup = manager?.groupingLevel == 0 && manager?.isUndoing != true && manager?.isRedoing != true
        if needsGroup { manager?.beginUndoGrouping() }
        manager?.registerUndo(withTarget: self) { target in
            target.applyFormatting(previous, selection: previousSelection)
        }
        manager?.setActionName("文字格式")
        if needsGroup { manager?.endUndoGrouping() }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && !hasMarkedText() { onFinish?(); return }
        super.keyDown(with: event)
    }
}

enum CanvasResizeHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX),
                y: movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY))
    }
    var cursor: NSCursor {
        if self == .left || self == .right { return .resizeLeftRight }
        if self == .top || self == .bottom { return .resizeUpDown }
        return .crosshair
    }
}

struct CanvasViewportAnchor {
    let pageID: UUID
    let fallbackPageIndex: Int
    let pointOnPage: CGPoint
}

/// A cancelled request can finish in ImageIO, but must never replace newer canvas state.
private final class CanvasPreviewRequest {
    let generation: UInt64
    let element: PaperElement
    let maximumDimension: Int
    private let lock = NSLock()
    private var cancelled = false
    init(generation: UInt64, element: PaperElement, maximumDimension: Int) {
        self.generation = generation; self.element = element; self.maximumDimension = maximumDimension
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func matches(_ item: PaperElement) -> Bool { element.imageData == item.imageData && element.crop == item.crop }
}

final class CanvasView: NSView, NSTextViewDelegate {
    var document = PaperDocument()
    var isInteractionEnabled = true {
        didSet {
            guard !isInteractionEnabled else { return }
            finishEditing()
            cancelObjectDrag()
        }
    }
    var selectedIDs = Set<UUID>()
    var activePage = 0
    var onWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?
    var onDropImages: (([URL], Int, CGPoint) -> Void)?
    var onNewText: ((Int, CGPoint) -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var textEditor: CanvasTextView?
    var editingID: UUID?
    private var editingOriginalText: NSAttributedString?
    private var editingOriginalRTF: Data?
    private var lastCommittedText: NSAttributedString?
    private var hasEditingCheckpoint = false
    private var isPreparingTextCheckpoint = false
    private var isFinishingEditing = false
    var showMargins = true
    var isPanningMode = false {
        didSet { updatePanCursor() }
    }
    private var imageCache: [UUID: NSImage] = [:]
    private var imageCacheSizes: [UUID: Int] = [:]
    private var cachedImageSources: [UUID: PaperElement] = [:]
    private var failedImageSources: [UUID: PaperElement] = [:]
    private var pendingPreviews: [UUID: CanvasPreviewRequest] = [:]
    private var previewGeneration: UInt64 = 0
    private static let previewQueue = DispatchQueue(label: "PaperDesk.canvas-preview", qos: .userInitiated)
    static let imageCacheBudget = 64 * 1024 * 1024
    private struct OverflowResult {
        let rtf: Data?
        let size: CGSize
        let value: Bool
    }
    private var overflowResults: [UUID: OverflowResult] = [:]
    var pendingPreviewCount: Int { pendingPreviews.count }
    var failedPreviewCount: Int { failedImageSources.count }
    var cachedImageCount: Int { imageCache.count }
    /// Decoded pixel buffer sizes; the small NSImage/object overhead is excluded.
    var cachedImageBytes: Int { imageCacheSizes.values.reduce(0, +) }
    private var temporaryPan = false
    private var panDragLocation: CGPoint?
    private var isPanActive: Bool { isPanningMode || temporaryPan || panDragLocation != nil }
    private var dragStart = CGPoint.zero
    private var dragElements: [PaperElement] = []
    private var dragSourcePage = 0
    private var dragSourcePageID: UUID?
    private var dragHandle: CanvasResizeHandle?
    private var didDrag = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    deinit { pendingPreviews.values.forEach { $0.cancel() } }
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
        if isPanActive { addCursorRect(visibleRect, cursor: panDragLocation == nil ? .openHand : .closedHand); return }
        guard isInteractionEnabled, selectedIDs.count == 1 else { return }
        for (pageIndex, page) in document.pages.enumerated() {
            guard let item = page.elements.first(where: { selectedIDs.contains($0.id) }) else { continue }
            let pageFrame = pageRect(pageIndex)
            for handle in resizeHandles(for: item) {
                let point = handle.point(in: item.rect)
                let frame = CGRect(x: pageFrame.minX + point.x * zoom - 6, y: pageFrame.minY + point.y * zoom - 6, width: 12, height: 12)
                let clipped = frame.intersection(visibleRect)
                if !clipped.isNull && !clipped.isEmpty && [clipped.minX, clipped.minY, clipped.width, clipped.height].allSatisfy({ $0.isFinite }) {
                    addCursorRect(clipped, cursor: handle.cursor)
                }
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // A hand drag may begin above an open text editor without changing its text.
        if isPanActive && hit != nil { return self }
        // Leave the content to NSTextView, but keep the outline and handles available
        // for moving/resizing a text box without requiring an extra Escape first.
        if hit != nil, isInteractionEnabled, let id = editingID {
            let canvasPoint = convert(point, from: superview)
            for (pageIndex, page) in document.pages.enumerated() {
                guard let item = page.elements.first(where: { $0.id == id }) else { continue }
                let local = localPoint(canvasPoint, page: pageIndex)
                if item.rect.insetBy(dx: -7 / zoom, dy: -7 / zoom).contains(local)
                    && !item.rect.insetBy(dx: 5 / zoom, dy: 5 / zoom).contains(local) { return self }
            }
        }
        return hit
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
    func clearImageCache() {
        previewGeneration &+= 1
        pendingPreviews.values.forEach { $0.cancel() }
        pendingPreviews.removeAll()
        imageCache.removeAll(); imageCacheSizes.removeAll(); cachedImageSources.removeAll(); failedImageSources.removeAll()
    }
    func invalidateImages() { clearImageCache(); needsDisplay = true }
    private func sameImage(_ first: PaperElement, _ second: PaperElement) -> Bool {
        first.imageData == second.imageData && first.crop == second.crop
    }
    private func visibleImages() -> [UUID: PaperElement] {
        let displayedRect = enclosingScrollView == nil ? bounds : visibleRect
        var wanted: [UUID: PaperElement] = [:]
        for (index, page) in document.pages.enumerated() where pageRect(index).intersects(displayedRect) {
            let pageFrame = pageRect(index)
            for item in page.elements where item.kind == .image {
                let frame = CGRect(x: pageFrame.minX + item.x * zoom, y: pageFrame.minY + item.y * zoom,
                                   width: item.width * zoom, height: item.height * zoom)
                if frame.intersects(displayedRect.intersection(pageFrame)) { wanted[item.id] = item }
            }
        }
        return wanted
    }
    /// Decode only visible image objects, off the event thread, using a bounded thumbnail.
    func rebuildImages() {
        let wanted = visibleImages()
        // Leave a little space for bitmap row alignment. Rebalance if a new collage appears.
        let itemBudget = Int(Double(Self.imageCacheBudget) * 0.9 / Double(max(1, wanted.count)))
        let maximumDimension = min(2048, max(1, Int(sqrt(Double(itemBudget) / 4))))
        for id in Array(imageCache.keys) {
            if let item = wanted[id], let source = cachedImageSources[id], sameImage(item, source), (imageCacheSizes[id] ?? 0) <= itemBudget { continue }
            imageCache.removeValue(forKey: id); imageCacheSizes.removeValue(forKey: id); cachedImageSources.removeValue(forKey: id)
        }
        for (id, request) in pendingPreviews {
            if let item = wanted[id], request.matches(item), request.maximumDimension <= maximumDimension { continue }
            request.cancel(); pendingPreviews.removeValue(forKey: id)
        }
        // Share the pixel budget among visible objects, so a collage cannot thrash the cache.
        for item in wanted.values {
            if imageCache[item.id] != nil || pendingPreviews[item.id] != nil { continue }
            if let failed = failedImageSources[item.id], sameImage(failed, item) { continue }
            let request = CanvasPreviewRequest(generation: previewGeneration, element: item, maximumDimension: maximumDimension)
            pendingPreviews[item.id] = request
            Self.previewQueue.async { [weak self] in
                guard !request.isCancelled else { return }
                let result = Result { try ImageTools.preview(for: request.element, maxPixelSize: request.maximumDimension) }
                guard !request.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.previewGeneration == request.generation,
                          self.pendingPreviews[item.id] === request, !request.isCancelled else { return }
                    self.pendingPreviews.removeValue(forKey: item.id)
                    guard let visible = self.visibleImages()[item.id], request.matches(visible) else { return }
                    switch result {
                    case .success(let cg):
                        let bytes = cg.bytesPerRow * cg.height
                        if bytes <= Self.imageCacheBudget - self.cachedImageBytes {
                            self.imageCache[item.id] = NSImage(cgImage: cg, size: .zero)
                            self.imageCacheSizes[item.id] = bytes
                            self.cachedImageSources[item.id] = request.element
                            self.failedImageSources.removeValue(forKey: item.id)
                        } else {
                            // Avoid repeatedly decoding a request rejected by the current budget.
                            self.failedImageSources[item.id] = request.element
                        }
                    case .failure:
                        self.failedImageSources[item.id] = request.element
                    }
                    self.needsDisplay = true
                }
            }
        }
        // Failed resources are cheap placeholders, but should not retain deleted project data.
        let liveIDs = Set(document.pages.flatMap(\.elements).filter { $0.kind == .image }.map(\.id))
        failedImageSources = failedImageSources.filter { liveIDs.contains($0.key) }
    }
    func overflows(_ item: PaperElement) -> Bool {
        guard item.kind == .text else { return false }
        let size = CGSize(width: item.width, height: item.height)
        if let cached = overflowResults[item.id], cached.rtf == item.textRTF, cached.size == size { return cached.value }
        let valid = item.width.isFinite && item.height.isFinite && item.width > 0 && item.height > 0
        let value = valid ? PageDrawing.overflows(item) : true
        overflowResults[item.id] = OverflowResult(rtf: item.textRTF, size: size, value: value)
        return value
    }
    var overflowCount: Int {
        let texts = document.pages.flatMap(\.elements).filter { $0.kind == .text }
        let ids = Set(texts.map(\.id))
        overflowResults = overflowResults.filter { ids.contains($0.key) }
        return texts.reduce(0) { $0 + (overflows($1) ? 1 : 0) }
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
            PageDrawing.draw(page, skipText: editingID, imageCache: imageCache, allowImageDecoding: false)
            if page.elements.isEmpty {
                let hint = NSAttributedString(string: "双击添加文字\n拖入图片开始排版", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor(srgbRed: 0.57, green: 0.63, blue: 0.68, alpha: 1),
                    .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineSpacing = 8; return style }()
                ])
                hint.draw(in: CGRect(x: 60, y: paperHeight / 2 - 24, width: paperWidth - 120, height: 60))
            }
            if showMargins {
                let guide = NSBezierPath(rect: document.contentRect)
                guide.lineWidth = 0.5 / zoom
                guide.setLineDash([3 / zoom, 4 / zoom], count: 2, phase: 0)
                NSColor(calibratedWhite: 0.75, alpha: 0.55).setStroke(); guide.stroke()
            }
            for item in page.elements where item.kind == .text && overflows(item) {
                NSColor.systemRed.setStroke()
                let outline = NSBezierPath(rect: item.rect); outline.lineWidth = 1.5 / zoom; outline.stroke()
            }
            for item in page.elements where selectedIDs.contains(item.id) {
                NSColor.controlAccentColor.setStroke()
                let isEditing = item.id == editingID
                let outline = NSBezierPath(rect: isEditing ? item.rect.insetBy(dx: -2 / zoom, dy: -2 / zoom) : item.rect)
                outline.lineWidth = 1.6 / zoom
                if isEditing { outline.setLineDash([3 / zoom, 2 / zoom], count: 2, phase: 0) }
                outline.stroke()
                if selectedIDs.count == 1 {
                    for direction in resizeHandles(for: item) {
                        let point = direction.point(in: item.rect)
                        let handle = CGRect(x: point.x - 4 / zoom, y: point.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom)
                        NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke()
                        let path = NSBezierPath(rect: handle); path.lineWidth = 1 / zoom; path.stroke()
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let label = "\(index + 1)  /  \(document.pages.count)   ·   A4"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: index == activePage ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]
            NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: rect.minX, y: rect.minY - 21))
        }
    }

    func resizeHandles(for item: PaperElement) -> [CanvasResizeHandle] {
        item.kind == .text ? CanvasResizeHandle.allCases : [.bottomRight]
    }
    func resizeHandle(at point: CGPoint, for item: PaperElement) -> CanvasResizeHandle? {
        resizeHandles(for: item).first { handle in
            let center = handle.point(in: item.rect)
            return CGRect(x: center.x - 7 / zoom, y: center.y - 7 / zoom, width: 14 / zoom, height: 14 / zoom).contains(point)
        }
    }
    /// The opposite edge remains fixed; all distances are in A4 points, independent
    /// of the display zoom. Never allow a resize to invert or cross a page edge.
    func resizedRect(_ original: CGRect, kind: ElementKind, handle: CanvasResizeHandle,
                     delta: CGPoint, preserveAspect: Bool) -> CGRect {
        guard [original.minX, original.minY, original.width, original.height, delta.x, delta.y].allSatisfy({ $0.isFinite }),
              original.width > 0, original.height > 0 else { return original }
        // Imported projects may contain objects extending beyond a sheet. Bring the
        // starting box into a valid A4 extent before applying a bounded resize delta.
        let original = CGRect(x: max(0, min(paperWidth - min(original.width, paperWidth), original.minX)),
                              y: max(0, min(paperHeight - min(original.height, paperHeight), original.minY)),
                              width: min(original.width, paperWidth), height: min(original.height, paperHeight))
        let delta = CGPoint(x: max(-paperWidth, min(paperWidth, delta.x)), y: max(-paperHeight, min(paperHeight, delta.y)))
        if kind == .image && handle == .bottomRight && preserveAspect {
            let ratio = original.width / original.height
            var width = max(24, original.width + delta.x)
            var height = max(24, original.height + delta.y)
            if abs(delta.x) >= abs(delta.y * ratio) { height = width / ratio } else { width = height * ratio }
            let fit = min(1, min(max(0, paperWidth - original.minX) / width, max(0, paperHeight - original.minY) / height))
            return CGRect(origin: original.origin, size: CGSize(width: max(1, width * fit), height: max(1, height * fit)))
        }
        var left = original.minX, right = original.maxX, top = original.minY, bottom = original.maxY
        let minWidth = min(24, original.width), minHeight = min(24, original.height)
        if handle.movesLeft { left = max(0, min(right - minWidth, left + delta.x)) }
        if handle.movesRight { right = min(paperWidth, max(left + minWidth, right + delta.x)) }
        if handle.movesTop { top = max(0, min(bottom - minHeight, top + delta.y)) }
        if handle.movesBottom { bottom = min(paperHeight, max(top + minHeight, bottom + delta.y)) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    override func mouseDown(with event: NSEvent) {
        if isPanActive {
            window?.makeFirstResponder(self)
            panDragLocation = event.locationInWindow
            cancelObjectDrag()
            updatePanCursor()
            return
        }
        guard isInteractionEnabled else { return }
        cancelObjectDrag()
        let previousEditingID = editingID
        finishEditing()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        var selectedHandle: (page: Int, item: PaperElement, handle: CanvasResizeHandle)?
        if selectedIDs.count == 1 {
            for (index, page) in document.pages.enumerated() {
                if let item = page.elements.first(where: { selectedIDs.contains($0.id) }),
                   let handle = resizeHandle(at: localPoint(point, page: index), for: item) {
                    selectedHandle = (index, item, handle); break
                }
            }
        }
        guard let page = selectedHandle?.page ?? pageIndex(at: point) else { selectedIDs = []; onSelection?(); needsDisplay = true; return }
        activePage = page
        let local = localPoint(point, page: page)
        let elements = document.pages[page].elements
        let hit = selectedHandle?.item ?? elements.reversed().first {
            ($0.id == previousEditingID ? $0.rect.insetBy(dx: -7 / zoom, dy: -7 / zoom) : $0.rect).contains(local)
        }
        if let hit {
            if event.modifierFlags.contains(.shift) && selectedHandle == nil {
                if selectedIDs.contains(hit.id) { selectedIDs.remove(hit.id) } else { selectedIDs.insert(hit.id) }
            } else if !selectedIDs.contains(hit.id) { selectedIDs = [hit.id] }
            if event.clickCount == 2 && hit.kind == .text && selectedHandle == nil {
                selectedIDs = [hit.id]; startEditing(hit.id)
                if let editor = textEditor {
                    let position = editor.characterIndexForInsertion(at: editor.convert(event.locationInWindow, from: nil))
                    let range = editor.selectionRange(forProposedRange: NSRange(location: position, length: 0), granularity: .selectByWord)
                    editor.setSelectedRange(range)
                }
                return
            }
            dragStart = point
            dragSourcePage = page
            dragSourcePageID = document.pages[page].id
            dragHandle = selectedHandle?.handle
            dragElements = elements.filter { selectedIDs.contains($0.id) }
            didDrag = false
        } else {
            selectedIDs = []
            dragElements = []
            if event.clickCount == 2 { onNewText?(page, local); return }
        }
        window?.invalidateCursorRects(for: self)
        onSelection?(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let previous = panDragLocation {
            let point = event.locationInWindow
            panDragLocation = point
            panViewport(by: CGPoint(x: previous.x - point.x, y: point.y - previous.y))
            return
        }
        guard isInteractionEnabled, hasValidObjectDrag else { cancelObjectDrag(); return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = (point.x - dragStart.x) / zoom
        let dy = (point.y - dragStart.y) / zoom
        guard dx.isFinite, dy.isFinite else { return }
        // Ignore hand tremor and prevent a mouse-down/up from creating undo entries.
        if !didDrag && hypot(point.x - dragStart.x, point.y - dragStart.y) < 2 { return }
        if !didDrag { onWillChange?(); didDrag = true }
        guard hasValidObjectDrag else { cancelObjectDrag(); return }
        for original in dragElements {
            guard let index = document.pages[dragSourcePage].elements.firstIndex(where: { $0.id == original.id }) else { continue }
            let rect: CGRect
            if let handle = dragHandle {
                rect = resizedRect(original.rect, kind: original.kind, handle: handle, delta: CGPoint(x: dx, y: dy),
                                   preserveAspect: !event.modifierFlags.contains(.shift))
            } else {
                rect = original.rect.offsetBy(dx: dx, dy: dy)
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
        guard isInteractionEnabled, didDrag, hasValidObjectDrag else { cancelObjectDrag(); return }
        let point = convert(event.locationInWindow, from: nil)
        let targetPage = pageIndex(at: point) ?? dragSourcePage
        if dragHandle == nil && targetPage != dragSourcePage {
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
        cancelObjectDrag()
        onChange?(); onSelection?(); needsDisplay = true
    }
    private var hasValidObjectDrag: Bool {
        !dragElements.isEmpty && document.pages.indices.contains(dragSourcePage)
            && document.pages[dragSourcePage].id == dragSourcePageID
            && dragElements.allSatisfy { original in selectedIDs.contains(original.id) && document.pages[dragSourcePage].elements.contains { $0.id == original.id } }
    }
    private func cancelObjectDrag() {
        dragElements = []; didDrag = false; dragSourcePageID = nil; dragHandle = nil
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
        guard isInteractionEnabled else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d" {
            onDuplicate?(); return
        }
        if event.keyCode == 51 || event.keyCode == 117 { cancelObjectDrag(); onDelete?(); return }
        if event.keyCode == 53 { cancelObjectDrag(); selectedIDs = []; onSelection?(); needsDisplay = true; return }
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
        guard isInteractionEnabled else { return }
        cancelObjectDrag()
        finishEditing()
        guard let item = document.pages.flatMap(\.elements).first(where: { $0.id == id && $0.kind == .text }) else { return }
        editingID = id
        selectedIDs = [id]
        let originalText = item.attributedText
        editingOriginalText = originalText; editingOriginalRTF = item.textRTF
        lastCommittedText = originalText; hasEditingCheckpoint = false
        let storage = NSTextStorage(attributedString: originalText)
        let manager = NSLayoutManager()
        manager.backgroundLayoutEnabled = false
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
    /// Snapshot before the first committed mutation. Controller.checkpoint calls back
    /// into syncEditing, so suppress that recursion until it has captured the old model.
    func prepareTextMutation() {
        guard editingID != nil, !hasEditingCheckpoint, !isPreparingTextCheckpoint else { return }
        hasEditingCheckpoint = true
        isPreparingTextCheckpoint = true
        onWillChange?()
        isPreparingTextCheckpoint = false
    }
    @discardableResult func syncEditing() -> Bool {
        guard !isPreparingTextCheckpoint, let id = editingID, let editor = textEditor, !editor.hasMarkedText() else { return false }
        let current = editor.attributedString()
        if let last = lastCommittedText, current.isEqual(to: last) { return false }
        guard let pageIndex = document.pages.firstIndex(where: { $0.elements.contains(where: { $0.id == id }) }),
              let itemIndex = document.pages[pageIndex].elements.firstIndex(where: { $0.id == id }) else { return false }
        prepareTextMutation()
        // A callback may have replaced the document. Recheck IDs before writing.
        guard document.pages.indices.contains(pageIndex), document.pages[pageIndex].elements.indices.contains(itemIndex),
              document.pages[pageIndex].elements[itemIndex].id == id else { return false }
        if let original = editingOriginalText, current.isEqual(to: original) {
            document.pages[pageIndex].elements[itemIndex].textRTF = editingOriginalRTF
        } else {
            document.pages[pageIndex].elements[itemIndex].setText(current)
        }
        lastCommittedText = NSAttributedString(attributedString: current)
        return true
    }
    func finishEditing() {
        guard let editor = textEditor, !isFinishingEditing else { return }
        isFinishingEditing = true
        // Resigning first lets the input method finalize a candidate through AppKit.
        // Never persist a still-marked composition as if it were committed text.
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }
        let changed = syncEditing()
        editor.delegate = nil
        editor.onFinish = nil
        editor.inputContext?.discardMarkedText()
        editor.undoManager?.removeAllActions()
        editor.removeFromSuperview()
        textEditor = nil; editingID = nil
        editingOriginalText = nil; editingOriginalRTF = nil; lastCommittedText = nil
        hasEditingCheckpoint = false; isFinishingEditing = false
        if changed { onChange?() }
        onSelection?(); needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    func textDidChange(_ notification: Notification) {
        if syncEditing() { onChange?(); needsDisplay = true }
        if textEditor?.hasMarkedText() != true { onSelection?() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let editor = textEditor, notification.object as? NSTextView === editor, !editor.hasMarkedText() else { return }
        onSelection?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isInteractionEnabled ? .copy : [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { isInteractionEnabled }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isInteractionEnabled else { return false }
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
