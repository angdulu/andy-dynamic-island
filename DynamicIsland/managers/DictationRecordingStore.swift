import Foundation

struct DictationRecordingStore {
    let directory: URL
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    func latestFailedRecording(now: Date = Date()) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey]
        ).filter {
            $0.lastPathComponent.hasPrefix("failed-dictation-") && $0.pathExtension == "wav"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        let sorted = files.sorted { expirationDate(for: $0) > expirationDate(for: $1) }
        var latest: URL?
        for file in sorted {
            if latest == nil, expirationDate(for: file) > now {
                latest = file
            } else {
                try FileManager.default.removeItem(at: file)
            }
        }
        return latest
    }

    func retainFailedRecording(_ audioURL: URL, now: Date = Date()) throws -> URL? {
        if !audioURL.lastPathComponent.hasPrefix("failed-dictation-") {
            let destination = directory.appendingPathComponent("failed-dictation-\(UUID().uuidString).wav")
            try FileManager.default.moveItem(at: audioURL, to: destination)
        }
        return try latestFailedRecording(now: now)
    }

    func expirationDate(for audioURL: URL) -> Date {
        let created = (try? audioURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        return created.addingTimeInterval(Self.retentionInterval)
    }
}
