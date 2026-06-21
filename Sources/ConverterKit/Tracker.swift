import Foundation

// MARK: - Legacy tracker module → IR
//
// Every tracker module (MOD/S3M/XM/IT/STM/669/DBM/MED + ~50 more) is parsed by
// the vendored libxmp (see Xmp.swift) into one neutral model (`TrackerModule`),
// which this converter turns into a composer-friendly IR song. Import-only: the
// goal is to make a legacy module easy to re-orchestrate in a modern DAW.
//
// Two decisions serve that goal specifically:
//   • Output tracks are grouped by instrument, not by tracker channel — so each
//     *sound* gets its own named lane (a channel reuses many instruments over
//     time, which is useless to a composer). When an instrument is also played
//     at sample offsets (9xx/Oxx) — a sliced / multi-sound sample, e.g. a
//     one-sample drum kit — those offsets are surfaced in the track comment.
//   • Each track carries a `comment` identifying the instrument — verbatim name
//     (often missing or just credits text), sample facts (length / loop), and a
//     usage-based guess (bass / percussion / lead / pad …) — so the composer can
//     pick a modern equivalent.
//
// Sample audio that libxmp decodes is carried out as embedded WAV clips (with
// root key + loop) by the DAWproject writer; the score, structure, and tempo
// map come across too.

/// One cell of a tracker pattern (a note slot + its columns/effects for a channel).
struct TCell {
    var note: Int?          // tracker note value, C-0 == 0 (nil = no note this row)
    var noteOff = false     // note-off / note-cut event
    var instrument: Int?    // 1-based instrument number (nil = none on this row)
    var volume: Int?        // 0...64 volume column (nil = none)
    var sampleOffset: Int?  // 9xx/Oxx parameter (slices a multi-sound sample)
    var setTempoBPM: Double? // tempo (BPM) change triggered on this row
    /// Raw libxmp effect columns (FX_* in effects.h). fx1 is the main effect,
    /// fx2 the secondary (often an XM/IT volume-column effect). 0 type = none.
    var fx1Type: Int = 0, fx1Param: Int = 0
    var fx2Type: Int = 0, fx2Param: Int = 0
}

/// Instrument/sample metadata used for naming + classification (no audio).
/// One sample within an instrument's keyzone map. A drum kit / layered XM/IT
/// instrument maps different key ranges to different samples; `noteStart…noteEnd`
/// is that range in cell-note space (libxmp note − 13, i.e. before any per-format
/// display offset). `transpose` is the subinstrument's tuning (xpo).
struct TSample {
    var name: String = ""
    var pcm: [Int16] = []
    var sampleRate: Int = 8363
    var channels: Int = 1
    var looped: Bool = false
    var loopStart: Int = 0
    var loopEnd: Int = 0
    var loopType: Int = 0
    var transpose: Int = 0
    var noteStart: Int = 0
    var noteEnd: Int = 119
}

struct TInstrument {
    var name: String = ""
    var sampleFrames: Int = 0   // length in sample frames (0 = unknown/empty)
    var looped: Bool = false
    var loopStart: Int = 0      // loop points, in sample frames
    var loopEnd: Int = 0
    var loopType: Int = 0       // 0 = forward, 1 = ping-pong, 2 = backward
    /// Semitone transpose implied by the sample's tuning (XM relative note,
    /// S3M/IT C5 playback rate). Added to pattern notes so the output lands in
    /// the octave the instrument actually sounds at.
    var transpose: Int = 0
    /// Decoded 16-bit PCM (empty if not decoded), and its playback rate.
    /// Interleaved L/R when `channels` == 2 (libxmp XMP_SAMPLE_STEREO), else mono.
    var pcm: [Int16] = []
    var sampleRate: Int = 8363
    var channels: Int = 1
    /// New Note Action mapped to Renoise's vocabulary: Cut / NoteOff / None.
    var newNoteAction: String = "NoteOff"
    /// Volume envelope reduced to AHDSR (XM/IT envelope, or AM-synth amplitude
    /// envelope), nil if the instrument has none.
    var envelope: ADSR? = nil
    /// Keyzone map for a multi-sample (key-mapped) instrument — a drum kit or a
    /// layered XM/IT instrument. Empty for the common single-sample case (the
    /// fields above describe that one sample); when non-empty it holds every
    /// sample with its own key range, and the fields above mirror the primary
    /// (widest-range) entry so the flattening IR path still has one sample.
    var samples: [TSample] = []
}

