import Foundation

// MARK: - Standard MIDI File (SMF) I/O  (pure Swift, no dependencies)
//
// Reads Format 0/1 files with PPQ (ticks-per-quarter) division; writes Format 1
// with a conductor track (song name + time signature + full tempo map) followed
// by one track per note track. Maps directly to/from the IR. MIDI integers are
// big-endian (note: ZIP, in Zip.swift, is little-endian).

enum SmfError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String { switch self { case let .malformed(m): return "malformed MIDI file: \(m)" } }
}

enum Smf {
    static let writePPQ = 960   // ticks per quarter note used when writing

    // MARK: Reading

    static func read(_ data: Data) throws -> IRSong {
        var r = Reader([UInt8](data))
        guard r.ascii(4) == "MThd" else { throw SmfError.malformed("missing MThd header") }
        let headerLen = Int(r.u32())
        guard headerLen >= 6 else { throw SmfError.malformed("bad header length") }
        _ = r.u16()                                   // format (0/1/2) — handled uniformly
        let ntracks = Int(r.u16())
        let division = Int16(bitPattern: r.u16())
        guard division > 0 else { throw SmfError.malformed("SMPTE time division is not supported") }
        let ppq = Double(division)
        r.skip(headerLen - 6)

        var song = IRSong()
        var tempoPoints: [IRTempoPoint] = []
        var firstTimeSig: (Int, Int)?
        var tracks: [IRTrack] = []

        for _ in 0..<ntracks {
            guard r.ascii(4) == "MTrk" else { throw SmfError.malformed("missing MTrk chunk") }
            let len = Int(r.u32())
            let end = min(r.pos + len, r.count)
            var tick = 0
            var status: UInt8 = 0
            var trackName: String?
            var pending: [Int: [(tick: Int, vel: Int)]] = [:]   // (channel<<8|key) -> note-ons
            var notes: [IRNote] = []

            while r.pos < end {
                tick += r.vlq()
                var b = r.u8()
                if b < 0x80 {            // running status: reuse last, rewind the data byte
                    r.pos -= 1
                    b = status
                } else if b < 0xF0 {     // channel message sets running status
                    status = b
                } else {                 // system/meta message clears running status
                    status = 0
                }

                switch b & 0xF0 {
                case 0x80, 0x90:                                 // note off / note on
                    let key = Int(r.u8()), vel = Int(r.u8()), channel = Int(b & 0x0F)
                    let id = (channel << 8) | key
                    if b & 0xF0 == 0x90 && vel > 0 {
                        pending[id, default: []].append((tick, vel))
                    } else if var q = pending[id], !q.isEmpty {
                        let on = q.removeFirst(); pending[id] = q
                        notes.append(IRNote(start: Double(on.tick) / ppq,
                                            length: max(1.0 / ppq, Double(tick - on.tick) / ppq),
                                            key: key, velocity: Double(on.vel) / 127.0))
                    }
                case 0xA0, 0xB0, 0xE0: r.skip(2)                 // poly-AT / CC / pitch-bend
                case 0xC0, 0xD0: r.skip(1)                       // program / channel pressure
                case 0xF0:
                    if b == 0xFF {                               // meta event
                        let type = r.u8()
                        let mlen = r.vlq()
                        let payload = r.pos
                        switch type {
                        case 0x51:                               // set tempo (µs per quarter)
                            let us = (Int(r.u8()) << 16) | (Int(r.u8()) << 8) | Int(r.u8())
                            if us > 0 { tempoPoints.append(IRTempoPoint(time: Double(tick) / ppq, bpm: 60_000_000.0 / Double(us))) }
                        case 0x58:                               // time signature: nn dd cc bb
                            let nn = Int(r.u8()), dd = Int(r.u8())
                            if firstTimeSig == nil { firstTimeSig = (nn, 1 << dd) }
                        case 0x03: trackName = r.ascii(mlen)     // track / sequence name
                        default: break
                        }
                        r.pos = payload + mlen
                    } else if b == 0xF0 || b == 0xF7 {           // SysEx
                        r.skip(r.vlq())
                    }
                default: break
                }
            }
            r.pos = end                                          // resync to chunk end

            if !notes.isEmpty {
                var t = IRTrack(role: .regular, name: trackName ?? "Track \(tracks.count + 1)")
                let trackEnd = notes.map { $0.start + $0.length }.max() ?? 0
                t.clips = [IRClip(start: 0, length: trackEnd, name: nil, notes: notes.sorted { $0.start < $1.start })]
                tracks.append(t)
            } else if let trackName, song.title == nil {
                song.title = trackName                            // conductor/name track
            }
        }

        if let (n, d) = firstTimeSig { song.signatureNumerator = n; song.signatureDenominator = d }
        if !tempoPoints.isEmpty { song.setTempoMap(dedup(tempoPoints)) }
        song.tracks = tracks
        return song
    }

