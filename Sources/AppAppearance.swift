import AppKit

/// Main-thread UI resources. Return a fresh NSImage instead of sharing mutable AppKit
/// image instances with document/export workers.
enum PaperDeskAppearance {
    static func applicationIcon() -> NSImage? {
        let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        // Test executables live in build/, beside the source tree's Resources/ folder.
        let besideTests = Bundle.main.executableURL?.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png")
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.png")
        for url in [bundled, besideTests, workingDirectory].compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PaperDesk")
    }

    static func alert() -> NSAlert {
        let alert = NSAlert()
        // Explicitly set the icon: programmatic alerts may otherwise use the generic
        // application icon even when the Dock and window header are already correct.
        if let icon = applicationIcon() { alert.icon = icon }
        return alert
    }
}

/// System-tinted buttons can force white text even on a pale bezel. Draw the
/// current-page marker explicitly so its contrast is stable in active windows.
final class PageNavigationButton: NSButton {
    var isCurrentPage = false
    override func draw(_ dirtyRect: NSRect) {
        guard isCurrentPage else { super.draw(dirtyRect); return }
        let rect = bounds.insetBy(dx: 1, dy: 2)
        let background = isHighlighted
            ? NSColor(srgbRed: 0.78, green: 0.88, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.86, green: 0.94, blue: 0.96, alpha: 1)
        background.setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.12, green: 0.18, blue: 0.22, alpha: isEnabled ? 1 : 0.5)
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
