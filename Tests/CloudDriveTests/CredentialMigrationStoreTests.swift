import XCTest
@testable import CloudDrive

final class CredentialMigrationStoreTests: XCTestCase {
    private enum Failure: Error { case denied, failed }
    private final class Backend {
        var current: String?, legacy: String? = "original"
        var currentReads = 0, legacyReads = 0, adds = 0, writes = 0, authorizations = 0
        var failCurrentRead = false, failAdd = false, failAuthorization = false
        var failedReadback = false, corruptAdd = false, raceValue: String?
        func store() -> CredentialMigrationStore<String> {
            CredentialMigrationStore(
                readCurrent: { _ in
                    self.currentReads += 1
                    if self.failCurrentRead || (self.failedReadback && self.adds > 0) { throw Failure.denied }
                    return self.current
                },
                readLegacy: { _ in self.legacyReads += 1; return self.legacy },
                addCurrent: { value in
                    self.adds += 1
                    if self.failAdd { throw Failure.failed }
                    if let race = self.raceValue { self.current = race; return false }
                    guard self.current == nil else { return false }
                    self.current = self.corruptAdd ? "mismatch" : value; return true
                },
                writeCurrent: { value in self.writes += 1; self.current = value },
                authorizeCreation: { self.authorizations += 1; if self.failAuthorization { throw Failure.denied } }
            )
        }
    }
    func testCurrentValueWinsWithoutReadingLegacyOrWriting() throws {
        let backend = Backend(); backend.current = "newer"
        let value = try backend.store().load(allowInteraction: true)
        XCTAssertEqual(value, StoredCredential(value: "newer", persisted: true))
        XCTAssertEqual(backend.legacyReads, 0); XCTAssertEqual(backend.adds, 0)
    }
    func testDeniedCurrentDoesNotFallBackToOldConnection() {
        let backend = Backend(); backend.failCurrentRead = true
        XCTAssertThrowsError(try backend.store().load(allowInteraction: true))
        XCTAssertEqual(backend.legacyReads, 0); XCTAssertEqual(backend.adds, 0)
    }
    func testAutomaticLegacyReadDoesNotMigrateOrClaimPersistence() throws {
        let backend = Backend()
        let value = try backend.store().load(allowInteraction: false)
        XCTAssertEqual(value, StoredCredential(value: "original", persisted: false))
        XCTAssertNil(backend.current); XCTAssertEqual(backend.adds, 0); XCTAssertEqual(backend.authorizations, 0)
    }
    func testExplicitLegacyReadMigratesThenVerifiesWithoutChangingOldValue() throws {
        let backend = Backend()
        let value = try backend.store().load(allowInteraction: true)
        XCTAssertEqual(value, StoredCredential(value: "original", persisted: true))
        XCTAssertEqual(backend.current, "original"); XCTAssertEqual(backend.legacy, "original")
        XCTAssertEqual(backend.currentReads, 2); XCTAssertEqual(backend.adds, 1)
    }
    func testRacingCurrentValueWinsAndNeverGetsOverwrittenByLegacy() throws {
        let backend = Backend(); backend.raceValue = "authoritative"
        let value = try backend.store().load(allowInteraction: true)
        XCTAssertEqual(value?.value, "authoritative"); XCTAssertEqual(backend.current, "authoritative")
        XCTAssertEqual(backend.legacy, "original"); XCTAssertEqual(backend.writes, 0)
    }
    func testAddAndReadbackFailuresDoNotReturnPersistentSuccess() {
        let backend = Backend(); backend.failAdd = true
        XCTAssertThrowsError(try backend.store().load(allowInteraction: true))
        XCTAssertNil(backend.current); XCTAssertEqual(backend.legacy, "original")
        backend.failAdd = false; backend.failedReadback = true
        XCTAssertThrowsError(try backend.store().load(allowInteraction: true))
        XCTAssertEqual(backend.legacy, "original")
    }
    func testMismatchedReadbackIsNotPersistentSuccess() {
        let backend = Backend(); backend.corruptAdd = true
        XCTAssertThrowsError(try backend.store().load(allowInteraction: true))
        XCTAssertEqual(backend.legacy, "original")
    }
    func testAutomaticLegacyValueCannotSkipFirstCurrentSave() async throws {
        let backend = Backend(), store = backend.store()
        let session = CredentialSession<StoredCredential<String>>(
            read: { try store.load(allowInteraction: $0) },
            write: { try store.save($0.value) }, shouldCache: { $0.persisted })
        _ = try await session.load()
        try await session.save(StoredCredential(value: "original", persisted: true))
        XCTAssertEqual(backend.writes, 1)
        XCTAssertEqual(backend.current, "original"); XCTAssertEqual(backend.legacy, "original")
    }
    func testUnsignedCreationRefusedWithoutWritingEitherItem() {
        let backend = Backend(); backend.failAuthorization = true
        XCTAssertThrowsError(try backend.store().load(allowInteraction: true))
        XCTAssertThrowsError(try backend.store().save("changed"))
        XCTAssertEqual(backend.adds, 0); XCTAssertEqual(backend.writes, 0)
        XCTAssertEqual(backend.legacy, "original")
    }
    func testSaveOnlyChangesCurrentAndRequiresReadback() throws {
        let backend = Backend(); try backend.store().save("changed")
        XCTAssertEqual(backend.current, "changed"); XCTAssertEqual(backend.legacy, "original")
        backend.failCurrentRead = true
        XCTAssertThrowsError(try backend.store().save("unconfirmed"))
    }
    func testMissingBothItemsDoesNotCreateEmptyCredentials() throws {
        let backend = Backend(); backend.legacy = nil
        XCTAssertNil(try backend.store().load(allowInteraction: true))
        XCTAssertEqual(backend.adds, 0)
    }
    func testAutomaticLegacySessionDoesNotSkipLaterMigrationOrUnchangedSave() async throws {
        let backend = Backend(), store = backend.store()
        let session = CredentialSession<StoredCredential<String>>(
            read: { try store.load(allowInteraction: $0) },
            write: { try store.save($0.value) }, shouldCache: { $0.persisted })
        let auto = try await session.load()
        XCTAssertEqual(auto?.persisted, false)
        let explicit = try await session.load(allowInteraction: true)
        XCTAssertEqual(explicit?.persisted, true); XCTAssertEqual(backend.adds, 1)
        try await session.save(StoredCredential(value: "original", persisted: true))
        XCTAssertEqual(backend.writes, 0)
    }
    func testFailedMigrationDoesNotCacheLegacyValue() async throws {
        let backend = Backend(); backend.failAdd = true
        let store = backend.store()
        let session = CredentialSession<StoredCredential<String>>(
            read: { try store.load(allowInteraction: $0) },
            write: { try store.save($0.value) }, shouldCache: { $0.persisted })
        do { _ = try await session.load(allowInteraction: true); XCTFail("Expected failed migration") } catch {}
        backend.failAdd = false
        let value = try await session.load(allowInteraction: true)
        XCTAssertEqual(value?.persisted, true); XCTAssertEqual(backend.adds, 2)
        XCTAssertEqual(backend.legacy, "original")
    }
}
