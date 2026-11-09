import XCTest
@testable import CloudDriveFSAdapter

final class DirectoryCursorTests: XCTestCase {
    func testContinuationCannotBeReusedForAnotherDirectoryOrRevision() throws {
        let table = FileSystemCursorTable()
        let directory = UUID()
        let expected = FileSystemDirectoryCursor(directoryID: directory, revision: 42, after: UUID().uuidString, dotIndex: 2)
        let cookie = table.insert(expected)
        XCTAssertEqual(try table.cursor(cookie, directory: directory), expected)
        XCTAssertThrowsError(try table.cursor(cookie, directory: UUID()))
        XCTAssertThrowsError(try expected.validate(pageRevision: 43, verifier: 0))
        XCTAssertThrowsError(try expected.validate(pageRevision: 42, verifier: 7))
        XCTAssertNoThrow(try expected.validate(pageRevision: 42, verifier: 43))
    }
    func testBoundedCookiesExpireWithoutPointingAtAnotherEntry() throws {
        let table = FileSystemCursorTable(capacity: 2)
        let directory = UUID()
        let first = table.insert(.init(directoryID: directory, revision: 1, after: "a", dotIndex: 2))
        let second = table.insert(.init(directoryID: directory, revision: 1, after: "b", dotIndex: 2))
        let third = table.insert(.init(directoryID: directory, revision: 1, after: "c", dotIndex: 2))
        XCTAssertThrowsError(try table.cursor(first, directory: directory))
        XCTAssertEqual(try table.cursor(second, directory: directory).after, "b")
        XCTAssertEqual(try table.cursor(third, directory: directory).after, "c")
        table.removeAll()
        XCTAssertThrowsError(try table.cursor(third, directory: directory))
    }
}
