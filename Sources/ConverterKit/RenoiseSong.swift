import Foundation

// MARK: - Raw Renoise song model
//
// A faithful-but-minimal representation of the parts of Song.xml we care about.
// The PatternSequence (pattern *order*) is preserved as a list of pattern
// indices; the converter walks it in order when laying clips onto the timeline.

struct RNNoteColumn {
    var note: String?        // e.g. "C-4", "OFF", or nil for empty
    var instrument: String?  // hex string like "01"
    var volume: String?      // hex string 00...80 (volume) — others are commands
    var panning: String?     // hex string
    var delay: String?       // hex string 00...FF (fraction of a line)
}

/// An effect-column cell, e.g. Number="0C" Value="0F" (note cut after 15 ticks).
struct RNEffectColumn {
    var number: String?   // command code such as "0G", "0C", "0Q", "ZL"
    var value: String?    // hex parameter, e.g. "10"
}

struct RNLine {
    var index: Int
    var noteColumns: [RNNoteColumn]
    var effectColumns: [RNEffectColumn] = []
}

/// One track's worth of a pattern. `lines` is sparse (only non-empty lines).
struct RNPatternTrack {
    var lines: [RNLine] = []
}

struct RNPattern {
    var numberOfLines: Int
    var tracks: [RNPatternTrack]   // parallel (by index) to RenoiseSong.tracks
    /// Kind of each positional pattern track, so the writer can emit the right
    /// element name (PatternTrack / PatternMasterTrack / PatternSendTrack).
    var trackKinds: [TrackRole] = []
}

struct RNTrack {
    var kind: TrackRole
    var name: String
    var color: RGB?
    var volume: Double = 1.0
    var pan: Double = 0.5
    var muted: Bool = false
    var soloed: Bool = false
    var visibleNoteColumns: Int = 1
    var visibleEffectColumns: Int = 1
}

/// One sample inside a Renoise instrument. The audio is embedded in the .xrns
/// ZIP under `SampleData/Instrument{NN} (name)/Sample00 (name).{audioExt}` and
/// located by that folder convention (no `<FileName>` needed).
struct RNSample {
    var name: String
    var audio: Data                        // encoded audio bytes to embed (FLAC, like Renoise)
    var audioExt: String = "flac"          // container extension for the audio
    var volume: Double = 1.0
    var transpose: Int = 0                 // semitones
    var finetune: Int = 0                  // −127…127 (≈ 1/128 semitone)
    var baseNote: Int = 48                 // root key as a Renoise note (C-4 = 48 = MIDI 60)
    var loopMode: String = "Off"           // Off / Forward / Backward / PingPong
    var loopStart: Int = 0
    var loopEnd: Int = 0
    var newNoteAction: String = "NoteOff"  // Cut / NoteOff / None  (NNA)
    var envelope: ADSR? = nil              // volume AHDSR modulation, nil = none
    var noteStart: Int = 0                 // keyzone range, Renoise note value 0…119
    var noteEnd: Int = 119                 // (a drum kit maps several samples across the keyboard)
}

/// A Renoise instrument slot. Empty `samples` is an empty placeholder (notes can
/// still reference it); one sample is the common case; several samples are a
/// key-mapped instrument (drum kit / layered XM/IT instrument).
struct RNInstrument {
    var name: String
    var samples: [RNSample]

    init(name: String, samples: [RNSample] = []) { self.name = name; self.samples = samples }
    /// Backward-compatible single-sample construction.
    init(name: String, sample: RNSample?) { self.name = name; self.samples = sample.map { [$0] } ?? [] }
    /// The first (often only) sample — convenience for single-sample readers.
    var sample: RNSample? { samples.first }
}

