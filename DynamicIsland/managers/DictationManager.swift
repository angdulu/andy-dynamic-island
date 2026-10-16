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
import Combine
import ApplicationServices
import CoreAudio

@MainActor
final class DictationManager: NSObject, ObservableObject {
    static let shared = DictationManager()

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var downloadingModel: DictationModel?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var modelStorageRevision = 0
    @Published private(set) var lastError: String?
    @Published private(set) var failedRecordingAvailable = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastRawTranscript: String?
    @Published private(set) var liveTranscript = ""
    @Published private(set) var isRefiningLive = false
    @Published private(set) var liveNotice: String?
    /// Normalized live microphone level (0...1) while recording. Drives Andy's
    /// listening animation; 0 whenever we are not capturing.
    @Published private(set) var inputLevel: Double = 0

    private var audioRecorder: AVAudioRecorder?
    private var preparedRecording: (recorder: AVAudioRecorder, url: URL, inputDeviceID: AudioDeviceID)?
    private var currentAudioURL: URL?
    private var suppressNextKeyUp = false
    private var activeDownloadDelegate: DictationModelDownloadDelegate?
    private var activeDownloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadID: UUID?
    private var hudSuppressionTimer: Timer?
    private var meteringTimer: Timer?
    private var liveTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var liveSession: UUID?
    private var previewTranscript = DictationPreviewTranscript()
    private var previewDraft = ""
    private var recordingUsesLiveMode = false
    private var recordingUsesLiveCleanup = false
    private var lastSpeechTime: TimeInterval = 0

    private let server = WhisperServer()
    private var idleUnloadTask: Task<Void, Never>?
    private var recoveryExpiryTask: Task<Void, Never>?
    private var failedAudioURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private var recordingTargetPID: pid_t?
    private let recordingStore = DictationRecordingStore(directory: DictationManager.recordingsDirectory)

    private override init() {
        super.init()
        refreshFailedRecording()
        Defaults.publisher(.dictationModelIdleTimeout)
            .sink { [weak self] _ in self?.scheduleIdleUnload() }
            .store(in: &cancellables)
        Defaults.publisher(.dictationEnableAICleanup)
            .sink { [weak self] _ in self?.prepareCleanupIfNeeded() }
            .store(in: &cancellables)
        Defaults.publisher(.enableScreenAssistant)
            .sink { [weak self] _ in self?.prepareNextRecording() }
            .store(in: &cancellables)
    }

    private func prepareCleanupIfNeeded() {
        guard !isRecording, !isTranscribing else { return }
        guard Defaults[.dictationEnableAICleanup] else {
            LlamaManager.shared.stopServer()
            return
        }
        let model = Defaults[.dictationSelectedCleanupModel]
        guard LlamaManager.isModelInstalled(model) else { return }
        Task { [weak self] in
            try? await LlamaManager.shared.ensureServerRunning(for: model)
            self?.scheduleIdleUnload()
        }
    }

    func retryFailedRecording() {
        guard !isRecording, !isTranscribing else { return }
        refreshFailedRecording()
        guard let failedAudioURL else { return }
        recordingUsesLiveCleanup = Defaults[.dictationEnableAICleanup]
        // A retry can happen in Settings; keep its output available for explicit copying.
        transcribe(audioURL: failedAudioURL, targetPID: nil)
    }

    func discardFailedRecording() {
        if let failedAudioURL { try? FileManager.default.removeItem(at: failedAudioURL) }
        failedAudioURL = nil
        failedRecordingAvailable = false
        recoveryExpiryTask?.cancel()
        recoveryExpiryTask = nil
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        copyToClipboard(lastTranscript)
    }

    func copyOriginalTranscript() {
        guard let lastRawTranscript else { return }
        copyToClipboard(lastRawTranscript)
    }

