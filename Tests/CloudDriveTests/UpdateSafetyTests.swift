import XCTest
@testable import CloudDrive

final class UpdateSafetyTests: XCTestCase {
    @MainActor func testCheckRevalidatesDriveState() throws {
        var safe = true
        let updates = UpdateController(canInstall: { safe }, notice: {})
        try updates.updater(updates.updater, mayPerform: .updates)
        safe = false
        XCTAssertThrowsError(try updates.updater(updates.updater, mayPerform: .updates))
        safe = true
        XCTAssertNoThrow(try updates.updater(updates.updater, mayPerform: .updates))
    }

    @MainActor func testReconnectPostponesRestartAndRequiresExplicitSafeResume() {
        var safe = false
        var installs = 0
        var notices = 0
        let updates = UpdateController(canInstall: { safe }, notice: { notices += 1 })
        XCTAssertTrue(updates.postponeInstallationIfNeeded { installs += 1 })
        XCTAssertTrue(updates.hasDeferredInstall)
        updates.installDeferredUpdate()
        XCTAssertEqual(installs, 0)
        safe = true
        XCTAssertEqual(installs, 0, "Ejecting alone must not install an update")
        updates.installDeferredUpdate()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(updates.hasDeferredInstall)
        updates.installDeferredUpdate()
        XCTAssertEqual(installs, 1, "The restart callback must be consumed once")
        XCTAssertEqual(notices, 2)
    }

    @MainActor func testSparkleDelegateHooksAreExportedAndAbortClearsCallback() {
        let updates = UpdateController(canInstall: { false }, notice: {})
        XCTAssertTrue(updates.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
        XCTAssertTrue(updates.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
        XCTAssertTrue(updates.postponeInstallationIfNeeded { XCTFail("Aborted callback must not run") })
        updates.updater(updates.updater, didAbortWithError: NSError(domain: "fixture", code: 1))
        XCTAssertFalse(updates.hasDeferredInstall)
    }

    @MainActor func testSafeRestartDoesNotPostpone() {
        let updates = UpdateController(canInstall: { true }, notice: { XCTFail("Unexpected notice") })
        XCTAssertFalse(updates.postponeInstallationIfNeeded { XCTFail("Sparkle owns immediate installation") })
        XCTAssertFalse(updates.hasDeferredInstall)
    }
}
