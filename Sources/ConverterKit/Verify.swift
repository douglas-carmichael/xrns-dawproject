import Foundation
import CLibxmp

// MARK: - Automated conversion verification
//
// We can't render the .xrns (no Renoise CLI), but we CAN drive libxmp's own
// player to get the reference playback: the per-row, per-channel volume and note
// of the original module. Comparing that envelope to what the converter intends
// flags every audible problem (a swell that runs away, a note that drops out, a
// fade that's too fast/slow) automatically — and works for EVERY libxmp format,
// so no format needs to be ear-checked by hand.

public enum Verify {

    /// libxmp's reference playback, sampled at each row start: (pattern, row, per-channel
    /// volume 0…64, per-channel note, and whether this row starts a new sub-song section).
    static func capture(_ data: Data, channels: Int) -> [(pattern: Int, row: Int, vol: [Int], note: [Int], newSection: Bool)] {
        guard let ctx = xmp_create_context() else { return [] }
        defer { xmp_free_context(ctx) }
        var rc: Int32 = -1
        data.withUnsafeBytes { raw in rc = xmp_load_module_from_memory(ctx, raw.baseAddress, CLong(data.count)) }
        guard rc == 0 else { return [] }
        defer { xmp_release_module(ctx) }
        guard xmpb_play_start(ctx) == 0 else { return [] }
        defer { xmp_end_player(ctx) }

        // Sub-song sections: order positions split by 0xFF end markers. Multi-section
        // S3M/IT (e.g. 2nd_skav) pack several sub-songs this way and libxmp plays only
        // the first naturally, so seek to each remaining section with xmp_set_position to
        // verify the whole song. Single-section modules collapse to one section [0, len).
        let ordCount = Int(xmpb_ctx_order_count(ctx))
        var sections: [(start: Int, end: Int)] = []
        var s = 0
        for i in 0..<max(0, ordCount) where Int(xmpb_ctx_order(ctx, Int32(i))) == 0xFF {
            if i > s { sections.append((s, i)) }
            s = i + 1
        }
        if s < ordCount { sections.append((s, ordCount)) }
        if sections.isEmpty { sections = [(0, max(1, ordCount))] }

        var out: [(Int, Int, [Int], [Int], Bool)] = []
        for (si, sec) in sections.enumerated() {
            if si > 0 { _ = xmpb_set_position(ctx, Int32(sec.start)) }
            var guardN = 0, entered = false, firstRow = true
            var visited = Set<Int>()                         // (order pos, row) captured this section
            while xmpb_play_frame(ctx) == 0 {
                guardN += 1; if guardN > 1_000_000 { break }
                let pos = Int(xmpb_fi_pos())
                if pos >= sec.start && pos < sec.end { entered = true }
                else if entered { break }                    // advanced past the section (hit the 0xFF) → done
                else { continue }                            // still settling after the seek
                if xmpb_fi_frame() != 0 { continue }         // sample at the first tick of each row
                let pat = Int(xmpb_fi_pattern()), row = Int(xmpb_fi_row())
                // Capture exactly one pass: stop as soon as a playback position (order
                // pos + row) repeats. This catches a song-end restart, a Bxx position
                // jump and an SBx pattern loop alike. Without it a module that loops
                // internally (keeping pos constant or jumping forward) replays a section
                // up to the frame guard — 100k+ rows — and wildly inflates the counts.
                if !visited.insert(pos * 4096 + row).inserted { break }
                var v = [Int](repeating: 0, count: channels), n = [Int](repeating: -1, count: channels)
                for ch in 0..<channels { v[ch] = Int(xmpb_fi_chvol(Int32(ch))); n[ch] = Int(xmpb_fi_chnote(Int32(ch))) }
                out.append((pat, row, v, n, firstRow))
                firstRow = false
            }
        }
        return out
    }

    /// Run verification on a module and print a divergence report.
    public static func run(_ path: String, threshold: Int = 16) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let m = try Xmp.read(data, path: path)
        let frames = capture(data, channels: m.channels)
        guard !frames.isEmpty else { print("verify \(path): could not play (format \(m.format))"); return }
        let speed = max(1, m.initialSpeed)
        let fineFmt = (m.format == "IT" || m.format == "S3M")
        let maxLib = frames.flatMap { $0.vol }.max() ?? 64
        let scale = maxLib > 64 ? 64.0 / Double(maxLib) : 1.0

