import Foundation

/// Stream codecs negotiated over AWC1 CONFIG2 (ids match both peers).
public enum StreamCodec: Int {
    case avc = 0
    case hevc = 1
}

/// Annex-B helpers shared by decoder and tests. The NAL framing is identical
/// for AVC and HEVC; only the type-field width differs (5 bits vs 6 bits).
public enum H264 {
    public static func nalTypes(in annexB: Data) -> [Int] {
        nalRanges(in: annexB).compactMap { range in
            range.isEmpty ? nil : Int(annexB[annexB.startIndex + range.lowerBound]) & 0x1F
        }
    }

    public static func hevcNalTypes(in annexB: Data) -> [Int] {
        nalRanges(in: annexB).compactMap { range in
            range.isEmpty ? nil : (Int(annexB[annexB.startIndex + range.lowerBound]) >> 1) & 0x3F
        }
    }

    public static func isKeyframeAccessUnit(_ annexB: Data) -> Bool {
        nalTypes(in: annexB).contains(5) // IDR slice
    }

    /// Codec-aware random-access check: AVC IDR (5); HEVC IDR_W_RADL (19),
    /// IDR_N_LP (20), CRA_NUT (21).
    public static func isSyncAccessUnit(_ annexB: Data, codec: StreamCodec) -> Bool {
        switch codec {
        case .avc: return isKeyframeAccessUnit(annexB)
        case .hevc:
            let types = hevcNalTypes(in: annexB)
            return types.contains(19) || types.contains(20) || types.contains(21)
        }
    }

    /// Converts an Annex-B access unit to AVCC (4-byte length prefixes),
    /// the format VideoToolbox expects inside CMSampleBuffer.
    public static func annexBToAVCC(_ annexB: Data) -> Data {
        var out = Data()
        for range in nalRanges(in: annexB) where !range.isEmpty {
            var len = UInt32(range.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(annexB.subdata(in: annexB.startIndex + range.lowerBound
                                     ..< annexB.startIndex + range.upperBound))
        }
        return out
    }

    /// Payload ranges (offsets into `annexB`) of each NAL, start codes excluded.
    static func nalRanges(in annexB: Data) -> [Range<Int>] {
        let bytes = [UInt8](annexB)
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, i + 3)); i += 3
            } else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0,
                      bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append((i, i + 4)); i += 4
            } else {
                i += 1
            }
        }
        return starts.enumerated().map { idx, s in
            let end = idx + 1 < starts.count ? starts[idx + 1].codeStart : bytes.count
            return s.payloadStart..<end
        }
    }
}
