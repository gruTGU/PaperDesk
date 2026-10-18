import AppKit

enum PageDrawing {
    static func layout(_ text: NSAttributedString, size: CGSize) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        // Every layout graph belongs to this call; background exports must never schedule
        // additional AppKit layout work or share a canvas/editor layout manager.
        manager.backgroundLayoutEnabled = false
        let safeSize = CGSize(width: size.width.isFinite && size.width > 0 ? size.width : 1,
                              height: size.height.isFinite && size.height > 0 ? size.height : 1)
        let container = NSTextContainer(containerSize: safeSize)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }
    static func overflows(_ element: PaperElement) -> Bool {
        guard element.kind == .text else { return false }
        guard element.width.isFinite, element.height.isFinite, element.width > 0, element.height > 0 else { return true }
        return autoreleasepool {
            let (storage, manager, container) = layout(element.attributedText, size: element.rect.size)
            let range = manager.glyphRange(for: container)
            return storage.length > 0 && NSMaxRange(range) < manager.numberOfGlyphs
        }
    }

    static func draw(_ page: PaperPage, skipText: UUID? = nil, imageCache: [UUID: NSImage] = [:], taggedPDF: Bool = false,
                     allowImageDecoding: Bool = true) {
        // Canvas paints placeholders while its bounded previews decode on a worker.
        try? render(page, skipText: skipText, imageCache: imageCache, taggedPDF: taggedPDF,
                    allowImageDecoding: allowImageDecoding, failOnImageError: false)
    }

    static func drawForExport(_ page: PaperPage, taggedPDF: Bool = false) throws {
        try render(page, skipText: nil, imageCache: [:], taggedPDF: taggedPDF,
                   allowImageDecoding: true, failOnImageError: true)
    }

    private static func render(_ page: PaperPage, skipText: UUID?, imageCache: [UUID: NSImage], taggedPDF: Bool,
                               allowImageDecoding: Bool, failOnImageError: Bool) throws {
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight).fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight)).addClip()
        for item in page.elements {
            try autoreleasepool {
                if item.kind == .text {
                    if item.id == skipText { return }
                    let (storage, manager, container) = layout(item.attributedText, size: item.rect.size)
                    let range = manager.glyphRange(for: container)
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    NSBezierPath(rect: item.rect).addClip()
                    withExtendedLifetime(storage) {
                        if taggedPDF, let context = NSGraphicsContext.current?.cgContext {
                            CGPDFContextBeginTag(context, .paragraph, [CGPDFTagProperty.actualText: storage.string] as CFDictionary)
                        }
                        manager.drawBackground(forGlyphRange: range, at: item.rect.origin)
                        manager.drawGlyphs(forGlyphRange: range, at: item.rect.origin)
                        if taggedPDF, let context = NSGraphicsContext.current?.cgContext { CGPDFContextEndTag(context) }
                    }
                } else {
                    let image: NSImage?
                    if let cached = imageCache[item.id] { image = cached }
                    else if allowImageDecoding {
                        do {
                            let cg = try ImageTools.displayedImage(for: item)
                            image = NSImage(cgImage: cg, size: .zero)
                        } catch {
                            if failOnImageError { throw error }
                            image = nil
                        }
                    } else { image = nil }
                    if let image {
                        image.draw(in: item.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                    } else {
                        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); item.rect.fill()
                        TextStyle.make(allowImageDecoding ? "图片无法读取" : "图片预览未载入", size: 12)
                            .draw(in: item.rect.insetBy(dx: 8, dy: 8))
                    }
                }
            }
        }
    }
}

enum PDFExporter {
    static func write(_ document: PaperDocument, to url: URL) throws {
        try ProjectStore.validate(document)
        let overflowCount = document.pages.reduce(0) { total, page in
            total + page.elements.reduce(0) { $0 + (PageDrawing.overflows($1) ? 1 : 0) }
        }
        guard overflowCount == 0 else { throw DeskError.message("有 \(overflowCount) 个文本框装不下全部文字。请加高文本框、减小字号，或把部分文字移到新页，再导出 PDF。") }
        // Stream large PDFs to a sibling temporary file instead of retaining the complete
        // document in NSMutableData. An image error must never truncate an existing output.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var bounds = CGRect(x: 0, y: 0, width: paperWidth, height: paperHeight)
        guard let consumer = CGDataConsumer(url: temporary as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, [kCGPDFContextTitle: document.title, kCGPDFContextCreator: "PaperDesk"] as CFDictionary) else {
            throw DeskError.message("PDF 上下文创建失败，请检查保存位置是否可写。")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for page in document.pages {
            try autoreleasepool {
                context.beginPDFPage(nil)
                defer { context.endPDFPage() }
                context.saveGState()
                defer { context.restoreGState() }
                context.translateBy(x: 0, y: paperHeight)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                // Decode and draw one image at a time. Previously every image was decoded
                // once for validation and again for drawing, doubling expensive decode work.
                try PageDrawing.drawForExport(page, taggedPDF: true)
            }
        }
        context.closePDF()
        closed = true
        let outputSize = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard outputSize > 0, let finishedPDF = CGPDFDocument(temporary as CFURL),
              finishedPDF.numberOfPages == document.pages.count else {
            throw DeskError.message("PDF 编码或写入不完整，原文件未被覆盖。")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func pageImage(_ page: PaperPage, scale: CGFloat = 2) throws -> CGImage {
        // Reject NaN/infinity and unreasonable bitmap allocations before any Int conversion.
        guard scale.isFinite, scale > 0, scale <= 8 else {
            throw DeskError.message("页面图片的缩放倍数必须大于 0 且不超过 8。")
        }
        try ProjectStore.validate(PaperDocument(pages: [page]))
        guard !page.elements.contains(where: { PageDrawing.overflows($0) }) else {
            throw DeskError.message("本页有文字超出文本框，请先调整后导出图片。")
        }
        let width = max(1, Int(ceil(paperWidth * scale)))
        let height = max(1, Int(ceil(paperHeight * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DeskError.message("页面图像内存分配失败，请降低导出倍率。")
        }
        context.interpolationQuality = .high
        // Fill the fractional extra pixel from rounding too, keeping opaque white borders.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        try PageDrawing.drawForExport(page)
        guard let image = context.makeImage() else { throw DeskError.message("页面图像编码失败。") }
        return image
    }
}
