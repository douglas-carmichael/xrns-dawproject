import XCTest
@testable import ConverterKit

final class PitchTests: XCTestCase {
    func testRenoiseNameToMidi() {
        XCTAssertEqual(Pitch.midiKey(fromRenoise: "C-4"), 60)   // middle C
        XCTAssertEqual(Pitch.midiKey(fromRenoise: "A-4"), 69)   // A440
        XCTAssertEqual(Pitch.midiKey(fromRenoise: "C#4"), 61)
        XCTAssertEqual(Pitch.midiKey(fromRenoise: "B-3"), 59)
        XCTAssertEqual(Pitch.midiKey(fromRenoise: "C-0"), 12)
    }

    func testNonNotes() {
        XCTAssertNil(Pitch.midiKey(fromRenoise: "OFF"))
        XCTAssertNil(Pitch.midiKey(fromRenoise: ""))
        XCTAssertNil(Pitch.midiKey(fromRenoise: "---"))
    }

    func testMidiToRenoiseName() {
        XCTAssertEqual(Pitch.renoiseName(fromMidi: 60), "C-4")
        XCTAssertEqual(Pitch.renoiseName(fromMidi: 69), "A-4")
        XCTAssertEqual(Pitch.renoiseName(fromMidi: 61), "C#4")
    }

    func testRoundTripAcrossRange() {
        // The Renoise-representable range maps to MIDI 12...131; MIDI clamps at 127.
        for key in 12...127 {
            let name = Pitch.renoiseName(fromMidi: key)
            XCTAssertEqual(Pitch.midiKey(fromRenoise: name), key, "round trip failed for \(key) -> \(name)")
        }
    }
}
