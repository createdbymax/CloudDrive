import SwiftUI

struct R2QualificationView: View {
    let connection: Connection
    let root: URL
    @StateObject private var controller = R2QualificationController()
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test R2 compatibility").font(.headline)
            Text("Uploads about 20 MB of generated data into a new isolated test folder, verifies conditional operations and downloaded bytes, then removes only its verified test objects. Failed tests retain their synthetic objects and a local report. Your existing files are not modified.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Run Isolated R2 Test…") { confirming = true }.disabled(controller.isRunning)
                if controller.isRunning { ProgressView().controlSize(.small) }
            }
            Text(controller.progress).font(.caption).accessibilityIdentifier("r2-qualification-status")
            if let report = controller.result {
                ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.name + ": " + step.state + (step.diagnostic.map { " (" + $0 + ")" } ?? "")).font(.caption)
                }
            }
            if let url = controller.reportURL {
                Button("Show Test Report") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }.confirmationDialog("Run an isolated live R2 test?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Run Test") { Task { await controller.run(connection: connection, root: root) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This uses the current connection and performs real R2 requests under a new generated qualification folder. Normal provider request and storage charges may apply.") }
    }
}
