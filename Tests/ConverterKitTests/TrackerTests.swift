import XCTest
import Foundation
@testable import ConverterKit

/// End-to-end coverage of the libxmp bridge + tracker→IR converter, driven by a
/// tiny module synthesised in memory (so the test needs no external files and
/// the C bridge — Xmp.read — is exercised on every CI run).
final class TrackerTests: XCTestCase {
    /// Build a tiny but valid 4-channel MOD: title, one named sample with a
    /// short PCM body, a one-row note on instrument 1, and that sample's data.
    private func minimalMod() -> Data {
        var b = [UInt8](repeating: 0, count: 1084)
        for (i, c) in Array("test".utf8).enumerated() { b[i] = c }
        for (i, c) in Array("kick".utf8).enumerated() { b[20 + i] = c }   // sample 1 name
        b[20 + 22] = 0x00; b[20 + 23] = 0x08      // length = 8 words (16 bytes)
        b[20 + 26] = 0x00; b[20 + 27] = 0x00      // repeat start = 0
        b[20 + 28] = 0x00; b[20 + 29] = 0x04      // repeat length = 4 words → loop 0..8
        b[950] = 1                                 // song length
        b[1080] = UInt8(ascii: "M"); b[1081] = UInt8(ascii: ".")
        b[1082] = UInt8(ascii: "K"); b[1083] = UInt8(ascii: ".")

        var pattern = [UInt8](repeating: 0, count: 1024)   // 64 rows × 4 ch × 4 bytes
        let period = 428, sample = 1                       // 428 = C-2 (→ MIDI 60)
        pattern[0] = UInt8((sample & 0xF0) | (period >> 8))
        pattern[1] = UInt8(period & 0xFF)
        pattern[2] = UInt8((sample << 4) & 0xF0)
        b += pattern

        let pcm: [Int8] = [0, 40, 80, 120, 80, 40, 0, -40, -80, -120, -80, -40, 0, 20, -20, 0]
        b += pcm.map { UInt8(bitPattern: $0) }
        return Data(b)
    }

    func testModNotesAndSampleExtraction() throws {
        let song = Tracker.toIR(try Xmp.read(minimalMod()))

        let kick = song.tracks.first { $0.name == "kick" }
        XCTAssertNotNil(kick, "track should be named from the sample")
        let notes = song.tracks.flatMap { $0.clips.flatMap { $0.notes } }
        XCTAssertEqual(notes.first?.key, 60)               // period 428 → C-2 → MIDI 60

        XCTAssertEqual(song.extractedSamples.count, 1)
        XCTAssertEqual(song.extractedSamples.first?.name, "kick")
        XCTAssertFalse(song.extractedSamples.first?.pcm.isEmpty ?? true)
        XCTAssertEqual(song.extractedSamples.first?.loopEnd, 8)   // loop points preserved
    }

    func testModToDawProjectEmbedsSampleAudio() throws {
        let song = Tracker.toIR(try Xmp.read(minimalMod()))
        let (project, _, files) = DawProjectWriter.write(song)

        XCTAssertTrue(files.contains { $0.name.hasSuffix(".wav") }, "a WAV should be embedded")
        XCTAssertTrue(project.contains("Extracted Samples"))
        XCTAssertTrue(project.contains("contentTimeUnit=\"seconds\""))   // audio clip present

        // The embedded WAV is a real RIFF/WAVE file with a loop (smpl) chunk.
        let wav = try XCTUnwrap(files.first { $0.name.hasSuffix(".wav") }?.data)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertNotNil(wav.range(of: Data("smpl".utf8)), "looped sample should carry a smpl chunk")
    }

    func testUnrecognisedDataReportsCleanError() {
        // A non-module blob must surface a clean error, not crash the C bridge.
        XCTAssertThrowsError(try Xmp.read(Data("not a module".utf8)))
    }

    func testModToRenoiseMakesPlayableMixableInstrument() throws {
        let song = Tracker.toIR(try Xmp.read(minimalMod()))
        var stats = ConvertStats()
        let rs = ToRenoise.fromIR(song, linesPerBeat: nil, stats: &stats)

        // The "kick" sample becomes a playable, looped, mapped Renoise instrument.
        let inst = rs.instruments.first { $0.name == "kick" }
        let sample = try XCTUnwrap(inst?.sample, "instrument should carry a playable sample")
        XCTAssertFalse(sample.audio.isEmpty)
        XCTAssertEqual(Array(sample.audio.prefix(4)), Array("fLaC".utf8))   // embedded as FLAC
        XCTAssertEqual(sample.audioExt, "flac")
        XCTAssertEqual(sample.loopMode, "Forward")     // minimalMod loops frames 0..8
        XCTAssertEqual(sample.loopEnd, 8)
        XCTAssertEqual(sample.baseNote, 48)            // rootKey MIDI 60 → Renoise note 48 (C-4)
        XCTAssertNil(sample.envelope, "a plain MOD sample has no volume envelope → no modulation set")

        // Each instrument is its own mixer channel (a track per instrument), and
        // the emitted Song.xml embeds the named instrument + its New Note Action.
        let xml = RenoiseWriter.write(rs)
        XCTAssertTrue(xml.contains("<Name>kick</Name>"))
        XCTAssertTrue(xml.contains("<NewNoteAction>"))
        XCTAssertTrue(rs.tracks.contains { $0.kind == .master }, "a master bus should exist for mixing")
    }

