# xrns-dawproject

A small, cross-platform command-line tool that converts, in any direction,
between Renoise songs (`.xrns`), the [DAWproject](https://github.com/bitwig/dawproject)
interchange format (`.dawproject`), and Standard MIDI Files (`.mid`) — and
**imports ~50 legacy tracker module formats** (MOD, S3M, XM, IT, STM, 669, DBM,
MED and many more) so old compositions can be re-orchestrated in a modern DAW.

```
   ┌─ .mod .s3m .xm .it .stm .669 .dbm .med … (~50 module formats, import-only)
   │
   └─▶  Renoise .xrns  ⇄  DAWproject .dawproject  ⇄  MIDI .mid
              (any of the three converts to any other — one shared model)
```

Written in Swift with **no external/system dependencies** — XML parsing,
ZIP/DEFLATE, and MIDI are implemented in-package, and the tracker parser
([libxmp](https://github.com/libxmp/libxmp), MIT) is **vendored and compiled from
source** — so a single `swift build` runs identically on **macOS, Linux and
Windows**. The binary is called `xrnsdaw`.

## Building

The build system is [SwiftPM](https://www.swift.org/package-manager/); the
commands are the same on every platform:

```sh
cd xrns-dawproject
swift build -c release          # → .build/release/xrnsdaw  (xrnsdaw.exe on Windows)
swift test                      # run the unit tests
./.build/release/xrnsdaw --help
```

Install it on your `PATH` with either:

```sh
swift package experimental-install          # installs to ~/.swiftpm/bin
# or just copy it:
cp .build/release/xrnsdaw /usr/local/bin/
```

You only need a [Swift toolchain](https://www.swift.org/install/) (5.9+):

- **macOS** — comes with Xcode / Command Line Tools.
- **Linux** — install via [swiftly](https://www.swift.org/install/linux/) or the swift.org tarball; for a portable binary add `--static-swift-stdlib`.
- **Windows** — `winget install Swift.Toolchain`, then `swift build -c release`.

There is no Xcode-project or Makefile to manage — open `Package.swift` directly
in Xcode if you want an IDE. Continuous integration builds and tests on all three
operating systems (see `.github/workflows/ci.yml`); tagging a commit
`xrnsdaw-v*` publishes prebuilt binaries for each OS to a GitHub Release.

## Usage

```
xrnsdaw <input> [options]

Options:
  -o, --output <path>   Output file (its extension can set the target format)
      --to <format>     Target format: "xrns", "dawproject" or "midi"
      --lpb <n>         Lines-per-beat grid when target is .xrns (default: derived from tempo)
      --layout <mode>   Legacy-module track layout: "channel" or "instrument" (see below).
                        Default: channel for .xrns, instrument for .dawproject/.mid
  -v, --verbose         Print a conversion summary
  -h, --help            Show help
```

The source format is taken from the input extension; the target is `--to`, else
the `-o` extension, else a default (xrns/midi → dawproject, dawproject → xrns):

```sh
xrnsdaw "My Song.xrns"                 # → "My Song.dawproject"
xrnsdaw "My Song.dawproject"           # → "My Song.xrns"
xrnsdaw song.xrns --to midi            # → song.mid
xrnsdaw song.mid -o out.dawproject -v  # MIDI → DAWproject, with summary
xrnsdaw in.dawproject --lpb 16         # force a finer tracker grid on the way back
```

## What gets converted

All formats translate through one neutral model (the IR), so each item below is
carried wherever both the source and target support it.

| Musical data | xrns | dawproject | mid |
|---|:---:|:---:|:---:|
| Tempo + **tempo map** (changes over time) | ✓ (`ZTxx`) | ✓ (`TempoAutomation`) | ✓ (set-tempo) |
| Time signature | ✓ | ✓ | ✓ |
| Tracks (name, colour, volume, pan, mute, solo) | ✓ | ✓ | name only |
| Track roles (regular / master / send) | ✓ | ✓ | — (notes only) |
| Notes (pitch, start, **duration**, velocity) | ✓ | ✓ | ✓ |
| Note commands (delay, cut — see below) | ✓ | n/a | n/a |
| Song title / artist / comment | ✓ | ✓ | title only |
| Pattern order / arrangement | ✓ | ✓ | flattened to one clip/track |

MIDI carries note tracks plus a global tempo map and time signature; it has no
mixer/master/send or clip concepts, so those are dropped when targeting `.mid`.

### Arrangement and pattern order

Renoise is a pattern sequencer: a *pattern pool* plus a *pattern sequence* that
says which pattern plays when. The converter **walks the pattern sequence in
order** and lays one DAWproject **clip per pattern instance** onto the
arrangement timeline at the correct beat offset. A song that plays patterns
`0, 1, 0, 2` becomes four clips in that order on each track's lane — the
arrangement reproduces the song exactly as it plays.

Going the other way, the continuous DAWproject arrangement is quantised onto a
tracker line grid and split into fixed-length Renoise patterns, emitted in order
in the pattern sequence.

### Note durations, pitch and velocity

Trackers don't store note durations directly: a note rings until the next note
or an `OFF` in the same column. The converter reconstructs real durations by
scanning each note column, and reverses the process (emitting `OFF` commands)
when writing Renoise. Overlapping/polyphonic notes are spread across Renoise's
note columns (up to its 12-column limit).

Pitch is anchored at A-4 = MIDI 69, so Renoise `C-4` ↔ MIDI 60. Velocity maps
between Renoise's volume column (`00`–`80` hex) and DAWproject's normalised
`0…1`.

### Renoise note commands (→ DAWproject)

Per-note [Renoise commands](https://tutorials.renoise.com/wiki/Effect_Commands)
are interpreted where DAWproject's note model (time / duration / key / velocity)
can represent them faithfully:

| Command | Source | Effect on the rendered note |
|---|---|---|
| Volume `00`–`80` | volume column | note **velocity** |
| Note delay | delay column (`xx`/256), `Qx` (vol/pan col), `0Qxx` (effect col) | fractional **start** position |
| Note cut | `Cx` (vol/pan col), `0C0y` (effect col) | shortened **duration** |

Continuous-pitch commands — glide `0G`/`Gx`, slides `0U`/`0D`/`Ux`/`Dx`,
arpeggio `0A`, vibrato `0V` — and probability/retrigger have no faithful target
in DAWproject 1.0, so the note is rendered at its **written (target) pitch**
without the (unrepresentable) pitch transition.

The reverse direction **emits** the same commands so sub-line timing survives
the tracker grid rather than being rounded to it:

| DAWproject note feature | Renoise command written |
|---|---|
| Note doesn't start on a line | **delay column** (`xx`/256 of a line) on the note-on |
| Note doesn't end on a line | **delay column** on the `OFF` |
| Note shorter than one line | **note-cut** `Cx` (panning column), x = ticks into the line |
| Velocity | **volume column** `00`–`7F` |

### Deriving lines-per-beat from tempo (→ Renoise)

When writing `.xrns`, the lines-per-beat grid is derived from the song's tempo
so the per-line duration stays near a musically useful target (~62 ms, i.e.
~8 lines/beat at 120 BPM): slower songs get a finer grid, faster songs a coarser
one, snapped to a power of two in `[4, 32]`. Examples: 60 BPM → 16, 120 → 8,
174 → 4. Because the `.xrns` extension is version-stable (Renoise bumps an
internal `doc_version`, not the extension), this holds across Renoise versions.
Override with `--lpb`.

### Do clips and scenes map?

- **Arrangement clips: yes.** Renoise patterns become `Clip` elements on the
  DAWproject **arrangement** timeline (and vice-versa), in pattern-sequence order.
- **Clip-launcher Scenes: no.** DAWproject `Scenes` are the non-linear
  clip-launcher grid (Ableton/Bitwig session view). Renoise has no such concept,
  so `<Scenes>` is left empty on export and ignored on import — only the linear
  arrangement is converted.

## Legacy module import (~50 formats via libxmp)

Legacy tracker modules are **import-only**, and the conversion is tuned for one
goal: making an old composition easy to **re-orchestrate in a modern DAW**.
Modules are parsed by [libxmp](https://github.com/libxmp/libxmp) (vendored), which
covers MOD, S3M, XM, IT, STM, 669, DBM, MED/OctaMED, MTM, OKT, ULT, PTM, GDM, FAR,
DIGI, and ~35 more — the format is detected from the file's content, so the
extension need not be known. Instead of mirroring the tracker's internals, the
output is organised the way a composer thinks:

- **One track per instrument** (not per channel — a channel reuses many
  instruments over time), named from the sample/instrument name.
- **An identification comment on every track**, because tracker sample-name
  slots are notoriously unreliable (often blank, cryptic, or holding greetings /
  credits text). The comment combines the verbatim name, sample facts
  (length, loop), score usage (note range, mono/polyphonic), sample-offset usage
  (a `9xx`/`Oxx`-sliced multi-sound sample is flagged), and a best-guess label —
  *"likely bass / pad / lead / drum kit"* — so you can pick a modern equivalent.
- **Correct octaves**: libxmp normalises every format onto one note scale (its
  "C-4" → MIDI 60) and resolves each instrument's tuning (XM relative-note,
  S3M/IT C5 rate, …), so notes land in the octave the instrument actually sounds at.
- **The original sounds, extracted**: every sample libxmp decodes is encoded with
  its **root key** and **loop** (start/end and type — forward / ping-pong /
  backward) and embedded — as a WAV (DAWproject reference audio) or as **FLAC**
  (Renoise, matching its native format and a fraction of the size). *Where* it
  lands and how it's used depends on the target (below).

The score, tempo map (including mid-song tempo changes), and instrument metadata
are always carried. **Companion files are resolved** when they sit next to the
module on disk: a Startrekker module finds its `.NT`/`.AS`, and its **AM-synth
instruments are rebuilt as playable instruments** — libxmp renders each synth
oscillator to a looped waveform, and its amplitude envelope comes across as a
Renoise volume envelope (below). A Startrekker module whose `.NT` is genuinely
missing still loads its PCM instruments and notes.

### → DAWproject: reference audio

DAWproject 1.0 has no generic sampler device, so the extracted samples can't be
wired to the notes as playable instruments. Instead each is placed as an audio
clip on a dedicated *Extracted Samples* track, laid out **sequentially after the
song** so opening the project doesn't trigger a wall of sound — a reference
palette you drop into your own sampler.

### → Renoise (.xrns): a playable, mixable song

Renoise *is* a sampler, so a module → `.xrns` comes across **fully playable**:

- **Each instrument becomes a real Renoise instrument** with its sample mapped at
  the right **root key**, **loop** (Off / Forward / Backward / PingPong), and
  **New Note Action** (from the module's NNA) — encoded as **FLAC** (Renoise's
  native format) under `SampleData/` where Renoise expects it. Hit play and it
  sounds like the original.
- **Volume envelopes** (XM/IT instrument envelopes, and Startrekker AM amplitude
  envelopes) are reduced to a Renoise volume **AHDSR** modulation device — the
  sustain level is exact and the shape is faithful, though the absolute attack/
  decay/release times are approximate (Renoise's normalised time curve isn't
  documented). Instruments without an envelope (most MOD samples) stay clean.
- **Note commands** survive the trip to the tracker grid: velocity → volume
  column, sub-line timing → note delay / cut, and the **sample-offset** `9xx`/`Oxx`
  → Renoise's `0Sxx` (so sliced/multi-sound samples retrigger at the right point).
- **Master headroom.** The master fader is lowered to fit the peak simultaneous
  voice count, so a dense module doesn't clip on first play — while every track
  stays at unity, leaving the original balance intact.

#### Track layout: `--layout channel` (default) vs `instrument`

A tracker channel time-shares many instruments over time, so there are two useful
ways to lay the song out — pick with `--layout`:

- **`channel`** *(default for `.xrns`)* — one track per **tracker channel**, the
  faithful, tracker-idiom view. Each note carries its own instrument reference,
  channel **panning is preserved** (classic Amiga MODs come in hard-panned L-R-R-L),
  and channel-scoped effect continuity (portamento/slide/vibrato memory) stays on
  one lane. Best for preservation, authentic playback, round-tripping, or editing
  the piece the way its author did.
- **`instrument`** *(default for `.dawproject`/`.mid`)* — one track per **sound**,
  the mixing/re-orchestration view. Every instrument gets its own track, mixer
  channel, and DSP chain, so you can EQ the bass, compress the drums, and reverb
  the lead with native or VST/AU plugins — one *sound* per fader, not a jumble.

Both are fully playable; they differ only in how notes are grouped across tracks.

## Limitations (by design)

- **DAWproject samples aren't playable.** DAWproject 1.0 has no generic
  sampler/instrument device, so on `→ .dawproject` the extracted samples are
  *reference audio*, not wired to the notes (drop them into your own sampler).
  The Renoise target has no such limit — there, samples are playable instruments
  (above). When a `.dawproject` *source* (no embedded sounds) is converted to
  `.xrns`, named-but-empty instrument slots are created for you to fill in.
- **No device/parameter automation.** Only static track volume/pan are carried.
- **Continuous-pitch and per-note pan** are not represented (see above).
- Notes that sustain across a Renoise pattern boundary are closed at the
  boundary (standard tracker→MIDI behaviour).

## Project layout

```
Package.swift                      SwiftPM manifest (CLibxmp + library + executable + tests)
Sources/CLibxmp/                   vendored libxmp (MIT) — the tracker parser, compiled from source
  xmpbridge.c, include/xmpbridge.h   C accessor shim for libxmp's flexible-array members
  include/module.modulemap           exposes xmp.h + the shim to Swift
Sources/ConverterKit/              the Swift library (all conversion logic)
  IR.swift                         format-neutral model (tracks, clips, notes) + pitch maths
  XML.swift                        pure-Swift XML parser + ordered writer
  Zip.swift                        pure-Swift ZIP read/write + CRC-32 + DEFLATE inflate
  RenoiseSong.swift                Renoise model + Song.xml reader & writer
  DawProject.swift                 project.xml / metadata.xml reader & writer (+ sample audio)
  Smf.swift                        Standard MIDI File reader & writer (IR ⇄ .mid)
  Wav.swift                        WAV/PCM encoder with smpl chunk (DAWproject audio)
  Flac.swift                       pure-Swift FLAC encoder (Renoise sample audio)
  Xmp.swift                        libxmp bridge: decoded xmp_module → shared tracker model
  Tracker.swift                    shared tracker model + composer-oriented IR converter
  Converter.swift                  IR ⇄ Renoise, IR ⇄ DAWproject (timing, commands, LPB, tempo map)
  CLI.swift                        argument parsing + orchestration (runCLI)
Sources/XrnsDawProjectCLI/main.swift   thin entry point → ConverterKit.runCLI
Tests/ConverterKitTests/           XCTest suite (pitch, XML, ZIP/inflate, MIDI, tempo, commands, libxmp bridge)
```

Every format is translated through one neutral intermediate representation (IR),
so each reader/writer is independent and the musical semantics live in one place.
All legacy modules are parsed by libxmp and walked into `Tracker.swift`'s shared
model + converter by `Xmp.swift`.

## Verification

`swift test` covers pitch mapping, the XML parser/writer, ZIP round-trips and
DEFLATE inflate (against a real compressed fixture), and conversion round-trips
in both directions. Output is also schema-checked against the official schemas:

```sh
# forward: DAWproject output
xmllint --noout --schema schema/Project.xsd   project.xml
xmllint --noout --schema schema/MetaData.xsd  metadata.xml

# reverse: Renoise output (Renoise 3.5, doc_version 67)
xmllint --noout --schema schema/RenoiseSong67.xsd  Song.xml
```

The bundled `schema/` directory holds the official [DAWproject](https://github.com/bitwig/dawproject)
schemas (`Project.xsd`, `MetaData.xsd`) and Renoise's published song schema
(`RenoiseSong67.xsd` = Renoise 3.5) used for these checks.

Validated against real Renoise demo/tutorial songs from empty templates up to
33 tracks / 5,500+ notes, in both directions. Legacy import is validated against
the official schemas across MOD/S3M/XM/IT/MED/DBM and Startrekker modules — a
real-world MOD/S3M/XM collection converts to schema-valid `.dawproject` and
`.xrns`, and a Startrekker AM module (with its `.NT`) round-trips its synth
voices into playable Renoise instruments.

## Credits

Legacy module parsing is powered by [libxmp](https://github.com/libxmp/libxmp)
by Claudio Matsuoka and Hipolito Carraro Jr, bundled under the MIT license
(`Sources/CLibxmp/LICENSE`).

## License

MIT — see [`LICENSE`](LICENSE). The bundled libxmp is also MIT-licensed.
