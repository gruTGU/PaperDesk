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
    first.recoveryQueue.sync {}; second.recoveryQueue.sync {}
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
    first.recoveryQueue.sync {}
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

    // Both names are absent while the writer is held. Symlink resolution cannot
    // canonicalize their casing yet, so reservations must use the volume's rules.
    let caseSensitive = (try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames ?? false
    let queuedURL = folder.appendingPathComponent("Homework.paperdesk")
    let caseAlias = folder.appendingPathComponent("homework.paperdesk")
    let workerGate = DispatchSemaphore(value: 0)
    DocumentTasks.queue.async { _ = workerGate.wait(timeout: .now() + 10) }
    defer { workerGate.signal() }
    first.saveAsynchronously(to: queuedURL)
    try require(first.pendingSaveURL == queuedURL && first.exporting, "asynchronous save must reserve the absent destination immediately")
    try require(!FileManager.default.fileExists(atPath: queuedURL.path), "held writer must not create its destination before conflict checks")
    try require(workspace.canSave(caseAlias, for: second) == caseSensitive,
                "case aliases must conflict on insensitive volumes, and remain distinct on sensitive volumes")
    try require(workspace.isActiveRecoveryURL(caseAlias) == !caseSensitive,
                "recovery protection must include case-equivalent pending save destinations")
    if !caseSensitive {
        try require(workspace.owner(of: caseAlias) === first, "pending case alias must activate its existing owner")
        let pendingOwner = try workspace.open(caseAlias, present: false)
        try require(pendingOwner === first && workspace.editors.count == 2, "opening a pending case alias must not read a nonexistent file or create another owner")
    }
    let composed = folder.appendingPathComponent("Café.paperdesk")
    let decomposed = folder.appendingPathComponent("Cafe\u{301}.paperdesk")
    try require(DocumentPathIdentity.matches(composed, decomposed), "canonically equivalent Unicode filenames must share a reservation key")
    let nestedUpper = folder.appendingPathComponent("AbsentFolder/Nested/Task.paperdesk")
    let nestedLower = folder.appendingPathComponent("absentfolder/nested/task.paperdesk")
    try require(DocumentPathIdentity.matches(nestedUpper, nestedLower) == !caseSensitive,
                "uncreated parent directories must inherit the closest existing ancestor's volume rules")
    workerGate.signal()
    let saveDeadline = Date().addingTimeInterval(15)
    while first.exporting && Date() < saveDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try require(!first.exporting && first.pendingSaveURL == nil, "held save must finish and release its reservation")
    let caseSaved = try ProjectStore.read(queuedURL)
    try require(caseSaved == first.canvas.document && !first.dirty, "reservation checks must preserve the first writer's document")
    first.recoveryQueue.sync {}; second.recoveryQueue.sync {}
    print("PASS independent documents, undo/recovery isolation, Save As original preservation, volume-aware pending-path reservations, Unicode aliases, open/save conflict protection, four margin controls and minimum window layout")
}
