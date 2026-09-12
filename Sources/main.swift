import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceController()
    var pendingFiles: [String] = []
    var launched = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        let paths = pendingFiles + CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        var errors: [Error] = []
        for path in paths {
            do { try workspace.open(URL(fileURLWithPath: path), from: workspace.activeEditor) }
            catch { errors.append(error) }
        }
        if workspace.editors.isEmpty { workspace.create() }
        if let error = errors.first { workspace.activeEditor?.showError(error) }
        DispatchQueue.main.async { [weak self] in self?.workspace.offerRecoveries() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace.mayTerminate() ? .terminateNow : .terminateCancel
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard launched else { pendingFiles.append(contentsOf: filenames); sender.reply(toOpenOrPrint: .success); return }
        var success = true
        for filename in filenames {
            do { try workspace.open(URL(fileURLWithPath: filename), from: workspace.activeEditor) }
            catch { success = false; workspace.activeEditor?.showError(error) }
        }
        sender.reply(toOpenOrPrint: success ? .success : .failure)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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