/// Neutral representation populated from a parsed module.
struct TrackerModule {
    var format: String                  // short tag for messages/comments ("MOD", "XM", …)
    var title: String = ""
    var channels: Int = 4
    var rowsPerBeat: Int = 4            // assumed grid (tracker convention: 4 rows/beat)
    var initialTempoBPM: Double = 125
    var initialSpeed: Int = 6           // ticks per row (module "speed"); Renoise TicksPerLine
    var instruments: [TInstrument] = [] // index 0 == instrument 1
    var order: [Int] = []               // pattern indices, in play order
    var patterns: [[[TCell]]] = []      // [pattern][row][channel]
    var channelPans: [Double] = []      // per-channel pan 0…1 (0.5 = centre); Amiga LRRL etc.
}

/// How a module's notes are laid out across IR tracks.
///   • `.instrument` — one track per *instrument* (a mixing/re-orchestration
///     view: each sound on its own named channel; track == instrument).
///   • `.channel` — one track per *tracker channel* (a faithful/tracker-idiom
///     view: preserves channel effect continuity and Amiga stereo; each note
///     carries its own instrument reference, since a channel time-shares many).
enum TrackLayout { case instrument, channel }

enum Tracker {
    /// Convert a parsed module to a composer-friendly IR song, in the requested
    /// track layout (see `TrackLayout`).
    static func toIR(_ m: TrackerModule, layout: TrackLayout = .instrument) -> IRSong {
        var song = IRSong()
        song.title = m.title.isEmpty ? nil : m.title

        // A speed/tempo effect on the first played row sets the effective start
        // values (the header speed is only a default).
        func speedChange(_ cell: TCell) -> Int? {
            if cell.fx1Type == 0x0F, cell.fx1Param >= 1, cell.fx1Param < 0x20 { return cell.fx1Param }
            if cell.fx1Type == 0xA3, cell.fx1Param >= 1 { return cell.fx1Param }   // S3M/IT speed
            return nil
        }
        var startSpeed = max(1, m.initialSpeed)
        var startBPM = m.initialTempoBPM
        if let p = m.order.first(where: { $0 >= 0 && $0 < m.patterns.count }),
           let firstRow = m.patterns[p].first {
            for cell in firstRow {
                if let sp = speedChange(cell) { startSpeed = sp }
                if let bpm = cell.setTempoBPM { startBPM = bpm }
            }
        }
        // Rows per beat: 4 at the classic speed 6. A faster speed (< 6) means finer
        // rows, so use proportionally more rows/beat to keep the musical tempo ≈ the
        // tracker BPM; a slower speed (> 6) keeps 4 rows/beat and lowers the tempo.
        // This makes DAWproject/MIDI tempos match the song, not the raw tracker BPM.
        let rpb = 24.0 / Double(min(6, startSpeed))
        song.gridLinesPerBeat = max(1, Int(rpb.rounded()))

        // musical BPM = 24·BPM / (rowsPerBeat·speed): equals the tracker BPM at the
        // start; mid-song speed changes scale it. The direct Renoise path keeps raw
        // BPM + TicksPerLine=speed and is unaffected.
        func musicalBPM(_ bpm: Double, _ speed: Int) -> Double { 24.0 * bpm / (rpb * Double(max(1, speed))) }

        struct Open { var startBeat: Double; var key: Int; var velocity: Double; var instrument: Int; var offset: Int }
        struct ParsedNote { var channel: Int; var instrument: Int; var note: IRNote }

        // Reconstruct notes once (channel is monophonic: a new note or note-off
        // closes the channel's open note), tagged with channel + instrument so
        // either layout can be assembled from the same parse.
        var parsed: [ParsedNote] = []
        var offsetsUsed: [Int: Set<Int>] = [:]
        var open = [Open?](repeating: nil, count: m.channels)
        var lastInstrument = [Int](repeating: 0, count: m.channels)
        var curBPM = startBPM
        var curSpeed = startSpeed
        var tempoEvents = [IRTempoPoint(time: 0, bpm: musicalBPM(curBPM, curSpeed))]

        func close(_ o: Open, channel: Int, at endBeat: Double) {
            let length = max(1.0 / rpb, endBeat - o.startBeat)
            parsed.append(ParsedNote(channel: channel, instrument: o.instrument,
                note: IRNote(start: o.startBeat, length: length, key: o.key, velocity: o.velocity,
                             sampleOffset: o.offset > 0 ? o.offset : nil)))
            if o.offset > 0 { offsetsUsed[o.instrument, default: []].insert(o.offset) }
        }

        var beatOffset = 0.0
        for patternIndex in m.order {
            guard patternIndex >= 0, patternIndex < m.patterns.count else { continue }
            let pattern = m.patterns[patternIndex]
            for (r, row) in pattern.enumerated() {
                let rowBeat = beatOffset + Double(r) / rpb
                for ch in 0..<min(m.channels, row.count) {
                    let cell = row[ch]
                    if let sp = speedChange(cell) {
                        curSpeed = sp
                        tempoEvents.append(IRTempoPoint(time: rowBeat, bpm: musicalBPM(curBPM, curSpeed)))
                    }
                    if let bpm = cell.setTempoBPM {
                        curBPM = bpm
                        tempoEvents.append(IRTempoPoint(time: rowBeat, bpm: musicalBPM(curBPM, curSpeed)))
                    }
                    if let inst = cell.instrument { lastInstrument[ch] = inst }
                    guard cell.note != nil || cell.noteOff else { continue }

                    if let o = open[ch] { close(o, channel: ch, at: rowBeat); open[ch] = nil }
                    if let nv = cell.note {
                        let inst = cell.instrument ?? lastInstrument[ch]
                        let transpose = (inst >= 1 && inst <= m.instruments.count) ? m.instruments[inst - 1].transpose : 0
                        open[ch] = Open(startBeat: rowBeat,
                                        key: min(127, max(0, nv + transpose + 12)),
                                        velocity: cell.volume.map { Double(min(64, max(0, $0))) / 64.0 } ?? 1.0,
                                        instrument: inst,
                                        offset: cell.sampleOffset ?? 0)
                    }
                }
            }
            beatOffset += Double(pattern.count) / rpb
        }
        for ch in 0..<m.channels { if let o = open[ch] { close(o, channel: ch, at: beatOffset) } }

        let songEnd = max(beatOffset, parsed.map { $0.note.start + $0.note.length }.max() ?? 0)
        func info(_ n: Int) -> TInstrument? { (n >= 1 && n <= m.instruments.count) ? m.instruments[n - 1] : nil }
        func extracted(_ n: Int, name: String, comment: String?) -> ExtractedSample? {
            guard let i = info(n), !i.pcm.isEmpty else { return nil }
            return ExtractedSample(name: name, comment: comment, pcm: i.pcm,
                                   sampleRate: i.sampleRate, channels: i.channels,
                                   rootKey: 60 + i.transpose,
                                   loopStart: i.looped ? i.loopStart : 0,
                                   loopEnd: i.looped ? i.loopEnd : 0,
                                   loopType: i.loopType, newNoteAction: i.newNoteAction,
                                   envelope: i.envelope)
        }

        // Notes grouped per instrument (for naming/identification in both layouts).
        var notesByInstrument: [Int: [IRNote]] = [:]
        for p in parsed { notesByInstrument[p.instrument, default: []].append(p.note) }

        switch layout {
        case .instrument:
            // One lane per *sound*; track == instrument, so notes need no explicit
            // instrument reference (the Renoise writer uses the track's index).
            for inst in notesByInstrument.keys.sorted() {
                let notes = notesByInstrument[inst]!.sorted { $0.start < $1.start }
                let (name, comment) = describe(format: m.format, instrument: inst, info: info(inst),
                                               notes: notes, offsets: offsetsUsed[inst] ?? [])
                var track = IRTrack(role: .regular, name: name, comment: comment)
                track.clips = [IRClip(start: 0, length: songEnd, name: nil, notes: notes)]
                song.tracks.append(track)
                if let s = extracted(inst, name: name, comment: comment) { song.extractedSamples.append(s) }
            }

        case .channel:
            // Build the instrument table (used instruments, in number order) so
            // notes can reference instruments by index; one track per channel.
            let used = Set(parsed.map { $0.instrument }).sorted()
            var indexOf: [Int: Int] = [:]
            for (i, n) in used.enumerated() {
                indexOf[n] = i
                let iNotes = (notesByInstrument[n] ?? []).sorted { $0.start < $1.start }
                let (name, comment) = describe(format: m.format, instrument: n, info: info(n),
                                               notes: iNotes, offsets: offsetsUsed[n] ?? [])
                let sample = extracted(n, name: name, comment: comment)
                song.instruments.append(IRInstrument(name: name, sample: sample))
                if let s = sample { song.extractedSamples.append(s) }
            }
            for ch in 0..<m.channels {
                let notes = parsed.filter { $0.channel == ch }
                    .map { p -> IRNote in var n = p.note; n.instrument = indexOf[p.instrument]; return n }
                    .sorted { $0.start < $1.start }
                let pan = ch < m.channelPans.count ? m.channelPans[ch] : 0.5
                var track = IRTrack(role: .regular, name: "Channel \(ch + 1)", pan: pan)
                track.clips = [IRClip(start: 0, length: songEnd, name: nil, notes: notes)]
                song.tracks.append(track)
            }
        }

        let deduped = dedupTempo(tempoEvents)
        if deduped.count > 1 { song.setTempoMap(deduped) }
        else { song.tempo = musicalBPM(startBPM, startSpeed) }
        return song
    }

