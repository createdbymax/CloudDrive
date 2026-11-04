import SwiftUI

struct ConnectionFields: View {
    @ObservedObject var drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("R2 S3 endpoint") { TextField("R2 S3 endpoint", text: $drive.connection.endpoint, prompt: Text("https://ACCOUNT.r2.cloudflarestorage.com")).labelsHidden() }
            LabeledContent("Bucket") { TextField("Bucket", text: $drive.connection.bucket).labelsHidden() }
            LabeledContent("Dedicated prefix") { TextField("Dedicated prefix", text: $drive.connection.prefix).labelsHidden() }
            LabeledContent("Access key ID") { SecureField("Access key ID", text: $drive.connection.accessKey).labelsHidden() }
            LabeledContent("Secret access key") { SecureField("Secret access key", text: $drive.connection.secretKey).labelsHidden() }
        }.textFieldStyle(.roundedBorder).disabled(!drive.canConnect)
    }
}

struct SetupView: View {
    @ObservedObject var drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Set up your R2 drive", systemImage: "externaldrive.badge.icloud").font(.title.bold())
            Text("Connect your own Cloudflare R2 bucket and browse it in Finder. Files stay ordinary objects in your dedicated prefix.")
            ConnectionFields(drive: drive)
            Text("Keys are stored in this Mac’s Keychain. Use one actively writing Mac and keep originals until you have checked your connection.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Save and Connect") { Task { await drive.start() } }.buttonStyle(.borderedProminent).disabled(!drive.canConnect)
                Button("Load Saved Connection") { Task { await drive.loadSavedConnection() } }.disabled(drive.busy || drive.running)
            }
            OperationFeedback(drive: drive)
            RecoveryActions(drive: drive)
        }
    }
}

struct RecoveryActions: View {
    @ObservedObject var drive: Drive
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if drive.keychainNeedsApproval {
                Label("Saved connection needs authorization", systemImage: "lock").font(.headline)
                Text("Automatic recovery does not open Keychain prompts. Load explicitly, then respond to macOS if asked.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Load Saved Connection") { Task { await drive.loadSavedConnection() } }.disabled(drive.busy || drive.running)
                Button("Retry Recovery") { Task { await drive.recover() } }.disabled(drive.busy)
            }
        }
    }
}

struct RecoveryView: View {
    @ObservedObject var drive: Drive
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Recovery", systemImage: "cross.case").font(.title2.bold())
                Text(drive.presentation.title).font(.headline)
                Text(drive.uploadStatus).font(.callout)
                RecoveryActions(drive: drive)
                OperationFeedback(drive: drive)
                Text("Do not delete the local cache to resolve a problem. Pending uploads may exist even when status is unavailable. Close open files before ejecting; CloudDrive will not force an unmount.").font(.callout).foregroundStyle(.secondary)
                Button("Eject safely") { Task { await drive.eject() } }.disabled(!drive.canEject)
                Text("Deleted-file and overwritten-file restoration is not available yet.").font(.callout).foregroundStyle(.secondary)
                RecentActivityView(drive: drive)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
