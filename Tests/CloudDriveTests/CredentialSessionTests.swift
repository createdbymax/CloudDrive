import XCTest
@testable import CloudDrive

final class CredentialSessionTests: XCTestCase {
    private enum FakeError: Error { case refused }
    private struct Secret: Equatable { let destination: String; let key: String }
    private final class Backend: @unchecked Sendable {
        let lock = NSLock()
        var value: Secret? = Secret(destination: "fixture", key: "first")
        var reads = 0, writes = 0
        var failRead = false, failWrite = false
        var gate: DispatchSemaphore?
        let started = DispatchSemaphore(value: 0)
        func read(_ interactive: Bool) throws -> Secret? {
            lock.lock(); reads += 1; let gate = gate; let failed = failRead; let value = value; lock.unlock()
            started.signal(); gate?.wait()
            if failed { throw FakeError.refused }; return value
        }
        func write(_ value: Secret) throws {
            lock.lock(); writes += 1; let failed = failWrite; if !failed { self.value = value }; lock.unlock()
            if failed { throw FakeError.refused }
        }
        var counts: (reads: Int, writes: Int) { lock.lock(); defer { lock.unlock() }; return (reads, writes) }
        func session() -> CredentialSession<Secret> { CredentialSession(read: read, write: write) }
    }
    private func waitForNative(_ session: CredentialSession<Secret>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.isPending && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertFalse(session.isPending)
    }
    func testQueuedExpiredRequestNeverStartsNativeRead() async throws {
        let backend = Backend(), queue = DispatchQueue(label: "credential-fixture-expired")
        queue.suspend(); var suspended = true
        defer { if suspended { queue.resume() } }
        let session = CredentialSession(read: backend.read, write: backend.write, executionQueue: queue)
        do { _ = try await session.load(allowInteraction: true, timeout: 0.02); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .timedOut) }
        XCTAssertTrue(session.isPending)
        queue.resume(); suspended = false
        try await waitForNative(session)
        XCTAssertEqual(backend.counts.reads, 0)
    }
    func testQueuedCancelledRequestNeverStartsNativeWrite() async throws {
        let backend = Backend(), queue = DispatchQueue(label: "credential-fixture-cancelled")
        queue.suspend(); var suspended = true
        defer { if suspended { queue.resume() } }
        let session = CredentialSession(read: backend.read, write: backend.write, executionQueue: queue)
        let task = Task { try await session.save(Secret(destination: "fixture", key: "new")) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !session.isPending && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .cancelled) }
        queue.resume(); suspended = false
        try await waitForNative(session)
        XCTAssertEqual(backend.counts.writes, 0)
    }
    func testSuccessfulReadIsReusedAndUnchangedWriteDoesNotTouchBackend() async throws {
        let backend = Backend(), session: CredentialSession<Secret>
        session = backend.session()
        let loaded = try await session.load(allowInteraction: true)
        let value = try XCTUnwrap(loaded)
        let again = try await session.load()
        XCTAssertEqual(again, value)
        try await session.save(value)
        XCTAssertEqual(backend.counts.reads, 1); XCTAssertEqual(backend.counts.writes, 0)
    }
    func testChangedSecretCannotSkipWriteAndSuccessfulSaveIsCached() async throws {
        let backend = Backend(), session = backend.session()
        _ = try await session.load()
        let rotated = Secret(destination: "fixture", key: "changed")
        try await session.save(rotated)
        let loadedRotated = try await session.load()
        XCTAssertEqual(loadedRotated, rotated)
        try await session.save(rotated)
        XCTAssertEqual(backend.counts.reads, 1); XCTAssertEqual(backend.counts.writes, 1)
    }
    func testReadAndWriteErrorsDoNotCreateFalseCachedSuccess() async throws {
        let backend = Backend(); backend.failRead = true
        let session = backend.session()
        do { _ = try await session.load(); XCTFail("Expected refusal") } catch {}
        backend.failRead = false
        let original = try await session.load()
        backend.failWrite = true
        do { try await session.save(Secret(destination: "fixture", key: "changed")); XCTFail("Expected refusal") } catch {}
        let loadedOriginal = try await session.load()
        XCTAssertEqual(loadedOriginal, original)
        XCTAssertEqual(backend.counts.reads, 3)
    }
    func testLateInteractiveApprovalIsConsumedOnlyByExplicitLoad() async throws {
        let backend = Backend(); let gate = DispatchSemaphore(value: 0); backend.gate = gate
        let session = backend.session()
        do { _ = try await session.load(allowInteraction: true, timeout: 0.03); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .timedOut) }
        XCTAssertTrue(session.isPending)
        do { _ = try await session.load(); XCTFail("Expected existing OS request") }
        catch { XCTAssertEqual(String(describing: error), String(describing: CredentialFailure.operationPending)) }
        gate.signal(); try await waitForNative(session)
        do { _ = try await session.load(); XCTFail("Automatic load must not consume a late approval") }
        catch { XCTAssertEqual(String(describing: error), String(describing: CredentialFailure.authorizationNeeded)) }
        let approved = try await session.load(allowInteraction: true)
        XCTAssertEqual(approved, Secret(destination: "fixture", key: "first"))
        XCTAssertEqual(backend.counts.reads, 1)
        let reused = try await session.load()
        XCTAssertEqual(reused, approved)
    }
    func testCancellationDiscardsLateApproval() async throws {
        let backend = Backend(); let gate = DispatchSemaphore(value: 0); backend.gate = gate
        let session = backend.session()
        let task = Task { try await session.load(allowInteraction: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while backend.counts.reads < 1 && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .cancelled) }
        gate.signal(); try await waitForNative(session)
        backend.gate = nil
        _ = try await session.load(allowInteraction: true)
        XCTAssertEqual(backend.counts.reads, 2)
    }
    func testClearMemoryForgetsCachedCredentialsAndDiscardsPendingResult() async throws {
        let backend = Backend(), session = backend.session()
        _ = try await session.load(); session.clearMemory(); _ = try await session.load()
        XCTAssertEqual(backend.counts.reads, 2)
        session.clearMemory()
        let gate = DispatchSemaphore(value: 0); backend.gate = gate
        let task = Task { try await session.load(allowInteraction: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while backend.counts.reads < 3 && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        session.clearMemory(); gate.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        try await waitForNative(session); backend.gate = nil
        _ = try await session.load()
        XCTAssertEqual(backend.counts.reads, 4)
    }
}
