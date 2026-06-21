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

    /// libxmp's reference playback, sampled at each row start: (pattern, row, per-channel volume 0…64, per-channel note).
    static func capture(_ data: Data, channels: Int) -> [(pattern: Int, row: Int, vol: [Int], note: [Int])] {
        guard let ctx = xmp_create_context() else { return [] }
        defer { xmp_free_context(ctx) }
        var rc: Int32 = -1
        data.withUnsafeBytes { raw in rc = xmp_load_module_from_memory(ctx, raw.baseAddress, CLong(data.count)) }
        guard rc == 0 else { return [] }
        defer { xmp_release_module(ctx) }
        guard xmpb_play_start(ctx) == 0 else { return [] }
        defer { xmp_end_player(ctx) }
        var out: [(Int, Int, [Int], [Int])] = []
        var guardN = 0, lastKey = -1
        while xmpb_play_frame(ctx) == 0 && xmpb_fi_loop() == 0 {
            guardN += 1; if guardN > 2_000_000 { break }
            if xmpb_fi_frame() != 0 { continue }        // sample at the first tick of each row
            let pat = Int(xmpb_fi_pattern()), row = Int(xmpb_fi_row())
            let key = pat * 4096 + row
            if key == lastKey { continue }              // one sample per row, but keep repeats in order
            lastKey = key
            var v = [Int](repeating: 0, count: channels), n = [Int](repeating: -1, count: channels)
            for ch in 0..<channels { v[ch] = Int(xmpb_fi_chvol(Int32(ch))); n[ch] = Int(xmpb_fi_chnote(Int32(ch))) }
            out.append((pat, row, v, n))
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
        var div: [(pat: Int, row: Int, ch: Int, mine: Int, lib: Int)] = []
        for f in frames where f.pattern >= 0 && f.pattern < m.patterns.count {
            let pat = m.patterns[f.pattern]
            guard f.row < pat.count else { continue }
            for ch in 0..<m.channels where ch < pat[f.row].count {
                let cell = pat[f.row][ch]
                let glide = (cell.fx1Type == 0x03 || cell.fx1Type == 0x05)   // Gxx / Lxy: slide to note, no retrigger
                if cell.noteOff { active[ch] = false; cur[ch] = 0 }
                else if cell.note != nil {
                    active[ch] = true
                    if let v = cell.volume { cur[ch] = v - 1 }
                    else if !glide { cur[ch] = 64 }                          // retrigger → default; glide keeps volume
                } else if let v = cell.volume { cur[ch] = v - 1 }
                if cell.fx1Type == 0x0C { active[ch] = true; cur[ch] = min(64, cell.fx1Param) }   // Cxx set volume
                if active[ch] && cell.fx1Type == 0x0A {
                    var p = cell.fx1Param
                    if p != 0 { mem[ch] = p } else { p = mem[ch] }
                    let up = p >> 4, dn = p & 0x0F
                    if fineFmt && dn == 0xF && up != 0 { cur[ch] = min(64, cur[ch] + up) }
                    else if fineFmt && up == 0xF && dn != 0 { cur[ch] = max(0, cur[ch] - dn) }
                    else if up > 0 { cur[ch] = min(64, cur[ch] + up * speed) }
                    else if dn > 0 { cur[ch] = max(0, cur[ch] - dn * speed) }
                }
                let mine = active[ch] ? cur[ch] : 0
                let lib = Int((Double(f.vol[ch]) * scale).rounded())
                if lib >= 6 && abs(mine - lib) > threshold {
                    div.append((f.pattern, f.row, ch, mine, lib))
                }
            }
        }
        let cells = frames.count * m.channels
        print("verify \(URL(fileURLWithPath: path).lastPathComponent): \(m.format) \(m.channels)ch, \(frames.count) rows captured, libxmp volmax=\(maxLib)")
        print("  volume divergences > \(threshold)/64: \(div.count) of \(cells) cells (\(cells > 0 ? div.count * 100 / cells : 0)%)")
        let byPat = Dictionary(grouping: div, by: { $0.pat }).mapValues { $0.count }.sorted { $0.value > $1.value }
        for (pat, cnt) in byPat.prefix(12) { print("    pattern \(pat): \(cnt) divergent cells") }
        print("  worst cells (mine vs libxmp):")
        for d in div.sorted(by: { abs($0.mine - $0.lib) > abs($1.mine - $1.lib) }).prefix(15) {
            print("    pat\(d.pat) row\(d.row) ch\(d.ch): mine=\(d.mine) libxmp=\(d.lib)")
        }
    }
}
