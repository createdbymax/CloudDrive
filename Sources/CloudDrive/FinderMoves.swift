import Darwin
import Foundation
import SwiftUI

/// Remote mutations are separate from the VFS upload queue.
struct FinderMoveStatus: Decodable, Equatable, Sendable {
    enum Phase: String, Decodable, Sendable { case idle, preparing, copying, verifying, removing, completed, failed, needsRecovery }
    let version: Int
    let enabled: Bool
    let active: Bool
    let needsRecovery: Bool
    let phase: Phase
    let completed: Int
    let total: Int
    let message: String

    struct Job: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let source: String
        let destination: String
        let active: Bool
        let needsRecovery: Bool
        let phase: Phase
        let completed: Int
        let total: Int
        let message: String
        var failureKind: String? = nil

        var displayMessage: String {
            if phase == .failed && failureKind == "destinationExists" {
                return "An item already exists at the destination. Choose a different name or destination folder, then submit a new move."
            }
            return status.displayMessage
        }
        var status: FinderMoveStatus {
            FinderMoveStatus(version: 1, enabled: true, active: active, needsRecovery: needsRecovery,
                phase: phase, completed: completed, total: total, message: message)
        }
        var canResume: Bool { needsRecovery && !active && phase == .needsRecovery && !id.hasPrefix("invalid-") && !source.isEmpty && !destination.isEmpty }
        var hasDisplayablePaths: Bool {
            FinderMoveRecords.validLabel(source) && FinderMoveRecords.validLabel(destination)
        }
    }
    var jobs: [Job]? = nil
    var hasActiveJobs: Bool { active || jobs?.contains(where: \.active) == true }
    var hasRecoverableJobs: Bool { needsRecovery || jobs?.contains(where: \.needsRecovery) == true }
    var hasFailedJobs: Bool { phase == .failed || jobs?.contains(where: { $0.phase == .failed }) == true }
    var holdsWorker: Bool { hasActiveJobs || hasRecoverableJobs }
    var recoverableJobs: [Job] { jobs?.filter(\.canResume) ?? [] }

    static func decode(_ data: Data) throws -> Self {
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.version == 1, value.completed >= 0, value.total >= value.completed,
                  value.total <= 10_000, value.message.utf8.count <= 4096,
                  value.enabled || !value.holdsWorker else { throw RuntimeFailure.invalidControlResponse }
            if let jobs = value.jobs {
                guard jobs.count <= 4, Set(jobs.map(\.id)).count == jobs.count,
                      value.active == jobs.contains(where: \.active), value.needsRecovery == jobs.contains(where: \.needsRecovery) else { throw RuntimeFailure.invalidControlResponse }
                for job in jobs {
                    guard !job.id.isEmpty, job.id.utf8.count <= 256, job.id.rangeOfCharacter(from: .controlCharacters) == nil,
                          job.completed >= 0, job.total >= job.completed, job.total <= 10_000,
                          job.message.utf8.count <= 4096, job.source.utf8.count <= 4096, job.destination.utf8.count <= 4096,
                          !(job.active && job.needsRecovery), !job.active || [.preparing,.copying,.verifying,.removing].contains(job.phase),
                          ![.preparing,.copying,.verifying,.removing].contains(job.phase) || job.active,
                          job.phase != .needsRecovery || job.needsRecovery else { throw RuntimeFailure.invalidControlResponse }
                }
            } else {
                guard !(value.active && value.needsRecovery), !value.active || [.preparing,.copying,.verifying,.removing].contains(value.phase) else {
                    throw RuntimeFailure.invalidControlResponse
                }
            }
            return value
        } catch { throw RuntimeFailure.invalidControlResponse }
    }
    func resumeBody(id: String?) -> Data? {
        if jobs != nil {
            guard let id, recoverableJobs.contains(where: { $0.id == id }) else { return nil }
            return try? JSONSerialization.data(withJSONObject: ["resume": true, "id": id])
        }
        guard id == nil, needsRecovery, !active, phase == .needsRecovery else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["resume": true])
    }
    /// Older workers discard the precise rename errno before publishing move
    /// status. Describe what to check without assigning a cause to that error.
    var displayMessage: String {
        if !holdsWorker, let failed = jobs?.first(where: { $0.phase == .failed }) {
            return failed.displayMessage
        }
        if phase == .failed && !needsRecovery && (message.isEmpty || [
            "Move could not finish. Check storage access and try again.",
            "Move could not finish. Check the destination and try again."
        ].contains(message)) {
            return "Check the destination in Finder. If it already contains a folder with the same name and files inside, choose a different name for the incoming folder. To combine them, open both folders and copy the items you want to keep."
        }
        return message
    }
    var safeToStop: Bool { enabled && !holdsWorker }
    var title: String {
        if let jobs, jobs.count > 1 {
            let moving = jobs.filter(\.active).count, interrupted = jobs.filter(\.needsRecovery).count
            if moving > 0 && interrupted > 0 { return "\(moving) moving · \(interrupted) need attention" }
            if moving > 1 { return "\(moving) Finder moves in progress" }
            if interrupted > 1 { return "\(interrupted) Finder moves need attention" }
        }
        if hasRecoverableJobs { return "Move needs attention" }
        if active {
            switch phase {
            case .preparing: return total > 0 ? "Preparing move: \(completed) of \(total) items checked" : "Preparing to move…"
            case .copying: return "Moving \(completed) of \(total) files"
            case .verifying: return "Checking moved files…"
            case .removing: return "Finishing move: \(completed) of \(total) files"
            default: return "Moving files…"
            }
        }
        return hasFailedJobs ? "Move could not finish" : "No moves waiting"
    }
}

