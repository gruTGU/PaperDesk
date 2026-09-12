import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var title: String {
        switch self {
        case .png: return "PNG（保留透明）"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC / HEIF"
        }
    }
    fileprivate var identifier: CFString {
        switch self {
        case .png: return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        }
    }
}

struct ImageExportResult {
    let data: Data
    let width: Int
    let height: Int
    let quality: Double
    let resized: Bool
}

enum ImageTools {
    private static let maximumPixels = 100_000_000
    private static let maximumInputBytes = 200_000_000

    /// ImageIO applies EXIF rotation/mirroring; returned pixels always have upright orientation.
    static func decode(_ data: Data) throws -> CGImage {
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw DeskError.message("图片为空或超过 200 MB，请先缩小图片。")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw DeskError.message("无法读取图片，请使用有效的 PNG、JPG 或 HEIF 图片。")
        }
        // HEIF containers may put their main photograph at an index other than zero.
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard index < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw DeskError.message("无法读取图片，请使用有效的 PNG、JPG 或 HEIF 图片。")
        }
        try validateDimensions(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw DeskError.message("图片解码失败，文件可能损坏或格式不受系统支持。")
        }
        try validateDimensions(image.width, image.height)
        return image
    }

    /// Normalized crop coordinates use the top-left corner of the upright image.
    static func crop(_ image: CGImage, to rect: CropRect) throws -> CGImage {
        let values = [rect.x, rect.y, rect.width, rect.height]
        guard values.allSatisfy({ $0.isFinite }), rect.x >= 0, rect.y >= 0,
              rect.width > 0, rect.height > 0,
              rect.x + rect.width <= 1.00001, rect.y + rect.height <= 1.00001 else {
            throw DeskError.message("裁剪范围无效，请在图片内部选择区域。")
        }
        if rect == .full { return image }
        let left = min(image.width - 1, Int(floor(rect.x * Double(image.width))))
        let top = min(image.height - 1, Int(floor(rect.y * Double(image.height))))
        let right = min(image.width, max(left + 1, Int(ceil((rect.x + rect.width) * Double(image.width)))))
        let bottom = min(image.height, max(top + 1, Int(ceil((rect.y + rect.height) * Double(image.height)))))
        guard let result = image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else {
            throw DeskError.message("无法裁剪图片。")
        }
        return result
    }

    static func displayedImage(for element: PaperElement) throws -> CGImage {
        guard element.kind == .image, let data = element.imageData else {
            throw DeskError.message("未选择图片，或图片资源缺失。")
        }
        return try crop(decode(data), to: element.crop)
    }

    static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.9) throws -> Data {
        try validateDimensions(image.width, image.height)
        guard quality.isFinite else { throw DeskError.message("图片质量数值无效。") }
        let available = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard available.contains(format.identifier as String) else {
            throw DeskError.message("当前系统不支持导出 \(format.title)，请选择 PNG 或 JPEG。")
        }
        // Use standard 8-bit sRGB output. PNG retains alpha; lossy formats use a white backdrop.
        let pixels = try rasterize(image, width: image.width, height: image.height, opaque: format != .png)
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, format.identifier, 1, nil) else {
            throw DeskError.message("无法创建图片编码器。")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality)),
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), buffer.length > 0 else {
            throw DeskError.message("\(format.title) 编码失败，请尝试其他格式。")
        }
        return buffer as Data
    }

    /// Meets the actual byte limit or throws. Lossy output first lowers quality, then dimensions.
    static func export(_ image: CGImage, format: ImageFormat, maxBytes: Int? = nil) throws -> ImageExportResult {
        try validateDimensions(image.width, image.height)
        if let limit = maxBytes, limit <= 0 { throw DeskError.message("目标大小必须大于 0。") }
        let initialQuality = format == .png ? 1.0 : 0.92
        guard let limit = maxBytes else {
            return ImageExportResult(data: try encode(image, format: format, quality: initialQuality),
                                     width: image.width, height: image.height, quality: initialQuality, resized: false)
        }
        var width = image.width
        var height = image.height
        for _ in 0..<48 {
            let current = width == image.width && height == image.height
                ? image : try rasterize(image, width: width, height: height, opaque: format != .png)
            let highData = try encode(current, format: format, quality: initialQuality)
            if highData.count <= limit {
                return result(highData, image: current, original: image, quality: initialQuality)
            }
            var smallestData = highData
            if format != .png {
                let minimumQuality = 0.08
                let lowData = try encode(current, format: format, quality: minimumQuality)
                smallestData = lowData
                if lowData.count <= limit {
                    var bestData = lowData
                    var bestQuality = minimumQuality
                    var low = minimumQuality
                    var high = initialQuality
                    // Keep only measured candidates under the limit; encoders can be non-monotonic.
                    for _ in 0..<8 {
                        let midpoint = (low + high) / 2
                        let candidate = try encode(current, format: format, quality: midpoint)
                        if candidate.count <= limit {
                            bestData = candidate
                            bestQuality = midpoint
                            low = midpoint
                        } else {
                            high = midpoint
                        }
                    }
                    return result(bestData, image: current, original: image, quality: bestQuality)
                }
            }
            guard width > 1 || height > 1 else { break }
            let factor = min(0.85, max(0.25, sqrt(Double(limit) / Double(smallestData.count)) * 0.93))
            width = max(1, Int(floor(Double(width) * factor)))
            height = max(1, Int(floor(Double(height) * factor)))
        }
        throw DeskError.message("目标大小太小：即使缩至最小尺寸，\(format.title) 仍无法满足。请提高目标大小或更换格式。")
    }

    static func rotateClockwise(_ image: CGImage) throws -> CGImage {
        let context = try bitmapContext(width: image.height, height: image.width, opaque: false)
        context.translateBy(x: 0, y: CGFloat(image.width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw DeskError.message("图片旋转失败。") }
        return result
    }

    private static func result(_ data: Data, image: CGImage, original: CGImage, quality: Double) -> ImageExportResult {
        ImageExportResult(data: data, width: image.width, height: image.height, quality: quality,
                          resized: image.width != original.width || image.height != original.height)
    }

    private static func validateDimensions(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= maximumPixels / height else {
            throw DeskError.message("图片尺寸无效或超过 1 亿像素，请先缩小图片。")
        }
    }

    private static func bitmapContext(width: Int, height: Int, opaque: Bool) throws -> CGContext {
        try validateDimensions(width, height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | alpha.rawValue) else {
            throw DeskError.message("无法分配图片处理内存，请缩小图片后重试。")
        }
        context.interpolationQuality = .high
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }

    private static func rasterize(_ image: CGImage, width: Int, height: Int, opaque: Bool) throws -> CGImage {
        let context = try bitmapContext(width: width, height: height, opaque: opaque)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw DeskError.message("图片缩放失败。") }
        return result
    }
}
