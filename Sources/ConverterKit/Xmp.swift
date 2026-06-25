import Foundation
import CLibxmp

// MARK: - libxmp bridge (→ TrackerModule)
//
// Parses any libxmp-supported module from memory and walks the decoded
// `xmp_module` (patterns/tracks/events, instruments, samples incl. PCM) into the
// shared TrackerModule, which the composer-oriented converter then turns into
// instrument tracks + extracted-sample audio. Flexible-array members are reached
// through the small C accessor shim in CLibxmp (xmpbridge.h).

enum Xmp {
    /// Parse a module. `path`, when given, lets libxmp resolve companion files
    /// (e.g. a Startrekker AM synth's `.NT`/`.AS`) that in-memory loading can't
    /// reach — so those synth instruments are rendered to samples and come
    /// through as playable instruments.
    static func read(_ data: Data, path: String? = nil) throws -> TrackerModule {
        guard let ctx = xmp_create_context() else {
            throw TrackerError.malformed("could not create libxmp context")
        }
        defer { xmp_free_context(ctx) }

        var rc = data.withUnsafeBytes { raw in
            xmp_load_module_from_memory(ctx, raw.baseAddress, CLong(data.count))
        }
        // In-memory loading can't find companion files; if it fails and the module
        // is on disk, retry by path so libxmp can locate them (and render AM synth).
        if rc != 0, let path {
            rc = path.withCString { xmp_load_module(ctx, $0) }
        }
        guard rc == 0 else { throw TrackerError.malformed("libxmp could not load this module (code \(rc))") }
        defer { xmp_release_module(ctx) }

        var info = xmp_module_info()
        xmp_get_module_info(ctx, &info)
        guard let mut = info.mod else { throw TrackerError.malformed("libxmp returned no module data") }
        let modP = UnsafePointer(mut)
        let mod = mut.pointee

        var m = TrackerModule(format: shortType(String(cString: xmpb_mod_type(modP))))
        // libxmp scales playback by a per-format time_factor (default 10); a few
        // formats express tempo in numbers calibrated for a different one, so the
        // BPM must be normalised to the default-10 scale that Renoise and the
        // DAWproject assume. FAR uses 4.01373, MED/MMD use 2.64 (libxmp common.h);
        // every other format is already on the 10 scale (timeScale 1).
        let timeScale: Double = m.format.contains("Farandole") ? 10.0 / 4.01373
                              : (m.format.contains("MED") ? 10.0 / 2.64 : 1.0)
        m.title = String(cString: xmpb_mod_name(modP)).trimmingCharacters(in: .whitespacesAndNewlines)
        m.channels = max(1, Int(mod.chn))
        m.channelPans = (0..<m.channels).map { Double(xmpb_chn_pan(modP, Int32($0))) / 255.0 }
        m.initialTempoBPM = (mod.bpm >= 32 ? Double(mod.bpm) : 125) * timeScale
        m.initialSpeed = max(1, Int(mod.spd))
        m.volSlideAllTicks = xmpb_quirk_vsall(ctx) != 0   // ST3.00 S3M: slides step on every tick (incl. tick 0)
        // Walk the order list. 0xFE ("+++") is a skip; 0xFF ("---") normally marks
        // the song end. But some S3M/IT files pack several sub-songs separated by
        // 0xFF — 2nd_skav (Second Reality) holds BOTH the intro and the ending that
        // way. A plain player (and Renoise's import) stop at the first 0xFF and lose
        // everything after, so we instead skip the marker and keep scanning, so every
        // section is converted. Trailing 0xFF padding simply contributes nothing.
        var order: [Int] = []
        for i in 0..<Int(mod.len) {
            let o = Int(xmpb_order(modP, Int32(i)))
            if o == 0xFF || o == 0xFE { continue }   // end / skip markers
            if o >= 0 && o < Int(mod.pat) { order.append(o) }
        }
        m.order = order

        for p in 0..<Int(mod.pat) {
            let rows = Int(xmpb_pat_rows(modP, Int32(p)))
            var pattern = [[TCell]](repeating: [TCell](repeating: TCell(), count: m.channels), count: max(1, rows))
            for ch in 0..<m.channels {
                let trk = Int(xmpb_pat_track(modP, Int32(p), Int32(ch)))
                guard trk >= 0, trk < Int(mod.trk) else { continue }
                let trackRows = min(rows, Int(xmpb_trk_rows(modP, Int32(trk))))
                for row in 0..<trackRows {
                    guard let evP = xmpb_event(modP, Int32(trk), Int32(row)) else { continue }
                    let ev = evP.pointee
                    var cell = TCell()
                    if ev.note >= UInt8(XMP_KEY_OFF) {           // OFF / CUT / FADE
                        cell.noteOff = true
                    } else if ev.note > 0 {
                        // libxmp normalises every loader onto one internal note
                        // scale shifted up an octave (XM adds 12, S3M bases at 13,
                        // MOD's period→note lands the same), where value 61 = "C-4".
                        // toIR later adds +12, so subtract 13 here to land C-4 on
                        // MIDI 60 (middle C) — matching what the tracker displays.
                        cell.note = max(0, Int(ev.note) - 13)
                    }
                    if ev.ins > 0 { cell.instrument = Int(ev.ins) }
                    if ev.vol > 0 { cell.volume = Int(ev.vol) } // libxmp normalises to 0…64
                    let offset = xmpb_ev_offset(evP)
                    if offset >= 0 { cell.sampleOffset = Int(offset) } // 9xx → sliced-sample hint
                    let bpm = xmpb_ev_tempo(evP)
                    if bpm > 0 { cell.setTempoBPM = Double(bpm) * timeScale }  // Fxx≥0x20 / Txx → tempo
                    let spd = xmpb_ev_speed(evP)
                    if spd > 0 { cell.speed = Int(spd) }              // speed in either column (incl. 669)
                    cell.fx1Type = Int(ev.fxt); cell.fx1Param = Int(ev.fxp)
                    cell.fx2Type = Int(ev.f2t); cell.fx2Param = Int(ev.f2p)
                    pattern[row][ch] = cell
                }
            }
            m.patterns.append(pattern)
        }

        // Decode one libxmp sample (by id) into a TSample carrying its PCM, loop
        // and channel layout (range/tuning are filled in by the caller). Cached so
        // a key-mapped instrument that reuses a sample never re-decodes it.
        var sampleCache: [Int: TSample] = [:]
        func loadSample(_ sid: Int) -> TSample? {
            guard sid >= 0, sid < Int(mod.smp) else { return nil }
            if let c = sampleCache[sid] { return c }
            let len = Int(xmpb_smp_len(modP, Int32(sid)))
            let flg = Int(xmpb_smp_flg(modP, Int32(sid)))
            var s = TSample()
            s.name = String(cString: xmpb_smp_name(modP, Int32(sid))).trimmingCharacters(in: .whitespacesAndNewlines)
            s.looped = (flg & Int(XMP_SAMPLE_LOOP)) != 0
            s.loopType = (flg & Int(XMP_SAMPLE_LOOP_BIDIR)) != 0 ? 1
                       : ((flg & Int(XMP_SAMPLE_LOOP_REVERSE)) != 0 ? 2 : 0)
            s.loopStart = Int(xmpb_smp_lps(modP, Int32(sid)))
            s.loopEnd = Int(xmpb_smp_lpe(modP, Int32(sid)))
            let stereo = (flg & Int(XMP_SAMPLE_STEREO)) != 0
            s.channels = stereo ? 2 : 1
            if len > 0, (flg & Int(XMP_SAMPLE_SYNTH)) == 0, let dp = xmpb_smp_data(modP, Int32(sid)) {
                // libxmp stereo data is interleaved L/R; `len` is in frames, so a
                // stereo sample holds len*2 16-bit values.
                s.pcm = decodePCM(dp, len: stereo ? len * 2 : len, sixteenBit: (flg & Int(XMP_SAMPLE_16BIT)) != 0)
            }
            sampleCache[sid] = s
            return s
        }
        // The subinstrument a cell-note maps to. Pattern events use cell-note =
        // ev.note − 13, but libxmp's key→subinstrument table sits one semitone
        // below that (its base differs from the event scale), so the keyzone for
        // cell-note c reads map[c + 12] — verified against Renoise's own import,
        // which lands a drum kit's zones one semitone above a c+13 lookup. Keys
        // past the table (c > 108) clamp to the top entry, extending it upward.
        func subForKey(_ ins: Int, _ c: Int) -> Int {
            Int(xmpb_map_ins(modP, Int32(ins), Int32(min(120, c + 12))))
        }

        for i in 0..<Int(mod.ins) {
            var inst = TInstrument(name: String(cString: xmpb_ins_name(modP, Int32(i)))
                .trimmingCharacters(in: .whitespacesAndNewlines))
            inst.transpose = Int(xmpb_sub_xpo(modP, Int32(i)))
            inst.sampleRate = 8363
            switch xmpb_ins_nna(modP, Int32(i)) {           // New Note Action → Renoise
            case 0: inst.newNoteAction = "Cut"              // CUT
            case 1: inst.newNoteAction = "None"             // CONTINUE — new note leaves the old playing
            default: inst.newNoteAction = "NoteOff"         // OFF / FADE (Renoise has no sample-level fade)
            }
            inst.envelope = envelopeADSR(modP, i)           // XM/IT/AM-synth volume envelope → AHDSR
            inst.synthVolume = xmpb_med_synth_vtlen(modP, Int32(i)) > 0   // MED synth volume-sequence instrument

            // Primary sample (subinstrument 0) → the instrument's top-level fields,
            // used by the flattening IR path and by single-sample output.
            // Effective volume = default volume × the sample's global volume (IT/GDM
            // carry a separate per-sample gvl). gvl defaults to volbase — which is >64
            // on a few formats — so clamp to 64, where it means "no scaling".
            let primVol = Double(xmpb_sub_vol_at(modP, Int32(i), 0)) / 64.0
            let primGvl = Double(min(Int32(64), xmpb_sub_gvl_at(modP, Int32(i), 0))) / 64.0
            inst.volume = primVol * primGvl
            inst.finetune = max(-127, min(127, Int(xmpb_sub_fin_at(modP, Int32(i), 0))))
            if let prim = loadSample(Int(xmpb_sub_sid(modP, Int32(i)))) {
                inst.sampleFrames = prim.pcm.count / max(1, prim.channels)
                inst.looped = prim.looped; inst.loopType = prim.loopType
                inst.loopStart = prim.loopStart; inst.loopEnd = prim.loopEnd
                inst.channels = prim.channels; inst.pcm = prim.pcm
            }

            // Key-mapped (multi-sample) instrument — a drum kit or layered XM/IT
            // instrument. Walk the key table in maximal runs of consecutive keys
            // that share a subinstrument; each run becomes one sample with its own
            // range and tuning. Single-sample instruments leave `samples` empty and
            // use the primary fields above (full 0…119 range).
            if Int(xmpb_ins_nsm(modP, Int32(i))) > 1 {
                var samples: [TSample] = []
                func emit(_ sub: Int, _ from: Int, _ to: Int) {
                    guard var s = loadSample(Int(xmpb_sub_sid_at(modP, Int32(i), Int32(sub)))) else { return }
                    s.transpose = Int(xmpb_sub_xpo_at(modP, Int32(i), Int32(sub)))
                    let kzVol = Double(xmpb_sub_vol_at(modP, Int32(i), Int32(sub))) / 64.0
                    let kzGvl = Double(min(Int32(64), xmpb_sub_gvl_at(modP, Int32(i), Int32(sub)))) / 64.0
                    s.volume = kzVol * kzGvl
                    s.finetune = max(-127, min(127, Int(xmpb_sub_fin_at(modP, Int32(i), Int32(sub)))))
                    s.noteStart = from; s.noteEnd = to
                    samples.append(s)
                }
                var runStart = 0, runSub = subForKey(i, 0)
                for c in 1...119 {
                    let sub = subForKey(i, c)
                    if sub != runSub { emit(runSub, runStart, c - 1); runStart = c; runSub = sub }
                }
                emit(runSub, runStart, 119)
                let real = samples.filter { !$0.pcm.isEmpty }
                if real.count > 1 { inst.samples = real }   // genuine multi-sample only
            }
            m.instruments.append(inst)
        }

        // FAR mid-song tempo. FAR stores tempo only as effects (a coarse→BPM table
        // plus fine slides and a tempo "mode"), which libxmp resolves during
        // playback, not in the events. Replay that state machine in play order and
        // stamp the resulting BPM + speed onto each tempo-changing cell, using
        // libxmp's own translator (xmpb_far_tempo). The DAWproject tempo map and a
        // FAR-specific XRNS emitter both read setTempoBPM/speed. Fine slides are
        // exact along a linear play-through; a pattern replayed at a different
        // accumulated fine tempo is approximate (the pooled-pattern caveat).
        if m.format.contains("Farandole") {
            // FAR's initial coarse tempo isn't on the public struct, so recover it
            // by matching the header BPM libxmp already computed (mode 1, no fine).
            var coarse = 4
            for c in 0...15 {
                var f: Int32 = 0, s: Int32 = 0, b: Int32 = 0
                if xmpb_far_tempo(1, 0, Int32(c), &f, &s, &b) == 0,
                   Int(b) == Int(m.initialTempoBPM.rounded()) { coarse = c; break }
            }
            var fine: Int32 = 0, mode = 1
            for op in m.order where op >= 0 && op < m.patterns.count {
                for r in m.patterns[op].indices {
                    for ch in m.patterns[op][r].indices {
                        var fineChange: Int32 = 0
                        switch m.patterns[op][r][ch].fx1Type {
                        case 0x68:                                  // FX_FAR_TEMPO
                            let p = m.patterns[op][r][ch].fx1Param
                            if (p >> 4) != 0 { mode = (p >> 4) - 1 } else { coarse = p & 0x0F }
                        case 0x69:                                  // FX_FAR_F_TEMPO (fine slide)
                            let p = m.patterns[op][r][ch].fx1Param, hi = p >> 4, lo = p & 0x0F
                            if hi != 0 { fine += Int32(hi); fineChange = Int32(hi) }
                            else if lo != 0 { fine -= Int32(lo); fineChange = -Int32(lo) }
                            else { fine = 0 }
                        default: continue
                        }
                        var s: Int32 = 0, b: Int32 = 0
                        if xmpb_far_tempo(Int32(mode), fineChange, Int32(coarse), &fine, &s, &b) == 0 {
                            m.patterns[op][r][ch].setTempoBPM = Double(b) * timeScale
                            m.patterns[op][r][ch].speed = Int(s)        // keep fx1Type 0x68 as the XRNS marker
                        } else {
                            m.patterns[op][r][ch].fx1Type = 0           // tempo 0: unrepresentable, drop
                        }
                    }
                }
            }
        }
        return m
    }

