import Foundation

// MARK: - Tracker effect → Renoise effect-column translation
//
// libxmp normalises every format's effects onto the FX_* constants in
// effects.h, exposed per cell as fx1Type/fx1Param (main) and fx2Type/fx2Param
// (secondary, usually an XM/IT volume-column effect). Renoise's importer writes
// most of these into a track's single effect column; the mapping below was
// derived by correlating libxmp's raw values against Renoise's own conversions
// of the MOD/XM/IT oracles (the only formats Renoise can import).
//
// Two conventions learned from the oracles:
//   • Renoise omits the Value entirely when the parameter is 0 (a "continue"
//     command like tone-porta/vibrato with effect memory) — it never writes "00".
//   • IT/S3M carry fine/extra-fine slides in the main porta effect with a 0xE0/
//     0xF0 high nibble; Renoise collapses them to the plain slide value.
//
// Panning (FX_SETPAN) and the volume-column effects go to the note column's
// panning / volume sub-columns, handled in TrackerRenoise, not here.

enum TrackerEffects {
    // libxmp FX_* constants we translate (see Sources/CLibxmp/effects.h).
    private enum FX {
        static let arpeggio = 0x00, portaUp = 0x01, portaDn = 0x02, tonePorta = 0x03
        static let vibrato = 0x04, toneVSlide = 0x05, vibraVSlide = 0x06, tremolo = 0x07
        static let offset = 0x09, volSlide = 0x0A, jump = 0x0B, volSet = 0x0C
        static let breakRow = 0x0D, extended = 0x0E, speed = 0x0F
        static let s3mArpeggio = 0xB4, itBPM = 0x87, s3mSpeed = 0xA3, trkVol = 0x80
        static let ultTempo = 0x5F   // ULT: 01-2f = speed, 30-ff = BPM
    }

    /// The main (fx1) effect → one Renoise effect-column cell, or nil if it has no
    /// effect-column representation (no-op, or it belongs in volume/panning).
    static func effectColumn(type: Int, param p: Int, format: String) -> RNEffectColumn? {
        let fineFmt = (format == "IT" || format == "S3M")
        // IT/S3M fine & extra-fine porta live in the main effect (0xE0/0xF0 high
        // nibble); Renoise writes the plain low-nibble amount.
        func porta(_ n: String) -> RNEffectColumn { ec(n, fineFmt && p >= 0xE0 ? p & 0x0F : p) }

        switch type {
        case FX.arpeggio, FX.s3mArpeggio:
            return p == 0 ? nil : ec("0A", p)            // 00 = no arpeggio (not emitted)
        case FX.portaUp:    return porta("0U")
        case FX.portaDn:    return porta("0D")
        case FX.tonePorta, FX.toneVSlide: return ec("0G", p)   // tone porta (+ vol slide) → glide
        case FX.vibrato:    return ec("0V", p)
        case FX.vibraVSlide: return nil                  // oracle emits no effect (vol part → vol col)
        case FX.tremolo:    return ec("0O", p)
        case FX.offset:     return ec("0S", p)
        case FX.volSlide:                                // up nibble → 0I (fade in), down → 0O (fade out)
            let up = p >> 4, dn = p & 0x0F
            // IT/S3M fine volume slides: the F nibble marks "fine" and chooses the
            // direction — DxF = fine up by x (low nibble F), DFy = fine down by y
            // (high nibble F). Without this the high F reads as a large up amount,
            // so a fine fade-DOWN wrongly becomes a fast fade-IN.
            if fineFmt && dn == 0xF && up != 0 { return ec("0I", up << 4) }   // DxF: fine up by x
            if fineFmt && up == 0xF && dn != 0 { return ec("0O", dn << 4) }   // DFy: fine down by y
            if up > 0 { return ec("0I", up << 4) }       // slide up
            return ec("0O", dn << 4)                     // slide down (param 0 → 0O00 = continue)
        case FX.jump:       return ec("0B", p)
        case FX.volSet:     return ec("0M", min(0xFF, p * 8))
        case FX.breakRow:   return ec("ZB", p)
        case FX.extended:
            if fineFmt { return nil }                    // IT/S3M S-commands differ; not E-commands
            switch p >> 4 {
            case 0x9: return ec("0R", p & 0x0F)          // retrigger
            case 0xD: return ec("0Q", p & 0x0F)          // note delay
            default:  return nil
            }
        case FX.speed:      return p >= 0x20 ? ec("ZT", p) : ec("ZL", p)
        case FX.itBPM:      return ec("ZT", p)
        case FX.s3mSpeed:   return ec("ZL", p)
        case FX.ultTempo:   return p >= 0x30 ? ec("ZT", p) : (p >= 1 ? ec("ZL", p) : nil)
        case FX.trkVol:     return ec("0L", min(0xFF, p * 3))   // IT set-track-volume
        default:            return nil
        }
    }

