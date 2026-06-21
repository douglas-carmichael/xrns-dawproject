import Foundation

// MARK: - Minimal WAV (RIFF/PCM) encoder
//
// Encodes 16-bit mono PCM for embedding extracted tracker samples. Writes a
// `smpl` chunk carrying the root key and (if present) the sample loop, so a
// modern sampler picks up both automatically. Pure Swift, little-endian.

enum Wav {
    /// `loopType` matches the WAV `smpl` convention: 0 = forward, 1 = alternating
    /// (ping-pong), 2 = backward.
    static func encode(_ pcm: [Int16], sampleRate: Int, channels: Int = 1,
                       rootKey: Int = 60, loopStart: Int = 0, loopEnd: Int = 0, loopType: Int = 0) -> Data {
        let rate = max(1, sampleRate)
        let hasLoop = loopEnd > loopStart && loopEnd <= pcm.count

        func u16(_ v: Int, into out: inout [UInt8]) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        }
        func u32(_ v: Int, into out: inout [UInt8]) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
        }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            var c = Array(id.utf8)
            u32(body.count, into: &c)
            c += body
            if body.count % 2 == 1 { c.append(0) }   // word-align
            return c
        }

        // fmt chunk
        var fmt = [UInt8]()
        u16(1, into: &fmt)                            // PCM
        u16(channels, into: &fmt)
        u32(rate, into: &fmt)
        u32(rate * channels * 2, into: &fmt)          // byte rate
        u16(channels * 2, into: &fmt)                 // block align
        u16(16, into: &fmt)                           // bits per sample

        // data chunk
        var data = [UInt8](); data.reserveCapacity(pcm.count * 2)
        for s in pcm { let u = UInt16(bitPattern: s); data.append(UInt8(u & 0xFF)); data.append(UInt8((u >> 8) & 0xFF)) }

        // smpl chunk (root note + optional loop)
        var smpl = [UInt8]()
        u32(0, into: &smpl); u32(0, into: &smpl)                  // manufacturer, product
        u32(1_000_000_000 / rate, into: &smpl)                   // sample period (ns)
        u32(max(0, min(127, rootKey)), into: &smpl)              // MIDI unity note
        u32(0, into: &smpl); u32(0, into: &smpl); u32(0, into: &smpl)  // pitch frac, SMPTE fmt, offset
        u32(hasLoop ? 1 : 0, into: &smpl)                        // number of loops
        u32(0, into: &smpl)                                      // sampler-specific data
        if hasLoop {
            u32(0, into: &smpl); u32(max(0, min(2, loopType)), into: &smpl)   // cue id, loop type
            u32(loopStart, into: &smpl); u32(loopEnd, into: &smpl)
            u32(0, into: &smpl); u32(0, into: &smpl)             // fraction, play count (0 = infinite)
        }

        var body = Array("WAVE".utf8)
        body += chunk("fmt ", fmt)
        body += chunk("data", data)
        body += chunk("smpl", smpl)

        var out = Array("RIFF".utf8)
        u32(body.count, into: &out)
        out += body
        return Data(out)
    }

    /// Decode a RIFF/PCM WAV to interleaved 16-bit samples. Handles 8-bit
    /// (unsigned, promoted to signed 16-bit) and 16-bit PCM; returns nil for
    /// other encodings or malformed input.
    static func decode(_ data: Data) -> (pcm: [Int16], channels: Int, sampleRate: Int)? {
        let b = [UInt8](data)
        guard b.count > 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,  // "RIFF"
              b[8] == 0x57, b[9] == 0x41, b[10] == 0x56, b[11] == 0x45 else { return nil }  // "WAVE"
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }

        var off = 12, channels = 1, rate = 44100, bits = 16
        while off + 8 <= b.count {
            let id = String(bytes: b[off ..< off + 4], encoding: .ascii) ?? ""
            let size = u32(off + 4)
            if id == "fmt " {
                channels = max(1, u16(off + 10)); rate = u32(off + 12); bits = u16(off + 22)
            } else if id == "data" {
                let start = off + 8, end = min(b.count, start + size)
                var pcm: [Int16] = []
                if bits == 16 {
                    pcm.reserveCapacity((end - start) / 2)
                    var i = start
                    while i + 1 < end { pcm.append(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)); i += 2 }
                } else if bits == 8 {
                    pcm.reserveCapacity(end - start)
                    for i in start ..< end { pcm.append(Int16(truncatingIfNeeded: (Int(b[i]) - 128) << 8)) }
                } else {
                    return nil
                }
                return (pcm, channels, max(1, rate))
            }
            off += 8 + size + (size & 1)
        }
        return nil
    }
}
