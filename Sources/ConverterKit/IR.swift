import Foundation

// MARK: - Intermediate Representation
//
// Both file formats are translated to/from this small, format-neutral model.
// Conversion is therefore expressed as four independent pieces:
//
//   XRNS  ──read──▶  IRSong  ──write──▶  DAWproject     (forward)
//   DAWproject ──read──▶ IRSong ──write──▶ XRNS         (reverse)
//
// Keeping a shared IR means the musical semantics (tempo, tracks, clips,
// notes) are defined once and neither reader/writer has to know about the
// other format.

/// 8-bit RGB colour as stored by both formats (Renoise: "r,g,b"; DAWproject: "#rrggbb").
struct RGB: Equatable {
    var r: Int
    var g: Int
    var b: Int

    /// Parse a Renoise `"178,80,80"` colour string.
    init?(renoise s: String) {
        let parts = s.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2] else { return nil }
        self.r = r; self.g = g; self.b = b
    }

    /// Parse a DAWproject `"#b25050"` colour string.
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.r = (v >> 16) & 0xFF
        self.g = (v >> 8) & 0xFF
        self.b = v & 0xFF
    }

    init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }

    var hex: String { String(format: "#%02x%02x%02x", r & 0xFF, g & 0xFF, b & 0xFF) }
    var renoise: String { "\(r),\(g),\(b)" }
    var isBlack: Bool { r == 0 && g == 0 && b == 0 }
}

/// Role of a track/mixer-channel. Maps to Renoise track kinds and DAWproject MixerRole.
enum TrackRole {
    case regular   // a normal note/sequencer track
    case master    // the single master channel
    case send      // an effect/send return track
}

/// A MIDI-style note. Times are in beats (quarter notes).
struct IRNote {
    var start: Double      // start, relative to the containing clip
    var length: Double     // duration in beats (always > 0)
    var key: Int           // MIDI key 0...127 (60 = middle C)
    var velocity: Double   // normalised 0...1
    /// Sample-start offset from a tracker `9xx`/`Oxx` command (0…255, 256ths),
    /// carried so the Renoise writer can re-emit it as `0Sxx`. nil = none.
    var sampleOffset: Int? = nil
    /// Index into `IRSong.instruments` for this note's sound. Used by the
    /// channel layout, where one track plays many instruments; nil means "use the
    /// track's own instrument" (the instrument layout, where track == instrument).
    var instrument: Int? = nil
}

/// A tempo change at an arrangement beat position. Tempo holds (step, not ramp)
/// until the next point — matching MIDI set-tempo semantics.
struct IRTempoPoint {
    var time: Double       // beats
    var bpm: Double
}

/// A volume envelope reduced to Renoise's AHDSR vocabulary. Each field is a
/// normalised 0…1 device value (sustain is a level; the rest are time-ish),
/// derived from a tracker instrument's volume envelope (XM/IT) or a Startrekker
/// AM synth's amplitude envelope.
struct ADSR {
    var attack: Double
    var hold: Double
    var decay: Double
    var sustain: Double
    var release: Double
}

/// A decoded instrument sample, carried so a writer that supports audio
/// (DAWproject) can embed it as reference material for re-orchestration.
struct ExtractedSample {
    var name: String
    var comment: String?
    var pcm: [Int16]       // mono, 16-bit
    var sampleRate: Int
    var rootKey: Int       // MIDI key the sample is tuned to (informational)
    var loopStart: Int = 0 // loop points in frames (loopEnd == 0 → no loop)
    var loopEnd: Int = 0
    var loopType: Int = 0  // 0 = forward, 1 = ping-pong, 2 = backward
    var newNoteAction: String = "NoteOff"  // NNA → Renoise: Cut / NoteOff / None
    var envelope: ADSR? = nil  // volume envelope (XM/IT/AM-synth), nil = none
}

/// An entry in a song's instrument table. Notes reference it by index (used by
/// the channel layout, where a single track plays many instruments over time).
/// A nil `sample` is a referenced-but-sampleless instrument (an empty slot).
struct IRInstrument {
    var name: String
    var sample: ExtractedSample?
}

/// A region on the arrangement timeline holding a bit of note content.
/// In the forward direction one clip is produced per Renoise pattern-instance.
struct IRClip {
    var start: Double      // start on the arrangement, in beats
    var length: Double     // length on the arrangement, in beats
    var name: String?
    var notes: [IRNote]    // note times are relative to `start`
}

