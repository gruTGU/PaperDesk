import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum PaperDeskTests {
    static var checks = 0
    static var failures = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw TestFailure(description: message) }
    }

    static func requireThrows(_ message: String, _ body: () throws -> Void) throws {
        checks += 1
        do { try body() }
        catch { return }
        throw TestFailure(description: message)
    }

    static func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); print("PASS  \(name)") }
        catch { failures += 1; print("FAIL  \(name): \(error)") }
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let keepAt = ProcessInfo.processInfo.environment["PAPERDESK_TEST_OUTPUT"]
        let directory = keepAt.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("PaperDesk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if keepAt == nil { try? FileManager.default.removeItem(at: directory) } }

        run("工程保存、重开与失败保护") { try testProject(directory) }
        run("四边页边距、旧工程兼容与失败保护") { try testMargins(directory) }
        for format in ImageFormat.allCases {
            if format == .heic && ProcessInfo.processInfo.environment["PAPERDESK_SKIP_HEIC"] == "1" {
                print("SKIP  HEIC 编码和压缩（显式跳过；未验证，不计为通过）")
                continue
            }
            run("\(format.rawValue.uppercased()) 编解码") { try testImageFormat(format) }
            run("\(format.rawValue.uppercased()) 实际文件大小上限") { try testCompression(format) }
        }
        run("无效图片和无法满足的压缩目标") { try testInvalidImages() }
        run("EXIF 方向、左上角裁剪与保留原图") { try testOrientationAndCrop() }
        run("两页 A4 PDF、视图和边距不改变固定版面、文本层与溢出保护") { try testPDF(directory) }
        run("DOCX 中文、图片与四边页边距往返") { try testDOCX(directory) }
        run("Markdown 中文及本地图片资源往返") { try testMarkdown(directory) }

        print("\n\(checks) 项断言，\(failures) 个失败组。\(keepAt == nil ? "测试文件已清理。" : "样例保留在 " + directory.path)")
        if failures != 0 { exit(1) }
    }

    static func fixture() throws -> PaperDocument {
        let image = try pattern(width: 96, height: 64)
        let png = try ImageTools.encode(image, format: .png)
        let illustration = PaperElement(kind: .image, x: 65, y: 160, width: 240, height: 160,
                                        imageData: png, imageName: "彩色示例.png")
        let first = PaperPage(elements: [.text("中文作业：第一章\n保留可编辑文本与图片。", height: 95), illustration])
        let second = PaperPage(elements: [.text("第二页：测试段落\nHello PaperDesk 2026", size: 17)])
        return PaperDocument(title: "格式与图片测试", pages: [first, second], zoom: 1.4, pageGap: 55)
    }

    static func testProject(_ directory: URL) throws {
        let document = try fixture()
        let url = directory.appendingPathComponent("作业.paperdesk")
        try ProjectStore.write(document, to: url)
        let loaded = try ProjectStore.read(url)
        try require(document == loaded, "工程重开后内容或设置变化")
        let originalBytes = try Data(contentsOf: url)
        var invalid = document
        invalid.pages[0].elements[0].width = -1
        try requireThrows("负宽度应拒绝保存") { try ProjectStore.write(invalid, to: url) }
        let preservedBytes = try Data(contentsOf: url)
        try require(preservedBytes == originalBytes, "失败保存覆盖了原工程")

        let invalidURL = directory.appendingPathComponent("invalid.paperdesk")
        try JSONEncoder().encode(invalid).write(to: invalidURL)
        try requireThrows("加载时应拒绝无效尺寸") { _ = try ProjectStore.read(invalidURL) }
        invalid = document
        invalid.pages[0].elements[0].x = .nan
        try requireThrows("非有限坐标应拒绝") { try ProjectStore.validate(invalid) }
        invalid = document
        invalid.pages[0].elements[1].crop = CropRect(x: 0.75, y: 0, width: 0.5, height: 1)
        try requireThrows("超出原图的裁剪应拒绝") { try ProjectStore.validate(invalid) }
        invalid = document
        invalid.pages.append(invalid.pages[0])
        try requireThrows("重复页面标识应拒绝") { try ProjectStore.validate(invalid) }
        invalid = document
        invalid.pages.removeAll()
        try requireThrows("没有 A4 页的工程应拒绝") { try ProjectStore.validate(invalid) }
    }

    static func testImageFormat(_ format: ImageFormat) throws {
        let image = try pattern(width: 96, height: 64)
            let data = try ImageTools.encode(image, format: format, quality: 0.95)
            let decoded = try ImageTools.decode(data)
            try require(decoded.width == 96 && decoded.height == 64, "\(format.rawValue) 尺寸往返错误")
            try assertColor(decoded, x: 12, y: 8, expected: (1, 0, 0), tolerance: 0.22,
                            message: "\(format.rawValue) 左上角红色不正确")
            try assertColor(decoded, x: 84, y: 56, expected: (1, 1, 0), tolerance: 0.22,
                            message: "\(format.rawValue) 右下角黄色不正确")
            print("      \(format.rawValue): \(data.count) bytes")
    }

    static func testMargins(_ directory: URL) throws {
        var document = try fixture()
        let elements = document.pages
        document.margins = PageMargins(top: 60, bottom: 90, left: 30, right: 75)
        let url = directory.appendingPathComponent("四边距.paperdesk")
        try ProjectStore.write(document, to: url)
        let loaded = try ProjectStore.read(url)
        try require(loaded == document, "上下左右四个独立值应随工程无损保存")
        try require(loaded.pages == elements, "设置页边距不应移动已有图文")
        try require(loaded.contentRect == CGRect(x: 30, y: 60, width: paperWidth - 105, height: paperHeight - 150),
                    "非对称页边距对应的内容区域不正确")

        let originalBytes = try Data(contentsOf: url)
        var legacy = try JSONSerialization.jsonObject(with: originalBytes) as! [String: Any]
        legacy.removeValue(forKey: "margins")
        let legacyURL = directory.appendingPathComponent("旧版工程.paperdesk")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        let oldDocument = try ProjectStore.read(legacyURL)
        try require(oldDocument.margins == PageMargins() && oldDocument.pages == elements,
                    "旧版无 margins 字段的工程应使用 15 mm 边距并保留内容")

        let invalidMargins = [PageMargins(top: -1), PageMargins(bottom: .infinity), PageMargins(left: .nan),
                              PageMargins(left: 0, right: paperWidth - 10),
                              PageMargins(top: paperHeight - 10, bottom: 0)]
        for margins in invalidMargins {
            var invalid = document
            invalid.margins = margins
            try requireThrows("负数、非有限或挤压内容区域的页边距应拒绝保存") { try ProjectStore.write(invalid, to: url) }
            let preserved = try Data(contentsOf: url)
            try require(preserved == originalBytes, "无效页边距保存覆盖了已有工程")
        }
        let minimum = PageMargins.minimumContentDimension
        document.margins = PageMargins(top: paperHeight - minimum, bottom: 0, left: 0, right: paperWidth - minimum)
        try ProjectStore.validate(document)
        try require(abs(document.contentRect.width - minimum) < 0.0001 && abs(document.contentRect.height - minimum) < 0.0001,
                    "最小 10 × 10 mm 内容区域边界应被接受")
    }

    static func testCompression(_ format: ImageFormat) throws {
        let image = try noisyImage(width: 512, height: 384)
            let limit = format == .png ? 25_000 : 8_000
            let result = try ImageTools.export(image, format: format, maxBytes: limit)
            try require(result.data.count <= limit, "\(format.rawValue) 超出目标：\(result.data.count) > \(limit)")
            let decoded = try ImageTools.decode(result.data)
            try require(decoded.width == result.width && decoded.height == result.height,
                        "压缩结果报告的尺寸与实际文件不同")
            try require(result.width <= image.width && result.height <= image.height,
                        "压缩不应放大图片")
            if format == .png { try require(result.resized, "高熵 PNG 应通过缩小尺寸满足上限") }
            print("      \(format.rawValue): \(result.data.count) / \(limit) bytes，\(result.width)×\(result.height)，quality \(String(format: "%.3f", result.quality))")
    }

    static func testInvalidImages() throws {
        let image = try pattern(width: 96, height: 64)
        try requireThrows("损坏图片应报错") { _ = try ImageTools.decode(Data("not an image".utf8)) }
        try requireThrows("零字节上限应拒绝") { _ = try ImageTools.export(image, format: .jpeg, maxBytes: 0) }
        try requireThrows("低于文件头的上限应明确失败") { _ = try ImageTools.export(image, format: .png, maxBytes: 1) }
    }

    static func testOrientationAndCrop() throws {
        let image = try pattern(width: 96, height: 64)
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TestFailure(description: "无法创建 EXIF 测试图片")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
                                                       kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "EXIF 测试图片编码失败")
        let upright = try ImageTools.decode(buffer as Data)
        try require(upright.width == 64 && upright.height == 96, "EXIF 6 应顺时针旋转并交换尺寸")
        try assertColor(upright, x: 8, y: 12, expected: (0, 0, 1), tolerance: 0.25, message: "旋转后的左上角应为蓝色")
        try assertColor(upright, x: 56, y: 12, expected: (1, 0, 0), tolerance: 0.25, message: "旋转后的右上角应为红色")
        try assertColor(upright, x: 8, y: 84, expected: (1, 1, 0), tolerance: 0.25, message: "旋转后的左下角应为黄色")
        try assertColor(upright, x: 56, y: 84, expected: (0, 1, 0), tolerance: 0.25, message: "旋转后的右下角应为绿色")

        let crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let cropped = try ImageTools.crop(image, to: crop)
        try require(cropped.width == 48 && cropped.height == 32, "归一化裁剪尺寸不正确")
        try assertColor(cropped, x: 24, y: 16, expected: (1, 0, 0), tolerance: 0.01, message: "裁剪原点应在左上角")
        let bytes = try ImageTools.encode(image, format: .png)
        let item = PaperElement(kind: .image, x: 0, y: 0, width: 80, height: 60, imageData: bytes, crop: crop)
        let displayed = try ImageTools.displayedImage(for: item)
        try require(displayed.width == 48 && displayed.height == 32, "画布图片未应用裁剪")
        try require(item.imageData == bytes && image.width == 96 && image.height == 64, "裁剪破坏了原图数据")
        try requireThrows("越界裁剪应报错") {
            _ = try ImageTools.crop(image, to: CropRect(x: -0.1, y: 0, width: 1, height: 1))
        }
    }

    static func testPDF(_ directory: URL) throws {
        var document = try fixture()
        let firstURL = directory.appendingPathComponent("A4.pdf")
        let secondURL = directory.appendingPathComponent("A4-other-view.pdf")
        try PDFExporter.write(document, to: firstURL)
        document.zoom = 0.25
        document.pageGap = 120
        document.margins = PageMargins(top: 100, bottom: 20, left: 5, right: 75)
        try PDFExporter.write(document, to: secondURL)
        guard let first = PDFDocument(url: firstURL), let second = PDFDocument(url: secondURL) else {
            throw TestFailure(description: "导出的 PDF 无法打开")
        }
        try require(first.pageCount == 2 && second.pageCount == 2, "PDF 页数应为 2")
        for index in 0..<2 {
            guard let a = first.page(at: index), let b = second.page(at: index) else {
                throw TestFailure(description: "PDF 缺少第 \(index + 1) 页")
            }
            let bounds = a.bounds(for: .mediaBox)
            try require(abs(bounds.width - paperWidth) < 0.02 && abs(bounds.height - paperHeight) < 0.02,
                        "PDF 必须是 A4，实际为 \(bounds)")
            let firstRaster = try raster(a)
            let secondRaster = try raster(b)
            try require(firstRaster == secondRaster, "缩放、页间距或页边距辅助线改变了第 \(index + 1) 页的固定版面")
        }
        let text = first.string ?? ""
        print("      PDF 文本：\(text.replacingOccurrences(of: "\n", with: " / "))")
        // macOS may map identical Chinese glyphs to compatibility radicals in PDF ToUnicode.
        let normalized = text.precomposedStringWithCompatibilityMapping
        try require(normalized.contains("中文作业") && text.contains("测试段落") && text.contains("Hello PaperDesk"), "PDF 应包含可提取的中英文文本层")
        print("      注：系统字体的部分字形被映射为兼容部首；文本层不保证逐码位往返，固定版面不受影响。")
        var overflow = document
        overflow.pages[0].elements[0] = .text(String(repeating: "不能静默裁掉的文字", count: 100), width: 100, height: 20)
        try requireThrows("文字溢出必须阻止 PDF 静默截断") { try PDFExporter.write(overflow, to: directory.appendingPathComponent("overflow.pdf")) }
    }

    static func testDOCX(_ directory: URL) throws {
        var document = try fixture()
        document.margins = PageMargins(top: 60, bottom: 90, left: 120, right: 100)
        document.pages[0].elements[1].width = 600
        document.pages[0].elements[1].height = 400
        let url = directory.appendingPathComponent("中文 作业.docx")
        try DocumentConversion.exportDOCX(document, to: url)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "无法读取导出 DOCX 的页面设置")
        try require(xml.contains("<w:pgMar w:top=\"1200\" w:right=\"2000\" w:bottom=\"1800\" w:left=\"2400\""),
                    "DOCX 没有按 twips 写入四个独立页边距")
        let imageScale = min(1, document.contentRect.width / 600, document.contentRect.height / 400)
        try require(xml.contains("<wp:extent cx=\"\(Int(600 * imageScale * 12700))\" cy=\"\(Int(400 * imageScale * 12700))\"/>"),
                    "DOCX 图片未缩放至非对称页边距内的区域")
        let imported = try DocumentConversion.importDocument(from: url)
        try ProjectStore.validate(imported)
        try require(imported.margins == document.margins, "DOCX 单节页边距往返发生变化")
        try require(imported.pages.flatMap(\.elements).allSatisfy { abs($0.x - document.margins.left) < 0.001 },
                    "DOCX 重新分页没有遵循左页边距")
        let items = imported.pages.flatMap(\.elements)
        let text = items.filter { $0.kind == .text }.map { $0.attributedText.string }.joined(separator: "\n")
        try require(text.contains("中文作业") && text.contains("第二页") && text.contains("Hello PaperDesk"),
                    "DOCX 往返丢失中英文文本")
        let images = items.filter { $0.kind == .image }
        try require(!images.isEmpty, "DOCX 往返应保留内嵌图片")
        let roundtrip = try ImageTools.displayedImage(for: images[0])
        try assertColor(roundtrip, x: roundtrip.width / 8, y: roundtrip.height / 8, expected: (1, 0, 0),
                        tolerance: 0.22, message: "DOCX 图片内容或方向变化")
        let native = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        try require(native.string.contains("中文作业"), "系统 Word 解析器不能读取导出文件的中文文本")

        let minimum = PageMargins.minimumContentDimension
        let boundary = PaperDocument(margins: PageMargins(top: paperHeight - minimum, bottom: 0,
                                                          left: 0, right: paperWidth - minimum))
        let boundaryURL = directory.appendingPathComponent("最小内容区域.docx")
        try DocumentConversion.exportDOCX(boundary, to: boundaryURL)
        let boundaryImported = try DocumentConversion.importDocument(from: boundaryURL)
        try require(boundaryImported.margins.isValid, "DOCX twips 换算不应使最小内容区域的边距无效")
    }

    static func testMarkdown(_ directory: URL) throws {
        let document = try fixture()
        let url = directory.appendingPathComponent("Markdown 作业.md")
        try DocumentConversion.exportMarkdown(document, to: url)
        let source = try String(contentsOf: url, encoding: .utf8)
        try require(source.contains("中文作业") && source.contains("第二页"), "Markdown 缺少中文文本")
        let regex = try NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
        let references = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        try require(!references.isEmpty, "Markdown 缺少图片引用")
        for match in references {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let path = String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let resource = directory.appendingPathComponent(path.removingPercentEncoding ?? path)
            try require(FileManager.default.fileExists(atPath: resource.path), "Markdown 引用的图片文件不存在：\(path)")
            let image = try ImageTools.decode(Data(contentsOf: resource))
            try require(image.width > 0 && image.height > 0, "Markdown 图片无法读取")
        }
        let imported = try DocumentConversion.importDocument(from: url)
        try ProjectStore.validate(imported)
        let items = imported.pages.flatMap(\.elements)
        try require(items.contains { $0.kind == .image }, "Markdown 导入未读取相对路径图片")
        try require(items.contains { $0.kind == .text && $0.attributedText.string.contains("中文作业") },
                    "Markdown 导入未保留中文")
    }

    static func pattern(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let top = y < height / 2
                let left = x < width / 2
                pixels[offset] = (top && left) || (!top && !left) ? 255 : 0
                pixels[offset + 1] = !left ? 255 : 0
                pixels[offset + 2] = !top && left ? 255 : 0
            }
        }
        return try rawImage(pixels, width: width, height: height)
    }

    static func noisyImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x12345678
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                seed = 1664525 &* seed &+ 1013904223
                pixels[index * 4 + channel] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        return try rawImage(pixels, width: width, height: height)
    }

    static func rawImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw TestFailure(description: "无法创建图片测试样本")
        }
        return image
    }

    static func assertColor(_ image: CGImage, x: Int, y: Int, expected: (Double, Double, Double),
                            tolerance: Double, message: String) throws {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestFailure(description: "无法读取测试像素")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let raw = context.data?.assumingMemoryBound(to: UInt8.self) else { throw TestFailure(description: "测试像素内存缺失") }
        let offset = (y * image.width + x) * 4
        let actual = (Double(raw[offset]) / 255, Double(raw[offset + 1]) / 255, Double(raw[offset + 2]) / 255)
        try require(abs(actual.0 - expected.0) <= tolerance && abs(actual.1 - expected.1) <= tolerance && abs(actual.2 - expected.2) <= tolerance,
                    "\(message)，实际 RGB=\(actual)")
    }

    static func raster(_ page: PDFPage) throws -> Data {
        let width = 300
        let height = 425
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pageRef = page.pageRef else {
            throw TestFailure(description: "无法栅格化 PDF 进行对照")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bounds = page.bounds(for: .mediaBox)
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.drawPDFPage(pageRef)
        guard let bytes = context.data else { throw TestFailure(description: "PDF 像素数据缺失") }
        return Data(bytes: bytes, count: width * height * 4)
    }
}
