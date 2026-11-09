import Foundation

public enum EncryptedDriveState {
    private struct Marker: Codable { let version: Int; let binding: String; let keyID: String }
    public static func validate(directory: URL, binding: String, keyID: String?) throws {
        try CoreFileIO.privateDirectory(directory)
        let url = directory.appendingPathComponent("encryption.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let marker = try CoreFileIO.readChecked(Marker.self, at: url, maximum: 16_384)
            guard marker.version == 1, marker.binding == binding, marker.keyID == keyID else { throw StorageFailure.integrity }
        } else if let keyID {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Namespace").path) else { throw StorageFailure.unsupported }
            try CoreFileIO.atomicChecked(Marker(version: 1, binding: binding, keyID: keyID), at: url)
        }
    }
}
