import Foundation

// Bridges a Polyend Tracker project (a *folder*) to and from the shared IR, so a
// project can convert to Renoise/DAWproject/MIDI and back. EXPERIMENTAL — the
// note/step semantics below are validated against the factory SD card
// (Tracker_SD_1.7), but the device cannot be tested here, and the export
// direction makes lossy choices (see below).
//
// Folder layout (verified against factory content):
//   project.mt                       song: tempo, 255-slot playlist, track names
//   patterns/pattern_NN.mtp          1-based; playlist value v selects pattern_v
//   instruments/instrument_NN.mti    slot NN == step.instrument + 1 (sparse)
//   samples/instrNN.wav              16-bit audio for instrument NN, matched by number
//
// Notes: step.note is MIDI (60 = middle C, matching the IR); per-step velocity
// rides in the Volume/Velocity FX (PatternFX index 18, 0..100). Polyend tracks
// are monophonic. The step grid (steps/beat) is not stored in the files; we
// default to 4 (a 16th-note grid == Renoise LPB 4) and let --lpb override it.
//
// Export is lossy: notes quantize to the step grid; overlapping notes on a track
// are dropped (monophonic) and counted; note durations become note-off (cut)
// steps where a free step exists before the next note.
enum PolyendSong {
    static let defaultStepsPerBeat = 4
    static let maxTracks = 16
    static let maxInstruments = 48
    private static let volumeFX = 18   // PatternFX "Volume/Velocity"

    // MARK: - Source: folder → IR

    static func read(folder: URL, stepsPerBeat: Int = defaultStepsPerBeat) throws -> IRSong {
        let fm = FileManager.default
        let mt = folder.appendingPathComponent("project.mt")
        guard fm.fileExists(atPath: mt.path) else {
            throw PolyendError.fileTooShort("no project.mt in \(folder.lastPathComponent)")
        }
        let project = try PolyendProject.parse(try Data(contentsOf: mt))

        var patterns: [Int: PatternData] = [:]
        let patDir = folder.appendingPathComponent("patterns")
        if let names = try? fm.contentsOfDirectory(atPath: patDir.path) {
            for name in names where name.lowercased().hasSuffix(".mtp") {
                guard let n = firstNumber(in: name),
                      let data = try? Data(contentsOf: patDir.appendingPathComponent(name)),
                      let pat = try? PolyendPattern.parse(data) else { continue }
                patterns[n] = pat
            }
        }

        let instruments = readInstruments(folder: folder)
        return toIR(project: project, patterns: patterns, instruments: instruments, stepsPerBeat: stepsPerBeat)
    }

    /// Pure conversion (no I/O) — patterns keyed by 1-based number, instruments
    /// indexed by 0-based slot. Exposed for testing.
    static func toIR(project: ProjectData, patterns: [Int: PatternData],
                     instruments: [IRInstrument], stepsPerBeat: Int) -> IRSong {
        var song = IRSong()
        song.tempo = max(1, Double(project.values.globalTempo))
        if !project.projectName.isEmpty { song.title = project.projectName }
        song.gridLinesPerBeat = stepsPerBeat
        let spb = Double(max(1, stepsPerBeat))

        let used = project.song.playlist.filter { $0 != 0 }.compactMap { patterns[$0] }
        let trackCount = min(maxTracks, used.map { $0.tracks.count }.max() ?? 0)
        guard trackCount > 0 else { song.instruments = instruments; return song }

        var tracks: [IRTrack] = (0 ..< trackCount).map { i in
            let names = project.values.trackNames
            let nm = (i < names.count && !names[i].isEmpty) ? names[i] : "Track \(i + 1)"
            return IRTrack(role: .regular, name: nm)
        }

        var maxInstRef = -1
        var beat = 0.0
        for entry in project.song.playlist where entry != 0 {
            guard let pat = patterns[entry] else { continue }
            let patSteps = pat.tracks.map { $0.length + 1 }.max() ?? 0
            let patBeats = Double(patSteps) / spb
            for ti in 0 ..< trackCount where ti < pat.tracks.count {
                let notes = stepsToNotes(pat.tracks[ti], stepsPerBeat: stepsPerBeat)
                for n in notes { maxInstRef = max(maxInstRef, n.instrument ?? -1) }
                if !notes.isEmpty {
                    tracks[ti].clips.append(IRClip(start: beat, length: patBeats, name: nil, notes: notes))
                }
            }
            beat += patBeats
        }
        song.tracks = tracks

        // Size the instrument table to cover every referenced slot (gaps = empty).
        var insts = instruments
        if maxInstRef + 1 > insts.count {
            insts += (insts.count ... maxInstRef).map { _ in IRInstrument(name: "", sample: nil) }
        }
        song.instruments = insts
        return song
    }

