import XCTest
import Foundation
@testable import ConverterKit

final class MidiTests: XCTestCase {
    private func song() -> IRSong {
        var s = IRSong()
        s.title = "Demo"
        s.tempo = 120
        var t = IRTrack(role: .regular, name: "Lead")
        t.clips = [IRClip(start: 0, length: 8, name: nil, notes: [
            IRNote(start: 0, length: 1, key: 60, velocity: 1.0),
            IRNote(start: 1, length: 2, key: 64, velocity: 0.5),
            IRNote(start: 4, length: 0.5, key: 67, velocity: 0.75),
        ])]
        s.tracks = [t]
        return s
    }

    func testIsAMidiFile() {
        let data = Smf.write(song())
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "MThd")
        XCTAssertTrue(data.count > 22)
    }

    func testMidiRoundTrip() throws {
        let back = try Smf.read(Smf.write(song()))
        let notes = back.tracks.flatMap { $0.clips.flatMap { $0.notes } }.sorted { $0.start < $1.start }
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes.map { $0.key }, [60, 64, 67])
        XCTAssertEqual(notes[1].start, 1.0, accuracy: 1e-3)
        XCTAssertEqual(notes[1].length, 2.0, accuracy: 1e-3)
        // Velocity survives the perceptual sqrt curve (write) / square (read) round
        // trip to within one 7-bit MIDI step of the nonlinear quantization.
        XCTAssertEqual(notes[2].velocity, 0.75, accuracy: 0.02)
        XCTAssertEqual(back.title, "Demo")
    }

    func testMidiPreservesTempoMap() throws {
        var s = song()
        s.setTempoMap([IRTempoPoint(time: 0, bpm: 120),
                       IRTempoPoint(time: 4, bpm: 140),
                       IRTempoPoint(time: 8, bpm: 90)])
        let back = try Smf.read(Smf.write(s))
        XCTAssertEqual(back.tempoMap.count, 3)
        XCTAssertEqual(back.tempoMap.map { Int($0.bpm.rounded()) }, [120, 140, 90])
        XCTAssertEqual(back.tempoMap[1].time, 4.0, accuracy: 1e-3)
    }
}

final class TempoMapTests: XCTestCase {
    private func mappedSong() -> IRSong {
        var s = IRSong()
        var t = IRTrack(role: .regular, name: "L")
        t.clips = [IRClip(start: 0, length: 16, name: nil,
                          notes: [IRNote(start: 0, length: 1, key: 60, velocity: 1.0)])]
        s.tracks = [t, IRTrack(role: .master, name: "Master")]
        s.setTempoMap([IRTempoPoint(time: 0, bpm: 120), IRTempoPoint(time: 8, bpm: 150)])
        return s
    }

    func testResolvedTempoMapFallsBackToConstant() {
        var s = IRSong()
        s.tempo = 128
        XCTAssertEqual(s.resolvedTempoMap.count, 1)
        XCTAssertEqual(s.resolvedTempoMap[0].bpm, 128)
    }

    func testDawProjectEmitsTempoAutomation() throws {
        let (proj, meta, _) = DawProjectWriter.write(mappedSong())
        XCTAssertTrue(proj.contains("<TempoAutomation"))
        XCTAssertTrue(proj.contains("<RealPoint"))
        let back = try DawProjectReader.read(project: Data(proj.utf8), metadata: Data(meta.utf8))
        XCTAssertEqual(back.tempoMap.count, 2)
        XCTAssertEqual(back.tempoMap.map { $0.bpm }, [120, 150])
        XCTAssertEqual(back.tempoMap[1].time, 8.0, accuracy: 1e-6)
    }

    func testConstantTempoEmitsNoAutomation() {
        var s = IRSong()
        s.tempo = 128
        let (proj, _, _) = DawProjectWriter.write(s)
        XCTAssertFalse(proj.contains("TempoAutomation"))
    }

    func testRenoiseEmitsAndReadsZTTempo() {
        var w = ConvertStats()
        let rs = ToRenoise.fromIR(mappedSong(), linesPerBeat: 8, stats: &w)
        let hasZT = rs.patterns.contains {
            $0.tracks.contains { $0.lines.contains { $0.effectColumns.contains { $0.number == "ZT" } } }
        }
        XCTAssertTrue(hasZT, "expected a ZTxx tempo command in the pattern data")

        var r = ConvertStats()
        let back = ToIR.fromRenoise(rs, stats: &r)
        XCTAssertEqual(back.tempoMap.map { Int($0.bpm.rounded()) }, [120, 150])
    }
}
