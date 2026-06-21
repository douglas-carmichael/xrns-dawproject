import Foundation

// MARK: - Legacy tracker module → Renoise (direct, pattern-pooled)
//
// Renoise's own module importer keeps each tracker pattern *once* in the pattern
// pool and references it from the pattern sequence (the module's order list). It
// lays out one Renoise track per tracker channel and copies each cell to the
// matching line verbatim — it does NOT reconstruct note durations or synthesise
// note-offs the way a continuous-timeline (DAWproject/MIDI) target needs.
//
// This converter reproduces that behaviour for the .xrns target so a module
// round-trips to the same structure Renoise would produce:
//   • the full pattern pool — every pattern in the file, at its native line
//     count (IT/S3M patterns vary), including ones the order never references;
//   • the order list as the pattern sequence (reused patterns appear once in the
//     pool, many times in the sequence);
//   • cell-for-cell note / instrument / volume / sample-offset / tempo data.
//
// The instrument-grouped re-orchestration layout and the DAWproject/MIDI targets
// still go through the flattening IR path (Tracker.toIR) — that path deliberately
// dissolves channels and patterns into a linear arrangement, which suits a DAW
// timeline but is the opposite of what a faithful Renoise import wants.
//
// NOTE: only the oracle modules (MOD/XM/IT) can be checked against a real Renoise
// import; everything here is written to be format-neutral and defensive so the
// other ~50 libxmp formats produce a valid, sensible .xrns too.
//
// INTENTIONAL DIVERGENCE: Renoise's own IT importer cannot represent IT
// volume-column pan / tone-portamento / vibrato, so it writes meaningless junk
// (a raw-byte artifact in the volume column). We deliberately do NOT replicate
// that bug: IT vol-column pan → the real panning column, and vol-column porta /
// vibrato → their proper effect-column commands (0G / 0V, in a second effect
// column when the first is taken). So for those specific cells our output is
// MORE correct than — and differs from — a native Renoise IT import. Everywhere
// Renoise is correct, we match it. (See TrackerEffects.secondaryPanning/Effect.)

enum TrackerRenoise {
    /// Build a pattern-pooled Renoise song from a parsed module (channel layout:
    /// one sequencer track per tracker channel, plus the master).
    static func convert(_ m: TrackerModule) -> RenoiseSong {
        var rs = RenoiseSong()
        rs.docVersion = 67
        rs.bpm = m.initialTempoBPM
        rs.linesPerBeat = max(1, m.rowsPerBeat)      // 1 tracker row → 1 Renoise line
        rs.ticksPerLine = ticksPerLine(m)            // from the module's speed
        rs.signatureNumerator = 4
        rs.signatureDenominator = 4
        rs.songName = m.title.isEmpty ? nil : m.title

        let channels = max(1, m.channels)
        let noteOffset = Self.noteOffset(m.format)

        // --- Tracks: one sequencer track per channel, then the master. Renoise
        // centres every channel on import (it ignores Amiga LRRL hardware pan)
        // and leaves faders at unity, relying on GlobalTrackHeadroom for room. ---
        var tracks: [RNTrack] = []
        for ch in 0..<channels {
            tracks.append(RNTrack(kind: .regular, name: String(format: "Track %02d", ch + 1)))
        }
        tracks.append(RNTrack(kind: .master, name: "Mst"))
        rs.tracks = tracks
        let trackKinds = tracks.map { $0.kind }

        // --- Instruments: slot 0 is an empty placeholder, then one slot per
        // tracker instrument (1-based) so a cell's instrument number indexes its
        // slot directly (cell instrument N → Renoise instrument N). Names are the
        // verbatim sample names, like a native import — not the IR's classifier. ---
        rs.instruments = [RNInstrument(name: "")]
        for inst in m.instruments {
            rs.instruments.append(instrument(inst, noteOffset: noteOffset))
        }

        // --- Pattern pool: every pattern in the file, native line count, each
        // channel copied cell-for-cell into its pattern track (master empty). ---
        var patterns: [RNPattern] = []
        for pat in m.patterns {
            let rows = max(1, pat.count)
            var ptracks: [RNPatternTrack] = []
            for ch in 0..<channels {
                ptracks.append(patternTrack(pat, channel: ch, rows: rows,
                                            noteOffset: noteOffset, format: m.format))
            }
            ptracks.append(RNPatternTrack())   // master pattern track (no notes)
            patterns.append(RNPattern(numberOfLines: rows, tracks: ptracks, trackKinds: trackKinds))
        }
        if patterns.isEmpty {   // degenerate module with no pattern data
            patterns = [RNPattern(numberOfLines: 64,
                                  tracks: tracks.map { _ in RNPatternTrack() },
                                  trackKinds: trackKinds)]
        }
        // Renoise's IT import keeps one empty trailing pattern beyond the file's
        // declared pattern count. libxmp reports the declared count for IT (one
        // short of Renoise); for MOD/XM its count already includes the trailing
        // pattern. Append it for IT so the pool matches a native Renoise import.
        if m.format == "IT" {
            patterns.append(RNPattern(numberOfLines: 64,
                                      tracks: tracks.map { _ in RNPatternTrack() },
                                      trackKinds: trackKinds))
        }
        rs.patterns = patterns

        // Show a second effect column on any channel that uses one (IT/S3M
        // volume-column porta/vibrato translated above).
        for ch in 0..<channels {
            var cols = 1
            for p in patterns where ch < p.tracks.count {
                for line in p.tracks[ch].lines { cols = max(cols, line.effectColumns.count) }
            }
            rs.tracks[ch].visibleEffectColumns = cols
        }

        // --- Sequence = the order list (already filtered to valid pool indices
        // in Xmp.read). A module with no usable order just plays the pool once. ---
        let order = m.order.filter { $0 >= 0 && $0 < patterns.count }
        rs.sequence = order.isEmpty ? Array(0..<patterns.count) : order

        return rs
    }

