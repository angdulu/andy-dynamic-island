import Foundation
import Darwin

@MainActor
final class WhisperServer {
    struct Configuration: Equatable {
        let executableURL: URL
        let modelURL: URL
        let threadCount: Int
        let vadModelURL: URL?
    }

    private var process: Process?
    private var configuration: Configuration?
    private var startupTask: Task<Int, Error>?
    private var readyPort: Int?
    private var generation = 0
    private var errorPipe: Pipe?
    private var diagnostics = ""
    private let startupTimeout: Duration

    init(startupTimeout: Duration = .seconds(30)) {
        self.startupTimeout = startupTimeout
    }

    func ensureRunning(configuration requested: Configuration) async throws -> Int {
        if configuration == requested, process?.isRunning == true {
            if let startupTask { return try await startupTask.value }
            if let readyPort { return readyPort }
        }

        stop()
        let port = try Self.availablePort()
        let child = Process()
        child.executableURL = requested.executableURL
        child.arguments = [
            "--model", requested.modelURL.path,
            "--host", "127.0.0.1", "--port", String(port),
            "--threads", String(requested.threadCount), "--language", "auto"
        ]
        if let vadModelURL = requested.vadModelURL {
            child.arguments! += ["--vad", "--vad-model", vadModelURL.path]
        }
        child.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardError = pipe
        let launchGeneration = generation
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data.suffix(8_192), as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self, self.generation == launchGeneration, self.readyPort == nil else { return }
                self.diagnostics = String((self.diagnostics + text).suffix(8_192))
            }
        }
        do {
            try child.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        errorPipe = pipe
        configuration = requested

        // All callers share readiness, including a short recording released during model loading.
        let task = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: startupTimeout)
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            while clock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else {
                    throw ServerError.exited(self.diagnostics)
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 0.5
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    try Task.checkCancellation()
                    guard child.isRunning, self.generation == launchGeneration else { throw CancellationError() }
                    return port
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ServerError.timedOut
        }
        startupTask = task
        do {
            let port = try await task.value
            guard generation == launchGeneration else { throw CancellationError() }
            readyPort = port
            startupTask = nil
            diagnostics = ""
            return port
        } catch {
            if generation == launchGeneration { stop() }
            throw error
        }
    }

    func stop() {
        generation += 1
        startupTask?.cancel()
        startupTask = nil
        readyPort = nil
        configuration = nil
        diagnostics = ""
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        if let child = process, child.isRunning {
            child.terminate()
            // Reap asynchronously so a model switch cannot freeze the main run loop.
            Task.detached {
                for _ in 0..<20 {
                    if !child.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
        }
        process = nil
    }

    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.portUnavailable }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard bound == 0, result == 0 else { throw ServerError.portUnavailable }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private enum ServerError: LocalizedError {
        case exited(String)
        case timedOut
        case portUnavailable

        var errorDescription: String? {
            switch self {
            case .exited(let details):
                return "Whisper stopped during startup. " + details.trimmingCharacters(in: .whitespacesAndNewlines)
            case .timedOut: return "Whisper did not become ready within the startup timeout."
            case .portUnavailable: return "Could not reserve a local port for Whisper."
            }
        }
    }
}
