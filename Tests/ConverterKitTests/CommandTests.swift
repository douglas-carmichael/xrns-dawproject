import XCTest
@testable import ConverterKit

/// Tests for interpreting Renoise note commands when converting to DAWproject,
/// and for deriving the tracker grid (LPB) from tempo on the way back.
final class CommandTests: XCTestCase {
    // Build a one-track, one-pattern song around a single note column line.
    private func song(line: RNLine, lpb: Int = 4, tpl: Int = 12, numberOfLines: Int = 16) -> RenoiseSong {
        var s = RenoiseSong()
        s.linesPerBeat = lpb
        s.ticksPerLine = tpl
        s.tracks = [RNTrack(kind: .regular, name: "T")]
        s.patterns = [RNPattern(numberOfLines: numberOfLines,
                                tracks: [RNPatternTrack(lines: [line])], trackKinds: [.regular])]
        s.sequence = [0]
        return s
    }

    private func notes(_ rs: RenoiseSong) -> [IRNote] {
        var stats = ConvertStats()
        return ToIR.fromRenoise(rs, stats: &stats).tracks.flatMap { $0.clips.flatMap { $0.notes } }
    }

    func testVelocityFromVolumeColumn() {
        let col = RNNoteColumn(note: "C-4", instrument: "00", volume: "40", panning: nil, delay: nil)
        let n = notes(song(line: RNLine(index: 0, noteColumns: [col])))
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].velocity, 0.5, accuracy: 1e-6)   // 0x40 / 0x80
    }

    func testNoteDelayColumnShiftsStart() {
        // Delay column 0x80 = half a line; lpb 4 -> 0.5 line = 0.125 beats.
        let col = RNNoteColumn(note: "C-4", instrument: "00", volume: nil, panning: nil, delay: "80")
        let n = notes(song(line: RNLine(index: 0, noteColumns: [col])))
        XCTAssertEqual(n[0].start, 0.125, accuracy: 1e-6)
    }

    func testNoteDelayVolumeColumnQ() {
        // Qx in the volume column delays by x ticks; 6 ticks / 12 tpl = 0.5 line.
        let col = RNNoteColumn(note: "C-4", instrument: "00", volume: "Q6", panning: nil, delay: nil)
        let n = notes(song(line: RNLine(index: 0, noteColumns: [col])))
        XCTAssertEqual(n[0].start, (6.0 / 12.0) / 4.0, accuracy: 1e-6)
    }

    func testNoteCutVolumeColumn() {
        // C4 cuts after 4 ticks; with no following note it would ring to pattern end.
        let col = RNNoteColumn(note: "C-4", instrument: "00", volume: "C4", panning: nil, delay: nil)
        let n = notes(song(line: RNLine(index: 0, noteColumns: [col])))
        XCTAssertEqual(n[0].length, (4.0 / 12.0) / 4.0, accuracy: 1e-6)
    }

    func testNoteCutEffectColumn() {
        // 0C03 = cut to volume 0 after 3 ticks.
        let col = RNNoteColumn(note: "C-4", instrument: "00", volume: nil, panning: nil, delay: nil)
        let line = RNLine(index: 0, noteColumns: [col],
                          effectColumns: [RNEffectColumn(number: "0C", value: "03")])
        let n = notes(song(line: line))
        XCTAssertEqual(n[0].length, (3.0 / 12.0) / 4.0, accuracy: 1e-6)
    }

    func testPitchCommandKeepsWrittenPitch() {
        // A glide command (0G) does not change which key we render — only the
        // (unrepresentable) transition. The note stays at its written pitch.
        let col = RNNoteColumn(note: "C-4", instrument: "00", volume: nil, panning: nil, delay: nil)
        let line = RNLine(index: 0, noteColumns: [col],
                          effectColumns: [RNEffectColumn(number: "0G", value: "10")])
        let n = notes(song(line: line))
        XCTAssertEqual(n[0].key, 60)
    }

    // MARK: tempo -> LPB

    func testDerivedLinesPerBeat() {
        XCTAssertEqual(ToRenoise.derivedLinesPerBeat(forBPM: 120), 8)
        XCTAssertEqual(ToRenoise.derivedLinesPerBeat(forBPM: 60), 16)
        XCTAssertEqual(ToRenoise.derivedLinesPerBeat(forBPM: 240), 4)
        XCTAssertEqual(ToRenoise.derivedLinesPerBeat(forBPM: 90), 8)    // 960/90 ≈ 10.7 -> 8
        XCTAssertEqual(ToRenoise.derivedLinesPerBeat(forBPM: 174), 4)   // 960/174 ≈ 5.5 -> 4
        XCTAssertEqual(ToRenoise.derivedLinesPerBeat(forBPM: 50), 16)   // 960/50  = 19.2 -> 16
    }

    func testReverseDerivesLPBFromTempoWhenNil() {
        var song = IRSong()
        song.tempo = 60
        var stats = ConvertStats()
        let rs = ToRenoise.fromIR(song, linesPerBeat: nil, stats: &stats)
        XCTAssertEqual(rs.linesPerBeat, 16)
        XCTAssertEqual(stats.linesPerBeat, 16)
    }

    func testReverseHonoursExplicitLPB() {
        var song = IRSong()
        song.tempo = 60
        var stats = ConvertStats()
        let rs = ToRenoise.fromIR(song, linesPerBeat: 4, stats: &stats)
        XCTAssertEqual(rs.linesPerBeat, 4)
    }

    // MARK: emitting commands (DAWproject -> XRNS)

    private func subLineSong() -> IRSong {
        var song = IRSong()
        song.tempo = 120
        var t = IRTrack(role: .regular, name: "L")
        // At lpb 4: start 0.3 beats = line 1.2 (sub-line); length 0.1 beats = 0.4 line (< 1 line).
        t.clips = [IRClip(start: 0, length: 4, name: nil,
                          notes: [IRNote(start: 0.3, length: 0.1, key: 60, velocity: 1.0)])]
        song.tracks = [t]
        return song
    }

    func testReverseEmitsDelayAndCutCommands() {
        var stats = ConvertStats()
        let rs = ToRenoise.fromIR(subLineSong(), linesPerBeat: 4, stats: &stats)
        let col = rs.patterns[0].tracks[0].lines
            .flatMap { $0.noteColumns }
            .first { $0.note != nil && $0.note != "OFF" }
        XCTAssertNotNil(col)
        XCTAssertEqual(col?.note, "C-4")
        XCTAssertNotNil(col?.delay, "sub-line start should be encoded as a delay-column value")
        XCTAssertEqual(col?.panning?.first, "C", "a sub-line-length note should use a note-cut command")
    }

    func testReverseThenForwardPreservesSubLineTiming() {
        var s1 = ConvertStats()
        let rs = ToRenoise.fromIR(subLineSong(), linesPerBeat: 4, stats: &s1)
        var s2 = ConvertStats()
        let back = ToIR.fromRenoise(rs, stats: &s2)
        let note = back.tracks.flatMap { $0.clips.flatMap { $0.notes } }.first
        XCTAssertNotNil(note)
        XCTAssertEqual(note?.key, 60)
        XCTAssertEqual(note?.start ?? -1, 0.3, accuracy: 0.02)    // recovered via the delay column
        XCTAssertEqual(note?.length ?? -1, 0.1, accuracy: 0.05)   // recovered via the cut command
    }
}
