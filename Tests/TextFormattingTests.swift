import AppKit

func testTextFormatting() throws {
    var checks = 0
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw DeskError.message("Text formatting: \(message)") }
    }
    let controller = EditorController()
    controller.autosaveTimer?.invalidate()
    defer { controller.canvas.finishEditing(); controller.dirty = false; controller.window.orderOut(nil); controller.removeRecovery(); controller.recoveryQueue.sync {} }
    let original = TextStyle.make("Alpha beta\nSecond paragraph", size: 14)
    var item = PaperElement.text("", x: 40, y: 40, width: 280, height: 180)
    item.setText(original)
    controller.load(PaperDocument(title: "格式测试", pages: [PaperPage(elements: [item])]), url: nil, imported: false)
    controller.canvas.selectedIDs = [item.id]
    controller.canvas.startEditing(item.id)
    guard let editor = controller.canvas.textEditor else { throw DeskError.message("Missing editor") }
    let baseline = NSAttributedString(attributedString: editor.attributedString())
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    controller.fontSizeField.stringValue = "18.5"; controller.applyFontSize()
    try require(editor.attributedString().isEqual(to: baseline), "caret font size leaves existing text untouched")
    try require((editor.typingAttributes[.font] as? NSFont)?.pointSize == 18.5, "caret sets following input size")
    try require(!controller.dirty, "caret-only format does not mark document changed")
    controller.refreshTextInspector()
    try require(controller.fontSizeField.stringValue == "18.5", "fractional point size preserved")
    editor.setSelectedRange(NSRange(location: 0, length: 5))
    controller.fontSizeField.stringValue = "22"; controller.applyFontSize()
    try require((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22, "selected characters change size")
    try require((editor.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize == 14, "unselected characters keep size")
    try require(controller.dirty, "selected format marks document changed")
    if editor.undoManager?.groupingLevel ?? 0 > 0 { editor.undoManager?.endUndoGrouping() }
    controller.undoAction()
    try require(editor.attributedString().isEqual(to: baseline), "format undo restores rich text inside same editor")
    controller.redoAction()
    try require((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22, "format redo reapplies selected size")
    try require(editor.selectedRange() == NSRange(location: 0, length: 5), "format undo redo retains selection")
    editor.setSelectedRange(NSRange(location: 0, length: 10)); controller.refreshTextInspector()
    try require(controller.fontSizeField.stringValue.isEmpty && controller.fontSizeField.placeholderString == "混合", "mixed font size explicit")
    editor.setSelectedRange(NSRange(location: 0, length: 5)); controller.toggleBold()
    editor.setSelectedRange(NSRange(location: 0, length: 10)); controller.refreshTextInspector()
    try require(controller.styleButtons[0].state == .mixed, "mixed bold state visible")
    controller.toggleBold()
    var allBold = true
    editor.attributedString().enumerateAttribute(.font, in: NSRange(location: 0, length: 10)) { value, _, _ in
        if !NSFontManager.shared.traits(of: value as! NSFont).contains(.boldFontMask) { allBold = false }
    }
    try require(allBold, "mixed bold becomes uniformly bold")
    controller.fontPicker.selectItem(at: 0); controller.applyFont()
    try require(NSFontManager.shared.traits(of: editor.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.boldFontMask), "font change preserves bold")
    editor.setSelectedRange(NSRange(location: 2, length: 0)); controller.alignment.selectedSegment = 1; controller.applyAlignment()
    let first = editor.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let second = editor.textStorage!.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle
    try require(first?.alignment == .center && second?.alignment != .center, "paragraph alignment affects caret paragraph only")
    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count)); controller.refreshTextInspector()
    try require(controller.alignment.selectedSegment == -1, "mixed paragraph alignment explicit")
    controller.canvas.finishEditing()
    controller.fitTextHeight()
    let fitted = controller.canvas.selectedElement!
    try require(fitted.height < 180 && !PageDrawing.overflows(fitted), "fit height reduces empty space without clipping")
    let beforeDuplicate = controller.canvas.document
    controller.duplicateSelection()
    try require(controller.canvas.document.pages[0].elements.count == 2, "duplicate inserts one object")
    let copy = controller.canvas.selectedElement!
    try require(copy.id != item.id && copy.attributedText.isEqual(to: fitted.attributedText), "duplicate has new identity and equal rich text")
    try require(copy.x == fitted.x + 12 && copy.y == fitted.y + 12, "duplicate offset within paper")
    controller.undoAction()
    try require(controller.canvas.document == beforeDuplicate, "duplicate undo restores document")
    controller.redoAction()
    try require(controller.canvas.document.pages[0].elements.count == 2, "duplicate redo restores copy")
    controller.canvas.document.pages.append(PaperPage(elements: [.text(String(repeating: "overflow ", count: 100), width: 30, height: 24)]))
    try require(!controller.focusFirstOverflow(in: [0]), "unselected page overflow ignored")
    try require(controller.focusFirstOverflow(in: [1]) && controller.canvas.activePage == 1, "overflow navigation selects offending page")
    try require(controller.canvas.selectedElement?.kind == .text, "overflow navigation selects text box")
    try require(EditorController.formatPointSize(14) == "14" && EditorController.formatPointSize(14.25) == "14.25", "point formatting trims only redundant zeros")
    controller.fontSizeField.stringValue = "16.5"; controller.styleButtons[0].state = .on
    controller.alignment.selectedSegment = 2
    controller.insertText(page: 0, at: CGPoint(x: 100, y: 200))
    let insertedAttributes = controller.canvas.textEditor!.typingAttributes
    let insertedFont = insertedAttributes[.font] as! NSFont
    try require(insertedFont.pointSize == 16.5 && NSFontManager.shared.traits(of: insertedFont).contains(.boldFontMask), "new text inherits size and bold")
    try require((insertedAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment == .right, "new text inherits paragraph alignment")
    controller.canvas.finishEditing()
    let beforeFieldUndo = controller.canvas.document
    controller.fontSizeField.selectText(nil)
    if let field = controller.window.firstResponder as? NSTextView, field.isFieldEditor {
        field.undoManager?.removeAllActions()
        controller.undoAction()
        try require(controller.canvas.document == beforeFieldUndo, "empty field-editor undo never removes document objects")
    } else { throw DeskError.message("Text formatting: font size field did not acquire field editor") }
    print("Text formatting: \(checks) checks passed")
}
