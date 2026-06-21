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
        XCTAssertFalse(sample.wav.isEmpty)
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
}
