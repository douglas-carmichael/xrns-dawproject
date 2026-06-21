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
    var baseNote: Int = 48                 // root key as a Renoise note (C-4 = 48 = MIDI 60)
    var loopMode: String = "Off"           // Off / Forward / Backward / PingPong
    var loopStart: Int = 0
    var loopEnd: Int = 0
    var newNoteAction: String = "NoteOff"  // Cut / NoteOff / None  (NNA)
    var envelope: ADSR? = nil              // volume AHDSR modulation, nil = none
}

/// A Renoise instrument slot. A nil `sample` is an empty placeholder (notes can
/// still reference it); otherwise it holds one playable sample.
struct RNInstrument {
    var name: String
    var sample: RNSample?
}

struct RenoiseSong {
    var docVersion: Int = 67
    var bpm: Double = 120
    var linesPerBeat: Int = 4
    var ticksPerLine: Int = 12
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

        return song
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
        let g = root.element("GlobalSongData")
        g.leaf("BeatsPerMin", String(format: "%g", song.bpm))
        g.leaf("LinesPerBeat", String(song.linesPerBeat))
        g.leaf("TicksPerLine", String(song.ticksPerLine))
        g.leaf("SignatureNumerator", String(song.signatureNumerator))
        g.leaf("SignatureDenominator", String(song.signatureDenominator))
        g.leaf("Octave", "4")
        if let name = song.songName { g.leaf("SongName", name) }
        if let artist = song.artist { g.leaf("Artist", artist) }
        if !song.comments.isEmpty {
            let c = g.element("SongComments")
            for line in song.comments { c.leaf("SongComment", line) }
        }

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
        guard let s = inst.sample else { return el }

        let gen = el.element("SampleGenerator")
        let samples = gen.element("Samples")
        let sm = samples.element("Sample")
        sm.leaf("Name", s.name)
        sm.leaf("Volume", floatString(s.volume))
        sm.leaf("Panning", "0.5")
        sm.leaf("Transpose", String(max(-127, min(127, s.transpose))))
        sm.leaf("Finetune", "0")
        sm.leaf("NewNoteAction", s.newNoteAction)
        sm.leaf("LoopMode", s.loopMode)
        sm.leaf("LoopStart", String(max(0, s.loopStart)))
        sm.leaf("LoopEnd", String(max(0, s.loopEnd)))
        if s.envelope != nil { sm.leaf("ModulationSetIndex", "0") }  // engage the volume envelope
        let map = sm.element("Mapping")
        map.leaf("BaseNote", String(max(0, min(119, s.baseNote))))
        map.leaf("NoteStart", "0")
        map.leaf("NoteEnd", "119")
        map.leaf("MapKeyToPitch", "true")

        // Volume envelope → a Renoise modulation set with a Volume AHDSR device
        // (structure matches Renoise's own factory instruments).
        if let env = s.envelope {
            let set = gen.element("ModulationSets").element("ModulationSet")
            set.leaf("SelectedPresetName", "Init")
            set.leaf("SelectedPresetLibrary", "Bundled Content")
            set.leaf("SelectedPresetIsModified", "true")
            let d = set.element("Devices").element("SampleAhdsrModulationDevice").attr("type", "SampleAhdsrModulationDevice")
            d.leaf("IsMaximized", "true")
            d.leaf("IsSelected", "false")
            d.leaf("SelectedPresetName", "Init")
            d.leaf("SelectedPresetLibrary", "Bundled Content")
            d.leaf("SelectedPresetIsModified", "true")
            d.add(param("IsActive", "1.0"))
            d.leaf("Target", "Volume")
            d.leaf("Operator", "*")
            d.leaf("Bipolar", "false")
            d.leaf("TempoSynced", "false")
            d.add(param("Attack", floatString(env.attack)))
            d.add(param("Hold", floatString(env.hold)))
            d.add(param("Decay", floatString(env.decay)))
            d.add(param("Sustain", floatString(env.sustain)))
            d.add(param("Release", floatString(env.release)))
            set.leaf("Name", "Set 01")
            set.leaf("FilterType", "0")
            set.leaf("FilterBankVersion", "3")
        }
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

        el.leaf("NumberOfVisibleNoteColumns", String(max(1, min(12, t.visibleNoteColumns))))
        el.leaf("NumberOfVisibleEffectColumns", "1")
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
        return el
    }
}

