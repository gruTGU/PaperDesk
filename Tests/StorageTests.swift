import AppKit

@main
enum StorageTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("paperdesk-storage-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let locations = StorageLocations(supportDirectory: root.appendingPathComponent("Support/PaperDesk"), cacheDirectory: root.appendingPathComponent("Caches/PaperDesk"))
        try fm.createDirectory(at: locations.recoveryDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: locations.cacheDirectory.appendingPathComponent("previews"), withIntermediateDirectories: true)
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { print("FAIL \(label)"); exit(1) }
            passed += 1; print("PASS \(label)")
        }
        func write(_ url: URL, count: Int) throws { try Data(repeating: 65, count: count).write(to: url) }
        let active = locations.recoveryDirectory.appendingPathComponent("active.paperdesk")
        let old = locations.recoveryDirectory.appendingPathComponent("old.paperdesk")
        let legacy = locations.supportDirectory.appendingPathComponent("Recovery-legacy.paperdesk")
        let unrelated = locations.supportDirectory.appendingPathComponent("MyAssignment.paperdesk")
        let outside = root.appendingPathComponent("saved-by-user.paperdesk")
        try write(active, count: 11); try write(old, count: 12); try write(legacy, count: 13)
        try write(unrelated, count: 14); try write(outside, count: 15)
        try write(locations.cacheDirectory.appendingPathComponent("preview.bin"), count: 20)
        try write(locations.cacheDirectory.appendingPathComponent("previews/nested.bin"), count: 30)
        let cacheLink = locations.cacheDirectory.appendingPathComponent("user-file-link")
        let folderLink = locations.cacheDirectory.appendingPathComponent("previews/folder-link")
        let recoveryLink = locations.recoveryDirectory.appendingPathComponent("linked.paperdesk")
        try fm.createSymbolicLink(at: cacheLink, withDestinationURL: outside)
        try fm.createSymbolicLink(at: folderLink, withDestinationURL: root)
        try fm.createSymbolicLink(at: recoveryLink, withDestinationURL: outside)
        let inventory = try StorageManager.inventory(locations: locations, activeRecoveryURLs: [active])
        check(inventory.filter { $0.kind == .cache }.reduce(0) { $0 + $1.bytes } == 50, "disk bytes exclude linked files and avoid link cycles")
        check(inventory.filter { $0.kind == .recovery }.count == 3, "new and legacy recoveries are listed")
        check(inventory.filter { $0.isProtected }.compactMap { $0.url?.resolvingSymlinksInPath() } == [active.resolvingSymlinksInPath()], "active recovery is labelled protected")
        check(!inventory.contains { $0.url == unrelated || $0.url == outside || $0.url == recoveryLink }, "user files and symbolic links excluded from recovery inventory")
        do {
            _ = try StorageManager.deleteRecoveries([old, active], activeRecoveryURLs: [active], locations: locations)
            check(false, "active recovery deletion rejected")
        } catch StorageError.protectedRecovery {
            check(fm.fileExists(atPath: old.path) && fm.fileExists(atPath: active.path), "selection validated before any recovery deletion")
        }
        for unsafe in [outside, unrelated, recoveryLink, locations.recoveryDirectory.appendingPathComponent("../../saved-by-user.paperdesk")] {
            do {
                _ = try StorageManager.deleteRecoveries([unsafe], activeRecoveryURLs: [], locations: locations)
                check(false, "unsafe recovery path rejected")
            } catch StorageError.unsafeLocation { check(true, "arbitrary, traversal, and symbolic-link recovery paths rejected") }
        }
        let cleared = try StorageManager.clearDiskCache(locations: locations)
        check(cleared.filesRemoved == 2 && cleared.bytesRemoved == 50 && cleared.skipped == 2, "only app cache files removed with accurate totals")
        check(fm.fileExists(atPath: outside.path) && fm.fileExists(atPath: unrelated.path), "saved user documents survive cache cleanup")
        check(fm.fileExists(atPath: active.path) && fm.fileExists(atPath: old.path), "cache cleanup preserves recovery backups")
        check((try? fm.destinationOfSymbolicLink(atPath: cacheLink.path)) != nil, "symbolic links preserved without following targets")
        let removed = try StorageManager.deleteRecoveries([old, legacy, old], activeRecoveryURLs: [active], locations: locations)
        check(removed.filesRemoved == 2 && removed.bytesRemoved == 25, "selected stale recoveries removed once with accurate totals")
        check(fm.fileExists(atPath: active.path) && fm.fileExists(atPath: outside.path), "active recovery and saved user project retained")
        let outsideDirectory = root.appendingPathComponent("UserFiles")
        try fm.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let userBackup = outsideDirectory.appendingPathComponent("private.paperdesk")
        try write(userBackup, count: 8)
        let alternate = StorageLocations(supportDirectory: root.appendingPathComponent("AlternateSupport"), cacheDirectory: root.appendingPathComponent("CacheSymlink"))
        try fm.createSymbolicLink(at: alternate.cacheDirectory, withDestinationURL: outsideDirectory)
        do {
            _ = try StorageManager.clearDiskCache(locations: alternate)
            check(false, "linked cache root rejected")
        } catch StorageError.unsafeLocation { check(fm.fileExists(atPath: userBackup.path), "cache directory symlink cannot expose user folder to cleanup") }
        let linkedSupport = StorageLocations(supportDirectory: root.appendingPathComponent("SupportSymlink"), cacheDirectory: root.appendingPathComponent("UnusedCache"))
        try fm.createSymbolicLink(at: linkedSupport.supportDirectory, withDestinationURL: outsideDirectory)
        do {
            _ = try StorageManager.recoveryFiles(locations: linkedSupport)
            check(false, "linked support root rejected")
        } catch StorageError.unsafeLocation { check(true, "support directory symlink is rejected") }
        let missing = StorageLocations(supportDirectory: root.appendingPathComponent("MissingSupport"), cacheDirectory: root.appendingPathComponent("MissingCache"))
        let missingInventory = try StorageManager.inventory(locations: missing)
        let missingCleanup = try StorageManager.clearDiskCache(locations: missing)
        check(missingInventory.isEmpty && missingCleanup.filesRemoved == 0, "missing application folders require no creation or cleanup")
        print("PASS \(passed) storage checks; all data isolated in a temporary directory")
    }
}
