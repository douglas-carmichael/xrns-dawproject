import Foundation

// MARK: - ZIP container access (pure Swift, no dependencies)
//
// Both .xrns and .dawproject are ordinary ZIP archives. To stay portable across
// macOS/Linux/Windows with no external packages and no system tools, this reads
// archives (incl. DEFLATE-compressed entries, via an inflater below) and writes
// them (STORED/uncompressed, which every ZIP reader accepts) entirely in Swift.

public enum ZipError: Error, CustomStringConvertible {
    case missingEntry(String)
    case malformed(String)
    case truncated

    public var description: String {
        switch self {
        case let .missingEntry(name): return "archive does not contain an entry named '\(name)'"
        case let .malformed(m): return "malformed ZIP: \(m)"
        case .truncated: return "unexpected end of compressed data"
        }
    }
}

public enum Zip {
    /// Read (and decompress, if needed) a single entry from an in-memory archive.
    public static func read(entry name: String, fromArchive data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let directory = try centralDirectory(bytes)
        guard let e = directory.first(where: { $0.name == name }) else {
            throw ZipError.missingEntry(name)
        }
        // The local header repeats the name/extra lengths; data starts after it.
        guard e.localHeaderOffset + 30 <= bytes.count,
              u32(bytes, e.localHeaderOffset) == 0x0403_4b50 else {
            throw ZipError.malformed("bad local header for '\(name)'")
        }
        let nameLen = Int(u16(bytes, e.localHeaderOffset + 26))
        let extraLen = Int(u16(bytes, e.localHeaderOffset + 28))
        let dataStart = e.localHeaderOffset + 30 + nameLen + extraLen
        guard dataStart + e.compressedSize <= bytes.count else {
            throw ZipError.malformed("entry '\(name)' runs past end of archive")
        }
        let compressed = Array(bytes[dataStart..<(dataStart + e.compressedSize)])
        switch e.method {
        case 0:  return Data(compressed)                                   // STORED
        case 8:  return Data(try Inflate.run(compressed, hint: e.uncompressedSize))  // DEFLATE
        default: throw ZipError.malformed("unsupported compression method \(e.method) for '\(name)'")
        }
    }

    /// Build a ZIP archive (STORED entries) from in-memory contents.
    public static func create(entries: [(name: String, data: Data)]) -> Data {
        var out = [UInt8]()
        var central = [UInt8]()
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021  // 1980-01-01

        for entry in entries {
            let nameBytes = [UInt8](entry.name.utf8)
            let payload = [UInt8](entry.data)
            let crc = CRC32.checksum(payload)
            let offset = UInt32(out.count)

            // Local file header.
            appendU32(&out, 0x0403_4b50)
            appendU16(&out, 20)            // version needed
            appendU16(&out, 0)             // flags
            appendU16(&out, 0)             // method = STORED
            appendU16(&out, dosTime)
            appendU16(&out, dosDate)
            appendU32(&out, crc)
            appendU32(&out, UInt32(payload.count))   // compressed size
            appendU32(&out, UInt32(payload.count))   // uncompressed size
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)             // extra length
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: payload)

            // Central directory record (buffered, written after all entries).
            appendU32(&central, 0x0201_4b50)
            appendU16(&central, 20)        // version made by
            appendU16(&central, 20)        // version needed
            appendU16(&central, 0)         // flags
            appendU16(&central, 0)         // method
            appendU16(&central, dosTime)
            appendU16(&central, dosDate)
            appendU32(&central, crc)
            appendU32(&central, UInt32(payload.count))
            appendU32(&central, UInt32(payload.count))
            appendU16(&central, UInt16(nameBytes.count))
            appendU16(&central, 0)         // extra length
            appendU16(&central, 0)         // comment length
            appendU16(&central, 0)         // disk number start
            appendU16(&central, 0)         // internal attributes
            appendU32(&central, 0)         // external attributes
            appendU32(&central, offset)    // local header offset
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(out.count)
        out.append(contentsOf: central)

