import Foundation

// MARK: - FLAC decoder (pure Swift)
//
// Decodes the full FLAC subset that libFLAC (and therefore Renoise) emits, so
// instrument samples can be read *out* of a .xrns: CONSTANT / VERBATIM / FIXED /
// LPC subframes, partitioned Rice residuals (4- and 5-bit, with the raw escape),
// and every channel-decorrelation mode (independent, left/side, right/side,
// mid/side). Output is interleaved 16-bit PCM. Returns nil on malformed or
// unsupported input rather than trapping.

extension Flac {
    struct Decoded {
        var pcm: [Int16]       // interleaved
        var channels: Int
        var sampleRate: Int
    }

    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            return nil    // missing "fLaC"
        }
        var r = BitReader(bytes, bitPos: 32)

        // --- Metadata blocks (capture STREAMINFO, skip the rest) ---
        var streamRate = 44100, streamChannels = 1, streamBps = 16
        var last = false
        while !last {
            guard let lastFlag = r.bit(), let type = r.bits(7), let length = r.bits(24) else { return nil }
            last = lastFlag == 1
            if type == 0 {       // STREAMINFO
                guard r.skip(16 + 16 + 24 + 24),                       // min/max block, min/max frame
                      let sr = r.bits(20), let ch = r.bits(3), let bps = r.bits(5),
                      r.skip(36), r.skipBytes(16) else { return nil }   // total samples, MD5
                streamRate = max(1, sr); streamChannels = ch + 1; streamBps = bps + 1
            } else {
                guard r.skipBytes(length) else { return nil }
            }
        }

        // --- Frames ---
        var channelData: [[Int]] = Array(repeating: [], count: streamChannels)
        while r.bytesRemaining >= 2 {
            guard let frame = decodeFrame(&r, streamChannels: streamChannels,
                                          streamBps: streamBps, streamRate: streamRate) else { break }
            if frame.count != channelData.count { channelData = Array(repeating: [], count: frame.count) }
            for c in 0 ..< frame.count { channelData[c].append(contentsOf: frame[c]) }
        }
        guard let first = channelData.first, !first.isEmpty else { return nil }

        // --- Interleave + convert to 16-bit ---
        let channels = channelData.count
        let frames = first.count
        var pcm = [Int16](repeating: 0, count: frames * channels)
        for c in 0 ..< channels {
            let col = channelData[c]
            for i in 0 ..< min(frames, col.count) {
                pcm[i * channels + c] = to16(col[i], bps: streamBps)
            }
        }
        return Decoded(pcm: pcm, channels: channels, sampleRate: streamRate)
    }

    // MARK: Frame

    private static func decodeFrame(_ r: inout BitReader, streamChannels: Int, streamBps: Int,
                                    streamRate: Int) -> [[Int]]? {
        guard let sync = r.bits(14), sync == 0b11111111111110 else { return nil }
        guard let _ = r.bit() else { return nil }                 // reserved
        guard let blockingStrategy = r.bit() else { return nil }   // 0 = fixed, 1 = variable
        guard let bsCode = r.bits(4), let srCode = r.bits(4),
              let chAssign = r.bits(4), let sizeCode = r.bits(3), r.skip(1) else { return nil }

        guard r.consumeCodedNumber(variable: blockingStrategy == 1) else { return nil }

        // Block size
        let blockSize: Int
        switch bsCode {
        case 0: return nil
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << (bsCode - 2)
        case 6: guard let v = r.bits(8) else { return nil }; blockSize = v + 1
        case 7: guard let v = r.bits(16) else { return nil }; blockSize = v + 1
        default: blockSize = 256 << (bsCode - 8)
        }
        guard blockSize > 0, blockSize <= 1 << 20 else { return nil }

        // Sample rate code may carry trailing bits we just consume.
        switch srCode {
        case 12: guard r.skip(8) else { return nil }
        case 13, 14: guard r.skip(16) else { return nil }
        case 15: return nil
        default: break
        }

        // Bits per sample (frame header may restate it; 0 = use STREAMINFO).
        let bps: Int
        switch sizeCode {
        case 0: bps = streamBps
        case 1: bps = 8
        case 2: bps = 12
        case 4: bps = 16
        case 5: bps = 20
        case 6: bps = 24
        default: return nil
        }

        guard r.skipBytes(1) else { return nil }   // CRC-8 (not verified)

        // Channel count + which channels carry the +1-bit "side".
        let channels: Int
        switch chAssign {
        case 0...7: channels = chAssign + 1
        case 8, 9, 10: channels = 2
        default: return nil
        }
        func sideBps(_ c: Int) -> Int {
            switch chAssign {
            case 8: return c == 1 ? bps + 1 : bps     // left/side → side is ch1
            case 9: return c == 0 ? bps + 1 : bps     // right/side → side is ch0
            case 10: return c == 1 ? bps + 1 : bps    // mid/side → side is ch1
            default: return bps
            }
        }

        var ch: [[Int]] = []
        ch.reserveCapacity(channels)
        for c in 0 ..< channels {
            guard let sub = decodeSubframe(&r, blockSize: blockSize, bps: sideBps(c)) else { return nil }
            ch.append(sub)
        }

        r.alignToByte()
        guard r.skipBytes(2) else { return nil }    // CRC-16 (not verified)

        // Undo inter-channel decorrelation.
        switch chAssign {
        case 8:  // left/side: right = left - side
            for i in 0 ..< blockSize { ch[1][i] = ch[0][i] - ch[1][i] }
        case 9:  // right/side: left = right + side
            for i in 0 ..< blockSize { ch[0][i] = ch[1][i] + ch[0][i] }
        case 10: // mid/side
            for i in 0 ..< blockSize {
                let side = ch[1][i]
                let mid = (ch[0][i] << 1) | (side & 1)
                ch[0][i] = (mid + side) >> 1
                ch[1][i] = (mid - side) >> 1
            }
        default: break
        }
        return ch
    }

    // MARK: Subframe

    private static func decodeSubframe(_ r: inout BitReader, blockSize: Int, bps: Int) -> [Int]? {
        guard r.skip(1) else { return nil }                 // mandatory zero bit
        guard let type = r.bits(6) else { return nil }
        guard let wastedFlag = r.bit() else { return nil }
        var wasted = 0
        if wastedFlag == 1 {
            guard let u = r.unary() else { return nil }
            wasted = u + 1
        }
        let effBps = bps - wasted
        guard effBps > 0 else { return nil }

        var samples: [Int]
        if type == 0 {                                       // CONSTANT
            guard let v = r.signed(effBps) else { return nil }
            samples = [Int](repeating: v, count: blockSize)
        } else if type == 1 {                                // VERBATIM
            samples = [Int](); samples.reserveCapacity(blockSize)
            for _ in 0 ..< blockSize { guard let v = r.signed(effBps) else { return nil }; samples.append(v) }
        } else if type >= 8 && type <= 12 {                  // FIXED, order = type - 8
            guard let s = decodeFixed(&r, blockSize: blockSize, bps: effBps, order: type - 8) else { return nil }
            samples = s
        } else if type >= 32 {                               // LPC, order = (type & 31) + 1
            guard let s = decodeLPC(&r, blockSize: blockSize, bps: effBps, order: (type & 31) + 1) else { return nil }
            samples = s
        } else {
            return nil                                       // reserved
        }

        if wasted > 0 { for i in 0 ..< samples.count { samples[i] <<= wasted } }
        return samples
    }

    private static func decodeFixed(_ r: inout BitReader, blockSize: Int, bps: Int, order: Int) -> [Int]? {
        var s = [Int](); s.reserveCapacity(blockSize)
        for _ in 0 ..< order { guard let v = r.signed(bps) else { return nil }; s.append(v) }
        guard let res = decodeResidual(&r, blockSize: blockSize, order: order) else { return nil }
        for i in order ..< blockSize {
            let e = res[i - order]
            let p: Int
            switch order {
            case 0: p = 0
            case 1: p = s[i - 1]
            case 2: p = 2 * s[i - 1] - s[i - 2]
            case 3: p = 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3]
            default: p = 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4]
            }
            s.append(e + p)
        }
        return s
    }

    private static func decodeLPC(_ r: inout BitReader, blockSize: Int, bps: Int, order: Int) -> [Int]? {
        var s = [Int](); s.reserveCapacity(blockSize)
        for _ in 0 ..< order { guard let v = r.signed(bps) else { return nil }; s.append(v) }
        guard let precM1 = r.bits(4), precM1 != 0xF, let shift = r.signed(5), shift >= 0 else { return nil }
        let precision = precM1 + 1
        var coef = [Int](); coef.reserveCapacity(order)
        for _ in 0 ..< order { guard let c = r.signed(precision) else { return nil }; coef.append(c) }
        guard let res = decodeResidual(&r, blockSize: blockSize, order: order) else { return nil }
        for i in order ..< blockSize {
            var acc = 0
            for j in 0 ..< order { acc += coef[j] * s[i - 1 - j] }
            s.append(res[i - order] + (acc >> shift))
        }
        return s
    }

    private static func decodeResidual(_ r: inout BitReader, blockSize: Int, order: Int) -> [Int]? {
        guard let method = r.bits(2), method <= 1, let poExp = r.bits(4) else { return nil }
        let partitions = 1 << poExp
        guard blockSize % partitions == 0, (blockSize >> poExp) >= order else { return nil }
        let paramBits = method == 0 ? 4 : 5
        let escape = method == 0 ? 0xF : 0x1F
        var residual = [Int](); residual.reserveCapacity(blockSize - order)
        for p in 0 ..< partitions {
            let count = (p == 0) ? (blockSize >> poExp) - order : (blockSize >> poExp)
            if count < 0 { return nil }
            guard let param = r.bits(paramBits) else { return nil }
            if param == escape {
                guard let rawBits = r.bits(5) else { return nil }
                for _ in 0 ..< count {
                    guard let v = rawBits == 0 ? 0 : r.signed(rawBits) else { return nil }
                    residual.append(v)
                }
            } else {
                for _ in 0 ..< count {
                    guard let q = r.unary(), let low = param == 0 ? 0 : r.bits(param) else { return nil }
                    let u = (q << param) | low
                    residual.append((u >> 1) ^ -(u & 1))     // zig-zag decode
                }
            }
        }
        return residual
    }

    private static func to16(_ v: Int, bps: Int) -> Int16 {
        if bps == 16 { return Int16(truncatingIfNeeded: v) }
        if bps < 16 { return Int16(truncatingIfNeeded: v << (16 - bps)) }
        return Int16(truncatingIfNeeded: v >> (bps - 16))
    }
}