struct RenoiseSong {
    var docVersion: Int = 67
    var bpm: Double = 120
    var linesPerBeat: Int = 4
    var ticksPerLine: Int = 12
    /// True when this song came from a tracker-module import (Renoise sets
    /// SampleOffsetCompatibilityMode on MOD/XM/IT import, and so do we). Such
    /// songs store the RAW module BPM with the speed in TicksPerLine, so the
    /// quarter-note tempo must be recovered as 24·BPM/(rpb·TPL). A native Renoise
    /// song stores its musical BPM directly and is read verbatim.
    var isModuleImport: Bool = false
    var signatureNumerator: Int = 4
    var signatureDenominator: Int = 4
    var songName: String?
    var artist: String?
    var comments: [String] = []
    var tracks: [RNTrack] = []
    var patterns: [RNPattern] = []
    var sequence: [Int] = []       // pattern indices, in play order
    var instruments: [RNInstrument] = []   // instrument slots (notes reference by hex index)
}

// MARK: - Reader (Song.xml -> RenoiseSong)

enum RenoiseReader {
    static func read(songXML data: Data) throws -> RenoiseSong {
        let root = try XML.parse(data)
        guard root.name == "RenoiseSong" else {
            throw ConvertError.parse("root element is not <RenoiseSong>")
        }

        var song = RenoiseSong()
        song.docVersion = root.attributeText("doc_version").flatMap { Int($0) } ?? 67

        if let g = root.firstChild("GlobalSongData") {
            song.bpm = g.childDouble("BeatsPerMin") ?? 120
            song.linesPerBeat = g.childInt("LinesPerBeat") ?? 4
            song.ticksPerLine = g.childInt("TicksPerLine") ?? 12
            song.isModuleImport = g.childBool("SampleOffsetCompatibilityMode") ?? false
            song.signatureNumerator = g.childInt("SignatureNumerator") ?? 4
            song.signatureDenominator = g.childInt("SignatureDenominator") ?? 4
            song.songName = g.childText("SongName")
            song.artist = g.childText("Artist")
            if let comments = g.firstChild("SongComments") {
                song.comments = comments.elements(forName: "SongComment").map { $0.trimmedText ?? "" }
            }
        }

        // Tracks, in document order (sequencer..., group..., master, send...).
        if let tracks = root.firstChild("Tracks") {
            for el in tracks.childElements {
                guard let t = parseTrack(el) else { continue }
                song.tracks.append(t)
            }
        }

        // Pattern pool.
        if let pool = root.firstChild("PatternPool"), let pats = pool.firstChild("Patterns") {
            for patEl in pats.elements(forName: "Pattern") {
                song.patterns.append(parsePattern(patEl))
            }
        }

        // Pattern sequence (the play order).
        if let seq = root.firstChild("PatternSequence"),
           let entries = seq.firstChild("SequenceEntries") {
            for entry in entries.elements(forName: "SequenceEntry") {
                if let idx = entry.childInt("Pattern") { song.sequence.append(idx) }
            }
        }
        // If a song somehow has patterns but no explicit sequence, play them in order.
        if song.sequence.isEmpty && !song.patterns.isEmpty {
            song.sequence = Array(0..<song.patterns.count)
        }

        // Instruments: names + sample metadata (baseNote, loop, NNA). The sample
        // audio lives in the container; the .xrns reader decodes and attaches it.
        if let insts = root.firstChild("Instruments") {
            for el in insts.elements(forName: "Instrument") {
                song.instruments.append(parseInstrument(el))
            }
        }

        return song
    }

    /// Parse one `<Instrument>`: its name and (if present) its first sample's
    /// metadata. Audio is left empty here — decoded from the ZIP by the reader.
    private static func parseInstrument(_ el: XML) -> RNInstrument {
        let name = el.childText("Name") ?? ""
        guard let sm = el.firstChild("SampleGenerator")?.firstChild("Samples")?.firstChild("Sample") else {
            return RNInstrument(name: name, sample: nil)
        }
        var s = RNSample(name: sm.childText("Name") ?? name, audio: Data())
        s.baseNote = sm.firstChild("Mapping")?.childInt("BaseNote") ?? 48
        s.transpose = sm.childInt("Transpose") ?? 0
        s.loopMode = sm.childText("LoopMode") ?? "Off"
        s.loopStart = sm.childInt("LoopStart") ?? 0
        s.loopEnd = sm.childInt("LoopEnd") ?? 0
        s.newNoteAction = sm.childText("NewNoteAction") ?? "NoteOff"
        return RNInstrument(name: name, sample: s)
    }