        // End of central directory.
        appendU32(&out, 0x0605_4b50)
        appendU16(&out, 0)                 // disk number
        appendU16(&out, 0)                 // disk with central dir
        appendU16(&out, UInt16(entries.count))
        appendU16(&out, UInt16(entries.count))
        appendU32(&out, UInt32(central.count))
        appendU32(&out, centralOffset)
        appendU16(&out, 0)                 // comment length
        return Data(out)
    }

    // MARK: Central directory parsing

    private struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private static func centralDirectory(_ b: [UInt8]) throws -> [Entry] {
        // Locate the End Of Central Directory record by scanning backwards.
        guard b.count >= 22 else { throw ZipError.malformed("file too small") }
        var eocd = -1
        let lowest = max(0, b.count - 22 - 65_535)
        var p = b.count - 22
        while p >= lowest {
            if u32(b, p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.malformed("no end-of-central-directory record") }

        let count = Int(u16(b, eocd + 10))
        var offset = Int(u32(b, eocd + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 46 <= b.count, u32(b, offset) == 0x0201_4b50 else {
                throw ZipError.malformed("bad central directory header")
            }
            let method = Int(u16(b, offset + 10))
            let compSize = Int(u32(b, offset + 20))
            let uncompSize = Int(u32(b, offset + 24))
            let nameLen = Int(u16(b, offset + 28))
            let extraLen = Int(u16(b, offset + 30))
            let commentLen = Int(u16(b, offset + 32))
            let localOffset = Int(u32(b, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLen <= b.count else { throw ZipError.malformed("name runs past end") }
            let name = String(decoding: b[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compSize,
                                 uncompressedSize: uncompSize, localHeaderOffset: localOffset))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    // MARK: Little-endian helpers

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func appendU16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendU32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }
}

// MARK: - CRC-32 (ISO-3309, as used by ZIP)

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - DEFLATE inflate (RFC 1951)
//
// A compact, allocation-light inflater modelled on the canonical zlib "puff"
// reference: canonical Huffman tables are decoded bit-by-bit. Sufficient for
// reading ZIP entries (raw DEFLATE streams, no zlib/gzip wrapper).

enum Inflate {
    static func run(_ input: [UInt8], hint: Int) throws -> [UInt8] {
        var state = State(input: input)
        if hint > 0 { state.output.reserveCapacity(hint) }
        try state.inflate()
        return state.output
    }
}

private let maxBits = 15
private let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                          35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
private let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                           3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
private let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
private let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                         7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
private let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

private struct Huffman {
    var count: [Int]
    var symbol: [Int]
}

private struct State {
    let input: [UInt8]
    var output: [UInt8] = []
    var inPos = 0
    var bitBuffer = 0
    var bitCount = 0

    init(input: [UInt8]) { self.input = input }

    mutating func bits(_ need: Int) throws -> Int {
        var value = bitBuffer
        while bitCount < need {
            guard inPos < input.count else { throw ZipError.truncated }
            value |= Int(input[inPos]) << bitCount
            inPos += 1
            bitCount += 8
        }
        bitBuffer = value >> need
        bitCount -= need
        return value & ((1 << need) - 1)
    }

    mutating func inflate() throws {
        var final = 0
        repeat {
            final = try bits(1)
            switch try bits(2) {
            case 0: try stored()
            case 1: try fixedBlock()
            case 2: try dynamicBlock()
            default: throw ZipError.malformed("invalid DEFLATE block type")
            }
        } while final == 0
    }

    mutating func stored() throws {
        bitBuffer = 0; bitCount = 0      // skip to byte boundary
        guard inPos + 4 <= input.count else { throw ZipError.truncated }
        let len = Int(input[inPos]) | (Int(input[inPos + 1]) << 8)
        inPos += 4                       // skip LEN + NLEN
        guard inPos + len <= input.count else { throw ZipError.truncated }
        output.append(contentsOf: input[inPos..<(inPos + len)])
        inPos += len
    }

    func construct(_ lengths: [Int], count n: Int) -> Huffman {
        var count = [Int](repeating: 0, count: maxBits + 1)
        for sym in 0..<n { count[lengths[sym]] += 1 }
        var offsets = [Int](repeating: 0, count: maxBits + 1)
        for len in 1..<maxBits { offsets[len + 1] = offsets[len] + count[len] }
        var symbol = [Int](repeating: 0, count: n)
        for sym in 0..<n where lengths[sym] != 0 {
            symbol[offsets[lengths[sym]]] = sym
            offsets[lengths[sym]] += 1
        }
        return Huffman(count: count, symbol: symbol)
    }

    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...maxBits {
            code |= try bits(1)
            let count = h.count[len]
            if code - first < count { return h.symbol[index + (code - first)] }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw ZipError.malformed("invalid Huffman code")
    }

    mutating func codes(_ lengthCode: Huffman, _ distanceCode: Huffman) throws {
        while true {
            let sym = try decode(lengthCode)
            if sym == 256 { return }                         // end of block
            if sym < 256 {
                output.append(UInt8(sym))
            } else {
                let s = sym - 257
                guard s < lengthBase.count else { throw ZipError.malformed("invalid length symbol") }
                let length = lengthBase[s] + (lengthExtra[s] > 0 ? try bits(lengthExtra[s]) : 0)
                let dsym = try decode(distanceCode)
                guard dsym < distBase.count else { throw ZipError.malformed("invalid distance symbol") }
                let distance = distBase[dsym] + (distExtra[dsym] > 0 ? try bits(distExtra[dsym]) : 0)
                guard distance <= output.count else { throw ZipError.malformed("distance beyond output") }
                var src = output.count - distance
                for _ in 0..<length {
                    output.append(output[src])
                    src += 1
                }
            }
        }
    }

    mutating func fixedBlock() throws {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0..<144 { lengths[i] = 8 }
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        for i in 280..<288 { lengths[i] = 8 }
        let lengthCode = construct(lengths, count: 288)
        let distanceCode = construct([Int](repeating: 5, count: 30), count: 30)
        try codes(lengthCode, distanceCode)
    }

    mutating func dynamicBlock() throws {
        let hlit = try bits(5) + 257
        let hdist = try bits(5) + 1
        let hclen = try bits(4) + 4
        guard hlit <= 286, hdist <= 30 else { throw ZipError.malformed("bad dynamic block sizes") }

        var clLengths = [Int](repeating: 0, count: 19)
        for idx in 0..<hclen { clLengths[codeLengthOrder[idx]] = try bits(3) }
        let clCode = construct(clLengths, count: 19)

        var lengths = [Int](repeating: 0, count: hlit + hdist)
        var idx = 0
        while idx < hlit + hdist {
            let sym = try decode(clCode)
            switch sym {
            case 0..<16:
                lengths[idx] = sym; idx += 1
            case 16:
                guard idx > 0 else { throw ZipError.malformed("repeat with no previous length") }
                let repeats = 3 + (try bits(2))
                let prev = lengths[idx - 1]
                guard idx + repeats <= lengths.count else { throw ZipError.malformed("length repeat overflow") }
                for _ in 0..<repeats { lengths[idx] = prev; idx += 1 }
            case 17:
                let repeats = 3 + (try bits(3))
                guard idx + repeats <= lengths.count else { throw ZipError.malformed("length repeat overflow") }
                for _ in 0..<repeats { lengths[idx] = 0; idx += 1 }
            case 18:
                let repeats = 11 + (try bits(7))
                guard idx + repeats <= lengths.count else { throw ZipError.malformed("length repeat overflow") }
                for _ in 0..<repeats { lengths[idx] = 0; idx += 1 }
            default:
                throw ZipError.malformed("invalid code-length symbol")
            }
        }
        let lengthCode = construct(Array(lengths[0..<hlit]), count: hlit)
        let distanceCode = construct(Array(lengths[hlit..<(hlit + hdist)]), count: hdist)
        try codes(lengthCode, distanceCode)
    }
}
