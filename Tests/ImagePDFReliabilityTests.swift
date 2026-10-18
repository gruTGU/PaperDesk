import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

private struct ReliabilityFailure: Error, CustomStringConvertible { let description: String }

@main
enum ImagePDFReliabilityTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw ReliabilityFailure(description: message) }
    }
    static func throwsError(_ message: String, _ body: () throws -> Void) throws {
        checks += 1
        do { try body() } catch { return }
        throw ReliabilityFailure(description: message)
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDesk-image-pdf-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try testThumbnails()
            print("PASS  有界缩略解码、全部 EXIF 方向、裁剪及无效输入")
            try testBitmap(directory)
            print("PASS  无 NSView 页面位图、坐标方向、倍率校验与失败保护")
            try testPDF(directory)
            print("PASS  流式 PDF、多页文字与图片、原文件替换及异常清理")
            try testWorker(directory)
            print("PASS  后台线程独立图文布局和连续 PDF/位图导出")
            print("\(checks) 项断言，0 个失败。测试文件已清理。")
        } catch {
            print("FAIL  \(error)")
            exit(1)
        }
    }

    static func pattern(width: Int = 800, height: Int = 400) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = (x < width / 2 && y < height / 2) || (x >= width / 2 && y >= height / 2) ? 255 : 0
                pixels[offset + 1] = x >= width / 2 ? 255 : 0
                pixels[offset + 2] = x < width / 2 && y >= height / 2 ? 255 : 0
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ReliabilityFailure(description: "无法创建测试图片")
        }
        return image
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ReliabilityFailure(description: "无法读取像素")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<4).map { Int(bytes[(y * image.width + x) * 4 + $0]) }
    }

    static func testThumbnails() throws {
        let original = try pattern()
        let png = try ImageTools.encode(original, format: .png)
        let thumbnail = try ImageTools.decodeThumbnail(png, maxPixelSize: 200)
        try require(thumbnail.width == 200 && thumbnail.height == 100, "缩略图没有按最长边缩小")
        let full = try ImageTools.decode(png)
        try require(full.width == 800 && full.height == 400, "预览功能改变了完整解码尺寸")
        let largerLimit = try ImageTools.decodeThumbnail(png, maxPixelSize: 2048)
        try require(largerLimit.width == 800 && largerLimit.height == 400, "缩略解码不应放大小图")
        let item = PaperElement(kind: .image, x: 0, y: 0, width: 200, height: 100,
                                imageData: png, crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let cropped = try ImageTools.preview(for: item, maxPixelSize: 200)
        // Core Graphics may pad rows for alignment; count the actual stride in the cache.
        try require(cropped.bitsPerComponent == 8 && cropped.bitsPerPixel == 32 && cropped.bytesPerRow >= cropped.width * 4 && cropped.bytesPerRow <= cropped.width * 4 + 256, "预览应使用独立且可准确计量的 RGBA 缓冲")
        let cropPixel = try pixel(cropped, x: 30, y: 20)
        try require(cropped.width == 100 && cropped.height == 50, "预览未正确应用归一化裁剪")
        try require(cropPixel[0] > 245 && cropPixel[1] < 10 && cropPixel[2] < 10, "预览裁剪原点应在左上角")
        try require(item.imageData == png, "预览改变了原图数据")
        for orientation in 1...8 {
            let bytes = NSMutableData()
            let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: orientation,
                                                              kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
            try require(CGImageDestinationFinalize(destination), "无法创建 EXIF 样例")
            let preview = try ImageTools.decodeThumbnail(bytes as Data, maxPixelSize: 200)
            let upright = try ImageTools.decode(bytes as Data)
            try require(max(preview.width, preview.height) == 200 && min(preview.width, preview.height) == 100,
                        "EXIF \(orientation) 预览尺寸错误")
            for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let a = try pixel(preview, x: Int(Double(preview.width) * fx), y: Int(Double(preview.height) * fy))
                let b = try pixel(upright, x: Int(Double(upright.width) * fx), y: Int(Double(upright.height) * fy))
                try require(zip(a, b).allSatisfy { abs($0 - $1) < 24 }, "EXIF \(orientation) 缩略图与完整图方向不一致")
            }
        }
        for size in [0, -1, Int.max, 8193] {
            try throwsError("无效预览尺寸未拒绝") { _ = try ImageTools.decodeThumbnail(png, maxPixelSize: size) }
        }
        try throwsError("损坏缩略图输入未拒绝") { _ = try ImageTools.decodeThumbnail(Data("broken".utf8)) }
        try throwsError("缺失图片的预览未拒绝") { _ = try ImageTools.preview(for: .text("not image")) }
        try throwsError("无效裁剪未拒绝") {
            var invalid = item; invalid.crop.width = .nan
            _ = try ImageTools.preview(for: invalid)
        }
    }

    static func fixture() throws -> PaperPage {
        let image = try ImageTools.encode(pattern(), format: .png)
        return PaperPage(elements: [PaperElement(kind: .image, x: 10, y: 10, width: 200, height: 100, imageData: image),
                                    .text("Background A4 export 中文", x: 20, y: 150, width: 500, height: 100)])
    }

    static func testBitmap(_ directory: URL) throws {
        let page = try fixture()
        let output = try PDFExporter.pageImage(page, scale: 1)
        try require(output.width == Int(ceil(paperWidth)) && output.height == Int(ceil(paperHeight)), "页面位图尺寸不符 A4")
        let topLeft = try pixel(output, x: 40, y: 35)
        let bottomLeft = try pixel(output, x: 40, y: 85)
        try require(topLeft[0] > 245 && topLeft[1] < 10 && topLeft[2] < 10, "位图左上角红块方向错误")
        try require(bottomLeft[0] < 10 && bottomLeft[1] < 10 && bottomLeft[2] > 245, "位图左下角蓝块方向错误")
        let white = try pixel(output, x: output.width - 1, y: output.height - 1)
        try require(white.allSatisfy { $0 == 255 }, "页面四周应为不透明白色")
        for scale: CGFloat in [.nan, .infinity, -.infinity, 0, -1, 9, .greatestFiniteMagnitude] {
            try throwsError("不安全页面倍率未拒绝") { _ = try PDFExporter.pageImage(page, scale: scale) }
        }
        var invalidPage = page
        invalidPage.elements[0].width = .nan
        try throwsError("无效页面坐标未拒绝") { _ = try PDFExporter.pageImage(invalidPage) }
        let overflow = PaperPage(elements: [.text(String(repeating: "overflow", count: 100), width: 10, height: 10)])
        try throwsError("文字溢出没有阻止位图导出") { _ = try PDFExporter.pageImage(overflow) }
        invalidPage = page
        invalidPage.elements[0].imageData = Data("broken image".utf8)
        let priorContext = NSGraphicsContext.current
        try throwsError("损坏图片不能静默导出为占位图") { _ = try PDFExporter.pageImage(invalidPage) }
        try require(NSGraphicsContext.current === priorContext, "失败的导出未恢复线程绘图上下文")
    }

    static func testPDF(_ directory: URL) throws {
        let target = directory.appendingPathComponent("safe.pdf")
        let original = Data("An existing file must survive an export failure".utf8)
        try original.write(to: target)
        var page = try fixture()
        page.elements[0].imageData = Data("broken image".utf8)
        try throwsError("损坏图片未阻止 PDF 导出") { try PDFExporter.write(PaperDocument(pages: [page]), to: target) }
        let preserved = try Data(contentsOf: target)
        try require(preserved == original, "失败导出覆盖了原文件")
        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try require(leftovers.count == 1 && leftovers.first?.standardizedFileURL.path == target.standardizedFileURL.path, "失败 PDF 导出留下临时文件：\(leftovers.map(\.path))")
        let document = PaperDocument(pages: [try fixture(), try fixture()])
        try PDFExporter.write(document, to: target)
        let pdf = PDFDocument(url: target)
        try require(pdf?.pageCount == 2, "已有目标文件没有安全替换为两页 PDF")
        try require((pdf?.string ?? "").contains("Background A4 export"), "PDF 丢失可选择文字层")
        let bounds = pdf!.page(at: 0)!.bounds(for: .mediaBox)
        try require(abs(bounds.width - paperWidth) < 0.02 && abs(bounds.height - paperHeight) < 0.02, "PDF 不是固定 A4")
        let finalFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try require(finalFiles.count == 1, "成功 PDF 导出留下临时文件")
    }

    static func testWorker(_ directory: URL) throws {
        let document = PaperDocument(pages: [try fixture()])
        let completion = DispatchSemaphore(value: 0)
        var outcome: Result<Int, Error>?
        DispatchQueue(label: "PaperDesk.tests.image-pdf.worker").async {
            outcome = Result {
                var exports = 0
                for index in 0..<5 {
                    try autoreleasepool {
                        let image = try PDFExporter.pageImage(document.pages[0], scale: 1)
                        guard image.width == Int(ceil(paperWidth)) else { throw ReliabilityFailure(description: "后台位图宽度不正确") }
                        try PDFExporter.write(document, to: directory.appendingPathComponent("worker-\(index).pdf"))
                        exports += 1
                    }
                }
                return exports
            }
            completion.signal()
        }
        try require(completion.wait(timeout: .now() + 30) == .success, "后台绘制阻塞或未完成")
        let completed = try outcome?.get()
        try require(completed == 5, "后台连续导出未全部完成")
    }
}