/// Inspect only private metadata records, never the mounted filesystem.
enum FinderMoveRecords {
    private static let filenames = ["move.json", "move-1.json", "move-2.json", "move-3.json"]
    private struct Envelope: Decodable { let version: Int; let complete: Bool; let binding: String?; let failed: Bool? }
    struct Route: Equatable, Sendable {
        let source: String
        let destination: String
    }
    private struct RouteEnvelope: Decodable {
        let version: Int, id: String, binding: String, complete: Bool
        let failed: Bool?
        let source: String, destination: String
    }
    /// Read labels through an owned directory descriptor. Never resolve a label
    /// against Finder, and never let a displayed record authorize a write.
    static func recordedRoutes(in directory: URL, expectedBinding: String) -> [Route] {
        filenames.compactMap { recordedRoute(in: directory, expectedBinding: expectedBinding, filename: $0) }
    }
    static func recordedRoute(in directory: URL, expectedBinding: String, filename: String = "move.json") -> Route? {
        guard filenames.contains(filename) else { return nil }
        guard !expectedBinding.isEmpty else { return nil }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return nil }
        defer { close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        let fd = openat(folder, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 32 * 1024 * 1024 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(info.st_size) + 1), data.count == info.st_size,
              let record = try? JSONDecoder().decode(RouteEnvelope.self, from: data), record.version == 1,
              record.binding == expectedBinding, !record.complete, record.failed != true, record.id.utf8.count == 32,
              record.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              record.source != record.destination, validLabel(record.source), validLabel(record.destination) else { return nil }
        return Route(source: record.source, destination: record.destination)
    }
    fileprivate static func validLabel(_ path: String) -> Bool {
        guard path.utf8.count <= 4096, path.rangeOfCharacter(from: .controlCharacters) == nil,
              path.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .format }) else { return false }
        return path.components(separatedBy: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func pending(in directory: URL, expectedBinding: String? = nil) throws -> Bool {
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return errno != ENOENT }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == getuid() else { return true }
        for name in filenames {
            if try pendingFile(name, in: directoryFD, privateDirectory: directoryInfo.st_mode & 0o077 == 0, expectedBinding: expectedBinding) { return true }
        }
        return false
    }
    private static func pendingFile(_ name: String, in directoryFD: Int32, privateDirectory: Bool, expectedBinding: String?) throws -> Bool {
        let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return errno != ENOENT }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 32 * 1024 * 1024 else { return true }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: Int(info.st_size) + 1), data.count == info.st_size,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { return true }
        if let expectedBinding, envelope.binding != expectedBinding { return true }
        if envelope.failed == true {
            guard privateDirectory, info.st_mode & 0o077 == 0, let expectedBinding, !expectedBinding.isEmpty, !envelope.complete,
                  let record = try? JSONDecoder().decode(PreparationFailure.self, from: data), record.valid else { return true }
            return false
        }
        return !envelope.complete
    }

    /// The new worker can record a final refusal before it publishes any inventory.
    /// Only this exact receipt shape permits a cold start to release its writer guard.
    private struct PreparationFailure: Decodable {
        let exclusive: Bool, preparing: Bool?, appleDouble: Bool?, requestID: String, id: String, source: String, destination: String
        let objects: EmptyInventory, directories: EmptyInventory
        struct EmptyInventory: Decodable {
            init(from decoder: Decoder) throws {
                if try decoder.singleValueContainer().decodeNil() { return }
                guard try decoder.unkeyedContainer().isAtEnd else { throw RuntimeFailure.invalidControlResponse }
            }
        }
        var valid: Bool {
            guard exclusive, preparing != true, appleDouble != true, requestID.hasPrefix("rc:"), (4...131).contains(requestID.utf8.count),
                  !requestID.contains("/"), !requestID.contains("\\"), requestID.rangeOfCharacter(from: .controlCharacters) == nil,
                  id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  FinderMoveRecords.validLabel(source), FinderMoveRecords.validLabel(destination) else { return false }
            let from = source.precomposedStringWithCanonicalMapping.lowercased()
            let to = destination.precomposedStringWithCanonicalMapping.lowercased()
            return from != to && !from.hasPrefix(to + "/") && !to.hasPrefix(from + "/")
        }
    }
}