    /// Reduce libxmp's volume envelope (point list, times in ticks, values 0…64)
    /// to a Renoise AHDSR. Sustain is mapped exactly (the steady-state level);
    /// attack/decay/release times go through a monotonic normalisation — the
    /// shape is faithful, the absolute times approximate (Renoise's normalised
    /// time curve isn't documented). Returns nil when the instrument has no
    /// enabled envelope (e.g. plain MOD samples).
    private static func envelopeADSR(_ m: UnsafePointer<xmp_module>, _ i: Int) -> ADSR? {
        let flg = xmpb_env_flg(m, Int32(i))
        guard (flg & 0x1) != 0 else { return nil }              // XMP_ENVELOPE_ON
        let npt = Int(xmpb_env_npt(m, Int32(i)))
        guard npt >= 2 else { return nil }
        func t(_ p: Int) -> Int { Int(xmpb_env_time(m, Int32(i), Int32(p))) }
        func v(_ p: Int) -> Int { Int(xmpb_env_val(m, Int32(i), Int32(p))) }

        var peak = 0
        for p in 1..<npt where v(p) > v(peak) { peak = p }      // first point of max level
        let hasSus = (flg & 0x2) != 0                           // XMP_ENVELOPE_SUS
        let susIdx = hasSus ? min(max(0, Int(xmpb_env_sus(m, Int32(i)))), npt - 1) : npt - 1

        let attackTicks  = max(0, t(peak) - t(0))
        let decayTicks   = max(0, t(max(peak, susIdx)) - t(peak))
        let releaseTicks = hasSus ? max(0, t(npt - 1) - t(susIdx)) : 0
        let sustainLevel = Double(max(0, min(64, v(susIdx)))) / 64.0

        func norm(_ ticks: Int) -> Double { min(1.0, (Double(ticks) / 512.0).squareRoot()) }
        return ADSR(attack: norm(attackTicks), hold: 0, decay: norm(decayTicks),
                    sustain: sustainLevel, release: hasSus ? max(0.02, norm(releaseTicks)) : 0.05)
    }

