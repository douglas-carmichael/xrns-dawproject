import Foundation

// Port of tracker-lib src/patterns/metadata.ts. The "patternsMetadata" file:
// 16-byte header (PAMD id, version, reserved, total size, flags) followed by
// fixed 50-byte records, each a NUL-terminated pattern name (max 31 chars).
enum PolyendMetadata {
    static func parse(_ data: Data) throws -> PatternsMetadata {
        var r = PolyendReader(data)
        guard r.count >= PatternsMetaConstants.headerSize else {
            throw PolyendError.fileTooShort("patternsMetadata header")
        }

        let fileId = r.ascii(4)
        let version = r.u16()
        r.skip(2)
        let totalSize = Int(r.u32())
        let controlFlags = Int(r.u32())

        guard fileId == PatternsMetaConstants.fileIdentifier else {
            throw PolyendError.invalidSignature(expected: PatternsMetaConstants.fileIdentifier, got: fileId)
        }
        guard version == PatternsMetaConstants.version else {
            throw PolyendError.unsupportedVersion("metadata version \(version)")
        }

        var names: [String] = []
        while r.offset + PatternsMetaConstants.patternRecordSize <= r.count {
            names.append(r.ascii(PatternsMetaConstants.nameMax))
            r.skip(PatternsMetaConstants.patternRecordSize - PatternsMetaConstants.nameMax)
        }

        let header = MetadataHeaderInfo(fileIdentifier: fileId, version: version,
                                        totalSize: totalSize, controlFlags: controlFlags)
        return PatternsMetadata(headerInfo: header, patternNames: names)
    }

    static func write(_ metadata: PatternsMetadata) -> Data {
        let totalSize = PatternsMetaConstants.headerSize
            + metadata.patternNames.count * PatternsMetaConstants.patternRecordSize
        let w = PolyendWriter(size: totalSize)

        w.ascii(metadata.headerInfo.fileIdentifier, 4)
        w.u16(metadata.headerInfo.version)
        w.skip(2)
        w.u32(UInt32(metadata.headerInfo.totalSize > 0 ? metadata.headerInfo.totalSize : totalSize))
        w.u32(UInt32(metadata.headerInfo.controlFlags))

        for name in metadata.patternNames {
            w.ascii(name, PatternsMetaConstants.nameMax)
            w.skip(PatternsMetaConstants.patternRecordSize - PatternsMetaConstants.nameMax)
        }
        return w.data
    }

    static func create(patternNames: [String]) -> PatternsMetadata {
        let header = MetadataHeaderInfo(
            fileIdentifier: PatternsMetaConstants.fileIdentifier,
            version: PatternsMetaConstants.version,
            totalSize: PatternsMetaConstants.headerSize + patternNames.count * PatternsMetaConstants.patternRecordSize,
            controlFlags: 0)
        return PatternsMetadata(headerInfo: header, patternNames: patternNames)
    }
}
