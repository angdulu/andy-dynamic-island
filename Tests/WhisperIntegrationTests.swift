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
        if let openingPath = ProcessInfo.processInfo.environment["ANDY_TEST_OPENING_AUDIO"] {
            let opening = try await transcribe(URL(fileURLWithPath: openingPath), language: "en")
            let letters = opening.lowercased().filter { $0.isLetter }
            guard letters.hasPrefix("iwanttocheck") else { throw Failure.missingSpeech }
        }
        // Exercise the same bounded WAV snapshots used by live preview against
        // the real server, without accessing the microphone.
        let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent("andy-preview-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: previewURL) }
        guard let preview = try LiveDictationAudio.snapshot(from: URL(fileURLWithPath: args[4]), startingAt: 0, endingAt: 5) else {
            throw Failure.invalidResponse
        }
        try preview.wav.write(to: previewURL)
        let partial = try await transcribe(previewURL)
        guard partial.lowercased().contains("fellow americans") else { throw Failure.missingSpeech }
        let full = try LiveDictationAudio.snapshot(from: URL(fileURLWithPath: args[4]), startingAt: 0)!
        let pcm = Data(full.wav.dropFirst(44))
        var joined = full.wav.prefix(44)
        let joinedPCM = pcm + Data(repeating: 0, count: 32_000) + pcm
        func writeSize(_ size: UInt32, at offset: Int) {
            var value = size.littleEndian
            withUnsafeBytes(of: &value) { joined.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        writeSize(UInt32(36 + joinedPCM.count), at: 4)
        writeSize(UInt32(joinedPCM.count), at: 40)
        joined.append(joinedPCM)
        try joined.write(to: previewURL)
        let boundary = full.endTime + 0.5
        let tail = try LiveDictationAudio.snapshot(from: previewURL, startingAt: boundary)!
        guard tail.wav.count < joined.count else { throw Failure.invalidResponse }
        try tail.wav.write(to: previewURL)
        let finalTail = try await transcribe(previewURL)
        guard finalTail.lowercased().contains("fellow americans") else { throw Failure.missingSpeech }
        var reused = DictationPreviewTranscript()
        reused.append(english, endingAt: boundary)
        reused.append(finalTail, endingAt: tail.endTime)
        guard reused.rawText.lowercased().components(separatedBy: "fellow americans").count == 3 else { throw Failure.invalidResponse }
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
        print("PASS: native HTTP transcription, preview phrase reuse and tail-only decoding, language detection, VAD silence, concurrent cold startup")
    }
}
