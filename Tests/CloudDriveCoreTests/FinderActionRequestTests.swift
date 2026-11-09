import XCTest
@testable import CloudDriveCore

final class FinderActionRequestTests: XCTestCase {
    func testUnicodeAndLiteralPercentNamesRoundTripWithoutChangingComponents() throws {
        let root = URL(fileURLWithPath: "/Users/fixture/Instant Drive")
        let request = try FinderActionRequest(action: .keepDownloaded, path: root.path + "/Été/100%20 + ?.wav")
        let parsed = try FinderActionRequest(url: XCTUnwrap(request.url))
        XCTAssertEqual(parsed, request)
        XCTAssertEqual(try parsed.relativeComponents(under: root), ["Été", "100%20 + ?.wav"])
    }
    func testUntrustedURLCannotAddCredentialsDuplicateFieldsOrTraversal() throws {
        for raw in ["clouddrive://finder?action=freeSpace", "clouddrive://finder?action=activity&action=freeSpace",
                    "clouddrive://finder?action=activity&token=secret", "clouddrive://user@finder?action=activity",
                    "clouddrive://finder:123?action=activity", "clouddrive://finder/other?action=activity",
                    "clouddrive://finder?action=activity#fragment", "https://finder?action=activity",
                    "clouddrive://finder?action=freeSpace&path=/mount/../escape",
                    "clouddrive://finder?action=freeSpace&path=relative"] {
            XCTAssertThrowsError(try FinderActionRequest(url: XCTUnwrap(URL(string: raw))), raw)
        }
    }
    func testPathPrefixCollisionAndMountRootCannotSelectAnItem() throws {
        let root = URL(fileURLWithPath: "/mount/drive")
        for path in ["/mount/drive-other/file", "/mount/drive", "/other/file"] {
            let request = try FinderActionRequest(action: .freeSpace, path: path)
            XCTAssertThrowsError(try request.relativeComponents(under: root))
        }
        XCTAssertEqual(try FinderActionRequest(url: XCTUnwrap(URL(string: "clouddrive://finder?action=activity"))).action, .activity)
    }
    func testMultipleSelectionsRoundTripAndLegacySingleAccessFailsClosed() throws {
        let request = try FinderActionRequest(action: .keepDownloaded, paths: ["/drive/Été/a%20.wav", "/drive/Other/file.txt"])
        let parsed = try FinderActionRequest(url: XCTUnwrap(request.url))
        XCTAssertEqual(parsed.paths, request.paths); XCTAssertNil(parsed.path)
        XCTAssertEqual(try parsed.relativeSelections(under: URL(fileURLWithPath: "/drive")), [["Été", "a%20.wav"], ["Other", "file.txt"]])
        XCTAssertThrowsError(try parsed.relativeComponents(under: URL(fileURLWithPath: "/drive")))
    }
    func testMultiselectionLimitsAndMixedQueryCannotHideAdditionalItems() throws {
        XCTAssertThrowsError(try FinderActionRequest(action: .freeSpace, paths: []))
        XCTAssertThrowsError(try FinderActionRequest(action: .freeSpace, paths: (0...32).map { "/drive/\($0)" }))
        XCTAssertThrowsError(try FinderActionRequest(action: .freeSpace, paths: ["/drive/a", "/drive/a"]))
        XCTAssertThrowsError(try FinderActionRequest(action: .freeSpace, paths: ["/drive/a", "/drive//a"]))
        XCTAssertThrowsError(try FinderActionRequest(action: .freeSpace, paths: (0..<10).map { "/drive/\($0)/" + String(repeating: "x", count: 2000) }))
        let url = try XCTUnwrap(URL(string: "clouddrive://finder?action=freeSpace&path=/drive/a&paths=%5B%22/drive/b%22%5D"))
        XCTAssertThrowsError(try FinderActionRequest(url: url))
        let outside = try FinderActionRequest(action: .freeSpace, paths: ["/drive/a", "/outside/b"])
        XCTAssertThrowsError(try outside.relativeSelections(under: URL(fileURLWithPath: "/drive")))
    }
}
