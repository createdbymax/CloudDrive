import XCTest
@testable import CloudDriveCore

private actor SpillPackRemote: StorageRemote {
    private var objects: [String: (StorageObject, Data)] = [:]
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var started = 0
    private var active = 0
    private var peak = 0
    private var sizes: [Int] = []
    private var keys: [Int: String] = [:]
    private var corrupt: Set<String> = []
    private var automatic = false
    private var observations: [(Int, XCTestExpectation)] = []
    func expectStarts(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Spill packs started: \(count)")
        if started >= count { expectation.fulfill() } else { observations.append((count, expectation)) }
        return expectation
    }
    func put(key: String, data: Data, condition: StorageCondition, operationID: UUID) async throws -> StorageObject {
        started += 1; active += 1; peak = max(peak, active); sizes.append(data.count)
        let number = started; keys[number] = key
        let ready = observations.filter { started >= $0.0 }; observations.removeAll { started >= $0.0 }
        for (_, observation) in ready { observation.fulfill() }
        if !automatic { await withCheckedContinuation { gates[number] = $0 } }
        defer { active -= 1 }
        guard objects[key] == nil else { throw StorageFailure.conflict }
        let object = StorageObject(key: key, size: Int64(data.count), validator: "pack-\(number)", checksum: CoreFileIO.hash(data), operationID: operationID)
        objects[key] = (object, data)
        return object
    }
    func release(_ number: Int, corruptVerification: Bool = false) {
        if corruptVerification, let key = keys[number] { corrupt.insert(key) }
        gates.removeValue(forKey: number)?.resume()
    }
    func releaseAll() { automatic = true; let held = gates.values; gates.removeAll(); for gate in held { gate.resume() } }
    func counters() -> (started: Int, peak: Int, sizes: [Int]) { (started, peak, sizes) }
    func head(key: String) -> StorageObject? { objects[key]?.0 }
    func read(key: String, range: Range<Int64>, validator: String) throws -> StorageRange {
        guard let (object, data) = objects[key], object.validator == validator else { throw StorageFailure.notFound }
        let bytes = corrupt.contains(key) ? Data(repeating: 0, count: range.count) : data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        return StorageRange(data: bytes, offset: range.lowerBound, totalSize: object.size, validator: validator)
    }
    func copy(source: String, destination: String, sourceValidator: String, operationID: UUID) throws -> StorageObject { throw StorageFailure.unsupported }
    func delete(key: String, validator: String) throws { throw StorageFailure.unsupported }
    func list(prefix: String, cursor: String?, limit: Int) throws -> StoragePage { throw StorageFailure.unsupported }
}