private struct RecordedMoveRouteView: View {
    let directory: URL
    let binding: String
    let phase: String
    @State private var routes: [FinderMoveRecords.Route] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                VStack(alignment: .leading) {
                    Text("From: \(route.source)")
                    Text("To: \(route.destination)")
                }
            }
        }
        .font(.callout).textSelection(.enabled)
        .task(id: phase) {
            routes = []
            let directory = directory, binding = binding
            let latest = await Task.detached(priority: .utility) {
                FinderMoveRecords.recordedRoutes(in: directory, expectedBinding: binding)
            }.value
            if !Task.isCancelled { routes = latest }
        }
    }
}

struct FinderMovesView: View {
    @ObservedObject var drive: Drive
    var body: some View {
        if let moves = drive.finderMoves, drive.running,
           UploadFreshness.isFresh(drive.moveSampledAt, at: Date()),
           moves.holdsWorker || moves.hasFailedJobs {
            VStack(alignment: .leading, spacing: 8) {
                Label(moves.title, systemImage: moves.needsRecovery ? "exclamationmark.triangle" : "folder").font(.headline)
                if let jobs = moves.jobs {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.phase == .completed ? "Move completed" : job.status.title).font(.callout.weight(.medium))
                            if job.hasDisplayablePaths {
                                Text("From: \(job.source)")
                                Text("To: \(job.destination)")
                            }
                            if !job.displayMessage.isEmpty { Text(job.displayMessage).foregroundStyle(.secondary) }
                            if job.total > 0 && job.active {
                                ProgressView(value: Double(job.completed), total: Double(job.total))
                            }
                            if job.canResume {
                                Button("Resume move") { Task { await drive.resumeMove(id: job.id) } }.disabled(!drive.canResumeMove)
                            }
                        }.font(.callout).textSelection(.enabled)
                    }
                    if jobs.isEmpty && !moves.displayMessage.isEmpty { Text(moves.displayMessage).font(.callout) }
                } else {
                    RecordedMoveRouteView(directory: drive.moveDirectory, binding: drive.connection.fingerprint, phase: moves.phase.rawValue)
                        .id(drive.connection.fingerprint)
                    if moves.active || moves.needsRecovery {
                        Text("Other Finder moves must wait until this move finishes. Then retry the other move in Finder.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !moves.displayMessage.isEmpty { Text(moves.displayMessage).font(.callout).foregroundStyle(.secondary) }
                    if moves.active { ProgressView().controlSize(.small) }
                    if moves.needsRecovery {
                        Button("Resume move") { Task { await drive.resumeMove() } }.disabled(!drive.canResumeMove)
                    }
                }
            }
        } else if drive.moveRecordsPending && !drive.running {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unfinished move records are retained. Connect Finder browsing to review and resume each move.")
                RecordedMoveRouteView(directory: drive.moveDirectory, binding: drive.connection.fingerprint, phase: "retained")
                    .id(drive.connection.fingerprint)
            }.font(.callout).foregroundStyle(.secondary)
        }
    }
}
