import XCTest
@testable import ConverterKit

/// Round-trip tests for the Polyend Tracker codecs (ported from the canonical
/// tracker-lib TypeScript). Since no hardware reference files ship with this
/// repo, correctness is established by (a) structural round-trip parse∘write and
/// (b) byte-stability: write(parse(write(x))) == write(x).
final class PolyendTests: XCTestCase {

    // MARK: - Pattern (.mtp)

    func testPatternRoundTrip() throws {
        // 128 steps (the .mtp always stores 128/track) so the parse is a full
        // structural round-trip; create(numSteps: <128) would pad to 128 on write.
        var p = PolyendPattern.create(numTracks: 16, numSteps: 128)
        // A populated step exercising both FX lanes (fx0 lower, fx1 upper) — on
        // disk fx1 precedes fx0, so this checks the lane ordering survives.
        p.tracks[0].steps[3] = StepData(
            note: 60, instrument: 5,
            fx: [FX(type: PolyendFX.table[18], value: 80),    // fx0 = Volume/Velocity
                 FX(type: PolyendFX.table[15], value: 120)])  // fx1 = Tempo

        let bytes = PolyendPattern.write(p)
        XCTAssertEqual(bytes.count, 28 + 769 * 16 + 4) // 12336

        let q = try PolyendPattern.parse(bytes)
        XCTAssertEqual(q.trackCount, 16)
        XCTAssertEqual(q.tracks.count, 16)

        let step = q.tracks[0].steps[3]
        XCTAssertEqual(step.note, 60)
        XCTAssertEqual(step.instrument, 5)
        XCTAssertEqual(step.fx[0].type.index, 18)
        XCTAssertEqual(step.fx[0].value, 80)
        XCTAssertEqual(step.fx[1].type.index, 15)
        XCTAssertEqual(step.fx[1].value, 120)
        XCTAssertEqual(q.tracks[1].steps[0].note, -1)  // untouched step stays empty

        XCTAssertEqual(p, q)                            // full structural round-trip
        XCTAssertEqual(PolyendPattern.write(q), bytes)  // byte-stable
    }

    func testPatternTrackCountDetection() throws {
        for n in [8, 12, 16] {
            let bytes = PolyendPattern.write(PolyendPattern.create(numTracks: n, numSteps: 128))
            XCTAssertEqual(try PolyendPattern.parse(bytes).trackCount, n)
        }
    }

    func testPatternRejectsBadSignature() {
        var bytes = [UInt8](PolyendPattern.write(PolyendPattern.create(numTracks: 16, numSteps: 16)))
        bytes[0] = 0x58 // 'X'
        XCTAssertThrowsError(try PolyendPattern.parse(Data(bytes)))
    }

    // MARK: - Project (.mt)

    func testProjectRoundTrip() throws {
        var pr = PolyendProject.create(name: "My Song")
        pr.values.globalTempo = 128.0
        pr.song.playlist[0] = 3
        pr.song.playlist[1] = 7
        pr.values.trackNames[0] = "Drums"
        pr.values.trackNames[9] = "Bass"   // lives in the 8-byte short-name region

        let bytes = PolyendProject.write(pr)
        XCTAssertGreaterThan(bytes.count, 2000)  // template decoded to the full project

        let q = try PolyendProject.parse(bytes)
        XCTAssertEqual(q.projectName, "My Song")
        XCTAssertEqual(q.values.globalTempo, 128.0, accuracy: 1e-4)
        XCTAssertEqual(q.song.playlist[0], 3)
        XCTAssertEqual(q.song.playlist[1], 7)
        XCTAssertEqual(q.values.trackNames[0], "Drums")
        XCTAssertEqual(q.values.trackNames[9], "Bass")
        XCTAssertEqual(q.values.trackNames.count, 16)

        XCTAssertEqual(PolyendProject.write(q), bytes)  // byte-stable
    }

    // MARK: - Patterns metadata (PAMD)

    func testMetadataRoundTrip() throws {
        let m = PolyendMetadata.create(patternNames: ["Intro", "Verse", "Chorus"])
        let bytes = PolyendMetadata.write(m)
        XCTAssertEqual(bytes.count, 16 + 3 * 50)

        let q = try PolyendMetadata.parse(bytes)
        XCTAssertEqual(q.headerInfo.fileIdentifier, "PAMD")
        XCTAssertEqual(q.headerInfo.version, 1)
        XCTAssertEqual(q.patternNames, ["Intro", "Verse", "Chorus"])
        XCTAssertEqual(PolyendMetadata.write(q), bytes)
    }

    // MARK: - Instrument (.pti)

    func testInstrumentRoundTripMono() throws {
        let pcm: [Int16] = [0, 1000, -1000, 32767, -32768, 5, -5, 100]
        let inst = PolyendInstrument.create(name: "kick", pcm: pcm, channels: 1)

        let bytes = PolyendInstrument.write(inst)
        XCTAssertEqual(bytes.count, 16 + 374 + pcm.count * 2 + 4) // 410

        let q = try PolyendInstrument.parse(bytes)
        XCTAssertEqual(q.header.idFile, "TI")
        XCTAssertEqual(q.sample.filename, "kick")
        XCTAssertEqual(q.sample.channels, 1)
        XCTAssertEqual(q.sample.length, pcm.count)
        XCTAssertEqual(q.pcm, pcm)
        XCTAssertEqual(q.volume, 1.0, accuracy: 1e-6)
        XCTAssertEqual(q.bitdepth, 16)
        XCTAssertEqual(PolyendInstrument.write(q), bytes)  // byte-stable
    }

    func testInstrumentRoundTripStereo() throws {
        let pcm: [Int16] = [1, 2, 3, 4, 5, 6, -1, -2]  // 4 interleaved L/R frames
        let inst = PolyendInstrument.create(name: "pad", pcm: pcm, channels: 2)

        let bytes = PolyendInstrument.write(inst)
        let q = try PolyendInstrument.parse(bytes)
        XCTAssertEqual(q.sample.channels, 2)
        XCTAssertEqual(q.sample.length, 4)
        XCTAssertEqual(q.pcm, pcm)                          // planar de/interleave round-trips
        XCTAssertEqual(PolyendInstrument.write(q), bytes)
    }

    func testInstrumentEmptySample() throws {
        let inst = PolyendInstrument.create(name: "empty")
        let bytes = PolyendInstrument.write(inst)
        XCTAssertEqual(bytes.count, 16 + 374 + 4)
        let q = try PolyendInstrument.parse(bytes)
        XCTAssertEqual(q.sample.length, 0)
        XCTAssertTrue(q.pcm.isEmpty)
    }
}