    private static func parseTrack(_ el: XML) -> RNTrack? {
        let kind: TrackRole
        switch el.name {
        case "SequencerTrack", "SequencerGroupTrack": kind = .regular
        case "SequencerMasterTrack": kind = .master
        case "SequencerSendTrack": kind = .send
        default: return nil
        }

        var t = RNTrack(kind: kind, name: el.childText("Name") ?? defaultName(kind))
        if let c = el.childText("Color") { t.color = RGB(renoise: c) }
        let state = el.childText("State") ?? "Active"
        t.muted = (state != "Active")
        t.soloed = el.childBool("Soloed") ?? false
        t.visibleNoteColumns = el.childInt("NumberOfVisibleNoteColumns") ?? 1

        // Volume/pan live in the first *MixerDevice of the track's device chain.
        if let devices = el.firstChild("FilterDevices")?.firstChild("Devices") {
            for dev in devices.childElements where dev.name.hasSuffix("MixerDevice") {
                if let v = dev.firstChild("Volume")?.childDouble("Value") { t.volume = v }
                if let p = dev.firstChild("Panning")?.childDouble("Value") { t.pan = p }
                break
            }
        }
        return t
    }

    private static func defaultName(_ kind: TrackRole) -> String {
        switch kind {
        case .master: return "Master"
        case .send: return "Send"
        case .regular: return "Track"
        }
    }

    private static func parsePattern(_ el: XML) -> RNPattern {
        let lines = el.childInt("NumberOfLines") ?? 64
        var tracks: [RNPatternTrack] = []
        if let tracksEl = el.firstChild("Tracks") {
            // PatternTrack / PatternMasterTrack / PatternSendTrack, in order.
            for trackEl in tracksEl.childElements {
                tracks.append(parsePatternTrack(trackEl))
            }
        }
        return RNPattern(numberOfLines: lines, tracks: tracks)
    }

    private static func parsePatternTrack(_ el: XML) -> RNPatternTrack {
        var pt = RNPatternTrack()
        guard let linesEl = el.firstChild("Lines") else { return pt }
        for lineEl in linesEl.elements(forName: "Line") {
            let index = lineEl.attributeText("index").flatMap { Int($0) } ?? 0
            var columns: [RNNoteColumn] = []
            if let ncs = lineEl.firstChild("NoteColumns") {
                for nc in ncs.elements(forName: "NoteColumn") {
                    columns.append(RNNoteColumn(
                        note: nc.childText("Note"),
                        instrument: nc.childText("Instrument"),
                        volume: nc.childText("Volume"),
                        panning: nc.childText("Panning"),
                        delay: nc.childText("Delay")))
                }
            }
            var effects: [RNEffectColumn] = []
            if let ecs = lineEl.firstChild("EffectColumns") {
                for ec in ecs.elements(forName: "EffectColumn") {
                    effects.append(RNEffectColumn(number: ec.childText("Number"), value: ec.childText("Value")))
                }
            }
            pt.lines.append(RNLine(index: index, noteColumns: columns, effectColumns: effects))
        }
        return pt
    }
}

// MARK: - Writer (RenoiseSong -> Song.xml)

