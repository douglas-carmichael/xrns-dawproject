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
    case module                          // any libxmp-supported tracker module: import-only

    /// Source format from an input extension. Anything that isn't one of the
    /// three round-trip formats is treated as a tracker module — libxmp detects
    /// the exact format (MOD/S3M/XM/IT/STM/669/DBM/MED and ~50 more) by content,
    /// so the extension need not be known ahead of time.
    init(inputExtension ext: String) {
        switch ext.lowercased() {
        case "xrns": self = .xrns
        case "dawproject": self = .dawproject
        case "mid", "midi": self = .midi
        default: self = .module
        }
    }

    /// Writable target from an extension (used for -o and --to) — only the three
    /// formats this tool can emit. Unknown extensions return nil.
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
        default: return nil
        }
    }

    var ext: String {
        switch self {
        case .xrns: return "xrns"; case .dawproject: return "dawproject"
        case .midi: return "mid"; case .module: return "module"
        }
    }

    var label: String {
        switch self {
        case .xrns: return "Renoise"; case .dawproject: return "DAWproject"
        case .midi: return "MIDI"; case .module: return "tracker module"
        }
    }

    /// Legacy tracker modules can be read but not written.
    var importOnly: Bool { self == .module }

    /// Default target when the user gives neither --to nor an -o extension.
    var defaultTarget: Format { self == .dawproject ? .xrns : .dawproject }
}

struct Options {
    var input: URL
    var output: URL?
    var target: Format?
    var linesPerBeat: Int?   // nil = derive from tempo (when target is .xrns)
    var layout: TrackLayout? // nil = default per target (xrns → channel, else instrument)
    var verbose = false
}

let usage = """
xrnsdaw — convert between Renoise (.xrns), DAWproject (.dawproject) and MIDI (.mid),
and import legacy tracker modules (MOD, S3M, XM, IT, STM, 669, DBM, MED + ~50 more).

USAGE:
  xrnsdaw <input> [options]

OPTIONS:
  -o, --output <path>      Output file (its extension can set the target format)
      --to <format>        Target format: "xrns", "dawproject" or "midi"
      --lpb <n>            Lines-per-beat grid when target is .xrns (default: derived from tempo)
      --layout <mode>      Legacy-module track layout: "channel" (faithful — one track per
                           tracker channel, preserves channel effects + stereo) or "instrument"
                           (one track per sound, best for mixing). Default: channel for .xrns,
                           instrument for .dawproject/.mid.
  -v, --verbose            Print a conversion summary
  -h, --help               Show this help

The source format is taken from the input extension; any non-round-trip extension
is treated as a tracker module and identified by content. The target is --to, else
the -o extension, else: xrns/midi/module → dawproject, dawproject → xrns.
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
    let cleaned = String(s.map { ch in
        (ch == "/" || ch == "\\" || ch == ":" || ch.isNewline || ch == "\t") ? "_" : ch
    }).trimmingCharacters(in: .whitespaces)
    let capped = cleaned.count > 60 ? String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) : cleaned
    return capped.isEmpty ? "Sample" : capped
}

private func readIR(_ format: Format, _ data: Data, path: String?, layout: TrackLayout) throws -> IRSong {
    var stats = ConvertStats()
    switch format {
    case .xrns:
        let song = try RenoiseReader.read(songXML: Zip.read(entry: "Song.xml", fromArchive: data))
        return ToIR.fromRenoise(song, stats: &stats)
    case .dawproject:
        let project = try Zip.read(entry: "project.xml", fromArchive: data)
        let metadata = try? Zip.read(entry: "metadata.xml", fromArchive: data)
        return try DawProjectReader.read(project: project, metadata: metadata)
    case .midi:
        return try Smf.read(data)
    case .module:
        return Tracker.toIR(try Xmp.read(data, path: path), layout: layout)
    }
}

private func writeIR(_ format: Format, _ song: IRSong, lpb: Int?, stats: inout ConvertStats) -> Data {
    stats.tracks = song.tracks.count
    stats.notes = song.tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
    switch format {
    case .xrns:
        let renoise = ToRenoise.fromIR(song, linesPerBeat: lpb, stats: &stats)
        var entries: [(name: String, data: Data)] = [("Song.xml", Data(RenoiseWriter.write(renoise).utf8))]
        // Embed each instrument's sample audio where Renoise expects it:
        // SampleData/Instrument{NN decimal} (name)/Sample00 (name).wav
        for (i, inst) in renoise.instruments.enumerated() {
            guard let s = inst.sample else { continue }
            let dir = "SampleData/Instrument\(String(format: "%02d", i)) (\(sanitizeRenoiseName(inst.name)))"
            entries.append(("\(dir)/Sample00 (\(sanitizeRenoiseName(s.name))).wav", s.wav))
        }
        return Zip.create(entries: entries)
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
    }
}

private func convert(_ opts: Options) throws {
    guard FileManager.default.fileExists(atPath: opts.input.path) else {
        throw ConvertError.io("input file not found: \(opts.input.path)")
    }
    let source = Format(inputExtension: opts.input.pathExtension)
    let target = opts.target
        ?? opts.output.flatMap { Format(writableExtension: $0.pathExtension) }
        ?? source.defaultTarget
    guard !target.importOnly else {
        throw ConvertError.usage("export to \(target.label) is not supported — legacy tracker formats are import-only")
    }
    guard target != source else {
        throw ConvertError.usage("source and target are both \(source.label); nothing to convert")
    }
    let output = opts.output ?? opts.input.deletingPathExtension().appendingPathExtension(target.ext)

    // Default legacy-module layout per target: a tracker target (.xrns) keeps the
    // faithful per-channel layout; re-orchestration targets default to one track
    // per instrument. --layout overrides either way.
    let layout = opts.layout ?? (target == .xrns ? .channel : .instrument)

    let inputData = try Data(contentsOf: opts.input)
    let song = try readIR(source, inputData, path: opts.input.path, layout: layout)
    var stats = ConvertStats()
    let outputData = writeIR(target, song, lpb: opts.linesPerBeat, stats: &stats)
    try outputData.write(to: output)
    print("Wrote \(output.lastPathComponent)  (\(source.label) → \(target.label))")

    if opts.verbose {
        print("  tracks:   \(stats.tracks)")
        print("  notes:    \(stats.notes)")
        if source == .module {
            print("  layout:   \(layout == .channel ? "channel (one track per tracker channel)" : "instrument (one track per sound)")")
        }
        switch target {
        case .xrns:
            print("  patterns: \(stats.patternsOrClips)")
            let note = opts.linesPerBeat == nil ? " (derived from tempo)" : ""
            print("  lpb:      \(stats.linesPerBeat)\(note)")
        case .dawproject:
            print("  clips:    \(stats.patternsOrClips)")
        case .midi, .module:
            break
        }
        if !song.tempoMap.isEmpty { print("  tempo map: \(song.tempoMap.count) points") }
        if stats.droppedNotes > 0 {
            print("  dropped:  \(stats.droppedNotes) notes (exceeded 12-column polyphony)")
        }
    }
}

/// Entry point used by the executable. Returns a process exit code.
public func runCLI(_ args: [String]) -> Int32 {
    if args.contains("-h") || args.contains("--help") {
        print(usage)
        return 0
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
