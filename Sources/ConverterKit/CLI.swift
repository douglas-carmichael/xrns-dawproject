import Foundation

// xrnsdaw — converter between Renoise (.xrns), DAWproject (.dawproject) and
// Standard MIDI File (.mid) songs, in any direction.
//
//   xrnsdaw <input> [-o <output>] [--to xrns|dawproject|midi] [--lpb N] [-v]
//
// All three formats translate through one neutral IR, so any source can target
// any other. The target is taken from --to, else the -o extension, else a
// sensible default for the source. The work lives here (not the executable) so
// it can be unit tested.

enum Format {
    case xrns, dawproject, midi          // read + write
    case polyend                         // Polyend Tracker project: read + write (a folder)
    case module                          // any libxmp-supported tracker module: import-only

    /// Source format from an input extension. Anything that isn't one of the
    /// round-trip formats is treated as a tracker module — libxmp detects the
    /// exact format (MOD/S3M/XM/IT/STM/669/DBM/MED and ~50 more) by content, so
    /// the extension need not be known ahead of time. Polyend projects are
    /// folders and detected separately (see `polyendSource`).
    init(inputExtension ext: String) {
        switch ext.lowercased() {
        case "xrns": self = .xrns
        case "dawproject": self = .dawproject
        case "mid", "midi": self = .midi
        default: self = .module
        }
    }

    /// Writable target from an extension (used for -o and --to) — only the
    /// file-based formats this tool can emit. Unknown extensions return nil.
    init?(writableExtension ext: String) {
        switch ext.lowercased() {
        case "xrns": self = .xrns
        case "dawproject": self = .dawproject
        case "mid", "midi": self = .midi
        default: return nil
        }
    }

    init?(name: String) {
        switch name.lowercased() {
        case "xrns", "renoise": self = .xrns
        case "dawproject", "daw", "dp": self = .dawproject
        case "mid", "midi": self = .midi
        case "polyend", "tracker", "poly": self = .polyend
        default: return nil
        }
    }

    var ext: String {
        switch self {
        case .xrns: return "xrns"; case .dawproject: return "dawproject"
        case .midi: return "mid"; case .polyend: return "polyend"; case .module: return "module"
        }
    }

    var label: String {
        switch self {
        case .xrns: return "Renoise"; case .dawproject: return "DAWproject"
        case .midi: return "MIDI"; case .polyend: return "Polyend Tracker"; case .module: return "tracker module"
        }
    }

    /// Legacy tracker modules can be read but not written.
    var importOnly: Bool { self == .module }

    /// Polyend projects are folders (read/written as a directory tree), not files.
    var isFolder: Bool { self == .polyend }

    /// Default target when the user gives neither --to nor an -o extension.
    var defaultTarget: Format { (self == .dawproject || self == .polyend) ? .xrns : .dawproject }
}

struct Options {
    var input: URL
    var output: URL?
    var target: Format?
    var linesPerBeat: Int?   // nil = derive from tempo (when target is .xrns)
    var layout: TrackLayout? // nil = default per target (xrns → channel, else instrument)
    var verbose = false
}

let toolVersion = "1.2.0"

let usage = """
xrnsdaw — convert between Renoise (.xrns), DAWproject (.dawproject), MIDI (.mid)
and Polyend Tracker projects, and import ~50 tracker module formats.

USAGE:
  xrnsdaw <input> [options]

OPTIONS:
  -o, --output <path>   Output file (or folder, for a Polyend target)
      --to <format>     Target: xrns | dawproject | midi | polyend (experimental)
      --lpb <n>         Lines/steps-per-beat grid (.xrns and Polyend targets)
      --layout <mode>   Module track layout: channel | instrument
  -v, --verbose         Print a conversion summary
      --verify          Diff the conversion's volume envelope against libxmp's
                        own playback (any format) — no output file written
  -h, --help            Show this help
      --version         Show the version

NOTE: Polyend Tracker export is experimental — quantised, monophonic per track,
      and not yet tested on hardware.
"""

