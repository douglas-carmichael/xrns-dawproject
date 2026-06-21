import Foundation

enum ConvertError: Error, CustomStringConvertible {
    case usage(String)
    case parse(String)
    case io(String)

    var description: String {
        switch self {
        case let .usage(m): return m
        case let .parse(m): return "parse error: \(m)"
        case let .io(m): return "i/o error: \(m)"
        }
    }
}

/// Summary statistics surfaced to the user after a conversion.
struct ConvertStats {
    var tracks = 0
    var notes = 0
    var patternsOrClips = 0
    var droppedNotes = 0
    var linesPerBeat = 0   // the LPB grid used for DAWproject -> XRNS
}

// MARK: - XRNS -> IR (forward)
//
// Walks the Renoise PatternSequence *in order* and lays one clip per pattern
// instance onto the arrangement, so the DAWproject timeline reproduces the song
// exactly as the pattern order plays it.

enum ToIR {
    static func fromRenoise(_ rs: RenoiseSong, stats: inout ConvertStats) -> IRSong {
        var song = IRSong()
        song.tempo = rs.bpm
        song.signatureNumerator = rs.signatureNumerator
        song.signatureDenominator = rs.signatureDenominator
        song.title = rs.songName
        song.artist = rs.artist
        song.comment = rs.comments.isEmpty ? nil
            : rs.comments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let lpb = Double(max(1, rs.linesPerBeat))

        var irTracks = rs.tracks.map {
            IRTrack(role: $0.kind, name: $0.name, color: $0.color,
                    volume: $0.volume, pan: $0.pan, mute: $0.muted, solo: $0.soloed)
        }

        var offset = 0.0
        var tempoEvents = [IRTempoPoint(time: 0, bpm: rs.bpm)]
        for patternIndex in rs.sequence {
            guard patternIndex >= 0, patternIndex < rs.patterns.count else { continue }
            let pattern = rs.patterns[patternIndex]
            let lengthBeats = Double(pattern.numberOfLines) / lpb

            // Tempo (ZTxx) commands anywhere in this pattern → tempo-map points.
            for pt in pattern.tracks {
                for line in pt.lines {
                    for ec in line.effectColumns where ec.number == "ZT" {
                        if let bpm = ec.value.flatMap({ Int($0, radix: 16) }), bpm > 0 {
                            tempoEvents.append(IRTempoPoint(time: offset + Double(line.index) / lpb, bpm: Double(bpm)))
                        }
                    }
                }
            }

            for ti in rs.tracks.indices where ti < pattern.tracks.count {
                let notes = notesFromPatternTrack(pattern.tracks[ti],
                                                  numberOfLines: pattern.numberOfLines,
                                                  lpb: lpb, tpl: rs.ticksPerLine)
                if !notes.isEmpty {
                    irTracks[ti].clips.append(IRClip(start: offset, length: lengthBeats,
                                                     name: nil, notes: notes))
                    stats.notes += notes.count
                    stats.patternsOrClips += 1
                }
            }
            offset += lengthBeats
        }

        song.tracks = irTracks
        // Adopt a tempo map only if ZT commands actually varied the tempo.
        let dedupedTempo = dedupTempo(tempoEvents)
        if dedupedTempo.count > 1 { song.setTempoMap(dedupedTempo) }
        stats.tracks = irTracks.count
        return song
    }

