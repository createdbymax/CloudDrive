import SwiftUI
import AppKit
import Darwin
import CloudDriveCore

struct DriveEncryptionSetupView: View {
    @ObservedObject var drive: Drive
    @ObservedObject private var owner: NamespaceDriveController
    @State private var secret: DriveEncryptionSecret?
    @State private var kit: DriveRecoveryKit?
    @State private var saved = false
    @State private var acknowledged = false
    @State private var failure = ""
    init(drive: Drive) { self.drive = drive; owner = drive.namespaceEngine }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Encrypted managed drive", systemImage: "lock.shield").font(.headline)
            Text("Encrypt file contents and the cloud index before uploading. Local files and caches remain protected by your Mac’s security. R2 can still see object sizes and request timing. Use a new empty prefix; existing ordinary files are never converted.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Keep your recovery kit somewhere outside this drive. Anyone with that file can decrypt the drive. Losing both the saved Mac key and the kit makes the files unrecoverable.")
                .font(.callout).foregroundStyle(.secondary)
            if owner.encrypted {
                Label("Encryption selected for this connection", systemImage: "lock.fill")
                Button("Unlock saved encryption key") { Task { await owner.unlockEncryption() } }.disabled(owner.busy)
                Button("Restore saved key from kit…") { recoverKit() }.disabled(owner.busy)
                if !owner.hasSession && !owner.enabled {
                    Button("Continue encrypted setup") { Task { await owner.prepare(connection: drive.connection, mode: .managed, legacySafe: drive.canAdoptNamespace) } }.disabled(owner.busy || !drive.canAdoptNamespace)
                }
            }
            if !owner.ownsDestination && !owner.hasSession {
                HStack {
                    Button("Create recovery kit…") { createKit() }.disabled(owner.busy)
                    Button("Recover with a kit…") { recoverKit() }.disabled(owner.busy)
                }
                if kit != nil {
                    Button(saved ? "Save another recovery kit…" : "Save recovery kit…") { saveKit() }
                    Toggle("I saved the kit outside this drive and understand it is required if this Mac’s key is lost.", isOn: $acknowledged)
                    Button("Prepare new encrypted drive") { Task {
                        guard let secret, saved, acknowledged else { return }
                        await owner.prepareEncrypted(connection: drive.connection, secret: secret, recovering: false, legacySafe: drive.canAdoptNamespace)
                        if owner.error.isEmpty { self.secret = nil; kit = nil }
                    } }.disabled(!saved || !acknowledged || owner.busy || !drive.canAdoptNamespace)
                }
            }
            if !failure.isEmpty { Text(failure).foregroundStyle(.orange).font(.callout) }
        }
    }
    private func createKit() {
        do {
            let key = EncryptedDriveKey.generate()
            let id = EncryptedDriveKey.identifier(for: key)
            let generated = try EncryptedDriveRecoveryEnvelope.create(masterKey: key, keyID: id)
            secret = .init(keyID: id, key: key)
            kit = .init(version: 1, envelope: generated.envelope, recoveryKey: generated.recoveryKey)
            saved = false; acknowledged = false; failure = ""
        } catch { failure = "A secure recovery key could not be generated. Nothing was changed." }
    }
    private func saveKit() {
        guard let kit else { return }
        let panel = NSSavePanel(); panel.title = "Save private recovery kit"; panel.nameFieldStringValue = "CloudDrive Recovery.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let mount = owner.mountpoint.standardizedFileURL.path + "/"
            guard !url.resolvingSymlinksInPath().path.hasPrefix(mount) else { throw POSIXError(.EINVAL) }
            let bytes = try JSONEncoder().encode(kit)
            // Refuse replacement and symbolic-link targets. A failed save never
            // marks the recovery checkpoint complete.
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(.EEXIST) }
            defer { Darwin.close(fd) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try file.write(contentsOf: bytes); try file.synchronize()
            guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
            let verified = try JSONDecoder().decode(DriveRecoveryKit.self, from: Data(contentsOf: url)).secret()
            guard verified == secret else { throw POSIXError(.EIO) }
            let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(parent) }
            guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
            saved = true; failure = ""
        } catch { failure = "The recovery kit could not be verified. Choose a new file outside this drive and retry." }
    }
    private func recoverKit() {
        let panel = NSOpenPanel(); panel.title = "Choose private recovery kit"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 65_536 else { throw POSIXError(.EINVAL) }
            let recovered = try JSONDecoder().decode(DriveRecoveryKit.self, from: Data(contentsOf: url)).secret()
            Task {
                if owner.encrypted { await owner.restoreEncryptionKey(recovered) }
                else { await owner.prepareEncrypted(connection: drive.connection, secret: recovered, recovering: true, legacySafe: drive.canAdoptNamespace) }
            }
        } catch { failure = "This recovery kit could not be authenticated. The drive and saved key were not changed." }
    }
}
