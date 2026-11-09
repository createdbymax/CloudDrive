import XCTest
@testable import CloudDrive
import CloudDriveCore

#if DEBUG
final class LogicMoveHelperTests: XCTestCase {
    func testPathScopePreservesExactNamesAndLimitsCollisionRenames() throws {
        let request = LogicMoveHelper.Request(op: "head", binding: "b", relativePath: "Mix.logicx/Audio Files/._take #%.aif",
            destinationRelativePath: "Mix (from Logic Projects 1).logicx/Audio Files/._take #% (from Logic Projects 2).aif", side: "destination")
        let keys = try LogicMoveHelper.keys(request, prefix: "saved")
        XCTAssertEqual(keys.source, "saved/Logic Projects/Mix.logicx/Audio Files/._take #%.aif")
        XCTAssertEqual(keys.destination, "saved/T5 Backup/Logic Projects/Mix (from Logic Projects 1).logicx/Audio Files/._take #% (from Logic Projects 2).aif")
        for path in ["/file", "a/../b", ".clouddrive/x", "dir//x", "dir/", "a\nb", "a\\b"] {
            let invalid = LogicMoveHelper.Request(op: "head", binding: "b", relativePath: path, side: "source")
            XCTAssertThrowsError(try LogicMoveHelper.keys(invalid, prefix: "saved"))
        }
        for target in ["Elsewhere/a.wav", "Original/changed.wav", "Original/a (from Logic Projects 0).wav", "Original/../a.wav"] {
            let invalid = LogicMoveHelper.Request(op: "copy", binding: "b", relativePath: "Original/a.wav", destinationRelativePath: target)
            XCTAssertThrowsError(try LogicMoveHelper.keys(invalid, prefix: "saved"))
        }
    }
    func testCopyRejectsWrongBindingSizeQualificationAndForeignDestinationThenReplaysItsOwnReceipt() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: work) }
        let remote = try FixtureStorageRemote(directory: work)
        let source = try await remote.put(key: "test/Logic Projects/a.wav", data: Data("one".utf8), condition: .absent, operationID: UUID())
        var request = LogicMoveHelper.Request(op: "copy", binding: "binding", relativePath: "a.wav", sourceValidator: source.validator,
            sourceSize: source.size, operationID: UUID())
        func result(_ request: LogicMoveHelper.Request, _ binding: String, _ qualified: Bool) async throws -> LogicMoveHelper.Reply {
            try await LogicMoveHelper.perform(request, binding: binding, scope: "test", remote: remote, qualified: qualified)
        }
        do { _ = try await result(request, "foreign", true); XCTFail() } catch LogicMoveHelper.Failure.wrongBinding {}
        do { _ = try await result(request, "binding", false); XCTFail() } catch LogicMoveHelper.Failure.missingQualification {}
        request.sourceSize = 9
        do { _ = try await result(request, "binding", true); XCTFail() } catch LogicMoveHelper.Failure.changedSource {}
        request.sourceSize = source.size
        let before = try await remote.head(key: "test/T5 Backup/Logic Projects/a.wav"); XCTAssertNil(before)
        let first = try await result(request, "binding", true), replayed = try await result(request, "binding", true)
        XCTAssertEqual(first.operationID, request.operationID); XCTAssertEqual(first.validator, replayed.validator)
        request.operationID = UUID()
        do { _ = try await result(request, "binding", true); XCTFail() } catch StorageFailure.conflict {}
        let preserved = try await remote.head(key: source.key); XCTAssertEqual(preserved?.validator, source.validator)
    }
}
#endif
