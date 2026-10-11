import Foundation
import AVFoundation

@main
struct WhisperIntegrationTests {
    enum Failure: Error { case invalidResponse, missingSpeech, unexpectedSilence }

    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let server = WhisperServer()
        defer { server.stop() }
        let configuration = WhisperServer.Configuration(
            executableURL: URL(fileURLWithPath: args[1]),
            modelURL: URL(fileURLWithPath: args[2]), threadCount: 4,
            vadModelURL: URL(fileURLWithPath: args[3])
        )
        async let firstPort = server.ensureRunning(configuration: configuration)
        try await Task.sleep(for: .milliseconds(50))
        let port = try await server.ensureRunning(configuration: configuration)
        guard port == (try await firstPort) else { throw Failure.invalidResponse }

        func transcribe(_ audioURL: URL, language: String = "auto") async throws -> String {
            let boundary = "Test-\(UUID().uuidString)"
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body.append(try Data(contentsOf: audioURL))
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = result["text"] as? String else { throw Failure.invalidResponse }
            print("\(audioURL.lastPathComponent): \(String(format: "%.2f", Date().timeIntervalSince(started)))s, \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            return text
        }

        let english = try await transcribe(URL(fileURLWithPath: args[4]))
        guard english.lowercased().contains("fellow americans") else { throw Failure.missingSpeech }
        if args.count > 5 {
            let korean = try await transcribe(URL(fileURLWithPath: args[5]))
            guard korean.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { throw Failure.missingSpeech }
        }
        if args.count > 6 {
            let shortKorean = try await transcribe(URL(fileURLWithPath: args[6]), language: "ko")
            guard shortKorean.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { throw Failure.missingSpeech }
        }
        let silenceURL = FileManager.default.temporaryDirectory.appendingPathComponent("andy-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: silenceURL) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: silenceURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 32_000)
            try file.write(from: buffer)
        }
        let silence = try await transcribe(silenceURL)
        guard silence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unexpectedSilence }
        server.stop()
        try await Task.sleep(for: .seconds(2.2))
        print("PASS: native HTTP transcription, language detection, VAD silence, concurrent cold startup")
    }
}
