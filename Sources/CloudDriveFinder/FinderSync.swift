import Cocoa
import FinderSync
import CloudDriveCore
import Darwin
import OSLog

/// The sandboxed Finder extension never reads credentials or owner descriptors.
/// It forwards a scoped selection to the app for confirmation and authenticated IO.
final class FinderSync: FIFinderSync {
    private let mountpoint: URL
    private let legacyMountpoint: URL
    private let badgeQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility; return queue
    }()
    // Accessed only on the main queue. A blocked filesystem can consume at most
    // two workers and 64 queued requests; no private owner files are consulted.
    private var badgeRequests: [String: UUID] = [:]
    private var outstandingBadgeReads = 0
    override init() {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? ""
        mountpoint = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support/BucketDrive/Instant Drive", isDirectory: true)
        legacyMountpoint = mountpoint.deletingLastPathComponent().appendingPathComponent("Drive", isDirectory: true)
        super.init()
        for (id, symbol, label) in [("remoteOnly", "icloud", "Online only"),
                                    ("downloading", "arrow.down.circle", "Downloading"),
                                    ("availableOffline", "checkmark.circle.fill", "Available offline"),
                                    ("attention", "exclamationmark.circle", "Needs attention")] {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                FIFinderSyncController.default().setBadgeImage(image, label: label, forBadgeIdentifier: id)
            }
        }
        FIFinderSyncController.default().directoryURLs = home.isEmpty ? [] : [mountpoint, legacyMountpoint]
    }
    override func requestBadgeIdentifier(for url: URL) {
        DispatchQueue.main.async { [weak self] in self?.requestBadge(url) }
    }
    private func requestBadge(_ url: URL) {
        let controller = FIFinderSyncController.default()
        controller.setBadgeIdentifier("", for: url)
        guard url.isFileURL, let request = try? FinderActionRequest(action: .keepDownloaded, paths: [url.path]),
              (try? request.relativeSelections(under: mountpoint)) != nil,
              outstandingBadgeReads < 64 else { return }
        let token = UUID(), path = url.path, mount = mountpoint.path
        let requestedAt = ProcessInfo.processInfo.systemUptime
        badgeRequests[path] = token; outstandingBadgeReads += 1
        // Expiry clears even when the filesystem read never returns. A later
        // Finder request gets a new token and cannot be overwritten by this one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.badgeRequests[path] == token else { return }
            self.badgeRequests.removeValue(forKey: path)
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
        badgeQueue.addOperation { [weak self] in
            let badge = Self.readAvailability(path: path, mount: mount)
            DispatchQueue.main.async {
                guard let self else { return }
                self.outstandingBadgeReads -= 1
                guard FinderBadgeEvidence.accepts(current: self.badgeRequests[path], completed: token,
                    requestedAt: requestedAt, now: ProcessInfo.processInfo.systemUptime) else { return }
                FIFinderSyncController.default().setBadgeIdentifier(badge ?? "", for: url)
            }
        }
    }
    private static func readAvailability(path: String, mount: String) -> String? {
        // O_EVTONLY avoids reading or hydrating file contents. NOFOLLOW rejects
        // a selected symlink; fstatfs binds the opened item to the native mount.
        guard nativeMountIsPresent(mount) else { return nil }
        let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var item = stat()
        guard fstat(fd, &item) == 0, item.st_mode & S_IFMT != S_IFLNK else { return nil }
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return nil }
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let mountedAt = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard ["clouddrive", "fskit"].contains(type.lowercased()), mountedAt == mount else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { fgetxattr(fd, "com.clouddrive.availability", $0.baseAddress, $0.count, 0, 0) }
        guard count > 0, count <= 64 else { return nil }
        return FinderBadgeEvidence.identifier(bytes: Array(bytes.prefix(count)))
    }
    private func ownedFilesystemIsPresent() -> Bool { Self.nativeMountIsPresent(mountpoint.path) }
    private static func nativeMountIsPresent(_ mount: String, legacy: Bool = false) -> Bool {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count >= 0, count < 4096 else { return false }
        var records: [statfs] = Array(repeating: statfs(), count: Int(count) + 16)
        let actual = records.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard actual >= 0, actual < records.count else { return false }
        return records.prefix(Int(actual)).contains { record in
            var value = record
            let type = withUnsafePointer(to: &value.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let mountedAt = withUnsafePointer(to: &value.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard mountedAt == mount else { return false }
            if legacy {
                let source = withUnsafePointer(to: &value.f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                return type.lowercased() == "nfs" && source == "127.0.0.1:/"
            }
            return ["clouddrive", "fskit"].contains(type.lowercased())
        }
    }
    private static let actionsLog = Logger(subsystem: "local.bucketdrive.app.finder", category: "actions")

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "CloudDrive")
        if actionRequest(.move) != nil {
            menu.addItem(withTitle: "Move to Folder…", action: #selector(moveSelection(_:)), keyEquivalent: "").target = self
            return menu
        }
        guard ownedFilesystemIsPresent() else { return nil }
        if actionRequest(.keepDownloaded) != nil {
            menu.addItem(withTitle: "Keep Downloaded…", action: #selector(keepDownloaded(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Free Up Local Space…", action: #selector(freeSpace(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Show CloudDrive Activity", action: #selector(showActivity(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func keepDownloaded(_ sender: Any?) { forward(.keepDownloaded) }
    @objc private func freeSpace(_ sender: Any?) { forward(.freeSpace) }
    @objc private func moveSelection(_ sender: Any?) { forward(.move) }
    @objc private func showActivity(_ sender: Any?) { forward(.activity) }

    // Finder creates its own menu items. Ask the controller for the current
    // selection inside the action, where Finder guarantees it is available.
    private func actionRequest(_ action: FinderActionRequest.Action) -> FinderActionRequest? {
        if action == .activity {
            return ownedFilesystemIsPresent() ? try? FinderActionRequest(action: .activity) : nil
        }
        guard let selection = FIFinderSyncController.default().selectedItemURLs(),
              !selection.isEmpty, selection.allSatisfy(\.isFileURL),
              let request = try? FinderActionRequest(action: action, paths: selection.map(\.path))
        else { return nil }
        let legacy = action == .move
        let root = legacy ? legacyMountpoint : mountpoint
        guard (try? request.relativeSelections(under: root)) != nil,
              Self.nativeMountIsPresent(root.path, legacy: legacy) else { return nil }
        return request
    }

    private func forward(_ action: FinderActionRequest.Action) {
        guard let url = actionRequest(action)?.url else {
            Self.actionsLog.notice("Ignored Finder action with unavailable selection or mount")
            return
        }
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard host.pathExtension == "app" else { return }
        NSWorkspace.shared.open([url], withApplicationAt: host, configuration: .init()) { _, error in
            if let error {
                Self.actionsLog.error("Finder action delivery failed (code \((error as NSError).code, privacy: .public))")
            } else {
                Self.actionsLog.info("Finder action delivered")
            }
        }
    }
}

/// Strict parsing and monotonic freshness; unknown never means available offline.
enum FinderBadgeEvidence {
    static func identifier(bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.count <= 64,
              let value = String(bytes: bytes, encoding: .utf8),
              ["remoteOnly", "downloading", "availableOffline", "attention"].contains(value) else { return nil }
        return value
    }
    static func accepts(current: UUID?, completed: UUID, requestedAt: TimeInterval, now: TimeInterval) -> Bool {
        current == completed && now >= requestedAt && now - requestedAt < 5
    }
}
