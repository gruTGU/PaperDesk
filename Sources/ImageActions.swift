import AppKit
import UniformTypeIdentifiers

final class CropPreviewView: NSView {
    let image: NSImage
    var selection: CropRect
    var anchor: CGPoint?
    override var isFlipped: Bool { true }
    init(image: CGImage, crop: CropRect) {
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        self.selection = crop
        super.init(frame: CGRect(x: 0, y: 0, width: 510, height: 350))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    var imageRect: CGRect {
        let fit = min((bounds.width - 16) / image.size.width, (bounds.height - 16) / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill(); bounds.fill()
        let rect = imageRect
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let selected = CGRect(x: rect.minX + selection.x * rect.width, y: rect.minY + selection.y * rect.height, width: selection.width * rect.width, height: selection.height * rect.height)
        let shade = NSBezierPath(rect: rect); shade.appendRect(selected); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill(); shade.fill()
        NSColor.white.setStroke(); let border = NSBezierPath(rect: selected); border.lineWidth = 1.5; border.stroke()
        let thirds = NSBezierPath()
        for step in 1...2 {
            let x = selected.minX + selected.width * CGFloat(step) / 3
            let y = selected.minY + selected.height * CGFloat(step) / 3
            thirds.move(to: CGPoint(x: x, y: selected.minY)); thirds.line(to: CGPoint(x: x, y: selected.maxY))
            thirds.move(to: CGPoint(x: selected.minX, y: y)); thirds.line(to: CGPoint(x: selected.maxX, y: y))
        }
        NSColor.white.withAlphaComponent(0.4).setStroke(); thirds.lineWidth = 0.5; thirds.stroke()
    }
    func normalized(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: max(0, min(1, (point.x - rect.minX) / rect.width)), y: max(0, min(1, (point.y - rect.minY) / rect.height)))
    }
    override func mouseDown(with event: NSEvent) { anchor = normalized(event) }
    override func mouseDragged(with event: NSEvent) {
        guard let start = anchor else { return }
        let end = normalized(event)
        if abs(end.x - start.x) > 0.002 && abs(end.y - start.y) > 0.002 {
            selection = CropRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); anchor = nil }
}

extension EditorController {
    @objc func cropImage() {
        canvas.finishEditing()
        guard let item = canvas.selectedElement, item.kind == .image, let data = item.imageData else {
            showError(DeskError.message("请先选择一张图片。")); return
        }
        withError {
            let original = try ImageTools.decode(data)
            let preview = CropPreviewView(image: original, crop: item.crop)
            let alert = NSAlert(); alert.messageText = "裁剪图片"; alert.informativeText = "在原图上拖出保留的矩形区域。原图会保留，可随时重新裁剪。"
            alert.accessoryView = preview; alert.addButton(withTitle: "应用裁剪"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "恢复完整图片")
            let result = alert.runModal()
            guard result != .alertSecondButtonReturn else { return }
            let crop = result == .alertThirdButtonReturn ? CropRect.full : preview.selection
            let cropped = try ImageTools.crop(original, to: crop)
            checkpoint()
            let ratio = Double(cropped.width) / Double(cropped.height)
            let width = min(item.width, paperWidth - item.x)
            let height = width / ratio
            let fit = min(1, (paperHeight - item.y) / height)
            modifySelected { $0.crop = crop; $0.width = width * fit; $0.height = height * fit }
            canvas.invalidateImages(); didChange(); refreshSelection()
        }
    }
    @objc func makeCollage() {
        canvas.finishEditing()
        let pageIndex = canvas.activePage
        let all = canvas.document.pages[pageIndex].elements.filter { $0.kind == .image }
        let selected = all.filter { canvas.selectedIDs.contains($0.id) }
        let images = selected.count >= 2 ? selected : all
        guard images.count >= 2 else { showError(DeskError.message("请在当前页插入至少两张图片，再进行拼图。")); return }
        let columns = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 110, height: 26)); columns.addItems(withTitles: ["1 列", "2 列", "3 列", "4 列", "5 列", "6 列"]); columns.selectItem(at: 1)
        let gap = NSTextField(string: "5"); gap.frame = CGRect(x: 0, y: 0, width: 110, height: 24)
        let stack = NSStackView(views: [NSTextField(labelWithString: "列数"), columns, NSTextField(labelWithString: "图片间距（mm）"), gap]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        columns.widthAnchor.constraint(equalToConstant: 150).isActive = true
        gap.widthAnchor.constraint(equalToConstant: 150).isActive = true
        stack.setFrameSize(CGSize(width: 320, height: 120))
        let alert = NSAlert(); alert.messageText = "排列 \(images.count) 张图片"; alert.informativeText = "在当前页的上下左右页边距以内等比排列。已有文字保留原位，可用撤销恢复。"; alert.accessoryView = stack; alert.addButton(withTitle: "排列"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let gapMM = Double(gap.stringValue), gapMM.isFinite, (0...30).contains(gapMM) else { showError(DeskError.message("图片间距请输入 0～30 mm。")); return }
        let count = min(images.count, columns.indexOfSelectedItem + 1)
        let rows = Int(ceil(Double(images.count) / Double(count)))
        let spacing = gapMM * 72 / 25.4
        let content = canvas.document.contentRect
        let width = (content.width - Double(count - 1) * spacing) / Double(count)
        let height = (content.height - Double(rows - 1) * spacing) / Double(rows)
        guard width > 10, height > 10 else { showError(DeskError.message("图片太多或间距太大，请增加列数或分到多页。")); return }
        checkpoint()
        for (order, image) in images.enumerated() {
            if let index = canvas.document.pages[pageIndex].elements.firstIndex(where: { $0.id == image.id }) {
                let factor = min(width / image.width, height / image.height)
                let w = image.width * factor, h = image.height * factor
                canvas.document.pages[pageIndex].elements[index].rect = CGRect(x: content.minX + Double(order % count) * (width + spacing) + (width - w) / 2, y: content.minY + Double(order / count) * (height + spacing) + (height - h) / 2, width: w, height: h)
            }
        }
        canvas.selectedIDs = Set(images.map(\.id)); didChange(); refreshSelection()
    }
    @objc func exportSelectedImage() {
        canvas.finishEditing()
        guard let item = canvas.selectedElement, item.kind == .image else { showError(DeskError.message("请先选择一张图片，再另存或压缩。")); return }
        withError {
            let image = try ImageTools.displayedImage(for: item)
            presentImageExport(image, suggestedName: (item.imageName as NSString?)?.deletingPathExtension ?? "图片")
        }
    }
    @objc func exportPageImage() {
        canvas.finishEditing()
        withError { presentImageExport(try PDFExporter.pageImage(canvas.document.pages[canvas.activePage], scale: 2), suggestedName: canvas.document.title + "-第\(canvas.activePage + 1)页") }
    }
    func presentImageExport(_ image: CGImage, suggestedName: String) {
        guard !exporting else { showError(DeskError.message("正在处理上一张图片，请稍候。")); return }
        let formatPicker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 270, height: 26))
        ImageFormat.allCases.forEach { formatPicker.addItem(withTitle: $0.title) }
        formatPicker.selectItem(at: 1)
        let limit = NSTextField(string: "0"); limit.frame = CGRect(x: 0, y: 0, width: 270, height: 24)
        let stack = NSStackView(views: [NSTextField(labelWithString: "保存格式"), formatPicker, NSTextField(labelWithString: "大小上限（KB，1 KB = 1000 字节；0 为不限）"), limit]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        formatPicker.widthAnchor.constraint(equalToConstant: 320).isActive = true
        limit.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.setFrameSize(CGSize(width: 360, height: 120))
        let alert = NSAlert(); alert.messageText = "图片另存 / 压缩"
        alert.informativeText = "当前 \(image.width) × \(image.height) 像素。\n为满足上限可能降低质量或像素尺寸。PNG 保留透明，JPEG / HEIC 使用白色底。"; alert.accessoryView = stack; alert.addButton(withTitle: "选择保存位置"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let kb = Double(limit.stringValue), kb.isFinite, kb >= 0, kb <= 200000 else { showError(DeskError.message("大小上限请输入 0～200000 KB。")); return }
        let maxBytes = kb == 0 ? nil : max(1, Int(kb * 1000))
        let format = ImageFormat.allCases[formatPicker.indexOfSelectedItem]
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .image]; panel.nameFieldStringValue = suggestedName + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        statusLabel.stringValue = "正在处理图片…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<ImageExportResult, Error> = Result {
                let exported = try ImageTools.export(image, format: format, maxBytes: maxBytes)
                try exported.data.write(to: url, options: .atomic)
                return exported
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.exporting = false
                switch result {
                case .success(let output):
                    self.statusLabel.stringValue = String(format: "已保存：%.1f KB · %d × %d 像素%@", Double(output.data.count) / 1000, output.width, output.height, output.resized ? " · 已降低像素尺寸" : "")
                case .failure(let error): self.statusLabel.stringValue = "图片导出失败"; self.showError(error)
                }
            }
        }
    }
}
