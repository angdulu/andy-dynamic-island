import Foundation

@main
struct DictationCoreTests {
    struct Failure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("andy-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        func model(_ name: String, mode: String = "ready") throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(mode.utf8).write(to: url)
            return url
        }
        func config(_ model: URL) -> WhisperServer.Configuration {
            .init(executableURL: fixture, modelURL: model, threadCount: 1, vadModelURL: nil)
        }
        let first = try model("first")
        let server = WhisperServer()
        defer { server.stop() }
        let ports = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask { try await server.ensureRunning(configuration: config(first)) }
            }
            var ports = Set<Int>()
            for try await port in group { ports.insert(port) }
            return ports
        }
        try check(ports.count == 1, "Concurrent callers must share one ready server")
        let launches = try String(contentsOf: first.appendingPathExtension("launches"), encoding: .utf8)
        try check(launches.split(separator: "\n").count == 1, "Cold startup launched more than one child")
        let second = try model("second")
        let secondPort = try await server.ensureRunning(configuration: config(second))
        try check(secondPort > 0, "Model switching must produce a ready server")
        server.stop()
        let slow = try model("slow", mode: "slow")
        let pending = Task { try await server.ensureRunning(configuration: config(slow)) }
        try await Task.sleep(for: .milliseconds(100))
        server.stop()
        let restart = try await server.ensureRunning(configuration: config(second))
        do { _ = try await pending.value; throw Failure(message: "Stopped startup should be cancelled") }
        catch is CancellationError {}
        let reused = try await server.ensureRunning(configuration: config(second))
        try check(restart == reused, "Old startup cleanup stopped the replacement server")
        server.stop()

        let failing = try model("failing", mode: "exit")
        do { _ = try await server.ensureRunning(configuration: config(failing)); throw Failure(message: "Startup failure was ignored") }
        catch is Failure { throw Failure(message: "Startup failure was ignored") }
        catch { try check(error.localizedDescription.contains("Whisper stopped"), "Unexpected startup failure: \(error)") }
        let impatient = WhisperServer(startupTimeout: .milliseconds(150))
        do { _ = try await impatient.ensureRunning(configuration: config(slow)); throw Failure(message: "Startup timeout was ignored") }
        catch is Failure { throw Failure(message: "Startup timeout was ignored") }
        catch { try check(error.localizedDescription.contains("timeout"), "Unexpected timeout: \(error)") }
        impatient.stop()
        print("PASS: shared startup, model switch, cancellation, restart, failure, timeout")

        let recordings = root.appendingPathComponent("Recordings")
        let store = DictationRecordingStore(directory: recordings)
        _ = try store.latestFailedRecording()
        let original = recordings.appendingPathComponent("dictation-1.wav")
        try Data("audio one".utf8).write(to: original)
        let retained = try store.retainFailedRecording(original)!
        try check(!FileManager.default.fileExists(atPath: original.path), "Failed recording must be moved into recovery")
        try check(try Data(contentsOf: retained) == Data("audio one".utf8), "Recovery changed the audio")
        let retried = try store.retainFailedRecording(retained)
        try check(retried == retained, "Retry must preserve the recovery file and its age")
        try await Task.sleep(for: .milliseconds(20))
        let newer = recordings.appendingPathComponent("dictation-2.wav")
        try Data("audio two".utf8).write(to: newer)
        let latest = try store.retainFailedRecording(newer)!
        try check(!FileManager.default.fileExists(atPath: retained.path), "Only the most recent failed recording should be kept")
        let unrelated = recordings.appendingPathComponent("unrelated.wav")
        try Data("unrelated".utf8).write(to: unrelated)
        let unrelatedDirectory = recordings.appendingPathComponent("failed-dictation-directory.wav")
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        let expired = try store.latestFailedRecording(now: store.expirationDate(for: latest).addingTimeInterval(1))
        try check(expired == nil, "Expired recovery should be removed")
        try check(FileManager.default.fileExists(atPath: unrelated.path), "Recovery cleanup removed an unrelated file")
        try check(FileManager.default.fileExists(atPath: unrelatedDirectory.path), "Recovery cleanup removed a directory")
        print("PASS: recovery, retry, replacement, expiration, unrelated-file preservation")
        try await Task.sleep(for: .seconds(2.2))
    }
}
