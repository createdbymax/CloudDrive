import Darwin
import Foundation

/// All destination operations are relative to pinned descriptors. Ejecting or replacing
/// the mount path can never redirect a copy into the ordinary directory below it.
enum MountedDrop {
    static func qualifiedWorker(versionResponse: Data) -> Bool? {
        struct Version: Decodable { let version: String }
        guard let info = try? JSONDecoder().decode(Version.self, from: versionResponse) else { return nil }
        return ["v1.75.2-clouddrive.8", "v1.75.2-clouddrive.9", "v1.75.2-clouddrive.10"].contains(info.version)
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func copy(_ urls: [URL], to mount: MountEntry) throws {
        let destination = open(mount.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw failure() }
        defer { close(destination) }
        var volume = statfs()
        guard fstatfs(destination, &volume) == 0 else { throw failure() }
        guard MountInspector.entry(volume) == mount, volume.f_flags & UInt32(MNT_RDONLY) == 0
        else { throw POSIXError(.ESTALE) }

        let allowsFolders = mount.type.lowercased() != "nfs"
        if !allowsFolders {
            // Reject a mixed Finder selection before writing any of its files.
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                      !url.path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw failure() }
                if info.st_mode & S_IFMT != S_IFREG { throw folderUnavailable }
            }
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try copyItem(url, into: destination, mountPath: mount.path, allowsFolders: allowsFolders) }
            catch {
                let reason: String
                switch (error as? POSIXError)?.code {
                case .EEXIST: reason = "An item already uses that name. Rename the incoming item, then try again."
                case .EXDEV: reason = "Choose a file or folder outside CloudDrive on one source volume."
                case .ESTALE: reason = "The source or drive changed during the copy. Check it in Finder and try again."
                default: reason = error.localizedDescription
                }
                throw NSError(domain: "CloudDrive.Drop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn’t copy “\(url.lastPathComponent)”. \(reason) Your originals are still in place. Check the drive for any items already copied."
                ])
            }
        }
    }

    static func copyItem(_ url: URL, into destination: Int32, mountPath: String, allowsFolders: Bool = true) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."),
              validName(url.lastPathComponent) else { throw POSIXError(.EINVAL) }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }

        var source = stat(), target = stat()
        guard fstatat(parent, url.lastPathComponent, &source, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(destination, &target) == 0 else { throw failure() }
        guard source.st_dev != target.st_dev else { throw POSIXError(.EXDEV) }
        // A dropped home folder or support directory can contain the mount itself.
        if source.st_mode & S_IFMT == S_IFDIR {
            guard allowsFolders else { throw folderUnavailable }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let mounted = URL(fileURLWithPath: mountPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
            guard mounted != path, !mounted.hasPrefix(path + "/") else { throw POSIXError(.EINVAL) }
        }
        // Both mounted backends can accept a named-fork write and then return no
        // bytes. Discover these before creating even the enclosing package.
        try preflight(name: url.lastPathComponent, from: parent, sourceDevice: source.st_dev)
        try copyEntry(name: url.lastPathComponent, from: parent, into: destination, sourceDevice: source.st_dev, allowsFolders: allowsFolders)
    }

    private static var folderUnavailable: NSError {
        NSError(domain: "CloudDrive.Drop", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Add Files accepts regular files on this drive. Use Open in Finder for folders, packages, or links and choose a new destination name."
        ])
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private static func checkResourceFork(_ fd: Int32) throws {
        let bytes = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
        if bytes > 0 {
            throw NSError(domain: "CloudDrive.Drop", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This item contains a Mac resource fork. Choose Compress in Finder, then add the ZIP archive to preserve it."
            ])
        }
        if bytes < 0, errno != ENOATTR, errno != ENOTSUP { throw failure() }
    }

    private static func forEachChild(_ folder: Int32, _ body: (String) throws -> Void) throws {
        let iterator = dup(folder)
        guard iterator >= 0 else { throw failure() }
        guard let stream = fdopendir(iterator) else { let error = failure(); close(iterator); throw error }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let record = readdir(stream) else {
                if errno != 0 { throw failure() }
                return
            }
            let child = withUnsafePointer(to: &record.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingUTF8: $0) }
            }
            guard let child else { throw POSIXError(.EILSEQ) }
            if child != "." && child != ".." { try body(child) }
        }
    }

    static func preflight(name: String, from parent: Int32, sourceDevice: dev_t) throws {
        guard validName(name) else { throw POSIXError(.EINVAL) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        guard info.st_dev == sourceDevice else { throw POSIXError(.EXDEV) }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK { return }
        guard kind == S_IFREG || kind == S_IFDIR else { throw POSIXError(.ENOTSUP) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var pinned = stat()
        guard fstat(descriptor, &pinned) == 0, pinned.st_dev == sourceDevice, pinned.st_ino == info.st_ino,
              pinned.st_mode & S_IFMT == kind else { throw POSIXError(.ESTALE) }
        try checkResourceFork(descriptor)
        if kind == S_IFDIR {
            try forEachChild(descriptor) { try preflight(name: $0, from: descriptor, sourceDevice: sourceDevice) }
        }
    }

    /// Exclusive creation also applies to every package member, including dotfiles.
    static func copyEntry(name: String, from parent: Int32, into destination: Int32, sourceDevice: dev_t, allowsFolders: Bool = true) throws {
        guard validName(name) else { throw POSIXError(.EINVAL) }
        var original = stat()
        guard fstatat(parent, name, &original, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        guard original.st_dev == sourceDevice else { throw POSIXError(.EXDEV) }

        let kind = original.st_mode & S_IFMT
        if !allowsFolders && kind != S_IFREG { throw folderUnavailable }
        if kind == S_IFLNK {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(parent, name, &buffer, buffer.count - 1)
            guard count >= 0, count < buffer.count - 1 else { throw failure() }
            guard symlinkat(buffer, destination, name) == 0 else { throw failure() }
            return
        }
        guard kind == S_IFREG || kind == S_IFDIR else { throw POSIXError(.ENOTSUP) }
        let source = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw failure() }
        defer { close(source) }
        var pinned = stat()
        guard fstat(source, &pinned) == 0, pinned.st_dev == original.st_dev,
              pinned.st_ino == original.st_ino, pinned.st_mode & S_IFMT == kind else { throw POSIXError(.ESTALE) }

        try checkResourceFork(source)
        if kind == S_IFREG {
            let file = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw failure() }
            let result = fcopyfile(source, file, nil, copyfile_flags_t(COPYFILE_ALL))
            let copyError = result == 0 ? nil : failure()
            let closed = close(file)
            if let copyError { throw copyError }
            guard closed == 0 else { throw failure() }
            return
        }

        guard mkdirat(destination, name, 0o700) == 0 else { throw failure() }
        let folder = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure() }
        defer { close(folder) }
        try forEachChild(source) { child in
            try copyEntry(name: child, from: source, into: folder, sourceDevice: sourceDevice)
        }
        guard fcopyfile(source, folder, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw failure() }
    }
}
