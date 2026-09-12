import AppKit

/// Conversion is deliberately a reading-order interchange, while the project and PDF keep canvas geometry.
enum DocumentConversion {
    static func importDocument(from url: URL) throws -> PaperDocument {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 80_000_000 else { throw DeskError.message("导入文件超过 80 MB，请先减小文件。") }
        let blocks: [FlowBlock]
        var margins = PageMargins()
        switch url.pathExtension.lowercased() {
        case "docx":
            let imported = try readDOCX(url)
            blocks = imported.blocks; margins = imported.margins
        case "md", "markdown":
            blocks = try readMarkdown(String(contentsOf: url, encoding: .utf8), base: url.deletingLastPathComponent())
        case "txt": blocks = [.text(TextStyle.make(try String(contentsOf: url, encoding: .utf8)))]
        default: throw DeskError.message("文档导入支持 DOCX、Markdown 和 UTF-8 TXT。PDF 仅支持导出。")
        }
        var document = try paginate(blocks, margins: margins)
        document.title = url.deletingPathExtension().lastPathComponent
        return document
    }

    static func exportDOCX(_ document: PaperDocument, to url: URL) throws {
        try ProjectStore.validate(document)
        var body = ""
        var entries: [(String, Data)] = []
        var relationships = ""
        var imageNumber = 0
        for (pageIndex, page) in document.pages.enumerated() {
            for element in readingOrder(page) {
                switch element.kind {
                case .text:
                    for paragraph in paragraphs(element.attributedText) { body += wordParagraph(paragraph) }
                case .image:
                    imageNumber += 1
                    let data = try pngData(element)
                    let name = "image\(imageNumber).png"
                    entries.append(("word/media/\(name)", data))
                    relationships += "<Relationship Id=\"rId\(imageNumber)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                    let scale = min(1, document.contentRect.width / element.width, document.contentRect.height / element.height)
                    let cx = Int(element.width * scale * 12700), cy = Int(element.height * scale * 12700)
                    body += """
                    <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(imageNumber)" name="\(xml(element.imageName ?? name))"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(imageNumber)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId\(imageNumber)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                    """
                }
            }
            if pageIndex < document.pages.count - 1 { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
        }
        let margins = document.margins
        // Quantize down by less than one twip so the minimum content area remains valid.
        body += "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"\(Int(margins.top * 20))\" w:right=\"\(Int(margins.right * 20))\" w:bottom=\"\(Int(margins.bottom * 20))\" w:left=\"\(Int(margins.left * 20))\" w:header=\"425\" w:footer=\"425\" w:gutter=\"0\"/></w:sectPr>"
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """
        entries.append(("word/document.xml", Data(documentXML.utf8)))
        entries.append(("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>".utf8)))
        entries.append(("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)))
        entries.append(("[Content_Types].xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".utf8)))
        try StoredZIP.write(entries).write(to: url, options: .atomic)
    }

    static func exportMarkdown(_ document: PaperDocument, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let assetName = "\(url.deletingPathExtension().lastPathComponent)-assets-\(UUID().uuidString.lowercased())"
        let assetURL = parent.appendingPathComponent(assetName, isDirectory: true)
        var assetCreated = false, lines: [String] = [], number = 0
        do {
            for (pageIndex, page) in document.pages.enumerated() {
                if pageIndex > 0 { lines.append("<!-- PaperDesk page break -->") }
                for element in readingOrder(page) {
                    if element.kind == .text {
                        for paragraph in paragraphs(element.attributedText) {
                            lines.append(markdownParagraph(paragraph))
                        }
                    } else {
                        if !assetCreated {
                            try FileManager.default.createDirectory(at: assetURL, withIntermediateDirectories: false)
                            assetCreated = true
                        }
                        number += 1
                        let name = "image-\(number).png"
                        try pngData(element).write(to: assetURL.appendingPathComponent(name), options: .atomic)
                        let target = "\(assetName)/\(name)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()#?"))) ?? "\(assetName)/\(name)"
                        let label = (element.imageName ?? "图片 \(number)").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
                        lines.append("![\(label)](\(target))")
                    }
                }
            }
            try Data((lines.joined(separator: "\n\n") + "\n").utf8).write(to: url, options: .atomic)
        } catch {
            if assetCreated { try? FileManager.default.removeItem(at: assetURL) }
            throw error
        }
    }

    private enum FlowBlock { case text(NSAttributedString), image(PaperElement), pageBreak }
    private static func readingOrder(_ page: PaperPage) -> [PaperElement] {
        page.elements.enumerated().sorted { a, b in
            if a.element.y != b.element.y { return a.element.y < b.element.y }
            if a.element.x != b.element.x { return a.element.x < b.element.x }
            return a.offset < b.offset
        }.map(\.element)
    }
    private static func pngData(_ element: PaperElement) throws -> Data {
        try ImageTools.encode(ImageTools.displayedImage(for: element), format: .png, quality: 0.9)
    }
    private static func paragraphs(_ text: NSAttributedString) -> [NSAttributedString] {
        guard text.length > 0 else { return [text] }
        let string = text.string as NSString
        var result: [NSAttributedString] = [], start = 0
        while start < string.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            var end = NSMaxRange(range)
            while end > range.location && [10, 13, 0x2029].contains(Int(string.character(at: end - 1))) { end -= 1 }
            result.append(text.attributedSubstring(from: NSRange(location: range.location, length: end - range.location)))
            start = NSMaxRange(range)
        }
        return result
    }

    private static func paginate(_ blocks: [FlowBlock], margins: PageMargins = PageMargins()) throws -> PaperDocument {
        var document = PaperDocument(margins: margins)
        try ProjectStore.validate(document)
        let content = document.contentRect
        var y = content.minY
        let width = content.width, bottom = content.maxY
        func newPage() throws {
            guard document.pages.count < 500 else { throw DeskError.message("文档超过 500 页，请拆分后导入。") }
            if !document.pages[document.pages.count - 1].elements.isEmpty { document.pages.append(PaperPage()) }
            y = content.minY
        }
        for block in blocks {
            switch block {
            case .pageBreak: try newPage()
            case .image(var item):
                let maximumHeight = content.height
                let scale = min(1, width / CGFloat(item.width), maximumHeight / CGFloat(item.height))
                item.width *= scale; item.height *= scale
                if y + item.height > bottom { try newPage() }
                item.x = content.minX; item.y = y
                document.pages[document.pages.count - 1].elements.append(item)
                y += item.height + 12
            case .text(let text):
                guard text.length <= 2_000_000 else { throw DeskError.message("文字内容过长，请拆分导入。") }
                if text.length == 0 { y += 12; continue }
                var offset = 0
                while offset < text.length {
                    if bottom - y < 28 { try newPage() }
                    let remainder = text.attributedSubstring(from: NSRange(location: offset, length: text.length - offset))
                    let storage = NSTextStorage(attributedString: remainder)
                    let layout = NSLayoutManager()
                    let container = NSTextContainer(size: NSSize(width: width, height: bottom - y - 4))
                    container.lineFragmentPadding = 0
                    layout.addTextContainer(container); storage.addLayoutManager(layout)
                    let glyphs = layout.glyphRange(for: container)
                    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    if characters.length == 0 {
                        if y > content.minY { try newPage(); continue }
                        throw DeskError.message("文字字号或行高大于一页可用区域，请先减小源文档字号。")
                    }
                    let height = min(bottom - y, max(20, ceil(layout.usedRect(for: container).height) + 4))
                    var item = PaperElement(kind: .text, x: content.minX, y: y, width: width, height: height)
                    item.setText(remainder.attributedSubstring(from: characters))
                    document.pages[document.pages.count - 1].elements.append(item)
                    offset += characters.length; y += height + 6
                    if offset < text.length { try newPage() }
                }
            }
        }
        try ProjectStore.validate(document)
        return document
    }

    private static func readMarkdown(_ source: String, base: URL) throws -> [FlowBlock] {
        guard source.utf8.count <= 12_000_000 else { throw DeskError.message("Markdown 文字超过 12 MB，请拆分导入。") }
        var result: [FlowBlock] = [], paragraph: [String] = [], inCode = false, code: [String] = []
        func flush() throws {
            if !paragraph.isEmpty {
                try appendMarkdownParagraph(paragraph.joined(separator: "\n"), base: base, to: &result)
                paragraph.removeAll()
            }
        }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                try flush()
                if inCode {
                    let value = NSMutableAttributedString(attributedString: TextStyle.make(code.joined(separator: "\n"), size: 12))
                    value.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: value.length))
                    result.append(.text(value)); code.removeAll()
                }
                inCode.toggle(); continue
            }
            if inCode { code.append(raw); continue }
            if line == "<!-- PaperDesk page break -->" { try flush(); result.append(.pageBreak); continue }
            if line.isEmpty { try flush(); continue }
            if line.range(of: "^(#{1,6} +|[-*+] +|[0-9]+[.)] +|!\\[)", options: .regularExpression) != nil {
                try flush(); try appendMarkdownParagraph(line, base: base, to: &result)
            } else { paragraph.append(raw) }
        }
        try flush()
        if inCode { result.append(.text(TextStyle.make(code.joined(separator: "\n"), size: 12))) }
        return result
    }
    private static func appendMarkdownParagraph(_ original: String, base: URL, to blocks: inout [FlowBlock]) throws {
        var content = original, size: CGFloat = 14, bold = false
        if let range = content.range(of: "^#{1,6} +", options: .regularExpression) {
            let count = content[range].filter { $0 == "#" }.count
            size = [26, 22, 18, 16, 15, 14][count - 1]; bold = true; content.removeSubrange(range)
        } else if let range = content.range(of: "^[-*+] +", options: .regularExpression) {
            content.replaceSubrange(range, with: "• ")
        }
        let regex = try NSRegularExpression(pattern: #"!\[((?:\\.|[^\]])*)\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\s*\)"#)
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        var position = 0
        for match in matches {
            if match.range.location > position {
                let part = ns.substring(with: NSRange(location: position, length: match.range.location - position))
                if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(try styledMarkdown(part, size: size, bold: bold))) }
            }
            var path = ns.substring(with: match.range(at: 2))
            if path.hasPrefix("<") && path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
            guard let decoded = path.removingPercentEncoding, !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\"), !decoded.contains("\0") else {
                throw DeskError.message("Markdown 图片仅支持文档目录内的相对路径：\(path)")
            }
            let root = base.standardizedFileURL.resolvingSymlinksInPath()
            let imageURL = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
            guard imageURL.path.hasPrefix(root.path + "/") else { throw DeskError.message("Markdown 图片不能引用文档目录之外的文件：\(path)") }
            guard FileManager.default.fileExists(atPath: imageURL.path) else { throw DeskError.message("Markdown 图片不存在：\(path)") }
            let fileSize = (try imageURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard fileSize <= 80_000_000 else { throw DeskError.message("Markdown 图片超过 80 MB：\(path)") }
            blocks.append(.image(try imageElement(Data(contentsOf: imageURL), name: imageURL.lastPathComponent)))
            position = NSMaxRange(match.range)
        }
        if position < ns.length || matches.isEmpty {
            let part = ns.substring(from: position)
            if !part.isEmpty { blocks.append(.text(try styledMarkdown(part, size: size, bold: bold))) }
        }
    }
    private static func styledMarkdown(_ markdown: String, size: CGFloat, bold: Bool) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let value = NSMutableAttributedString(attributedString: TextStyle.make(String(parsed[run.range].characters), size: size, bold: bold))
            let intent = run.inlinePresentationIntent ?? []
            var font = value.length > 0 ? value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
            if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
            if let current = font {
                var traits = NSFontManager.shared.traits(of: current)
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                value.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: traits), range: NSRange(location: 0, length: value.length))
            }
            if let link = run.link { value.addAttribute(.link, value: link, range: NSRange(location: 0, length: value.length)) }
            result.append(value)
        }
        return result
    }
    private static func markdownParagraph(_ text: NSAttributedString) -> String {
        if text.length == 0 { return "" }
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let isBold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        let level = isBold ? ((font?.pointSize ?? 14) >= 24 ? 1 : (font?.pointSize ?? 14) >= 20 ? 2 : (font?.pointSize ?? 14) >= 17 ? 3 : 0) : 0
        var output = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let raw = (text.string as NSString).substring(with: range)
            let leading = String(raw.prefix(while: { $0.isWhitespace })), trailing = String(raw.reversed().prefix(while: { $0.isWhitespace }).reversed())
            let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if core.isEmpty { output += raw; return }
            var content = markdownEscape(core)
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.italicFontMask) { content = "*\(content)*" }
            if traits.contains(.boldFontMask) && level == 0 { content = "**\(content)**" }
            if let link = attrs[.link] { content = "[\(content)](\(String(describing: link).replacingOccurrences(of: ")", with: "%29")))" }
            output += leading + content + trailing
        }
        if output.hasPrefix("• ") { output = "- " + output.dropFirst(2) }
        if level > 0 { output = String(repeating: "#", count: level) + " " + output }
        return output
    }
    private static func markdownEscape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        for token in ["*", "_", "[", "]", "`", "#", "<", ">"] { result = result.replacingOccurrences(of: token, with: "\\" + token) }
        return result
    }

    private static func wordParagraph(_ text: NSAttributedString) -> String {
        let paragraph = text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        let alignment: String
        switch paragraph?.alignment { case .center: alignment = "center"; case .right: alignment = "right"; case .justified: alignment = "both"; default: alignment = "left" }
        let before = Int((paragraph?.paragraphSpacingBefore ?? 0) * 20), after = Int((paragraph?.paragraphSpacing ?? 8) * 20)
        var result = "<w:p><w:pPr><w:jc w:val=\"\(alignment)\"/><w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/></w:pPr>"
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            let traits = NSFontManager.shared.traits(of: font)
            var properties = "<w:rFonts w:ascii=\"\(xml(font.familyName ?? font.fontName))\" w:hAnsi=\"\(xml(font.familyName ?? font.fontName))\" w:eastAsia=\"\(xml(font.familyName ?? font.fontName))\"/><w:sz w:val=\"\(Int(font.pointSize * 2))\"/><w:szCs w:val=\"\(Int(font.pointSize * 2))\"/>"
            if traits.contains(.boldFontMask) { properties += "<w:b/>" }
            if traits.contains(.italicFontMask) { properties += "<w:i/>" }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }
            if let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                properties += String(format: "<w:color w:val=\"%02X%02X%02X\"/>", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            }
            let raw = (text.string as NSString).substring(with: range)
            let content = raw.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(xml($0))</w:t>" }.joined(separator: "<w:tab/>")
            result += "<w:r><w:rPr>\(properties)</w:rPr>\(content)</w:r>"
        }
        return result + "</w:p>"
    }
    private static func xml(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func imageElement(_ data: Data, name: String, width: CGFloat? = nil, height: CGFloat? = nil) throws -> PaperElement {
        var item = PaperElement(kind: .image, x: paperMargin, y: paperMargin, width: 300, height: 200, imageData: data, imageName: name)
        let image = try ImageTools.displayedImage(for: item)
        let w = width ?? CGFloat(image.width), h = height ?? CGFloat(image.height)
        guard w > 0, h > 0, w.isFinite, h.isFinite else { throw DeskError.message("图片尺寸无效：\(name)") }
        // Pagination applies the imported document's margins after reading its section settings.
        item.width = w; item.height = h
        return item
    }

    private struct WordFormat {
        var name: String?; var size: CGFloat?; var bold: Bool?; var italic: Bool?; var underline: Bool?; var color: NSColor?; var alignment: NSTextAlignment?
        mutating func apply(_ node: XMLNode?) {
            guard let node else { return }
            let r = node.name == "rPr" ? node : node.child("rPr")
            let p = node.name == "pPr" ? node : node.child("pPr")
            if let fonts = r?.child("rFonts") { name = fonts.attributes["eastAsia"] ?? fonts.attributes["ascii"] ?? name }
            if let raw = r?.child("sz")?.attributes["val"], let number = Double(raw), number > 0 { size = min(200, CGFloat(number) / 2) }
            if let b = r?.child("b") { bold = !["0", "false", "off"].contains(b.attributes["val"] ?? "1") }
            if let i = r?.child("i") { italic = !["0", "false", "off"].contains(i.attributes["val"] ?? "1") }
            if let u = r?.child("u") { underline = !["none", "0", "false"].contains(u.attributes["val"] ?? "single") }
            if let hex = r?.child("color")?.attributes["val"], hex.count == 6, let value = UInt32(hex, radix: 16) {
                color = NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
            }
            if let value = p?.child("jc")?.attributes["val"] { alignment = ["center": .center, "right": .right, "both": .justified, "left": .left][value] ?? .left }
        }
        func attributes() -> [NSAttributedString.Key: Any] {
            var font = NSFont(name: name ?? "PingFangSC-Regular", size: size ?? 14) ?? NSFont.systemFont(ofSize: size ?? 14)
            if bold == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let p = NSMutableParagraphStyle(); p.lineSpacing = 4; p.paragraphSpacing = 8; p.alignment = alignment ?? .left
            var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? NSColor.black, .paragraphStyle: p]
            if underline == true { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            return result
        }
    }
    private static func readDOCX(_ url: URL) throws -> (blocks: [FlowBlock], margins: PageMargins) {
        let archive = try ReadZIP(url)
        let root = try parseXML(archive.read("word/document.xml"))
        var relations: [String: XMLNode] = [:]
        if archive.contains("word/_rels/document.xml.rels") {
            let relRoot = try parseXML(archive.read("word/_rels/document.xml.rels"))
            for node in relRoot.children { if let id = node.attributes["Id"] { relations[id] = node } }
        }
        var styles: [String: XMLNode] = [:], defaultFormat = WordFormat()
        if archive.contains("word/styles.xml") {
            let styleRoot = try parseXML(archive.read("word/styles.xml"))
            defaultFormat.apply(styleRoot.child("docDefaults")?.child("rPrDefault"))
            for node in styleRoot.children where node.name == "style" { if let id = node.attributes["styleId"] { styles[id] = node } }
        }
        func format(_ id: String?, depth: Int = 0) -> WordFormat {
            guard let id, let style = styles[id], depth < 12 else { return defaultFormat }
            var value = format(style.child("basedOn")?.attributes["val"], depth: depth + 1)
            value.apply(style); return value
        }
        var numbering: [String: String] = [:], numbers: [String: Int] = [:]
        if archive.contains("word/numbering.xml") {
            let numRoot = try parseXML(archive.read("word/numbering.xml"))
            var abstract: [String: String] = [:]
            for n in numRoot.children where n.name == "abstractNum" {
                if let id = n.attributes["abstractNumId"] { abstract[id] = n.firstDescendant("numFmt")?.attributes["val"] ?? "decimal" }
            }
            for n in numRoot.children where n.name == "num" {
                if let id = n.attributes["numId"], let aid = n.child("abstractNumId")?.attributes["val"] { numbering[id] = abstract[aid] ?? "decimal" }
            }
        }
        guard let body = root.child("body") else { throw DeskError.message("DOCX 缺少正文。") }
        var margins = PageMargins()
        if let attributes = body.child("sectPr")?.child("pgMar")?.attributes {
            func points(_ edge: String, default value: Double) throws -> Double {
                guard let raw = attributes[edge] else { return value }
                guard let number = Double(raw), number.isFinite else { throw DeskError.message("DOCX 页边距无效。") }
                return number / 20
            }
            margins = try PageMargins(top: points("top", default: margins.top),
                                      bottom: points("bottom", default: margins.bottom),
                                      left: points("left", default: margins.left),
                                      right: points("right", default: margins.right))
            guard margins.isValid else { throw DeskError.message("DOCX 页边距超出 A4 可用区域，请在 Word 中调整后导入。") }
        }
        var blocks: [FlowBlock] = []
        for paragraph in body.descendants("p") {
            let properties = paragraph.child("pPr")
            var paragraphFormat = format(properties?.child("pStyle")?.attributes["val"])
            paragraphFormat.apply(properties)
            var text = NSMutableAttributedString(string: "")
            func flushText() { if text.length > 0 { blocks.append(.text(text)); text = NSMutableAttributedString(string: "") } }
            if let numId = properties?.child("numPr")?.child("numId")?.attributes["val"], numId != "0" {
                numbers[numId, default: 0] += 1
                text.append(NSAttributedString(string: numbering[numId] == "bullet" ? "• " : "\(numbers[numId]!)" + ". ", attributes: paragraphFormat.attributes()))
            }
            for run in paragraph.descendants("r") {
                var current = paragraphFormat
                if let id = run.child("rPr")?.child("rStyle")?.attributes["val"], let style = styles[id] { current.apply(style) }
                current.apply(run)
                for part in run.children {
                    switch part.name {
                    case "t": text.append(NSAttributedString(string: part.text, attributes: current.attributes()))
                    case "tab": text.append(NSAttributedString(string: "\t", attributes: current.attributes()))
                    case "br":
                        if part.attributes["type"] == "page" { flushText(); blocks.append(.pageBreak) }
                        else { text.append(NSAttributedString(string: "\n", attributes: current.attributes())) }
                    case "drawing", "pict":
                        let embed = part.firstDescendant("blip")?.attributes["embed"] ?? part.firstDescendant("imagedata")?.attributes["id"]
                        guard let id = embed, let relation = relations[id], let target = relation.attributes["Target"] else {
                            throw DeskError.message("DOCX 含无法读取的图片引用。请在 Word 中嵌入图片后再导入。")
                        }
                        guard relation.attributes["TargetMode"] != "External" else { throw DeskError.message("DOCX 含外部链接图片，请先在 Word 中嵌入图片。") }
                        let path = try archivePath(target, relativeTo: "word")
                        let extent = part.firstDescendant("extent")
                        let width = extent?.attributes["cx"].flatMap(Double.init).map { CGFloat($0) / 12700 }
                        let height = extent?.attributes["cy"].flatMap(Double.init).map { CGFloat($0) / 12700 }
                        var image = try imageElement(archive.read(path), name: (path as NSString).lastPathComponent, width: width, height: height)
                        if let crop = part.firstDescendant("srcRect") {
                            let left = Double(crop.attributes["l"] ?? "0") ?? 0, top = Double(crop.attributes["t"] ?? "0") ?? 0
                            let right = Double(crop.attributes["r"] ?? "0") ?? 0, bottom = Double(crop.attributes["b"] ?? "0") ?? 0
                            if left >= 0, top >= 0, right >= 0, bottom >= 0, left + right < 100000, top + bottom < 100000 {
                                image.crop = CropRect(x: left / 100000, y: top / 100000, width: 1 - (left + right) / 100000, height: 1 - (top + bottom) / 100000)
                            }
                        }
                        flushText(); blocks.append(.image(image))
                    default: break
                    }
                }
            }
            flushText()
        }
        return (blocks, margins)
    }
    private static func archivePath(_ target: String, relativeTo base: String) throws -> String {
        guard let decoded = target.removingPercentEncoding, !decoded.contains(":"), !decoded.contains("\\"), !decoded.contains("\0") else { throw DeskError.message("DOCX 图片路径无效。") }
        var components = decoded.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !components.isEmpty else { throw DeskError.message("DOCX 图片路径越界。") }; components.removeLast() }
            else { components.append(String(part)) }
        }
        return components.joined(separator: "/")
    }
    private static func parseXML(_ data: Data) throws -> XMLNode {
        guard data.count <= 12_000_000 else { throw DeskError.message("DOCX XML 过大，请拆分导入。") }
        let parser = XMLParser(data: data), delegate = XMLTreeBuilder()
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw DeskError.message("DOCX XML 已损坏，无法导入。") }
        return root
    }
}

private final class XMLNode {
    let name: String, attributes: [String: String]
    var children: [XMLNode] = [], text = ""
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func firstDescendant(_ name: String) -> XMLNode? { for node in children { if node.name == name { return node }; if let found = node.firstDescendant(name) { return found } }; return nil }
    func descendants(_ name: String) -> [XMLNode] { children.flatMap { $0.name == name ? [$0] : $0.descendants(name) } }
}
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?, stack: [XMLNode] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        var attrs: [String: String] = [:]
        for (key, value) in attributeDict { attrs[String(key.split(separator: ":").last ?? Substring(key))] = value }
        let node = XMLNode(name: String(elementName.split(separator: ":").last ?? Substring(elementName)), attributes: attrs)
        if let parent = stack.last { parent.children.append(node) } else { root = node }; stack.append(node)
        if stack.count > 150 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
}

/// Store-only ZIP output keeps this app dependency-free. PNG payloads are already compressed.
private enum StoredZIP {
    static func write(_ entries: [(String, Data)]) -> Data {
        var output = Data(), central = Data()
        for (name, data) in entries {
            let filename = Data(name.utf8), crc = checksum(data), offset = UInt32(output.count), size = UInt32(data.count)
            output.le32(0x04034b50); output.le16(20); output.le16(0x0800); output.le16(0); output.le16(0); output.le16(33); output.le32(crc); output.le32(size); output.le32(size); output.le16(UInt16(filename.count)); output.le16(0); output.append(filename); output.append(data)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0); central.le16(0); central.le16(33); central.le32(crc); central.le32(size); central.le32(size); central.le16(UInt16(filename.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(offset); central.append(filename)
        }
        let offset = UInt32(output.count); output.append(central)
        output.le32(0x06054b50); output.le16(0); output.le16(0); output.le16(UInt16(entries.count)); output.le16(UInt16(entries.count)); output.le32(UInt32(central.count)); output.le32(offset); output.le16(0)
        return output
    }
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        return crc ^ 0xffffffff
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 65535)); le16(UInt16(value >> 16)) }
    func u16(_ offset: Int) -> Int { Int(self[offset]) | Int(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
}
private struct ReadZIP {
    struct Entry { let method: Int, size: Int, compressed: Int, offset: Int, crc: UInt32 }
    let url: URL, data: Data
    var entries: [String: Entry] = [:]
    init(_ url: URL) throws {
        self.url = url; data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw DeskError.message("DOCX 不是有效的 ZIP 文档。") }
        var end: Int?
        for position in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if data.u32(position) == 0x06054b50 && position + 22 + data.u16(position + 20) == data.count { end = position; break }
        }
        guard let end, data.u16(end + 4) == 0, data.u16(end + 6) == 0, data.u16(end + 10) < 5000 else { throw DeskError.message("不支持此 DOCX 压缩结构。请用 Word 另存为普通 DOCX。") }
        var position = data.u32(end + 16), total = 0
        for _ in 0..<data.u16(end + 10) {
            guard position >= 0, position + 46 <= data.count, data.u32(position) == 0x02014b50 else { throw DeskError.message("DOCX 目录结构已损坏。") }
            let nameCount = data.u16(position + 28), extra = data.u16(position + 30), comment = data.u16(position + 32)
            guard position + 46 + nameCount + extra + comment <= data.count, data.u16(position + 8) & 1 == 0 else { throw DeskError.message("DOCX 已加密或损坏，请先解密后导入。") }
            guard let name = String(data: data.subdata(in: position + 46..<position + 46 + nameCount), encoding: .utf8), entries[name] == nil else { throw DeskError.message("DOCX 存在无效或重复的资源名称。") }
            let size = data.u32(position + 24), compressed = data.u32(position + 20), offset = data.u32(position + 42)
            total += size
            guard size <= 100_000_000, total <= 200_000_000 else { throw DeskError.message("DOCX 解压后内容过大，请压缩图片或拆分文件。") }
            entries[name] = Entry(method: data.u16(position + 10), size: size, compressed: compressed, offset: offset, crc: UInt32(data.u32(position + 16)))
            position += 46 + nameCount + extra + comment
        }
    }
    func contains(_ name: String) -> Bool { entries[name] != nil }
    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw DeskError.message("DOCX 缺少资源：\(name)") }
        let offset = entry.offset
        guard offset >= 0, offset + 30 <= data.count, data.u32(offset) == 0x04034b50 else { throw DeskError.message("DOCX 资源结构已损坏。") }
        let start = offset + 30 + data.u16(offset + 26) + data.u16(offset + 28)
        guard start + entry.compressed <= data.count else { throw DeskError.message("DOCX 资源内容不完整。") }
        if entry.method == 0 {
            let value = data.subdata(in: start..<start + entry.compressed)
            guard value.count == entry.size, StoredZIP.checksum(value) == entry.crc else { throw DeskError.message("DOCX 资源校验失败。") }
            return value
        }
        guard entry.method == 8 else { throw DeskError.message("DOCX 使用了不支持的压缩方式，请在 Word 中重新另存为 DOCX。") }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip accepts filename patterns: quote their metacharacters, without invoking a shell.
        let pattern = name.map { c -> String in switch c { case "[": return "[[]"; case "?": return "[?]"; case "*": return "[*]"; default: return String(c) } }.joined()
        process.arguments = ["-p", url.path, pattern]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var result = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            result.append(chunk)
            if result.count > entry.size { process.terminate(); process.waitUntilExit(); throw DeskError.message("DOCX 资源大小与目录不一致。") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, result.count == entry.size, StoredZIP.checksum(result) == entry.crc else { throw DeskError.message("DOCX 资源解压或校验失败。") }
        return result
    }
}
