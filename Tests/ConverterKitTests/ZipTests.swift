import XCTest
import Foundation
@testable import ConverterKit

final class ZipTests: XCTestCase {
    // A real ZIP archive produced by Python's zipfile with ZIP_DEFLATED, base64
    // encoded. Entry "hello.txt" = "The quick brown fox jumps over the lazy dog. "
    // repeated 8 times. This exercises the full read path incl. the inflater.
    private let deflateZipBase64 = """
    UEsDBBQAAAAIAHF/1Fy7Fg/jMwAAAGgBAAAJAAAAaGVsbG8udHh0C8lIVSgszUzOVkgqyi/PU0jL\
    r1DIKs0tKFbIL0stUigBSuckVlUqpOSn6ymEjComVzEAUEsBAhQDFAAAAAgAcX/UXLsWD+MzAAAA\
    aAEAAAkAAAAAAAAAAAAAAIABAAAAAGhlbGxvLnR4dFBLBQYAAAAAAQABADcAAABaAAAAAAA=
    """

    private var deflateZip: Data {
        Data(base64Encoded: deflateZipBase64.replacingOccurrences(of: "\n", with: ""))!
    }

    func testReadDeflateCompressedEntry() throws {
        let out = try Zip.read(entry: "hello.txt", fromArchive: deflateZip)
        let expected = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 8)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), expected)
    }

    func testMissingEntryThrows() {
        XCTAssertThrowsError(try Zip.read(entry: "nope.txt", fromArchive: deflateZip)) { error in
            guard case ZipError.missingEntry = error else {
                return XCTFail("expected missingEntry, got \(error)")
            }
        }
    }

    func testStoredRoundTrip() throws {
        let text = Data("Hello, ZIP round-trip! 😀 áéí — ünïcödé".utf8)
        let binary = Data((0..<2048).map { UInt8($0 & 0xFF) })
        let archive = Zip.create(entries: [
            ("project.xml", text),
            ("nested/dir/data.bin", binary),
        ])
        XCTAssertEqual(try Zip.read(entry: "project.xml", fromArchive: archive), text)
        XCTAssertEqual(try Zip.read(entry: "nested/dir/data.bin", fromArchive: archive), binary)
    }

    func testCRC32KnownValue() {
        // CRC-32 of "123456789" is the standard check value 0xCBF43926.
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }
}