    /// Convert one pattern-track's tracker lines into notes with computed
    /// durations. Each note column is scanned independently: a note rings until
    /// the next note or an "OFF" in the same column, or the end of the pattern.
    ///
    /// Per-note Renoise commands are interpreted where DAWproject's note model
    /// (time / duration / key / velocity) can represent them faithfully:
    ///   • volume column 00–80            → note velocity
    ///   • note delay (delay column, `Qx`, `0Qxx`) → fractional start position
    ///   • note cut (`Cx`, `0C0y`)        → shortened duration
    /// Continuous-pitch commands (glide `0G`/`Gx`, slides `0U`/`0D`, arpeggio
    /// `0A`, vibrato `0V`) and probability/retrigger have no faithful target in
    /// DAWproject 1.0, so the note keeps its written (target) pitch.
    private static func notesFromPatternTrack(_ pt: RNPatternTrack, numberOfLines: Int,
                                              lpb: Double, tpl: Int) -> [IRNote] {
        struct Event { var pos: Double; var key: Int?; var velocity: Double; var isOff: Bool; var cutEnd: Double? }
        var byColumn: [Int: [Event]] = [:]
        let tplD = Double(max(1, tpl))

        for line in pt.lines {
            // Line-level effect-column commands apply to notes started on this line.
            var lineDelayTicks = 0
            var lineCutTicks: Int?
            for ec in line.effectColumns {
                guard let number = ec.number, let cmd = number.last else { continue }
                let value = ec.value.flatMap { Int($0, radix: 16) } ?? 0
                switch cmd {
                case "Q": lineDelayTicks = value                               // 0Qxx: delay xx ticks
                case "C": if value >> 4 == 0 { lineCutTicks = value & 0x0F }    // 0C0y: cut after y ticks
                default: break
                }
            }

            for (col, nc) in line.noteColumns.enumerated() {
                guard let token = nc.note else { continue }
                let vol = parseVolumePan(nc.volume)
                let pan = parseVolumePan(nc.panning)

                // Delay: delay column (xx/256 of a line) + `Qx` (vol/pan) + `0Qxx` (effect).
                var delayLines = Double(nc.delay.flatMap { Int($0, radix: 16) } ?? 0) / 256.0
                if let q = command("Q", vol, pan) { delayLines += Double(q) / tplD }
                if lineDelayTicks > 0 { delayLines += Double(lineDelayTicks) / tplD }
                let pos = Double(line.index) + delayLines

                if token == "OFF" || token == "---" {
                    byColumn[col, default: []].append(Event(pos: pos, key: nil, velocity: 0, isOff: true, cutEnd: nil))
                } else if let key = Pitch.midiKey(fromRenoise: token) {
                    let velocity = vol.value.map { Double($0) / 128.0 } ?? 1.0
                    // Note cut → absolute end position (lines from this line's start).
                    var cutEnd: Double?
                    if let c = command("C", vol, pan) { cutEnd = Double(line.index) + Double(c) / tplD }
                    if let c = lineCutTicks { cutEnd = Double(line.index) + Double(c) / tplD }
                    byColumn[col, default: []].append(
                        Event(pos: pos, key: key, velocity: velocity, isOff: false, cutEnd: cutEnd))
                }
            }
        }

        var notes: [IRNote] = []
        for (_, events) in byColumn {
            let sorted = events.sorted { $0.pos < $1.pos }
            var open: (start: Double, key: Int, velocity: Double, cutEnd: Double?)?
            for e in sorted {
                if let o = open {
                    var end = e.pos
                    if let cut = o.cutEnd { end = min(end, cut) }
                    appendNote(&notes, start: o.start, end: end, key: o.key, velocity: o.velocity, lpb: lpb)
                    open = nil
                }
                if !e.isOff, let key = e.key { open = (e.pos, key, e.velocity, e.cutEnd) }
            }
            if let o = open {
                var end = Double(numberOfLines)
                if let cut = o.cutEnd { end = min(end, cut) }
                appendNote(&notes, start: o.start, end: end, key: o.key, velocity: o.velocity, lpb: lpb)
            }
        }
        return notes.sorted { $0.start < $1.start }
    }

    private static func appendNote(_ notes: inout [IRNote], start: Double, end: Double,
                                   key: Int, velocity: Double, lpb: Double) {
        let startBeats = start / lpb
        var lengthBeats = (end - start) / lpb
        if lengthBeats <= 0 { lengthBeats = 1.0 / lpb }   // minimum one line
        notes.append(IRNote(start: startBeats, length: lengthBeats, key: key, velocity: velocity))
    }

    /// A volume/panning column cell: either a 00–80 value or a letter command + nibble.
    private struct VolPan { var value: Int?; var command: (Character, Int)? }

