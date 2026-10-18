import AppKit

extension EditorController {
    func newTextAttributes() -> [NSAttributedString.Key: Any] {
        let typedSize = Double(fontSizeField.stringValue) ?? 14
        let size = typedSize.isFinite && (4...200).contains(typedSize) ? typedSize : 14
        let fontName = fontPicker.selectedItem?.representedObject as? String ?? "PingFangSC-Regular"
        var font = NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
        if styleButtons[0].state == .on { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if styleButtons[1].state == .on { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes = TextStyle.make(" ", size: size).attributes(at: 0, effectiveRange: nil)
        attributes[.font] = font; attributes[.foregroundColor] = colorWell.color
        attributes[.underlineStyle] = styleButtons[2].state == .on ? NSUnderlineStyle.single.rawValue : 0
        let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]
        if alignments.indices.contains(alignment.selectedSegment) { paragraph.alignment = alignments[alignment.selectedSegment] }
        paragraph.lineSpacing = 0
        paragraph.lineHeightMultiple = Double(linePicker.titleOfSelectedItem ?? "") ?? 1.25
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    /// The live selection is authoritative; the serialized model can lag during IME composition.
    func refreshTextInspector() {
        guard let item = canvas.selectedElement, item.kind == .text else { return }
        let editor = canvas.textEditor
        let text = editor?.attributedString() ?? item.attributedText
        let range = editor?.selectedRange() ?? NSRange(location: 0, length: text.length)
        var attributes: [[NSAttributedString.Key: Any]] = []
        if range.length == 0 {
            attributes = [editor?.typingAttributes ?? TextStyle.make(" ").attributes(at: 0, effectiveRange: nil)]
        } else {
            text.enumerateAttributes(in: range) { value, _, _ in attributes.append(value) }
        }
        let fonts = attributes.map { $0[.font] as? NSFont ?? .systemFont(ofSize: 14) }
        let sizes = Set(fonts.map { $0.pointSize })
        if window.firstResponder !== fontSizeField.currentEditor() || fontSizeField.currentEditor() == nil {
            fontSizeField.stringValue = sizes.count == 1 ? Self.formatPointSize(fonts[0].pointSize) : ""
            fontSizeField.placeholderString = sizes.count == 1 ? nil : "混合"
        }
        let families = Set(fonts.map { $0.familyName ?? $0.fontName })
        if families.count == 1, let font = fonts.first {
            let match = fontPicker.itemArray.first { item in
                guard let name = item.representedObject as? String, let candidate = NSFont(name: name, size: 14) else { return false }
                return candidate.familyName == font.familyName
            }
            if let match { fontPicker.select(match) }
            else {
                let title = font.familyName ?? font.fontName
                fontPicker.addItem(withTitle: title)
                fontPicker.lastItem?.representedObject = font.fontName
                fontPicker.select(fontPicker.lastItem)
            }
        } else {
            if fontPicker.item(withTitle: "混合字体") == nil {
                fontPicker.addItem(withTitle: "混合字体"); fontPicker.lastItem?.isEnabled = false
            }
            fontPicker.selectItem(withTitle: "混合字体")
        }
        let states: [[Bool]] = [
            fonts.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) },
            fonts.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) },
            attributes.map { ($0[.underlineStyle] as? Int ?? 0) != 0 }
        ]
        for (button, values) in zip(styleButtons, states) {
            button.state = values.allSatisfy { $0 } ? .on : (values.contains(true) ? .mixed : .off)
        }
        let paragraphs = attributes.map { $0[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default }
        let alignments = Set(paragraphs.map { $0.alignment.rawValue })
        alignment.selectedSegment = alignments.count == 1 ? ([NSTextAlignment.left, .center, .right, .justified].firstIndex(of: paragraphs[0].alignment) ?? 0) : -1
        let lines = Set(paragraphs.map { $0.lineHeightMultiple == 0 ? 1 : $0.lineHeightMultiple })
        if lines.count == 1, let value = lines.first {
            let title = Self.formatPointSize(value)
            if linePicker.item(withTitle: title) == nil { linePicker.addItem(withTitle: title) }
            linePicker.selectItem(withTitle: title)
        } else {
            if linePicker.item(withTitle: "混合") == nil { linePicker.addItem(withTitle: "混合"); linePicker.lastItem?.isEnabled = false }
            linePicker.selectItem(withTitle: "混合")
        }
        let colors = attributes.map { $0[.foregroundColor] as? NSColor ?? .black }
        colorWell.color = colors.first ?? .black
        colorWell.toolTip = colors.dropFirst().allSatisfy { $0.isEqual(colors.first) } ? "文字颜色" : "选区含多种颜色；选择颜色后统一应用"
        let selectedCount = range.length > 0 && editor != nil ? (text.string as NSString).substring(with: range).count : 0
        let mixed = sizes.count > 1 || families.count > 1 || styleButtons.contains { $0.state == .mixed } || alignments.count > 1 || lines.count > 1
        selectionLabel.stringValue = editor == nil ? "文本框 · \(text.string.count) 字 · 双击编辑" : (selectedCount > 0 ? "已选 \(selectedCount) 字 · 格式仅作用选区" : "正在编辑 · \(text.string.count) 字 · 字符格式作用后续输入")
        if mixed { selectionLabel.stringValue += " · 含混合格式" }
    }

    static func formatPointSize(_ value: CGFloat) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression).replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    static func fittedTextHeight(_ item: PaperElement) -> CGFloat {
        let (storage, manager, container) = PageDrawing.layout(item.attributedText, size: CGSize(width: item.width, height: 100_000))
        return withExtendedLifetime(storage) { max(24, ceil(max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)) + 2) }
    }

    @objc func fitTextHeight() {
        guard !exporting, canvas.textEditor?.hasMarkedText() != true else { return }
        canvas.finishEditing()
        guard let item = canvas.selectedElement, item.kind == .text else { return }
        let height = Self.fittedTextHeight(item)
        guard height <= paperHeight - item.y else {
            showError(DeskError.message("当前宽度下的文字高度超过纸面剩余空间。请加宽文本框、缩小字号、向上移动，或把文字拆到下一页。")); return
        }
        guard abs(height - item.height) > 0.01 else { return }
        checkpoint(); modifySelected { $0.height = height }; didChange(); refreshSelection()
    }

    @discardableResult func focusFirstOverflow(in indices: [Int]? = nil) -> Bool {
        canvas.finishEditing()
        for page in indices ?? Array(canvas.document.pages.indices) where canvas.document.pages.indices.contains(page) {
            if let item = canvas.document.pages[page].elements.first(where: { canvas.overflows($0) }) {
                canvas.activePage = page; canvas.selectedIDs = [item.id]
                let paper = canvas.pageRect(page)
                canvas.scrollToVisible(CGRect(x: paper.minX + item.x * canvas.zoom, y: paper.minY + item.y * canvas.zoom, width: item.width * canvas.zoom, height: min(item.height, 100) * canvas.zoom))
                canvas.needsDisplay = true; refreshSelection(); return true
            }
        }
        return false
    }
    @objc func locateOverflow() { guard !exporting else { return }; focusFirstOverflow() }

    @objc func duplicateSelection() {
        guard !exporting, canvas.textEditor?.hasMarkedText() != true else { return }
        canvas.finishEditing()
        let page = canvas.activePage
        guard canvas.document.pages.indices.contains(page) else { return }
        let selected = canvas.document.pages[page].elements.filter { canvas.selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        guard selected.count + canvas.document.pages[page].elements.count <= 2000 else {
            showError(DeskError.message("本页对象过多，请先添加新页。")); return
        }
        let copies = selected.map { item -> PaperElement in
            var copy = item; copy.id = UUID()
            copy.x = max(0, min(copy.x + 12, paperWidth - copy.width)); copy.y = max(0, min(copy.y + 12, paperHeight - copy.height))
            return copy
        }
        checkpoint(); canvas.document.pages[page].elements.append(contentsOf: copies)
        canvas.selectedIDs = Set(copies.map(\.id)); didChange(); refreshSelection()
    }

    func recordOutput(to url: URL, message: String) {
        lastOutputURL = url; outputButton.isHidden = false
        outputButton.toolTip = "\(message)\n\(url.path)\n点击在 Finder 中显示"
        outputButton.setAccessibilityLabel("在 Finder 显示：\(url.lastPathComponent)")
        statusLabel.stringValue = message
    }
    @objc func revealLastOutput() {
        guard let url = lastOutputURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError(DeskError.message("最近输出的文件已被移动或删除：\(url.lastPathComponent)")); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