final class ParallelSpillPackingTests: XCTestCase {
    private struct PackReceipt: Codable {
        struct Member: Codable { let id: UUID; let length: Int; let checksum: String }
        let validator: String?
        let members: [Member]?
    }
    private let mib = 1024 * 1024
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("parallel-spill-" + UUID().uuidString) }
    private func append(_ value: UInt8, store: ContentStore, remote: SpillPackRemote) async throws -> ContentSnapshot {
        try await store.prepareManagedWrite(nodeID: UUID(), fromGeneration: 0, toGeneration: 1, logicalSize: 0, base: nil,
            previousSnapshotID: nil, offset: 0, data: Data(repeating: value, count: mib), mutationFingerprint: nil, prefix: "Drive", remote: remote)
    }
    private func waitForState(_ store: ContentStore, failed: Bool = false, idle: Bool = false) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let status = await store.packingStatusForTesting()
            if (!failed || status.failed) && (!idle || (status.active == 0 && status.pendingRefills == 0)) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Spill packing did not reach expected state")
    }
    private func verify(_ snapshots: [ContentSnapshot], store: ContentStore, remote: SpillPackRemote) async throws {
        for (index, saved) in snapshots.enumerated() {
            let snapshot = try await store.snapshot(id: saved.id)
            var bytes = Data(repeating: 0, count: mib)
            let holes = try await store.overlay(snapshot: snapshot, range: 0..<Int64(mib), into: &bytes, remote: remote, prefix: "Drive")
            XCTAssertTrue(holes.isEmpty)
            XCTAssertEqual(bytes, Data(repeating: UInt8(index + 1), count: mib))
        }
    }

    func testExtentIndexClosesBeforeReplacementAndCloseIsIdempotent() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try CoreFileIO.privateDirectory(dir)
        let extent = ContentExtent(offset: 0, length: 4096, fileID: UUID(), storedLength: 4096, fileOffset: 0, checksum: String(repeating: "a", count: 64))
        let original = try ManagedExtentIndex(dir)
        let root = try XCTUnwrap(original.build(extents: [extent]))
        original.close(); original.close()
        // Keep the old object alive while replacement connections open: close()
        // must actually relinquish SQLite/WAL resources before owner-lock release.
        for _ in 0..<12 {
            let replacement = try ManagedExtentIndex(dir)
            XCTAssertEqual(try replacement.read(root: root, range: 0..<4096), [extent])
            replacement.close()
        }
    }

    func testFourDisjointPacksAndAnyCompletionReleaseHighWaterAdmission() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = SpillPackRemote()
        var store: ContentStore? = try ContentStore(directory: dir, maximumBytes: Int64(64 * mib))
        var snapshots: [ContentSnapshot] = []
        for value in 1...64 { snapshots.append(try await append(UInt8(value), store: store!, remote: remote)) }
        await fulfillment(of: [remote.expectStarts(4)], timeout: 5)
        var status = await store!.packingStatusForTesting()
        XCTAssertEqual(status.active, 4); XCTAssertEqual(status.selectedBytes, Int64(32 * mib))
        let admission = XCTestExpectation(description: "Next local write admitted before first pack completes")
        let extra = Task { [current = store!] in
            let snapshot = try await self.append(65, store: current, remote: remote)
            admission.fulfill(); return snapshot
        }
        await remote.release(2)
        await fulfillment(of: [admission, remote.expectStarts(5)], timeout: 5)
        snapshots.append(try await extra.value)
        status = await store!.packingStatusForTesting()
        XCTAssertLessThanOrEqual(status.active, 4); XCTAssertLessThanOrEqual(status.selectedBytes, Int64(32 * mib))
        let accounting = await store!.accounting()
        XCTAssertLessThanOrEqual(accounting.dirtyBytes, Int64(64 * mib))
        await remote.releaseAll(); await waitForState(store!, idle: true)
        let counters = await remote.counters()
        XCTAssertEqual(counters.peak, 4)
        XCTAssertTrue(counters.sizes.allSatisfy { $0 == 8 * mib }, "Background refill must not turn trailing 1 MiB writes into tiny packs")
        // A crash after the validator receipt but midway through unlink can
        // leave redundant local members. Recreate that exact on-disk shape.
        let receipts = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("writeback"), includingPropertiesForKeys: nil)
        let receipt = try CoreFileIO.readChecked(PackReceipt.self, at: XCTUnwrap(receipts.first), maximum: 128 * 1024)
        let member = try XCTUnwrap(receipt.members?.first)
        XCTAssertNotNil(receipt.validator)
        let value = try XCTUnwrap((1...65).first { CoreFileIO.hash(Data(repeating: UInt8($0), count: member.length)) == member.checksum })
        let leftover = dir.appendingPathComponent("extents/" + member.id.uuidString)
        try Data(repeating: UInt8(value), count: member.length).write(to: leftover)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leftover.path)
        // All tasks have settled before dropping the owner. Both remotely packed
        // and still-local tail data must survive ordinary cold reconstruction.
        store = nil
        let reopened = try ContentStore(directory: dir, maximumBytes: Int64(64 * mib))
        try await verify(snapshots, store: reopened, remote: remote)
        let reopenedUsage = await reopened.accounting()
        let localFiles = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("extents"), includingPropertiesForKeys: nil)
        XCTAssertEqual(reopenedUsage.dirtyBytes, try localFiles.reduce(Int64(0)) { try $0 + CoreFileIO.allocatedSize($1) })
    }

    func testFailedVerificationRetainsLocalMembersAndRequeuesWithoutDuplicateReceipts() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = SpillPackRemote()
        var store: ContentStore? = try ContentStore(directory: dir, maximumBytes: Int64(64 * mib))
        var snapshots: [ContentSnapshot] = []
        for value in 1...64 { snapshots.append(try await append(UInt8(value), store: store!, remote: remote)) }
        await fulfillment(of: [remote.expectStarts(4)], timeout: 5)
        await remote.release(1, corruptVerification: true)
        await waitForState(store!, failed: true)
        let failed = await store!.packingStatusForTesting(), usage = await store!.accounting()
        XCTAssertEqual(failed.active, 3); XCTAssertEqual(usage.dirtyBytes, Int64(64 * mib))
        XCTAssertGreaterThanOrEqual(failed.queued, 8)
        do { _ = try await append(65, store: store!, remote: remote); XCTFail("Pressure must report failed verification") }
        catch { XCTAssertEqual(error as? StorageFailure, .integrity) }
        await remote.releaseAll(); await waitForState(store!, idle: true)
        let finalUsage = await store!.accounting(), counters = await remote.counters()
        XCTAssertLessThanOrEqual(finalUsage.dirtyBytes, Int64(64 * mib)); XCTAssertLessThanOrEqual(counters.peak, 4)
        store = nil
        let reopened = try ContentStore(directory: dir, maximumBytes: Int64(64 * mib))
        try await verify(snapshots, store: reopened, remote: remote)
    }

    func testLimitedQuotaCanFlushPartialPackWithoutExceedingLocalBudget() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let remote = SpillPackRemote(); await remote.releaseAll()
        let store = try ContentStore(directory: dir, maximumBytes: 256 * 1024)
        var snapshots: [ContentSnapshot] = []
        for value in 1...3 {
            snapshots.append(try await store.prepareManagedWrite(nodeID: UUID(), fromGeneration: 0, toGeneration: 1,
                logicalSize: 0, base: nil, previousSnapshotID: nil, offset: 0, data: Data(repeating: UInt8(value), count: 128 * 1024),
                mutationFingerprint: nil, prefix: "Drive", remote: remote))
        }
        let usage = await store.accounting(), counters = await remote.counters()
        XCTAssertLessThanOrEqual(usage.dirtyBytes, 256 * 1024)
        XCTAssertEqual(counters.sizes, [256 * 1024])
        for (index, snapshot) in snapshots.enumerated() {
            var bytes = Data(repeating: 0, count: 128 * 1024)
            let holes = try await store.overlay(snapshot: snapshot, range: 0..<Int64(bytes.count), into: &bytes, remote: remote, prefix: "Drive")
            XCTAssertTrue(holes.isEmpty); XCTAssertEqual(bytes, Data(repeating: UInt8(index + 1), count: 128 * 1024))
        }
    }
}
