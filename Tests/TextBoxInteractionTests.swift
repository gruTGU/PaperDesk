import AppKit

/// Exercises native text input and canvas events together: these paths previously
/// created dirty documents on focus changes and made corner drags the only resize.
func testTextBoxInteraction() throws {
    var checks = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw DeskError.message("Text box interaction: \(message)") }
    }
    func near(_ first: CGFloat, _ second: CGFloat) -> Bool { abs(first - second) < 0.01 }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
    let canvas = CanvasView(frame: .zero)
    window.contentView = scroll; scroll.documentView = canvas
    var original = PaperElement.text("Hello world\n中文与 Emoji 👩‍💻", x: 60, y: 80, width: 300, height: 160)
    let colored = NSMutableAttributedString(attributedString: original.attributedText)
    colored.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 5))
    original.setText(colored)
    let originalDocument = PaperDocument(pages: [PaperPage(elements: [original])])
    canvas.document = originalDocument
    canvas.updateSize(viewport: scroll.contentSize)
    var snapshots: [PaperDocument] = [], changes = 0, selections = 0
    canvas.onWillChange = {
        // Match the real controller: checkpoint recursively requests a text sync.
        canvas.syncEditing(); snapshots.append(canvas.document)
    }
    canvas.onChange = { changes += 1 }
    canvas.onSelection = { selections += 1 }
    for _ in 0..<3 { canvas.startEditing(original.id); canvas.finishEditing() }
    try require(canvas.document == originalDocument && snapshots.isEmpty && changes == 0,
                "entering and leaving unchanged rich text keeps the exact RTF, dirty state, and undo history")

    canvas.startEditing(original.id)
    let editor = canvas.textEditor!
    let initialColor = editor.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    try require(initialColor?.usingColorSpace(.sRGB) == NSColor.systemRed.usingColorSpace(.sRGB), "opening a text box preserves existing colors")
    let priorSelections = selections
    editor.setSelectedRange(NSRange(location: 1, length: 4))
    try require(selections > priorSelections, "cursor and selection changes refresh formatting controls")
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    editor.insertText(" 已提交", replacementRange: editor.selectedRange())
    canvas.syncEditing()
    try require(snapshots.count == 1 && snapshots[0] == originalDocument, "first native input checkpoints the previous text, not the new input")
    try require(canvas.document.pages[0].elements[0].attributedText.string.hasSuffix(" 已提交"), "native committed input updates the model")
    editor.insertText("。", replacementRange: editor.selectedRange())
    canvas.syncEditing()
    try require(snapshots.count == 1, "a continuous text editing session adds one project undo snapshot")
    let sessionChanges = changes
    canvas.finishEditing()
    try require(changes == sessionChanges && canvas.textEditor == nil && window.firstResponder !== editor,
                "finishing already-synchronized input neither dirties again nor retains first responder")
    try require(editor.undoManager?.canUndo == false, "closing a text session discards native undo references")
    canvas.document = snapshots.removeLast()
    canvas.startEditing(original.id)
    try require(canvas.textEditor?.string == original.attributedText.string && canvas.textEditor?.undoManager?.canUndo == false,
                "project undo restores the original text and the next text session has independent undo")
    canvas.finishEditing()

    snapshots.removeAll(); changes = 0
    canvas.startEditing(original.id)
    let composing = canvas.textEditor!
    composing.setSelectedRange(NSRange(location: composing.string.utf16.count, length: 0))
    composing.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: composing.selectedRange())
    try require(composing.hasMarkedText(), "native composition establishes a marked range")
    canvas.syncEditing(); canvas.textDidChange(Notification(name: NSText.didChangeNotification, object: composing))
    try require(canvas.document == originalDocument && snapshots.isEmpty && changes == 0,
                "autosave/sync does not serialize unfinished IME composition or create undo history")
    let marked = composing.markedRange()
    composing.insertText("你", replacementRange: marked)
    canvas.syncEditing()
    try require(!composing.hasMarkedText() && canvas.document.pages[0].elements[0].attributedText.string.hasSuffix("你"),
                "committing an IME candidate writes the final text")
    try require(snapshots.count == 1 && snapshots[0] == originalDocument, "IME commit keeps the original pre-composition undo snapshot")
    canvas.finishEditing()

    canvas.document = originalDocument; snapshots.removeAll(); changes = 0
    canvas.startEditing(original.id)
    let cancelled = canvas.textEditor!
    cancelled.setSelectedRange(NSRange(location: cancelled.string.utf16.count, length: 0))
    cancelled.setMarkedText("weiwancheng", selectedRange: NSRange(location: 3, length: 0), replacementRange: cancelled.selectedRange())
    canvas.finishEditing()
    try require(canvas.document == originalDocument && snapshots.isEmpty && changes == 0,
                "ending an unfinished synthetic composition never persists the temporary phonetic spelling")

    canvas.startEditing(original.id)
    let undoEditor = canvas.textEditor!
    undoEditor.undoManager?.groupsByEvent = false
    undoEditor.undoManager?.beginUndoGrouping()
    undoEditor.insertText("x", replacementRange: undoEditor.selectedRange())
    undoEditor.undoManager?.endUndoGrouping()
    try require(undoEditor.undoManager?.canUndo == true, "native typing registers an undo operation on the session manager")
    undoEditor.undoManager?.undo()
    try require(canvas.document == originalDocument, "native text undo restores the exact original RTF bytes and clean state")
    undoEditor.undoManager?.redo()
    try require(canvas.document.pages[0].elements[0].attributedText.string.hasSuffix("x"), "native text redo restores the committed edit")
    canvas.finishEditing()

    canvas.document = originalDocument; snapshots.removeAll(); changes = 0
    canvas.startEditing(original.id)
    let formatting = canvas.textEditor!
    formatting.undoManager?.groupsByEvent = false
    formatting.setSelectedRange(NSRange(location: 0, length: 5))
    let formatted = NSMutableAttributedString(attributedString: formatting.attributedString())
    formatted.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: formatting.selectedRange())
    formatting.undoManager?.beginUndoGrouping()
    let applied = formatting.applyFormatting(formatted, selection: formatting.selectedRange())
    formatting.undoManager?.endUndoGrouping()
    try require(applied && snapshots.count == 1 && snapshots[0] == originalDocument, "formatting registers the old rich-text document before model sync")
    try require(formatting.undoManager?.canUndo == true, "formatting participates in the current text session undo manager")
    formatting.undoManager?.undo()
    try require(canvas.document == originalDocument && formatting.selectedRange() == NSRange(location: 0, length: 5),
                "format undo restores mixed text attributes, exact original RTF, and selection")
    formatting.undoManager?.redo()
    let underline = formatting.attributedString().attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
    let outsideUnderline = formatting.attributedString().attribute(.underlineStyle, at: 6, effectiveRange: nil) as? Int ?? 0
    try require(underline == NSUnderlineStyle.single.rawValue && outsideUnderline == 0, "format redo restores only the selected run")
    let previousCount = changes
    try require(!formatting.applyFormatting(formatting.attributedString(), selection: formatting.selectedRange()) && changes == previousCount,
                "a no-op formatting operation creates no extra text change or undo step")
    canvas.finishEditing()

    canvas.document = originalDocument
    canvas.startEditing(original.id)
    let outlined = canvas.textEditor!
    let page = canvas.pageRect(0)
    let borderPoint = CGPoint(x: page.minX + original.rect.minX, y: page.minY + original.rect.midY)
    let contentPoint = CGPoint(x: page.minX + original.x + 30, y: page.minY + original.y + 25)
    try require(canvas.hitTest(canvas.convert(borderPoint, to: canvas.superview)) === canvas, "editing border stays available for resizing")
    try require(canvas.hitTest(canvas.convert(contentPoint, to: canvas.superview)) === outlined, "text interior retains native insertion and selection behavior")
    canvas.finishEditing()

    func event(_ type: NSEvent.EventType, point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    for zoom in [0.5, 1.0, 2.5] {
        for handle in CanvasResizeHandle.allCases {
            canvas.document = originalDocument; canvas.document.zoom = zoom
            canvas.updateSize(viewport: scroll.contentSize); canvas.selectedIDs = [original.id]
            let frame = canvas.pageRect(0), local = handle.point(in: original.rect)
            let start = CGPoint(x: frame.minX + local.x * zoom, y: frame.minY + local.y * zoom)
            let end = CGPoint(x: start.x + 20 * zoom, y: start.y + 10 * zoom)
            canvas.mouseDown(with: event(.leftMouseDown, point: start))
            canvas.mouseDragged(with: event(.leftMouseDragged, point: end))
            canvas.mouseUp(with: event(.leftMouseUp, point: end))
            let actual = canvas.document.pages[0].elements[0].rect
            let expected = CGRect(x: original.x + (handle.movesLeft ? 20 : 0),
                                  y: original.y + (handle.movesTop ? 10 : 0),
                                  width: original.width + (handle.movesRight ? 20 : 0) - (handle.movesLeft ? 20 : 0),
                                  height: original.height + (handle.movesBottom ? 10 : 0) - (handle.movesTop ? 10 : 0))
            try require(near(actual.minX, expected.minX) && near(actual.minY, expected.minY)
                        && near(actual.width, expected.width) && near(actual.height, expected.height),
                        "\(handle) resize at \(zoom)x moves only the intended edges")
        }
    }
    let bounded = canvas.resizedRect(original.rect, kind: .text, handle: .topLeft, delta: CGPoint(x: -10000, y: -10000), preserveAspect: false)
    try require(bounded.minX == 0 && bounded.minY == 0 && bounded.maxX == original.rect.maxX && bounded.maxY == original.rect.maxY,
                "outward resizing stops at A4 edges and preserves the opposite corner")
    let shrunk = canvas.resizedRect(original.rect, kind: .text, handle: .topLeft, delta: CGPoint(x: 10000, y: 10000), preserveAspect: false)
    try require(shrunk.width == 24 && shrunk.height == 24 && shrunk.maxX == original.rect.maxX && shrunk.maxY == original.rect.maxY,
                "inward resizing cannot invert a text box or shrink below its minimum")
    let bottom = canvas.resizedRect(original.rect, kind: .text, handle: .bottomRight, delta: CGPoint(x: 10000, y: 10000), preserveAspect: false)
    try require(near(bottom.maxX, paperWidth) && near(bottom.maxY, paperHeight), "bottom/right edges stop at A4 boundaries")
    let invalid = canvas.resizedRect(original.rect, kind: .text, handle: .left, delta: CGPoint(x: CGFloat.nan, y: 1), preserveAspect: false)
    try require(invalid == original.rect, "non-finite mouse geometry cannot enter the document")
    let outOfBounds = canvas.resizedRect(CGRect(x: 1000, y: -20, width: 800, height: 80), kind: .text,
                                        handle: .right, delta: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0), preserveAspect: false)
    try require(outOfBounds.width > 0 && outOfBounds.minX >= 0 && outOfBounds.minY >= 0 && outOfBounds.maxX <= paperWidth,
                "off-page imported geometry cannot produce a negative-size resize")
    let image = CGRect(x: 50, y: 50, width: 200, height: 100)
    let scaled = canvas.resizedRect(image, kind: .image, handle: .bottomRight, delta: CGPoint(x: 10000, y: 10000), preserveAspect: true)
    try require(near(scaled.width / scaled.height, 2) && scaled.maxX <= paperWidth && scaled.maxY <= paperHeight,
                "image corner resize retains aspect ratio while fitting the page")
    let freeImage = canvas.resizedRect(image, kind: .image, handle: .bottomRight, delta: CGPoint(x: 0, y: 50), preserveAspect: false)
    try require(freeImage.width == 200 && freeImage.height == 150, "Shift keeps independent image width and height resizing")

    canvas.document = originalDocument; canvas.updateSize(viewport: scroll.contentSize); canvas.selectedIDs = [original.id]
    snapshots.removeAll(); changes = 0
    let frame = canvas.pageRect(0), center = CGPoint(x: frame.minX + original.rect.midX, y: frame.minY + original.rect.midY)
    canvas.mouseDown(with: event(.leftMouseDown, point: center))
    canvas.mouseDragged(with: event(.leftMouseDragged, point: CGPoint(x: center.x + 0.1, y: center.y + 0.1)))
    canvas.mouseUp(with: event(.leftMouseUp, point: center))
    try require(canvas.document == originalDocument && snapshots.isEmpty && changes == 0, "click jitter does not dirty or move an object")
    // A double click near the first word must not jump to the document end.
    let wordPoint = CGPoint(x: frame.minX + original.x + 20, y: frame.minY + original.y + 8)
    canvas.mouseDown(with: event(.leftMouseDown, point: wordPoint, clicks: 2))
    try require(canvas.textEditor != nil && canvas.textEditor!.selectedRange().location < 6 && canvas.textEditor!.selectedRange().length > 0,
                "double click edits at the clicked word instead of moving the caret to the end")
    canvas.finishEditing()
    // A selected box can be completely outside the scrolled viewport. CGRect's
    // null intersection uses infinity, which AppKit rejects as a cursor rectangle.
    canvas.document = originalDocument; canvas.document.pages.append(PaperPage())
    canvas.updateSize(viewport: scroll.contentSize); canvas.selectedIDs = [original.id]
    canvas.panViewport(by: CGPoint(x: 0, y: canvas.pageRect(1).minY))
    canvas.resetCursorRects()
    try require(canvas.document.pages[0].elements[0] == original, "offscreen resize handles create no invalid cursor rectangles")
    print("PASS \(checks) text-box interaction checks: no-op editing, rich colors, independent undo, IME commit safety, selection callbacks, editing border, 8-way resizing, zoom and A4 limits")
}