/// A track and its mixer channel.
struct IRTrack {
    var role: TrackRole
    var name: String
    var comment: String?   // free-text notes (e.g. legacy-instrument identification)
    var color: RGB?
    var volume: Double     // linear gain, 1.0 = unity (0 dB)
    var pan: Double        // 0...1, 0.5 = centre
    var mute: Bool
    var solo: Bool
    var clips: [IRClip]

    init(role: TrackRole, name: String, comment: String? = nil, color: RGB? = nil,
         volume: Double = 1.0, pan: Double = 0.5,
         mute: Bool = false, solo: Bool = false, clips: [IRClip] = []) {
        self.role = role; self.name = name; self.comment = comment; self.color = color
        self.volume = volume; self.pan = pan
        self.mute = mute; self.solo = solo; self.clips = clips
    }

    /// All notes flattened to arrangement-absolute beat positions, sorted by start.
    var absoluteNotes: [IRNote] {
        var out: [IRNote] = []
        for clip in clips {
            for n in clip.notes {
                out.append(IRNote(start: clip.start + n.start, length: n.length,
                                  key: n.key, velocity: n.velocity,
                                  sampleOffset: n.sampleOffset, instrument: n.instrument))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}

/// A whole song.
struct IRSong {
    var tempo: Double = 120            // tempo at the start (always valid)
    /// Full tempo map. Empty means a constant `tempo`. When non-empty it is
    /// authoritative and includes the starting tempo.
    var tempoMap: [IRTempoPoint] = []
    var signatureNumerator: Int = 4
    var signatureDenominator: Int = 4
    var title: String?
    var artist: String?
    var comment: String?
    var tracks: [IRTrack] = []
    /// Decoded instrument samples (from legacy modules), embedded by the
    /// DAWproject writer as reference audio.
    var extractedSamples: [ExtractedSample] = []
    /// Ordered instrument table that `IRNote.instrument` indexes into. Populated
    /// by the channel layout (one track per tracker channel); empty otherwise, in
    /// which case the Renoise writer makes one instrument per track.
    var instruments: [IRInstrument] = []

    var regularTracks: [IRTrack] { tracks.filter { $0.role == .regular } }

    /// The tempo map to emit: the explicit map if present (sorted), otherwise a
    /// single point at the constant tempo.
    var resolvedTempoMap: [IRTempoPoint] {
        tempoMap.isEmpty ? [IRTempoPoint(time: 0, bpm: tempo)]
                         : tempoMap.sorted { $0.time < $1.time }
    }

    /// Record the tempo map and keep `tempo` (the starting value) in sync.
    mutating func setTempoMap(_ points: [IRTempoPoint]) {
        let sorted = points.sorted { $0.time < $1.time }
        tempoMap = sorted
        if let first = sorted.first { tempo = first.bpm }
    }

    /// Length of the arrangement in beats (end of the last note/clip on any track).
    var lengthInBeats: Double {
        var end = 0.0
        for t in tracks {
            for c in t.clips { end = max(end, c.start + c.length) }
        }
        return end
    }
}

// MARK: - Pitch conversion

/// Conversion between Renoise note names and MIDI keys.
///
/// Renoise stores notes as `"C-4"`, `"C#4"`, `"OFF"`, … with an internal value
/// range 0...119 where `C-0 == 0`. A sample's `BaseNote` of 48 corresponds to
/// `"C-4"`. We anchor the MIDI mapping at A-4 = 440 Hz = MIDI 69, which makes
/// Renoise `"C-4"` == MIDI 60 (middle C) — i.e. MIDI = renoiseValue + 12.
enum Pitch {
    static let renoiseToMidiOffset = 12
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Parse a Renoise note token. Returns nil for empty / "OFF" / unparseable.
    static func midiKey(fromRenoise token: String) -> Int? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard t.count == 3, t != "OFF", t != "---" else { return nil }
        let c = Array(t)
        let base: Int
        switch c[0] {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        let semitone = base + (c[1] == "#" ? 1 : 0)
        guard let octave = Int(String(c[2])) else { return nil }
        let value = octave * 12 + semitone
        return min(127, max(0, value + renoiseToMidiOffset))
    }

    /// Render a MIDI key as a 3-character Renoise note token, e.g. 60 -> "C-4".
    static func renoiseName(fromMidi key: Int) -> String {
        let value = min(119, max(0, key - renoiseToMidiOffset))
        let octave = value / 12
        let name = names[value % 12]
        return name.count == 1 ? "\(name)-\(octave)" : "\(name)\(octave)"
    }
}
