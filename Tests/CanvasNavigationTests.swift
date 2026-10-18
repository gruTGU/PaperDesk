import AppKit

func testCanvasNavigation() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DeskError.message("Canvas navigation: \(message)") }
    }
    func near(_ first: CGFloat, _ second: CGFloat) -> Bool { abs(first - second) < 0.01 }
    func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        try require(condition(), message)
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
    scroll.borderType = .noBorder
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    window.contentView = scroll
    let canvas = CanvasView(frame: .zero)
    canvas.document = PaperDocument(pages: [PaperPage(elements: [.text("保留文字")]), PaperPage()], zoom: 2, pageGap: 28)
    scroll.documentView = canvas
    canvas.updateSize(viewport: scroll.contentSize)
    let originalDocument = canvas.document
    let originalSelection: Set<UUID> = [canvas.document.pages[0].elements[0].id]
    canvas.selectedIDs = originalSelection
    var changes = 0
    canvas.onWillChange = { changes += 1 }
    canvas.onChange = { changes += 1 }
    canvas.onSelection = { changes += 1 }
    let clip = scroll.contentView
    canvas.panViewport(by: CGPoint(x: 130, y: 210))
    try require(near(clip.bounds.minX, 130) && near(clip.bounds.minY, 210), "horizontal and vertical scroll offsets")
    canvas.panViewport(by: CGPoint(x: 100_000, y: 100_000))
    try require(near(clip.bounds.maxX, canvas.bounds.maxX) && near(clip.bounds.maxY, canvas.bounds.maxY), "clamp at right/bottom edges")
    canvas.panViewport(by: CGPoint(x: -100_000, y: -100_000))
    try require(near(clip.bounds.minX, 0) && near(clip.bounds.minY, 0), "clamp at left/top edges")
    canvas.panViewport(by: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
    try require(clip.bounds.origin == .zero, "ignore non-finite deltas")
    let target = CGPoint(x: canvas.pageRect(1).minX + 200 * canvas.zoom - clip.bounds.width / 2,
                         y: canvas.pageRect(1).minY + 300 * canvas.zoom - clip.bounds.height / 2)
    canvas.panViewport(by: target)
    let anchor = canvas.captureViewportAnchor()!
    try require(anchor.pageID == canvas.document.pages[1].id && near(anchor.pointOnPage.x, 200) && near(anchor.pointOnPage.y, 300), "capture second-page center")
    canvas.document.zoom = 2.5
    canvas.updateSize(viewport: scroll.contentSize)
    canvas.restoreViewportAnchor(anchor)
    let restored = canvas.captureViewportAnchor()!
    try require(restored.pageID == anchor.pageID && near(restored.pointOnPage.x, 200) && near(restored.pointOnPage.y, 300), "zoom retains the point under viewport center")
    canvas.document.zoom = originalDocument.zoom
    canvas.updateSize(viewport: scroll.contentSize)
    canvas.panViewport(by: CGPoint(x: 240 - clip.bounds.minX, y: 300 - clip.bounds.minY))
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func dragHand() {
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 250, y: 200)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 150)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 150)))
    }
    canvas.isPanningMode = true
    dragHand()
    try require(near(clip.bounds.minX, 190) && near(clip.bounds.minY, 250), "hand drag moves page with pointer in both axes")
    canvas.isPanningMode = false
    func space(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }
    canvas.keyDown(with: space(.keyDown))
    dragHand()
    canvas.keyUp(with: space(.keyUp))
    try require(near(clip.bounds.minX, 140) && near(clip.bounds.minY, 200), "space temporarily enables hand drag")
    try require(canvas.document == originalDocument && canvas.selectedIDs == originalSelection && changes == 0, "panning leaves document, selection and undo callbacks untouched")
    let bitmap = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(NSColor.systemBlue.cgColor)
    bitmap.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
    let imageData = try ImageTools.encode(bitmap.makeImage()!, format: .png)
    canvas.document.pages[0].elements.append(PaperElement(kind: .image, x: 30, y: 30, width: 20, height: 10, imageData: imageData))
    canvas.document.pages[1].elements.append(PaperElement(kind: .image, x: 30, y: 30, width: 20, height: 10, imageData: imageData))
    canvas.panViewport(by: CGPoint(x: -clip.bounds.minX, y: -clip.bounds.minY))
    canvas.rebuildImages()
    try waitUntil("visible preview completes asynchronously") { canvas.pendingPreviewCount == 0 }
    try require(canvas.cachedImageCount == 1 && canvas.cachedImageBytes >= 800, "decoded cache reports visible page footprint without decoding offscreen pages")
    let withImage = canvas.document
    canvas.clearImageCache()
    try require(canvas.cachedImageCount == 0 && canvas.cachedImageBytes == 0 && canvas.document == withImage, "cache cleanup preserves embedded project images")
    canvas.document.zoom = 0.5
    canvas.updateSize(viewport: scroll.contentSize)
    canvas.panViewport(by: CGPoint(x: -100_000, y: 0))
    canvas.panViewport(by: CGPoint(x: 80, y: 0))
    try require(near(clip.bounds.minX, 80), "zoomed-out sheets can still move horizontally")
    try testCanvasStability()
    print("PASS canvas horizontal panning, edge clamping, center-preserving zoom, hand/space drag, and decoded cache cleanup")
}


