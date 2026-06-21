import Foundation

// Swift port of the Polyend Tracker file-format types from the canonical
// TypeScript library (tracker-lib): src/types/{patterns,project,instruments}.ts.
// Field names and numeric encodings mirror the TS source of truth so the
// codecs in PolyendPattern/Project/Metadata/Instrument stay a 1:1 translation.
//
// EXPERIMENTAL: validated by round-trip (parse∘write) self-consistency, not
// against Polyend hardware output. See PolyendSong.swift for the IR bridge.

// MARK: - Patterns (.mtp)

struct FXRecord: Equatable {
    let index: Int
    let symbol: String
    let name: String
    let min: Int
    let max: Int
    let def: Int
    let scaledMin: Int?
    let scaledMax: Int?

    init(_ index: Int, _ symbol: String, _ name: String, _ min: Int, _ max: Int, _ def: Int,
         scaled: (Int, Int)? = nil) {
        self.index = index; self.symbol = symbol; self.name = name
        self.min = min; self.max = max; self.def = def
        self.scaledMin = scaled?.0; self.scaledMax = scaled?.1
    }
}

struct FX: Equatable {
    var type: FXRecord
    var value: Int
}

struct StepData: Equatable {
    /// 0–127 = note; -1 empty; -2 off/fade; -3 off/cut; -4 off (default).
    var note: Int
    /// 0–47 sample instruments, 48–63 MIDI, 64–66 synth engines.
    var instrument: Int
    /// Exactly two lanes: fx[0] is the lower lane, fx[1] the upper (on disk fx1 precedes fx0).
    var fx: [FX]
}

struct TrackData: Equatable {
    var length: Int          // steps in the track, min 1 max 128 (stored as count-1)
    var steps: [StepData]
}

struct PatternHeader: Equatable {
    var idFile: String       // "PM" (or "KS")
    var type: Int
    var fwVersion: [Int]     // 4 bytes
    var fileStructureVersion: String  // dotted, 4 parts
    var size: Int
}

struct PatternData: Equatable {
    var header: PatternHeader
    var tracks: [TrackData]
    var crc: UInt32
    var trackCount: Int
}

enum PatternConstants {
    static let headerSize = 14
    static let paddingSize = 2
    static let unusedSize = 12          // header trailer; the TS write/parse use 12 (the 10 in the TS const is an off-by-2 used only by its size-detection)
    static let trackCountOld = 8
    static let trackCountOG = 12
    static let trackCountMiniPlus = 16
    static let stepCount = 128
    static let stepSize = 6
    static let trackHeaderSize = 1
    static let crcSize = 4
    static let preTrackSize = headerSize + paddingSize + unusedSize     // 28
    static let trackSize = trackHeaderSize + stepSize * stepCount       // 769
}

