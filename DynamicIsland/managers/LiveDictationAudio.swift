import Foundation

/// Reads a bounded PCM snapshot without stopping AVAudioRecorder. Its WAV sizes
/// may still be zero while recording, so use the bytes actually on disk.
enum LiveDictationAudio {
    struct Snapshot {
        let wav: Data
        let endTime: TimeInterval
    }

    static func snapshot(from url: URL, startingAt start: TimeInterval, endingAt end: TimeInterval? = nil) throws -> Snapshot? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 4096) ?? Data()
        guard header.count >= 12,
              String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else { return nil }

        var cursor = 12
        var format: Data?
        while cursor + 8 <= header.count {
            let name = String(decoding: header[cursor..<cursor + 4], as: UTF8.self)
            let size = Int(uint32(header, at: cursor + 4))
            let payload = cursor + 8
            if name == "fmt ", size >= 16, payload + 16 <= header.count {
                format = header.subdata(in: payload..<payload + 16)
            }
            if name == "data" {
                guard let format,
                      uint16(format, at: 0) == 1,
                      uint16(format, at: 2) == 1,
                      uint32(format, at: 4) == 16_000,
                      uint16(format, at: 14) == 16 else { return nil }
                let fileSize = try file.seekToEnd()
                let byteOffset = max(0, Int((start * 16_000).rounded())) * 2
                var available = max(0, Int(fileSize) - payload)
                if let end { available = min(available, max(0, Int(end * 16_000)) * 2) }
                let count = (available - byteOffset) / 2 * 2
                guard count >= 3_200 else { return nil }
                try file.seek(toOffset: UInt64(payload + byteOffset))
                var pcm = try file.read(upToCount: count) ?? Data()
                if pcm.count % 2 != 0 { pcm.removeLast() }
                guard pcm.count >= 3_200, pcm.count <= Int(UInt32.max) - 36 else { return nil }
                var wav = Data("RIFF".utf8)
                append(UInt32(36 + pcm.count), to: &wav)
                wav.append(Data("WAVEfmt ".utf8))
                append(UInt32(16), to: &wav)
                wav.append(format)
                wav.append(Data("data".utf8))
                append(UInt32(pcm.count), to: &wav)
                wav.append(pcm)
                return Snapshot(wav: wav, endTime: Double(byteOffset + pcm.count) / 32_000)
            }
            guard size <= header.count - payload else { return nil }
            cursor = payload + size + (size % 2)
        }
        return nil
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(uint16(data, at: offset)) | UInt32(uint16(data, at: offset + 2)) << 16
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
