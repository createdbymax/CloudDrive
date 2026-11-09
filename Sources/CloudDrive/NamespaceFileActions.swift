import SwiftUI

/// All offline actions go through the same owner as Finder and uploads.
struct NamespaceFileActions: View {
    @ObservedObject var drive: Drive
    let item: CatalogObject
    var body: some View {
        if drive.namespaceEngine.enabled, let id = UUID(uuidString: item.etag) {
            Divider()
            Button("Move to Recently Deleted") { Task { await drive.namespaceEngine.moveToTrash(id) } }
                .disabled(!drive.namespaceEngine.running || drive.namespaceEngine.busy || drive.namespaceEngine.readOnly)
            Button("Keep downloaded") { Task { await drive.namespaceEngine.keepDownloaded(id) } }
                .disabled(!drive.namespaceEngine.running || drive.namespaceEngine.busy)
            Button("Free local space") { Task { await drive.namespaceEngine.freeLocalSpace(id) } }
                .disabled(!drive.namespaceEngine.running || drive.namespaceEngine.busy)
        }
    }
}
