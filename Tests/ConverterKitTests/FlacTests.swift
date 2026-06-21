import XCTest
import Foundation
@testable import ConverterKit

final class FlacTests: XCTestCase {
    /// Encode a stressy mono 16-bit signal and dump the FLAC + the raw PCM so an
    /// external decoder (`flac -d`) can confirm a bit-exact lossless round-trip.
    func testFlacEncodesSmallerValidStreamAndDumpsForRoundTrip() throws {
        var pcm = [Int16]()
        for i in 0..<5000 { pcm.append(Int16(truncatingIfNeeded: Int(Double(Int16.max) * 0.8 * sin(Double(i) * 0.05)))) }
        pcm += [Int16](repeating: -12345, count: 1000)                               // constant run
        for i in 0..<3000 { pcm.append(Int16(truncatingIfNeeded: i * 7 - 10000)) }   // wrapping ramp
        pcm += [.min, .max, 0, -1, 1, .min, .max]                                    // extremes

        let data = Flac.encode(pcm, sampleRate: 8363)
        XCTAssertEqual(Array(data.prefix(4)), Array("fLaC".utf8))
        XCTAssertLessThan(data.count, pcm.count * 2, "FLAC should be smaller than raw 16-bit PCM")

        try data.write(to: URL(fileURLWithPath: "/tmp/xrnsdaw_flac.flac"))
        var raw = Data()
        for s in pcm { raw.append(UInt8(truncatingIfNeeded: s)); raw.append(UInt8(truncatingIfNeeded: s >> 8)) }
        try raw.write(to: URL(fileURLWithPath: "/tmp/xrnsdaw_flac.expected"))
    }

    func testFlacConstantAndEmpty() {
        XCTAssertEqual(Array(Flac.encode([Int16](repeating: 0, count: 2048), sampleRate: 44100).prefix(4)),
                       Array("fLaC".utf8))
        XCTAssertEqual(Array(Flac.encode([], sampleRate: 8363).prefix(4)), Array("fLaC".utf8))
    }

    /// The decoder reproduces what our encoder writes (exercises CONSTANT, FIXED
    /// orders 0–4, partitioned Rice and multi-frame streams). LPC and stereo
    /// decorrelation — which our encoder doesn't emit — are covered by decoding
    /// real Renoise samples in the .xrns import path.
    func testFlacDecodeRoundTrip() {
        let cases: [(String, [Int16])] = [
            ("silence", [Int16](repeating: 0, count: 1000)),               // CONSTANT
            ("constant", [Int16](repeating: -12345, count: 300)),
            ("ramp", (0..<6000).map { Int16(truncatingIfNeeded: $0) }),     // FIXED low order
            ("sine", (0..<6000).map { Int16(truncatingIfNeeded: Int(Double(Int16.max) * 0.7 * sin(Double($0) * 0.03))) }),
            ("noisy", (0..<9000).map { Int16(truncatingIfNeeded: ($0 &* 2654435761) ^ ($0 >> 5)) }),  // multi-frame
            ("extremes", [.min, .max, 0, -1, 1, .min, .max, 32766, -32767]),
        ]
        for (name, pcm) in cases {
            let encoded = Flac.encode(pcm, sampleRate: 44100)
            guard let dec = Flac.decode(encoded) else { XCTFail("\(name): decode returned nil"); continue }
            XCTAssertEqual(dec.channels, 1, "\(name): channels")
            XCTAssertEqual(dec.sampleRate, 44100, "\(name): rate")
            XCTAssertEqual(dec.pcm, pcm, "\(name): PCM round-trip")
        }
    }

    func testFlacDecodeRejectsGarbage() {
        XCTAssertNil(Flac.decode(Data([0, 1, 2, 3, 4, 5])))
        XCTAssertNil(Flac.decode(Data("NOTFLAC!".utf8)))
    }
}
