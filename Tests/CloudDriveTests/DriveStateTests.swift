import XCTest
@testable import CloudDrive
final class DriveStateTests: XCTestCase {
    func testBindingRequiresExactDestinationAndCache() {
        let c = Connection(endpoint: "https://example.r2.cloudflarestorage.com", bucket: "fixture", prefix: "nested/drive", accessKey: "test", secretKey: "test")
        let cache = URL(fileURLWithPath: "/tmp/fixture-cache")
        XCTAssertTrue(BackendBinding.matches(fs: "bucket{abc12}:fixture/nested/drive", cachePath: "/tmp/fixture-cache/vfs/bucket{abc12}/fixture/nested/drive", connection: c, cacheRoot: cache))
        XCTAssertFalse(BackendBinding.matches(fs: "bucket{abc12}:fixture/other", cachePath: "/tmp/fixture-cache/vfs/bucket{abc12}/fixture/nested/drive", connection: c, cacheRoot: cache))
        XCTAssertFalse(BackendBinding.matches(fs: "bucket{abc12}:fixture/nested/drive", cachePath: "/tmp/other-cache/vfs/bucket{abc12}/fixture/nested/drive", connection: c, cacheRoot: cache))
        XCTAssertFalse(BackendBinding.matches(fs: "wrong:fixture/nested/drive", cachePath: "/tmp/fixture-cache/vfs/wrong/fixture/nested/drive", connection: c, cacheRoot: cache))
    }
    func testUnknownCannotBeIdleOrVerified() {
        XCTAssertNotEqual(UploadState.unknown, .idle)
        XCTAssertTrue(UploadState.unknown.text.contains("unknown"))
        XCTAssertTrue(UploadState.idle.text.contains("does not independently verify"))
    }
    func testWorkerEnvironmentDoesNotInheritCredentialOverrides() {
        let c = Connection()
        XCTAssertNil(c.workerEnvironment["RCLONE_CONFIG_OTHER_SECRET_ACCESS_KEY"])
        XCTAssertNil(c.workerEnvironment["HTTP_PROXY"])
        XCTAssertEqual(c.workerEnvironment["RCLONE_CONFIG_BUCKET_PROVIDER"], "Cloudflare")
    }
}
