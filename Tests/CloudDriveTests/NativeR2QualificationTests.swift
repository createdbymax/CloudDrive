import XCTest
@testable import CloudDrive

#if DEBUG
final class NativeR2QualificationTests: XCTestCase {
    func testPublicationDeadlineAdvancesOnlyWithProgressAndRemainsBounded() {
        let start = ContinuousClock.now
        var window = QualificationPublicationWindow(start: start)
        window.observe(pending: 20, published: 1, at: start)
        window.observe(pending: 20, published: 1, at: start.advanced(by: .seconds(35)))
        XCTAssertEqual(window.deadline, start.advanced(by: .seconds(45)))
        for second in [40, 80, 120] {
            window.observe(pending: 20 - second / 40, published: Int64(second), at: start.advanced(by: .seconds(second)))
        }
        XCTAssertEqual(window.deadline, start.advanced(by: .seconds(150)))
        window.observe(pending: 1, published: 170, at: start.advanced(by: .seconds(160)))
        XCTAssertEqual(window.deadline, start.advanced(by: .seconds(150)))
    }
    @MainActor func testScopeUsesFreshChildPrefixAndFixedDeterministicPayload() {
        let id = UUID(uuidString: "A18A9F80-A6E8-4A67-A02A-5294FD7EB94C")!
        let prefix = NativeR2Qualification.prefix(parent: "user/drive/", id: id)
        XCTAssertEqual(prefix, "user/drive/clouddrive-native-qualification-a18a9f80-a6e8-4a67-a02a-5294fd7eb94c")
        XCTAssertNotEqual(prefix, "user/drive")
        XCTAssertEqual(NativeR2Qualification.payload().count, 2 * 1024 * 1024)
        XCTAssertEqual(NativeR2Qualification.payload(), NativeR2Qualification.payload())
    }
    @MainActor func testMountOwnershipRejectsWrongSourceTypeIdentityAndLocation() {
        let mount = URL(fileURLWithPath: "/synthetic/Qualifications/native-test/Mount")
        let resource = URL(fileURLWithPath: "/synthetic/group/r/fixture")
        let good = MountEntry(path: mount.path, source: resource.absoluteString, type: "clouddrive", id: "1:2")
        XCTAssertTrue(NativeR2Qualification.owned(good, mount: mount, resource: resource))
        var bad = good; bad.source = "/other/resource"
        XCTAssertFalse(NativeR2Qualification.owned(bad, mount: mount, resource: resource))
        bad = good; bad.type = "nfs"
        XCTAssertFalse(NativeR2Qualification.owned(bad, mount: mount, resource: resource))
        bad = good; bad.path = "/user/drive"
        XCTAssertFalse(NativeR2Qualification.owned(bad, mount: mount, resource: resource))
        bad = good; bad.id = ""
        XCTAssertFalse(NativeR2Qualification.owned(bad, mount: mount, resource: resource))
        bad = good; bad.source = "file://foreign/synthetic/group/r/fixture"
        XCTAssertFalse(NativeR2Qualification.owned(bad, mount: mount, resource: resource))
    }
}
#endif