    /// Renoise TicksPerLine ← the speed (ticks per row) in effect on the very
    /// first played row: a speed command on order[0] row 0 if present, else the
    /// module's initial speed. Matches Renoise's own import (gslinger 31,
    /// necrodancev2 5, scirreal 3, 4thsym 4 — all set their start speed on row 0).
    private static func ticksPerLine(_ m: TrackerModule) -> Int {
        var speed = m.initialSpeed
        if let p = m.order.first(where: { $0 >= 0 && $0 < m.patterns.count }),
           let row0 = m.patterns[p].first {
            for cell in row0 {
                // FX_SPEED (0x0F) with param < 0x20 is speed (≥ that is tempo);
                // FX_S3M_SPEED (0xA3) is always speed.
                if (cell.fx1Type == 0x0F && cell.fx1Param >= 1 && cell.fx1Param < 0x20)
                    || (cell.fx1Type == 0xA3 && cell.fx1Param >= 1) {
                    speed = cell.fx1Param
                    break
                }
            }
        }
        return max(1, min(256, speed))
    }

    /// Correction from libxmp's normalised note value to the note Renoise writes
    /// on import. Renoise stores each format's samples at a fixed/native rate and
    /// shifts the written note to suit, so the displayed octave is format-specific:
    ///   • MOD  −29: Amiga samples are stored at 44.1 kHz (≈ +29 semitones over
    ///     libxmp's 8363 Hz reference), so the written note drops 29 to compensate.
    ///   • IT   +12: libxmp normalises IT notes one octave below their displayed value.
    ///   • XM     0: libxmp's value already equals Renoise's displayed note.
    /// Only MOD/XM/IT have a Renoise oracle to match; every other libxmp format
    /// keeps libxmp's value (0) — there is no Renoise import to match, and 0 is
    /// sound-correct. The matching `BaseNote` shift in `instrument(_:noteOffset:)`
    /// keeps playback pitch unchanged regardless of this display offset.
    private static func noteOffset(_ format: String) -> Int {
        switch format {
        case "MOD": return -29
        case "IT":  return 12
        default:    return 0
        }
    }

    /// One channel's column of a pattern → a sparse Renoise pattern track,
    /// copying each non-empty cell to its line index. No durations are computed
    /// and no note-offs invented: a note simply rings until the channel's next
    /// note or an explicit OFF, exactly as the tracker plays it.
    private static func patternTrack(_ pattern: [[TCell]], channel ch: Int, rows: Int,
                                     noteOffset: Int, format: String) -> RNPatternTrack {
        var pt = RNPatternTrack()
        for r in 0..<min(rows, pattern.count) {
            let row = pattern[r]
            guard ch < row.count else { continue }
            let cell = row[ch]

            var nc = RNNoteColumn()
            var hasColumn = false
            // The note column holds either a key-off or a pitched note. The
            // instrument / volume / panning sub-columns are INDEPENDENT of the
            // note and apply on a note-off line too: a tracker key-off very often
            // carries a volume-column value — classically "set volume 0" to
            // silence a still-ringing or looping (percussion) sample. Renoise's
            // own import preserves these on the OFF line; gating them behind a
            // pitched note drops them, leaving the sample audible — phantom hits.
            if cell.noteOff {
                nc.note = "OFF"
                hasColumn = true
            } else if let n = cell.note {
                // Map libxmp's normalised note onto Renoise's displayed note
                // (per-format offset); the sample's BaseNote shifts to match, so
                // pitch is unchanged. Matches Renoise's own MOD/XM/IT import.
                nc.note = Pitch.renoiseName(fromValue: n + noteOffset)
                hasColumn = true
            }
            if let inst = cell.instrument {
                nc.instrument = String(format: "%02X", min(0xFE, max(0, inst)))
                hasColumn = true
            }
            if let v = cell.volume {
                // libxmp's ev.vol is 1-based (1…65 = volume 0…64); Renoise's
                // volume column is 0…0x80, so value = (v − 1) × 2.
                nc.volume = String(format: "%02X", min(0x80, max(0, (v - 1) * 2)))
                hasColumn = true
            }
            if let pan = TrackerEffects.panning(type: cell.fx1Type, param: cell.fx1Param, format: format) {
                nc.panning = pan
                hasColumn = true
            } else if let pan = TrackerEffects.secondaryPanning(type: cell.fx2Type, param: cell.fx2Param, format: format) {
                nc.panning = pan
                hasColumn = true
            }

            // Effect columns: the main effect (fx1) takes the first column. An
            // IT/S3M volume-column porta/vibrato (fx2) is translated to its proper
            // effect (0G/0V) in a second column — Renoise's own IT import can't
            // represent these and writes junk, so we deliberately diverge.
            var effects: [RNEffectColumn] = []
            if let e = TrackerEffects.effectColumn(type: cell.fx1Type, param: cell.fx1Param, format: format) {
                effects.append(e)
            }
            if let e2 = TrackerEffects.secondaryEffect(type: cell.fx2Type, param: cell.fx2Param, format: format) {
                effects.append(e2)
            }

            if hasColumn || !effects.isEmpty {
                pt.lines.append(RNLine(index: r,
                                       noteColumns: hasColumn ? [nc] : [],
                                       effectColumns: effects))
            }
        }
        return pt
    }

