import AppKit

/// A reservation must identify an on-disk name even before that file exists.
/// Resolving symlinks alone only repairs the casing of already existing components.
enum DocumentPathIdentity {
    static func key(for url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var existing = resolved
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }
            existing = parent
        }
        let supportsCaseSensitiveNames = (try? existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
        let normalized = resolved.path.precomposedStringWithCanonicalMapping
        // When volume metadata is unavailable, reject ambiguous aliases conservatively
        // rather than allow a second asynchronous writer to overwrite the same target.
        guard supportsCaseSensitiveNames == true else {
            return normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
        }
        return normalized
    }

    static func matches(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return key(for: lhs) == key(for: rhs)
    }
}

/// Each tab is a real window with an independent document, undo history and recovery file.
final class WorkspaceController {
    private(set) var editors: [EditorController] = []
    let recoveryDirectory: URL
    var storageController: StorageWindowController?
    weak var lastActiveEditor: EditorController?
    private var retiringRecoveryQueues: [UUID: DispatchQueue] = [:]
    private(set) var isTerminating = false

    init(recoveryDirectory: URL = StorageManager.recoveryDirectory) {
        self.recoveryDirectory = recoveryDirectory
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var activeEditor: EditorController? {
        editors.first { $0.window === NSApp.keyWindow } ?? editors.first { $0.window === NSApp.mainWindow } ?? lastActiveEditor ?? editors.last
    }
    var activeRecoveryURLs: Set<URL> { Set(editors.map(\.restorationURL) + editors.compactMap(\.currentURL) + editors.compactMap(\.pendingSaveURL)) }

    func isActiveRecoveryURL(_ url: URL) -> Bool {
        let identity = DocumentPathIdentity.key(for: url)
        return activeRecoveryURLs.contains { DocumentPathIdentity.key(for: $0) == identity }
    }

    func owner(of url: URL) -> EditorController? {
        let identity = DocumentPathIdentity.key(for: url)
        return editors.first { editor in
            [editor.currentURL, editor.restorationURL, editor.pendingSaveURL].compactMap { $0 }.contains {
                DocumentPathIdentity.key(for: $0) == identity
            }
        }
    }

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
        guard !isTerminating else { return }
        create(tabbedWith: separate ? nil : editor)
    }

    @discardableResult
    func open(_ url: URL, from editor: EditorController? = nil, present: Bool = true) throws -> EditorController {
        if let existing = owner(of: url) {
            if present { existing.window.makeKeyAndOrderFront(nil) }
            return existing
        }
        let native = url.pathExtension.lowercased() == "paperdesk"
        let document = try native ? ProjectStore.read(url) : DocumentConversion.importDocument(from: url)
        let opened = create(document: document, url: native ? url : nil, imported: !native, tabbedWith: editor, present: present)
        opened.fileExperience.sourceURL = url
        return opened
    }

    func remove(_ editor: EditorController) {
        let token = UUID()
        retiringRecoveryQueues[token] = editor.recoveryQueue
        editor.recoveryQueue.async { [weak self] in
            DispatchQueue.main.async { self?.retiringRecoveryQueues.removeValue(forKey: token) }
        }
        editors.removeAll { $0 === editor }
        if lastActiveEditor === editor { lastActiveEditor = editors.last }
        if editors.isEmpty { storageController?.close() }
    }

    func canSave(_ url: URL, for editor: EditorController) -> Bool {
        let identity = DocumentPathIdentity.key(for: url)
        return !editors.contains { other in
            if DocumentPathIdentity.key(for: other.restorationURL) == identity { return true }
            guard other !== editor else { return false }
            return [other.currentURL, other.pendingSaveURL].compactMap { $0 }.contains {
                DocumentPathIdentity.key(for: $0) == identity
            }
        }
    }

    func mayTerminate() -> Bool {
        guard !isTerminating else { return true }
        // Do not discard any recovery until all documents agree to close.
        var confirmed: [ObjectIdentifier: PaperDocument] = [:]
        while let editor = editors.first(where: { confirmed[ObjectIdentifier($0)] != $0.canvas.document }) {
            editor.window.makeKeyAndOrderFront(nil)
            if !editor.mayReplaceDocument(afterSave: { NSApp.terminate(nil) }) { return false }
            confirmed[ObjectIdentifier(editor)] = editor.canvas.document
        }
        // A modal save/discard prompt pumps events. An already-confirmed window can
        // start an export without changing its document snapshot during that prompt.
        if let busy = editors.first(where: \.exporting) {
            busy.window.makeKeyAndOrderFront(nil)
            busy.showError(DeskError.message("文档任务仍在处理中，请完成后再退出。"))
            return false
        }
        isTerminating = true
        editors.forEach { $0.autosaveTimer?.invalidate(); $0.setWorking("正在退出"); $0.removeRecovery() }
        return true
    }

    /// Includes the last window's queue even after its editor has left `editors`.
    /// Do not block the main thread while an older large recovery write is finishing.
    func finishRecoveryCleanup(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for queue in editors.map(\.recoveryQueue) + Array(retiringRecoveryQueues.values) {
            group.enter(); queue.async { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func offerRecoveries() {
        guard !isTerminating else { return }
        let files: [URL]
        do { files = try StorageManager.recoveryFiles().filter { !isActiveRecoveryURL($0) } }
        catch { activeEditor?.showError(error); return }
        guard !files.isEmpty, let parent = activeEditor else { return }
        let alert = PaperDeskAppearance.alert()
        alert.messageText = "找到 \(files.count) 份未保存的作业备份"
        alert.informativeText = "恢复后会分别打开为标签，请保存为工程文件。暂不恢复的备份仍可在“存储空间”中查看。"
        alert.addButton(withTitle: "恢复全部")
        alert.addButton(withTitle: "暂不恢复")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = parent.exporting ? create() : parent
        host.runTask("正在读取恢复备份", work: {
            files.map { url in (url, autoreleasepool { Result { try ProjectStore.read(url) } }) }
        }, completion: { [weak self, weak host] results in
            guard let self, let host else { return }
            var anchor = host
            var errors: [String] = []
            for (url, result) in results {
                switch result {
                case .success(let document):
                    guard !self.isActiveRecoveryURL(url) else { continue }
                    anchor = self.create(document: document, imported: true, tabbedWith: anchor, recoveryURL: url)
                case .failure(let error): errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !errors.isEmpty { anchor.showError(DeskError.message(errors.joined(separator: "\n"))) }
        })
    }

    func showStorage(relativeTo window: NSWindow) {
        if storageController == nil {
            storageController = StorageWindowController(activeRecoveryURLs: { [weak self] in self?.activeRecoveryURLs ?? [] }, memoryCacheUsage: { [weak self] in
                let canvases = self?.editors.map(\.canvas) ?? []
                return (count: canvases.reduce(0) { $0 + $1.cachedImageCount }, bytes: canvases.reduce(Int64(0)) { $0 + Int64($1.cachedImageBytes) })
            }, clearMemoryCache: { [weak self] in self?.editors.forEach { $0.canvas.clearImageCache() } }, canDeleteRecoveries: { [weak self] in self?.editors.contains(where: \.exporting) != true })
        }
        storageController?.show(relativeTo: window)
    }
}
