import FSKit

@main
@available(macOS 26.0, *)
struct CloudDriveFSExtension: UnaryFileSystemExtension {
    private let implementation = CloudDriveFileSystem()
    var fileSystem: CloudDriveFileSystem { implementation }
}
