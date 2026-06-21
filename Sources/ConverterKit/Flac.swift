import Foundation

// MARK: - Minimal FLAC encoder (pure Swift, mono 16-bit)
//
// Encodes 16-bit mono PCM to a standards-compliant FLAC stream, so Renoise —
// which stores instrument samples as FLAC — loads converted instruments
// natively at a fraction of WAV's size. It uses FLAC's FIXED predictors
// (orders 0–4, the best chosen per block) with Rice-coded residuals: that's the
// core of FLAC's lossless compression, minus LPC. Output round-trips bit-exactly
// through the reference `flac` decoder (and libFLAC, which Renoise uses).
//
// No loop metadata is embedded — Renoise takes loop points from the instrument
// XML, not the audio file.

enum Flac {
    static func encode(_ pcm: [Int16], sampleRate: Int) -> Data {
        let bw = BitWriter()
        bw.appendByte(0x66); bw.appendByte(0x4C); bw.appendByte(0x61); bw.appendByte(0x43)  // "fLaC"

        let blockSize = 4096
        let n = pcm.count
        let maxBlk = n == 0 ? blockSize : min(blockSize, n)
        let minBlk: Int = n <= blockSize ? max(1, n) : (n % blockSize == 0 ? blockSize : n % blockSize)

        // STREAMINFO (last metadata block, type 0, 34 bytes)
        bw.bits(1, 1); bw.bits(0, 7); bw.bits(34, 24)
        bw.bits(UInt(minBlk), 16)
        bw.bits(UInt(maxBlk), 16)
        bw.bits(0, 24)                       // min frame size (unknown)
        bw.bits(0, 24)                       // max frame size (unknown)
        bw.bits(UInt(max(1, sampleRate)), 20)
        bw.bits(0, 3)                        // channels - 1 (mono)
        bw.bits(15, 5)                       // bits per sample - 1 (16-bit)
        bw.bits(UInt(n), 36)                 // total samples
        for _ in 0..<16 { bw.appendByte(0) } // MD5 = 0 (not computed; decoders accept this)

        var frame = 0, i = 0
        while i < n {
            let len = min(blockSize, n - i)
            encodeFrame(bw, pcm, start: i, count: len, frameNumber: frame)
            i += len; frame += 1
        }
        return bw.data()
    }

    private static func encodeFrame(_ bw: BitWriter, _ pcm: [Int16], start: Int, count: Int, frameNumber: Int) {
        let frameStart = bw.byteCount
        // --- Frame header ---
        bw.bits(0b11111111111110, 14)   // sync
        bw.bits(0, 1)                   // reserved
        bw.bits(0, 1)                   // fixed-blocksize strategy
        bw.bits(0b0111, 4)              // block size: 16-bit (blocksize-1) follows
        bw.bits(0b0000, 4)              // sample rate: from STREAMINFO
        bw.bits(0b0000, 4)              // channels: 1 (mono)
        bw.bits(0b100, 3)              // sample size: 16 bits
        bw.bits(0, 1)                   // reserved
        writeUTF8(bw, UInt(frameNumber))
        bw.bits(UInt(count - 1), 16)    // block size - 1
        let c8 = crc8(bw.bytes(from: frameStart))   // header is byte-aligned here
        bw.appendByte(c8)

        // --- Subframe (mono) ---
        writeSubframe(bw, pcm, start: start, count: count)

        // --- Frame footer: pad to byte, CRC-16 over the whole frame ---
        bw.align()
        let c16 = crc16(bw.bytes(from: frameStart))
        bw.bits(UInt(c16), 16)
    }

    private static func writeSubframe(_ bw: BitWriter, _ pcm: [Int16], start: Int, count: Int) {
        let bps = 16
        var x = [Int](repeating: 0, count: count)
        for k in 0..<count { x[k] = Int(pcm[start + k]) }

        // CONSTANT subframe if the whole block is one value.
        if let first = x.first, x.allSatisfy({ $0 == first }) {
            bw.bits(0, 1); bw.bits(0b000000, 6); bw.bits(0, 1)
            writeSigned(bw, first, bps)
            return
        }

        // Pick the FIXED order (0…4) with the smallest residual magnitude.
        let maxOrder = min(4, count - 1)
        var order = 0, residual = x, bestCost = Int.max
        for o in 0...maxOrder {
            let r = fixedResidual(x, order: o)
            let cost = r.reduce(0) { $0 + abs($1) } + o * bps   // + warmup-bit penalty
            if cost < bestCost { bestCost = cost; order = o; residual = r }
        }

        bw.bits(0, 1)                          // zero bit
        bw.bits(UInt(0b001000 | order), 6)     // FIXED, order in low 3 bits
        bw.bits(0, 1)                          // no wasted bits
        for k in 0..<order { writeSigned(bw, x[k], bps) }   // warmup samples, verbatim

        // Residual: partitioned Rice, 5-bit parameters, partition order 0.
        bw.bits(0b01, 2)
        bw.bits(0, 4)
        let k = bestRiceParam(residual)
        bw.bits(UInt(k), 5)
        for r in residual {
            let u = zigzag(r)
            let q = Int(u >> UInt(k))
            for _ in 0..<q { bw.bits(0, 1) }
            bw.bits(1, 1)
            if k > 0 { bw.bits(u & ((UInt(1) << UInt(k)) - 1), k) }
        }
    }

