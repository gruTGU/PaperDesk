import AppKit
import UniformTypeIdentifiers

final class TopAlignedView: NSView { override var isFlipped: Bool { true } }
final class TopAlignedStack: NSStackView { override var isFlipped: Bool { true } }

final class EditorWindow: NSWindow {
    weak var editor: EditorController?
    override func newWindowForTab(_ sender: Any?) { editor?.newDocument() }
}

final class EditorController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let window: NSWindow
    let canvas = CanvasView(frame: .zero)
    let scroll = NSScrollView()
    let pageList = TopAlignedStack()
    let inspector = NSStackView()
    let statusLabel = NSTextField(labelWithString: "就绪")
    let selectionLabel = NSTextField(wrappingLabelWithString: "双击纸面添加文字，或拖入图片。")
    let titleLabel = NSTextField(labelWithString: "未命名作业")
    let zoomSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 3, target: nil, action: nil)
    let zoomLabel = NSTextField(labelWithString: "100%")
    let gapSlider = NSSlider(value: 28, minValue: 0, maxValue: 120, target: nil, action: nil)
    let gapLabel = NSTextField(labelWithString: "页间距 28 px")
    let fontPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let fontSizeField = NSTextField(string: "14")
    let linePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let alignment = NSSegmentedControl(labels: ["左", "中", "右", "两端"], trackingMode: .selectOne, target: nil, action: nil)
    let colorWell = NSColorWell()
    let handButton = NSButton(checkboxWithTitle: "平移", target: nil, action: nil)
    var marginFields: [NSTextField] = []
    weak var workspace: WorkspaceController?
    var standaloneStorage: StorageWindowController?
    var geometry: [NSTextField] = []
    let ratioCheck = NSButton(checkboxWithTitle: "图片保持比例", target: nil, action: nil)
    var currentURL: URL?
    var fileExperience = DocumentFileExperience()
    var lastOutputURL: URL?
    let outputButton = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
    var pendingSaveURL: URL?
    var dirty = false
    var savedDocument = PaperDocument()
    var undoStack: [PaperDocument] = []
    var redoStack: [PaperDocument] = []
    var autosaveTimer: Timer?
    var restorationURL: URL
    var pageSignature = ""
    var exporting = false
    var taskName: String?
    let taskIndicator = NSProgressIndicator()
    let recoveryQueue = DispatchQueue(label: "local.paperdesk.recovery", qos: .utility)
    var recoveryPending = false
    var recoveryGeneration = 0
    var lastRecoveryDocument: PaperDocument?
    var isClosed = false
    var contextualButtons: [NSButton] = []
    var textControls: [NSControl] = []
    var styleButtons: [NSButton] = []
    let locateOverflowButton = NSButton(title: "定位溢出", target: nil, action: nil)

    init(restorationURL: URL = StorageManager.recoveryDirectory.appendingPathComponent("Recovery-\(UUID().uuidString).paperdesk")) {
        window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.restorationURL = restorationURL
        super.init()
        (window as? EditorWindow)?.editor = self
        window.title = "PaperDesk · A4 作业排版"
        window.tabbingIdentifier = "PaperDesk.documents"
        window.minSize = CGSize(width: 1080, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .aqua)
        configureUI()
        configureCanvas()
        createMenu()
        savedDocument = canvas.document
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.writeRecovery() }
    }
    deinit { autosaveTimer?.invalidate() }
    func show(center: Bool = true) {
        if center { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateLayout()
        refresh()
    }
    private func label(_ title: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading }
        button.toolTip = title
        if [#selector(cropImage), #selector(exportSelectedImage), #selector(bringFront), #selector(sendBack), #selector(deleteSelection)].contains(action) { contextualButtons.append(button) }
        return button
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let view = NSStackView(views: views)
        view.orientation = .horizontal; view.alignment = .centerY; view.spacing = spacing
        return view
    }
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func addInspector(_ view: NSView) {
        inspector.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
    }
    func configureUI() {
        let root = NSView()
        root.wantsLayer = true
        // The editor explicitly uses Aqua. A dynamic NSColor converted to CGColor here
        // resolves in the ambient appearance, which can be Dark Aqua before drawing.
        // Keep this non-dynamic background consistent with the light controls and text.
        let panelBackground = NSColor(srgbRed: 0.97, green: 0.975, blue: 0.985, alpha: 1)
        root.layer?.backgroundColor = panelBackground.cgColor
        window.backgroundColor = panelBackground
        window.contentView = root
        let outer = NSStackView(); outer.orientation = .vertical; outer.spacing = 0; outer.alignment = .leading
        outer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo: root.leadingAnchor), outer.trailingAnchor.constraint(equalTo: root.trailingAnchor), outer.topAnchor.constraint(equalTo: root.topAnchor), outer.bottomAnchor.constraint(equalTo: root.bottomAnchor)])

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pdf = button("导出 PDF", #selector(exportPDF), symbol: "arrow.up.document.fill")
        pdf.bezelColor = .controlAccentColor
        let brandIcon = NSImageView()
        brandIcon.image = PaperDeskAppearance.applicationIcon()
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        brandIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        brandIcon.setAccessibilityLabel("PaperDesk 应用图标")
        let brand = NSStackView(views: [label("PaperDesk", size: 18, weight: .bold), label("你的 A4 图文工作台", size: 10)])
        brand.orientation = .vertical; brand.alignment = .leading; brand.spacing = 1
        let header = row([brandIcon, brand, label("｜", size: 20), titleLabel, spacer(), button("新标签", #selector(newDocument), symbol: "plus"), button("打开", #selector(openDocument), symbol: "folder"), button("保存", #selector(saveDocument), symbol: "square.and.arrow.down"), button("另存为", #selector(saveAs), symbol: "doc.on.doc"), pdf], spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        outer.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        let topDivider = divider(); outer.addArrangedSubview(topDivider); topDivider.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        let body = NSStackView(); body.orientation = .horizontal; body.alignment = .top; body.spacing = 0
        outer.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)

        let sidebar = NSStackView(); sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 12
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = NSColor.white.cgColor
        sidebar.edgeInsets = NSEdgeInsets(top: 20, left: 14, bottom: 16, right: 14)
        sidebar.addArrangedSubview(label("页面", size: 13, weight: .semibold))
        sidebar.addArrangedSubview(button("添加 A4 页", #selector(addPage), symbol: "plus.rectangle"))
        sidebar.addArrangedSubview(button("复制当前页", #selector(duplicatePage), symbol: "doc.on.doc"))
        sidebar.addArrangedSubview(button("删除当前页", #selector(deletePage), symbol: "trash"))
        let pageScroll = NSScrollView(); pageScroll.hasVerticalScroller = true; pageScroll.drawsBackground = false
        pageList.orientation = .vertical; pageList.alignment = .leading; pageList.spacing = 8
        pageList.translatesAutoresizingMaskIntoConstraints = false; pageScroll.documentView = pageList
        pageList.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor).isActive = true
        sidebar.addArrangedSubview(pageScroll)
        pageScroll.widthAnchor.constraint(equalToConstant: 142).isActive = true
        pageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        pageScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let help = NSTextField(wrappingLabelWithString: "A4 · 210 × 297 mm\n\n双击：编辑文字\n拖拽：移动对象\n文字四边 / 四角：缩放\n图片右下角：缩放\nShift：多选 / 自由缩放\n方向键：微调位置\n平移 / 空格拖拽：移动视图\nShift + 滚轮：左右移动")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(help)
        body.addArrangedSubview(sidebar)
        sidebar.widthAnchor.constraint(equalToConstant: 170).isActive = true
        sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let center = NSStackView(); center.orientation = .vertical; center.spacing = 0; center.alignment = .leading
        handButton.target = self; handButton.action = #selector(toggleHand)
        handButton.toolTip = "拖动纸张平移视图；关闭后继续选择和编辑对象。也可按住空格拖动。"
        let toolbar = row([button("文字", #selector(addText), symbol: "textformat"), button("图片", #selector(addImages), symbol: "photo"), button("裁剪", #selector(cropImage), symbol: "crop"), button("拼图", #selector(makeCollage), symbol: "square.grid.2x2"), handButton, spacer(), button("−", #selector(zoomOut)), zoomSlider, button("+", #selector(zoomIn)), zoomLabel, button("适宽", #selector(fitWidth))], spacing: 5)
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        zoomSlider.target = self; zoomSlider.action = #selector(changeZoom)
        zoomSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        zoomLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        center.addArrangedSubview(toolbar); toolbar.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        scroll.documentView = canvas
        center.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        center.setContentHuggingPriority(.defaultLow, for: .horizontal)
        body.addArrangedSubview(center); center.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let inspectScroll = NSScrollView(); inspectScroll.hasVerticalScroller = true; inspectScroll.drawsBackground = false; inspectScroll.autohidesScrollers = true
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 11
        inspector.translatesAutoresizingMaskIntoConstraints = false
        let inspectContainer = TopAlignedView(); inspectContainer.translatesAutoresizingMaskIntoConstraints = false
        inspectContainer.wantsLayer = true; inspectContainer.layer?.backgroundColor = NSColor.white.cgColor
        inspectContainer.addSubview(inspector); inspectScroll.documentView = inspectContainer
        NSLayoutConstraint.activate([inspectContainer.widthAnchor.constraint(equalTo: inspectScroll.contentView.widthAnchor), inspector.leadingAnchor.constraint(equalTo: inspectContainer.leadingAnchor, constant: 16), inspector.trailingAnchor.constraint(equalTo: inspectContainer.trailingAnchor, constant: -16), inspector.topAnchor.constraint(equalTo: inspectContainer.topAnchor, constant: 20), inspector.bottomAnchor.constraint(equalTo: inspectContainer.bottomAnchor, constant: -20)])
        body.addArrangedSubview(inspectScroll)
        inspectScroll.widthAnchor.constraint(equalToConstant: 236).isActive = true
        inspectScroll.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        addInspector(label("对象属性", size: 14, weight: .semibold))
        selectionLabel.font = .systemFont(ofSize: 11); selectionLabel.textColor = .secondaryLabelColor
        addInspector(selectionLabel)
        addInspector(divider())
        addInspector(label("位置与尺寸 · mm", size: 11, weight: .medium))
        for pair in [["X", "Y"], ["宽", "高"]] {
            var parts: [NSView] = []
            for name in pair {
                let input = NSTextField(string: "0"); input.target = self; input.action = #selector(applyGeometry)
                input.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                input.setAccessibilityLabel("对象\(name)（毫米）")
                input.toolTip = "对象\(name)，单位为毫米；按 Return 应用"
                input.widthAnchor.constraint(equalToConstant: 62).isActive = true
                geometry.append(input); parts += [label(name, size: 11), input]
            }
            addInspector(row(parts, spacing: 5))
        }
        ratioCheck.state = .on; addInspector(ratioCheck)
        addInspector(row([button("置顶", #selector(bringFront)), button("置底", #selector(sendBack)), button("删除", #selector(deleteSelection))], spacing: 5))
        let duplicate = button("复制一份", #selector(duplicateSelection))
        contextualButtons.append(duplicate)
        let fitText = button("适应文字高度", #selector(fitTextHeight))
        addInspector(row([duplicate, fitText], spacing: 5))
        addInspector(divider())
        addInspector(label("文字格式", size: 11, weight: .medium))
        for (name, font) in [("苹方", "PingFangSC-Regular"), ("宋体", "SongtiSC-Regular"), ("黑体", "STHeitiSC-Light"), ("Times New Roman", "TimesNewRomanPSMT"), ("Menlo", "Menlo-Regular")] {
            fontPicker.addItem(withTitle: name); fontPicker.lastItem?.representedObject = font
        }
        fontPicker.target = self; fontPicker.action = #selector(applyFont)
        addInspector(fontPicker)
        fontSizeField.target = self; fontSizeField.action = #selector(applyFontSize)
        fontSizeField.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let bold = button("B", #selector(toggleBold)); bold.font = .boldSystemFont(ofSize: 13)
        let italic = button("I", #selector(toggleItalic)); let underline = button("U", #selector(toggleUnderline))
        styleButtons = [bold, italic, underline]
        styleButtons.forEach { $0.setButtonType(.toggle); $0.allowsMixedState = true }
        bold.toolTip = "加粗 · ⌘B"; italic.toolTip = "斜体 · ⌘I"; underline.toolTip = "下划线 · ⌘U"
        fontSizeField.setAccessibilityLabel("字号（点）")
        fontSizeField.toolTip = "字号 4～200 pt；按 Return 应用"
        addInspector(row([fontSizeField, label("pt", size: 10), bold, italic, underline], spacing: 3))
        alignment.target = self; alignment.action = #selector(applyAlignment); alignment.selectedSegment = 0
        addInspector(alignment)
        linePicker.addItems(withTitles: ["1.0", "1.25", "1.5", "2.0"]); linePicker.selectItem(at: 1)
        linePicker.target = self; linePicker.action = #selector(applyLineHeight)
        colorWell.color = .black; colorWell.target = self; colorWell.action = #selector(applyColor)
        colorWell.widthAnchor.constraint(equalToConstant: 42).isActive = true
        textControls = [fontPicker, fontSizeField, bold, italic, underline, alignment, linePicker, colorWell, fitText]
        addInspector(row([label("行距", size: 11), linePicker, spacer(), colorWell]))
        addInspector(divider())
        gapSlider.target = self; gapSlider.action = #selector(changeGap)
        gapLabel.font = .systemFont(ofSize: 11)
        addInspector(gapLabel); addInspector(gapSlider)
        addInspector(label("A4 页边距 · mm", size: 11, weight: .medium))
        for names in [["上", "下"], ["左", "右"]] {
            var parts: [NSView] = []
            for name in names {
                let field = NSTextField(string: "15")
                field.target = self; field.action = #selector(applyMargins)
                field.widthAnchor.constraint(equalToConstant: 62).isActive = true
                field.setAccessibilityLabel("\(name)页边距（毫米）")
                marginFields.append(field); parts += [label(name, size: 11), field]
            }
            addInspector(row(parts, spacing: 5))
        }
        let marginHelp = label("用于参考线、新文字及拼图；已有对象保留位置。", size: 10)
        marginHelp.lineBreakMode = .byWordWrapping; marginHelp.maximumNumberOfLines = 2
        addInspector(marginHelp)
        let marginCheck = NSButton(checkboxWithTitle: "显示页边距参考线", target: self, action: #selector(toggleMargins)); marginCheck.state = .on
        addInspector(marginCheck)
        addInspector(divider())
        addInspector(label("导出与转换", size: 11, weight: .medium))
        addInspector(button("导出 DOCX", #selector(exportDOCX), symbol: "doc.text"))
        addInspector(button("导出 Markdown", #selector(exportMarkdown), symbol: "text.alignleft"))
        addInspector(button("图片另存 / 压缩", #selector(exportSelectedImage), symbol: "photo.badge.arrow.down"))
        addInspector(button("当前页另存图片", #selector(exportPageImage), symbol: "rectangle.inset.filled"))

        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        taskIndicator.style = .spinning; taskIndicator.controlSize = .small; taskIndicator.isDisplayedWhenStopped = false
        taskIndicator.isHidden = true
        taskIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        taskIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let undoButton = button("撤销", #selector(undoAction), symbol: "arrow.uturn.backward")
        let redoButton = button("重做", #selector(redoAction), symbol: "arrow.uturn.forward")
        undoButton.toolTip = "撤销 · ⌘Z"; redoButton.toolTip = "重做 · ⇧⌘Z"
        locateOverflowButton.target = self; locateOverflowButton.action = #selector(locateOverflow)
        locateOverflowButton.bezelStyle = .rounded; locateOverflowButton.isHidden = true
        locateOverflowButton.toolTip = "选中第一个装不下文字的文本框，可用“适应文字高度”处理。"
        outputButton.target = self; outputButton.action = #selector(revealLastOutput)
        outputButton.bezelStyle = .rounded; outputButton.isHidden = true
        let bottom = row([undoButton, redoButton, taskIndicator, statusLabel, locateOverflowButton, outputButton, spacer(), button("存储空间", #selector(showStorage), symbol: "internaldrive"), label("本机处理", size: 10)])
        bottom.edgeInsets = NSEdgeInsets(top: 7, left: 16, bottom: 7, right: 16)
        outer.addArrangedSubview(bottom); bottom.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }
    func configureCanvas() {
        canvas.onWillChange = { [weak self] in self?.checkpoint() }
        canvas.onChange = { [weak self] in self?.didChange() }
        canvas.onSelection = { [weak self] in self?.refreshSelection() }
        canvas.onDropImages = { [weak self] urls, page, point in self?.insertImages(urls, page: page, at: point) }
        canvas.onNewText = { [weak self] page, point in self?.insertText(page: page, at: point) }
        canvas.onDuplicate = { [weak self] in self?.duplicateSelection() }
        canvas.onDelete = { [weak self] in self?.deleteSelection() }
    }
    func createMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let parent = NSMenuItem(); let menu = NSMenu(title: title)
            for item in items {
                if item.0 == "-" { menu.addItem(.separator()); continue }
                let entry = NSMenuItem(title: item.0, action: item.1, keyEquivalent: item.2); entry.target = self; entry.keyEquivalentModifierMask = item.3; menu.addItem(entry)
            }
            parent.submenu = menu; main.addItem(parent)
        }
        submenu("PaperDesk", [("关于 PaperDesk", #selector(about), "", []), ("退出 PaperDesk", #selector(quit), "q", .command)])
        submenu("文件", [("新建标签", #selector(newDocument), "t", .command), ("新建文档", #selector(newDocument), "n", .command), ("新建独立窗口", #selector(newWindow), "n", [.command, .shift]), ("打开工程 / DOCX / Markdown…", #selector(openDocument), "o", .command), ("保存工程", #selector(saveDocument), "s", .command), ("工程另存为…", #selector(saveAs), "s", [.command, .shift]), ("关闭当前标签", #selector(closeDocument), "w", .command), ("导出 PDF…", #selector(exportPDF), "e", .command), ("导出 DOCX…", #selector(exportDOCX), "", []), ("导出 Markdown…", #selector(exportMarkdown), "", []), ("存储空间与缓存…", #selector(showStorage), "", [])])
        let edit = NSMenu(title: "编辑"); let editParent = NSMenuItem(); editParent.submenu = edit; main.addItem(editParent)
        let undo = NSMenuItem(title: "撤销", action: #selector(undoAction), keyEquivalent: "z"); undo.target = self; edit.addItem(undo)
        let redo = NSMenuItem(title: "重做", action: #selector(redoAction), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; redo.target = self; edit.addItem(redo)
        edit.addItem(.separator())
        for item in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: item.0, action: item.1, keyEquivalent: item.2) }
        submenu("格式", [("加粗", #selector(toggleBold), "b", .command), ("斜体", #selector(toggleItalic), "i", .command), ("下划线", #selector(toggleUnderline), "u", .command), ("适应文字高度", #selector(fitTextHeight), "", []), ("定位文字溢出", #selector(locateOverflow), "", []), ("复制所选对象", #selector(duplicateSelection), "d", .command)])
        submenu("插入", [("文字框", #selector(addText), "t", [.command, .shift]), ("图片…", #selector(addImages), "i", [.command, .shift]), ("A4 页面", #selector(addPage), "p", [.command, .shift])])
        submenu("视图", [("放大", #selector(zoomIn), "+", .command), ("缩小", #selector(zoomOut), "-", .command), ("适合宽度", #selector(fitWidth), "0", .command)])
        submenu("窗口", [("下一个标签", #selector(nextTab), "\t", .control), ("上一个标签", #selector(previousTab), "\t", [.control, .shift]), ("将当前标签移到独立窗口", #selector(detachTab), "", [])])
        if let menu = main.items.last?.submenu {
            NSApp.windowsMenu = menu
        }
        NSApp.mainMenu = main
    }
    func updateLayout() { canvas.updateSize(viewport: scroll.contentSize) }
    func windowDidResize(_ notification: Notification) { updateLayout() }
    func windowDidBecomeKey(_ notification: Notification) { workspace?.lastActiveEditor = self; createMenu(); updateLayout() }
    func checkpoint() {
        canvas.syncEditing()
        if undoStack.last != canvas.document { undoStack.append(canvas.document); if undoStack.count > 40 { undoStack.removeFirst() } }
        redoStack.removeAll()
    }
    func didChange() {
        dirty = canvas.document != savedDocument
        window.isDocumentEdited = dirty
        updateLayout(); refresh()
    }
    func refresh() {
        titleLabel.stringValue = canvas.document.title
        window.title = "\(canvas.document.title) · PaperDesk"
        window.tab.title = canvas.document.title + (dirty ? " ●" : "")
        window.representedURL = currentURL
        zoomSlider.doubleValue = canvas.document.zoom; zoomLabel.stringValue = "\(Int(canvas.document.zoom * 100))%"
        gapSlider.doubleValue = canvas.document.pageGap; gapLabel.stringValue = "页间距 \(Int(canvas.document.pageGap)) px"
        let margins = canvas.document.margins
        for (field, value) in zip(marginFields, [margins.top, margins.bottom, margins.left, margins.right]) {
            if window.firstResponder !== field.currentEditor() { field.stringValue = String(format: "%.1f", value * 25.4 / 72) }
        }
        let signature = canvas.document.pages.enumerated().map { "\($0.element.id):\($0.element.elements.count):\($0.offset == canvas.activePage)" }.joined()
        if signature != pageSignature {
            pageSignature = signature
            for view in pageList.arrangedSubviews { pageList.removeArrangedSubview(view); view.removeFromSuperview() }
            for (index, page) in canvas.document.pages.enumerated() {
                let entry = PageNavigationButton(title: "\(index == canvas.activePage ? "●" : "○")  第 \(index + 1) 页   ·   \(page.elements.count)", target: self, action: #selector(selectPage))
                entry.bezelStyle = .rounded; entry.font = .systemFont(ofSize: 12)
                entry.setButtonType(.momentaryPushIn); entry.isCurrentPage = index == canvas.activePage
                entry.setAccessibilityLabel("第 \(index + 1) 页，\(page.elements.count) 个对象\(index == canvas.activePage ? "，当前页" : "")")
                entry.toolTip = "第 \(index + 1) 页，\(page.elements.count) 个对象"
                entry.tag = index; entry.widthAnchor.constraint(equalToConstant: 138).isActive = true
                pageList.addArrangedSubview(entry)
            }
        }
        let objects = canvas.document.pages.flatMap(\.elements)
        let overflows = canvas.overflowCount
        locateOverflowButton.isHidden = overflows == 0
        locateOverflowButton.isEnabled = !exporting && overflows > 0
        statusLabel.stringValue = overflows > 0 ? "⚠ \(overflows) 个文本框文字溢出：请加高、缩小字号或拆到新页。" : "第 \(canvas.activePage + 1) / \(canvas.document.pages.count) 页 · \(objects.count) 个对象 · \(dirty ? "未保存（每 5 秒自动恢复备份）" : "已保存")"
        statusLabel.textColor = overflows > 0 ? .systemRed : .secondaryLabelColor
        if let taskName { statusLabel.stringValue = taskName + "… 可切换其他标签"; statusLabel.textColor = .secondaryLabelColor }
    }
    func refreshSelection() {
        if let item = canvas.selectedElement {
            selectionLabel.stringValue = item.kind == .text ? "文字框 · 双击进入编辑，Esc 结束" : "图片 · 拖右下角等比缩放"
            for (field, value) in zip(geometry, [item.x, item.y, item.width, item.height]) { field.stringValue = String(format: "%.1f", value * 25.4 / 72); field.isEnabled = true }
            if item.kind == .text { refreshTextInspector() }
        } else {
            selectionLabel.stringValue = canvas.selectedIDs.isEmpty ? "双击纸面添加文字，或拖入图片。" : "已选择 \(canvas.selectedIDs.count) 个对象"
            geometry.forEach { $0.isEnabled = false }
        }
        let selected = canvas.selectedElement
        let isText = selected?.kind == .text
        textControls.forEach { $0.isEnabled = isText && !exporting }
        ratioCheck.isEnabled = selected?.kind == .image && !exporting
        for control in contextualButtons {
            let imageOnly = control.action == #selector(cropImage) || control.action == #selector(exportSelectedImage)
            control.isEnabled = !exporting && (imageOnly ? selected?.kind == .image : !canvas.selectedIDs.isEmpty)
        }
        if exporting { geometry.forEach { $0.isEnabled = false } }
        refresh()
    }
    func showError(_ error: Error) {
        guard !isClosed else { return }
        if window.attachedSheet != nil { statusLabel.stringValue = error.localizedDescription; return }
        let alert = PaperDeskAppearance.alert(); alert.messageText = "未能完成操作"; alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
    func withError(_ action: () throws -> Void) { do { try action() } catch { showError(error) } }
    @objc func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"
        let alert = PaperDeskAppearance.alert(); alert.messageText = "PaperDesk \(version)"; alert.informativeText = "面向作业的本地 A4 图文排版工具。\n\n工程保存完整编辑状态；PDF 固定版式；DOCX 和 Markdown 按内容阅读顺序导出。\n\n首版采用可自由摆放的文字框，文字不会自动流到下一页。"; alert.beginSheetModal(for: window)
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func selectPage(_ sender: NSButton) {
        guard !exporting, canvas.document.pages.indices.contains(sender.tag) else { return }
        canvas.finishEditing(); canvas.activePage = sender.tag; canvas.selectedIDs = []
        canvas.scrollToVisible(canvas.pageRect(sender.tag).insetBy(dx: -10, dy: -25)); refreshSelection(); canvas.needsDisplay = true
    }
    @objc func addPage() {
        guard !exporting else { return }
        guard canvas.document.pages.count < 500 else { showError(DeskError.message("最多支持 500 页，请另建一份作业。")); return }
        canvas.finishEditing(); checkpoint()
        canvas.document.pages.append(PaperPage()); canvas.activePage = canvas.document.pages.count - 1; canvas.selectedIDs = []
        didChange(); canvas.scrollToVisible(canvas.pageRect(canvas.activePage)); refreshSelection()
    }
    @objc func duplicatePage() {
        guard !exporting, canvas.document.pages.indices.contains(canvas.activePage) else { return }
        guard canvas.document.pages.count < 500 else { showError(DeskError.message("最多支持 500 页，请另建一份作业。")); return }
        canvas.finishEditing(); checkpoint()
        var page = canvas.document.pages[canvas.activePage]; page.id = UUID()
        for i in page.elements.indices { page.elements[i].id = UUID() }
        canvas.document.pages.insert(page, at: canvas.activePage + 1); canvas.activePage += 1; canvas.selectedIDs = []
        didChange(); canvas.scrollToVisible(canvas.pageRect(canvas.activePage)); refreshSelection()
    }
    @objc func deletePage() {
        guard !exporting, canvas.document.pages.indices.contains(canvas.activePage) else { return }
        canvas.finishEditing(); checkpoint()
        canvas.document.pages.remove(at: canvas.activePage)
        if canvas.document.pages.isEmpty { canvas.document.pages = [PaperPage()] }
        canvas.activePage = min(canvas.activePage, canvas.document.pages.count - 1); canvas.selectedIDs = []
        canvas.invalidateImages(); didChange(); refreshSelection()
    }
    @objc func addText() {
        let area = canvas.document.contentRect
        insertText(page: canvas.activePage, at: CGPoint(x: area.minX, y: min(area.minY + CGFloat(canvas.document.pages[canvas.activePage].elements.count % 8) * 30, area.maxY - min(80, area.height))))
    }
    func insertText(page: Int, at point: CGPoint) {
        guard !exporting, canvas.document.pages.indices.contains(page), point.x.isFinite, point.y.isFinite else { return }
        guard canvas.document.pages[page].elements.count < 2000 else { showError(DeskError.message("本页对象过多，请添加新页。")); return }
        let insertionAttributes = newTextAttributes()
        canvas.finishEditing(); checkpoint()
        let x = max(0, min(point.x, paperWidth - 100)), y = max(0, min(point.y, paperHeight - 80))
        let area = canvas.document.contentRect
        let right = area.maxX > x + 24 ? area.maxX : paperWidth
        let bottom = area.maxY > y + 24 ? area.maxY : paperHeight
        let item = PaperElement.text("", x: x, y: y, width: min(400, right - x), height: min(180, bottom - y))
        canvas.document.pages[page].elements.append(item); canvas.activePage = page; canvas.selectedIDs = [item.id]
        didChange(); canvas.startEditing(item.id)
        canvas.scrollToVisible(CGRect(x: canvas.pageRect(page).minX + x * canvas.zoom, y: canvas.pageRect(page).minY + y * canvas.zoom, width: 100 * canvas.zoom, height: 40 * canvas.zoom))
        canvas.textEditor?.typingAttributes = insertionAttributes
        refreshSelection()
    }
    @objc func addImages() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let self { self.insertImages(panel.urls, page: self.canvas.activePage, at: self.canvas.document.contentRect.origin) }
        }
    }
    func insertImages(_ urls: [URL], page: Int, at point: CGPoint) {
        guard !exporting, !urls.isEmpty, canvas.document.pages.indices.contains(page), point.x.isFinite, point.y.isFinite else { return }
        let pageID = canvas.document.pages[page].id
        guard urls.count + canvas.document.pages[page].elements.count <= 2000 else { showError(DeskError.message("本页对象过多，请分批放到新页。")); return }
        let existingBytes = canvas.document.pages.flatMap(\.elements).reduce(0) { $0 + ($1.imageData?.count ?? 0) }
        runTask("正在导入图片", work: {
            var items: [PaperElement] = []
            var totalBytes = existingBytes
            for (index, url) in urls.enumerated() {
                try autoreleasepool {
                    let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard resource.isRegularFile == true, (resource.fileSize ?? 0) <= 140_000_000 else { throw DeskError.message("图片不是普通文件或体积过大，请先压缩。") }
                    let data = try Data(contentsOf: url)
                    totalBytes += data.count
                    guard totalBytes <= 140_000_000 else { throw DeskError.message("图片原件总计超过 140 MB，可能使工程无法保存。请先压缩或分到多份作业。") }
                    let image = try ImageTools.decodeThumbnail(data, maxPixelSize: 2048)
                    let factor = min(1, min(300 / Double(image.width), 350 / Double(image.height)))
                    let width = Double(image.width) * factor, height = Double(image.height) * factor
                    let item = PaperElement(kind: .image,
                        x: max(0, min(paperWidth - width, point.x + Double(index % 5) * 22)),
                        y: max(0, min(paperHeight - height, point.y + Double(index % 5) * 22)),
                        width: width, height: height, imageData: data, imageName: url.lastPathComponent)
                    items.append(item)
                }
            }
            return items
        }, completion: { [weak self] items in
            guard let self, let target = self.canvas.document.pages.firstIndex(where: { $0.id == pageID }) else { return }
            self.checkpoint(); self.canvas.document.pages[target].elements.append(contentsOf: items)
            self.canvas.activePage = target; self.canvas.selectedIDs = Set(items.map(\.id))
            self.canvas.invalidateImages(); self.didChange(); self.refreshSelection()
        })
    }
    @objc func deleteSelection() {
        guard !canvas.selectedIDs.isEmpty else { return }
        canvas.finishEditing(); checkpoint()
        for p in canvas.document.pages.indices { canvas.document.pages[p].elements.removeAll { canvas.selectedIDs.contains($0.id) } }
        canvas.selectedIDs = []; canvas.invalidateImages(); didChange(); refreshSelection()
    }
    @objc func bringFront() { reorder(front: true) }
    @objc func sendBack() { reorder(front: false) }
    func reorder(front: Bool) {
        canvas.finishEditing(); guard !canvas.selectedIDs.isEmpty else { return }; checkpoint()
        for p in canvas.document.pages.indices {
            let selected = canvas.document.pages[p].elements.filter { canvas.selectedIDs.contains($0.id) }
            let other = canvas.document.pages[p].elements.filter { !canvas.selectedIDs.contains($0.id) }
            canvas.document.pages[p].elements = front ? other + selected : selected + other
        }
        didChange()
    }
    @objc func applyGeometry(_ sender: NSTextField) {
        guard let original = canvas.selectedElement else { return }
        let values = geometry.map { Double($0.stringValue).map { $0 * 72 / 25.4 } ?? .nan }
        guard values.allSatisfy(\.isFinite), values[2] >= 12, values[3] >= 12 else { refreshSelection(); return }
        canvas.finishEditing()
        var rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        if original.kind == .image && ratioCheck.state == .on {
            if sender === geometry[2] { rect.size.height = rect.width * original.height / original.width }
            if sender === geometry[3] { rect.size.width = rect.height * original.width / original.height }
        }
        guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { refreshSelection(); showError(DeskError.message("尺寸超出可计算范围，请输入正常的毫米数值。")); return }
        if rect.width > paperWidth || rect.height > paperHeight {
            let factor = min(paperWidth / rect.width, paperHeight / rect.height); rect.size.width *= factor; rect.size.height *= factor
        }
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { refreshSelection(); return }
        checkpoint(); modifySelected { $0.rect = canvas.clamped(rect) }; didChange(); refreshSelection()
    }
    func modifySelected(_ transform: (inout PaperElement) -> Void) {
        for p in canvas.document.pages.indices { for i in canvas.document.pages[p].elements.indices where canvas.selectedIDs.contains(canvas.document.pages[p].elements[i].id) { transform(&canvas.document.pages[p].elements[i]) } }
    }
    @objc func changeZoom() { setZoom(zoomSlider.doubleValue) }
    @objc func zoomIn() { setZoom(canvas.document.zoom + 0.1) }
    @objc func zoomOut() { setZoom(canvas.document.zoom - 0.1) }
    func setZoom(_ value: Double) {
        guard value.isFinite, !exporting else { return }
        let anchor = canvas.captureViewportAnchor()
        canvas.document.zoom = max(0.25, min(3, value)); didChange()
        if let anchor { canvas.restoreViewportAnchor(anchor) }
    }
    @objc func fitWidth() { setZoom((scroll.contentSize.width - 72) / paperWidth) }
    @objc func changeGap() { canvas.document.pageGap = gapSlider.doubleValue; didChange() }
    @objc func toggleHand() {
        canvas.finishEditing(); canvas.isPanningMode = handButton.state == .on
        window.makeFirstResponder(canvas)
    }
    @objc func applyMargins() {
        let values = marginFields.map { Double($0.stringValue).map { $0 * 72 / 25.4 } ?? .nan }
        guard values.count == 4 else { return }
        var candidate = canvas.document
        candidate.margins = PageMargins(top: values[0], bottom: values[1], left: values[2], right: values[3])
        do {
            try ProjectStore.validate(candidate)
            canvas.finishEditing(); checkpoint(); canvas.document.margins = candidate.margins; didChange()
        } catch {
            window.makeFirstResponder(canvas); refresh(); showError(error)
        }
    }
    @objc func toggleMargins(_ sender: NSButton) { canvas.showMargins = sender.state == .on; canvas.needsDisplay = true }

    func editText(paragraph: Bool = false, _ transform: (NSMutableAttributedString, NSRange) -> Void) {
        guard !exporting, let item = canvas.selectedElement, item.kind == .text else { return }
        if let editor = canvas.textEditor, let storage = editor.textStorage {
            guard !editor.hasMarkedText() else { return }
            var range = editor.selectedRange()
            if paragraph, storage.length > 0 { range = (storage.string as NSString).paragraphRange(for: range) }
            if range.length == 0 {
                let sample = NSMutableAttributedString(string: " ", attributes: editor.typingAttributes)
                transform(sample, NSRange(location: 0, length: 1)); editor.typingAttributes = sample.attributes(at: 0, effectiveRange: nil)
            } else {
                let formatted = NSMutableAttributedString(attributedString: storage)
                transform(formatted, range)
                if !formatted.isEqual(to: storage) {
                    canvas.prepareTextMutation()
                    editor.applyFormatting(formatted, selection: editor.selectedRange())
                }
            }
            window.makeFirstResponder(editor)
        } else {
            checkpoint()
            var value = item
            let text = NSMutableAttributedString(attributedString: item.attributedText)
            transform(text, NSRange(location: 0, length: text.length)); value.setText(text)
            modifySelected { $0 = value }; didChange()
        }
        refreshSelection()
    }
    @objc func applyFont() {
        guard let name = fontPicker.selectedItem?.representedObject as? String else { return }
        editText { text, range in text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let old = value as? NSFont ?? .systemFont(ofSize: 14)
            var font = NSFont(name: name, size: old.pointSize) ?? NSFont.systemFont(ofSize: old.pointSize)
            let traits = NSFontManager.shared.traits(of: old).intersection([.boldFontMask, .italicFontMask])
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            text.addAttribute(.font, value: font, range: subrange)
        } }
    }
    @objc func applyFontSize() {
        guard let size = Double(fontSizeField.stringValue), size.isFinite, (4...200).contains(size) else { refreshSelection(); return }
        editText { text, range in text.enumerateAttribute(.font, in: range) { value, subrange, _ in let font = value as? NSFont ?? .systemFont(ofSize: 14); text.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: subrange) } }
    }
    @objc func toggleBold() { toggleTrait(.boldFontMask) }
    @objc func toggleItalic() { toggleTrait(.italicFontMask) }
    func toggleTrait(_ trait: NSFontTraitMask) {
        editText { text, range in
            guard range.length > 0 else { return }
            var remove = true
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                if !NSFontManager.shared.traits(of: value as? NSFont ?? .systemFont(ofSize: 14)).contains(trait) { remove = false }
            }
            text.enumerateAttribute(.font, in: range) { value, subrange, _ in let font = value as? NSFont ?? .systemFont(ofSize: 14); text.addAttribute(.font, value: remove ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange) }
        }
    }
    @objc func toggleUnderline() {
        editText { text, range in
            guard range.length > 0 else { return }
            var allUnderlined = true
            text.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in if (value as? Int ?? 0) == 0 { allUnderlined = false } }
            text.addAttribute(.underlineStyle, value: allUnderlined ? 0 : NSUnderlineStyle.single.rawValue, range: range)
        }
    }
    @objc func applyAlignment() {
        let values: [NSTextAlignment] = [.left, .center, .right, .justified]
        let selected = values[min(values.count - 1, max(0, alignment.selectedSegment))]
        editParagraph { $0.alignment = selected }
    }
    @objc func applyLineHeight() { let multiple = Double(linePicker.titleOfSelectedItem ?? "1.25") ?? 1.25; editParagraph { $0.lineHeightMultiple = multiple; $0.lineSpacing = 0 } }
    func editParagraph(_ transform: (NSMutableParagraphStyle) -> Void) {
        editText(paragraph: true) { text, range in
            let paragraphs = (text.string as NSString).paragraphRange(for: range)
            text.enumerateAttribute(.paragraphStyle, in: paragraphs) { value, subrange, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                transform(style); text.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }
    }
    @objc func applyColor() { let color = colorWell.color; editText { $0.addAttribute(.foregroundColor, value: color, range: $1) } }
    @objc func undoAction() {
        guard !exporting, canvas.textEditor?.hasMarkedText() != true else { return }
        if let field = window.firstResponder as? NSTextView, field !== canvas.textEditor, field.isFieldEditor {
            if field.undoManager?.canUndo == true { field.undoManager?.undo() }; return
        }
        if let editor = canvas.textEditor, editor.undoManager?.canUndo == true { editor.undoManager?.undo(); refreshSelection(); return }
        canvas.finishEditing()
        while undoStack.last == canvas.document { undoStack.removeLast() }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(canvas.document); canvas.document = previous; canvas.selectedIDs = []; canvas.activePage = min(canvas.activePage, previous.pages.count - 1)
        canvas.invalidateImages(); didChange(); refreshSelection()
    }
    @objc func redoAction() {
        guard !exporting, canvas.textEditor?.hasMarkedText() != true else { return }
        if let field = window.firstResponder as? NSTextView, field !== canvas.textEditor, field.isFieldEditor {
            if field.undoManager?.canRedo == true { field.undoManager?.redo() }; return
        }
        if let editor = canvas.textEditor, editor.undoManager?.canRedo == true { editor.undoManager?.redo(); refreshSelection(); return }
        canvas.finishEditing()
        while redoStack.last == canvas.document { redoStack.removeLast() }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(canvas.document); canvas.document = next; canvas.selectedIDs = []; canvas.activePage = min(canvas.activePage, next.pages.count - 1)
        canvas.invalidateImages(); didChange(); refreshSelection()
    }

    func mayReplaceDocument(afterSave: (() -> Void)? = nil) -> Bool {
        if exporting { showError(DeskError.message("文档任务仍在处理中，请完成后再关闭这个作业。")); return false }
        canvas.finishEditing()
        guard dirty else { return true }
        let alert = PaperDeskAppearance.alert(); alert.messageText = "保存“\(canvas.document.title)”？"; alert.informativeText = "当前修改尚未保存到工程文件。"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return false }
        if response == .alertFirstButtonReturn { saveToDisk(forceChoose: false, completion: afterSave); return false }
        return true
    }
    @objc func newDocument() {
        if let workspace { workspace.newDocument(from: self); return }
        guard mayReplaceDocument(afterSave: { [weak self] in self?.newDocument() }) else { return }
        load(PaperDocument(), url: nil, imported: false); removeRecovery()
    }
    @objc func newWindow() { workspace?.newDocument(from: self, separate: true) }
    @objc func closeDocument() { (NSApp.keyWindow ?? window).performClose(nil) }
    @objc func activateWindow() { window.makeKeyAndOrderFront(nil) }
    @objc func nextTab() { switchTab(offset: 1) }
    @objc func previousTab() { switchTab(offset: -1) }
    func switchTab(offset: Int) {
        guard let group = window.tabGroup, let index = group.windows.firstIndex(where: { $0 === window }), !group.windows.isEmpty else { return }
        canvas.syncEditing()
        let target = group.windows[(index + offset + group.windows.count) % group.windows.count]
        group.selectedWindow = target; target.makeKeyAndOrderFront(nil)
    }
    @objc func detachTab() {
        guard let group = window.tabGroup, group.windows.count > 1 else { return }
        group.removeWindow(window); window.setFrameOrigin(window.frame.origin.applying(CGAffineTransform(translationX: 28, y: -28)))
        window.makeKeyAndOrderFront(nil)
        if window.tabGroup?.isTabBarVisible != true { window.toggleTabBar(nil) }
    }
    @objc func showStorage() {
        if let workspace { workspace.showStorage(relativeTo: window); return }
        if standaloneStorage == nil {
            standaloneStorage = StorageWindowController(activeRecoveryURLs: { [weak self] in self.map { Set([$0.restorationURL]) } ?? [] }, memoryCacheUsage: { [weak self] in
                (count: self?.canvas.cachedImageCount ?? 0, bytes: Int64(self?.canvas.cachedImageBytes ?? 0))
            }, clearMemoryCache: { [weak self] in self?.canvas.clearImageCache() }, canDeleteRecoveries: { [weak self] in self?.exporting != true })
        }
        standaloneStorage?.show(relativeTo: window)
    }
    @objc func openDocument() {
        if workspace == nil && !mayReplaceDocument(afterSave: { [weak self] in self?.openDocument() }) { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = workspace != nil
        panel.allowedContentTypes = [UTType(filenameExtension: "paperdesk") ?? .data, UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.message = "每份文件分别打开为标签。支持 PaperDesk 工程、DOCX、Markdown；PDF 仅导出。"
        if panel.runModal() == .OK { openDocuments(panel.urls) }
    }
    func openURL(_ url: URL) { openDocuments([url]) }
    func load(_ doc: PaperDocument, url: URL?, imported: Bool) {
        canvas.finishEditing(); canvas.document = doc; canvas.activePage = 0; canvas.selectedIDs = []; currentURL = url
        fileExperience = DocumentFileExperience(sourceURL: url); lastOutputURL = nil; outputButton.isHidden = true
        undoStack.removeAll(); redoStack.removeAll(); savedDocument = imported ? PaperDocument() : doc
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.invalidateImages(); didChange(); refreshSelection()
        scroll.contentView.scroll(to: CGPoint(x: max(0, (canvas.bounds.width - scroll.contentSize.width) / 2), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc func saveDocument() { saveToDisk(forceChoose: false) }
    @objc func saveAs() { saveToDisk(forceChoose: true) }
    func saveToDisk(forceChoose: Bool, completion: (() -> Void)? = nil) {
        guard !exporting else { return }
        canvas.finishEditing()
        var destination = currentURL
        if forceChoose || destination == nil {
            guard let url = chooseFileDestination(ext: "paperdesk", message: "工程保留所有文字、图片原件、裁剪与位置，下次可继续编辑。", isSaveAs: forceChoose) else { return }
            destination = url
        }
        guard let url = destination else { return }
        saveAsynchronously(to: url, completion: completion)
    }
    func saveProject(to url: URL) throws {
        canvas.syncEditing()
        try checkSaveDestination(url)
        var doc = canvas.document; doc.title = url.deletingPathExtension().lastPathComponent
        try ProjectStore.write(doc, to: url)
        canvas.document = doc; savedDocument = doc; currentURL = url; dirty = false; window.isDocumentEdited = false
        removeRecovery(); refresh()
        if window.isKeyWindow { createMenu() }
    }
    func chooseExport(ext: String, message: String) -> URL? {
        chooseFileDestination(ext: ext, message: message)
    }
    @objc func exportPDF() {
        guard let request = choosePDFExport() else { return }
        guard !focusFirstOverflow(in: request.pageIndices) else {
            showError(DeskError.message("已定位所选页面中溢出的文本框。请先适应文字高度、加宽、缩小字号或拆页，然后重新导出。")); return
        }
        let snapshot = canvas.document
        exportAsynchronously(to: request.url, kind: "PDF（\(request.pageIndices.count) 页）", work: { try PDFExporter.write(snapshot, to: request.url, pageIndices: request.pageIndices) })
    }
    @objc func exportDOCX() {
        guard let url = chooseExport(ext: "docx", message: "导出可编辑文字和图片，按页面阅读顺序排列；自由摆放坐标不保留。") else { return }
        let snapshot = canvas.document
        exportAsynchronously(to: url, kind: "DOCX", work: { try DocumentConversion.exportDOCX(snapshot, to: url) })
    }
    @objc func exportMarkdown() {
        guard let url = chooseExport(ext: "md", message: "导出文字和图片链接，不保留 A4 坐标、字体或分页。图片保存在旁边的资源文件夹。") else { return }
        let snapshot = canvas.document
        exportAsynchronously(to: url, kind: "Markdown 与图片资源", work: { try DocumentConversion.exportMarkdown(snapshot, to: url) })
    }
    func writeRecovery() {
        guard dirty, !recoveryPending, !exporting, !isClosed else { return }
        canvas.syncEditing()
        let snapshot = canvas.document
        guard snapshot != lastRecoveryDocument else { return }
        let url = restorationURL, generation = recoveryGeneration
        recoveryPending = true
        recoveryQueue.async { [weak self] in
            let result = autoreleasepool { Result {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ProjectStore.write(snapshot, to: url)
            } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.recoveryPending = false
                guard generation == self.recoveryGeneration, !self.isClosed else { return }
                switch result {
                case .success: self.lastRecoveryDocument = snapshot
                case .failure(let error): self.statusLabel.stringValue = "自动恢复备份未成功，请手动保存：\(error.localizedDescription)"
                }
            }
        }
    }
    func removeRecovery() {
        recoveryGeneration += 1; lastRecoveryDocument = nil
        let url = restorationURL
        // Deletion is ordered after already queued writes, preventing a stale backup reappearing.
        recoveryQueue.async { try? FileManager.default.removeItem(at: url) }
    }
    func windowWillClose(_ notification: Notification) { isClosed = true; autosaveTimer?.invalidate(); autosaveTimer = nil; canvas.finishEditing(); workspace?.remove(self) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace?.isTerminating != true else { return false }
        let result = mayReplaceDocument(afterSave: { [weak self] in self?.window.performClose(nil) })
        if result { removeRecovery(); dirty = false }
        return result
    }
}