    func testChannelLayoutPreservesChannelsAndReferencesInstruments() throws {
        // Channel layout: one track per tracker channel (the 4-channel MOD → 4
        // tracks), an explicit instrument table, and per-note instrument refs.
        let byChannel = Tracker.toIR(try Xmp.read(minimalMod()), layout: .channel)
        XCTAssertEqual(byChannel.regularTracks.count, 4)
        XCTAssertEqual(byChannel.instruments.count, 1)          // only "kick" is used
        XCTAssertEqual(byChannel.instruments.first?.name, "kick")
        let chNotes = byChannel.tracks.flatMap { $0.clips.flatMap { $0.notes } }
        XCTAssertEqual(chNotes.first?.instrument, 0)            // references the table
        XCTAssertEqual(chNotes.first?.key, 60)

        // Instrument layout: one track per instrument, no explicit per-note ref.
        let byInstrument = Tracker.toIR(try Xmp.read(minimalMod()), layout: .instrument)
        XCTAssertEqual(byInstrument.regularTracks.count, 1)
        XCTAssertTrue(byInstrument.instruments.isEmpty)
        XCTAssertNil(byInstrument.tracks.first?.clips.first?.notes.first?.instrument)
    }

    func testSampleOffsetBecomesRenoiseCommand() {
        // A note carrying a 9xx sample offset must re-emit as Renoise's 0Sxx.
        var track = IRTrack(role: .regular, name: "lead")
        track.clips = [IRClip(start: 0, length: 4, name: nil,
                              notes: [IRNote(start: 0, length: 1, key: 60, velocity: 1, sampleOffset: 0x20)])]
        var song = IRSong()
        song.tracks = [track]
        var stats = ConvertStats()
        let xml = RenoiseWriter.write(ToRenoise.fromIR(song, linesPerBeat: 4, stats: &stats))
        XCTAssertTrue(xml.contains("<Number>0S</Number>"))
        XCTAssertTrue(xml.contains("<Value>20</Value>"))
    }

    // MARK: - Pattern flow control (break Dxx / jump Bxx / loop E6x·SBx)

    /// One cell with an optional note + one raw libxmp effect (FX_* in effects.h).
    private func cell(note: Int? = nil, inst: Int? = nil, fxt: Int = 0, fxp: Int = 0) -> TCell {
        var c = TCell(); c.note = note; c.instrument = inst; c.fx1Type = fxt; c.fx1Param = fxp; return c
    }

    /// Assemble a single-instrument module (speed 6 → 4 rows/beat) from rows given
    /// as `[row: [channel: TCell]]` sparse maps, so a test only spells out the cells
    /// it cares about.
    private func flowModule(order: [Int], patterns: [[Int: [Int: TCell]]], rows: Int = 8, channels: Int = 2) -> TrackerModule {
        var m = TrackerModule(format: "MOD")
        m.channels = channels
        m.order = order
        m.instruments = [TInstrument(name: "s", sampleFrames: 4, pcm: [0, 1, 2, 3], sampleRate: 8363)]
        m.patterns = patterns.map { pat in
            (0..<rows).map { r in (0..<channels).map { ch in pat[r]?[ch] ?? TCell() } }
        }
        return m
    }

