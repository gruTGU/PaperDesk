import AppKit
import PDFKit

enum PageDrawing {
    static func layout(_ text: NSAttributedString, size: CGSize) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }
    static func overflows(_ element: PaperElement) -> Bool {
        guard element.kind == .text else { return false }
        let (storage, manager, container) = layout(element.attributedText, size: element.rect.size)
        let range = manager.glyphRange(for: container)
        return storage.length > 0 && NSMaxRange(range) < manager.numberOfGlyphs
    }
    static func draw(_ page: PaperPage, skipText: UUID? = nil, imageCache: [UUID: NSImage] = [:], taggedPDF: Bool = false) {
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight)).addClip()
        for item in page.elements {
            if item.kind == .text {
                if item.id == skipText { continue }
                let (storage, manager, container) = layout(item.attributedText, size: item.rect.size)
                let range = manager.glyphRange(for: container)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: item.rect).addClip()
                withExtendedLifetime(storage) {
                    if taggedPDF, let context = NSGraphicsContext.current?.cgContext {
                        CGPDFContextBeginTag(context, .paragraph, [CGPDFTagProperty.actualText: storage.string] as CFDictionary)
                    }
                    manager.drawBackground(forGlyphRange: range, at: item.rect.origin)
                    manager.drawGlyphs(forGlyphRange: range, at: item.rect.origin)
                    if taggedPDF, let context = NSGraphicsContext.current?.cgContext { CGPDFContextEndTag(context) }
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                let image: NSImage?
                if let cached = imageCache[item.id] { image = cached }
                else if let cg = try? ImageTools.displayedImage(for: item) { image = NSImage(cgImage: cg, size: .zero) }
                else { image = nil }
                if let image {
                    image.draw(in: item.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                } else {
                    NSColor.systemRed.withAlphaComponent(0.1).setFill(); item.rect.fill()
                    TextStyle.make("图片无法读取", size: 12).draw(in: item.rect.insetBy(dx: 8, dy: 8))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class ExportPageView: NSView {
    let page: PaperPage
    override var isFlipped: Bool { true }
    init(page: PaperPage) {
        self.page = page
        super.init(frame: CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func draw(_ dirtyRect: NSRect) { PageDrawing.draw(page, taggedPDF: true) }
}

enum PDFExporter {
    static func write(_ document: PaperDocument, to url: URL) throws {
        try ProjectStore.validate(document)
        let overflowCount = document.pages.flatMap(\.elements).filter { PageDrawing.overflows($0) }.count
        guard overflowCount == 0 else { throw DeskError.message("有 \(overflowCount) 个文本框装不下全部文字。请加高文本框、减小字号，或把部分文字移到新页，再导出 PDF。") }
        let output = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, [kCGPDFContextTitle: document.title, kCGPDFContextCreator: "PaperDesk"] as CFDictionary) else {
            throw DeskError.message("PDF 上下文创建失败。")
        }
        for page in document.pages {
            for item in page.elements where item.kind == .image { _ = try ImageTools.displayedImage(for: item) }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: paperHeight)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            PageDrawing.draw(page, taggedPDF: true)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard output.length > 0 else { throw DeskError.message("PDF 编码失败。") }
        try (output as Data).write(to: url, options: .atomic)
    }

    static func pageImage(_ page: PaperPage, scale: CGFloat = 2) throws -> CGImage {
        guard !page.elements.contains(where: { PageDrawing.overflows($0) }) else {
            throw DeskError.message("本页有文字超出文本框，请先调整后导出图片。")
        }
        for item in page.elements where item.kind == .image { _ = try ImageTools.displayedImage(for: item) }
        let view = ExportPageView(page: page)
        guard let pdf = PDFDocument(data: view.dataWithPDF(inside: view.bounds)), let pdfPage = pdf.page(at: 0) else { throw DeskError.message("页面图像生成失败。") }
        let image = pdfPage.thumbnail(of: CGSize(width: paperWidth * scale, height: paperHeight * scale), for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DeskError.message("页面图像编码失败。") }
        return cg
    }
}
