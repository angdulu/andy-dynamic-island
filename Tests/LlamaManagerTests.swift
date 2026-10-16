import Foundation
import Defaults

// Fixed settings for the real production manager; no user preferences are written.
enum CleanupModel {
    case llama1b
    var fileName: String { "Llama-3.2-1B-Instruct-Q4_K_M.gguf" }
    var displayName: String { "Llama 3.2 1B" }
    var sha256: String { "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83" }
    var downloadURL: URL { URL(string: "https://example.invalid/unused")! }
}

enum Defaults {
    struct Key { static let dictationSelectedCleanupModel = Key() }
    static subscript(_ key: Key) -> CleanupModel { .llama1b }
}

@main
struct LlamaManagerTests {
    struct Failure: Error { let message: String }

    @MainActor
    static func main() async throws {
        let manager = LlamaManager.shared
        defer { manager.stopServer() }
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try await manager.ensureServerRunning(for: .llama1b) }
            }
            try await group.waitForAll()
        }
        guard manager.isServerRunning else { throw Failure(message: "Concurrent preparation did not produce a ready server") }
        print("PASS: 20 concurrent cleanup preparations shared startup (\(String(format: "%.2f", Date().timeIntervalSince(started)))s)")
        let reused = Date()
        try await manager.ensureServerRunning(for: .llama1b)
        guard Date().timeIntervalSince(reused) < 0.1 else { throw Failure(message: "Ready model was unnecessarily reloaded") }
        let editStarted = Date()
        let cleaned = try await manager.cleanText("hello, how are you?", conservative: true)
        guard cleaned.lowercased().filter({ $0.isLetter }) == "hellohowareyou" else { throw Failure(message: "Question was answered: \(cleaned)") }
        print("PASS: production cleanup preserves questions (\(String(format: "%.2f", Date().timeIntervalSince(editStarted)))s warm edit)")
        manager.stopServer()
        let interrupted = Task { try await manager.ensureServerRunning(for: .llama1b) }
        await Task.yield()
        manager.stopServer()
        try await manager.ensureServerRunning(for: .llama1b)
        do {
            try await interrupted.value
            throw Failure(message: "Interrupted model startup was not cancelled")
        } catch is CancellationError {}
        guard manager.isServerRunning else { throw Failure(message: "Interrupted startup stopped its replacement") }
        let restarted = try await manager.cleanText("he go there yesterday", conservative: true)
        guard restarted.lowercased().contains("yesterday") else { throw Failure(message: "Restarted cleanup failed") }
        print("PASS: startup cancellation, replacement server, warm reuse and production inference")
    }
}
