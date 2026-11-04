import XCTest
@testable import CloudDrive

final class UploadProgressTests: XCTestCase {
    private func queue(_ json: String) throws -> UploadQueue { try UploadQueue.decode(Data(json.utf8)) }
    private func stats(_ json: String) throws -> TransferStats {
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if object["bytes"] == nil { object["bytes"] = 0 }
        if object["elapsedTime"] == nil { object["elapsedTime"] = 1 }
        return try TransferStats.decode(JSONSerialization.data(withJSONObject: object))
    }
    private let remote = "bucket{fixture}:test/uploads"

    func testUsesOutstandingUploadsNotLifetimeBytesOrDownloads() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a.bin","size":100,"tries":1,"uploading":true},{"id":2,"name":"b.bin","size":300,"tries":0,"uploading":false}]}"#)
        let s = try stats(#"{"bytes":99999999,"totalBytes":99999999,"speed":999999,"transferring":[{"name":"a.bin","size":100,"bytes":25,"speed":10,"speedAvg":5,"eta":15,"srcFs":"/cache","dstFs":"bucket{fixture}:test/uploads"},{"name":"download.bin","size":1000,"bytes":900,"speed":1000,"dstFs":"/cache"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: s, destination: remote)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.totalBytes, 400)
        XCTAssertEqual(result.completedBytes, 25)
        XCTAssertEqual(result.speed, 5)
        XCTAssertEqual(result.eta, 75)
        XCTAssertEqual(result.progress, 0.0625)
        XCTAssertEqual(result.rows[0].progress, 0.25)
    }
    func testSameNameDownloadCannotBecomeUploadProgress() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"same.bin","size":100,"tries":1,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"same.bin","size":100,"bytes":80,"speedAvg":40,"eta":1,"srcFs":"bucket{fixture}:test/uploads","dstFs":"/cache"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: s, destination: remote)
        XCTAssertNil(result.rows[0].bytes); XCTAssertNil(result.progress)
        XCTAssertNil(result.speed); XCTAssertNil(result.eta)
    }
    func testWaitingRetryDoesNotHideActiveUploadSpeedOrInventItsBytes() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true},{"id":2,"name":"b","size":100,"tries":2,"uploading":false}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":50,"speedAvg":10,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: s, destination: remote)
        XCTAssertEqual(result.speed, 10)
        XCTAssertNil(result.rows[1].bytes)
        XCTAssertNil(result.progress); XCTAssertNil(result.eta)
    }
    func testOversizedRetryCounterDoesNotBecome100Percent() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":2,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":120,"speedAvg":20,"eta":0,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: s, destination: remote)
        XCTAssertNil(result.rows[0].progress); XCTAssertNil(result.completedBytes)
        XCTAssertNil(result.speed); XCTAssertEqual(result.retryingCount, 1)
    }
    func testMissingCountersAndNullETAAreUnknown() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true}]}"#)
        let initial = try stats(#"{"transferring":[{"name":"a","size":100,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        XCTAssertNil(UploadProgressSnapshot.make(queue: q, stats: initial, destination: remote).progress)
        let active = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":10,"speedAvg":0,"eta":null,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: active, destination: remote)
        XCTAssertEqual(result.rows[0].bytes, 10); XCTAssertNil(result.rows[0].eta)
        XCTAssertNil(result.eta)
    }
    func testMalformedNumbersAndMissingIdentityFailDecoding() {
        XCTAssertThrowsError(try TransferStats.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try stats(#"{"transferring":null}"#))
        for json in [
            #"{"transferring":[{"name":"a","size":100,"bytes":true}]}"#,
            #"{"transferring":[{"name":"a","size":-2}]}"#,
            #"{"transferring":[{"name":"a","size":100,"speedAvg":-1}]}"#,
            #"{"transferring":[{"size":100}]}"#,
            #"{"transferring":"wrong"}"#
        ] { XCTAssertThrowsError(try stats(json)) }
    }
    func testPartialMismatchDoesNotInventOverallProgress() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true},{"id":2,"name":"b","size":100,"tries":1,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":50,"speedAvg":10,"eta":5,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: s, destination: remote)
        XCTAssertEqual(result.rows[0].bytes, 50); XCTAssertNil(result.rows[1].bytes)
        XCTAssertNil(result.completedBytes); XCTAssertNil(result.progress); XCTAssertNil(result.speed)
    }
    func testFinishingBytesAreNotCloudCompletionAndEmptyQueueIsNot100Percent() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":100,"speedAvg":10,"eta":0,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        XCTAssertEqual(UploadProgressSnapshot.make(queue: q, stats: s, destination: remote).rows[0].label, "Finishing upload")
        let empty = UploadProgressSnapshot.make(queue: try queue(#"{"queue":[]}"#), stats: try stats("{}"), destination: remote)
        XCTAssertTrue(empty.isEmpty); XCTAssertNil(empty.progress); XCTAssertNil(empty.eta)
    }
    func testDuplicateOrChangedSizeTransferIsUnknown() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":101,"bytes":50,"speedAvg":10,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        XCTAssertNil(UploadProgressSnapshot.make(queue: q, stats: s, destination: remote).progress)
        let duplicate = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":50,"speedAvg":10,"dstFs":"bucket{fixture}:test/uploads"},{"name":"a","size":100,"bytes":60,"speedAvg":10,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        XCTAssertNil(UploadProgressSnapshot.make(queue: q, stats: duplicate, destination: remote).progress)
    }
    func testRateSumOverflowCannotProduceInfiniteSpeedOrETA() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true},{"id":2,"name":"b","size":100,"tries":1,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":100,"bytes":50,"speedAvg":1e308,"dstFs":"bucket{fixture}:test/uploads"},{"name":"b","size":100,"bytes":50,"speedAvg":1e308,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        let result = UploadProgressSnapshot.make(queue: q, stats: s, destination: remote)
        XCTAssertEqual(result.completedBytes, 100)
        XCTAssertEqual(result.progress, 0.5)
        XCTAssertNil(result.speed); XCTAssertNil(result.eta)
    }

    func testUnknownSourceSizeUsesKnownQueueSizeAndSumOverflowStaysUnknown() throws {
        let q = try queue(#"{"queue":[{"id":1,"name":"a","size":100,"tries":1,"uploading":true}]}"#)
        let s = try stats(#"{"transferring":[{"name":"a","size":-1,"bytes":25,"speedAvg":10,"eta":null,"dstFs":"bucket{fixture}:test/uploads"}]}"#)
        XCTAssertEqual(UploadProgressSnapshot.make(queue: q, stats: s, destination: remote).progress, 0.25)
        let large = try queue(#"{"queue":[{"id":1,"name":"a","size":9223372036854775807,"tries":0,"uploading":false},{"id":2,"name":"b","size":1,"tries":0,"uploading":false}]}"#)
        let result = UploadProgressSnapshot.make(queue: large, stats: try stats("{}"), destination: remote)
        XCTAssertNil(result.totalBytes); XCTAssertNil(result.progress)
    }
}
