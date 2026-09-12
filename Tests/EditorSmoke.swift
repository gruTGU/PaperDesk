import AppKit

@main enum UISmoke {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let ambient = NSAppearance(named: appearanceName)!
            NSApp.appearance = ambient
            ambient.performAsCurrentDrawingAppearance {
                let probe = EditorController()
                probe.autosaveTimer?.invalidate()
                let root = probe.window.contentView!
                guard let cg = root.layer?.backgroundColor,
                      let background = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else {
                    print("FAIL missing panel background"); exit(1)
                }
                var text = NSColor.black
                probe.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    text = probe.titleLabel.textColor!.usingColorSpace(.sRGB)!
                }
                let brightness = min(background.redComponent, background.greenComponent, background.blueComponent)
                let contrast = (luminance(background) + 0.05) / (luminance(text) + 0.05)
                guard brightness >= 0.9, contrast >= 7 else {
                    print("FAIL panel contrast under \(appearanceName.rawValue): background minimum=\(brightness), contrast=\(contrast)")
                    exit(1)
                }
                print("PASS readable light panels under \(appearanceName.rawValue): contrast=\(String(format: "%.1f", contrast)):1")
            }
        }
        try testCanvasNavigation()
        try testWorkspace()
        let context = CGContext(data: nil, width: 192, height: 128, bitsPerComponent: 8, bytesPerRow: 192 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, color) in [NSColor.systemTeal, .systemOrange, .systemBlue, .systemYellow].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: (i % 2) * 96, y: (i / 2) * 64, width: 96, height: 64))
        }
        let image = PaperElement(kind: .image, x: 65, y: 160, width: 300, height: 200, imageData: try ImageTools.encode(context.makeImage()!, format: .png), imageName: "配色示例.png")
        let doc = PaperDocument(title: "图文作业示例", pages: [PaperPage(elements: [.text("观察与记录\n在 A4 页面上自由整理文字和图片。", height: 95, size: 16), image]), PaperPage(elements: [.text("第二页\n继续记录。")])], zoom: 1, pageGap: 28)
        let controller = EditorController()
        controller.autosaveTimer?.invalidate()
        controller.load(doc, url: nil, imported: false)
        let root = controller.window.contentView!
        root.layoutSubtreeIfNeeded()
        controller.updateLayout()
        root.layoutSubtreeIfNeeded()
        print("root=\(root.frame) scroll=\(controller.scroll.frame) canvas=\(controller.canvas.frame) inspector=\(controller.inspector.frame)")
        print("ambiguous root=\(root.hasAmbiguousLayout) inspector=\(controller.inspector.hasAmbiguousLayout) pageList=\(controller.pageList.frame)")
        guard controller.scroll.frame.width > 500, controller.scroll.frame.height > 400 else { fatalError("editor layout collapsed") }
        let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("interface.png"))
        let firstID = controller.canvas.document.pages[0].elements[0].id
        controller.canvas.selectedIDs = [firstID]
        controller.canvas.startEditing(firstID)
        guard let editor = controller.canvas.textEditor else { fatalError("no text editor") }
        editor.textStorage?.setAttributedString(TextStyle.make("这是内部编辑测试。\n中文与 English 123。", size: 16))
        controller.canvas.textDidChange(Notification(name: NSText.didChangeNotification))
        controller.canvas.finishEditing()
        assert(controller.canvas.document.pages[0].elements[0].attributedText.string.contains("内部编辑测试"))
        controller.fontSizeField.stringValue = "18"
        controller.applyFontSize()
        assert((controller.canvas.document.pages[0].elements[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
        controller.deleteSelection()
        assert(!controller.canvas.document.pages[0].elements.contains { $0.id == firstID })
        controller.undoAction()
        assert(controller.canvas.document.pages[0].elements.contains { $0.id == firstID })
        controller.redoAction()
        assert(!controller.canvas.document.pages[0].elements.contains { $0.id == firstID })
        controller.addPage()
        assert(controller.canvas.document.pages.count == 3)
        controller.duplicatePage()
        assert(controller.canvas.document.pages.count == 4)
        controller.deletePage()
        assert(controller.canvas.document.pages.count == 3)
        try ProjectStore.validate(controller.canvas.document)
        print("PASS internal controller editing, font change, delete, undo/redo, page operations, layout render")
    }
    static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
}
