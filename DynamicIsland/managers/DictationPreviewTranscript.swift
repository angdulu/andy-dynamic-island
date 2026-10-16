import Foundation

/// Only audio ending in a detected pause can enter the reusable transcript.
/// An unfinished hypothesis stays outside this store and is replaced freely.
struct DictationPreviewTranscript {
    private struct Segment {
        let raw: String
        let endTime: TimeInterval
        var corrected: String?
    }

    private var segments: [Segment] = []

    var endTime: TimeInterval { segments.last?.endTime ?? 0 }
    var rawText: String { segments.map(\.raw).joined(separator: " ") }
    var text: String { segments.map { $0.corrected ?? $0.raw }.joined(separator: " ") }
    var nextCorrection: (index: Int, text: String)? {
        guard let index = segments.firstIndex(where: { $0.corrected == nil }) else { return nil }
        return (index, segments[index].raw)
    }

    mutating func append(_ raw: String, endingAt endTime: TimeInterval) {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty early recognition is not proof that its audio was silent.
        // Keep it uncommitted so the next preview/final pass includes the onset.
        guard !raw.isEmpty, endTime > self.endTime else { return }
        segments.append(Segment(raw: raw, endTime: endTime))
    }

    mutating func finishCorrection(at index: Int, text: String) {
        guard segments.indices.contains(index) else { return }
        segments[index].corrected = text
    }
}
