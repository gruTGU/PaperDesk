import AppKit
import PDFKit

func testFileExperience() throws {
    var checks = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw DeskError.message("File experience: \(message)") }
    }
    func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks += 1; return }
        throw DeskError.message("File experience: \(message)")
    }
    func wait(_ message: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        try require(predicate(), message)
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDesk-file-experience-\(UUID().uuidString)")
    let projects = folder.appendingPathComponent("Projects"), imports = folder.appendingPathComponent("Imports"), exports = folder.appendingPathComponent("Exports")
    for location in [projects, imports, exports] { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(at: folder) }

    let all = try PDFPageSelection.indices(.all, pageCount: 5)
    try require(all == [0, 1, 2, 3, 4], "all pages remain in document order")
    let current = try PDFPageSelection.indices(.current, pageCount: 5, currentPage: 3)
    try require(current == [3], "current page uses a zero-based canvas index")
    let selected = try PDFPageSelection.indices(.custom("5, 1, 3-4, 3,1"), pageCount: 5)
    try require(selected == [0, 2, 3, 4], "ranges deduplicate and retain document order")
    let chinese = try PDFPageSelection.indices(.custom(" 1，3–4、5 "), pageCount: 5)
    try require(chinese == [0, 2, 3, 4], "Chinese separators and typographic dash are accepted")
    let repeatedRange = try PDFPageSelection.indices(.custom("2-2,2"), pageCount: 5)
    try require(repeatedRange == [1], "single-page ranges are valid and deduplicated")
    for expression in ["", " ", "0", "6", "-1", "1,", ",1", "1,,2", "4-2", "1-2-3", "2-", "1.5", "+1", "1 2", "NaN", "9999999999999999999999999", String(repeating: "1", count: 10_001)] {
        try rejects("invalid page range accepted: \(expression.prefix(40))") { _ = try PDFPageSelection.indices(.custom(expression), pageCount: 5) }
    }
    try rejects("missing current page accepted") { _ = try PDFPageSelection.indices(.current, pageCount: 2, currentPage: 2) }
    try rejects("empty source document accepted") { _ = try PDFPageSelection.indices(.all, pageCount: 0) }

    var fileState = DocumentFileExperience()
    let project = projects.appendingPathComponent("观察.paperdesk")
    let source = imports.appendingPathComponent("观察.docx")
    let exported = exports.appendingPathComponent("观察.pdf")
    let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    try require(fileState.directory(currentURL: nil, exporting: false).path == fallback.path, "unsaved project gets a predictable Documents fallback")
    fileState.sourceURL = source
    try require(fileState.directory(currentURL: nil, exporting: true).path == imports.path, "first imported-document export starts beside its source")
    try require(fileState.directory(currentURL: project, exporting: true).path == projects.path, "saved project folder takes priority over import source")
    fileState.lastExportURL = exported
    try require(fileState.directory(currentURL: project, exporting: true).path == exports.path, "next export remembers the last successful output folder")
    try require(fileState.directory(currentURL: project, exporting: false).path == projects.path, "Save As remains beside the editable project")
    fileState.lastExportURL = folder.appendingPathComponent("removed/output.pdf")
    try require(fileState.directory(currentURL: project, exporting: true).path == projects.path, "deleted export folder falls back to the project folder")
    try require(fileState.suggestedName(title: "观察", ext: "docx") == "观察-导出.docx", "lossy imported DOCX gets a distinct suggested name")
    try require(fileState.suggestedName(title: "观察.paperdesk", ext: "PDF") == "观察.pdf", "known old extensions are replaced and output extension normalized")
    try require(fileState.suggestedName(title: "观察.v2", ext: "pdf") == "观察.v2.pdf", "ordinary version suffixes are retained")
    try require(fileState.suggestedName(title: "观察", ext: "paperdesk", isSaveAs: true) == "观察-副本.paperdesk", "Save As suggests an editable copy")
    try require(fileState.suggestedName(title: "  ", ext: "pdf") == "未命名作业.pdf", "empty title receives a useful filename")
    try require(fileState.suggestedName(title: "作业/实验:1\n草稿", ext: "pdf") == "作业-实验-1-草稿.pdf", "title cannot inject directories or control characters")

    let rangeUI = PDFPageRangeAccessory(pageCount: 5, currentPage: 2)
    try require(!rangeUI.customPages.isEnabled && rangeUI.summary.stringValue.contains("5 / 5"), "PDF panel defaults to a clear all-pages summary")
    rangeUI.choice.selectItem(at: 1); rangeUI.changed()
    let uiCurrent = try rangeUI.selectedPages()
    try require(uiCurrent == [2] && rangeUI.summary.stringValue.contains("1 / 5"), "PDF panel current-page option matches canvas selection")
    rangeUI.choice.selectItem(at: 2); rangeUI.customPages.stringValue = "1,3-5"; rangeUI.changed()
    try require(rangeUI.customPages.isEnabled && rangeUI.summary.stringValue.contains("4 / 5"), "PDF panel displays the custom selection count")
    rangeUI.customPages.stringValue = "6"; rangeUI.changed()
    try require(rangeUI.summary.textColor == .systemRed, "invalid range has inline feedback")
    try rejects("native save panel validation accepted invalid range") { try rangeUI.panel(NSSavePanel(), validate: exported) }

    let pages = (1...5).map { index in PaperPage(elements: [.text("PAGE-\(index)", height: 100)]) }
    let document = PaperDocument(title: "范围验收", pages: pages)
    try PDFExporter.write(document, to: exported, pageIndices: [4, 0, 2, 2])
    guard let pdf = PDFDocument(url: exported) else { throw DeskError.message("File experience: exported PDF cannot be reopened") }
    try require(pdf.pageCount == 3, "selected-page PDF contains exactly three pages")
    try require(pdf.page(at: 0)?.string?.contains("PAGE-1") == true && pdf.page(at: 1)?.string?.contains("PAGE-3") == true && pdf.page(at: 2)?.string?.contains("PAGE-5") == true, "PDF contains the requested source pages in source order")
    let goodBytes = try Data(contentsOf: exported)
    for invalidIndices in [[], [-1], [5]] {
        try rejects("PDF accepted invalid indices \(invalidIndices)") { try PDFExporter.write(document, to: exported, pageIndices: invalidIndices) }
        let bytes = try Data(contentsOf: exported)
        try require(bytes == goodBytes, "invalid range preserves an existing PDF")
    }
    var withOverflow = document
    withOverflow.pages[1].elements = [.text(String(repeating: "Overflow ", count: 1000), width: 30, height: 15)]
    try PDFExporter.write(withOverflow, to: exported, pageIndices: [0])
    try require(PDFDocument(url: exported)?.pageCount == 1, "overflow outside the selected pages does not block PDF export")
    let beforeOverflowFailure = try Data(contentsOf: exported)
    try rejects("selected-page overflow must block PDF") { try PDFExporter.write(withOverflow, to: exported, pageIndices: [1]) }
    let afterOverflowFailure = try Data(contentsOf: exported)
    try require(beforeOverflowFailure == afterOverflowFailure, "failed selected-page export protects the existing output")

    let editor = EditorController(restorationURL: folder.appendingPathComponent("Recovery.paperdesk"))
    editor.autosaveTimer?.invalidate()
    defer {
        editor.recoveryQueue.sync {}
        if let sheet = editor.window.attachedSheet { editor.window.endSheet(sheet) }
        editor.window.close()
    }
    editor.load(document, url: nil, imported: true)
    let beforeDocument = editor.canvas.document, beforeSaved = editor.savedDocument, beforeDirty = editor.dirty
    let accepted = editor.exportAsynchronously(to: exported, kind: "PDF", work: { try PDFExporter.write(document, to: exported, pageIndices: [0, 4]) })
    try require(accepted, "export starts on the document worker")
    try wait("export finishes") { !editor.exporting }
    try require(editor.canvas.document == beforeDocument && editor.savedDocument == beforeSaved && editor.dirty == beforeDirty && editor.currentURL == nil, "export leaves unsaved project content, path and dirty state unchanged")
    try require(editor.fileExperience.lastExportURL == exported, "successful export records its output location")
    try require(editor.fileExperience.pendingExportURL == nil, "successful export releases its destination")
    try require(editor.statusLabel.stringValue.contains("已导出 PDF"), "successful export provides actionable feedback")
    let untouchedState = editor.fileExperience.lastExportURL
    let failedOutput = exports.appendingPathComponent("failed.pdf")
    let missingDirectory = exports.appendingPathComponent("missing/failed.pdf")
    let sentinel = Data("original file must survive".utf8)
    try sentinel.write(to: failedOutput)
    var badImage = document
    badImage.pages[0].elements = [PaperElement(kind: .image, x: 20, y: 20, width: 100, height: 100, imageData: Data([1, 2, 3]))]
    let invalidSnapshot = badImage
    try require(editor.exportAsynchronously(to: failedOutput, kind: "PDF", work: { try PDFExporter.write(invalidSnapshot, to: failedOutput) }), "corrupt-image export starts but reports a worker failure")
    try wait("failed export restores controls") { !editor.exporting }
    if let sheet = editor.window.attachedSheet { editor.window.endSheet(sheet) }
    let bytesAfterFailure = try Data(contentsOf: failedOutput)
    try require(bytesAfterFailure == sentinel, "render failure preserves an existing output file")
    try rejects("invalid directory must fail export") { try PDFExporter.write(document, to: missingDirectory) }
    try require(editor.fileExperience.lastExportURL == untouchedState && editor.currentURL == nil && editor.dirty == beforeDirty, "failed export cannot replace successful output history or saved state")
    try require(editor.fileExperience.pendingExportURL == nil && editor.canvas.isInteractionEnabled, "failed export releases its path and editing lock")

    let reservationWorkspace = WorkspaceController(recoveryDirectory: folder.appendingPathComponent("Reservations"))
    let exportingEditor = reservationWorkspace.create(present: false), otherEditor = reservationWorkspace.create(present: false)
    exportingEditor.autosaveTimer?.invalidate(); otherEditor.autosaveTimer?.invalidate()
    defer { exportingEditor.window.close(); otherEditor.window.close() }
    let gate = DispatchSemaphore(value: 0)
    DocumentTasks.queue.async { _ = gate.wait(timeout: .now() + 10) }
    exportingEditor.exportAsynchronously(to: exported, kind: "PDF", work: { try PDFExporter.write(document, to: exported) })
    try require(exportingEditor.fileExperience.pendingExportURL == exported, "in-flight output reserves its destination")
    try rejects("another tab may overwrite a pending export") { try otherEditor.checkExportDestination(exported) }
    try require(!exportingEditor.windowShouldClose(exportingEditor.window), "a pending export prevents closing its document")
    if let sheet = exportingEditor.window.attachedSheet { exportingEditor.window.endSheet(sheet) }
    try require(!reservationWorkspace.mayTerminate() && !reservationWorkspace.isTerminating, "quit is deferred while export is still pending")
    if let sheet = exportingEditor.window.attachedSheet { exportingEditor.window.endSheet(sheet) }
    gate.signal()
    try wait("reserved export finishes") { !exportingEditor.exporting }
    try otherEditor.checkExportDestination(exported)
    try require(exportingEditor.fileExperience.pendingExportURL == nil, "completed output can be deliberately selected again")

    guard let context = CGContext(data: nil, width: 192, height: 128, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw DeskError.message("File experience: image test bitmap allocation failed")
    }
    for y in 0..<128 {
        for x in 0..<192 {
            context.setFillColor(CGColor(red: CGFloat((x * 17 + y * 3) % 256) / 255,
                                         green: CGFloat((x * 11 + y * 29) % 256) / 255,
                                         blue: CGFloat((x * 7 + y * 13) % 256) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    guard let image = context.makeImage() else { throw DeskError.message("File experience: image test fixture failed") }
    let imageOutput = exports.appendingPathComponent("压缩副本.jpeg")
    try require(ImageFormat.jpeg.exportExtensions.contains("jpeg") && ImageFormat.heic.exportExtensions.contains("heif"), "common JPEG and HEIF alternate extensions are accepted")
    try require(editor.exportImageAsynchronously(image, format: .jpeg, maxBytes: 2000, to: imageOutput), "image compression uses the protected export worker")
    try require(editor.fileExperience.pendingExportURL == imageOutput, "image output reserves its destination")
    try wait("image compression finishes") { !editor.exporting }
    let jpeg = try Data(contentsOf: imageOutput)
    let decoded = try ImageTools.decode(jpeg)
    try require(jpeg.count <= 2000 && jpeg.count > 0, "image export honors the actual byte limit")
    try require(editor.lastOutputURL == imageOutput && !editor.outputButton.isHidden && editor.outputButton.toolTip?.contains(imageOutput.path) == true, "image export provides its Finder result button")
    try require(editor.statusLabel.stringValue.contains("上限 2.0 KB") && editor.statusLabel.stringValue.contains("\(decoded.width) × \(decoded.height)"), "image result reports the requested ceiling and actual pixel dimensions")
    try require(editor.fileExperience.lastExportURL == imageOutput && editor.fileExperience.pendingExportURL == nil, "image exports share the successful output folder and release their reservation")
    try require(editor.canvas.document == beforeDocument && editor.currentURL == nil && editor.dirty == beforeDirty, "compressing an image leaves the native project unchanged")
    let pngOutput = exports.appendingPathComponent("透明副本.png")
    try require(editor.exportImageAsynchronously(image, format: .png, maxBytes: nil, to: pngOutput), "unlimited PNG output starts")
    try wait("PNG export finishes") { !editor.exporting }
    let pngData = try Data(contentsOf: pngOutput)
    let png = try ImageTools.decode(pngData)
    try require(png.width == image.width && png.height == image.height && !editor.statusLabel.stringValue.contains("上限"), "unlimited image export keeps original dimensions and omits a false limit")
    try require(editor.exportImageAsynchronously(image, format: .png, maxBytes: 1, to: pngOutput), "impossible compression target reports a worker failure")
    try wait("failed image export releases controls") { !editor.exporting }
    if let sheet = editor.window.attachedSheet { editor.window.endSheet(sheet) }
    let protectedPNG = try Data(contentsOf: pngOutput)
    try require(protectedPNG == pngData && editor.lastOutputURL == pngOutput && editor.fileExperience.lastExportURL == pngOutput && editor.fileExperience.pendingExportURL == nil, "failed image compression preserves original bytes and the prior successful output")

    try require(reservationWorkspace.mayTerminate() && reservationWorkspace.isTerminating, "clean windows can terminate after export completes")
    var workRanAfterTermination = false
    let refusedOnExit = exportingEditor.exportAsynchronously(to: exports.appendingPathComponent("too-late.pdf"), kind: "PDF", work: { workRanAfterTermination = true })
    try require(!refusedOnExit && !workRanAfterTermination && exportingEditor.fileExperience.pendingExportURL == nil, "termination cannot begin a new export or leak a path reservation")
    otherEditor.window.close()
    let refusedAfterClose = otherEditor.exportImageAsynchronously(image, format: .png, maxBytes: nil, to: exports.appendingPathComponent("closed.png"))
    try require(!refusedAfterClose && otherEditor.fileExperience.pendingExportURL == nil, "closed windows cannot queue image exports")

    // A document already confirmed for quit can begin an export while another
    // document's save/discard alert runs its nested event loop.
    let modalWorkspace = WorkspaceController(recoveryDirectory: folder.appendingPathComponent("ModalRecovery"))
    let confirmedEditor = modalWorkspace.create(present: false)
    let dirtyEditor = modalWorkspace.create(document: document, imported: true, present: false)
    confirmedEditor.autosaveTimer?.invalidate(); dirtyEditor.autosaveTimer?.invalidate()
    defer { confirmedEditor.window.close(); dirtyEditor.window.close() }
    let modalGate = DispatchSemaphore(value: 0)
    DocumentTasks.queue.async { _ = modalGate.wait(timeout: .now() + 10) }
    let modalExport = exports.appendingPathComponent("modal-export.pdf")
    var startedDuringConfirmation = false
    DispatchQueue.main.async {
        startedDuringConfirmation = confirmedEditor.exportAsynchronously(to: modalExport, kind: "PDF", work: { try PDFExporter.write(document, to: modalExport) })
        NSApp.stopModal(withCode: .alertThirdButtonReturn)
    }
    let terminatedDuringExport = modalWorkspace.mayTerminate()
    try require(startedDuringConfirmation && !terminatedDuringExport && !modalWorkspace.isTerminating, "quit rechecks background work after nested confirmation alerts")
    if let sheet = confirmedEditor.window.attachedSheet { confirmedEditor.window.endSheet(sheet) }
    modalGate.signal()
    try wait("export started during quit confirmation completes") { !confirmedEditor.exporting }

    let saveURL = projects.appendingPathComponent("完成保存.paperdesk")
    var didSave = false
    editor.saveAsynchronously(to: saveURL) { didSave = true }
    try wait("save completion fires only after a successful write") { !editor.exporting }
    let saved = try ProjectStore.read(saveURL)
    try require(didSave && editor.currentURL == saveURL && !editor.dirty && saved == editor.savedDocument, "save result commits the new native project path and clean state")
    try require(editor.fileExperience.lastExportURL == pngOutput, "saving the project does not forget its export folder")
    let panel = editor.makeFilePanel(ext: "paperdesk", message: "测试", isSaveAs: true)
    try require(panel.directoryURL?.path == projects.path && panel.nameFieldStringValue == "完成保存-副本.paperdesk", "Save As panel combines current location and copy filename")
    print("PASS \(checks) file experience checks: PDF ranges, panels, filenames, directories, atomic failures and independent save/export state")
}