/// Effect table, index == position. Ported from PatternFX in src/types/patterns.ts.
enum PolyendFX {
    static let table: [FXRecord] = [
        FXRecord(0, "-", "None", 0, 100, 0),
        FXRecord(1, "!", "Off", 0, 0, 0),
        FXRecord(2, "m", "Micro-move", 0, 100, 0),
        FXRecord(3, "R", "Roll", 0, 47, 1),
        FXRecord(4, "C", "Chance", 0, 100, 0),
        FXRecord(5, "n", "Random Note", 0, 100, 0),
        FXRecord(6, "i", "Random Instrument", 0, 100, 0),
        FXRecord(7, "v", "Random Volume", 0, 100, 0),
        FXRecord(8, "a", "MIDI CC A", 0, 127, 0),
        FXRecord(9, "b", "MIDI CC B", 0, 127, 0),
        FXRecord(10, "c", "MIDI CC C", 0, 127, 0),
        FXRecord(11, "d", "MIDI CC D", 0, 127, 0),
        FXRecord(12, "e", "MIDI CC E", 0, 127, 0),
        FXRecord(13, "x", "Break Pattern", 1, 1, 1),
        FXRecord(14, "0", "MIDI Chord", 0, 15, 0),
        FXRecord(15, "T", "Tempo", 4, 200, 60, scaled: (8, 400)),
        FXRecord(16, "x", "Random FX Value", 0, 255, 0),
        FXRecord(17, "I", "Swing", 25, 75, 50, scaled: (-25, 25)),
        FXRecord(18, "V", "Volume/Velocity", 0, 100, 0),
        FXRecord(19, "G", "Glide", 0, 100, 0),
        FXRecord(20, "q", "Gate Length", 0, 100, 0),
        FXRecord(21, "A", "Arp", 0, 33, 0),
        FXRecord(22, "p", "Position", 0, 100, 0),
        FXRecord(23, "g", "Volume LFO", 0, 24, 0),
        FXRecord(24, "h", "Panning LFO", 0, 30, 0),
        FXRecord(25, "S", "Slice", 0, 47, 0, scaled: (1, 48)),
        FXRecord(26, "r", "Reverse Playback", 0, 1, 0),
        FXRecord(27, "L", "Low-pass", 0, 100, 0),
        FXRecord(28, "H", "High-pass", 0, 100, 0),
        FXRecord(29, "B", "Band-pass", 0, 100, 0),
        FXRecord(30, "s", "Delay Send", 0, 100, 0),
        FXRecord(31, "P", "Panning", 0, 100, 0, scaled: (-50, 50)),
        FXRecord(32, "t", "Reverb Send", 0, 100, 0),
        FXRecord(33, "l", "Finetune LFO", 0, 30, 0),
        FXRecord(34, "M", "Micro-tune/Pitchbend", 0, 198, 0, scaled: (-99, 99)),
        FXRecord(35, "j", "Filter LFO", 0, 30, 0),
        FXRecord(36, "k", "Position LFO", 0, 30, 0),
        FXRecord(37, "f", "MIDI CC F", 0, 127, 0),
        FXRecord(38, "D", "Overdrive", 0, 100, 0),
        FXRecord(39, "E", "Bit Depth", 1, 16, 0),
        FXRecord(40, "U", "Tune", 0, 48, 0, scaled: (-24, 24)),
        FXRecord(41, "F", "Slide Up", 0, 255, 0),
        FXRecord(42, "J", "Slide Down", 0, 255, 0),
    ]

    static let none = table[0]

    /// Effect record for a stored index; clamps unknown indices to None.
    static func record(_ index: Int) -> FXRecord {
        (index >= 0 && index < table.count) ? table[index] : none
    }
}

// MARK: - Patterns metadata ("patternsMetadata", PAMD)

struct MetadataHeaderInfo: Equatable {
    var fileIdentifier: String   // "PAMD"
    var version: Int             // 1
    var totalSize: Int
    var controlFlags: Int
}

struct PatternsMetadata: Equatable {
    var headerInfo: MetadataHeaderInfo
    var patternNames: [String]
}

enum PatternsMetaConstants {
    static let fileIdentifier = "PAMD"
    static let version = 1
    static let headerSize = 16
    static let patternRecordSize = 50
    static let nameMax = 31
}

// MARK: - Project (.mt)

struct ProjectHeader: Equatable {
    var idFile: String           // "MT"
    var type: Int
    var fwVersion: String        // dotted
    var fileStructureVersion: String
    var size: Int
}

struct SongData: Equatable {
    var playlist: [Int]          // 255 entries; 0 = empty slot
    var playlistPos: Int
}

struct ReverbParams: Equatable {
    var size: Float
    var damp: Float
    var predelay: Float
    var diffusion: Float
}

struct MtValues: Equatable {
    var globalTempo: Float
    var trackNames: [String]     // 16 entries
    var delayFeedback: Int
    var delayTime: Int
    var delayParams: Int
    var delayVolume: Int
    var delayMute: Int
    var reverb: ReverbParams
    var reverbVolume: Int
    var reverbMute: Int
}

struct ProjectData: Equatable {
    var crc: String
    var header: ProjectHeader
    var projectName: String
    var song: SongData
    var values: MtValues
}

