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
        m.title = String(cString: xmpb_mod_name(modP)).trimmingCharacters(in: .whitespacesAndNewlines)
        m.channels = max(1, Int(mod.chn))
        m.channelPans = (0..<m.channels).map { Double(xmpb_chn_pan(modP, Int32($0))) / 255.0 }
        m.initialTempoBPM = mod.bpm >= 32 ? Double(mod.bpm) : 125
        m.initialSpeed = max(1, Int(mod.spd))
        // Walk the order list, honouring S3M/IT separators: 0xFF ("---") ends the
        // song (stop), 0xFE ("+++") is a skip (ignore, continue). Renoise does the
        // same, so entries after the end marker don't become bogus sequence slots.
        var order: [Int] = []
        for i in 0..<Int(mod.len) {
            let o = Int(xmpb_order(modP, Int32(i)))
            if o == 0xFF { break }            // XMP_MARK_END
            if o == 0xFE { continue }         // XMP_MARK_SKIP
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
                    if bpm > 0 { cell.setTempoBPM = Double(bpm) }      // Fxx≥0x20 / Txx → tempo
                    cell.fx1Type = Int(ev.fxt); cell.fx1Param = Int(ev.fxp)
                    cell.fx2Type = Int(ev.f2t); cell.fx2Param = Int(ev.f2p)
                    pattern[row][ch] = cell
                }
            }
            m.patterns.append(pattern)
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
            let sid = Int(xmpb_sub_sid(modP, Int32(i)))
            if sid >= 0, sid < Int(mod.smp) {
                let len = Int(xmpb_smp_len(modP, Int32(sid)))
                let flg = Int(xmpb_smp_flg(modP, Int32(sid)))
                inst.sampleFrames = len
                inst.looped = (flg & Int(XMP_SAMPLE_LOOP)) != 0
                inst.loopType = (flg & Int(XMP_SAMPLE_LOOP_BIDIR)) != 0 ? 1
                              : ((flg & Int(XMP_SAMPLE_LOOP_REVERSE)) != 0 ? 2 : 0)
                inst.loopStart = Int(xmpb_smp_lps(modP, Int32(sid)))
                inst.loopEnd = Int(xmpb_smp_lpe(modP, Int32(sid)))
                if len > 0, (flg & Int(XMP_SAMPLE_SYNTH)) == 0, let dp = xmpb_smp_data(modP, Int32(sid)) {
                    inst.pcm = decodePCM(dp, len: len, sixteenBit: (flg & Int(XMP_SAMPLE_16BIT)) != 0)
                }
            }
            m.instruments.append(inst)
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