    private static func decodePCM(_ p: UnsafePointer<UInt8>, len: Int, sixteenBit: Bool) -> [Int16] {
        if sixteenBit {
            return p.withMemoryRebound(to: Int16.self, capacity: len) {
                Array(UnsafeBufferPointer(start: $0, count: len))   // libxmp 16-bit data is host-endian
            }
        }
        var out = [Int16](); out.reserveCapacity(len)
        for k in 0..<len { out.append(Int16(Int8(bitPattern: p[k])) * 256) }
        return out
    }

    /// Map libxmp's descriptive type string to a short tag for track comments.
    private static func shortType(_ t: String) -> String {
        let s = t.lowercased()
        if s.contains("protracker") || s.contains("noisetracker") || s.contains("soundtracker") || s.contains("startrekker") { return "MOD" }
        // ModPlug/OpenMPT/Schism name the saved format as a token in the type
        // string, e.g. "ModPlug Tracker 1.16 IT 2.14" — match that, not just the
        // authoring tracker, so a ModPlug-saved IT is still classed as IT.
        if s.contains("impulse") || s.contains(" it ") || s.hasSuffix(" it") { return "IT" }
        if s.contains("fast tracker") || s.contains("fasttracker") || s.contains("ft2") || s.contains(" xm") { return "XM" }
        if s.contains("scream tracker") || s.contains(" s3m") { return "S3M" }
        if s.contains("octamed") || s.hasPrefix("med") { return "MED" }
        if s.contains("digibooster") { return "DBM" }
        if s.contains("composer 669") || s.contains("unis 669") { return "669" }
        return t.isEmpty ? "module" : t
    }
}