    private func refreshFailedRecording() {
        recoveryExpiryTask?.cancel()
        failedAudioURL = try? recordingStore.latestFailedRecording()
        failedRecordingAvailable = failedAudioURL != nil
        guard let failedAudioURL else { return }
        if lastError == nil { lastError = "A failed dictation is available to retry." }
        let remaining = recordingStore.expirationDate(for: failedAudioURL).timeIntervalSinceNow
        recoveryExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, remaining))) } catch { return }
            self?.discardFailedRecording()
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        let interval = Defaults[.dictationModelIdleTimeout].interval
        guard interval > 0, !isRecording, !isTranscribing else { return }
        idleUnloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard let self, !self.isRecording, !self.isTranscribing else { return }
            self.stopServer()
            LlamaManager.shared.stopServer()
        }
    }

    func handleShortcutKeyDown() {
        guard Defaults[.enableShortcuts], Defaults[.enableScreenAssistant] else { return }
        if !Defaults[.dictationOnlyMode] {
            ScreenAssistantPanelManager.shared.hideScreenAssistantPanel()
        }

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
        let downloadID = UUID()
        activeDownloadID = downloadID

        Task {
            guard activeDownloadID == downloadID else { return }
            var temporaryFile: URL?
            defer {
                if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
                if activeDownloadID == downloadID {
                    activeDownloadSession?.invalidateAndCancel()
                    activeDownloadSession = nil
                    activeDownloadDelegate = nil
                    activeDownloadTask = nil
                    activeDownloadID = nil
                    downloadingModel = nil
                    downloadProgress = nil
                }
            }
            do {
                let temporaryURL = try await downloadFile(for: model, downloadID: downloadID)
                temporaryFile = temporaryURL
                guard activeDownloadID == downloadID else { return }
                let downloadedHash = try await Task.detached { try Self.sha256(for: temporaryURL) }.value
                guard activeDownloadID == downloadID else { return }
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
                if activeDownloadID == downloadID, (error as NSError).code != NSURLErrorCancelled {
                    lastError = error.localizedDescription
                    print("Dictation: model download failed: \(error.localizedDescription)")
                }
            }

        }
    }

    func cancelModelDownload() {
        guard downloadingModel != nil else { return }
        activeDownloadID = nil
        activeDownloadTask?.cancel()
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadTask = nil
        activeDownloadSession = nil
        activeDownloadDelegate = nil
        downloadingModel = nil
        downloadProgress = nil
    }

    func deleteDownloadedModel(_ model: DictationModel) {
        guard !isRecording, !isTranscribing else { return }
        guard let modelURL = Self.downloadedModelURL(for: model) else { return }

        do {
            if Defaults[.dictationSelectedModel] == model { stopServer() }
            try FileManager.default.removeItem(at: modelURL)
            modelStorageRevision += 1
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("Dictation: failed to delete model: \(error.localizedDescription)")
        }
    }

    private func downloadFile(for model: DictationModel, downloadID: UUID) async throws -> URL {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-dictation-\(UUID().uuidString)-\(model.fileName)")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DictationModelDownloadDelegate(
                temporaryURL: temporaryURL,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard self?.activeDownloadID == downloadID else { return }
                        self?.downloadProgress = progress
                    }
                },
                completion: { result in
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

    private static var defaultInputDeviceID: AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private func makeRecording() throws -> (recorder: AVAudioRecorder, url: URL, inputDeviceID: AudioDeviceID) {
        let inputDeviceID = Self.defaultInputDeviceID
        let audioURL = Self.recordingsDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
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
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            try? FileManager.default.removeItem(at: audioURL)
            throw NSError(domain: "DictationManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the microphone."])
        }
        return (recorder, audioURL, inputDeviceID)
    }

    private func discardPreparedRecording() {
        guard let preparedRecording else { return }
        preparedRecording.recorder.stop()
        try? FileManager.default.removeItem(at: preparedRecording.url)
        self.preparedRecording = nil
    }

    private func prepareNextRecording() {
        guard !isRecording, !isTranscribing else { return }
        guard Defaults[.enableScreenAssistant] else {
            discardPreparedRecording()
            return
        }
        // Prepare resources ahead of the shortcut, but never start an idle
        // recording or trigger a microphone permission request at launch.
        guard preparedRecording == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        preparedRecording = try? makeRecording()
    }

    private func startRecording() {
        idleUnloadTask?.cancel()
        do {
            if let preparedRecording, preparedRecording.inputDeviceID != Self.defaultInputDeviceID {
                discardPreparedRecording()
            }
            let prepared = try preparedRecording ?? makeRecording()
            preparedRecording = nil
            let recorder = prepared.recorder
            let audioURL = prepared.url

            guard recorder.record() else {
                lastError = "Could not start microphone recording."
                try? FileManager.default.removeItem(at: audioURL)
                scheduleIdleUnload()
                return
            }

            // Silence any active timer alarm if it is currently finished/overtime
            if TimerManager.shared.isFinished || TimerManager.shared.isOvertime {
                TimerManager.shared.stopTimer()
            }

            startContinuousVolumeHUDSuppression()
            playDictationSound(.begin)

            currentAudioURL = audioURL
            recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            audioRecorder = recorder
            recordingUsesLiveCleanup = Defaults[.dictationEnableAICleanup]
            recordingUsesLiveMode = recordingUsesLiveCleanup && Defaults[.dictationCleanupPreview]
            previewTranscript = DictationPreviewTranscript()
            previewDraft = ""
            liveTranscript = ""
            liveNotice = nil
            lastSpeechTime = 0
            isRecording = true
            lastError = nil
            startMetering()
            print("Dictation: recording started")
            refreshFailedRecording()

            if recordingUsesLiveMode {
                startLivePreview(audioURL: audioURL)
            }

            Task {
                _ = try? await ensureServerRunning()
            }
            // Load cleanup independently of Whisper so their cold starts overlap
            // the recording instead of delaying the first completed phrase.
            if recordingUsesLiveCleanup {
                let cleanupModel = Defaults[.dictationSelectedCleanupModel]
                Task {
                    if LlamaManager.isModelInstalled(cleanupModel) {
                        try? await LlamaManager.shared.ensureServerRunning(for: cleanupModel)
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            scheduleIdleUnload()
            print("Dictation: failed to start recording: \(error)")
        }
    }

    /// Polls the recorder's meter and normalizes dBFS into a 0...1 curve that
    /// tracks speech rather than the full silence-to-clipping range.
    private func startMetering() {
        meteringTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.audioRecorder, self.isRecording else { return }
                recorder.updateMeters()
                let power = Double(recorder.averagePower(forChannel: 0))
                // -55 dB (room noise) → 0, -8 dB (talking close) → 1
                let normalized = (power + 55.0) / 47.0
                self.inputLevel = min(1, max(0, normalized))
                if self.recordingUsesLiveMode, power > -48 {
                    self.lastSpeechTime = recorder.currentTime
                }
            }
        }
        meteringTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        inputLevel = 0
    }

    private func startLivePreview(audioURL: URL) {
        let session = UUID()
        liveSession = session
        LiveDictationPreviewPanel.shared.show()
        if recordingUsesLiveCleanup, !LlamaManager.isModelInstalled(Defaults[.dictationSelectedCleanupModel]) {
            liveNotice = "Download a cleanup model in Settings to enable light correction."
        }
        liveTask = Task { [weak self] in
            guard let self else { return }
            var previewEnd: TimeInterval = 0
            while self.isRecording, self.liveSession == session {
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard self.isRecording, self.liveSession == session else { return }
                // Don't send silence to the recognizer or queue overlapping requests.
                guard self.lastSpeechTime > self.previewTranscript.endTime else { continue }
                let speechEnd = self.lastSpeechTime
                let captureTime = self.audioRecorder?.currentTime ?? 0
                let paused = captureTime - speechEnd >= 0.65
                do {
                    let start = self.previewTranscript.endTime
                    guard let snapshot = try await Task.detached(operation: {
                        try LiveDictationAudio.snapshot(from: audioURL, startingAt: start, endingAt: captureTime)
                    }).value, snapshot.endTime > previewEnd + 0.3 else { continue }
                    guard self.isRecording, self.liveSession == session else { return }
                    let text = try await self.transcribeViaHTTP(audioData: snapshot.wav)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard self.liveSession == session else { return }
                    previewEnd = snapshot.endTime
                    self.previewDraft = text
                    self.updateCleanupPreview()
                    // Only edit a completed phrase, never an unfinished word.
                    if paused, snapshot.endTime >= speechEnd + 0.4 {
                        self.previewDraft = ""
                        self.previewTranscript.append(text, endingAt: snapshot.endTime)
                        self.startPreviewCleanup(session: session)
                        self.updateCleanupPreview()
                    }
                } catch {
                    guard self.isRecording, self.liveSession == session else { return }
                    self.liveNotice = "Preview paused. Remaining audio will be transcribed when you finish."
                    return
                }
            }
        }
    }

    private func updateCleanupPreview() {
        liveTranscript = [previewTranscript.text, previewDraft].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func startPreviewCleanup(session: UUID) {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.liveSession == session { self.cleanupTask = nil } }
            while self.liveSession == session, let next = self.previewTranscript.nextCorrection {
                let corrected = await self.lightlyCleanLiveText(next.text)
                guard self.liveSession == session else { return }
                self.previewTranscript.finishCorrection(at: next.index, text: corrected)
                self.updateCleanupPreview()
            }
        }
    }

    private func lightlyCleanLiveText(_ text: String) async -> String {
        guard recordingUsesLiveCleanup,
              LlamaManager.isModelInstalled(Defaults[.dictationSelectedCleanupModel]) else { return text }
        isRefiningLive = true
        defer { isRefiningLive = false }
        do {
            return try await LlamaManager.shared.cleanText(text, conservative: true)
        } catch {
            liveNotice = "Some corrections were skipped; original wording was kept."
            return text
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        suppressVolumeHUD(for: 3.5)
        playDictationSound(.end)

        stopMetering()
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false

        guard let audioURL = currentAudioURL else { return }
        currentAudioURL = nil
        transcribe(audioURL: audioURL, targetPID: recordingTargetPID, live: recordingUsesLiveMode)
        recordingTargetPID = nil
    }

    private func transcribe(audioURL: URL, targetPID: pid_t?, live: Bool = false) {
        idleUnloadTask?.cancel()
        recoveryExpiryTask?.cancel()
        isTranscribing = true
        lastError = nil
        startContinuousVolumeHUDSuppression()

        Task {
            // Let an in-flight preview finish before final inference. Cancelling
            // its HTTP request would not stop the server's GPU work.
            if live { await liveTask?.value }
            liveTask = nil
            do {
                let rawTranscript: String
                let transcript: String
                if live {
                    // Confirmed phrases already have recognition results. Decode
                    // only the remaining tail, then drain the correction queue.
                    let start = previewTranscript.endTime
                    let tail = try await Task.detached {
                        try LiveDictationAudio.snapshot(from: audioURL, startingAt: start)
                    }.value
                    previewDraft = ""
                    if let tail {
                        let raw = try await transcribeViaHTTP(audioData: tail.wav)
                        previewTranscript.append(raw, endingAt: tail.endTime)
                    } else if start == 0 || lastSpeechTime > start {
                        // Unsupported headers or a very short spoken tail: prefer
                        // a complete decode over silently dropping audio.
                        let raw = try await transcribeViaHTTP(audioURL: audioURL)
                        // A replacement must not race a correction of old segments.
                        await cleanupTask?.value
                        previewTranscript = DictationPreviewTranscript()
                        previewTranscript.append(raw, endingAt: .greatestFiniteMagnitude)
                    }
                    if let session = liveSession { startPreviewCleanup(session: session) }
                    await cleanupTask?.value
                    rawTranscript = previewTranscript.rawText
                    transcript = previewTranscript.text
                    liveTranscript = transcript
                } else {
                    rawTranscript = try await transcribeViaHTTP(audioURL: audioURL)
                    transcript = await lightlyCleanLiveText(rawTranscript)
                }
                
                try? FileManager.default.removeItem(at: audioURL)
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.refreshFailedRecording()
                } else {
                    self.discardFailedRecording()
                    self.lastError = nil
                    self.lastTranscript = text
                    self.lastRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if targetPID == nil {
                        self.copyLastTranscript()
                    } else {
                        self.apply(transcript: text, targetPID: targetPID)
                    }
                }
            } catch {
                do { _ = try self.recordingStore.retainFailedRecording(audioURL) } catch {
                    print("Dictation: could not retain failed recording: \(error.localizedDescription)")
                }
                self.refreshFailedRecording()
                self.lastError = error.localizedDescription
                print("Dictation: transcription failed: \(error.localizedDescription)")
            }
            self.isTranscribing = false
            self.liveSession = nil
            self.cleanupTask = nil
            if live { LiveDictationPreviewPanel.shared.hide() }
            self.stopContinuousVolumeHUDSuppression()
            self.scheduleIdleUnload()
            self.prepareNextRecording()
        }
    }

    private func apply(transcript: String, targetPID: pid_t?) {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { return }

        if Defaults[.dictationPasteMethod] != .clipboard {
            guard AXIsProcessTrusted() else {
                lastError = "Accessibility access is needed to insert text. Your transcript is available to copy."
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                lastError = "The active app changed. Your transcript is available to copy."
                return
            }
        }

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

        var startIndex = 0
        while startIndex < utf16.count {
            var endIndex = min(startIndex + 20, utf16.count)
            if endIndex < utf16.count, (0xD800...0xDBFF).contains(utf16[endIndex - 1]) {
                endIndex -= 1
            }
            var chunk = Array(utf16[startIndex..<endIndex])

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp?.post(tap: .cghidEventTap)
            startIndex = endIndex
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
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        server.stop()
        if !isRecording, !isTranscribing { discardPreparedRecording() }
    }

    @discardableResult
    func ensureServerRunning() async throws -> Int {
        let model = Defaults[.dictationSelectedModel]
        guard let serverURL = Self.whisperServerURL else {
            throw NSError(domain: "DictationManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "whisper-server was not found."])
        }
        guard let modelURL = Self.modelURL(for: model) else {
            throw NSError(domain: "DictationManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model \(model.displayName) is not installed."])
        }

        let threadCount = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let port = try await server.ensureRunning(configuration: .init(
            executableURL: serverURL, modelURL: modelURL,
            threadCount: threadCount, vadModelURL: Self.vadModelURL
        ))
        scheduleIdleUnload()
        return port
    }

    private func transcribeViaHTTP(audioURL: URL) async throws -> String {
        let fileData = try await Task.detached { try Data(contentsOf: audioURL) }.value
        return try await transcribeViaHTTP(audioData: fileData)
    }

    private func transcribeViaHTTP(audioData fileData: Data) async throws -> String {
        let serverPort = try await ensureServerRunning()
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(serverPort)/inference")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
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
        body.append("\(Defaults[.dictationLanguage].rawValue)\r\n".data(using: .utf8)!)

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
            guard self.audioRecorder === recorder, self.isRecording else { return }
            recorder.stop()
            self.stopMetering()
            self.audioRecorder = nil
            self.isRecording = false
            self.liveSession = nil
            self.liveTask?.cancel()
            self.liveTask = nil
            self.cleanupTask?.cancel()
            self.cleanupTask = nil
            LiveDictationPreviewPanel.shared.hide()
            if let audioURL = self.currentAudioURL {
                _ = try? self.recordingStore.retainFailedRecording(audioURL)
                self.refreshFailedRecording()
            }
            self.currentAudioURL = nil
            self.recordingTargetPID = nil
            self.stopContinuousVolumeHUDSuppression()
            self.lastError = error?.localizedDescription ?? "Microphone recording failed."
            self.scheduleIdleUnload()
        }
    }
}

private enum DictationError: LocalizedError {
    case checksumMismatch

    var errorDescription: String? {
        switch self {
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
