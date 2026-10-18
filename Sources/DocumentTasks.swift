import AppKit

/// Only immutable document snapshots cross this queue. Views and editing state stay on main.
enum DocumentTasks {
    static let queue = DispatchQueue(label: "local.paperdesk.document-work", qos: .userInitiated)
}

extension EditorController {
    func setWorking(_ title: String?) {
        taskName = title
        exporting = title != nil
        canvas.isInteractionEnabled = !exporting
        func update(_ view: NSView) {
            if let control = view as? NSControl { control.isEnabled = !exporting }
            for child in view.subviews { update(child) }
        }
        if let root = window.contentView { update(root) }
        taskIndicator.isHidden = !exporting
        if exporting { taskIndicator.startAnimation(nil) } else { taskIndicator.stopAnimation(nil) }
        refreshSelection()
    }

    @discardableResult
    func runTask<T>(_ title: String, work: @escaping () throws -> T, completion: @escaping (T) -> Void) -> Bool {
        guard !exporting, !isClosed, workspace?.isTerminating != true else { return false }
        guard workspace?.storageController?.deletingRecoveries != true, standaloneStorage?.deletingRecoveries != true else {
            showError(DeskError.message("正在清理恢复备份，请清理完成后重试。")); return false
        }
        canvas.finishEditing()
        setWorking(title)
        DocumentTasks.queue.async { [weak self] in
            let result = autoreleasepool { Result { try work() } }
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                self.setWorking(nil)
                switch result {
                case .success(let value): completion(value)
                case .failure(let error):
                    self.statusLabel.stringValue = title + "失败"
                    self.showError(error)
                }
            }
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if exporting {
            return [#selector(quit), #selector(newDocument), #selector(newWindow), #selector(nextTab), #selector(previousTab), #selector(closeDocument)].contains(menuItem.action)
        }
        if menuItem.action == #selector(undoAction) || menuItem.action == #selector(redoAction) {
            let undo = menuItem.action == #selector(undoAction)
            if canvas.textEditor?.hasMarkedText() == true { return false }
            if let field = window.firstResponder as? NSTextView, field !== canvas.textEditor, field.isFieldEditor {
                return undo ? field.undoManager?.canUndo == true : field.undoManager?.canRedo == true
            }
            let textUndo = undo ? canvas.textEditor?.undoManager?.canUndo : canvas.textEditor?.undoManager?.canRedo
            return textUndo == true || (undo ? !undoStack.isEmpty : !redoStack.isEmpty)
        }
        if [#selector(toggleBold), #selector(toggleItalic), #selector(toggleUnderline), #selector(fitTextHeight)].contains(menuItem.action) {
            return canvas.selectedElement?.kind == .text && canvas.textEditor?.hasMarkedText() != true
        }
        if menuItem.action == #selector(duplicateSelection) { return !canvas.selectedIDs.isEmpty && canvas.textEditor?.hasMarkedText() != true }
        if menuItem.action == #selector(locateOverflow) { return canvas.document.pages.flatMap(\.elements).contains { canvas.overflows($0) } }
        return true
    }

    func openDocuments(_ urls: [URL], completion: ((Bool) -> Void)? = nil) {
        guard !urls.isEmpty, !exporting, !isClosed, workspace?.isTerminating != true else { completion?(false); return }
        var remaining: [URL] = []
        var seen = Set<String>()
        for url in urls {
            let canonical = DocumentPathIdentity.key(for: url)
            guard seen.insert(canonical).inserted else { continue }
            if let owner = workspace?.owner(of: url) { owner.window.makeKeyAndOrderFront(nil) }
            else { remaining.append(url) }
        }
        guard !remaining.isEmpty else { completion?(true); return }
        let started = runTask("正在打开 \(remaining.count) 份文档", work: {
            remaining.map { url -> (URL, Result<PaperDocument, Error>) in
                (url, autoreleasepool { Result {
                    try url.pathExtension.lowercased() == "paperdesk" ? ProjectStore.read(url) : DocumentConversion.importDocument(from: url)
                } })
            }
        }, completion: { [weak self] results in
            guard let self else { return }
            var anchor = self
            var failures: [String] = []
            for (url, result) in results {
                switch result {
                case .success(let doc):
                    let native = url.pathExtension.lowercased() == "paperdesk"
                    if let workspace = self.workspace {
                        // A path can be opened by a second window while the read is queued.
                        if let existing = workspace.owner(of: url) {
                            existing.window.makeKeyAndOrderFront(nil); anchor = existing
                        } else {
                            anchor = workspace.create(document: doc, url: native ? url : nil, imported: !native, tabbedWith: anchor)
                            anchor.fileExperience.sourceURL = url
                        }
                    } else {
                        self.load(doc, url: native ? url : nil, imported: !native)
                        self.fileExperience.sourceURL = url
                    }
                case .failure(let error): failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { anchor.showError(DeskError.message(failures.joined(separator: "\n"))) }
            completion?(failures.isEmpty)
        })
        if !started { completion?(false) }
    }

    func saveAsynchronously(to url: URL, completion: (() -> Void)? = nil) {
        guard !exporting, !isClosed, workspace?.isTerminating != true else { return }
        canvas.finishEditing()
        do { try checkSaveDestination(url) } catch { showError(error); return }
        var snapshot = canvas.document
        snapshot.title = url.deletingPathExtension().lastPathComponent
        // Reserve the path until the writer finishes so another tab cannot overwrite it.
        pendingSaveURL = url
        let started = runTask("正在保存工程", work: { () -> Result<PaperDocument, Error> in
            Result { try ProjectStore.write(snapshot, to: url); return snapshot }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.pendingSaveURL = nil
            switch result {
            case .success(let document):
                self.canvas.document = document; self.savedDocument = document; self.currentURL = url
                self.dirty = false; self.window.isDocumentEdited = false
                self.removeRecovery(); self.refresh()
                self.recordOutput(to: url, message: "已保存：\(url.lastPathComponent)")
                completion?()
            case .failure(let error): self.showError(error)
            }
        })
        if !started { pendingSaveURL = nil }
    }

    func checkSaveDestination(_ url: URL) throws {
        guard !DocumentPathIdentity.matches(url, restorationURL), workspace?.canSave(url, for: self) != false else {
            throw DeskError.message("此路径正在被其他标签或自动恢复备份使用，请选择其他文件名。")
        }
    }
}