    private static func stepsToNotes(_ track: TrackData, stepsPerBeat: Int) -> [IRNote] {
        let spb = Double(max(1, stepsPerBeat))
        let active = min(track.length + 1, track.steps.count)
        var notes: [IRNote] = []
        var i = 0
        while i < active {
            let step = track.steps[i]
            guard step.note >= 0 else { i += 1; continue }   // -1 empty, <-1 note-off
            // Note runs until the next non-empty step (a new note or a note-off).
            var j = i + 1
            while j < active && track.steps[j].note == -1 { j += 1 }
            notes.append(IRNote(start: Double(i) / spb, length: Double(j - i) / spb,
                                key: min(127, max(0, step.note)), velocity: velocity(step),
                                instrument: step.instrument))
            // Consume a terminating note-off; leave a following note-on for the loop.
            i = (j < active && track.steps[j].note < 0) ? j + 1 : j
        }
        return notes
    }

    private static func velocity(_ step: StepData) -> Double {
        for fx in step.fx where fx.type.index == volumeFX {
            return Double(max(0, min(100, fx.value))) / 100.0
        }
        return 1.0
    }

    static func readInstruments(folder: URL) -> [IRInstrument] {
        let fm = FileManager.default
        let instDir = folder.appendingPathComponent("instruments")
        let sampDir = folder.appendingPathComponent("samples")
        guard let names = try? fm.contentsOfDirectory(atPath: instDir.path) else { return [] }

        var bySlot: [Int: IRInstrument] = [:]
        var maxSlot = -1
        for name in names where name.lowercased().hasSuffix(".mti") || name.lowercased().hasSuffix(".pti") {
            guard let fileNo = firstNumber(in: name), fileNo >= 1,
                  let data = try? Data(contentsOf: instDir.appendingPathComponent(name)),
                  let inst = try? PolyendInstrument.parse(data) else { continue }
            let slot = fileNo - 1
            let displayName = inst.sample.filename.isEmpty ? "Instrument \(fileNo)" : inst.sample.filename

            var sample: ExtractedSample?
            if !inst.pcm.isEmpty {                                   // embedded (.pti)
                sample = ExtractedSample(name: displayName, comment: nil, pcm: inst.pcm,
                                         sampleRate: InstrumentConstants.sampleRate,
                                         channels: max(1, inst.sample.channels), rootKey: 60)
            } else if let wav = readWav(sampleFor: fileNo, in: sampDir) {  // external samples/instrNN.wav
                sample = ExtractedSample(name: displayName, comment: nil, pcm: wav.pcm,
                                         sampleRate: wav.sampleRate, channels: wav.channels, rootKey: 60)
            }
            bySlot[slot] = IRInstrument(name: displayName, sample: sample)
            maxSlot = max(maxSlot, slot)
        }
        guard maxSlot >= 0 else { return [] }
        return (0 ... maxSlot).map { bySlot[$0] ?? IRInstrument(name: "", sample: nil) }
    }

    // MARK: - Destination: IR → folder