    /// Build one Renoise instrument slot from a tracker instrument, embedding its
    /// decoded sample as FLAC (mapped, looped, with NNA and any volume envelope).
    /// Notes are written untransposed (libxmp's normalised value), so the
    /// instrument's tuning (libxmp xpo: XM relative note / IT C5 speed) goes into
    /// the sample's BaseNote: a +xpo (sample sounds higher) means a *lower* root,
    /// so BaseNote = C-4 (48) − xpo. Verified sound-equivalent to Renoise's import
    /// (a constant ~0.2-semitone global tuning-reference offset; no relative drift).
    private static func instrument(_ inst: TInstrument, noteOffset: Int) -> RNInstrument {
        let name = inst.name
        let modes = ["Forward", "PingPong", "Backward"]
        // Encode one keyzone's PCM (mono → FLAC like Renoise; stereo → WAV, as our
        // FLAC encoder is mono-only) and package it with its mapping. `baseNote`
        // and the note range are final Renoise note values (caller applies the
        // per-format display offset). nil when there's no PCM to embed.
        func make(_ sName: String, _ pcm: [Int16], rate: Int, channels: Int,
                  looped lp: Bool, loopType: Int, loopStart: Int, loopEnd: Int,
                  baseNote: Int, noteStart: Int, noteEnd: Int) -> RNSample? {
            guard !pcm.isEmpty else { return nil }
            let looped = lp && loopEnd > loopStart && loopEnd > 0
            let (audio, ext): (Data, String) = channels == 2
                ? (Wav.encode(pcm, sampleRate: rate, channels: 2), "wav")
                : (Flac.encode(pcm, sampleRate: rate), "flac")
            return RNSample(name: sName.isEmpty ? "Sample" : sName, audio: audio, audioExt: ext,
                            volume: 1.0, transpose: 0,
                            baseNote: max(0, min(119, baseNote)),
                            loopMode: looped ? modes[min(2, max(0, loopType))] : "Off",
                            loopStart: looped ? loopStart : 0,
                            loopEnd: looped ? loopEnd : 0,
                            newNoteAction: inst.newNoteAction,
                            envelope: inst.envelope,
                            noteStart: max(0, min(119, noteStart)),
                            noteEnd: max(0, min(119, noteEnd)))
        }

        // Key-mapped (multi-sample) instrument — drum kit / layered XM/IT: one
        // RNSample per keyzone, each with its own note range and root note. The
        // ranges are in cell-note space; add the format's display offset to land
        // on Renoise's note values (matching the pattern notes' own offset).
        if !inst.samples.isEmpty {
            let rn = inst.samples.compactMap {
                make($0.name, $0.pcm, rate: $0.sampleRate, channels: $0.channels,
                     looped: $0.looped, loopType: $0.loopType, loopStart: $0.loopStart, loopEnd: $0.loopEnd,
                     baseNote: 48 - $0.transpose + noteOffset,
                     noteStart: $0.noteStart + noteOffset, noteEnd: $0.noteEnd + noteOffset)
            }
            if !rn.isEmpty { return RNInstrument(name: name, samples: rn) }
        }

        // Single-sample instrument (the common case): one sample across 0…119.
        guard let sm = make(name, inst.pcm, rate: inst.sampleRate, channels: inst.channels,
                            looped: inst.looped, loopType: inst.loopType,
                            loopStart: inst.loopStart, loopEnd: inst.loopEnd,
                            baseNote: 48 - inst.transpose + noteOffset, noteStart: 0, noteEnd: 119)
        else { return RNInstrument(name: name) }
        return RNInstrument(name: name, samples: [sm])
    }
}
