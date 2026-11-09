import XCTest
@testable import CloudDriveCore

final class NamespaceSocketErrorTests: XCTestCase {
    func testMissingSocketPreservesKernelError() async throws {
        let descriptor = NamespaceOwnerDescriptor(socketPath: "/tmp/missing-" + UUID().uuidString + "/owner.sock",
                                                   token: String(repeating: "a", count: 64), binding: "synthetic")
        do {
            _ = try await UnixSocketRPCClient(descriptor: descriptor).call(.init(operation: "volume"))
            XCTFail("Missing socket must fail")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .ENOENT)
        }
    }
}