    /// The note column's panning sub-column for a main effect, or nil. It holds
    /// either a pan level (00 left … 40 centre … 80 right) or a letter command:
    ///   • FX_SETPAN (0…255, Renoise halves it) → pan level.
    ///   • IT/S3M S8x (extended sub-8, 0…15) → pan level.
    ///   • IT/S3M SDx note delay (extended sub-D) → "Qx" (Renoise puts the delay
    ///     in the panning column, unlike MOD/XM which use the 0Q effect column).
    static func panning(type: Int, param p: Int, format: String) -> String? {
        if type == 0x08 { return String(format: "%02X", min(0x80, p >> 1)) }
        if (format == "IT" || format == "S3M"), type == 0x0E {
            switch p >> 4 {
            case 0x8: return String(format: "%02X", min(0x80, (p & 0x0F) * 8))
            case 0xD: return "Q" + String(p & 0x0F, radix: 16, uppercase: true)
            default:  return nil
            }
        }
        return nil
    }

    /// The note panning from a *secondary* (volume-column) set-pan effect, or nil.
    ///   • XM: libxmp stores the 16 vol-column pan levels inverted in f2p (0…240);
    ///     Renoise maps them to 0x80…0x01 — matched here (Renoise gets XM right).
    ///   • IT/S3M: f2p = pan(0…64)×4, so the correct Renoise pan is f2p/2. Renoise's
    ///     OWN IT import mangles this into a junk volume-column value (it can't
    ///     represent vol-column pan); we deliberately diverge and write the real pan.
    static func secondaryPanning(type: Int, param p: Int, format: String) -> String? {
        guard type == 0x08 else { return nil }
        if format == "XM" {
            return String(format: "%02X", max(0, min(0x80, 0x80 - Int((Double(p) * 127.0 / 240.0).rounded()))))
        }
        return String(format: "%02X", max(0, min(0x80, p / 2)))
    }

    /// A *secondary* (volume-column) effect that has a proper Renoise effect-column
    /// equivalent, or nil. IT/S3M only: vol-column tone-portamento (Gx) → 0G and
    /// vibrato (Hx) → 0V. Renoise's own IT import can't represent these and emits
    /// junk volume values; we deliberately diverge and preserve the musical intent.
    static func secondaryEffect(type: Int, param p: Int, format: String) -> RNEffectColumn? {
        guard format == "IT" || format == "S3M" else { return nil }
        switch type {
        case 0x03: return ec("0G", p)   // vol-column tone portamento → glide
        case 0x04: return ec("0V", p)   // vol-column vibrato (depth) → vibrato
        default:   return nil
        }
    }

    /// An effect-column cell. Renoise omits the Value when the parameter is 0
    /// (e.g. a "continue" command), so a 0 value becomes an empty column.
    private static func ec(_ number: String, _ value: Int) -> RNEffectColumn {
        let v = max(0, min(0xFF, value))
        return RNEffectColumn(number: number, value: v == 0 ? nil : String(format: "%02X", v))
    }
}