    /// Notes' (key, start) pairs, sorted by start then key — the played timeline.
    private func timeline(_ song: IRSong) -> [(key: Int, start: Double)] {
        song.tracks.flatMap { $0.clips.flatMap { $0.notes } }
            .map { ($0.key, $0.start) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
    }

    func testPatternBreakTruncatesAndPullsFollowingPatternEarly() {
        // Pattern 0: note at row 0, pattern break (FX_BREAK 0x0D) at row 4.
        // Pattern 1: note at row 0. Order [0, 1]. The break ends pattern 0 after
        // row 4 (5 rows = 1.25 beats), so pattern 1's note lands at beat 1.25 — not
        // 2.0 (which is where playing all 8 rows would put it).
        let m = flowModule(order: [0, 1], patterns: [
            [0: [0: cell(note: 48, inst: 1)], 4: [0: cell(fxt: 0x0D, fxp: 0)]],
            [0: [0: cell(note: 50, inst: 1)]],
        ])
        let t = timeline(Tracker.toIR(m))
        XCTAssertEqual(t.map { $0.key }, [60, 62])
        XCTAssertEqual(t[1].start, 1.25, accuracy: 1e-9)   // pulled early by the break
    }

    func testPositionJumpSkipsInterveningPattern() {
        // Pattern 0 jumps (FX_JUMP 0x0B) to order 2 at row 4, so order 1 never plays.
        let m = flowModule(order: [0, 1, 2], patterns: [
            [0: [0: cell(note: 48, inst: 1)], 4: [0: cell(fxt: 0x0B, fxp: 2)]],
            [0: [0: cell(note: 50, inst: 1)]],   // skipped
            [0: [0: cell(note: 52, inst: 1)]],
        ])
        let t = timeline(Tracker.toIR(m))
        XCTAssertEqual(t.map { $0.key }, [60, 64])          // 62 (order 1) never sounds
        XCTAssertEqual(t[1].start, 1.25, accuracy: 1e-9)
    }

    func testPatternLoopPerChannelTerminates() {
        // ch0 loops rows 2-6 (E60@2, E62@6); ch1 has a lone E61@8 with no E60 of its
        // own. A single global loop let ch1 re-enter and re-arm ch0's loop forever
        // (the 101.1.MOD blowup that hit the row cap). Per-channel state + fire-once
        // must terminate with a small, bounded note count.
        let m = flowModule(order: [0], patterns: [[
            0: [0: cell(note: 48, inst: 1)],
            2: [0: cell(fxt: 0x0E, fxp: 0x60)],
            6: [0: cell(note: 50, inst: 1, fxt: 0x0E, fxp: 0x62)],
            8: [1: cell(fxt: 0x0E, fxp: 0x61)],
        ]], rows: 16, channels: 2)
        let notes = Tracker.toIR(m).tracks.flatMap { $0.clips.flatMap { $0.notes } }
        XCTAssertGreaterThan(notes.count, 0)
        XCTAssertLessThan(notes.count, 100, "per-channel loop must terminate, not blow up")
    }

    func testExtremeSpeedClampsTempoToValidRange() {
        // A very high speed (an ending-hold like 2ND_PM.S3M's A7F = speed 127) computes
        // a sub-20 BPM tempo that DAWs floor to 20, reading as the whole song's tempo.
        // Every tempo-map point must stay within the declared [20, 999] range.
        var slow = TCell(); slow.speed = 200
        let m = flowModule(order: [0], patterns: [[
            0: [0: cell(note: 48, inst: 1)],
            8: [0: slow],
        ]], rows: 16, channels: 1)
        let song = Tracker.toIR(m)
        XCTAssertFalse(song.tempoMap.isEmpty)
        for p in song.tempoMap {
            XCTAssertGreaterThanOrEqual(p.bpm, 20.0, "tempo must not fall below the DAWproject floor")
            XCTAssertLessThanOrEqual(p.bpm, 999.0)
        }
    }

    func testS3MVolumeSlideBothNibblesSlidesDown() {
        // ScreamTracker 3 gives the DOWN slide priority when both nibbles of a Dxy
        // volume slide are set (libxmp QUIRK_VOLPDN — Skaven's 2nd Reality uses D7).
        // It must become a fade-OUT by the low nibble (0O70), not a fade-IN by the
        // high nibble (0ID0), which blasted the part to full volume — a jackhammer.
        let s3m = TrackerEffects.effectColumn(type: 0x0A, param: 0xD7, format: "S3M")
        XCTAssertEqual(s3m?.number, "0O")
        XCTAssertEqual(s3m?.value, "70")
        // IT/MOD/XM keep up-priority (no VOLPDN): D7 → fade in by the high nibble.
        for fmt in ["IT", "MOD", "XM"] {
            let c = TrackerEffects.effectColumn(type: 0x0A, param: 0xD7, format: fmt)
            XCTAssertEqual(c?.number, "0I", "\(fmt) keeps up-priority")
            XCTAssertEqual(c?.value, "D0", "\(fmt) keeps up-priority")
        }
        // Single-nibble S3M slides are unchanged: D07 → down 7, D70 → up 7.
        XCTAssertEqual(TrackerEffects.effectColumn(type: 0x0A, param: 0x07, format: "S3M")?.number, "0O")
        XCTAssertEqual(TrackerEffects.effectColumn(type: 0x0A, param: 0x70, format: "S3M")?.number, "0I")
    }

    func testPatternLoopRepeatsBody() {
        // Loop start (E60) at row 2, loop end (E62 → 2 repeats) at row 4 carrying a
        // note. Body rows 2…4 play 1 + 2 = 3 times, so that note sounds three times.
        let m = flowModule(order: [0], patterns: [[
            0: [0: cell(note: 48, inst: 1)],
            2: [0: cell(fxt: 0x0E, fxp: 0x60)],
            4: [0: cell(note: 50, inst: 1, fxt: 0x0E, fxp: 0x62)],
        ]])
        let t = timeline(Tracker.toIR(m))
        XCTAssertEqual(t.filter { $0.key == 62 }.count, 3)  // looped body's note plays 3×
        // First two passes' notes land before the third (1.0, 1.75, 2.5 beats).
        XCTAssertEqual(t.filter { $0.key == 62 }.map { $0.start }, [1.0, 1.75, 2.5])
    }
}