func parseArguments(_ args: [String]) throws -> Options {
    var input: URL?
    var output: URL?
    var target: Format?
    var lpb: Int?
    var layout: TrackLayout?
    var verbose = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output":
            i += 1
            guard i < args.count else { throw ConvertError.usage("missing value for \(a)") }
            output = URL(fileURLWithPath: args[i])
        case "--to":
            i += 1
            guard i < args.count else { throw ConvertError.usage("missing value for --to") }
            guard let f = Format(name: args[i]) else {
                throw ConvertError.usage("--to must be 'xrns', 'dawproject' or 'midi'")
            }
            target = f
        case "--lpb":
            i += 1
            guard i < args.count, let n = Int(args[i]), n >= 1, n <= 32 else {
                throw ConvertError.usage("--lpb must be an integer 1...32")
            }
            lpb = n
        case "--layout":
            i += 1
            guard i < args.count else { throw ConvertError.usage("missing value for --layout") }
            switch args[i].lowercased() {
            case "channel": layout = .channel
            case "instrument": layout = .instrument
            default: throw ConvertError.usage("--layout must be 'channel' or 'instrument'")
            }
        case "-v", "--verbose":
            verbose = true
        default:
            if a.hasPrefix("-") { throw ConvertError.usage("unknown option: \(a)") }
            guard input == nil else { throw ConvertError.usage("unexpected extra argument: \(a)") }
            input = URL(fileURLWithPath: a)
        }
        i += 1
    }

    guard let input else { throw ConvertError.usage("no input file given\n\n\(usage)") }
    return Options(input: input, output: output, target: target, linesPerBeat: lpb, layout: layout, verbose: verbose)
}

// MARK: format ⇄ IR

/// Make an instrument/sample name safe for a ZIP path component inside the
/// `SampleData/Instrument{NN} (name)` convention (drop path separators / control
/// characters, collapse whitespace, cap length).
private func sanitizeRenoiseName(_ s: String) -> String {
    // Must match Renoise's own sample-path sanitisation, or Renoise looks for the
    // embedded audio at a path that doesn't exist and crashes on a declared-but-
    // missing sample. Renoise replaces the cross-platform-illegal set
    // < > : " / \ | ? * (and control characters) with '_'.
    let illegal: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
    let cleaned = String(s.map { ch -> Character in
        if illegal.contains(ch) { return "_" }
        if let v = ch.unicodeScalars.first?.value, v < 0x20 { return "_" }
        return ch
    }).trimmingCharacters(in: .whitespaces)
    let capped = cleaned.count > 60 ? String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) : cleaned
    return capped.isEmpty ? "Sample" : capped
}

/// Pack a `RenoiseSong` into `.xrns` container bytes: Song.xml plus each
/// instrument's sample audio embedded where Renoise locates it by folder
/// convention (`SampleData/Instrument{NN} (name)/Sample00 (name).{ext}`).
private func packRenoiseXrns(_ renoise: RenoiseSong) -> Data {
    var entries: [(name: String, data: Data)] = [("Song.xml", Data(RenoiseWriter.write(renoise).utf8))]
    for (i, inst) in renoise.instruments.enumerated() {
        let dir = "SampleData/Instrument\(String(format: "%02d", i)) (\(sanitizeRenoiseName(inst.name)))"
        // One audio file per sample — a key-mapped instrument (drum kit) embeds
        // several (Sample00, Sample01, …) where Renoise locates them by index.
        for (j, s) in inst.samples.enumerated() {
            entries.append(("\(dir)/Sample\(String(format: "%02d", j)) (\(sanitizeRenoiseName(s.name))).\(s.audioExt)", s.audio))
        }
    }
    return Zip.create(entries: entries)
}

/// Count pitched note-ons across a Renoise song's pattern pool (for the verbose
/// summary on the direct tracker→Renoise path).
private func countNoteOns(_ renoise: RenoiseSong) -> Int {
    var n = 0
    for p in renoise.patterns {
        for t in p.tracks {
            for line in t.lines {
                for col in line.noteColumns where col.note != nil && col.note != "OFF" { n += 1 }
            }
        }
    }
    return n
}

