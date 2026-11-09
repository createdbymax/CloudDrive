import AppKit
import CoreTransferable
import Darwin
import Foundation
import XCTest
@testable import CloudDrive

final class MountedDropTests: XCTestCase {
    func testFinderFileURLRepresentationCanReachTypedDropDestination() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
            completion(original.dataRepresentation, nil)
            return nil
        }
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: URL.self) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(received.standardizedFileURL, original.standardizedFileURL)
    }

    func testLegacyWorkerQualificationRequiresExactTestedVersion() {
        XCTAssertEqual(MountedDrop.qualifiedWorker(versionResponse: Data(#"{"version":"v1.75.2-clouddrive.8"}"#.utf8)), true)
        XCTAssertEqual(MountedDrop.qualifiedWorker(versionResponse: Data(#"{"version":"v1.75.2-clouddrive.9"}"#.utf8)), true)
        XCTAssertEqual(MountedDrop.qualifiedWorker(versionResponse: Data(#"{"version":"v1.75.2-clouddrive.10"}"#.utf8)), true)
        for version in ["v1.75.2-clouddrive.7", "v1.75.2", "v1.75.2-clouddrive.80", "v1.75.2-clouddrive.8-DEV", "v1.75.2-clouddrive.9-DEV", "v1.75.2-clouddrive.11"] {
            XCTAssertEqual(MountedDrop.qualifiedWorker(versionResponse: Data("{\"version\":\"\(version)\"}".utf8)), false)
        }
        XCTAssertNil(MountedDrop.qualifiedWorker(versionResponse: Data("{}".utf8)))
    }

    func testExclusiveCopyPreservesPackageMembersAndFileMetadata() throws {
        try fixture { source, target, input, output, device in
            let package = source.appendingPathComponent("Example.bundle")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            let data = package.appendingPathComponent(".payload")
            try Data("original".utf8).write(to: data)
            XCTAssertEqual(chmod(data.path, 0o640), 0)
            XCTAssertEqual(setxattr(data.path, "org.clouddrive.fixture", "yes", 3, 0, 0), 0)
            XCTAssertEqual(symlink(".payload", package.appendingPathComponent("link").path), 0)
            try MountedDrop.copyEntry(name: "Example.bundle", from: input, into: output, sourceDevice: device)
            let result = target.appendingPathComponent("Example.bundle")
            let member = result.appendingPathComponent(".payload")
            XCTAssertEqual(try Data(contentsOf: member), Data("original".utf8))
            var buffer = [UInt8](repeating: 0, count: 8)
            XCTAssertEqual(getxattr(member.path, "org.clouddrive.fixture", &buffer, 8, 0, 0), 3)
            XCTAssertEqual(String(decoding: buffer.prefix(3), as: UTF8.self), "yes")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: member.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: result.appendingPathComponent("link").path), ".payload")
            try Data("new".utf8).write(to: package.appendingPathComponent("new"))
            XCTAssertThrowsError(try MountedDrop.copyEntry(name: "Example.bundle", from: input, into: output, sourceDevice: device))
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.appendingPathComponent("new").path))
        }
    }

    func testExistingFileOrSymlinkCannotBeOverwrittenAndSameVolumeIsRejected() throws {
        try fixture { source, target, input, output, device in
            let file = source.appendingPathComponent("report")
            try Data("new".utf8).write(to: file)
            XCTAssertThrowsError(try MountedDrop.copyItem(file, into: output, mountPath: target.path))
            let existing = target.appendingPathComponent("other")
            try Data("keep".utf8).write(to: existing)
            XCTAssertEqual(symlink("other", target.appendingPathComponent("report").path), 0)
            XCTAssertThrowsError(try MountedDrop.copyEntry(name: "report", from: input, into: output, sourceDevice: device))
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        }
    }

    func testFilesOnlyDestinationRefusesFolderAndLinkBeforeCreatingAnything() throws {
        try fixture { source, target, input, output, device in
            try FileManager.default.createDirectory(at: source.appendingPathComponent("folder"), withIntermediateDirectories: false)
            XCTAssertEqual(symlink("folder", source.appendingPathComponent("shortcut").path), 0)
            for name in ["folder", "shortcut"] {
                XCTAssertThrowsError(try MountedDrop.copyEntry(name: name, from: input, into: output, sourceDevice: device, allowsFolders: false)) {
                    XCTAssertTrue($0.localizedDescription.contains("Open in Finder"))
                }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    func testPreflightRefusesResourceForkInsidePackage() throws {
        try fixture { source, target, input, _, device in
            let package = source.appendingPathComponent("Example.bundle")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            let member = package.appendingPathComponent("image")
            try Data("data".utf8).write(to: member)
            XCTAssertEqual(setxattr(member.path, "com.apple.ResourceFork", "fork", 4, 0, 0), 0)
            XCTAssertThrowsError(try MountedDrop.preflight(name: "Example.bundle", from: input, sourceDevice: device)) {
                XCTAssertTrue($0.localizedDescription.contains("Compress in Finder"))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    func testDetachedMountCannotWriteToUnderlyingFolder() throws {
        try fixture { source, target, _, _, _ in
            let file = source.appendingPathComponent("sample")
            try Data("sample".utf8).write(to: file)
            let stale = MountEntry(path: target.path, source: "127.0.0.1:/", type: "nfs", id: "9999:99")
            XCTAssertThrowsError(try MountedDrop.copy([file], to: stale))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    func testConcurrentSameNameDoesNotMergeDirectory() throws {
        try fixture { source, target, input, output, device in
            try FileManager.default.createDirectory(at: source.appendingPathComponent("photos"), withIntermediateDirectories: false)
            try Data("once".utf8).write(to: source.appendingPathComponent("photos/test"))
            let lock = NSLock()
            var outcomes: [Int] = []
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let result: Int
                do {
                    try MountedDrop.copyEntry(name: "photos", from: input, into: output, sourceDevice: device)
                    result = 0
                } catch { result = (error as NSError).code }
                lock.withLock { outcomes.append(result) }
            }
            XCTAssertEqual(outcomes.filter { $0 == 0 }.count, 1)
            XCTAssertEqual(outcomes.filter { $0 == EEXIST }.count, 7)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent("photos").path), ["test"])
        }
    }

    private func fixture(_ body: (URL, URL, Int32, Int32, dev_t) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input"), target = root.appendingPathComponent("output")
        for dir in [source, target] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let input = open(source.path, O_RDONLY | O_DIRECTORY), output = open(target.path, O_RDONLY | O_DIRECTORY)
        defer { close(input); close(output) }
        var st = stat()
        XCTAssertEqual(fstat(input, &st), 0)
        try body(source, target, input, output, st.st_dev)
    }
}