        // Walk the captured rows in playback order, carrying each channel's running
        // volume across pattern boundaries (as Renoise does), so a note sustained
        // from an earlier pattern isn't falsely seen as silent. Compare only where
        // libxmp has a note sounding (lib>0) — foghorn = mine ≫ lib, silenced =
        // mine ≪ lib; idle cells are skipped (one-shot sample ends aren't modelled).
        var cur = [Int](repeating: 0, count: m.channels)
        var active = [Bool](repeating: false, count: m.channels)
        var mem = [Int](repeating: 0, count: m.channels)
        var qmem = [Int](repeating: 0, count: m.channels)   // Qxy retrigger param memory
        var curInst = [Int](repeating: -1, count: m.channels)
        var curSpeed = speed   // ticks/row, tracked through mid-song speed changes
        var div: [(pat: Int, row: Int, ch: Int, mine: Int, lib: Int, myNote: Int, libNote: Int)] = []
        var envCells = 0    // active cells on enveloped instruments — volume is envelope-driven, not model-checkable
        var gv = 64, gvSlide = 0, gvCells = 0   // global volume (0…64) and cells it explains
        for f in frames where f.pattern >= 0 && f.pattern < m.patterns.count {
            if f.newSection {   // libxmp restarts every channel at a sub-song boundary
                for ch in 0..<m.channels { active[ch] = false; cur[ch] = 0; curInst[ch] = -1; mem[ch] = 0 }
                gv = 64; gvSlide = 0
            }
            let pat = m.patterns[f.pattern]
            guard f.row < pat.count else { continue }
            // Global volume (XM Gxx/Hxy → 0x10 set / 0x11 slide) scales EVERY channel.
            // The converter doesn't emit it — Renoise's own importer drops it too — so
            // its effect is isolated below as a known gap, not counted as a volume bug.
            if gvSlide != 0 { gv = max(0, min(64, gv + gvSlide)); gvSlide = 0 }   // a prior row's slide lands now
            for c in pat[f.row] {
                if let sp = c.speed { curSpeed = max(1, sp) }                            // mid-song speed change (drives per-tick slide rates)
                for (t, pr) in [(c.fx1Type, c.fx1Param), (c.fx2Type, c.fx2Param)] {
                    if t == 0x10 { gv = min(64, pr) }                                    // set global volume
                    else if t == 0x11 { let up = pr >> 4, dn = pr & 0x0F                 // global volume slide (defer like channel slides)
                        if up > 0 { gvSlide = up * curSpeed } else if dn > 0 { gvSlide = -dn * curSpeed } }
                }
            }
            for ch in 0..<m.channels where ch < pat[f.row].count {
                let cell = pat[f.row][ch]
                // A note delay (Sxy with x=D → libxmp FX_EXTENDED / EX_DELAY) defers the
                // whole cell — note, instrument and volume column — to tick x. We sample
                // at tick 0, so libxmp still shows the previous volume on this row; don't
                // flag that transitional frame as a divergence (the value still carries
                // forward for later rows). SD0 (delay 0) is immediate, so excluded.
                let noteDelay = (cell.fx1Type == 0x0E && cell.fx1Param >> 4 == 0x0D && cell.fx1Param & 0x0F != 0)
                             || (cell.fx2Type == 0x0E && cell.fx2Param >> 4 == 0x0D && cell.fx2Param & 0x0F != 0)
                if let i = cell.instrument { curInst[ch] = i - 1 }           // libxmp ev.ins is 1-based
                let ins = curInst[ch], valid = ins >= 0 && ins < m.instruments.count
                let enveloped = valid && m.instruments[ins].envelope != nil
                // An instrument with no audio (a macro/placeholder the song still
                // triggers) makes no sound; libxmp reports a phantom channel volume for
                // it, so don't compare. Both our output and Renoise's leave it empty.
                let hasAudio = valid && (!m.instruments[ins].pcm.isEmpty || !m.instruments[ins].samples.isEmpty)
                // Sample-default volume on (re)trigger. For a plain single-sample
                // instrument (MOD/S3M) sub-0's volume IS the playback default. For a
                // multi-sample (key-mapped) or enveloped instrument (IT/XM) the note
                // maps to a keyzone sub and/or the envelope drives the level, so
                // sub-0's volume is meaningless — assume full and let the note play.
                let sdef: Int = {
                    guard valid else { return 64 }
                    let inst = m.instruments[ins]
                    if !inst.samples.isEmpty {      // multi-sample: use the keyzone the note maps to (libxmp key space = cell.note)
                        if let n = cell.note, let s = inst.samples.first(where: { n >= $0.noteStart && n <= $0.noteEnd }) {
                            return Int((s.volume * 64).rounded())
                        }
                        return 64
                    }
                    return inst.envelope != nil ? 64 : Int((inst.volume * 64).rounded())
                }()
                // A note-off cuts a plain sample, but on an enveloped instrument it
                // starts the envelope's release — libxmp (and Renoise, which plays the
                // exported envelope) keep sounding, so don't model it as instant silence.
                if cell.noteOff { if !enveloped { active[ch] = false; cur[ch] = 0 } }
                else if cell.note != nil {
                    let wasActive = active[ch]
                    active[ch] = true
                    // A note with no sample number leaves the running volume unchanged
                    // (standard tracker behaviour, tone-porta notes included); a sample
                    // number resets the volume to that sample's default. The volume
                    // column, when present, always wins.
                    let keepVol = cell.instrument == nil && wasActive
                    if let v = cell.volume { cur[ch] = v - 1 }
                    else if !keepVol { cur[ch] = sdef }
                } else if cell.instrument != nil { if active[ch] { cur[ch] = sdef } }  // instrument-only row resets volume
                else if let v = cell.volume { cur[ch] = v - 1 }
                if cell.fx1Type == 0x0C { active[ch] = true; cur[ch] = min(64, cell.fx1Param) }   // Cxx set volume
                // Volume slide (Axy / Dxy). Fine slides apply on tick 0, so they change
                // THIS row's frame-0 value; regular slides apply on ticks 1…speed-1, so
                // their effect first shows at the NEXT row's frame 0. libxmp is sampled
                // at frame 0, so apply fine now and defer the regular step past compare.
                // Volume slide: Axy/Dxy (0x0A), and — for S3M/MOD, where the converter
                // emits it in the effect column — the volume-slide part of the combos
                // Lxy/5xy (0x05) and Kxy/6xy (0x06). XM/IT ride the volume column.
                let comboSlide = (cell.fx1Type == 0x05 || cell.fx1Type == 0x06) && (m.format == "S3M" || m.format == "MOD")
                var regSlide = 0
                if active[ch] && (cell.fx1Type == 0x0A || comboSlide) {
                    var p = cell.fx1Param
                    if p != 0 { mem[ch] = p } else { p = mem[ch] }
                    let up = p >> 4, dn = p & 0x0F
                    if fineFmt && dn == 0xF && up != 0 { cur[ch] = min(64, cur[ch] + up) }
                    else if fineFmt && up == 0xF && dn != 0 { cur[ch] = max(0, cur[ch] - dn) }
                    else if m.format == "S3M" && up > 0 && dn > 0 { regSlide = -dn * curSpeed }  // ST3 priority-down (QUIRK_VOLPDN)
                    else if up > 0 { regSlide = up * curSpeed }
                    else if dn > 0 { regSlide = -dn * curSpeed }
                }
                // Qxy retrigger volume change, modelled to match the converter's fade
                // approximation (0I/0O ≈ amt per tick): the same amt-per-tick slide.
                if active[ch] && cell.fx1Type == 0x1B {
                    var p = cell.fx1Param
                    if p != 0 { qmem[ch] = p } else { p = qmem[ch] }
                    let x = p >> 4
                    let amt: Int
                    switch x {
                    case 0x1, 0x9: amt = 1;  case 0x2, 0xA: amt = 2;  case 0x3, 0xB: amt = 4
                    case 0x4, 0xC: amt = 8;  case 0x5, 0xD: amt = 16
                    case 0x6, 0xE: amt = 8;  case 0x7, 0xF: amt = 16
                    default:       amt = 0
                    }
                    if x >= 9 { regSlide = amt * curSpeed } else if x != 0 && x != 8 { regSlide = -amt * curSpeed }
                }
                let mine = active[ch] ? cur[ch] : 0
                let lib = Int((Double(f.vol[ch]) * scale).rounded())
                if lib >= 6 && hasAudio && !noteDelay {
                    if enveloped { envCells += 1 }      // envelope drives the level (exported to Renoise as-is); model can't check
                    else if abs(mine - lib) > threshold {
                        let mineGv = Int((Double(mine) * Double(gv) / 64.0).rounded())
                        if gv < 64 && abs(mineGv - lib) <= threshold { gvCells += 1 }   // explained by global volume (not emitted — Renoise-importer parity)
                        else { div.append((f.pattern, f.row, ch, mine, lib, cell.note ?? -1, ch < f.note.count ? f.note[ch] : -1)) }
                    }
                }
                if regSlide != 0 { cur[ch] = max(0, min(64, cur[ch] + regSlide)) }   // takes effect from the next row
            }
        }
        let cells = frames.count * m.channels
        print("verify \(URL(fileURLWithPath: path).lastPathComponent): \(m.format) \(m.channels)ch, \(frames.count) rows captured, libxmp volmax=\(maxLib)")
        let checked = cells - envCells
        print("  volume divergences > \(threshold)/64: \(div.count) of \(checked) checked cells (\(checked > 0 ? div.count * 100 / checked : 0)%)")
        if envCells > 0 { print("    (\(envCells) enveloped-instrument cells skipped — level is envelope-driven and exported to Renoise unchanged)") }
        if gvCells > 0 { print("    (\(gvCells) cells explained by global volume — not emitted, matching Renoise's own importer)") }
        let byPat = Dictionary(grouping: div, by: { $0.pat }).mapValues { $0.count }.sorted { $0.value > $1.value }
        for (pat, cnt) in byPat.prefix(12) { print("    pattern \(pat): \(cnt) divergent cells") }
        print("  worst cells (mine vs libxmp):")
        for d in div.sorted(by: { abs($0.mine - $0.lib) > abs($1.mine - $1.lib) }).prefix(15) {
            print("    pat\(d.pat) row\(d.row) ch\(d.ch): mine=\(d.mine) libxmp=\(d.lib)  (myNote=\(d.myNote) libNote=\(d.libNote))")
        }
    }
}
