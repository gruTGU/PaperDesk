import AppKit
import zlib

private struct ConversionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum ConversionStabilityTests {
    static var checks = 0
    static let bodyPrefix = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
    static let bodySuffix = "</w:body></w:document>"

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw ConversionFailure(description: message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        checks += 1
        do { try action() } catch { return }
        throw ConversionFailure(description: message)
    }
    static func text(_ document: PaperDocument) -> String {
        document.pages.flatMap(\.elements).filter { $0.kind == .text }.map { $0.attributedText.string }.joined()
    }
    static func xml(_ content: String) -> String { bodyPrefix + "<w:p><w:r><w:t>" + content + "</w:t></w:r></w:p>" + bodySuffix }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDesk-conversion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if CommandLine.arguments.contains("--benchmark") {
            let value = String(repeating: "中文长文布局 Text with emoji 😀 and accent é。", count: 3500)
            let url = directory.appendingPathComponent("long.txt")
            try Data(value.utf8).write(to: url)
            let start = Date()
            let document = try DocumentConversion.importDocument(from: url)
            try require(text(document) == value, "长文分页丢失或重复字符")
            print("BENCHMARK \(value.utf16.count) UTF-16 characters, \(document.pages.count) pages, \(String(format: "%.3f", Date().timeIntervalSince(start))) seconds")
            return
        }
        try testArchive(directory)
        print("PASS  DEFLATE、损坏归档、长度/CRC/目录一致性")
        try testXML(directory)
        print("PASS  XML 复杂度、实体和错误输入")
        try testPagination(directory)
        print("PASS  长文、Unicode 和连续空白页分页")
        try testUnicodeRTF(directory)
        print("PASS  组合 emoji、ZWJ/ZWNJ、字体回退与文字样式保存")
        try testMarkdown(directory)
        print("PASS  Markdown 本地文件边界和失败导出保护")
        try testWorker(directory)
        print("PASS  独占工作线程上的 DOCX/Markdown 往返")
        print("\(checks) conversion stability checks passed; temporary fixtures removed.")
    }

    static func testArchive(_ directory: URL) throws {
        let value = "压缩 DOCX 中文与 emoji 😀，保留全部内容。"
        let valid = try archive(Data(xml(value).utf8))
        let url = directory.appendingPathComponent("test [literal]*?.docx")
        try valid.write(to: url)
        let recovered = text(try DocumentConversion.importDocument(from: url))
        try require(recovered == value, "原始 DEFLATE 读取失败：\(recovered.debugDescription)")
        var bad = valid
        let central = centralOffset(valid)
        bad.replaceSubrange((central + 16)..<(central + 20), with: [0, 0, 0, 0])
        try bad.write(to: url)
        try rejects("错误 CRC 未被拒绝") { _ = try DocumentConversion.importDocument(from: url) }
        bad = valid
        bad.replaceSubrange((central + 24)..<(central + 28), with: [1, 0, 0, 0])
        try bad.write(to: url)
        try rejects("虚假解压长度未被拒绝") { _ = try DocumentConversion.importDocument(from: url) }
        bad = valid
        bad[30] = UInt8(ascii: "X")
        try bad.write(to: url)
        try rejects("本地头与中央目录名称不一致未被拒绝") { _ = try DocumentConversion.importDocument(from: url) }
        bad = valid
        bad[6] = 1
        try bad.write(to: url)
        try rejects("本地头独有的加密标志未被拒绝") { _ = try DocumentConversion.importDocument(from: url) }
        bad = valid
        bad[bad.count - 10] = 0
        bad[bad.count - 9] = 0
        try bad.write(to: url)
        try rejects("错误中央目录长度未被拒绝") { _ = try DocumentConversion.importDocument(from: url) }
        for length in [0, 4, 21, valid.count - 1] {
            try Data(valid.prefix(length)).write(to: url)
            try rejects("截断 ZIP 未被拒绝，长度 \(length)") { _ = try DocumentConversion.importDocument(from: url) }
        }
        // A tiny advertised size must never allocate the actual expanded payload.
        let bomb = try archive(Data(String(repeating: "a", count: 4_000_000).utf8), declaredSize: 16)
        try bomb.write(to: url)
        let start = Date()
        try rejects("超出声明大小的压缩内容未被拒绝") { _ = try DocumentConversion.importDocument(from: url) }
        try require(Date().timeIntervalSince(start) < 2, "错误大小归档拒绝耗时异常")
        // Check our independently built DEFLATE fixture with the OS implementation.
        try valid.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "测试 ZIP 本身无效")
    }

    static func testXML(_ directory: URL) throws {
        let url = directory.appendingPathComponent("input.docx")
        let badInputs = [
            "not XML",
            "<!DOCTYPE w:document [<!ENTITY x 'expanded'>]>" + xml("&x;"),
            bodyPrefix + String(repeating: "<x>", count: 160) + String(repeating: "</x>", count: 160) + bodySuffix,
            bodyPrefix + String(repeating: "<x/>", count: 100_001) + bodySuffix
        ]
        for (index, source) in badInputs.enumerated() {
            try archive(Data(source.utf8)).write(to: url)
            try rejects("不安全或过度复杂的 XML 未拒绝：\(index)") { _ = try DocumentConversion.importDocument(from: url) }
        }
        try archive(Data(("<!DOCTYPE w:document [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + xml("&x;")).utf8)).write(to: url)
        do {
            let external = try DocumentConversion.importDocument(from: url)
            try require(text(external).isEmpty, "外部实体不应被读取")
        } catch is DeskError { checks += 1 }
        try archive(Data(xml("&lt;正常&gt; &amp; &quot;引用&quot;").utf8)).write(to: url)
        try require(text(DocumentConversion.importDocument(from: url)) == "<正常> & \"引用\"", "预定义 XML 实体被错误禁止")
    }

    static func testPagination(_ directory: URL) throws {
        let value = String(repeating: "中英混排 Text 😀 café é。", count: 1400)
        let url = directory.appendingPathComponent("long.txt")
        try Data(value.utf8).write(to: url)
        let document = try DocumentConversion.importDocument(from: url)
        try require(document.pages.count > 5, "长文未分页")
        try require(text(document) == value, "分页边界丢失 Unicode 字符或文本顺序变化")
        for page in document.pages {
            try require(page.elements.allSatisfy { $0.rect.minY >= document.contentRect.minY && $0.rect.maxY <= document.contentRect.maxY + 0.01 }, "分页文字超出内容区域")
        }
        let blankPages = PaperDocument(pages: [PaperPage(), PaperPage(), PaperPage(elements: [.text("第三页")])])
        let docx = directory.appendingPathComponent("empty-pages.docx")
        try DocumentConversion.exportDOCX(blankPages, to: docx)
        let loaded = try DocumentConversion.importDocument(from: docx)
        try require(loaded.pages.count == 3 && loaded.pages[0].elements.isEmpty && loaded.pages[1].elements.isEmpty, "连续空白页被折叠")
        try require(text(loaded) == "第三页", "空白页之后正文丢失")
        let markdown = directory.appendingPathComponent("empty-pages.md")
        try DocumentConversion.exportMarkdown(blankPages, to: markdown)
        let md = try DocumentConversion.importDocument(from: markdown)
        try require(md.pages.count == 3 && text(md) == "第三页", "Markdown 连续分页标记丢失")
        try Data((String(repeating: "<!-- PaperDesk page break -->\n", count: 500) + "正文").utf8).write(to: markdown)
        try rejects("500 页限制未拒绝大量空白分页") { _ = try DocumentConversion.importDocument(from: markdown) }
    }

    static func testMarkdown(_ directory: URL) throws {
        let url = directory.appendingPathComponent("path.md")
        for target in ["../outside.png", "/etc/passwd", "https://example.com/a.png", "missing.png"] {
            try Data("![图片](\(target))".utf8).write(to: url)
            try rejects("不允许的 Markdown 图片路径未拒绝：\(target)") { _ = try DocumentConversion.importDocument(from: url) }
        }
        let fifo = directory.appendingPathComponent("named-pipe.png")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw ConversionFailure(description: "创建 FIFO 测试文件失败") }
        try Data("![图片](named-pipe.png)".utf8).write(to: url)
        try rejects("特殊文件必须在读取前拒绝，避免阻塞") { _ = try DocumentConversion.importDocument(from: url) }
        let specialDocument = directory.appendingPathComponent("named-pipe.txt")
        guard mkfifo(specialDocument.path, 0o600) == 0 else { throw ConversionFailure(description: "创建文本 FIFO 失败") }
        try rejects("特殊文档文件必须在读取前拒绝") { _ = try DocumentConversion.importDocument(from: specialDocument) }
        let destination = directory.appendingPathComponent("preserved.md")
        let original = Data("已有文档".utf8)
        try original.write(to: destination)
        var invalid = PaperDocument()
        invalid.pages = []
        try rejects("无效文档未阻止 Markdown 导出") { try DocumentConversion.exportMarkdown(invalid, to: destination) }
        try require(Data(contentsOf: destination) == original, "失败 Markdown 导出覆盖了原文档")
    }

    static func testUnicodeRTF(_ directory: URL) throws {
        let values = ["中文 👩‍💻 家庭 👨‍👩‍👧‍👦 é", "A 🇨🇳 🏳️‍🌈 👍🏽 👩🏻‍💻 Z",
                      "阿拉伯 ا‌ا‌ا ا‍ا Persian ZWNJ\u{200c} and ZWJ\u{200d}"]
        for value in values {
            let styled = NSMutableAttributedString(attributedString: TextStyle.make(value, size: 17, bold: true))
            styled.addAttributes([.foregroundColor: NSColor.red, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 0, length: styled.length))
            var item = PaperElement.text("")
            item.setText(styled)
            let restored = item.attributedText
            try require(restored.string == value, "RTF 往返丢失组合 emoji 或连接符：\(restored.string.debugDescription)")
            try require((restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 17, "字体回退改变原文字号")
            try require((restored.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue, "字体回退改变下划线")
            try require((restored.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)?.redComponent == 1, "字体回退改变颜色")
            try require(styled.string == value, "编码意外修改调用方文本")
            let project = directory.appendingPathComponent("unicode.paperdesk")
            let document = PaperDocument(pages: [PaperPage(elements: [item])])
            try ProjectStore.write(document, to: project)
            try require(text(ProjectStore.read(project)) == value, "工程重开丢失组合 emoji")
            let docx = directory.appendingPathComponent("unicode.docx")
            try DocumentConversion.exportDOCX(document, to: docx)
            try require(text(DocumentConversion.importDocument(from: docx)) == value, "DOCX 往返丢失组合 emoji")
        }
    }

    static func testWorker(_ directory: URL) throws {
        let done = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "PaperDesk.ConversionTest")
        final class ResultBox { var error: Error?; var text = "" }
        let result = ResultBox()
        queue.async {
            do {
                let markdown = directory.appendingPathComponent("worker.md")
                try Data("# 标题\n\n**bold** and *italic* 中文".utf8).write(to: markdown)
                let document = try DocumentConversion.importDocument(from: markdown)
                let output = directory.appendingPathComponent("worker.docx")
                try DocumentConversion.exportDOCX(document, to: output)
                result.text = text(try DocumentConversion.importDocument(from: output))
            } catch { result.error = error }
            done.signal()
        }
        try require(done.wait(timeout: .now() + 20) == .success, "工作线程转换卡住")
        if let error = result.error { throw error }
        try require(result.text == "标题bold and italic 中文", "工作线程转换丢失内容")
    }

    static func centralOffset(_ data: Data) -> Int {
        let index = data.count - 6
        return (0..<4).reduce(0) { $0 | Int(data[index + $1]) << ($1 * 8) }
    }
    static func archive(_ payload: Data, declaredSize: Int? = nil) throws -> Data {
        var compressed = Data(count: Int(compressBound(uLong(payload.count)))), stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ConversionFailure(description: "压缩 fixture 初始化失败")
        }
        defer { deflateEnd(&stream) }
        let status = compressed.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(payload.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw ConversionFailure(description: "压缩 fixture 失败") }
        compressed.count = Int(stream.total_out)
        let name = Data("word/document.xml".utf8)
        let checksum = payload.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count))) }
        var local = Data(), central = Data()
        let size = UInt32(declaredSize ?? payload.count)
        local.testLE32(0x04034b50); local.testLE16(20); local.testLE16(0); local.testLE16(8); local.testLE16(0); local.testLE16(33)
        local.testLE32(checksum); local.testLE32(UInt32(compressed.count)); local.testLE32(size); local.testLE16(UInt16(name.count)); local.testLE16(0)
        local.append(name); local.append(compressed)
        central.testLE32(0x02014b50); central.testLE16(20); central.testLE16(20); central.testLE16(0); central.testLE16(8)
        central.testLE16(0); central.testLE16(33); central.testLE32(checksum); central.testLE32(UInt32(compressed.count)); central.testLE32(size)
        central.testLE16(UInt16(name.count)); central.testLE16(0); central.testLE16(0); central.testLE16(0); central.testLE16(0)
        central.testLE32(0); central.testLE32(0); central.append(name)
        let offset = UInt32(local.count)
        local.append(central)
        local.testLE32(0x06054b50); local.testLE16(0); local.testLE16(0); local.testLE16(1); local.testLE16(1)
        local.testLE32(UInt32(central.count)); local.testLE32(offset); local.testLE16(0)
        return local
    }
}

private extension Data {
    mutating func testLE16(_ number: UInt16) { append(UInt8(number & 255)); append(UInt8(number >> 8)) }
    mutating func testLE32(_ number: UInt32) { testLE16(UInt16(number & 65535)); testLE16(UInt16(number >> 16)) }
}