enum ProjectConstants {
    static let fileIdentifier = "MT"
    static let type = 1
    static let paddingAfterHeader = 2
    static let playlistSize = 255
    static let projectNameSize = 32
    static let trackNameSize = 21
    static let trackNameSizeShort = 8
    static let crcSize = 4
}

// MARK: - Instruments (.pti)

enum SampleType: Int { case waveFile = 0, wavetable = 1 }

enum InstrumentPlayMode: Int {
    case oneShot = 0, forwardLoop, backwardLoop, pingpongLoop, slice, beatSlice, wavetable, granular
}

enum InstrumentFilterType: Int { case lowPass = 0, highPass, bandPass }

enum LFOShape: Int { case revSaw = 0, saw, triangle, square, random }

enum LFOSpeed: Int {
    case s128 = 0, s96, s64, s48, s32, s24, s16, s12, s8, s6, s4, s3, s2, s3_2, s1, s3_4,
         s1_2, s3_8, s1_3, s1_4, s3_16, s1_6, s1_8, s1_12, s1_16, s1_24, s1_32, s1_48, s1_64
}

enum GranularShape: Int { case square = 0, triangle, gauss }
enum GranularType: Int { case forward = 0, backward, pingPong }

struct InstrumentHeader: Equatable {
    var idFile: String           // "TI"
    var type: Int
    var fwVersion: String
    var fileStructureVersion: String
    var size: Int
}

struct SampleBankSlot: Equatable {
    var type: Int
    var filename: String         // max 32 bytes
    var length: Int              // frames
    var wavetableWindowSize: Int
    var wavetableWindowCount: Int
    var channels: Int            // 1 mono, 2 stereo
}

struct Envelope: Equatable {
    var amount: Float
    var delay: Int
    var attack: Int
    var decay: Int
    var sustain: Float
    var release: Int
}

struct LFO: Equatable {
    var shape: Int
    var speed: Int
    var amount: Float
}

struct Automation: Equatable {
    var enabled: Bool
    var isLFO: Bool
    var envelope: Envelope
    var lfo: LFO
}

struct Granular: Equatable {
    var grainLength: Int
    var currentPosition: Int
    var shape: Int
    var type: Int
}

struct InstrumentData: Equatable {
    var header: InstrumentHeader
    var isActive: Bool
    var sample: SampleBankSlot
    var playmode: Int
    var startPoint: Int
    var loopPoint1: Int
    var loopPoint2: Int
    var endPoint: Int
    var wavetableCurrentWindow: UInt32
    var automations: [Automation]   // 6
    var cutoff: Float
    var resonance: Float
    var filterType: Int
    var filterEnabled: Bool
    var tune: Int
    var finetune: Int
    var volume: Float
    var panning: Float
    var delaySend: Float
    var reverbSend: Float
    var slices: [Int]               // 48
    var numSlices: Int
    var selectedSlice: Int
    var granular: Granular
    var overdrive: Float
    var bitdepth: Int
    var crc: String
    /// Interleaved 16-bit PCM (the .pti stores it de-interleaved/planar on disk;
    /// the codec converts). Empty for an instrument with no sample.
    var pcm: [Int16]
}

enum InstrumentConstants {
    static let fileIdentifier = "TI"
    static let type = 1
    static let headerSize = 16          // 14 fields + 2 padding
    static let paddingAfterHeader = 2
    // Verified against real factory files: an audio-less .mti is exactly
    // 16 + 372 + 4 (header + main fields + CRC), and a .pti stores the header
    // `size` field as 0x0174 = 372. The TS *read* uses 372 (correct); only its
    // *write* adds a stray +2 (and allocates 376). We use 372 for both, so the
    // layout matches hardware: header(16) + fields(372) + audio + CRC(4).
    static let mainFieldsSize = 372
    static let crcSize = 4
    static let envelopeCount = 6
    static let lfoCount = 6
    static let slicesCount = 48
    static let max16Bit = 65535
    static let sampleRate = 44100
}
