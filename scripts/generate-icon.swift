import AppKit
import CoreGraphics

// Original PaperDesk icon. Geometry uses a 1024 × 1024 design space, then renders
// at each native icon size so Dock/Finder never depend on a flattened screenshot.
// To change the artwork, edit these paths/colors and run generate-icon.sh.
struct IconPainter {
    let context: CGContext

    func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    func fill(_ path: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
        context.addPath(path); context.setFillColor(color(hex, alpha: alpha)); context.fillPath()
    }
    func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ hex: UInt32) {
        fill(rounded(CGRect(x: x, y: y, width: width, height: height), radius: height / 2), hex)
    }
    func polygon(_ points: [CGPoint], _ hex: UInt32) {
        guard let first = points.first else { return }
        let path = CGMutablePath(); path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
        fill(path, hex)
    }
    func gradient(_ path: CGPath, colors: [UInt32], start: CGPoint, end: CGPoint) {
        context.saveGState(); defer { context.restoreGState() }
        context.addPath(path); context.clip()
        let values = colors.map { color($0) } as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: values, locations: nil)!
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    func draw() {
        // The outer 10% is transparent, matching the visual footprint of macOS icons.
        let tile = rounded(CGRect(x: 96, y: 96, width: 832, height: 832), radius: 184)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 26, color: color(0x063653, alpha: 0.24))
        fill(tile, 0x0875AA)
        context.restoreGState()
        gradient(tile, colors: [0x1261B0, 0x087FBB, 0x1CC5CC],
                 start: CGPoint(x: 215, y: 115), end: CGPoint(x: 830, y: 920))
        context.saveGState()
        context.addPath(tile); context.clip()
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x76F2EE, alpha: 0.33), color(0x76F2EE, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 840, y: 260), startRadius: 0,
                                   endCenter: CGPoint(x: 840, y: 260), endRadius: 570, options: [])
        context.restoreGState()

        // A second sheet creates the multi-page/document cue without tiny lettering.
        context.saveGState()
        context.translateBy(x: 494, y: 512); context.rotate(by: -0.105)
        let backSheet = rounded(CGRect(x: -236, y: -287, width: 448, height: 570), radius: 36)
        context.setShadow(offset: CGSize(width: 1, height: -12), blur: 20, color: color(0x073E71, alpha: 0.2))
        fill(backSheet, 0xB9EBF7)
        context.restoreGState()

        let paper = CGMutablePath()
        paper.move(to: CGPoint(x: 334, y: 211))
        paper.addLine(to: CGPoint(x: 624, y: 211))
        paper.addLine(to: CGPoint(x: 737, y: 324))
        paper.addLine(to: CGPoint(x: 737, y: 774))
        paper.addQuadCurve(to: CGPoint(x: 701, y: 810), control: CGPoint(x: 737, y: 810))
        paper.addLine(to: CGPoint(x: 334, y: 810))
        paper.addQuadCurve(to: CGPoint(x: 298, y: 774), control: CGPoint(x: 298, y: 810))
        paper.addLine(to: CGPoint(x: 298, y: 247))
        paper.addQuadCurve(to: CGPoint(x: 334, y: 211), control: CGPoint(x: 298, y: 211))
        paper.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -16), blur: 25, color: color(0x004C80, alpha: 0.24))
        fill(paper, 0xFFFFFF)
        context.restoreGState()
        gradient(paper, colors: [0xFFFFFF, 0xF5FBFE], start: CGPoint(x: 330, y: 230), end: CGPoint(x: 710, y: 810))
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: 624, y: 211)); fold.addLine(to: CGPoint(x: 624, y: 296))
        fold.addQuadCurve(to: CGPoint(x: 652, y: 324), control: CGPoint(x: 624, y: 324))
        fold.addLine(to: CGPoint(x: 737, y: 324)); fold.closeSubpath()
        gradient(fold, colors: [0xD2EAF6, 0xE9F6FC], start: CGPoint(x: 626, y: 320), end: CGPoint(x: 700, y: 250))

        bar(342, 308, 191, 23, 0x245D87)
        bar(342, 351, 240, 12, 0x9DBED2)
        let picture = rounded(CGRect(x: 342, y: 404, width: 309, height: 202), radius: 22)
        gradient(picture, colors: [0xD2F2F8, 0xAFDCEB], start: CGPoint(x: 342, y: 404), end: CGPoint(x: 650, y: 606))
        context.saveGState()
        context.addPath(picture); context.clip()
        context.setFillColor(color(0xFFFFFF, alpha: 0.95))
        context.fillEllipse(in: CGRect(x: 565, y: 436, width: 39, height: 39))
        polygon([CGPoint(x: 420, y: 606), CGPoint(x: 548, y: 475), CGPoint(x: 691, y: 606)], 0x5AACC4)
        polygon([CGPoint(x: 320, y: 606), CGPoint(x: 436, y: 459), CGPoint(x: 572, y: 606)], 0x237EAA)
        polygon([CGPoint(x: 436, y: 459), CGPoint(x: 405, y: 498), CGPoint(x: 432, y: 493), CGPoint(x: 455, y: 506), CGPoint(x: 475, y: 501)], 0xF2FCFF)
        context.restoreGState()
        bar(342, 649, 274, 14, 0xA5C1D3)
        bar(342, 682, 225, 14, 0xB9D0DE)
        bar(342, 715, 160, 14, 0xB9D0DE)

        // Gold editing pencil: a single bold silhouette stays recognizable at 16/32 px.
        context.saveGState()
        context.translateBy(x: 584, y: 835); context.rotate(by: -0.935)
        let pencil = CGMutablePath()
        pencil.move(to: CGPoint(x: 0, y: 0)); pencil.addLine(to: CGPoint(x: 54, y: -35))
        pencil.addLine(to: CGPoint(x: 332, y: -35))
        pencil.addQuadCurve(to: CGPoint(x: 356, y: -11), control: CGPoint(x: 356, y: -35))
        pencil.addLine(to: CGPoint(x: 356, y: 11))
        pencil.addQuadCurve(to: CGPoint(x: 332, y: 35), control: CGPoint(x: 356, y: 35))
        pencil.addLine(to: CGPoint(x: 54, y: 35)); pencil.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 6, height: -9), blur: 14, color: color(0x194F72, alpha: 0.28))
        fill(pencil, 0xF5AD3B)
        context.restoreGState()
        context.saveGState()
        context.addPath(pencil); context.clip()
        gradient(pencil, colors: [0xFFD57B, 0xFFBE48, 0xF79A26], start: CGPoint(x: 150, y: -35), end: CGPoint(x: 150, y: 35))
        context.setFillColor(color(0xFFFFFF, alpha: 0.38)); context.fill(CGRect(x: 57, y: -26, width: 241, height: 8))
        context.setFillColor(color(0xD68024)); context.fill(CGRect(x: 298, y: -35, width: 15, height: 70))
        context.setFillColor(color(0xF8DFB7)); context.fill(CGRect(x: 0, y: -36, width: 56, height: 72))
        polygon([CGPoint(x: 0, y: 0), CGPoint(x: 21, y: -14), CGPoint(x: 21, y: 14)], 0x245574)
        context.restoreGState()
        context.restoreGState()
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in entries {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create \(size)px drawing context")
    }
    context.setAllowsAntialiasing(true)
    context.translateBy(x: 0, y: CGFloat(size))
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: -scale)
    IconPainter(context: context).draw()
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode \(name)")
    }
    try png.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}
print("Rendered 10 icon variants (16–1024 px).")
