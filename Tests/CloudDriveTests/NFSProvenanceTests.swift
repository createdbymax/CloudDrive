import XCTest
@testable import CloudDrive
final class NFSProvenanceTests: XCTestCase {
    func testRequiresCurrentPortForExactMount() {
        let report = """
        /private/tmp/fixture from 127.0.0.1:/
          -- Original mount options:
             NFS parameters: vers=3,tcp,port=5555,mountport=5555
          -- Current mount parameters:
             NFS parameters: vers=3,tcp,port=5555,mountport=5555,hard
        """
        XCTAssertTrue(NFSProvenance.matches(report: report, mountPath: "/private/tmp/fixture", port: 5555))
        XCTAssertFalse(NFSProvenance.matches(report: report, mountPath: "/private/tmp/fixture", port: 5556))
        XCTAssertFalse(NFSProvenance.matches(report: report, mountPath: "/private/tmp/other", port: 5555))
        XCTAssertFalse(NFSProvenance.matches(report: report.replacingOccurrences(of: "port=5555,mountport", with: "port=5555,port=5556,mountport"), mountPath: "/private/tmp/fixture", port: 5555))
        XCTAssertFalse(NFSProvenance.matches(report: report.replacingOccurrences(of: "-- Current mount parameters:", with: "-- Unknown:"), mountPath: "/private/tmp/fixture", port: 5555))
    }
}