    private static func parseVolumePan(_ s: String?) -> VolPan {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return VolPan(value: nil, command: nil)
        }
        if raw.count == 2, let v = Int(raw, radix: 16), v <= 0x80 {
            return VolPan(value: v, command: nil)              // 00–80 level
        }
        if raw.count == 2, let first = raw.first, first.isLetter,
           let param = Int(String(raw.dropFirst()), radix: 16) {
            return VolPan(value: nil, command: (first, param)) // e.g. C5, Q3, G8
        }
        return VolPan(value: nil, command: nil)
    }

    /// Look up a single-letter command (e.g. "C", "Q") in either column.
    private static func command(_ letter: Character, _ vol: VolPan, _ pan: VolPan) -> Int? {
        if let c = vol.command, c.0 == letter { return c.1 }
        if let c = pan.command, c.0 == letter { return c.1 }
        return nil
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

// MARK: - IR -> XRNS (reverse)
//
// The continuous DAWproject arrangement is quantised onto a tracker line grid
// and segmented into fixed-length patterns. Note durations become note-on /
// "OFF" pairs; overlapping notes on one track are spread across note columns.
// The grid (lines-per-beat) is derived from tempo unless overridden.

enum ToRenoise {
    /// Derive a lines-per-beat grid from tempo so the per-line duration stays
    /// near a musically useful target (~62 ms, i.e. ~8 lines/beat at 120 BPM):
    /// slower songs get a finer grid, faster songs a coarser one. Snapped to a
    /// power of two in [4, 32] — the tracker norm, dividing beats into clean
    /// binary subdivisions. The `.xrns` extension is version-stable, so this
    /// applies regardless of the Renoise version that later opens the file.
    static func derivedLinesPerBeat(forBPM bpm: Double) -> Int {
        guard bpm > 0 else { return 8 }
        let ideal = 960.0 / bpm              // == 60 / (bpm * 0.0625 s-per-line)
        return [4, 8, 16, 32].min { abs(Double($0) - ideal) < abs(Double($1) - ideal) }!
    }

    /// Convert to a Renoise song. `linesPerBeat` overrides the grid; nil derives
    /// it from the song's tempo via `derivedLinesPerBeat`.
    static func fromIR(_ song: IRSong, linesPerBeat: Int?, stats: inout ConvertStats) -> RenoiseSong {
        let lpb = max(1, linesPerBeat ?? derivedLinesPerBeat(forBPM: song.tempo))
        stats.linesPerBeat = lpb
        var rs = RenoiseSong()
        rs.docVersion = 67
        rs.bpm = song.tempo
        rs.linesPerBeat = lpb
        rs.signatureNumerator = song.signatureNumerator
        rs.signatureDenominator = song.signatureDenominator
        rs.songName = song.title
        rs.artist = song.artist
        rs.comments = song.comment.map { $0.components(separatedBy: "\n") } ?? []

        // Renoise track order in the file: sequencer tracks, then master, then sends.
        let regulars = song.tracks.filter { $0.role == .regular }
        let sends = song.tracks.filter { $0.role == .send }
        let master = song.tracks.first { $0.role == .master } ?? IRTrack(role: .master, name: "Master")
        let ordered = regulars + [master] + sends
        let kinds = ordered.map { $0.role }

        // Pattern grid.
        let patternBeats = patternLengthBeats(lpb: lpb)
        let patternLines = Int((patternBeats * Double(lpb)).rounded())
        let songLength = song.lengthInBeats
        let patternCount = songLength <= 0 ? 1 : max(1, Int(ceil(songLength / patternBeats)))

        // Pre-flatten each ordered track's notes to absolute beats.
        let absoluteNotesPerTrack = ordered.map { $0.absoluteNotes }
        var visibleColumns = [Int](repeating: 1, count: ordered.count)

        var patterns: [RNPattern] = []
        for p in 0..<patternCount {
            let segStart = Double(p) * patternBeats
            let segEnd = segStart + patternBeats
            var patternTracks: [RNPatternTrack] = []

            for (ti, role) in kinds.enumerated() {
                guard role == .regular else { patternTracks.append(RNPatternTrack()); continue }
                let inSegment = absoluteNotesPerTrack[ti]
                    .filter { $0.start >= segStart && $0.start < segEnd }
                    .map { IRNote(start: $0.start - segStart, length: $0.length,
                                  key: $0.key, velocity: $0.velocity,
                                  sampleOffset: $0.sampleOffset, instrument: $0.instrument) }
                // Regular tracks are first in `ordered`, so ti is also this
                // track's instrument index (Renoise references instruments in hex).
                let instHex = String(format: "%02X", min(0xFE, ti))
                let (lines, columns, dropped) = placeNotes(inSegment, numberOfLines: patternLines,
                                                            lpb: Double(lpb), tpl: rs.ticksPerLine,
                                                            defaultInstrument: instHex)
                visibleColumns[ti] = max(visibleColumns[ti], columns)
                stats.droppedNotes += dropped
                stats.notes += inSegment.count - dropped
                patternTracks.append(RNPatternTrack(lines: lines))
            }

            patterns.append(RNPattern(numberOfLines: patternLines, tracks: patternTracks, trackKinds: kinds))
        }

        // Tempo-map changes → ZTxx commands on the first track (integer BPM 20…255).
        let tempoMap = song.resolvedTempoMap
        if tempoMap.count > 1, !patterns.isEmpty, !patterns[0].tracks.isEmpty {
            for tp in tempoMap.dropFirst() {
                let bpm = max(20, min(255, Int(tp.bpm.rounded())))
                let p = min(patternCount - 1, max(0, Int(tp.time / patternBeats)))
                let line = min(patternLines - 1, max(0, Int(((tp.time - Double(p) * patternBeats) * Double(lpb)).rounded())))
                addEffect(&patterns[p].tracks[0], line: line,
                          RNEffectColumn(number: "ZT", value: String(format: "%02X", bpm)))
            }
        }

        rs.tracks = ordered.enumerated().map { i, t in
            var rt = RNTrack(kind: t.role, name: t.name, color: t.color,
                             volume: t.volume, pan: t.pan, muted: t.mute, soloed: t.solo)
            rt.visibleNoteColumns = visibleColumns[i]
            return rt
        }

        // Instrument slots. With an explicit instrument table (the channel layout,
        // where notes reference instruments by index), build straight from it;
        // otherwise make one slot per regular track (instrument layout / non-legacy
        // sources, where a track's note-ons reference its own index). Either way,
        // a matched extracted sample is wired in as a *playable* Renoise instrument
        // (root key, loop, New Note Action) so the import sounds immediately.
        if !song.instruments.isEmpty {
            rs.instruments = song.instruments.map { makeRenoiseInstrument(name: $0.name, sample: $0.sample) }
        } else {
            let samplesByName = Dictionary(song.extractedSamples.map { ($0.name, $0) },
                                           uniquingKeysWith: { first, _ in first })
            rs.instruments = regulars.map { makeRenoiseInstrument(name: $0.name, sample: samplesByName[$0.name]) }
        }

        // Legacy-module imports stack many sample channels; give the master bus
        // headroom (sized from the peak simultaneous voice count) so the summed
        // mix doesn't clip on first playback. Tracks stay at unity, so the
        // relative balance — and the per-track channels you mix with plugins —
        // are untouched; just raise the master fader once you've gain-staged.
        if !song.extractedSamples.isEmpty,
           let masterIdx = ordered.firstIndex(where: { $0.role == .master }) {
            let voices = peakPolyphony(absoluteNotesPerTrack.flatMap { $0 })
            if voices > 1 { rs.tracks[masterIdx].volume = max(0.25, 1.0 / Double(voices).squareRoot()) }
        }

        rs.patterns = patterns
        rs.sequence = Array(0..<patternCount)

        stats.tracks = rs.tracks.count
        stats.patternsOrClips = patterns.count
        return rs
    }

    /// Build a Renoise instrument for one IR track, wiring in the matching
    /// extracted sample (if any) as a playable, mapped, looped sample. A track
    /// with no sample becomes an empty named slot the user can fill in.
    private static func makeRenoiseInstrument(name: String, sample: ExtractedSample?) -> RNInstrument {
        guard let s = sample, !s.pcm.isEmpty else { return RNInstrument(name: name) }
        let looped = s.loopEnd > s.loopStart && s.loopEnd > 0
        let modes = ["Forward", "PingPong", "Backward"]
        let wav = Wav.encode(s.pcm, sampleRate: s.sampleRate, channels: 1, rootKey: s.rootKey,
                             loopStart: s.loopStart, loopEnd: s.loopEnd, loopType: s.loopType)
        let sm = RNSample(name: s.name, wav: wav,
                          volume: 1.0, transpose: 0,
                          baseNote: s.rootKey - 12,                  // Renoise note = MIDI − 12
                          loopMode: looped ? modes[min(2, max(0, s.loopType))] : "Off",
                          loopStart: s.loopStart, loopEnd: s.loopEnd,
                          newNoteAction: s.newNoteAction, envelope: s.envelope)
        return RNInstrument(name: name, sample: sm)
    }

    /// Peak number of notes sounding simultaneously across a note set (a sweep
    /// over note-on/note-off events). Used to size master headroom.
    private static func peakPolyphony(_ notes: [IRNote]) -> Int {
        var events: [(t: Double, d: Int)] = []
        for n in notes { events.append((n.start, 1)); events.append((n.start + n.length, -1)) }
        events.sort { $0.t != $1.t ? $0.t < $1.t : $0.d < $1.d }
        var cur = 0, peak = 0
        for e in events { cur += e.d; peak = max(peak, cur) }
        return peak
    }

    /// Merge an effect-column command into a pattern track at a given line,
    /// creating the line if needed and keeping lines sorted.
    private static func addEffect(_ track: inout RNPatternTrack, line: Int, _ ec: RNEffectColumn) {
        if let i = track.lines.firstIndex(where: { $0.index == line }) {
            track.lines[i].effectColumns.append(ec)
        } else {
            track.lines.append(RNLine(index: line, noteColumns: [], effectColumns: [ec]))
            track.lines.sort { $0.index < $1.index }
        }
    }

    /// Pattern length in beats, clamped so a pattern never exceeds 512 lines.
    private static func patternLengthBeats(lpb: Int) -> Double {
        let preferred = 16.0
        let maxLines = 512.0
        return min(preferred, (maxLines / Double(lpb)).rounded(.down))
    }

    /// Place a segment's notes onto tracker lines, spreading overlapping notes
    /// across note columns. Sub-line timing is preserved with Renoise commands
    /// rather than rounded to the grid:
    ///   • a note that doesn't start on a line gets a **delay column** value
    ///     (xx/256 of a line) on its note-on (and on its `OFF`);
    ///   • a note shorter than one line is ended with a **note-cut** command
    ///     (`Cx` in the panning column), x = ticks into the line;
    ///   • velocity is written to the volume column (`00`–`7F`).
    /// Returns the (sparse) lines, the number of columns used, and how many notes
    /// were dropped for exceeding Renoise's 12-column polyphony limit.
    private static func placeNotes(_ notes: [IRNote], numberOfLines N: Int, lpb: Double, tpl: Int,
                                   defaultInstrument: String)
        -> (lines: [RNLine], columns: Int, dropped: Int)
    {
        struct Placed { var onPos: Double; var offPos: Double; var key: Int; var velocity: Double; var offset: Int?; var instrument: Int? }
        var columns: [[Placed]] = []
        var freeAtLine: [Int] = []     // first line at which a column is free again
        var dropped = 0
        let tplD = Double(max(1, tpl))

        /// Split a fractional line position into (line index, delay byte 0…255).
        func split(_ pos: Double) -> (line: Int, delay: Int) {
            var line = Int(pos.rounded(.down))
            var delay = Int(((pos - Double(line)) * 256).rounded())
            if delay >= 256 { line += 1; delay = 0 }
            return (line, delay)
        }

        for n in notes.sorted(by: { $0.start < $1.start }) {
            let onPos = max(0, n.start * lpb)
            let offPos = max(onPos + 1.0 / tplD, (n.start + n.length) * lpb)  // strictly after onPos
            let onLine = min(N - 1, Int(onPos.rounded(.down)))
            let endsWithinLine = Int(offPos.rounded(.down)) <= onLine
            // The column is busy through onLine (cut) or up to the OFF line.
            let freeAt = endsWithinLine ? onLine + 1 : min(N, Int(offPos.rounded(.down)))

            var assigned = -1
            for c in freeAtLine.indices where freeAtLine[c] <= onLine { assigned = c; break }
            if assigned == -1 {
                if columns.count < 12 {
                    assigned = columns.count; columns.append([]); freeAtLine.append(0)
                } else { dropped += 1; continue }
            }
            columns[assigned].append(Placed(onPos: onPos, offPos: offPos, key: n.key,
                                            velocity: n.velocity, offset: n.sampleOffset, instrument: n.instrument))
            freeAtLine[assigned] = freeAt
        }

        var events: [(line: Int, column: Int, data: RNNoteColumn)] = []
        var lineEffects: [Int: RNEffectColumn] = [:]   // sample-offset (0Sxx) per note-on line
        for (ci, colNotes) in columns.enumerated() {
            for (i, item) in colNotes.enumerated() {
                var on = RNNoteColumn()
                on.note = Pitch.renoiseName(fromMidi: item.key)
                on.instrument = item.instrument.map { String(format: "%02X", min(0xFE, max(0, $0))) } ?? defaultInstrument
                let vol = Int((item.velocity * 128).rounded())
                if vol < 0x80 { on.volume = String(format: "%02X", max(0, min(0x7F, vol))) }

                let (onLine, onDelay) = split(min(item.onPos, Double(N) - 0.0001))
                if onDelay > 0 { on.delay = String(format: "%02X", onDelay) }
                // Re-emit a tracker sample offset (9xx) as Renoise's 0Sxx. One per
                // line (the track effect column applies to the row's trigger).
                if let off = item.offset, lineEffects[onLine] == nil {
                    lineEffects[onLine] = RNEffectColumn(number: "0S", value: String(format: "%02X", max(0, min(255, off))))
                }

                if Int(item.offPos.rounded(.down)) <= onLine {
                    // Shorter than one line → cut command in the panning column.
                    let cutTicks = max(1, min(0xF, Int(((item.offPos - Double(onLine)) * tplD).rounded())))
                    on.panning = "C" + String(cutTicks, radix: 16, uppercase: true)
                    events.append((onLine, ci, on))
                } else {
                    events.append((onLine, ci, on))
                    let nextOn = i + 1 < colNotes.count ? colNotes[i + 1].onPos : Double.infinity
                    let (offLine, offDelay) = split(item.offPos)
                    // Emit OFF unless the next note-on shares its line (it cuts us).
                    if offLine < N, Double(offLine) < nextOn.rounded(.down) || nextOn.isInfinite {
                        var off = RNNoteColumn(); off.note = "OFF"
                        if offDelay > 0 { off.delay = String(format: "%02X", offDelay) }
                        events.append((offLine, ci, off))
                    }
                }
            }
        }

        // Group events into lines, sizing each line's columns to the max used.
        var byLine: [Int: [(Int, RNNoteColumn)]] = [:]
        for e in events { byLine[e.line, default: []].append((e.column, e.data)) }
        var lines: [RNLine] = []
        for idx in byLine.keys.sorted() {
            let cols = byLine[idx]!
            let maxCol = cols.map { $0.0 }.max() ?? 0
            var ncs = [RNNoteColumn](repeating: RNNoteColumn(), count: maxCol + 1)
            for (c, data) in cols { ncs[c] = data }
            lines.append(RNLine(index: idx, noteColumns: ncs,
                                effectColumns: lineEffects[idx].map { [$0] } ?? []))
        }
        return (lines, max(1, columns.count), dropped)
    }
}