    // MARK: Instrument identification

    /// Produce a track name + an identifying comment for one instrument,
    /// combining the verbatim name, sample facts, score usage, and any
    /// sample-offset usage (which signals a sliced / multi-sound sample).
    private static func describe(format: String, instrument: Int, info: TInstrument?,
                                 notes: [IRNote], offsets: Set<Int>) -> (name: String, comment: String) {
        let rawName = (info?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? "\(format) \(instrument)" : rawName

        let keys = notes.map { $0.key }
        let lo = keys.min() ?? 60, hi = keys.max() ?? 60
        let distinct = Set(keys).count
        let poly = maxConcurrency(notes)
        let looped = info?.looped ?? false
        let frames = info?.sampleFrames ?? 0
        let short = frames > 0 && frames < 4000           // ~<0.1 s at typical rates
        let sliced = !offsets.isEmpty

        let guess: String
        if sliced && distinct <= 2 {
            guess = "drum kit / sliced sample (multiple sounds in one sample)"
        } else if distinct <= 2 && (short || !looped) {
            guess = "percussion / one-shot"
        } else if hi <= 50 && poly <= 1 {
            guess = "bass"
        } else if looped && poly >= 2 {
            guess = "pad / chords"
        } else if lo >= 64 && poly <= 1 {
            guess = "lead"
        } else if looped {
            guess = "sustained instrument"
        } else {
            guess = "instrument"
        }

        var parts: [String] = ["\(format) instrument \(instrument)"]
        if !rawName.isEmpty { parts.append("name: \"\(rawName)\"") }
        parts.append("\(notes.count) notes, \(Pitch.renoiseName(fromMidi: lo))–\(Pitch.renoiseName(fromMidi: hi))")
        parts.append(poly >= 2 ? "polyphonic" : "monophonic")
        if frames > 0 {
            if looped {
                let kinds = ["forward", "ping-pong", "backward"]
                parts.append("looped sample (\(kinds[min(2, max(0, info?.loopType ?? 0))]))")
            } else {
                parts.append("one-shot sample (\(frames) frames)")
            }
        }
        if sliced {
            let list = offsets.sorted().map { "0x\(String(format: "%02X", $0))00" }.joined(separator: ", ")
            parts.append("played at sample offsets [\(list)] — a sliced / multi-sound sample"
                         + (looped ? " / loop entered at different points" : "")
                         + "; the sound varies by start point")
        }
        parts.append("likely \(guess)")
        return (name, parts.joined(separator: "; "))
    }

    private static func maxConcurrency(_ notes: [IRNote]) -> Int {
        var events: [(time: Double, delta: Int)] = []
        for n in notes { events.append((n.start, 1)); events.append((n.start + n.length, -1)) }
        events.sort { $0.time != $1.time ? $0.time < $1.time : $0.delta < $1.delta }
        var current = 0, peak = 0
        for e in events { current += e.delta; peak = max(peak, current) }
        return peak
    }

    private static func dedupTempo(_ points: [IRTempoPoint]) -> [IRTempoPoint] {
        var out: [IRTempoPoint] = []
        for p in points.sorted(by: { $0.time < $1.time }) {
            if let last = out.last, abs(last.bpm - p.bpm) < 1e-6 { continue }
            out.append(p)
        }
        return out
    }
}

enum TrackerError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String { switch self { case let .malformed(m): return "malformed module: \(m)" } }
}
