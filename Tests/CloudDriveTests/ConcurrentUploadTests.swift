import XCTest
import SwiftUI
import AppKit
import CryptoKit
@testable import CloudDrive

private let concurrentConnection = Connection(endpoint: "https://concurrent-fixture.r2.cloudflarestorage.com", bucket: "fixture", prefix: "prefix", accessKey: "synthetic-access", secretKey: "synthetic-secret")

/// Cancellable synthetic transport. It keeps metadata only, never concatenates file payloads.
private actor ConcurrentRemote: SingleObjectRemote {
    private struct Session {
        let key: String
        let jobID: UUID
        var parts: [Int: RemoteUploadPart] = [:]
    }
    private var objects: [String: RemoteUploadObject] = [:]
    private var sessions: [String: Session] = [:]
    private var events: [String] = []
    private var putCounts: [String: Int] = [:]
    private var partCounts: [String: [Int: Int]] = [:]
    private var writingKeys: [String: Int] = [:]
    private var inFlight = 0
    private var peak = 0
    private var overlappingKeyWrites = 0
    private var delay: Duration
    private var perKeyDelay: [String: Duration] = [:]
    private var slowFirstPart: Duration?
    private var failingKey: String?
    init(delay: Duration = .milliseconds(30)) { self.delay = delay }
    func setDelay(_ value: Duration) { delay = value }
    func setDelay(_ value: Duration, key: String) { perKeyDelay[key] = value }
    func fail(key: String?) { failingKey = key }
    func delayFirstPart(_ value: Duration) { slowFirstPart = value }
    func metrics() -> (active: Int, peak: Int, duplicates: Int, puts: [String: Int], parts: [String: [Int: Int]], events: [String]) {
        (inFlight, peak, overlappingKeyWrites, putCounts, partCounts, events)
    }
    func object(for key: String) -> RemoteUploadObject? { objects[key] }
    private func entered(_ key: String, label: String) {
        inFlight += 1; peak = max(peak, inFlight)
        writingKeys[key, default: 0] += 1
        events.append("start:" + label)
    }
    private func left(_ key: String, label: String) {
        writingKeys[key, default: 0] -= 1
        inFlight -= 1; events.append("end:" + label)
    }
    func head(key: String) async throws -> RemoteUploadObject? { objects[key] }
    func create(key: String, jobID: UUID) async throws -> String {
        let id = jobID.uuidString
        sessions[id] = .init(key: key, jobID: jobID)
        return id
    }
    func list(key: String, uploadID: String) async throws -> [RemoteUploadPart] {
        guard let session = sessions[uploadID], session.key == key else { throw MultipartRemoteError.expired }
        return session.parts.values.sorted { $0.number < $1.number }
    }
    func putPart(key: String, uploadID: String, number: Int, data: Data, md5: String) async throws -> String {
        let label = "\(key):part:\(number)"
        entered(key, label: label)
        defer { left(key, label: label) }
        partCounts[key, default: [:]][number, default: 0] += 1
        try await Task.sleep(for: number == 1 ? (slowFirstPart ?? delay) : delay)
        try Task.checkCancellation()
        guard Insecure.MD5.hash(data: data).hex == md5 else { throw MultipartRemoteError.checksumMismatch }
        guard var session = sessions[uploadID], session.key == key else { throw MultipartRemoteError.expired }
        session.parts[number] = .init(number: number, etag: md5, size: Int64(data.count))
        sessions[uploadID] = session
        return md5
    }
    func complete(key: String, uploadID: String, parts: [ConfirmedUploadPart]) async throws {
        guard let session = sessions[uploadID], session.key == key else { throw MultipartRemoteError.expired }
        var digests = Data(), size: Int64 = 0
        for part in parts.sorted(by: { $0.number < $1.number }) {
            guard let saved = session.parts[part.number], saved.etag == part.etag, saved.size == part.size,
                  let digest = Data(hex: part.md5) else { throw MultipartRemoteError.checksumMismatch }
            digests.append(digest); size += part.size
        }
        objects[key] = .init(size: size, etag: Insecure.MD5.hash(data: digests).hex + "-\(parts.count)", jobID: session.jobID.uuidString)
    }
    func putObject(key: String, jobID: UUID, data: Data, md5: String) async throws {
        if writingKeys[key, default: 0] > 0 { overlappingKeyWrites += 1 }
        entered(key, label: key)
        defer { left(key, label: key) }
        putCounts[key, default: 0] += 1
        try await Task.sleep(for: perKeyDelay[key] ?? delay)
        try Task.checkCancellation()
        if failingKey == key { throw MultipartRemoteError.http(503) }
        guard objects[key] == nil else { throw MultipartRemoteError.http(412) }
        guard Insecure.MD5.hash(data: data).hex == md5 else { throw MultipartRemoteError.checksumMismatch }
        objects[key] = .init(size: Int64(data.count), etag: md5, jobID: jobID.uuidString)
    }
    func putEmpty(key: String, jobID: UUID) async throws {
        objects[key] = .init(size: 0, etag: Insecure.MD5.hash(data: Data()).hex, jobID: jobID.uuidString)
    }
    func abort(key: String, uploadID: String) async throws { sessions.removeValue(forKey: uploadID) }
}