    private static func dedup(_ points: [IRTempoPoint]) -> [IRTempoPoint] {
        var out: [IRTempoPoint] = []
        for p in points.sorted(by: { $0.time < $1.time }) {
            if let last = out.last, abs(last.bpm - p.bpm) < 1e-6 { continue }
            out.append(p)
        }
        return out
    }

    // MARK: Writing

    static func write(_ song: IRSong) -> Data {
        let ppq = writePPQ
        func ticks(_ beats: Double) -> Int { Int((beats * Double(ppq)).rounded()) }

        let noteTracks = song.tracks.filter { $0.role == .regular && !$0.absoluteNotes.isEmpty }

        var out = Array("MThd".utf8)
        appendU32(&out, 6)
        appendU16(&out, 1)                                    // format 1
        appendU16(&out, UInt16(1 + noteTracks.count))
        appendU16(&out, UInt16(ppq))

        // Conductor track: name, time signature, tempo map.
        var conductor: [Event] = []
        if let title = song.title { conductor.append(Event(0, meta(0x03, Array(title.utf8)))) }
        let dd = UInt8(max(0, Int(log2(Double(max(1, song.signatureDenominator))).rounded())))
        conductor.append(Event(0, meta(0x58, [UInt8(clamping: song.signatureNumerator), dd, 24, 8])))
        for tp in song.resolvedTempoMap {
            let us = max(1, Int((60_000_000.0 / tp.bpm).rounded()))
            conductor.append(Event(ticks(tp.time), meta(0x51, [UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)])))
        }
        out += trackChunk(conductor)

        // One MTrk per note track (channel 0).
        for t in noteTracks {
            var events: [Event] = [Event(0, meta(0x03, Array(t.name.utf8)))]
            for n in t.absoluteNotes {
                let on = ticks(n.start)
                let off = max(on + 1, ticks(n.start + n.length))
                let key = UInt8(clamping: n.key)
                let vel = UInt8(min(127, max(1, Int((n.velocity * 127).rounded()))))
                events.append(Event(on, [0x90, key, vel]))
                events.append(Event(off, [0x80, key, 0]))
            }
            out += trackChunk(events)
        }
        return Data(out)
    }

    private struct Event { var tick: Int; var bytes: [UInt8]; init(_ t: Int, _ b: [UInt8]) { tick = t; bytes = b } }

    /// Serialise events into an MTrk chunk. Events are ordered by tick, then by
    /// type (meta, then note-off, then note-on) so coincident events are safe.
    private static func trackChunk(_ events: [Event]) -> [UInt8] {
        func rank(_ s: UInt8) -> Int { s == 0xFF ? 0 : (s & 0xF0 == 0x80 ? 1 : (s & 0xF0 == 0x90 ? 3 : 2)) }
        let ordered = events.enumerated()
            .sorted {
                ($0.element.tick, rank($0.element.bytes[0]), $0.offset)
                    < ($1.element.tick, rank($1.element.bytes[0]), $1.offset)
            }
            .map { $0.element }

        var body = [UInt8]()
        var last = 0
        for e in ordered {
            appendVLQ(&body, e.tick - last)
            last = e.tick
            body += e.bytes
        }
        appendVLQ(&body, 0); body += [0xFF, 0x2F, 0x00]       // end of track

        var chunk = Array("MTrk".utf8)
        appendU32(&chunk, UInt32(body.count))
        return chunk + body
    }

    private static func meta(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var e: [UInt8] = [0xFF, type]
        appendVLQ(&e, payload.count)
        return e + payload
    }

    // MARK: Big-endian + VLQ helpers

    private static func appendU16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
    }
    private static func appendU32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
    }
    private static func appendVLQ(_ out: inout [UInt8], _ value: Int) {
        var v = max(0, value)
        var buf = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { buf.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        out += buf.reversed()
    }

    private struct Reader {
        let b: [UInt8]; var pos = 0
        var count: Int { b.count }
        init(_ bytes: [UInt8]) { b = bytes }
        mutating func u8() -> UInt8 { let v = pos < b.count ? b[pos] : 0; pos += 1; return v }
        mutating func u16() -> UInt16 { (UInt16(u8()) << 8) | UInt16(u8()) }
        mutating func u32() -> UInt32 { (UInt32(u16()) << 16) | UInt32(u16()) }
        mutating func skip(_ n: Int) { pos += max(0, n) }
        mutating func ascii(_ n: Int) -> String {
            let e = min(pos + max(0, n), b.count)
            let s = String(decoding: b[min(pos, b.count)..<e], as: UTF8.self)
            pos += n
            return s
        }
        mutating func vlq() -> Int {
            var v = 0
            while pos < b.count {
                let byte = b[pos]; pos += 1
                v = (v << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            return v
        }
    }
}
