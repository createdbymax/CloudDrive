import Foundation
import CryptoKit

// Potentially blocking filesystem calls stay in an expendable helper, never on the UI actor.
// Only the app-owned fixture root and an exact synthetic filename are accepted.
func fail() -> Never { FileHandle.standardError.write(Data("File operation failed. Fixture retained if present.\n".utf8)); exit(1) }
let args = CommandLine.arguments
if args.count != 5 { fail() }
let action = args[1], base = URL(fileURLWithPath: args[2], isDirectory: true)
let name = args[3], expected = args[4]
if action == "prepare" {
    do {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: base.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty else { fail() }
        exit(0)
    } catch { fail() }
}
guard name.range(of: "^clouddrive-check-[A-Fa-f0-9-]{36}\\.bin$", options: .regularExpression) != nil else { fail() }
let url = base.appendingPathComponent(name)
do {
    switch action {
    case "write":
        // Create exclusively so an existing file can never be overwritten.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { fail() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let chunk = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for _ in 0..<16 { try file.write(contentsOf: chunk) }
        try file.synchronize(); try file.close()
    case "hash":
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { fail() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var digest = SHA256(), count = 0
        while let bytes = try file.read(upToCount: 65536), !bytes.isEmpty {
            count += bytes.count; guard count <= 1048576 else { fail() }; digest.update(data: bytes)
        }
        guard count == 1048576 else { fail() }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard expected == "-" || expected == hex else { fail() }
        print(hex)
    case "remove":
        // Only remove a fully verified synthetic fixture.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { fail() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var digest = SHA256(), count = 0
        while let bytes = try file.read(upToCount: 65536), !bytes.isEmpty {
            count += bytes.count; guard count <= 1048576 else { fail() }; digest.update(data: bytes)
        }
        guard count == 1048576,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { fail() }
        try FileManager.default.removeItem(at: url)
    default: fail()
    }
} catch { fail() }
