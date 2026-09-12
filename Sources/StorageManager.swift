import AppKit

struct StorageLocations {
    let supportDirectory: URL
    let cacheDirectory: URL
    var recoveryDirectory: URL { supportDirectory.appendingPathComponent("Recovery", isDirectory: true) }

    static var user: StorageLocations {
        let manager = FileManager.default
        return StorageLocations(
            supportDirectory: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("PaperDesk", isDirectory: true),
            cacheDirectory: manager.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("PaperDesk", isDirectory: true)
        )
    }
}

struct StorageEntry {
    enum Kind { case memory, cache, recovery }
    let kind: Kind
    let name: String
    let url: URL?
    let bytes: Int64
    let fileCount: Int
    var isProtected = false
}

struct StorageCleanupResult {
    var filesRemoved = 0
    var bytesRemoved: Int64 = 0
    var skipped = 0
}

enum StorageError: LocalizedError {
    case unsafeLocation
    case protectedRecovery
    var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "此位置不是 PaperDesk 可清理的缓存或恢复备份。"
        case .protectedRecovery: return "此恢复备份仍由打开的文档使用，已保留。"
        }
    }
}

enum StorageManager {
    static var supportDirectory: URL { StorageLocations.user.supportDirectory }
    static var cacheDirectory: URL { StorageLocations.user.cacheDirectory }
    static var recoveryDirectory: URL { StorageLocations.user.recoveryDirectory }

    private static func fileType(_ url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // The owned directory must itself be a real directory. Never traverse a link
    // substituted for either the support folder or its Recovery child.
    private static func directoryExists(_ url: URL) throws -> Bool {
        guard exists(url) else { return false }
        guard try fileType(url) == .typeDirectory else { throw StorageError.unsafeLocation }
        return true
    }

    private static func children(_ url: URL) throws -> [URL] {
        guard try directoryExists(url) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL == b.standardizedFileURL || a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func regularFile(_ url: URL) -> Bool { (try? fileType(url)) == .typeRegular }

    static func recoveryFiles(locations: StorageLocations = .user) throws -> [URL] {
        guard try directoryExists(locations.supportDirectory) else { return [] }
        let legacy = try children(locations.supportDirectory).filter {
            $0.lastPathComponent.hasPrefix("Recovery") && $0.pathExtension.lowercased() == "paperdesk" && regularFile($0)
        }
        let current = try children(locations.recoveryDirectory).filter {
            $0.pathExtension.lowercased() == "paperdesk" && regularFile($0)
        }
        return (current + legacy).sorted {
            let left = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
            let right = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
            return left > right
        }
    }

    private static func measure(_ url: URL) throws -> (bytes: Int64, count: Int) {
        switch try fileType(url) {
        case .typeRegular:
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ((attributes[.size] as? NSNumber)?.int64Value ?? 0, 1)
        case .typeDirectory:
            var total: (bytes: Int64, count: Int) = (0, 0)
            for child in try children(url) {
                let result = try measure(child)
                total.bytes += result.bytes; total.count += result.count
            }
            return total
        default: return (0, 0) // Links and special files are neither followed nor counted.
        }
    }

    static func inventory(locations: StorageLocations = .user, activeRecoveryURLs: Set<URL> = []) throws -> [StorageEntry] {
        var entries: [StorageEntry] = []
        for url in try children(locations.cacheDirectory) {
            guard try fileType(url) != .typeSymbolicLink else { continue }
            let measured = try measure(url)
            entries.append(StorageEntry(kind: .cache, name: url.lastPathComponent, url: url, bytes: measured.bytes, fileCount: measured.count))
        }
        for url in try recoveryFiles(locations: locations) {
            let measured = try measure(url)
            entries.append(StorageEntry(kind: .recovery, name: url.lastPathComponent, url: url, bytes: measured.bytes, fileCount: 1, isProtected: activeRecoveryURLs.contains { sameLocation($0, url) }))
        }
        return entries
    }

    private static func removeCacheEntry(_ url: URL, result: inout StorageCleanupResult) throws {
        switch try fileType(url) {
        case .typeRegular:
            let measured = try measure(url)
            try FileManager.default.removeItem(at: url)
            result.filesRemoved += 1; result.bytesRemoved += measured.bytes
        case .typeDirectory:
            for child in try children(url) { try removeCacheEntry(child, result: &result) }
            if try children(url).isEmpty { try FileManager.default.removeItem(at: url) }
        default: result.skipped += 1 // Preserve symbolic links; never delete their targets.
        }
    }

    static func clearDiskCache(locations: StorageLocations = .user) throws -> StorageCleanupResult {
        var result = StorageCleanupResult()
        for url in try children(locations.cacheDirectory) { try removeCacheEntry(url, result: &result) }
        return result
    }

    static func deleteRecoveries(_ selectedURLs: [URL], activeRecoveryURLs: Set<URL>, locations: StorageLocations = .user) throws -> StorageCleanupResult {
        let allowed = try recoveryFiles(locations: locations)
        // Validate the entire selection before deleting anything. Only files shown
        // in the managed recovery inventory can enter this operation.
        var unique = Set<URL>()
        for requestedURL in selectedURLs {
            guard regularFile(requestedURL), let url = allowed.first(where: { sameLocation($0, requestedURL) }) else { throw StorageError.unsafeLocation }
            guard !activeRecoveryURLs.contains(where: { sameLocation($0, url) }) else { throw StorageError.protectedRecovery }
            unique.insert(url.standardizedFileURL)
        }
        var result = StorageCleanupResult()
        for url in unique {
            let measured = try measure(url)
            try FileManager.default.removeItem(at: url)
            result.filesRemoved += 1; result.bytesRemoved += measured.bytes
        }
        return result
    }
}

final class StorageWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let activeRecoveryURLs: () -> Set<URL>
    private let memoryCacheUsage: () -> (count: Int, bytes: Int64)
    private let clearMemoryCache: () -> Void
    private let locations: StorageLocations
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "正在读取…")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var rows: [StorageEntry] = []
    private var controls: [NSButton] = []
    private var deleteButton: NSButton!
    private var busy = false

