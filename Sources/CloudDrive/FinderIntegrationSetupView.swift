import SwiftUI
import ServiceManagement
import AppKit

struct FinderIntegrationPresentation: Equatable {
    enum State { case unsupportedSystem, componentMissing, activationUnconfirmed, connected }
    let state: State
    init(supportedSystem: Bool, componentPresent: Bool, mounted: Bool) {
        if mounted { state = .connected }
        else if !supportedSystem { state = .unsupportedSystem }
        else if !componentPresent { state = .componentMissing }
        else { state = .activationUnconfirmed }
    }
    var title: String {
        switch state {
        case .unsupportedSystem: return "File management needs macOS 26 or later"
        case .componentMissing: return "Finder component is missing from this build"
        case .activationUnconfirmed: return "Enable Finder integration in System Settings"
        case .connected: return "Finder integration is connected"
        }
    }
    var detail: String {
        switch state {
        case .unsupportedSystem: return "Use a supported macOS version for the new file-management drive. Existing legacy connections are separate."
        case .componentMissing: return "Install CloudDrive in Applications using a build that includes its signed filesystem extension and provisioning profile. A settings switch cannot add a missing component."
        case .activationUnconfirmed: return "In System Settings, open General → Login Items & Extensions. Under Extensions, choose By Category, then the information button beside File System Extensions. Turn on CloudDrive, return here, and connect Finder. The included component does not prove macOS has enabled it."
        case .connected: return "The current mount was confirmed by macOS. You can open your drive in Finder."
        }
    }
}

struct FinderIntegrationSetupView: View {
    @ObservedObject var drive: Drive
    @ObservedObject private var owner: NamespaceDriveController
    @Environment(\.scenePhase) private var scenePhase
    @State private var revision = 0
    init(drive: Drive) { self.drive = drive; owner = drive.namespaceEngine }
    private var supportedSystem: Bool {
        if #available(macOS 26.0, *) { return true }; return false
    }
    var body: some View {
        let presentation = FinderIntegrationPresentation(supportedSystem: supportedSystem,
            componentPresent: owner.extensionAvailable, mounted: owner.mounted)
        VStack(alignment: .leading, spacing: 10) {
            Label(presentation.title, systemImage: owner.mounted ? "checkmark.circle" : "externaldrive.badge.questionmark")
                .font(.subheadline.weight(.semibold))
            Text(presentation.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if presentation.state == .activationUnconfirmed {
                Button("Open Login Items & Extensions") { SMAppService.openSystemSettingsLoginItems() }
                    .accessibilityIdentifier("namespace-open-extension-settings")
                Text("For right-click actions, also enable CloudDrive under Finder Extensions. That extension is separate from the filesystem connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if presentation.state == .componentMissing {
                Button("Show this app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            }
            if !owner.mounted {
                Button("Check component again") { revision += 1 }.disabled(owner.busy)
                    .help("Check this app’s embedded component. Enablement is confirmed when Finder connects.")
            }
        }
        .id(revision)
        .onChange(of: scenePhase) { _, phase in if phase == .active { revision += 1 } }
    }
}
