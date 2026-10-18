import Foundation

/// AWC1 framing. See shared/protocol/PROTOCOL.md.
public enum WireProtocol {
    public static let headerSize = 20
    public static let maxPayload = 8 * 1024 * 1024
    public static let magic: [UInt8] = [0x41, 0x57, 0x43, 0x31] // AWC1

    public struct Frame: Equatable {
        public var type: UInt8
        public var flags: UInt8
        public var ptsUs: Int64
        public var payload: Data
        public var isKeyframe: Bool { flags & 1 != 0 }
        public init(type: UInt8, flags: UInt8, ptsUs: Int64, payload: Data) {
            self.type = type; self.flags = flags; self.ptsUs = ptsUs; self.payload = payload
        }
    }

    public struct Config: Equatable {
        public var sps: Data, pps: Data, width: Int, height: Int, fps: Int
        /// Quarter-turns clockwise (0...3) the receiver applies to frames.
        public var rotation: Int = 0
    }

    public static let typeConfig2: UInt8 = 5
    public static let codecAVC = 0
    public static let codecHEVC = 1

    /// Codec-negotiated config: AVC carries [sps, pps], HEVC [vps, sps, pps].
    public struct ConfigV2: Equatable {
        public var codec: Int
        public var paramSets: [Data]
        public var width: Int, height: Int, fps: Int
        /// Quarter-turns clockwise (0...3); 0 means frames arrive upright
        /// (rotated on-device) so the receiver forwards without rendering.
        public var rotation: Int = 0
        public init(codec: Int, paramSets: [Data], width: Int, height: Int,
                    fps: Int, rotation: Int = 0) {
            self.codec = codec; self.paramSets = paramSets
            self.width = width; self.height = height
            self.fps = fps; self.rotation = rotation
        }
    }

    public static func encode(type: UInt8, flags: UInt8, ptsUs: Int64, payload: Data) -> Data {
        precondition(payload.count <= maxPayload)
        var out = Data(capacity: headerSize + payload.count)
        out.append(contentsOf: magic)
        out.append(type); out.append(flags); out.append(contentsOf: [0, 0])
        appendBE(UInt64(bitPattern: ptsUs), to: &out)
        appendBE(UInt32(payload.count), to: &out)
        out.append(payload)
        return out
    }

    public static func encodeConfig(sps: Data, pps: Data, width: Int, height: Int,
                                    fps: Int, rotation: Int = 0) -> Data {
        var out = Data()
        appendBE(UInt16(sps.count), to: &out); out.append(sps)
        appendBE(UInt16(pps.count), to: &out); out.append(pps)
        appendBE(UInt16(width), to: &out); appendBE(UInt16(height), to: &out)
        out.append(UInt8(fps)); out.append(UInt8(rotation & 3))
        return out
    }

    public static func decodeConfig(_ payload: Data) -> Config? {
        var r = Reader(data: payload)
        guard let spsLen = r.u16(), let sps = r.bytes(Int(spsLen)),
              let ppsLen = r.u16(), let pps = r.bytes(Int(ppsLen)),
              let w = r.u16(), let h = r.u16(), let fps = r.u8(),
              let rotation = r.u8() else { return nil }
        return Config(sps: sps, pps: pps, width: Int(w), height: Int(h),
                      fps: Int(fps), rotation: Int(rotation & 3))
    }

    public static func encodeConfigV2(codec: Int, paramSets: [Data], width: Int,
                                      height: Int, fps: Int, rotation: Int = 0) -> Data {
        precondition(codec == codecAVC || codec == codecHEVC)
        precondition(!paramSets.isEmpty && paramSets.count <= 8)
        var out = Data()
        out.append(UInt8(codec)); out.append(UInt8(paramSets.count))
        for set in paramSets {
            appendBE(UInt16(set.count), to: &out); out.append(set)
        }
        appendBE(UInt16(width), to: &out); appendBE(UInt16(height), to: &out)
        out.append(UInt8(fps)); out.append(UInt8(rotation & 3))
        return out
    }

    public static func decodeConfigV2(_ payload: Data) -> ConfigV2? {
        var r = Reader(data: payload)
        guard let codec = r.u8(), let count = r.u8(),
              (codec == codecAVC || codec == codecHEVC),
              count >= 1, count <= 8 else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let len = r.u16(), let set = r.bytes(Int(len)) else { return nil }
            sets.append(set)
        }
        guard let w = r.u16(), let h = r.u16(), let fps = r.u8(),
              let rotation = r.u8() else { return nil }
        return ConfigV2(codec: Int(codec), paramSets: sets, width: Int(w),
                        height: Int(h), fps: Int(fps), rotation: Int(rotation & 3))
    }

    public static func encodeControl(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\($0)=\($1)" }.joined(separator: ";").utf8)
    }

    public static func decodeControl(_ payload: Data) -> [String: String] {
        var out: [String: String] = [:]
        for part in String(decoding: payload, as: UTF8.self).split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    private static func appendBE<T: FixedWidthInteger>(_ v: T, to d: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data; var i = 0
        mutating func u16() -> UInt16? { guard let b = bytes(2) else { return nil }
            return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.index(after: b.startIndex)]) }
        mutating func u8() -> UInt8? { bytes(1)?.first }
        mutating func bytes(_ n: Int) -> Data? {
            guard i + n <= data.count else { return nil }
            defer { i += n }
            return data.subdata(in: data.startIndex + i..<data.startIndex + i + n)
        }
    }
}

/// Incremental parser: feed bytes, get whole frames. Resyncs on bad magic.
public final class FrameParser {
    private var buffer = Data()
    public init() {}
    public func feed(_ chunk: Data) -> [WireProtocol.Frame] {
        buffer.append(chunk)
        var frames: [WireProtocol.Frame] = []
        while let f = nextFrame() { frames.append(f) }
        return frames
    }
    private func nextFrame() -> WireProtocol.Frame? {
        guard let start = indexOfMagic() else {
            if buffer.count > 3 { buffer = buffer.suffix(3) }
            return nil
        }
        if start > 0 { buffer.removeFirst(start) }
        guard buffer.count >= WireProtocol.headerSize else { return nil }
        let len = Int(readBE32(at: 16))
        guard len <= WireProtocol.maxPayload else { buffer.removeFirst(4); return nil }
        guard buffer.count >= WireProtocol.headerSize + len else { return nil }
        let frame = WireProtocol.Frame(
            type: buffer[buffer.startIndex + 4], flags: buffer[buffer.startIndex + 5],
            ptsUs: Int64(bitPattern: readBE64(at: 8)),
            payload: buffer.subdata(in: buffer.startIndex + WireProtocol.headerSize
                ..< buffer.startIndex + WireProtocol.headerSize + len))
        buffer.removeFirst(WireProtocol.headerSize + len)
        return frame
    }
    private func indexOfMagic() -> Int? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer.prefix(min(buffer.count, 64 * 1024)))
        for i in 0...(bytes.count - 4) where Array(bytes[i..<i + 4]) == WireProtocol.magic {
            return i
        }
        return buffer.count > 64 * 1024 ? 0 : nil
    }
    private func readBE32(at off: Int) -> UInt32 {
        let b = buffer.startIndex + off
        return UInt32(buffer[b]) << 24 | UInt32(buffer[b + 1]) << 16
            | UInt32(buffer[b + 2]) << 8 | UInt32(buffer[b + 3])
    }
    private func readBE64(at off: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(buffer[buffer.startIndex + off + k]) }
        return v
    }
}
