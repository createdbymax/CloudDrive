import Foundation
import Darwin

/// Explicit diagnostic startup only. Release builds never select this path.
enum R2QualificationLaunch {
    static func requested(arguments: [String]) -> Bool {
        #if DEBUG
        return arguments.dropFirst().contains { ["--qualify-r2", "--qualify-native-r2", "--qualify-native-r2-project", "--qualify-native-r2-group", "--qualify-native-r2-bounded", "--qualify-native-r2-exercise", "--quiesce-native-qualification", "--verify-native-qualification"].contains($0) }
        #else
        return false
        #endif
    }
    static func valid(arguments: [String]) -> Bool {
        if arguments.count == 3, ["--quiesce-native-qualification", "--verify-native-qualification"].contains(arguments[1]) { return UUID(uuidString: arguments[2]) != nil }
        return arguments.count == 2 && ["--qualify-r2", "--qualify-native-r2", "--qualify-native-r2-project", "--qualify-native-r2-group", "--qualify-native-r2-bounded", "--qualify-native-r2-exercise"].contains(arguments[1])
    }
    #if DEBUG
    @MainActor static func run(arguments: [String], root: URL) async -> Never {
        guard valid(arguments: arguments) else { finish(status: "invalid-arguments", path: nil, code: 64) }
        if arguments[1] == "--quiesce-native-qualification", let id = UUID(uuidString: arguments[2]) {
            do { try await NativeR2Qualification.quiesce(runID: id, root: root); finish(status: "safe-to-stop", path: nil, code: 0) }
            catch { finish(status: NativeR2Qualification.diagnostic(error), path: nil, code: 1) }
        }
        if arguments[1] == "--qualify-native-r2-exercise" {
            do { try NativeR2Qualification.exercise(); finish(status: "passed", path: nil, code: 0) }
            catch { finish(status: NativeR2Qualification.diagnostic(error), path: nil, code: Int32((error as NSError).domain == NSPOSIXErrorDomain ? max(1, min(125, (error as NSError).code)) : 1)) }
        }
        // An independent watchdog bounds even a stalled system/provider call.
        // It exits only this diagnostic process; retained native owners/mounts
        // are never killed by the deadline handler.
        let watchdog = DispatchWorkItem { finish(status: "deadline-exceeded-evidence-retained", path: nil, code: 124) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (["--qualify-native-r2-project", "--qualify-native-r2-group", "--qualify-native-r2-bounded"].contains(arguments[1]) ? 1800 : 240), execute: watchdog)
        defer { watchdog.cancel() }
        do {
            guard let savedConnection = try await Credentials.loadBounded(allowInteraction: false) else {
                finish(status: "saved-connection-unavailable", path: nil, code: 3)
            }
            if arguments[1] == "--verify-native-qualification", let id = UUID(uuidString: arguments[2]) {
                do {
                    let path = try await NativeR2Qualification.verifyRetained(runID: id, root: root, connection: savedConnection)
                    finish(status: "verified-after-deadline", path: path.path, code: 0)
                } catch { finish(status: NativeR2Qualification.diagnostic(error), path: nil, code: 1) }
            }
            if let scenario = NativeRunCase(rawValue: arguments[1]) {
                let (state, path) = await NativeR2Qualification.run(connection: savedConnection, root: root, scenario: scenario)
                finish(status: state, path: path?.path, code: state == "passed" ? 0 : 1)
            }
            let controller = R2QualificationController()
            await controller.run(connection: savedConnection, root: root)
            let state = controller.result?.state ?? "preparation-failed"
            finish(status: state, path: controller.reportURL?.path,
                   code: state == "passed" ? 0 : state == "incomplete" ? 2 : 1)
        } catch {
            finish(status: "saved-connection-unavailable", path: nil, code: 3)
        }
    }
    private static func finish(status: String, path: String?, code: Int32) -> Never {
        // No arbitrary error, connection, provider, key or request details.
        var output = ["status": status]
        if let path { output["reportPath"] = path }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
        Darwin.exit(code)
    }
    #endif
}
