import AppKit

/// Each tab is a real window with an independent document, undo history and recovery file.
final class WorkspaceController {
    private(set) var editors: [EditorController] = []
    let recoveryDirectory: URL
    var storageController: StorageWindowController?
    weak var lastActiveEditor: EditorController?

    init(recoveryDirectory: URL = StorageManager.recoveryDirectory) {
        self.recoveryDirectory = recoveryDirectory
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var activeEditor: EditorController? {
        editors.first { $0.window === NSApp.keyWindow } ?? editors.first { $0.window === NSApp.mainWindow } ?? lastActiveEditor ?? editors.last
    }
    var activeRecoveryURLs: Set<URL> { Set(editors.map(\.restorationURL) + editors.compactMap(\.currentURL)) }

    @discardableResult
    func create(document: PaperDocument = PaperDocument(), url: URL? = nil, imported: Bool = false,
                tabbedWith existing: EditorController? = nil, recoveryURL: URL? = nil, present: Bool = true) -> EditorController {
        let editor = EditorController(restorationURL: recoveryURL ?? recoveryDirectory.appendingPathComponent("Recovery-\(UUID().uuidString).paperdesk"))
        editor.workspace = self
        editors.append(editor)
        editor.load(document, url: url, imported: imported)
        if present {
            if let existing { existing.canvas.syncEditing(); existing.window.addTabbedWindow(editor.window, ordered: .above) }
            editor.show(center: existing == nil)
            if editor.window.tabGroup?.isTabBarVisible != true { editor.window.toggleTabBar(nil) }
        }
        return editor
    }

    func newDocument(from editor: EditorController?, separate: Bool = false) {
        create(tabbedWith: separate ? nil : editor)
    }

    @discardableResult
    func open(_ url: URL, from editor: EditorController? = nil, present: Bool = true) throws -> EditorController {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = editors.first(where: { $0.currentURL?.standardizedFileURL.resolvingSymlinksInPath() == canonical || $0.restorationURL.standardizedFileURL.resolvingSymlinksInPath() == canonical }) {
            if present { existing.window.makeKeyAndOrderFront(nil) }
            return existing
        }
        let native = url.pathExtension.lowercased() == "paperdesk"
        let document = try native ? ProjectStore.read(url) : DocumentConversion.importDocument(from: url)
        return create(document: document, url: native ? url : nil, imported: !native, tabbedWith: editor, present: present)
    }

    func remove(_ editor: EditorController) {
        editors.removeAll { $0 === editor }
        if lastActiveEditor === editor { lastActiveEditor = editors.last }
        if editors.isEmpty { storageController?.close() }
    }

    func canSave(_ url: URL, for editor: EditorController) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        return !editors.contains { $0.restorationURL.standardizedFileURL.resolvingSymlinksInPath() == path || ($0 !== editor && $0.currentURL?.standardizedFileURL.resolvingSymlinksInPath() == path) }
    }

    func mayTerminate() -> Bool {
        // Do not discard any recovery until all documents agree to close.
        for editor in editors {
            editor.window.makeKeyAndOrderFront(nil)
            if !editor.mayReplaceDocument() { return false }
        }
        editors.forEach { $0.removeRecovery() }
        return true
    }

    func offerRecoveries() {
        let files: [URL]
        do { files = try StorageManager.recoveryFiles().filter { !activeRecoveryURLs.contains($0) } }
        catch { activeEditor?.showError(error); return }
        guard !files.isEmpty, let parent = activeEditor else { return }
        let alert = NSAlert()
        alert.messageText = "找到 \(files.count) 份未保存的作业备份"
        alert.informativeText = "恢复后会分别打开为标签，请保存为工程文件。暂不恢复的备份仍可在“存储空间”中查看。"
        alert.addButton(withTitle: "恢复全部")
        alert.addButton(withTitle: "暂不恢复")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var anchor = parent
        for url in files {
            do {
                let document = try ProjectStore.read(url)
                anchor = create(document: document, imported: true, tabbedWith: anchor, recoveryURL: url)
            } catch { parent.showError(error) }
        }
    }

    func showStorage(relativeTo window: NSWindow) {
        if storageController == nil {
            storageController = StorageWindowController(activeRecoveryURLs: { [weak self] in self?.activeRecoveryURLs ?? [] }, memoryCacheUsage: { [weak self] in
                let canvases = self?.editors.map(\.canvas) ?? []
                return (count: canvases.reduce(0) { $0 + $1.cachedImageCount }, bytes: canvases.reduce(Int64(0)) { $0 + Int64($1.cachedImageBytes) })
            }, clearMemoryCache: { [weak self] in self?.editors.forEach { $0.canvas.clearImageCache() } })
        }
        storageController?.show(relativeTo: window)
    }
}
