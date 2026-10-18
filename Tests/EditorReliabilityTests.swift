import AppKit

func testEditorReliability() throws {
    var checks = 0
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !value() { throw DeskError.message("Editor reliability: \(message)") }
    }
    func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        try require(condition(), message)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDesk-reliability-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let workspace = WorkspaceController(recoveryDirectory: folder.appendingPathComponent("Recovery"))
    let first = workspace.create(document: PaperDocument(title: "后台保存", pages: [PaperPage(elements: [.text("中文与 Emoji 👩‍💻")])]), imported: true, present: false)
    let second = workspace.create(present: false)
    first.autosaveTimer?.invalidate(); second.autosaveTimer?.invalidate()
    defer {
        first.recoveryQueue.sync {}; second.recoveryQueue.sync {}
        if let sheet = first.window.attachedSheet { first.window.endSheet(sheet) }
    }

    // Deterministically hold only the worker, proving the main run loop stays available.
    let gate = DispatchSemaphore(value: 0)
    DocumentTasks.queue.async { _ = gate.wait(timeout: .now() + 10) }
    let destination = folder.appendingPathComponent("异步保存.paperdesk")
    first.saveAsynchronously(to: destination)
    try require(first.exporting && !first.canvas.isInteractionEnabled, "saving locks only this document's editing")
    try require(!workspace.canSave(destination, for: second), "an in-flight Save As reserves its destination")
    var mainWasResponsive = false
    DispatchQueue.main.async { mainWasResponsive = true }
    try wait("main event loop responds while writer is held") { mainWasResponsive }
    second.checkpoint(); second.canvas.document.title = "另一份仍可编辑"; second.didChange()
    try require(second.dirty && second.canvas.isInteractionEnabled, "other document remains editable")
    var duplicateWorkRan = false
    let accepted = first.runTask("重复任务", work: { duplicateWorkRan = true }, completion: { _ in })
    try require(!accepted && !duplicateWorkRan, "same-window task reentry is rejected")
    var refusedOpen: Bool?
    first.openDocuments([destination]) { refusedOpen = $0 }
    try require(refusedOpen == false, "a refused open replies immediately to its caller")
    gate.signal()
    try wait("asynchronous save finishes") { !first.exporting }
    let stored = try ProjectStore.read(destination)
    try require(stored == first.canvas.document && !first.dirty && first.currentURL == destination, "saved state matches completed snapshot")
    try require(first.pendingSaveURL == nil && first.canvas.isInteractionEnabled, "saving releases the path and controls")
    try require(first.taskIndicator.isHidden, "progress indicator clears on completion")

    // A queued backup followed by Save/Discard must never resurrect the old recovery.
    first.canvas.document.title = "旧恢复内容"; first.didChange()
    let recoveryGate = DispatchSemaphore(value: 0)
    first.recoveryQueue.async { _ = recoveryGate.wait(timeout: .now() + 10) }
    first.writeRecovery()
    first.canvas.document.title = "新恢复内容"; first.didChange()
    first.removeRecovery()
    recoveryGate.signal(); first.recoveryQueue.sync {}
    try wait("backup completion returns to main") { !first.recoveryPending }
    try require(!FileManager.default.fileExists(atPath: first.restorationURL.path), "queued cleanup follows older writes")
    first.writeRecovery(); first.recoveryQueue.sync {}
    try wait("new recovery finishes") { !first.recoveryPending }
    let recovered = try ProjectStore.read(first.restorationURL)
    try require(recovered.title == "新恢复内容", "next backup contains the latest state")
    let previousDate = try FileManager.default.attributesOfItem(atPath: first.restorationURL.path)[.modificationDate] as? Date
    first.writeRecovery(); first.recoveryQueue.sync {}
    let currentDate = try FileManager.default.attributesOfItem(atPath: first.restorationURL.path)[.modificationDate] as? Date
    try require(previousDate == currentDate && !first.recoveryPending, "unchanged document is not repeatedly encoded and written")

    let originalBytes = try Data(contentsOf: destination)
    first.saveAsynchronously(to: folder)
    try wait("failed save returns controls") { !first.exporting }
    try require(first.pendingSaveURL == nil && first.dirty && first.currentURL == destination, "failed save preserves document and destination")
    let afterFailure = try Data(contentsOf: destination)
    try require(originalBytes == afterFailure, "failed save leaves original bytes unchanged")
    if let sheet = first.window.attachedSheet { first.window.endSheet(sheet) }

    let image = PaperElement(kind: .image, x: 10, y: 10, width: 100, height: 200, imageData: Data([1]))
    first.canvas.document.pages[0].elements.append(image); first.canvas.selectedIDs = [image.id]
    first.refreshSelection()
    let beforeGeometry = first.canvas.document
    first.geometry[2].stringValue = "1e306"
    first.applyGeometry(first.geometry[2])
    try require(first.canvas.document == beforeGeometry, "overflowing ratio arithmetic cannot insert NaN geometry")
    if let sheet = first.window.attachedSheet { first.window.endSheet(sheet) }
    first.fontSizeField.stringValue = "1e309"
    first.insertText(page: 0, at: CGPoint(x: 20, y: 20))
    let font = first.canvas.textEditor?.typingAttributes[.font] as? NSFont
    try require(font?.pointSize.isFinite == true && font?.pointSize == 14, "nonfinite typed font sizes safely fall back")
    first.canvas.finishEditing()
    let previousZoom = first.canvas.document.zoom
    first.setZoom(.nan); first.setZoom(.infinity)
    try require(first.canvas.document.zoom == previousZoom, "invalid zoom leaves geometry unchanged")
    first.canvas.selectedIDs = []; first.refreshSelection()
    try require(first.textControls.allSatisfy { !$0.isEnabled } && first.contextualButtons.allSatisfy { !$0.isEnabled }, "irrelevant text/image actions disable without a selection")
    let beforeStaleSelection = first.canvas.activePage
    let oldPageButton = NSButton(); oldPageButton.tag = 999
    first.selectPage(oldPageButton)
    try require(first.canvas.activePage == beforeStaleSelection, "stale page controls cannot select a removed page")

    // Close and release the active text view repeatedly without stale responder callbacks.
    for index in 0..<12 {
        let editor = workspace.create(document: PaperDocument(title: "生命周期\(index)", pages: [PaperPage(elements: [.text("文本")])]), present: false)
        editor.autosaveTimer?.invalidate()
        editor.canvas.startEditing(editor.canvas.document.pages[0].elements[0].id)
        editor.canvas.finishEditing()
        editor.window.close()
    }
    try require(workspace.editors.count == 2, "closing many editors removes their lifecycle owners")
    let recoveryPath = folder.appendingPathComponent("并发恢复.paperdesk")
    let recoveryDocument = PaperDocument(title: "待恢复作业")
    try ProjectStore.write(recoveryDocument, to: recoveryPath)
    let openGate = DispatchSemaphore(value: 0)
    DocumentTasks.queue.async { _ = openGate.wait(timeout: .now() + 10) }
    second.openDocuments([recoveryPath])
    let recoveredOwner = workspace.create(document: recoveryDocument, recoveryURL: recoveryPath, present: false)
    recoveredOwner.autosaveTimer?.invalidate()
    openGate.signal()
    try wait("queued open checks recovery ownership again") { !second.exporting }
    try require(workspace.editors.count == 3, "open cannot duplicate a recovery owner created while reading")
    recoveredOwner.window.close()

    let retiring = workspace.create(document: PaperDocument(title: "最后关闭的作业"), imported: true, present: false)
    retiring.autosaveTimer?.invalidate()
    let closeGate = DispatchSemaphore(value: 0)
    retiring.recoveryQueue.async { _ = closeGate.wait(timeout: .now() + 10) }
    retiring.writeRecovery(); retiring.removeRecovery(); retiring.window.close()
    var cleanupFinished = false
    workspace.finishRecoveryCleanup { cleanupFinished = true }
    try require(!cleanupFinished, "termination waits for the removed editor's pending cleanup")
    closeGate.signal()
    try wait("termination cleanup completes without blocking main") { cleanupFinished }
    try require(!FileManager.default.fileExists(atPath: retiring.restorationURL.path), "last-window discard cannot resurrect a recovery")
    retiring.saveAsynchronously(to: folder.appendingPathComponent("closed.paperdesk"))
    try require(retiring.pendingSaveURL == nil && !retiring.exporting, "a closed editor cannot reserve a save destination")
    print("PASS \(checks) editor reliability checks: responsive workers, save reservations/failure, recovery ordering, invalid geometry/font, contextual controls and repeated text-window close")
}
