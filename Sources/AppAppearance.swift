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
