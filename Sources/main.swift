import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceController()
    var pendingFiles: [String] = []
    var launched = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = PaperDeskAppearance.applicationIcon() {
            NSApp.applicationIconImage = icon
        }
        launched = true
        let paths = pendingFiles + CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if workspace.editors.isEmpty { workspace.create() }
        if paths.isEmpty { DispatchQueue.main.async { [weak self] in self?.workspace.offerRecoveries() } }
        else { workspace.activeEditor?.openDocuments(paths.map { URL(fileURLWithPath: $0) }, completion: { [weak self] _ in self?.workspace.offerRecoveries() }) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspace.isTerminating { return .terminateLater }
        guard workspace.mayTerminate() else { return .terminateCancel }
        workspace.finishRecoveryCleanup { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !workspace.isTerminating else { sender.reply(toOpenOrPrint: .failure); return }
        guard launched else { pendingFiles.append(contentsOf: filenames); sender.reply(toOpenOrPrint: .success); return }
        let editor = workspace.activeEditor.flatMap { $0.exporting ? nil : $0 } ?? workspace.create()
        editor.openDocuments(filenames.map { URL(fileURLWithPath: $0) }, completion: { success in sender.reply(toOpenOrPrint: success ? .success : .failure) })
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !workspace.isTerminating else { return false }
        if workspace.editors.isEmpty { workspace.create() }
        else { workspace.activeEditor?.window.makeKeyAndOrderFront(nil) }
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