/// Decode each Renoise instrument's embedded sample (FLAC or WAV, located by the
/// `SampleData/Instrument{NN} (...)` folder convention) into the IR instrument
/// table, so samples — mono or stereo — flow out of a .xrns. A nil sample is an
/// empty slot; the array is indexed by Renoise instrument slot (what notes
/// reference), so gaps are preserved.
private func renoiseSamples(archive data: Data, instruments: [RNInstrument]) -> [IRInstrument] {
    guard !instruments.isEmpty else { return [] }
    let names = Zip.entryNames(inArchive: data)
    return instruments.enumerated().map { i, inst in
        guard let meta = inst.sample else { return IRInstrument(name: inst.name, sample: nil) }
        let prefix = "SampleData/Instrument\(String(format: "%02d", i)) "
        guard let entry = names.first(where: { $0.hasPrefix(prefix) && ($0.hasSuffix(".flac") || $0.hasSuffix(".wav")) }),
              let bytes = try? Zip.read(entry: entry, fromArchive: data) else {
            return IRInstrument(name: inst.name, sample: nil)
        }
        let decoded: (pcm: [Int16], channels: Int, sampleRate: Int)? =
            entry.hasSuffix(".flac") ? Flac.decode(bytes).map { ($0.pcm, $0.channels, $0.sampleRate) }
                                     : Wav.decode(bytes)
        guard let d = decoded, !d.pcm.isEmpty else { return IRInstrument(name: inst.name, sample: nil) }
        let looped = meta.loopMode != "Off" && meta.loopEnd > meta.loopStart
        let loopType = ["Forward": 0, "PingPong": 1, "Backward": 2][meta.loopMode] ?? 0
        let sample = ExtractedSample(name: meta.name, comment: nil, pcm: d.pcm,
                                     sampleRate: d.sampleRate, channels: d.channels,
                                     rootKey: meta.baseNote + 12,   // Renoise note (C-4=48) → MIDI 60
                                     loopStart: looped ? meta.loopStart : 0,
                                     loopEnd: looped ? meta.loopEnd : 0,
                                     loopType: loopType, newNoteAction: meta.newNoteAction)
        return IRInstrument(name: inst.name, sample: sample)
    }
}

private func readIR(_ format: Format, _ data: Data, path: String?, layout: TrackLayout) throws -> IRSong {
    var stats = ConvertStats()
    switch format {
    case .xrns:
        let song = try RenoiseReader.read(songXML: Zip.read(entry: "Song.xml", fromArchive: data))
        var ir = ToIR.fromRenoise(song, stats: &stats)
        ir.instruments = renoiseSamples(archive: data, instruments: song.instruments)
        // Also expose the decoded audio as reference samples for the DAWproject
        // writer (which embeds `extractedSamples`).
        ir.extractedSamples = ir.instruments.compactMap { $0.sample }
        return ir
    case .dawproject:
        let project = try Zip.read(entry: "project.xml", fromArchive: data)
        let metadata = try? Zip.read(entry: "metadata.xml", fromArchive: data)
        return try DawProjectReader.read(project: project, metadata: metadata)
    case .midi:
        return try Smf.read(data)
    case .module:
        return Tracker.toIR(try Xmp.read(data, path: path), layout: layout)
    case .polyend:
        preconditionFailure("Polyend source is read by PolyendSong.read (folder I/O), not readIR")
    }
}

private func writeIR(_ format: Format, _ song: IRSong, lpb: Int?, stats: inout ConvertStats) -> Data {
    stats.tracks = song.tracks.count
    stats.notes = song.tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
    switch format {
    case .xrns:
        let renoise = ToRenoise.fromIR(song, linesPerBeat: lpb, stats: &stats)
        return packRenoiseXrns(renoise)
    case .dawproject:
        stats.patternsOrClips = song.tracks.reduce(0) { $0 + $1.clips.filter { !$0.notes.isEmpty }.count }
        let (projectXML, metadataXML, files) = DawProjectWriter.write(song)
        var entries: [(name: String, data: Data)] = [("project.xml", Data(projectXML.utf8)),
                                                      ("metadata.xml", Data(metadataXML.utf8))]
        entries += files
        return Zip.create(entries: entries)
    case .midi:
        return Smf.write(song)
    case .module:
        preconditionFailure("import-only target should have been rejected before writeIR")
    case .polyend:
        preconditionFailure("Polyend target is written by PolyendSong.write (folder I/O), not writeIR")
    }
}

/// Detect a Polyend Tracker project input: a directory containing `project.mt`,
/// or a path to a `project.mt` file. Returns the project folder, else nil.
private func polyendFolder(_ input: URL) -> URL? {
    let fm = FileManager.default
    if input.lastPathComponent == "project.mt", fm.fileExists(atPath: input.path) {
        return input.deletingLastPathComponent()
    }
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: input.path, isDirectory: &isDir), isDir.boolValue,
       fm.fileExists(atPath: input.appendingPathComponent("project.mt").path) {
        return input
    }
    return nil
}

