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
}