enum RenoiseWriter {
    static func write(_ song: RenoiseSong) -> String {
        let root = XML("RenoiseSong").attr("doc_version", String(song.docVersion))

        // --- GlobalSongData ---
        // Renoise reads this block in a fixed element order (stricter than the
        // schema's xs:all); skipping the Metronome/Shuffle/compatibility fields
        // makes it bail and fall back to a 32-BPM default. So emit the full set
        // in Renoise's own order (matching a native MOD/XM/IT import).
        let g = root.element("GlobalSongData")
        g.leaf("BeatsPerMin", String(format: "%g", song.bpm))
        g.leaf("LinesPerBeat", String(song.linesPerBeat))
        g.leaf("TicksPerLine", String(song.ticksPerLine))
        g.leaf("SignatureNumerator", String(song.signatureNumerator))
        g.leaf("SignatureDenominator", String(song.signatureDenominator))
        g.leaf("MetronomeBeatsPerBar", "0")
        g.leaf("MetronomeLinesPerBeat", "0")
        g.leaf("MetronomeVolume", "0.707945764")
        g.leaf("ShuffleIsActive", "false")
        // Renoise's player reads a fixed 4-entry shuffle array; an empty
        // <ShuffleAmounts/> makes TPlayerGlobalSongData index out of bounds and
        // crash on load. Emit the four zero amounts Renoise itself writes.
        let shuffle = g.element("ShuffleAmounts")
        for _ in 0..<4 { shuffle.leaf("ShuffleAmount", "0") }
        g.leaf("Octave", "4")
        g.leaf("LoopCoeff", "4")
        g.leaf("SongName", song.songName ?? "")
        g.leaf("Artist", song.artist ?? "")
        if !song.comments.isEmpty {
            let c = g.element("SongComments")
            for line in song.comments { c.leaf("SongComment", line) }
        }
        g.leaf("ShowSongCommentsAfterLoading", "false")
        g.leaf("ShowUsedAutomationsOnly", "false")
        g.leaf("FollowAutomations", "true")
        g.leaf("SampleOffsetCompatibilityMode", "true")    // MOD/XM/IT import default
        g.leaf("PitchEffectsCompatibilityMode", "true")
        g.leaf("GlobalTrackHeadroom", "0.5")
        g.leaf("PlaybackEngineVersion", "1")
        g.leaf("RenderSelectionNameCounter", "0")
        g.leaf("RecordSampleNameCounter", "0")
        g.leaf("NewSampleNameCounter", "0")

        // --- Instruments ---
        // Renoise needs at least one instrument for notes to reference. Each slot
        // is emitted in order; sample-backed slots carry a playable sample whose
        // audio is embedded in the container under SampleData/ (see writeIR).
        let instruments = root.element("Instruments")
        let slots = song.instruments.isEmpty ? [RNInstrument(name: "Converted Instrument")] : song.instruments
        for slot in slots { instruments.add(instrumentElement(slot)) }

        // --- Tracks ---
        let tracksEl = root.element("Tracks")
        for t in song.tracks {
            tracksEl.add(trackElement(t))
        }

        // --- PatternPool ---
        let pool = root.element("PatternPool")
        pool.leaf("HighliteStep", "0")
        let pats = pool.element("Patterns").attr("type", "PatternList")
        for p in song.patterns {
            pats.add(patternElement(p))
        }

        // --- PatternSequence (the play order) ---
        let seq = root.element("PatternSequence")
        let entries = seq.element("SequenceEntries").attr("type", "PatternSequenceEntryList")
        for idx in song.sequence {
            let e = entries.element("SequenceEntry")
            e.leaf("IsSectionStart", "false")
            e.leaf("Pattern", String(idx))
        }

        return root.document(declaration: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    }

    // A Renoise automation/device parameter value: <Name><Value>v</Value>...</Name>
    private static func param(_ name: String, _ value: String) -> XML {
        let e = XML(name)
        e.leaf("Value", value)
        e.leaf("Visualization", "Device only")
        return e
    }

    /// Build one `<Instrument>`. Sample-backed slots get a `<SampleGenerator>`
    /// with a single mapped sample (root key, loop, NNA); the audio itself is
    /// embedded in the container by the ZIP step, located by folder convention.
    private static func instrumentElement(_ inst: RNInstrument) -> XML {
        // Real Renoise instruments/samples carry NO `type` attribute — only
        // polymorphic items (track kinds, devices) do. Emitting type="Instrument"
        // is what makes Renoise fail with "could not create an object of type
        // instrument", so these wrappers/items stay attribute-free.
        let el = XML("Instrument")
        el.leaf("Name", inst.name)
        guard !inst.samples.isEmpty else { return el }

        // One <Sample> per keyzone. A single-sample instrument spans the whole
        // keyboard (0…119); a key-mapped instrument (drum kit / layered XM/IT)
        // emits several, each with its own note range — so a drum line plays the
        // right drum per key instead of one sample pitched across the keyboard.
        // All samples share modulation set 0 (matching Renoise's own import).
        let gen = el.element("SampleGenerator")
        let samples = gen.element("Samples")
        for s in inst.samples {
            let sm = samples.element("Sample")
            sm.leaf("Name", s.name)
            sm.leaf("Volume", floatString(s.volume))
            sm.leaf("Panning", "0.5")
            sm.leaf("Transpose", String(max(-127, min(127, s.transpose))))
            sm.leaf("Finetune", String(max(-127, min(127, s.finetune))))
            sm.leaf("NewNoteAction", s.newNoteAction)
            sm.leaf("LoopMode", s.loopMode)
            sm.leaf("LoopStart", String(max(0, s.loopStart)))
            sm.leaf("LoopEnd", String(max(0, s.loopEnd)))
            sm.leaf("ModulationSetIndex", "0")
            let map = sm.element("Mapping")
            map.leaf("BaseNote", String(max(0, min(119, s.baseNote))))
            map.leaf("NoteStart", String(max(0, min(119, s.noteStart))))
            map.leaf("NoteEnd", String(max(0, min(119, s.noteEnd))))
            map.leaf("MapKeyToPitch", "true")
        }

        // Every sample-backed instrument carries the base modulation set Renoise
        // itself writes on import — a single SampleMixerModulationDevice. Renoise's
        // module import does NOT translate XM/IT volume envelopes into modulation,
        // and emitting an AHDSR-only set crashes its instrument-editor UI on load
        // (TSampleModulationSetView::CreateInputSliderRack), so we emit only this
        // base device (matching the oracle exactly). The envelope stays in the IR
        // (and is used by the DAWproject writer) but isn't written to .xrns.
        let set = gen.element("ModulationSets").element("ModulationSet")
        set.leaf("SelectedPresetName", "Init")
        set.leaf("SelectedPresetLibrary", "")
        set.leaf("SelectedPresetIsModified", "true")
        let mix = set.element("Devices").element("SampleMixerModulationDevice").attr("type", "SampleMixerModulationDevice")
        mix.add(param("IsActive", "1.0"))
        mix.add(param("Volume", "1.0"))
        mix.add(param("Panning", "0.0"))
        mix.add(param("Pitch", "0.0"))
        mix.leaf("PitchModulationRange", "12")
        mix.add(param("Cutoff", "63.5"))
        mix.add(param("Resonance", "63.5"))
        mix.add(param("Drive", "0.0"))
        set.leaf("Name", "Set 01")
        set.leaf("FilterType", "0")
        set.leaf("FilterBankVersion", "3")
        el.leaf("ActiveGeneratorTab", "Samples")   // ensure the editor opens the valid Samples tab
        return el
    }

    /// Format a Double the way Renoise writes floats (e.g. 1.0, 0.5) — never in
    /// scientific notation, always with a decimal point.
    private static func floatString(_ v: Double) -> String {
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s
    }

    private static func trackElement(_ t: RNTrack) -> XML {
        let (elementName, mixerName): (String, String)
        switch t.kind {
        case .master: (elementName, mixerName) = ("SequencerMasterTrack", "MasterTrackMixerDevice")
        case .send:   (elementName, mixerName) = ("SequencerSendTrack", "SendTrackMixerDevice")
        case .regular:(elementName, mixerName) = ("SequencerTrack", "TrackMixerDevice")
        }

        let el = XML(elementName).attr("type", elementName)
        el.leaf("Name", t.name)
        if let c = t.color, !c.isBlack { el.leaf("Color", c.renoise) }
        el.leaf("ColorBlend", "0.0")
        el.leaf("State", t.muted ? "Off" : "Active")
        el.leaf("Soloed", t.soloed ? "true" : "false")

        // 12 note-column states/names (Renoise's fixed maximum).
        let states = el.element("NoteColumnStates")
        for _ in 0..<12 { states.leaf("NoteColumnState", "Active") }
        let names = el.element("NoteColumnNames")
        for _ in 0..<12 { names.element("NoteColumnName") }

        // Only regular tracks carry note columns; the master/send tracks declare
        // 0 (matching Renoise's own output — a non-regular track with note columns
        // is invalid and can crash Renoise on load).
        let visibleNote = t.kind == .regular ? max(1, min(12, t.visibleNoteColumns)) : 0
        el.leaf("NumberOfVisibleNoteColumns", String(visibleNote))
        el.leaf("NumberOfVisibleEffectColumns", String(max(1, min(8, t.visibleEffectColumns))))
        el.leaf("VolumeColumnIsVisible", "true")
        el.leaf("PanningColumnIsVisible", "true")
        el.leaf("DelayColumnIsVisible", "false")
        el.leaf("SampleEffectColumnIsVisible", "false")

        // Mixer device carrying the track's volume + panning.
        let devices = el.element("FilterDevices").element("Devices")
        let mixer = devices.element(mixerName).attr("type", mixerName)
        mixer.leaf("CustomDeviceName", "Mixer")
        mixer.leaf("IsMaximized", "true")
        mixer.add(param("IsActive", "1.0"))
        mixer.add(param("Panning", String(format: "%g", t.pan)))
        mixer.add(param("Volume", String(format: "%g", t.volume)))
        mixer.add(param("PostPanning", "0.5"))
        mixer.add(param("PostVolume", "1.0"))
        mixer.leaf("SmoothParameterChanges", "true")
        return el
    }

    private static func patternElement(_ p: RNPattern) -> XML {
        let el = XML("Pattern")
        el.leaf("NumberOfLines", String(p.numberOfLines))
        let tracksEl = el.element("Tracks")
        for (i, pt) in p.tracks.enumerated() {
            // Element name must match the song track kind at the same index.
            tracksEl.add(patternTrackElement(pt, kind: kindForPatternTrack(index: i, in: p)))
        }
        return el
    }

    // Pattern tracks are positional. `pattern.trackKinds` (set by the converter,
    // parallel to `pattern.tracks`) tells us which element name to emit.
    private static func kindForPatternTrack(index: Int, in pattern: RNPattern) -> String {
        guard index < pattern.trackKinds.count else { return "PatternTrack" }
        switch pattern.trackKinds[index] {
        case .master: return "PatternMasterTrack"
        case .send: return "PatternSendTrack"
        case .regular: return "PatternTrack"
        }
    }

    private static func patternTrackElement(_ pt: RNPatternTrack, kind: String) -> XML {
        let el = XML(kind).attr("type", kind)
        el.leaf("SelectedPresetName", "Init")
        el.leaf("SelectedPresetLibrary", "")
        el.leaf("SelectedPresetIsModified", "true")
        // Only regular tracks carry note/effect lines; master/send tracks have
        // none — matching Renoise's own pattern-track structure.
        if kind == "PatternTrack" {
            let lines = el.element("Lines")
            for line in pt.lines where !line.noteColumns.isEmpty || !line.effectColumns.isEmpty {
                let lineEl = lines.element("Line").attr("index", String(line.index))
                if !line.noteColumns.isEmpty {
                    let ncs = lineEl.element("NoteColumns").attr("type", "PatternLineNoteColumnList")
                    for col in line.noteColumns {
                        let nc = ncs.element("NoteColumn")
                        if let n = col.note { nc.leaf("Note", n) }
                        if let i = col.instrument { nc.leaf("Instrument", i) }
                        if let v = col.volume { nc.leaf("Volume", v) }
                        if let p = col.panning { nc.leaf("Panning", p) }
                        if let d = col.delay { nc.leaf("Delay", d) }
                    }
                }
                if !line.effectColumns.isEmpty {
                    let ecs = lineEl.element("EffectColumns").attr("type", "PatternLineEffectColumnList")
                    for ec in line.effectColumns {
                        let e = ecs.element("EffectColumn")
                        if let v = ec.value { e.leaf("Value", v) }
                        if let n = ec.number { e.leaf("Number", n) }
                    }
                }
            }
        }
        el.leaf("AliasPatternIndex", "-1")
        el.leaf("ColorEnabled", "false")
        el.leaf("Color", "0,0,0")
        return el
    }
}

