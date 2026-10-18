import AppKit
import UniformTypeIdentifiers

/// Session-only locations. Exporting never changes the editable project's saved state.
struct DocumentFileExperience {
    var sourceURL: URL?
    var lastExportURL: URL?
    var pendingExportURL: URL?

    func directory(currentURL: URL?, exporting: Bool) -> URL {
        let candidates = (exporting ? [lastExportURL] : []) + [currentURL, sourceURL]
        for candidate in candidates.compactMap({ $0 }) {
            let parent = candidate.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue { return parent }
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func suggestedName(title: String, ext: String, isSaveAs: Bool = false) -> String {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownExtensions = ["paperdesk", "pdf", "docx", "md", "markdown", "txt", "png", "jpg", "jpeg", "heic", "heif"]
        if knownExtensions.contains((base as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        base = base.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { base = "未命名作业" }
        if isSaveAs { base += "-副本" }
        else if let sourceURL,
                sourceURL.pathExtension.lowercased() == ext.lowercased(),
                sourceURL.deletingPathExtension().lastPathComponent == base {
            // DOCX/Markdown conversion is lossy. Suggest a distinct output name while
            // retaining the native save panel's explicit overwrite confirmation.
            base += "-导出"
        }
        return base + "." + ext.lowercased()
    }
}

struct PDFExportRequest {
    let url: URL
    /// Zero-based page indices in the document's reading order.
    let pageIndices: [Int]
}

/// Retained for the complete lifetime of NSSavePanel.runModal().
final class PDFPageRangeAccessory: NSObject, NSOpenSavePanelDelegate, NSTextFieldDelegate {
    let pageCount: Int
    let currentPage: Int
    let view: NSStackView
    let choice = NSPopUpButton(frame: .zero, pullsDown: false)
    let customPages = NSTextField(string: "")
    let summary = NSTextField(wrappingLabelWithString: "")

    init(pageCount: Int, currentPage: Int) {
        self.pageCount = pageCount; self.currentPage = currentPage
        view = NSStackView()
        super.init()
        let label = NSTextField(labelWithString: "页面范围")
        let row = NSStackView(views: [label, choice, customPages])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        view.addArrangedSubview(row); view.addArrangedSubview(summary)
        choice.addItems(withTitles: ["全部页面", "当前页（第 \(currentPage + 1) 页）", "自定义页码"])
        choice.target = self; choice.action = #selector(changed)
        choice.setAccessibilityLabel("PDF 页面范围")
        customPages.placeholderString = "例如 1,3-5"
        customPages.setAccessibilityLabel("PDF 自定义页码")
        customPages.toolTip = "使用逗号分隔页码，用短横线表示连续页；重复页会合并，按文档顺序导出。"
        customPages.delegate = self
        choice.widthAnchor.constraint(equalToConstant: 170).isActive = true
        customPages.widthAnchor.constraint(equalToConstant: 165).isActive = true
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        view.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        summary.font = .systemFont(ofSize: 11)
        summary.maximumNumberOfLines = 2
        summary.widthAnchor.constraint(equalToConstant: 415).isActive = true
        summary.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        view.setFrameSize(CGSize(width: 430, height: 90))
        changed()
    }

    func selectedPages() throws -> [Int] {
        switch choice.indexOfSelectedItem {
        case 0: return try PDFPageSelection.indices(.all, pageCount: pageCount, currentPage: currentPage)
        case 1: return try PDFPageSelection.indices(.current, pageCount: pageCount, currentPage: currentPage)
        default: return try PDFPageSelection.indices(.custom(customPages.stringValue), pageCount: pageCount, currentPage: currentPage)
        }
    }

    @objc func changed() {
        customPages.isEnabled = choice.indexOfSelectedItem == 2
        do {
            let pages = try selectedPages()
            summary.textColor = .secondaryLabelColor
            summary.stringValue = "将导出 \(pages.count) / \(pageCount) 页，保持原文档顺序和 A4 尺寸。"
        } catch {
            summary.textColor = .systemRed
            summary.stringValue = error.localizedDescription
        }
    }
    func controlTextDidChange(_ notification: Notification) { changed() }
    func panel(_ sender: Any, validate url: URL) throws { _ = try selectedPages() }
}

extension EditorController {
    func makeFilePanel(ext: String, message: String, isSaveAs: Bool = false) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.nameFieldStringValue = fileExperience.suggestedName(title: canvas.document.title, ext: ext, isSaveAs: isSaveAs)
        panel.directoryURL = fileExperience.directory(currentURL: currentURL, exporting: ext != "paperdesk")
        panel.message = message
        panel.title = ext == "paperdesk" ? (isSaveAs ? "工程另存为" : "保存工程") : "导出 \(ext.uppercased())"
        panel.prompt = ext == "paperdesk" ? "保存" : "导出"
        return panel
    }

    func chooseFileDestination(ext: String, message: String, isSaveAs: Bool = false) -> URL? {
        guard !exporting, !isClosed else { return nil }
        canvas.finishEditing()
        let panel = makeFilePanel(ext: ext, message: message, isSaveAs: isSaveAs)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Never change the URL after the native panel has confirmed an overwrite.
        guard url.pathExtension.caseInsensitiveCompare(ext) == .orderedSame else {
            showError(DeskError.message("文件名需要使用 .\(ext) 扩展名。")); return nil
        }
        return url
    }

    func choosePDFExport() -> PDFExportRequest? {
        guard !exporting, !isClosed else { return nil }
        canvas.finishEditing()
        let panel = makeFilePanel(ext: "pdf", message: "PDF 保留 A4 图文位置。导出副本不会保存工程，继续编辑请另存 .paperdesk。")
        let range = PDFPageRangeAccessory(pageCount: canvas.document.pages.count, currentPage: canvas.activePage)
        panel.accessoryView = range.view
        panel.delegate = range
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            guard url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else { throw DeskError.message("文件名需要使用 .pdf 扩展名。") }
            return PDFExportRequest(url: url, pageIndices: try range.selectedPages())
        } catch { showError(error); return nil }
    }

    func exportSucceeded(to url: URL, kind: String) {
        fileExperience.lastExportURL = url
        recordOutput(to: url, message: "已导出 \(kind)：\(url.lastPathComponent)")
    }

    func checkExportDestination(_ url: URL) throws {
        let editors = workspace?.editors ?? [self]
        let reserved = editors.contains { editor in
            [editor.currentURL, editor.pendingSaveURL, editor.restorationURL, editor.fileExperience.pendingExportURL]
                .contains { DocumentPathIdentity.matches($0, url) }
        }
        guard !reserved else { throw DeskError.message("这个位置正在保存、导出或用作已打开的工程/恢复文件，请选择其他文件名，或等待当前任务完成。") }
    }

    @discardableResult
    func exportAsynchronously<T>(to url: URL, kind: String, work: @escaping () throws -> T,
                                 completion: ((T) -> Void)? = nil) -> Bool {
        guard !exporting, !isClosed, workspace?.isTerminating != true else { return false }
        do { try checkExportDestination(url) } catch { showError(error); return false }
        fileExperience.pendingExportURL = url
        let started = runTask("正在导出 \(kind)", work: { Result { try work() } }, completion: { [weak self] result in
            guard let self else { return }
            self.fileExperience.pendingExportURL = nil
            switch result {
            case .success(let value):
                self.exportSucceeded(to: url, kind: kind)
                completion?(value)
            case .failure(let error):
                self.statusLabel.stringValue = "\(kind) 导出失败，工程修改仍然保留"
                self.showError(error)
            }
        })
        if !started { fileExperience.pendingExportURL = nil }
        return started
    }
}
