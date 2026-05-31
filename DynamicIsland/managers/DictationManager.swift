/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import AudioToolbox
import AVFoundation
import CryptoKit
import Defaults

@MainActor
final class DictationManager: NSObject, ObservableObject {
    static let shared = DictationManager()

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var downloadingModel: DictationModel?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var modelStorageRevision = 0
    @Published private(set) var lastError: String?

    private var audioRecorder: AVAudioRecorder?
    private var currentAudioURL: URL?
    private var suppressNextKeyUp = false
    private var activeDownloadDelegate: DictationModelDownloadDelegate?
    private var activeDownloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var hudSuppressionTimer: Timer?

    private var serverProcess: Process?
    private var serverPort = 8178
    private var currentLoadedModel: DictationModel?

    private override init() {
        super.init()
    }

    func handleShortcutKeyDown() {
        guard Defaults[.enableShortcuts], Defaults[.enableScreenAssistant] else { return }
        ScreenAssistantPanelManager.shared.hideScreenAssistantPanel()

        if Defaults[.dictationPushToTalk] {
            guard !isRecording, !isTranscribing else { return }
            suppressNextKeyUp = false
            startRecording()
        } else {
            toggleRecording()
        }
    }

    func handleShortcutKeyUp() {
        guard Defaults[.enableShortcuts], Defaults[.enableScreenAssistant] else { return }
        guard Defaults[.dictationPushToTalk], !suppressNextKeyUp else {
            suppressNextKeyUp = false
            return
        }
        stopRecordingAndTranscribe()
    }

