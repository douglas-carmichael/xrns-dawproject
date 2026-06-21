import Foundation

// Little-endian byte reader/writer used by the Polyend Tracker codecs. This is
// the Swift counterpart of the TypeScript source-of-truth's `DataView` usage in
// tracker-lib (https://github.com/.../tracker-lib): every multi-byte field in
// the .mt/.mtp/.pti formats is little-endian, matching `DataView.get*/set*(…, true)`.

/// Sequential + random-access reader over an immutable byte buffer.
struct PolyendReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }
    var remaining: Int { bytes.count - offset }

    // MARK: Sequential reads (advance `offset`)

    mutating func u8() -> Int { defer { offset += 1 }; return Int(bytes[offset]) }
    mutating func i8() -> Int { defer { offset += 1 }; return Int(Int8(bitPattern: bytes[offset])) }
    mutating func u16() -> Int { defer { offset += 2 }; return PolyendReader.u16(bytes, offset) }
    mutating func i16() -> Int { defer { offset += 2 }; return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: PolyendReader.u16(bytes, offset)))) }
    mutating func u32() -> UInt32 { defer { offset += 4 }; return PolyendReader.u32(bytes, offset) }
    mutating func f32() -> Float { defer { offset += 4 }; return Float(bitPattern: PolyendReader.u32(bytes, offset)) }
    mutating func skip(_ n: Int) { offset += n }

    mutating func slice(_ n: Int) -> [UInt8] {
        defer { offset += n }
        return Array(bytes[offset ..< offset + n])
    }

    /// Reads `n` bytes as ASCII, truncated at the first NUL (matching the TS
    /// `TextDecoder('ascii').decode(...).split('\x00')[0]`).
    mutating func ascii(_ n: Int) -> String {
        defer { offset += n }
        return PolyendReader.ascii(bytes, offset, n)
    }

    // MARK: Absolute reads (the project codec parses by fixed offsets)

    func u8At(_ i: Int) -> Int { Int(bytes[i]) }
    func u16At(_ i: Int) -> Int { PolyendReader.u16(bytes, i) }
    func u32At(_ i: Int) -> UInt32 { PolyendReader.u32(bytes, i) }
    func f32At(_ i: Int) -> Float { Float(bitPattern: PolyendReader.u32(bytes, i)) }
    func asciiAt(_ i: Int, _ n: Int) -> String { PolyendReader.ascii(bytes, i, n) }

    // MARK: Primitives

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func ascii(_ b: [UInt8], _ i: Int, _ n: Int) -> String {
        var s = ""
        for k in 0 ..< n {
            let c = b[i + k]
            if c == 0 { break }
            s.append(Character(UnicodeScalar(c)))
        }
        return s
    }
}

/// Mutable byte buffer with a sequential cursor plus absolute writes. Can be
/// seeded from a template (the project writer patches fixed offsets into the
/// embedded `LATEST_PROJECT_TEMPLATE`).
final class PolyendWriter {
    var bytes: [UInt8]
    var offset: Int = 0

    init(size: Int) { bytes = [UInt8](repeating: 0, count: size) }
    init(template: [UInt8]) { bytes = template }

    var data: Data { Data(bytes) }

    // MARK: Sequential writes

    func u8(_ v: Int) { bytes[offset] = UInt8(truncatingIfNeeded: v); offset += 1 }
    func i8(_ v: Int) { bytes[offset] = UInt8(bitPattern: Int8(truncatingIfNeeded: v)); offset += 1 }
    func u16(_ v: Int) { putU16(offset, v); offset += 2 }
    func i16(_ v: Int) { putU16(offset, Int(UInt16(bitPattern: Int16(truncatingIfNeeded: v)))); offset += 2 }
    func u32(_ v: UInt32) { putU32(offset, v); offset += 4 }
    func f32(_ v: Float) { putU32(offset, v.bitPattern); offset += 4 }
    func skip(_ n: Int) { offset += n }
    func raw(_ b: [UInt8]) { for v in b { bytes[offset] = v; offset += 1 } }

    /// Writes `s` as ASCII into an `n`-byte field, NUL-padding the remainder.
    func ascii(_ s: String, _ n: Int) {
        let scalars = Array(s.unicodeScalars.prefix(n))
        for k in 0 ..< n {
            bytes[offset + k] = k < scalars.count ? UInt8(truncatingIfNeeded: scalars[k].value) : 0
        }
        offset += n
    }

    // MARK: Absolute writes

    func u8At(_ i: Int, _ v: Int) { bytes[i] = UInt8(truncatingIfNeeded: v) }
    func u16At(_ i: Int, _ v: Int) { putU16(i, v) }
    func i16At(_ i: Int, _ v: Int) { putU16(i, Int(UInt16(bitPattern: Int16(truncatingIfNeeded: v)))) }
    func u32At(_ i: Int, _ v: UInt32) { putU32(i, v) }
    func f32At(_ i: Int, _ v: Float) { putU32(i, v.bitPattern) }
    func asciiAt(_ i: Int, _ s: String, _ n: Int) {
        let scalars = Array(s.unicodeScalars.prefix(n))
        for k in 0 ..< n {
            bytes[i + k] = k < scalars.count ? UInt8(truncatingIfNeeded: scalars[k].value) : 0
        }
    }
    func rawAt(_ i: Int, _ b: [UInt8]) { for (k, v) in b.enumerated() { bytes[i + k] = v } }

    // MARK: Primitives

    private func putU16(_ i: Int, _ v: Int) {
        bytes[i] = UInt8(truncatingIfNeeded: v)
        bytes[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    private func putU32(_ i: Int, _ v: UInt32) {
        bytes[i] = UInt8(truncatingIfNeeded: v)
        bytes[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
        bytes[i + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }
}

/// Parse-time errors thrown by the Polyend codecs. Named to avoid colliding with
/// any other `TrackerError` in the codebase.
enum PolyendError: Error, CustomStringConvertible {
    case invalidSignature(expected: String, got: String)
    case fileTooShort(String)
    case unsupportedVersion(String)
    case invalidWav(String)

    var description: String {
        switch self {
        case let .invalidSignature(expected, got):
            return "Invalid Polyend file signature: expected '\(expected)', got '\(got)'."
        case let .fileTooShort(what): return "Polyend file too short: \(what)."
        case let .unsupportedVersion(what): return "Unsupported Polyend version: \(what)."
        case let .invalidWav(what): return "Invalid WAV data: \(what)."
        }
    }
}
