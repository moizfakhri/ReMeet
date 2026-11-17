import Foundation

/// Fixes the RIFF and data chunk sizes of a WAV whose writer never finished (ReMeet quit
/// or crashed mid-recording). The samples are all there; only the header says 0 bytes.
public enum WAVRepair {
    public struct Result: Equatable, Sendable {
        public var repaired: Bool
        public var dataBytes: UInt64
    }

    public enum RepairError: Error, Equatable {
        case notRIFF
        case noDataChunk
        case tooLarge
    }

    public static func repair(_ url: URL) throws -> Result {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else {
            throw RepairError.notRIFF
        }
        guard fileSize <= UInt64(UInt32.max) else { throw RepairError.tooLarge }

        // Walk chunks until "data"; everything after its header is sample data.
        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(chunk[4]) | UInt64(chunk[5]) << 8 | UInt64(chunk[6]) << 16 | UInt64(chunk[7]) << 24
            if id == "data" {
                let actual = fileSize - (offset + 8)
                let riffSize = UInt32(fileSize - 8)
                let currentRIFF = header[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                if size == actual && UInt32(littleEndian: currentRIFF) == riffSize {
                    return Result(repaired: false, dataBytes: actual)
                }
                try handle.seek(toOffset: 4)
                try handle.write(contentsOf: littleEndian(riffSize))
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: littleEndian(UInt32(actual)))
                return Result(repaired: true, dataBytes: actual)
            }
            offset += 8 + size + (size & 1)
        }
        throw RepairError.noDataChunk
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
