import AppKit

func testWorkspace() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DeskError.message("Workspace: \(message)") }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDesk-workspace-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = WorkspaceController(recoveryDirectory: folder.appendingPathComponent("Recovery"))
    let first = workspace.create(document: PaperDocument(title: "作业甲", pages: [PaperPage(elements: [.text("甲的内容")])]), present: false)
    let second = workspace.create(document: PaperDocument(title: "作业乙", pages: [PaperPage(elements: [.text("乙的内容")])]), present: false)
    defer { workspace.editors.forEach { $0.autosaveTimer?.invalidate() } }
    try require(workspace.editors.count == 2 && first.restorationURL != second.restorationURL, "documents require separate controllers and recovery paths")
    let firstSaved = first.canvas.document
    first.checkpoint(); first.canvas.document.title = "甲的新标题"; first.didChange()
    second.checkpoint(); second.canvas.document.title = "乙的新标题"; second.didChange()
    first.writeRecovery(); second.writeRecovery()
    let recoveryA = try ProjectStore.read(first.restorationURL), recoveryB = try ProjectStore.read(second.restorationURL)
    try require(recoveryA.title == "甲的新标题" && recoveryB.title == "乙的新标题", "recovery content must not overwrite the other document")
    for destination in [first.restorationURL, second.restorationURL] {
        var rejected = false
        do { try first.saveProject(to: destination) } catch { rejected = true }
        try require(rejected, "Save As must reject every active recovery path")
    }
    let recoveryBAfter = try ProjectStore.read(second.restorationURL)
    try require(recoveryBAfter == recoveryB, "rejected Save As must preserve recovery bytes")
    let recoveredOwner = try workspace.open(first.restorationURL, present: false)
    try require(recoveredOwner === first && workspace.editors.count == 2, "opening an active recovery activates its owner")
    first.undoAction()
    try require(first.canvas.document == firstSaved && second.canvas.document.title == "乙的新标题" && second.undoStack.count == 1, "undo history is independent")
    let original = folder.appendingPathComponent("原件.paperdesk")
    try first.saveProject(to: original)
    let originalBytes = try Data(contentsOf: original)
    first.checkpoint(); first.canvas.document.pages[0].elements.append(.text("副本新增内容", y: 250)); first.didChange()
    let copy = folder.appendingPathComponent("副本.paperdesk")
    try first.saveProject(to: copy)
    let unchanged = try Data(contentsOf: original)
    let copied = try ProjectStore.read(copy)
    try require(unchanged == originalBytes && copied.pages[0].elements.count == 2 && first.currentURL == copy && !first.dirty, "Save As keeps the original intact and switches the active destination")
    try require(FileManager.default.fileExists(atPath: second.restorationURL.path) && !FileManager.default.fileExists(atPath: first.restorationURL.path), "saving one document only removes its own recovery")
    do { try second.saveProject(to: copy); throw DeskError.message("expected active-path conflict") }
    catch { try require(second.currentURL == nil && second.dirty, "failed save must preserve unsaved document state") }
    let preservedCopy = try ProjectStore.read(copy)
    try require(preservedCopy == copied, "active destination must remain intact")
    let reopened = try workspace.open(copy, present: false)
    try require(reopened === first && workspace.editors.count == 2, "opening an already open path switches to its existing controller")
    do { _ = try workspace.open(folder.appendingPathComponent("missing.paperdesk"), present: false) } catch {}
    try require(workspace.editors.count == 2, "failed open must not replace any document or add a broken tab")
    first.marginFields[0].stringValue = "10"
    first.marginFields[1].stringValue = "20"
    first.marginFields[2].stringValue = "25"
    first.marginFields[3].stringValue = "30"
    let elementsBefore = first.canvas.document.pages[0].elements
    first.applyMargins()
    try require(abs(first.canvas.document.margins.left * 25.4 / 72 - 25) < 0.01 && first.canvas.document.pages[0].elements == elementsBefore, "four controls update margins without moving existing elements")
    first.addText(); first.canvas.finishEditing()
    let added = first.canvas.document.pages[0].elements.last!
    try require(abs(added.x - first.canvas.document.contentRect.minX) < 0.01 && added.rect.maxX <= first.canvas.document.contentRect.maxX + 0.01, "new text uses adjusted margins")
    first.window.setContentSize(NSSize(width: 1080, height: 680))
    first.window.contentView?.layoutSubtreeIfNeeded(); first.updateLayout()
    try require(first.scroll.frame.width >= 600 && first.scroll.frame.height >= 350, "minimum window size must leave a usable canvas")
    print("PASS independent documents, undo/recovery isolation, Save As original preservation, open/save conflict protection, four margin controls and minimum window layout")
}