/// MSB-first bit reader over a byte buffer. Reads return nil past end-of-buffer.
private struct BitReader {
    let bytes: [UInt8]
    var bitPos: Int

    init(_ bytes: [UInt8], bitPos: Int = 0) { self.bytes = bytes; self.bitPos = bitPos }

    var bytesRemaining: Int { max(0, bytes.count - (bitPos + 7) / 8) }

    mutating func bit() -> Int? {
        let idx = bitPos >> 3
        guard idx < bytes.count else { return nil }
        let shift = 7 - (bitPos & 7)
        bitPos += 1
        return Int((bytes[idx] >> shift) & 1)
    }

    mutating func bits(_ n: Int) -> Int? {
        guard n >= 0 else { return nil }
        if n == 0 { return 0 }
        var v = 0
        for _ in 0 ..< n { guard let b = bit() else { return nil }; v = (v << 1) | b }
        return v
    }

    /// Reads `n` bits as a two's-complement signed integer.
    mutating func signed(_ n: Int) -> Int? {
        guard n > 0, let u = bits(n) else { return nil }
        return (u >> (n - 1)) & 1 == 1 ? u - (1 << n) : u
    }

    /// Counts zero bits up to (and consuming) the terminating 1.
    mutating func unary() -> Int? {
        var count = 0
        while true {
            guard let b = bit() else { return nil }
            if b == 1 { return count }
            count += 1
            if count > 1 << 24 { return nil }    // corruption guard
        }
    }

    mutating func skip(_ n: Int) -> Bool {
        bitPos += n
        return bitPos <= bytes.count * 8
    }

    mutating func skipBytes(_ n: Int) -> Bool { skip(n * 8) }

    mutating func alignToByte() { if bitPos & 7 != 0 { bitPos = (bitPos + 7) & ~7 } }

    /// Consumes a FLAC frame/sample number (UTF-8-like, 1–7 bytes).
    mutating func consumeCodedNumber(variable: Bool) -> Bool {
        guard let b0 = bits(8) else { return false }
        if b0 < 0x80 { return true }
        var leading = 0, x = b0
        while (x & 0x80) != 0 { leading += 1; x = (x << 1) & 0xFF }
        guard leading >= 2 else { return false }
        for _ in 0 ..< (leading - 1) { guard bits(8) != nil else { return false } }
        return true
    }
}