    /// Residuals of the FIXED predictor of the given order (samples order..<count).
    /// The arithmetic is split into named sub-terms — the one-line polynomial form
    /// trips Swift's "expression too complex to type-check in reasonable time".
    private static func fixedResidual(_ x: [Int], order: Int) -> [Int] {
        let n = x.count
        if order == 0 { return x }
        var out = [Int]()
        out.reserveCapacity(max(0, n - order))
        for i in order..<n {
            let r: Int
            switch order {
            case 1:
                r = x[i] - x[i - 1]
            case 2:
                r = x[i] - 2 * x[i - 1] + x[i - 2]
            case 3:
                let outer = x[i] - x[i - 3]
                let inner = 3 * (x[i - 1] - x[i - 2])
                r = outer - inner
            default:
                let ends = x[i] + x[i - 4]
                let near = 4 * (x[i - 1] + x[i - 3])
                let mid = 6 * x[i - 2]
                r = ends - near + mid
            }
            out.append(r)
        }
        return out
    }

    private static func zigzag(_ r: Int) -> UInt {
        UInt(bitPattern: (r << 1) ^ (r >> (Int.bitWidth - 1)))
    }

    /// Rice parameter (0…30) minimising total coded bits for the residual set.
    private static func bestRiceParam(_ residual: [Int]) -> Int {
        let us = residual.map { zigzag($0) }
        var bestK = 0, bestBits = Int.max
        for k in 0...30 {
            var bits = 0
            for u in us { bits += Int(u >> UInt(k)) + 1 + k }
            if bits < bestBits { bestBits = bits; bestK = k } else if bits > bestBits + (bestBits >> 2) { break }
        }
        return bestK
    }

    /// Frame number coded UTF-8-style (FLAC extends it to 36 bits).
    private static func writeUTF8(_ bw: BitWriter, _ value: UInt) {
        if value < 0x80 { bw.appendByte(UInt8(value)); return }
        let forms: [(UInt, Int, UInt8)] = [
            (0x800, 2, 0xC0), (0x10000, 3, 0xE0), (0x200000, 4, 0xF0),
            (0x4000000, 5, 0xF8), (0x80000000, 6, 0xFC), (0x1000000000, 7, 0xFE),
        ]
        for (limit, nbytes, prefix) in forms where value < limit {
            let cont = 6 * (nbytes - 1)
            bw.appendByte(prefix | UInt8(truncatingIfNeeded: value >> UInt(cont)))
            var shift = cont - 6
            for _ in 0..<(nbytes - 1) {
                bw.appendByte(0x80 | UInt8(truncatingIfNeeded: (value >> UInt(shift)) & 0x3F))
                shift -= 6
            }
            return
        }
    }

    private static func writeSigned(_ bw: BitWriter, _ v: Int, _ bits: Int) {
        let mask: UInt = bits >= 64 ? ~0 : (UInt(1) << UInt(bits)) - 1
        bw.bits(UInt(bitPattern: v) & mask, bits)
    }

    private static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes { crc ^= b; for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 } }
        return crc
    }

    private static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }

    /// MSB-first bit accumulator over a byte buffer.
    final class BitWriter {
        private var buf = [UInt8]()
        private var acc: UInt = 0
        private var nbits = 0

        var byteCount: Int { buf.count }                    // valid count when byte-aligned
        func bytes(from start: Int) -> ArraySlice<UInt8> { buf[start..<buf.count] }
        func data() -> Data { Data(buf) }

        func bits(_ value: UInt, _ count: Int) {
            var c = count
            while c > 0 { c -= 1; acc = (acc << 1) | ((value >> UInt(c)) & 1); nbits += 1
                if nbits == 8 { buf.append(UInt8(acc & 0xFF)); acc = 0; nbits = 0 } }
        }
        func appendByte(_ b: UInt8) {            // fast path when byte-aligned
            if nbits == 0 { buf.append(b) } else { bits(UInt(b), 8) }
        }
        func align() { while nbits != 0 { bits(0, 1) } }
    }
}