    static func write(_ song: IRSong, to folder: URL, stepsPerBeat: Int = defaultStepsPerBeat) throws -> Int {
        let result = fromIR(song, stepsPerBeat: stepsPerBeat)
        let fm = FileManager.default
        let patDir = folder.appendingPathComponent("patterns")
        try fm.createDirectory(at: patDir, withIntermediateDirectories: true)

        try PolyendProject.write(result.project).write(to: folder.appendingPathComponent("project.mt"))
        for p in result.patterns {
            try PolyendPattern.write(p.pattern)
                .write(to: patDir.appendingPathComponent(String(format: "pattern_%02d.mtp", p.num)))
        }
        let meta = PolyendMetadata.create(patternNames: result.patterns.map { "Pattern \($0.num)" })
        try PolyendMetadata.write(meta).write(to: patDir.appendingPathComponent("patternsMetadata"))

        if !result.instruments.isEmpty {
            let instDir = folder.appendingPathComponent("instruments")
            let sampDir = folder.appendingPathComponent("samples")
            try fm.createDirectory(at: instDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: sampDir, withIntermediateDirectories: true)
            for entry in result.instruments {
                let no = entry.slot + 1
                try PolyendInstrument.write(entry.inst)
                    .write(to: instDir.appendingPathComponent(String(format: "instrument_%02d.mti", no)))
                if let s = entry.sample {
                    try Wav.encode(s.pcm, sampleRate: s.sampleRate, channels: max(1, s.channels))
                        .write(to: sampDir.appendingPathComponent(String(format: "instr%02d.wav", no)))
                }
            }
        }
        return result.dropped
    }

    struct ExportInstrument { var slot: Int; var inst: InstrumentData; var sample: ExtractedSample? }
    struct ExportResult {
        var project: ProjectData
        var patterns: [(num: Int, pattern: PatternData)]
        var instruments: [ExportInstrument]
        var dropped: Int
    }

    /// Pure conversion (no I/O). Exposed for testing.
    static func fromIR(_ song: IRSong, stepsPerBeat: Int) -> ExportResult {
        let spb = Double(max(1, stepsPerBeat))
        let regular = song.regularTracks
        let trackCount = min(maxTracks, max(1, regular.count))

        let lengthSteps = max(1, Int((song.lengthInBeats * spb).rounded(.up)))
        let patternCount = max(1, (lengthSteps + 127) / 128)
        var pats = (0 ..< patternCount).map { _ in PolyendPattern.create(numTracks: trackCount, numSteps: 128) }

        // Pass 1: place every note-on (monophonic — a step already taken on this
        // track drops the colliding note). Record end steps for pass 2.
        var dropped = 0
        var ends: [(patIdx: Int, ti: Int, stepIn: Int, endAbs: Int)] = []
        for (ti, track) in regular.enumerated() where ti < trackCount {
            for note in track.absoluteNotes {
                let stepAbs = Int((note.start * spb).rounded())
                guard stepAbs >= 0 else { continue }
                let patIdx = stepAbs / 128, stepIn = stepAbs % 128
                guard patIdx < patternCount else { continue }
                guard pats[patIdx].tracks[ti].steps[stepIn].note == -1 else { dropped += 1; continue }

                let slot = max(0, min(maxInstruments - 1, note.instrument ?? ti))
                var fx = [FX(type: PolyendFX.none, value: 0), FX(type: PolyendFX.none, value: 0)]
                let vel = Int((note.velocity * 100).rounded())
                if vel < 100 { fx[0] = FX(type: PolyendFX.table[volumeFX], value: max(0, min(100, vel))) }
                pats[patIdx].tracks[ti].steps[stepIn] =
                    StepData(note: min(127, max(0, note.key)), instrument: slot, fx: fx)
                ends.append((patIdx, ti, stepIn, stepAbs + max(1, Int((note.length * spb).rounded()))))
            }
        }
        // Pass 2: durations → a note-off (cut) at each end step, but only where the
        // step is still empty (a following note-on already terminates the note, and
        // must not be overwritten — that was the bug if done inline in pass 1).
        for e in ends where e.endAbs / 128 == e.patIdx {
            let endIn = e.endAbs % 128
            if endIn > e.stepIn, pats[e.patIdx].tracks[e.ti].steps[endIn].note == -1 {
                pats[e.patIdx].tracks[e.ti].steps[endIn].note = -3
            }
        }

        var project = PolyendProject.create(name: song.title ?? "Converted")
        project.values.globalTempo = Float(song.tempo)
        var playlist = [Int](repeating: 0, count: ProjectConstants.playlistSize)
        for i in 0 ..< min(patternCount, ProjectConstants.playlistSize) { playlist[i] = i + 1 }
        project.song.playlist = playlist
        for ti in 0 ..< trackCount where ti < regular.count && ti < project.values.trackNames.count {
            project.values.trackNames[ti] = regular[ti].name
        }

        var instruments: [ExportInstrument] = []
        for (i, irInst) in song.instruments.enumerated() where i < maxInstruments {
            guard let s = irInst.sample, !s.pcm.isEmpty else { continue }
            let ch = max(1, s.channels)
            var inst = PolyendInstrument.create(name: shortName(irInst.name), channels: ch)
            inst.sample.length = s.pcm.count / ch
            instruments.append(ExportInstrument(slot: i, inst: inst, sample: s))
        }

        let patternsOut = (0 ..< patternCount).map { (num: $0 + 1, pattern: pats[$0]) }
        return ExportResult(project: project, patterns: patternsOut, instruments: instruments, dropped: dropped)
    }