/// Regression tests cover real interruption paths rather than only normal mouse-up sequences.
func testCanvasStability() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DeskError.message("Canvas stability: \(message)") }
    }
    func waitUntil(_ message: String, timeout: TimeInterval = 8, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        try require(condition(), message)
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 850))
    window.contentView = scroll
    let canvas = CanvasView(frame: .zero)
    scroll.documentView = canvas
    canvas.document.pages = [PaperPage(), PaperPage(elements: [.text("拖动中的文字", x: 30, y: 30, width: 200, height: 100)])]
    canvas.updateSize(viewport: scroll.contentSize)
    func event(_ type: NSEvent.EventType, page: Int, x: CGFloat) -> NSEvent {
        let frame = canvas.pageRect(page)
        let point = canvas.convert(CGPoint(x: frame.minX + x, y: frame.minY + 40), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    canvas.mouseDown(with: event(.leftMouseDown, page: 1, x: 40))
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 1, x: 55))
    canvas.document.pages.remove(at: 1)
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 1, x: 70))
    canvas.mouseUp(with: event(.leftMouseUp, page: 1, x: 70))
    try require(canvas.document.pages.count == 1, "deleting source page during drag cancels safely")

    canvas.document.pages[0].elements = [.text("原页", x: 30, y: 30, width: 200, height: 100)]
    canvas.mouseDown(with: event(.leftMouseDown, page: 0, x: 40))
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 0, x: 55))
    let replacement = PaperPage(elements: [.text("替换后的页", x: 30, y: 30, width: 200, height: 100)])
    canvas.document.pages[0] = replacement
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 0, x: 70))
    canvas.mouseUp(with: event(.leftMouseUp, page: 0, x: 70))
    try require(canvas.document.pages[0] == replacement, "undo/replacement cannot mutate a different page at the same index")

    canvas.mouseDown(with: event(.leftMouseDown, page: 0, x: 40))
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 0, x: 55))
    canvas.document.pages[0] = replacement
    canvas.selectedIDs = [] // Undo/Esc clears selection even when page and object IDs survive.
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 0, x: 80))
    canvas.mouseUp(with: event(.leftMouseUp, page: 0, x: 80))
    try require(canvas.document.pages[0] == replacement, "undo of the same object cancels the in-flight drag")

    let textID = replacement.elements[0].id
    canvas.startEditing(textID)
    let finishedEditor = canvas.textEditor
    canvas.finishEditing()
    try require(canvas.textEditor == nil && window.firstResponder !== finishedEditor, "finishing text detaches first responder before releasing editor")
    canvas.isInteractionEnabled = false
    canvas.selectedIDs = [textID]
    var deleted = false
    canvas.onDelete = { deleted = true }
    let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!
    canvas.keyDown(with: delete)
    canvas.startEditing(textID)
    canvas.mouseDown(with: event(.leftMouseDown, page: 0, x: 40))
    canvas.mouseDragged(with: event(.leftMouseDragged, page: 0, x: 80))
    canvas.mouseUp(with: event(.leftMouseUp, page: 0, x: 80))
    try require(!deleted && canvas.textEditor == nil && canvas.document.pages[0] == replacement, "busy canvas blocks edits and deletion")
    canvas.panViewport(by: CGPoint(x: 10, y: 0))
    try require(scroll.contentView.bounds.minX > 0, "busy canvas still allows navigation")
    canvas.isInteractionEnabled = true

    var text = PaperElement.text("短文字", width: 250, height: 100)
    try require(!canvas.overflows(text) && !canvas.overflows(text), "overflow cache can reuse unchanged layout")
    text.setText(TextStyle.make(String(repeating: "一行很长的文字。", count: 1000)))
    try require(canvas.overflows(text), "RTF change invalidates overflow cache")
    text.width = 9000; text.height = 9000
    try require(!canvas.overflows(text), "size change invalidates overflow cache")

    let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 12000, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
    let data = try ImageTools.encode(context.makeImage()!, format: .png)
    let largeImage = PaperElement(kind: .image, x: 20, y: 20, width: 80, height: 80, imageData: data)
    canvas.document = PaperDocument(pages: [PaperPage(elements: [largeImage]), PaperPage(elements: [PaperElement(kind: .image, x: 20, y: 20, width: 80, height: 80, imageData: data)])])
    canvas.updateSize(viewport: scroll.contentSize)
    canvas.panViewport(by: CGPoint(x: -100000, y: -100000))
    canvas.rebuildImages()
    try waitUntil("bounded preview finishes") { canvas.pendingPreviewCount == 0 }
    try require(canvas.cachedImageCount == 1 && canvas.cachedImageBytes <= 2048 * 2048 * 4, "large source uses bounded thumbnail rather than full decoded pixels")
    let fullPreviewBytes = canvas.cachedImageBytes
    canvas.clearImageCache(); canvas.rebuildImages()
    canvas.document.pages[0].elements[0].crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
    canvas.rebuildImages()
    try waitUntil("changed crop preview finishes") { canvas.pendingPreviewCount == 0 }
    try require(canvas.cachedImageCount == 1 && canvas.cachedImageBytes < fullPreviewBytes, "stale full-image decode cannot overwrite a newer crop request")
    canvas.document.pages[0].elements[0].crop = .full
    canvas.invalidateImages(); canvas.rebuildImages()
    // Increase the visible count while that full-size request is still queued.
    for index in 1...7 {
        canvas.document.pages[0].elements.append(PaperElement(kind: .image, x: 20 + Double(index % 4) * 90, y: 20 + Double(index / 4) * 90, width: 80, height: 80, imageData: data))
    }
    canvas.rebuildImages()
    try waitUntil("visible collage previews finish") { canvas.pendingPreviewCount == 0 }
    try require(canvas.cachedImageCount == 8 && canvas.cachedImageBytes <= CanvasView.imageCacheBudget, "collage thumbnails remain within the 64 MiB budget")
    let badImage = PaperElement(kind: .image, x: 20, y: 300, width: 80, height: 80, imageData: Data("broken image".utf8))
    canvas.document.pages[0].elements.append(badImage)
    canvas.rebuildImages()
    try waitUntil("invalid preview completes") { canvas.pendingPreviewCount == 0 }
    try require(canvas.failedPreviewCount == 1, "invalid preview is cached as a failed placeholder")
    for _ in 0..<5 { canvas.rebuildImages() }
    try require(canvas.pendingPreviewCount == 0, "failed preview does not continuously retry during redraw")
    canvas.panViewport(by: CGPoint(x: 0, y: canvas.pageRect(1).minY + 100))
    canvas.rebuildImages()
    try waitUntil("scrolled preview finishes") { canvas.pendingPreviewCount == 0 }
    try require(canvas.cachedImageCount <= 1, "scrolling evicts offscreen image pixels")
    canvas.clearImageCache()
    canvas.rebuildImages()
    canvas.clearImageCache()
    // Pump the queue to make any queued decode completion prove its generation check.
    let deadline = Date().addingTimeInterval(0.2)
    while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    try require(canvas.cachedImageCount == 0 && canvas.pendingPreviewCount == 0, "clearing cache prevents stale background completion from refilling it")
    print("PASS interrupted drag/undo, text responder lifetime, busy navigation, overflow invalidation, asynchronous bounded previews, offscreen eviction and failed-preview caching")
}