    init(activeRecoveryURLs: @escaping () -> Set<URL>, memoryCacheUsage: @escaping () -> (count: Int, bytes: Int64), clearMemoryCache: @escaping () -> Void, locations: StorageLocations = .user) {
        self.activeRecoveryURLs = activeRecoveryURLs
        self.memoryCacheUsage = memoryCacheUsage
        self.clearMemoryCache = clearMemoryCache
        self.locations = locations
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 530), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "存储与缓存 · PaperDesk"
        panel.minSize = NSSize(width: 760, height: 420)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = NSColor(srgbRed: 0.97, green: 0.975, blue: 0.985, alpha: 1)
        configureUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(relativeTo parent: NSWindow) {
        guard let window else { return }
        if !window.isVisible {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func configureUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        summary.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(summary)
        let note = NSTextField(wrappingLabelWithString: "图片预览缓存可重新生成。恢复备份可能包含未保存的作业；正在使用的备份会保留。")
        note.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(note)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true; table.rowHeight = 28
        table.delegate = self; table.dataSource = self
        for (identifier, title, width) in [("category", "类别", 120.0), ("size", "大小", 90.0), ("name", "项目", 210.0), ("path", "位置", 400.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        scroll.documentView = table
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 8
        for (title, action) in [("刷新", #selector(refresh)), ("清理图片预览", #selector(clearMemory)), ("清理磁盘缓存", #selector(clearDisk)), ("删除所选恢复备份…", #selector(deleteSelected))] {
            let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded
            controls.append(button); toolbar.addArrangedSubview(button)
        }
        deleteButton = controls.last!
        stack.addArrangedSubview(toolbar)
        feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor
        feedback.stringValue = "恢复备份和磁盘缓存分开管理。已保存的工程文件不在清理范围内。"
        stack.addArrangedSubview(feedback)
        feedback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func setBusy(_ value: Bool) {
        busy = value
        for button in controls { button.isEnabled = !value }
        table.isEnabled = !value
        updateSelection()
    }

    @objc private func refresh() {
        guard !busy else { return }
        setBusy(true)
        let memory = memoryCacheUsage(), active = activeRecoveryURLs(), places = locations
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try StorageManager.inventory(locations: places, activeRecoveryURLs: active) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                switch result {
                case .success(let disk):
                    self.rows = [StorageEntry(kind: .memory, name: "图片预览（\(memory.count) 张）", url: nil, bytes: memory.bytes, fileCount: memory.count)] + disk
                    self.table.reloadData(); self.updateSelection()
                    let cacheBytes = disk.filter { $0.kind == .cache }.reduce(Int64(0)) { $0 + $1.bytes }
                    let recoveryBytes = disk.filter { $0.kind == .recovery }.reduce(Int64(0)) { $0 + $1.bytes }
                    self.summary.stringValue = "内存预览 \(Self.size(memory.bytes))　磁盘缓存 \(Self.size(cacheBytes))　恢复备份 \(Self.size(recoveryBytes))"
                case .failure(let error): self.summary.stringValue = "读取存储失败"; self.feedback.stringValue = error.localizedDescription
                }
            }
        }
    }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = rows[row]
        let value: String
        switch identifier {
        case "category":
            switch entry.kind { case .memory: value = "内存预览"; case .cache: value = "磁盘缓存"; case .recovery: value = entry.isProtected ? "恢复备份 · 使用中" : "恢复备份" }
        case "size": value = Self.size(entry.bytes)
        case "name": value = entry.name
        default: value = entry.url?.path ?? "所有打开的文档窗口 · 估算值"
        }
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle; field.toolTip = value
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private var selectedRecoveries: [URL] {
        table.selectedRowIndexes.compactMap { index in
            guard rows.indices.contains(index), rows[index].kind == .recovery, !rows[index].isProtected else { return nil }
            return rows[index].url
        }
    }

    private func updateSelection() { deleteButton?.isEnabled = !busy && !selectedRecoveries.isEmpty }

    @objc private func clearMemory() {
        clearMemoryCache()
        feedback.stringValue = "已清理图片预览缓存；再次显示图片时会按需生成。"
        refresh()
    }

    private func runCleanup(_ action: @escaping () throws -> StorageCleanupResult) {
        guard !busy else { return }
        setBusy(true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try action() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                switch result {
                case .success(let cleaned):
                    self.feedback.stringValue = "已清理 \(cleaned.filesRemoved) 个文件，释放 \(Self.size(cleaned.bytesRemoved))。" + (cleaned.skipped > 0 ? "已跳过 \(cleaned.skipped) 个链接或特殊文件。" : "")
                case .failure(let error): self.feedback.stringValue = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    @objc private func clearDisk() {
        let places = locations
        runCleanup { try StorageManager.clearDiskCache(locations: places) }
    }

    @objc private func deleteSelected() {
        let selected = selectedRecoveries
        guard !selected.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "删除 \(selected.count) 个恢复备份？"
        alert.informativeText = "这些备份可能包含尚未另存的作业。删除后无法通过 PaperDesk 恢复。\n\n" + selected.prefix(4).map(\.lastPathComponent).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除备份")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            let active = self.activeRecoveryURLs(), places = self.locations
            self.runCleanup { try StorageManager.deleteRecoveries(selected, activeRecoveryURLs: active, locations: places) }
        }
    }
}
