import XCTest
@testable import CloudDriveCore

final class NamespaceResourceLocationTests: XCTestCase {
    func testProductionNeverFallsBackToTemporaryDirectory() throws {
        let session = UUID()
        if let group = try? NamespaceResourceLocation.sharedBase() {
            let resource = try NamespaceResourceLocation.resource(sessionID: session)
            XCTAssertEqual(resource.deletingLastPathComponent(), group)
            XCTAssertNotEqual(resource.deletingLastPathComponent(), NamespaceResourceLocation.fixtureBase())
        } else {
            XCTAssertThrowsError(try NamespaceResourceLocation.resource(sessionID: session)) { error in
                XCTAssertEqual((error as? POSIXError)?.code, .EPERM)
            }
            let fixture = try NamespaceResourceLocation.resource(sessionID: session, fixture: true)
            XCTAssertEqual(fixture.deletingLastPathComponent(), NamespaceResourceLocation.fixtureBase())
        }
    }

    func testResourceFitsUnixSocketAddressAndIsSessionSpecific() throws {
        let session = UUID()
        let base = URL(fileURLWithPath: "/Users/max/Library/Group Containers/EGEBBVL76D.cd/r", isDirectory: true)
        let resource = try NamespaceResourceLocation.resource(base: base, sessionID: session)
        XCTAssertEqual(resource.lastPathComponent, String(session.uuidString.prefix(16)))
        XCTAssertLessThan(resource.appendingPathComponent("owner.sock").path.utf8.count, 104)
        XCTAssertThrowsError(try NamespaceResourceLocation.resource(base: URL(fileURLWithPath: "/"+String(repeating: "a", count: 90)), sessionID: session)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENAMETOOLONG)
        }
    }
}
