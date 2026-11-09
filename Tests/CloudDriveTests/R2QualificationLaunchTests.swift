import XCTest
@testable import CloudDrive

final class R2QualificationLaunchTests: XCTestCase {
    func testNormalLaunchNeverOptsIntoLiveDiagnostics() {
        XCTAssertFalse(R2QualificationLaunch.requested(arguments: ["CloudDrive"]))
        XCTAssertFalse(R2QualificationLaunch.requested(arguments: ["CloudDrive", "--qualify-r2-other"]))
    }
    func testDiagnosticRequiresExactStandaloneOption() {
        XCTAssertTrue(R2QualificationLaunch.valid(arguments: ["CloudDrive", "--qualify-r2"]))
        XCTAssertTrue(R2QualificationLaunch.valid(arguments: ["CloudDrive", "--qualify-native-r2"]))
        XCTAssertFalse(R2QualificationLaunch.valid(arguments: ["CloudDrive", "--qualify-native-r2", "/user/drive"]))
        XCTAssertFalse(R2QualificationLaunch.valid(arguments: ["CloudDrive", "--qualify-r2", "extra"]))
        XCTAssertFalse(R2QualificationLaunch.valid(arguments: []))
        #if DEBUG
        XCTAssertTrue(R2QualificationLaunch.requested(arguments: ["CloudDrive", "--qualify-r2"]))
        #else
        XCTAssertFalse(R2QualificationLaunch.requested(arguments: ["CloudDrive", "--qualify-r2"]))
        #endif
    }
}
