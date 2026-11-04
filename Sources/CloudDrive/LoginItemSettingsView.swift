import SwiftUI
import ServiceManagement

/// System registration is authoritative; no separate UserDefaults flag can drift from it.
@MainActor final class LoginItemSettings: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?

    var requested: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer {
            refresh()
            busy = false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Couldn’t change Open at Login. \(error.localizedDescription)"
        }
    }
}

struct LoginItemSettingsView: View {
    @StateObject private var loginItem = LoginItemSettings()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open at Login", isOn: Binding(
                get: { loginItem.requested },
                set: { enabled in Task { await loginItem.setEnabled(enabled) } }
            ))
            .disabled(loginItem.busy)
            Text("Start CloudDrive automatically when you sign in to your Mac.")
                .font(.callout).foregroundStyle(.secondary)
            if loginItem.status == .requiresApproval {
                Text("Allow CloudDrive in macOS Login Items to finish enabling Open at Login.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if loginItem.status == .notFound {
                Text("macOS couldn’t find this app’s login item. Move CloudDrive to Applications and try again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = loginItem.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .onAppear { loginItem.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loginItem.refresh() }
        }
    }
}
