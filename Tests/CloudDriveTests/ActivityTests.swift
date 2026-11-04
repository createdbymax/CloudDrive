import XCTest
@testable import CloudDrive
final class ActivityTests: XCTestCase {
    func testDuplicateQueueIdentitiesAreRejected() throws {
        let repeatedID = #"{"queue":[{"id":1,"name":"a","size":1,"tries":0,"uploading":false},{"id":1,"name":"b","size":1,"tries":0,"uploading":false}]}"#
        let repeatedName = #"{"queue":[{"id":1,"name":"a","size":1,"tries":0,"uploading":false},{"id":2,"name":"a","size":1,"tries":0,"uploading":false}]}"#
        XCTAssertThrowsError(try UploadQueue.decode(Data(repeatedID.utf8)))
        XCTAssertThrowsError(try UploadQueue.decode(Data(repeatedName.utf8)))
    }
    func testMissingQueueAndInvalidEntriesAreNotEmptySuccess() throws {
        XCTAssertThrowsError(try UploadQueue.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try UploadQueue.decode(Data(#"{"queue":[{"id":1,"name":"file","size":-1,"tries":0,"uploading":false}]}"#.utf8)))
        let queue = try UploadQueue.decode(Data(#"{"queue":[{"id":1,"name":"file","size":10,"tries":2,"uploading":false}]}"#.utf8))
        XCTAssertEqual(queue.queue.first?.label, "Retrying (2 attempts)")
    }
}
