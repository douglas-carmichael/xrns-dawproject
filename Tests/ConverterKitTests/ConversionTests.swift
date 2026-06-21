import XCTest
import Foundation
@testable import ConverterKit

final class ConversionTests: XCTestCase {
    private func sampleSong() -> IRSong {
        var song = IRSong()
        song.tempo = 128
        song.signatureNumerator = 3
        song.signatureDenominator = 4
        song.title = "Test Song"
        song.artist = "Tester"
        song.comment = "line one\nline two"

        var lead = IRTrack(role: .regular, name: "Lead", color: RGB(r: 178, g: 80, b: 80),
                           volume: 0.8, pan: 0.25, mute: false, solo: false)
        lead.clips = [IRClip(start: 0, length: 4, name: nil, notes: [
            IRNote(start: 0, length: 1, key: 60, velocity: 1.0),
            IRNote(start: 1, length: 0.5, key: 64, velocity: 0.5),
            IRNote(start: 2, length: 2, key: 67, velocity: 0.75),
        ])]

        song.tracks = [lead, IRTrack(role: .master, name: "Master")]
        return song
    }

    func testDawProjectWriteReadRoundTrip() throws {
        let song = sampleSong()
        let (proj, meta, _) = DawProjectWriter.write(song)
        let back = try DawProjectReader.read(project: Data(proj.utf8), metadata: Data(meta.utf8))

        XCTAssertEqual(back.tempo, 128)
        XCTAssertEqual(back.signatureNumerator, 3)
        XCTAssertEqual(back.signatureDenominator, 4)
        XCTAssertEqual(back.title, "Test Song")
        XCTAssertEqual(back.artist, "Tester")

        let lead = try XCTUnwrap(back.tracks.first { $0.role == .regular })
        XCTAssertEqual(lead.name, "Lead")
        XCTAssertEqual(lead.color, RGB(r: 178, g: 80, b: 80))
        XCTAssertEqual(lead.pan, 0.25, accuracy: 1e-6)
        XCTAssertEqual(lead.volume, 0.8, accuracy: 1e-6)
        XCTAssertTrue(back.tracks.contains { $0.role == .master })

        let notes = lead.clips.flatMap { $0.notes }.sorted { $0.start < $1.start }
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes.map { $0.key }, [60, 64, 67])
        XCTAssertEqual(notes[1].length, 0.5, accuracy: 1e-6)
        XCTAssertEqual(notes[2].velocity, 0.75, accuracy: 1e-6)
    }

    func testRenoiseWriteReadRoundTripPreservesNotes() throws {
        var stats = ConvertStats()
        let renoise = ToRenoise.fromIR(sampleSong(), linesPerBeat: 8, stats: &stats)
        let xml = RenoiseWriter.write(renoise)

        let parsed = try RenoiseReader.read(songXML: Data(xml.utf8))
        XCTAssertEqual(parsed.bpm, 128)
        XCTAssertEqual(parsed.linesPerBeat, 8)

        var stats2 = ConvertStats()
        let ir = ToIR.fromRenoise(parsed, stats: &stats2)
        let notes = ir.tracks.flatMap { $0.clips.flatMap { $0.notes } }
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(Set(notes.map { $0.key }), [60, 64, 67])
        // velocities survive the volume-column round trip
        let byKey = Dictionary(uniqueKeysWithValues: notes.map { ($0.key, $0.velocity) })
        XCTAssertEqual(byKey[64]!, 0.5, accuracy: 0.02)
        XCTAssertEqual(byKey[67]!, 0.75, accuracy: 0.02)
    }

    func testRenoiseOutputIsWellFormedXML() throws {
        var stats = ConvertStats()
        let renoise = ToRenoise.fromIR(sampleSong(), linesPerBeat: 8, stats: &stats)
        let xml = RenoiseWriter.write(renoise)
        let root = try XML.parse(Data(xml.utf8))
        XCTAssertEqual(root.name, "RenoiseSong")
        XCTAssertEqual(root.attributeText("doc_version"), "67")
        XCTAssertNotNil(root.firstChild("PatternPool"))
        XCTAssertNotNil(root.firstChild("PatternSequence"))
    }

    func testFullPipelineThroughZipContainers() throws {
        // IR -> DAWproject zip, then read project.xml back out of the container.
        let song = sampleSong()
        let (proj, meta, _) = DawProjectWriter.write(song)
        let dawZip = Zip.create(entries: [
            ("project.xml", Data(proj.utf8)),
            ("metadata.xml", Data(meta.utf8)),
        ])
        let projOut = try Zip.read(entry: "project.xml", fromArchive: dawZip)
        XCTAssertEqual(String(decoding: projOut, as: UTF8.self), proj)

        // IR -> Renoise zip, then read Song.xml back out.
        var stats = ConvertStats()
        let renoise = ToRenoise.fromIR(song, linesPerBeat: 8, stats: &stats)
        let xrnsZip = Zip.create(entries: [("Song.xml", Data(RenoiseWriter.write(renoise).utf8))])
        let songOut = try Zip.read(entry: "Song.xml", fromArchive: xrnsZip)
        XCTAssertEqual(try XML.parse(songOut).name, "RenoiseSong")
    }

    func testEmptySongStillProducesValidContainers() throws {
        let empty = IRSong()
        let (proj, _, _) = DawProjectWriter.write(empty)
        XCTAssertEqual(try XML.parse(Data(proj.utf8)).name, "Project")

        var stats = ConvertStats()
        let renoise = ToRenoise.fromIR(empty, linesPerBeat: 8, stats: &stats)
        XCTAssertGreaterThanOrEqual(renoise.patterns.count, 1)  // Renoise needs >=1 pattern
        XCTAssertEqual(renoise.sequence.count, renoise.patterns.count)
    }
}