private func convert(_ opts: Options) throws {
    guard FileManager.default.fileExists(atPath: opts.input.path) else {
        throw ConvertError.io("input not found: \(opts.input.path)")
    }
    let polyendIn = polyendFolder(opts.input)
    let source = polyendIn != nil ? .polyend : Format(inputExtension: opts.input.pathExtension)
    let target = opts.target
        ?? opts.output.flatMap { Format(writableExtension: $0.pathExtension) }
        ?? source.defaultTarget
    guard !target.importOnly else {
        throw ConvertError.usage("export to \(target.label) is not supported — legacy tracker formats are import-only")
    }
    guard target != source else {
        throw ConvertError.usage("source and target are both \(source.label); nothing to convert")
    }

    // Output: a folder for a Polyend target, else a file with the target extension.
    let output = opts.output ?? (target.isFolder
        ? opts.input.deletingPathExtension()
        : opts.input.deletingPathExtension().appendingPathExtension(target.ext))

    // Default legacy-module layout per target: tracker-style targets (.xrns,
    // .polyend) keep the faithful per-channel layout; re-orchestration targets
    // default to one track per instrument. --layout overrides either way.
    let layout = opts.layout ?? ((target == .xrns || target == .polyend) ? .channel : .instrument)
    // Polyend step grid (steps per beat); --lpb overrides the 16th-note default.
    let stepsPerBeat = opts.linesPerBeat ?? PolyendSong.defaultStepsPerBeat

    var stats = ConvertStats()
    var tempoMapPoints = 0

    // Tracker module → Renoise, channel layout, no explicit grid: use the direct
    // pattern-pooled path so the result matches Renoise's own module import (full
    // pattern pool + sequence, native line counts, cell-for-cell). An explicit
    // --lpb, the instrument layout, or any other target falls through to the IR.
    if source == .module, target == .xrns, layout == .channel, opts.linesPerBeat == nil {
        let renoise = TrackerRenoise.convert(try Xmp.read(try Data(contentsOf: opts.input), path: opts.input.path))
        stats.tracks = renoise.tracks.count
        stats.patternsOrClips = renoise.patterns.count
        stats.linesPerBeat = renoise.linesPerBeat
        stats.notes = countNoteOns(renoise)
        try packRenoiseXrns(renoise).write(to: output)
    } else {
        // Source → IR
        let song: IRSong
        if let folder = polyendIn {
            song = try PolyendSong.read(folder: folder, stepsPerBeat: stepsPerBeat)
        } else {
            song = try readIR(source, try Data(contentsOf: opts.input), path: opts.input.path, layout: layout)
        }
        tempoMapPoints = song.tempoMap.count

        // IR → target
        if target == .polyend {
            stats.tracks = song.tracks.count
            stats.notes = song.tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
            stats.droppedNotes = try PolyendSong.write(song, to: output, stepsPerBeat: stepsPerBeat)
        } else {
            try writeIR(target, song, lpb: opts.linesPerBeat, stats: &stats).write(to: output)
        }
    }
    print("Wrote \(output.lastPathComponent)  (\(source.label) → \(target.label))")

    if opts.verbose {
        print("  tracks:   \(stats.tracks)")
        print("  notes:    \(stats.notes)")
        if source == .module {
            print("  layout:   \(layout == .channel ? "channel (one track per tracker channel)" : "instrument (one track per sound)")")
        }
        if source == .polyend || target == .polyend {
            print("  grid:     \(stepsPerBeat) steps/beat")
        }
        switch target {
        case .xrns:
            print("  patterns: \(stats.patternsOrClips)")
            let note = opts.linesPerBeat == nil ? " (derived from tempo)" : ""
            print("  lpb:      \(stats.linesPerBeat)\(note)")
        case .dawproject:
            print("  clips:    \(stats.patternsOrClips)")
        case .midi, .polyend, .module:
            break
        }
        if tempoMapPoints > 0 { print("  tempo map: \(tempoMapPoints) points") }
        if stats.droppedNotes > 0 {
            let why = target == .polyend ? "overlap on monophonic Polyend tracks" : "exceeded 12-column polyphony"
            print("  dropped:  \(stats.droppedNotes) notes (\(why))")
        }
    }
}

/// Entry point used by the executable. Returns a process exit code.
public func runCLI(_ args: [String]) -> Int32 {
    if args.contains("-h") || args.contains("--help") {
        print(usage)
        return 0
    }
    if args.contains("--version") {
        print("xrnsdaw \(toolVersion)")
        return 0
    }
    if args.contains("--verify") {
        let paths = args.filter { !$0.hasPrefix("-") }
        guard let path = paths.last else {
            FileHandle.standardError.write(Data("error: --verify needs a module path\n".utf8)); return 1
        }
        do { try Verify.run(path); return 0 }
        catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); return 1 }
    }
    do {
        try convert(try parseArguments(args))
        return 0
    } catch let error as ConvertError {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}
