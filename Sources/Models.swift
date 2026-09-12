import AppKit

let paperWidth: CGFloat = 595.275590551
let paperHeight: CGFloat = 841.88976378
let paperMargin: CGFloat = 42.52

struct CropRect: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    static let full = CropRect()
}

enum ElementKind: String, Codable { case text, image }

struct PaperElement: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ElementKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var textRTF: Data? = nil
    var imageData: Data? = nil
    var imageName: String? = nil
    var crop: CropRect = .full

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }
    var attributedText: NSAttributedString {
        guard let data = textRTF,
              let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return NSAttributedString(string: "") }
        return value
    }
    mutating func setText(_ value: NSAttributedString) {
        textRTF = try? value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    static func text(_ string: String, x: Double = 42.52, y: Double = 42.52, width: Double = 510.23, height: Double = 180, size: CGFloat = 14) -> PaperElement {
        var item = PaperElement(kind: .text, x: x, y: y, width: width, height: height)
        item.setText(TextStyle.make(string, size: size))
        return item
    }
}

struct PaperPage: Codable, Identifiable, Equatable {
    var id = UUID()
    var elements: [PaperElement] = []
}

/// Page margins are stored in points; canvas coordinates remain relative to the A4 sheet.
struct PageMargins: Codable, Equatable {
    var top: Double = paperMargin
    var bottom: Double = paperMargin
    var left: Double = paperMargin
    var right: Double = paperMargin

    static let minimumContentDimension: Double = 10 * 72 / 25.4

    var isValid: Bool {
        [top, bottom, left, right].allSatisfy { $0.isFinite && $0 >= 0 }
            && left + right <= paperWidth - Self.minimumContentDimension
            && top + bottom <= paperHeight - Self.minimumContentDimension
    }
}

struct PaperDocument: Codable, Equatable {
    var version = 1
    var title = "未命名作业"
    var pages: [PaperPage] = [PaperPage()]
    var zoom: Double = 1
    var pageGap: Double = 28
    var margins = PageMargins()

    var contentRect: CGRect {
        CGRect(x: margins.left, y: margins.top,
               width: paperWidth - margins.left - margins.right,
               height: paperHeight - margins.top - margins.bottom)
    }

    private enum CodingKeys: String, CodingKey { case version, title, pages, zoom, pageGap, margins }
}

extension PaperDocument {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        title = try values.decode(String.self, forKey: .title)
        pages = try values.decode([PaperPage].self, forKey: .pages)
        zoom = try values.decode(Double.self, forKey: .zoom)
        pageGap = try values.decode(Double.self, forKey: .pageGap)
        // Version 1 projects created before adjustable margins retain their 15 mm guides.
        margins = try values.decodeIfPresent(PageMargins.self, forKey: .margins) ?? PageMargins()
    }
}

enum DeskError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}

enum TextStyle {
    static func make(_ text: String, size: CGFloat = 14, bold: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        let font = NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
    }
}

enum ProjectStore {
    static func read(_ url: URL) throws -> PaperDocument {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 200_000_000 else { throw DeskError.message("工程超过 200 MB，请先压缩大图。") }
        let doc = try JSONDecoder().decode(PaperDocument.self, from: Data(contentsOf: url))
        try validate(doc)
        return doc
    }
    static func write(_ document: PaperDocument, to url: URL) throws {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= 200_000_000 else { throw DeskError.message("工程超过 200 MB，请减少图片或压缩后再保存。原文件未被覆盖。") }
        try data.write(to: url, options: .atomic)
    }
    static func validate(_ doc: PaperDocument) throws {
        guard doc.version == 1, !doc.pages.isEmpty, doc.pages.count <= 500,
              doc.zoom.isFinite, (0.25...3).contains(doc.zoom),
              doc.pageGap.isFinite, (0...120).contains(doc.pageGap) else {
            throw DeskError.message("工程版本或页面设置无效。")
        }
        guard doc.margins.isValid else {
            throw DeskError.message("页边距必须为有效的非负数，并且至少保留 10 × 10 mm 的页面内容区域。")
        }
        var ids = Set<UUID>()
        for page in doc.pages {
            guard ids.insert(page.id).inserted, page.elements.count <= 2000 else { throw DeskError.message("工程页面数据无效。") }
            for item in page.elements {
                let n = [item.x, item.y, item.width, item.height, item.crop.x, item.crop.y, item.crop.width, item.crop.height]
                guard ids.insert(item.id).inserted, n.allSatisfy({ $0.isFinite }), item.width > 0, item.height > 0,
                      item.width <= 10000, item.height <= 10000, abs(item.x) <= 10000, abs(item.y) <= 10000,
                      item.crop.x >= 0, item.crop.y >= 0, item.crop.width > 0, item.crop.height > 0,
                      item.crop.x + item.crop.width <= 1.00001, item.crop.y + item.crop.height <= 1.00001 else {
                    throw DeskError.message("工程内有无效坐标或裁剪区域。")
                }
                if item.kind == .image && item.imageData == nil { throw DeskError.message("工程图片资源缺失。") }
                if item.kind == .text {
                    guard let rtf = item.textRTF,
                          (try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil
                    else { throw DeskError.message("工程文字资源损坏。") }
                }
            }
        }
    }
}