private actor AppendDuringBatch {
    let source: URL
    private var appended = false
    private var failed = false
    init(source: URL) { self.source = source }
    func update(engine: DirectUploadEngine, jobs: [DirectUploadJob]) async {
        guard !appended, jobs.contains(where: { $0.status == .uploading }) else { return }
        appended = true
        do { _ = try await engine.enqueue(urls: [source], connection: concurrentConnection, excluded: []) }
        catch { failed = true }
    }
    func result() -> (Bool, Bool) { (appended, failed) }
}

private actor SlowQueueObserver {
    private var entered = false
    private var states: [UploadQueueState] = []
    func receive(_ state: UploadQueueState) async {
        let first = !entered
        entered = true
        if first { try? await Task.sleep(for: .milliseconds(80)) }
        states.append(state)
    }
    func hasEntered() -> Bool { entered }
    func snapshots() -> [UploadQueueState] { states }
}

final class ConcurrentUploadTests: XCTestCase {
    private var root: URL!
    private var records: URL { root.appendingPathComponent("records") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("concurrent-upload-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func makeJob(size: Int = 4096, partSize: Int64 = 64 * 1_048_576) throws -> DirectUploadJob {
        let file = root.appendingPathComponent(UUID().uuidString + ".bin")
        try Data(repeating: 0x5b, count: size).write(to: file)
        return DirectUploadJob(batchID: UUID(), sourcePath: file.path, source: try UploadSourceIdentity.capture(file),
                               destination: concurrentConnection.fingerprint, key: "prefix/" + file.lastPathComponent, partSize: partSize)
    }
    private func makeEngine(with jobs: [DirectUploadJob]) async throws -> DirectUploadEngine {
        try UploadQueueStore(directory: records).insert(jobs)
        let engine = DirectUploadEngine(); _ = try await engine.open(directory: records)
        return engine
    }
    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw DirectUploadFailure.message("Synthetic concurrent fixture timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor func testActualControllerKeepsUploadingWhileNativeSidebarViewsSwitch() async throws {
        _ = NSApplication.shared
        let jobs = try (0..<8).map { _ in try makeJob() }
        try UploadQueueStore(directory: records).insert(jobs)
        let remote = ConcurrentRemote(delay: .milliseconds(300))
        let controller = DirectUploadController(defaultDirectory: records, rememberLocation: false, makeUploadRemote: { _ in remote })
        await controller.restoreIfNeeded()
        controller.canStart = { true }
        let drive = Drive(root: root.appendingPathComponent("sidebar-state"), binary: URL(fileURLWithPath: "/nonexistent-preview-backend"),
                          helper: URL(fileURLWithPath: "/nonexistent-preview-helper"), useKeychain: false, autoRecover: false)
        drive.connection = concurrentConnection
        drive.directUploads = controller
        let navigation = DashboardNavigation()
        let host = NSHostingView(rootView: ContentView(drive: drive, navigation: navigation).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        controller.resume(connection: concurrentConnection)
        try await until { await remote.metrics().active > 0 }
        for destination in [DashboardDestination.uploads, .drive, .uploads, .drive] {
            navigation.destination = destination
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertTrue(controller.isActive, "Changing sidebar views must not pause the live controller")
            XCTAssertTrue(drive.directUploads === controller)
        }
        try await until { await MainActor.run { !controller.isActive } }
        XCTAssertEqual(controller.jobs.count, 8)
        XCTAssertTrue(controller.jobs.allSatisfy { $0.status == .uploaded })
        let metrics = await remote.metrics()
        XCTAssertEqual(metrics.puts.count, 8)
        XCTAssertTrue(metrics.puts.values.allSatisfy { $0 == 1 }, "Switching views must not restart completed requests")
        XCTAssertEqual(metrics.duplicates, 0)
        await controller.relinquishForTesting()
    }

    func testIndependentFilesOverlapAndRespectFileConcurrencyLimit() async throws {
        let jobs = try (0..<10).map { _ in try makeJob() }, remote = ConcurrentRemote(delay: .milliseconds(50))
        let engine = try await makeEngine(with: jobs)
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 4) { _ in }
        let metrics = await remote.metrics(), snapshot = await engine.snapshot()
        XCTAssertGreaterThan(metrics.peak, 1); XCTAssertLessThanOrEqual(metrics.peak, 4)
        XCTAssertEqual(metrics.active, 0); XCTAssertEqual(metrics.duplicates, 0)
        XCTAssertEqual(metrics.puts.count, jobs.count); XCTAssertTrue(metrics.puts.values.allSatisfy { $0 == 1 })
        XCTAssertTrue(snapshot.allSatisfy { $0.status == .uploaded && $0.verifiedAt != nil })
    }

    func testPauseDrainsAllRequestsAndLeavesEveryInFlightFileResumable() async throws {
        let jobs = try (0..<7).map { _ in try makeJob() }, remote = ConcurrentRemote(delay: .seconds(20))
        let engine = try await makeEngine(with: jobs)
        let task = Task { try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 3) { _ in } }
        defer { task.cancel() }
        try await until { await remote.metrics().active == 3 }
        task.cancel(); _ = try? await task.value
        let paused = await engine.snapshot(), stopped = await remote.metrics()
        XCTAssertEqual(stopped.active, 0)
        XCTAssertTrue(paused.allSatisfy { $0.status == .paused || $0.status == .waiting })
        XCTAssertEqual(paused.filter { $0.status == .paused }.count, 3)
        XCTAssertTrue(paused.filter { $0.status == .paused }.allSatisfy { $0.singlePutMD5 != nil })
        await remote.setDelay(.milliseconds(5))
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 3) { _ in }
        let resumed = await engine.snapshot()
        XCTAssertTrue(resumed.allSatisfy { $0.status == .uploaded })
    }

    func testResumeKeepsCompletedFilesAndDoesNotUploadThemAgain() async throws {
        let jobs = try (0..<5).map { _ in try makeJob() }, remote = ConcurrentRemote(delay: .seconds(20))
        await remote.setDelay(.milliseconds(5), key: jobs[0].key)
        let engine = try await makeEngine(with: jobs)
        let task = Task { try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { _ in } }
        defer { task.cancel() }
        try await until {
            let snapshot = await engine.snapshot()
            return snapshot.contains { $0.id == jobs[0].id && $0.status == .uploaded }
        }
        task.cancel(); _ = try? await task.value
        await remote.setDelay(.milliseconds(5))
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { _ in }
        let metrics = await remote.metrics(), snapshot = await engine.snapshot()
        XCTAssertEqual(metrics.puts[jobs[0].key], 1)
        XCTAssertTrue(snapshot.allSatisfy { $0.status == .uploaded })
    }

    func testFailureDoesNotCancelOtherFilesAndIsReportedAfterBatchDrains() async throws {
        let jobs = try (0..<4).map { _ in try makeJob() }, remote = ConcurrentRemote(delay: .milliseconds(30))
        await remote.fail(key: jobs[0].key)
        let engine = try await makeEngine(with: jobs)
        do {
            try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 3) { _ in }
            XCTFail("The batch must report the failed upload")
        } catch MultipartRemoteError.http(503) { }
        let metrics = await remote.metrics(), snapshot = await engine.snapshot()
        XCTAssertEqual(metrics.active, 0)
        XCTAssertEqual(snapshot.first { $0.id == jobs[0].id }?.status, .attention)
        XCTAssertFalse(snapshot.contains { $0.status == .uploading || $0.status == .checking })
        XCTAssertTrue(snapshot.filter { $0.id != jobs[0].id }.allSatisfy { $0.status == .uploaded })
    }

    func testConcurrentMultipartRestartSkipsEachFilesConfirmedParts() async throws {
        let jobs = try (0..<2).map { _ in try makeJob(size: 15 * 1_048_576 + 17, partSize: 5 * 1_048_576) }
        let engine = try await makeEngine(with: jobs), remote = ConcurrentRemote(delay: .seconds(20))
        await remote.delayFirstPart(.milliseconds(5))
        let task = Task { try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { _ in } }
        defer { task.cancel() }
        try await until {
            let snapshot = await engine.snapshot()
            return snapshot.count == 2 && snapshot.allSatisfy { $0.parts.contains { $0.number == 1 } }
        }
        task.cancel(); _ = try? await task.value
        let interrupted = await engine.snapshot(), pausedMetrics = await remote.metrics()
        XCTAssertEqual(pausedMetrics.active, 0)
        XCTAssertTrue(interrupted.allSatisfy { $0.uploadID != nil && $0.status == .paused })
        await engine.closeForTesting()
        let restarted = DirectUploadEngine(); _ = try await restarted.open(directory: records)
        await remote.setDelay(.milliseconds(5))
        try await restarted.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { _ in }
        let metrics = await remote.metrics(), finished = await restarted.snapshot()
        XCTAssertTrue(finished.allSatisfy { $0.status == .uploaded && $0.verifiedAt != nil })
        for job in jobs { XCTAssertEqual(metrics.parts[job.key]?[1], 1) }
    }

    func testBatchExcludesForeignDestinations() async throws {
        let local = try makeJob(); var foreign = try makeJob()
        foreign.destination = String(repeating: "a", count: 64)
        let engine = try await makeEngine(with: [local, foreign]), remote = ConcurrentRemote()
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint) { _ in }
        let snapshot = await engine.snapshot(), metrics = await remote.metrics()
        XCTAssertEqual(snapshot.first { $0.id == local.id }?.status, .uploaded)
        XCTAssertEqual(snapshot.first { $0.id == foreign.id }?.status, .waiting)
        XCTAssertNil(metrics.puts[foreign.key])
    }

    func testFilesAddedDuringBatchArePickedUpWithoutAnotherResume() async throws {
        let first = try makeJob(), next = try makeJob(), engine = try await makeEngine(with: [first])
        let append = AppendDuringBatch(source: URL(fileURLWithPath: next.sourcePath)), remote = ConcurrentRemote()
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { snapshot in
            await append.update(engine: engine, jobs: snapshot)
        }
        let result = await append.result(), snapshot = await engine.snapshot()
        XCTAssertTrue(result.0); XCTAssertFalse(result.1)
        XCTAssertEqual(snapshot.count, 2); XCTAssertTrue(snapshot.allSatisfy { $0.status == .uploaded })
    }

    func testSlowStateObserverAndConcurrentEnqueuePublishMonotonicCompleteState() async throws {
        let initialJobs = try (0..<3).map { _ in try makeJob() }, added = try makeJob()
        let engine = try await makeEngine(with: initialJobs), remote = ConcurrentRemote(), observer = SlowQueueObserver()
        let initialState = await engine.snapshotState()
        let task = Task {
            try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 3,
                                      stateUpdate: { state in await observer.receive(state) }) { _ in }
        }
        defer { task.cancel() }
        try await until { await observer.hasEntered() }
        let before = await engine.snapshotState()
        _ = try await engine.enqueue(urls: [URL(fileURLWithPath: added.sourcePath)], connection: concurrentConnection, excluded: [])
        let afterEnqueue = await engine.snapshotState()
        XCTAssertGreaterThan(afterEnqueue.revision, before.revision)
        try await task.value
        let finalState = await engine.snapshotState(), observed = await observer.snapshots()
        XCTAssertGreaterThan(finalState.revision, initialState.revision)
        XCTAssertEqual(finalState.jobs.count, 4)
        XCTAssertTrue(finalState.jobs.allSatisfy { $0.status == .uploaded })
        XCTAssertGreaterThan(observed.count, 1)
        XCTAssertTrue(zip(observed, observed.dropFirst()).allSatisfy { pair in pair.0.revision <= pair.1.revision })
        let latest = try XCTUnwrap(observed.last)
        XCTAssertEqual(latest.revision, finalState.revision)
        XCTAssertEqual(Set(latest.jobs.map(\.id)), Set(finalState.jobs.map(\.id)))
        XCTAssertTrue(latest.jobs.allSatisfy { $0.status == .uploaded })
    }

    func testSnapshotRevisionAdvancesAfterEachQueueMutation() async throws {
        let first = try makeJob(), second = try makeJob(), engine = try await makeEngine(with: [first])
        let opened = await engine.snapshotState(), unchanged = await engine.snapshotState()
        XCTAssertEqual(opened.revision, unchanged.revision)
        _ = try await engine.enqueue(urls: [URL(fileURLWithPath: second.sourcePath)], connection: concurrentConnection, excluded: [])
        let enqueued = await engine.snapshotState()
        XCTAssertEqual(enqueued.revision, opened.revision + 1)
        _ = try await engine.cancel(id: first.id, remote: ConcurrentRemote(), destination: concurrentConnection.fingerprint)
        let cancelled = await engine.snapshotState()
        XCTAssertEqual(cancelled.revision, enqueued.revision + 1)
        _ = try await engine.clearFinished()
        let cleared = await engine.snapshotState()
        XCTAssertEqual(cleared.revision, cancelled.revision + 1)
        XCTAssertEqual(cleared.jobs.count, 1)
    }

    func testControlAndStandaloneRunsCannotInterfereWithAnActiveBatch() async throws {
        let jobs = try (0..<3).map { _ in try makeJob() }, engine = try await makeEngine(with: jobs), remote = ConcurrentRemote(delay: .seconds(20))
        let task = Task { try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { _ in } }
        defer { task.cancel() }
        try await until { await remote.metrics().active == 2 }
        do { _ = try await engine.open(directory: records); XCTFail("Cannot reopen during batch") } catch is DirectUploadFailure { }
        do { try await engine.run(id: jobs[2].id, remote: remote, destination: concurrentConnection.fingerprint) { _ in }; XCTFail("Cannot start unrelated run") } catch is DirectUploadFailure { }
        do { _ = try await engine.cancel(id: jobs[2].id, remote: remote, destination: concurrentConnection.fingerprint); XCTFail("Cannot change queue during batch") } catch is DirectUploadFailure { }
        do { _ = try await engine.clearFinished(); XCTFail("Cannot clear queue during batch") } catch is DirectUploadFailure { }
        task.cancel(); _ = try? await task.value
        let metrics = await remote.metrics(); XCTAssertEqual(metrics.active, 0)
    }

    func testSameDestinationKeysAreSerializedAndKeptBoth() async throws {
        let first = try makeJob(); var second = try makeJob(); second.key = first.key
        let engine = try await makeEngine(with: [first, second]), remote = ConcurrentRemote(delay: .milliseconds(50))
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 2) { _ in }
        let metrics = await remote.metrics(), snapshot = await engine.snapshot()
        XCTAssertEqual(metrics.duplicates, 0)
        XCTAssertTrue(snapshot.allSatisfy { $0.status == .uploaded })
        XCTAssertEqual(Set(snapshot.map(\.key)).count, 2)
    }

    func testMultipartPipelineRefillsAnAvailableSlotBeforeSlowPartFinishes() async throws {
        let job = try makeJob(size: 25 * 1_048_576 + 11, partSize: 5 * 1_048_576)
        let engine = try await makeEngine(with: [job]), remote = ConcurrentRemote(delay: .milliseconds(10))
        await remote.delayFirstPart(.milliseconds(250))
        try await engine.runBatch(remote: remote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 1) { _ in }
        let metrics = await remote.metrics(), snapshot = await engine.snapshot()
        let fifthStart = try XCTUnwrap(metrics.events.firstIndex(of: "start:\(job.key):part:5"))
        let firstEnd = try XCTUnwrap(metrics.events.firstIndex(of: "end:\(job.key):part:1"))
        XCTAssertLessThan(fifthStart, firstEnd)
        XCTAssertLessThanOrEqual(metrics.peak, 4)
        XCTAssertEqual(metrics.parts[job.key]?.count, 6)
        XCTAssertTrue(metrics.parts[job.key]?.values.allSatisfy { $0 == 1 } == true)
        XCTAssertEqual(snapshot[0].status, .uploaded)
    }

    func testSyntheticLatencyBenchmarkComparesSerialAndConcurrentFiles() async throws {
        let jobs = try (0..<8).map { _ in try makeJob() }, serial = try await makeEngine(with: jobs)
        let parallelRecords = root.appendingPathComponent("parallel-records")
        try UploadQueueStore(directory: parallelRecords).insert(jobs)
        let parallel = DirectUploadEngine(); _ = try await parallel.open(directory: parallelRecords)
        let serialRemote = ConcurrentRemote(delay: .milliseconds(25)), parallelRemote = ConcurrentRemote(delay: .milliseconds(25))
        let began = Date()
        try await serial.runBatch(remote: serialRemote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 1) { _ in }
        let serialSeconds = Date().timeIntervalSince(began), parallelBegan = Date()
        try await parallel.runBatch(remote: parallelRemote, destination: concurrentConnection.fingerprint, maxConcurrentFiles: 4) { _ in }
        let parallelSeconds = Date().timeIntervalSince(parallelBegan)
        let serialMetrics = await serialRemote.metrics(), parallelMetrics = await parallelRemote.metrics()
        let serialSnapshot = await serial.snapshot(), parallelSnapshot = await parallel.snapshot()
        XCTAssertEqual(serialMetrics.peak, 1); XCTAssertGreaterThan(parallelMetrics.peak, 1); XCTAssertLessThanOrEqual(parallelMetrics.peak, 4)
        XCTAssertTrue(serialSnapshot.allSatisfy { $0.status == .uploaded })
        XCTAssertTrue(parallelSnapshot.allSatisfy { $0.status == .uploaded })
        // Timing is illustrative only. Deterministic assertions cover overlap, the cap and final receipts.
        print(String(format: "Synthetic 25ms per PUT, 8 files: serial %.3fs; 4 concurrent %.3fs", serialSeconds, parallelSeconds))
    }
}