    // MARK: - Helpers

    /// First contiguous run of digits in a filename (pattern_01 → 1, instr14 → 14).
    private static func firstNumber(in name: String) -> Int? {
        var digits = ""
        for ch in name {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    private static func shortName(_ s: String) -> String { String(s.prefix(32)) }

    private static func readWav(sampleFor fileNo: Int, in dir: URL) -> (pcm: [Int16], channels: Int, sampleRate: Int)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names where name.lowercased().hasSuffix(".wav") {
            if firstNumber(in: name) == fileNo,
               let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
               let wav = parseWav(data) {
                return wav
            }
        }
        return nil
    }

    /// Minimal 16-bit PCM WAV reader (RIFF/fmt/data). Returns nil for non-16-bit.
    static func parseWav(_ data: Data) -> (pcm: [Int16], channels: Int, sampleRate: Int)? {
        var r = PolyendReader(data)
        guard r.count >= 44, r.ascii(4) == "RIFF" else { return nil }
        r.skip(4)
        guard r.ascii(4) == "WAVE" else { return nil }

        var channels = 1, sampleRate = 44100, bits = 16
        var pcmBytes: [UInt8] = []
        while r.offset + 8 <= r.count {
            let id = r.ascii(4)
            let size = Int(r.u32())
            if id == "fmt " {
                let start = r.offset
                r.skip(2)                 // audio format
                channels = max(1, r.u16())
                sampleRate = Int(r.u32())
                r.skip(6)                 // byte rate (4) + block align (2)
                bits = r.u16()
                r.offset = start + size + (size & 1)
            } else if id == "data" {
                pcmBytes = r.slice(size)
                break
            } else {
                r.skip(size + (size & 1))
            }
        }
        guard bits == 16, !pcmBytes.isEmpty else { return nil }
        var pcm = [Int16](repeating: 0, count: pcmBytes.count / 2)
        for i in 0 ..< pcm.count {
            pcm[i] = Int16(bitPattern: UInt16(pcmBytes[i * 2]) | (UInt16(pcmBytes[i * 2 + 1]) << 8))
        }
        return (pcm, channels, sampleRate)
    }
}
