import AppKit

func testCanvasNavigation() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DeskError.message("Canvas navigation: \(message)") }
    }
    func near(_ first: CGFloat, _ second: CGFloat) -> Bool { abs(first - second) < 0.01 }
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
    try require(canvas.cachedImageCount == 1 && canvas.cachedImageBytes >= 800, "decoded cache reports visible page footprint without decoding offscreen pages")
    let withImage = canvas.document
    canvas.clearImageCache()
    try require(canvas.cachedImageCount == 0 && canvas.cachedImageBytes == 0 && canvas.document == withImage, "cache cleanup preserves embedded project images")
    canvas.document.zoom = 0.5
    canvas.updateSize(viewport: scroll.contentSize)
    canvas.panViewport(by: CGPoint(x: -100_000, y: 0))
    canvas.panViewport(by: CGPoint(x: 80, y: 0))
    try require(near(clip.bounds.minX, 80), "zoomed-out sheets can still move horizontally")
    print("PASS canvas horizontal panning, edge clamping, center-preserving zoom, hand/space drag, and decoded cache cleanup")
}