    func toggleRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else if !isTranscribing {
            startRecording()
        }
    }

    func download(model: DictationModel) {
        guard downloadingModel == nil, !Self.isModelInstalled(model) else { return }

        downloadingModel = model
        downloadProgress = 0
        lastError = nil

        Task {
            do {
                let temporaryURL = try await downloadFile(for: model)
                let downloadedHash = try Self.sha256(for: temporaryURL)
                guard downloadedHash == model.sha256 else {
                    throw DictationError.checksumMismatch
                }

                let destinationURL = Self.modelStorageDirectory.appendingPathComponent(model.fileName)
                try FileManager.default.createDirectory(
                    at: Self.modelStorageDirectory,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                modelStorageRevision += 1
                print("Dictation: downloaded \(model.displayName)")
            } catch {
                if (error as NSError).code != NSURLErrorCancelled {
                    lastError = error.localizedDescription
                    print("Dictation: model download failed: \(error.localizedDescription)")
                }
            }

            downloadingModel = nil
            downloadProgress = nil
            activeDownloadTask = nil
        }
    }

    func cancelModelDownload() {
        guard downloadingModel != nil else { return }
        activeDownloadTask?.cancel()
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadTask = nil
        activeDownloadSession = nil
        activeDownloadDelegate = nil
        downloadingModel = nil
        downloadProgress = nil
    }

    func deleteDownloadedModel(_ model: DictationModel) {
        guard let modelURL = Self.downloadedModelURL(for: model) else { return }

        do {
            try FileManager.default.removeItem(at: modelURL)
            modelStorageRevision += 1
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("Dictation: failed to delete model: \(error.localizedDescription)")
        }
    }

    private func downloadFile(for model: DictationModel) async throws -> URL {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-dictation-\(UUID().uuidString)-\(model.fileName)")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DictationModelDownloadDelegate(
                temporaryURL: temporaryURL,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        self?.activeDownloadSession?.invalidateAndCancel()
                        self?.activeDownloadSession = nil
                        self?.activeDownloadDelegate = nil
                    }
                    continuation.resume(with: result)
                }
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: model.downloadURL)
            activeDownloadDelegate = delegate
            activeDownloadSession = session
            activeDownloadTask = task
            task.resume()
        }
    }

    private func startRecording() {
        do {
            let audioURL = Self.recordingsDirectory
                .appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970)).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = false
            recorder.prepareToRecord()

            guard recorder.record() else {
                lastError = "Could not start microphone recording."
                return
            }

            startContinuousVolumeHUDSuppression()
            playDictationSound(.begin)

            currentAudioURL = audioURL
            audioRecorder = recorder
            isRecording = true
            lastError = nil
            print("Dictation: recording started")

            Task {
                try? await ensureServerRunning()
                if Defaults[.dictationEnableAICleanup] {
                    let cleanupModel = Defaults[.dictationSelectedCleanupModel]
                    if LlamaManager.isModelInstalled(cleanupModel) {
                        try? await LlamaManager.shared.ensureServerRunning(for: cleanupModel)
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            print("Dictation: failed to start recording: \(error)")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        
        suppressVolumeHUD(for: 3.5)
        playDictationSound(.end)
        
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false

        guard let audioURL = currentAudioURL else { return }
        currentAudioURL = nil
        transcribe(audioURL: audioURL)
    }

    private func transcribe(audioURL: URL) {
        isTranscribing = true
        lastError = nil
        startContinuousVolumeHUDSuppression()

        Task {
            do {
                var transcript = try await transcribeViaHTTP(audioURL: audioURL)
                
                if Defaults[.dictationEnableAICleanup] {
                    let cleanupModel = Defaults[.dictationSelectedCleanupModel]
                    if LlamaManager.isModelInstalled(cleanupModel) {
                        do {
                            print("Dictation: running local AI cleanup using \(cleanupModel.displayName)...")
                            transcript = try await LlamaManager.shared.cleanText(transcript)
                        } catch {
                            print("Dictation: local AI cleanup failed, using raw transcript: \(error.localizedDescription)")
                        }
                    }
                }
                
                self.isTranscribing = false
                self.stopContinuousVolumeHUDSuppression()
                try? FileManager.default.removeItem(at: audioURL)
                self.lastError = nil
                self.apply(transcript: transcript)
            } catch {
                self.isTranscribing = false
                self.stopContinuousVolumeHUDSuppression()
                try? FileManager.default.removeItem(at: audioURL)
                self.lastError = error.localizedDescription
                print("Dictation: transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(transcript: String) {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { return }

        switch Defaults[.dictationPasteMethod] {
        case .direct:
            typeText(cleanedTranscript)
        case .directAndClipboard:
            copyToClipboard(cleanedTranscript)
            pasteFromClipboard()
        case .clipboard:
            copyToClipboard(cleanedTranscript)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)

        for startIndex in stride(from: 0, to: utf16.count, by: 20) {
            let endIndex = min(startIndex + 20, utf16.count)
            var chunk = Array(utf16[startIndex..<endIndex])

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func pasteFromClipboard() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    private func playDictationSound(_ sound: DictationSound) {
        guard Defaults[.dictationSoundEffects] else { return }
        sound.play()
    }

    private func suppressVolumeHUD(for interval: TimeInterval = 1.25) {
        HUDSuppressionCoordinator.shared.suppressVolumeHUD(for: interval)
    }

    private func startContinuousVolumeHUDSuppression() {
        suppressVolumeHUD(for: 3.5)
        guard hudSuppressionTimer == nil else { return }

        hudSuppressionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            HUDSuppressionCoordinator.shared.suppressVolumeHUD(for: 3.5)
        }
    }

    private func stopContinuousVolumeHUDSuppression() {
        hudSuppressionTimer?.invalidate()
        hudSuppressionTimer = nil
        suppressVolumeHUD(for: 3.5)
    }

    private nonisolated static func runWhisper(whisperCLI: URL, modelURL: URL, audioURL: URL) -> Result<String, Error> {
        let duration = Self.audioDuration(for: audioURL)
        let audioURLs: [URL]
        do {
            audioURLs = try Self.chunkedAudioURLs(for: audioURL)
        } catch {
            return .failure(error)
        }

        defer {
            for chunkURL in audioURLs where chunkURL != audioURL {
                try? FileManager.default.removeItem(at: chunkURL)
            }
        }

        let process = Process()
        let threadCount = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        var arguments = [
            "-m", modelURL.path,
            "-t", "\(threadCount)",
            "-l", "auto",
            "-mc", "0",
            "-bo", "1",
            "-bs", "1",
            "-nf",
            "-np",
            "-nt"
        ]

        if (duration ?? 0) >= 8, let vadModelURL = vadModelURL {
            arguments += [
                "--vad",
                "--vad-model", vadModelURL.path
            ]
        }
        arguments += audioURLs.map(\.path)

        process.executableURL = whisperCLI
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            return .failure(DictationError.transcriptionFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return .success(Self.cleanTranscript(output))
    }

    private nonisolated static func chunkedAudioURLs(for audioURL: URL) throws -> [URL] {
        let inputFile = try AVAudioFile(forReading: audioURL)
        let format = inputFile.processingFormat
        let framesPerChunk = AVAudioFrameCount(format.sampleRate * 20)
        guard framesPerChunk > 0, inputFile.length > Int64(framesPerChunk) else {
            return [audioURL]
        }

        var chunkURLs: [URL] = []
        var chunkIndex = 0

        while inputFile.framePosition < inputFile.length {
            let remainingFrames = inputFile.length - inputFile.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(framesPerChunk), remainingFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw DictationError.transcriptionFailed("Could not prepare audio chunk.")
            }

            try inputFile.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }

            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("atoll-dictation-chunk-\(UUID().uuidString)-\(chunkIndex).wav")
            let outputFile = try AVAudioFile(forWriting: chunkURL, settings: inputFile.fileFormat.settings)
            try outputFile.write(from: buffer)
            chunkURLs.append(chunkURL)
            chunkIndex += 1
        }

        return chunkURLs.isEmpty ? [audioURL] : chunkURLs
    }

    private nonisolated static func audioDuration(for audioURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return TimeInterval(file.length) / sampleRate
    }

    private nonisolated static func cleanTranscript(_ output: String) -> String {
        output
            .split(separator: "\n")
            .map { line in
                line
                    .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static var recordingsDirectory: URL {
        let directory = applicationSupportDirectory
            .appendingPathComponent("Dictation", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Atoll", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var modelStorageDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("TranscriptionModels", isDirectory: true)
    }

    private static func modelURL(for model: DictationModel) -> URL? {
        for directory in modelDirectories {
            let candidate = directory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func isModelInstalled(_ model: DictationModel) -> Bool {
        modelURL(for: model) != nil
    }

    static func isModelDownloadedByAtoll(_ model: DictationModel) -> Bool {
        downloadedModelURL(for: model) != nil
    }

    private static func downloadedModelURL(for model: DictationModel) -> URL? {
        let candidate = modelStorageDirectory.appendingPathComponent(model.fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static var modelDirectories: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return [
            modelStorageDirectory,
            support.appendingPathComponent("computer.andy.app", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
        ]
    }

    private static var whisperServerURL: URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Whisper", isDirectory: true)
            .appendingPathComponent("whisper-server"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private nonisolated static var vadModelURL: URL? {
        let fileNames = [
            "ggml-silero-v5.1.2.bin",
            "silero-vad.bin",
            "ggml-vad.bin"
        ]

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let directories = [
            Bundle.main.resourceURL?.appendingPathComponent("Whisper", isDirectory: true),
            support?
                .appendingPathComponent("Atoll", isDirectory: true)
                .appendingPathComponent("TranscriptionModels", isDirectory: true),
            support?
                .appendingPathComponent("computer.andy.app", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
        ].compactMap { $0 }

        for directory in directories {
            for fileName in fileNames {
                let candidate = directory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }

    private nonisolated static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistent whisper-server Management

    func stopServer() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            print("Dictation: whisper-server terminated")
        }
        serverProcess = nil
        currentLoadedModel = nil
    }

    private func startServer(for model: DictationModel) async throws {
        stopServer()

        guard let serverURL = Self.whisperServerURL else {
            throw NSError(domain: "DictationManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "whisper-server was not found."])
        }
        guard let modelURL = Self.modelURL(for: model) else {
            throw NSError(domain: "DictationManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model \(model.displayName) is not installed."])
        }

        let port = 8178
        let threadCount = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        let process = Process()
        process.executableURL = serverURL
        process.arguments = [
            "--model", modelURL.path,
            "--port", "\(port)",
            "--host", "127.0.0.1",
            "--threads", "\(threadCount)",
            "--language", "auto"
        ]

        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        self.serverProcess = process
        self.serverPort = port
        self.currentLoadedModel = model

        print("Dictation: whisper-server started on port \(port) for model \(model.displayName)")
    }

    func ensureServerRunning() async throws {
        let selectedModel = Defaults[.dictationSelectedModel]

        if let process = serverProcess, process.isRunning, currentLoadedModel == selectedModel {
            return
        }

        try await startServer(for: selectedModel)

        var retries = 0
        let client = URLSession.shared
        let pingURL = URL(string: "http://127.0.0.1:\(serverPort)/")!

        while retries < 50 {
            do {
                let (_, response) = try await client.data(from: pingURL)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    print("Dictation: whisper-server is ready and healthy!")
                    return
                }
            } catch {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            retries += 1
        }

        throw NSError(domain: "DictationManager", code: 504, userInfo: [NSLocalizedDescriptionKey: "whisper-server startup timed out."])
    }

    private func transcribeViaHTTP(audioURL: URL) async throws -> String {
        try await ensureServerRunning()

        let fileData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(serverPort)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // Language part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("auto\r\n".data(using: .utf8)!)

        // Response format part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "DictationManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."])
        }

        guard httpResponse.statusCode == 200 else {
            let errMsg = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)"
            throw NSError(domain: "DictationManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }

        struct WhisperResponse: Codable {
            let text: String?
        }

        let whisperResult = try JSONDecoder().decode(WhisperResponse.self, from: data)
        guard let rawText = whisperResult.text else {
            throw NSError(domain: "DictationManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "No transcription text returned."])
        }

        return Self.cleanTranscript(rawText)
    }
}

private enum DictationSound {
    case begin
    case end

    private var fileName: String {
        switch self {
        case .begin:
            return "whisper_begin"
        case .end:
            return "whisper_end"
        }
    }

    func play() {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "wav") else { return }
        var soundID = SystemSoundID()
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError else { return }
        AudioServicesPlaySystemSoundWithCompletion(soundID) {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }
}

extension DictationManager: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.lastError = error?.localizedDescription
        }
    }
}

private enum DictationError: LocalizedError {
    case transcriptionFailed(String)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let message):
            return message.isEmpty ? "Whisper transcription failed." : message
        case .checksumMismatch:
            return "Downloaded model did not pass verification."
        }
    }
}

private final class DictationModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let temporaryURL: URL
    private let progressHandler: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var didComplete = false

    init(
        temporaryURL: URL,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.temporaryURL = temporaryURL
        self.progressHandler = progressHandler
        self.completion = completion
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            try FileManager.default.copyItem(at: location, to: temporaryURL)
            didComplete = true
            completion(.success(temporaryURL))
        } catch {
            didComplete = true
            completion(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !didComplete, let error else { return }
        didComplete = true
        completion(.failure(error))
    }
}
