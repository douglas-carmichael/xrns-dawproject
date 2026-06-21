import Foundation

// Port of tracker-lib src/patterns/pattern.ts. A .mtp holds one pattern:
// header (14) + padding (2) + unused (12) + N tracks (1 length byte + 128
// six-byte steps each) + CRC (4). Step bytes on disk are note, instrument,
// fx1.type, fx1.value, fx0.type, fx0.value — note that fx1 precedes fx0.
enum PolyendPattern {
    static func parse(_ data: Data) throws -> PatternData {
        var r = PolyendReader(data)
        let fileSize = r.count
        let trackCount = detectTrackCount(fileSize)

        let header = readHeader(&r)
        guard header.idFile == "PM" || header.idFile == "KS" else {
            throw PolyendError.invalidSignature(expected: "PM", got: header.idFile)
        }

        r.skip(PatternConstants.paddingSize)
        r.skip(PatternConstants.unusedSize)

        var tracks: [TrackData] = []
        tracks.reserveCapacity(trackCount)
        for _ in 0 ..< trackCount {
            tracks.append(readTrack(&r))
        }

        let crc = r.u32()
        return PatternData(header: header, tracks: tracks, crc: crc, trackCount: trackCount)
    }

    static func write(_ pattern: PatternData) -> Data {
        let trackCount = pattern.tracks.count
        let fileSize = PatternConstants.preTrackSize
            + PatternConstants.trackSize * trackCount
            + PatternConstants.crcSize
        let w = PolyendWriter(size: fileSize)

        writeHeader(w, pattern.header)
        w.skip(PatternConstants.paddingSize)
        w.skip(PatternConstants.unusedSize)        // 12 reserved zero bytes

        for track in pattern.tracks { writeTrack(w, track) }
        w.u32(pattern.crc)
        return w.data
    }

    /// Builds an empty pattern (mirrors Tracker.createPattern). `numTracks` is
    /// 8/12/16; `numSteps` 1–128.
    static func create(numTracks: Int, numSteps: Int) -> PatternData {
        var tracks: [TrackData] = []
        for _ in 0 ..< numTracks {
            var steps: [StepData] = []
            for _ in 0 ..< numSteps {
                steps.append(StepData(note: -1, instrument: 0,
                                      fx: [FX(type: PolyendFX.none, value: 0),
                                           FX(type: PolyendFX.none, value: 0)]))
            }
            tracks.append(TrackData(length: numSteps - 1, steps: steps))
        }
        let header = PatternHeader(idFile: "PM", type: 0, fwVersion: [1, 9, 0, 0],
                                   fileStructureVersion: "5.5.5.5", size: 0)
        return PatternData(header: header, tracks: tracks, crc: 0, trackCount: numTracks)
    }

    // MARK: - Private

    /// The TS detects track count from exact file size but its size table is off
    /// by 2 (uses a 10-byte unused region instead of 12). We invert the actual
    /// write formula instead, falling back to 16 (Tracker+/Mini) like the TS.
    private static func detectTrackCount(_ fileSize: Int) -> Int {
        let body = fileSize - PatternConstants.preTrackSize - PatternConstants.crcSize
        if body > 0, body % PatternConstants.trackSize == 0 {
            let n = body / PatternConstants.trackSize
            if n == PatternConstants.trackCountOld
                || n == PatternConstants.trackCountOG
                || n == PatternConstants.trackCountMiniPlus {
                return n
            }
        }
        return PatternConstants.trackCountMiniPlus
    }

    private static func readHeader(_ r: inout PolyendReader) -> PatternHeader {
        let idFile = r.ascii(2)
        let type = r.u16()
        let fw = [r.u8(), r.u8(), r.u8(), r.u8()]
        let fsv = [r.u8(), r.u8(), r.u8(), r.u8()].map(String.init).joined(separator: ".")
        let size = r.u16()
        return PatternHeader(idFile: idFile, type: type, fwVersion: fw,
                             fileStructureVersion: fsv, size: size)
    }

    private static func readTrack(_ r: inout PolyendReader) -> TrackData {
        let length = r.u8()
        var steps: [StepData] = []
        steps.reserveCapacity(PatternConstants.stepCount)
        for _ in 0 ..< PatternConstants.stepCount { steps.append(readStep(&r)) }
        return TrackData(length: length, steps: steps)
    }

    private static func readStep(_ r: inout PolyendReader) -> StepData {
        let note = r.i8()
        let instrument = r.u8()
        let fx1Type = r.u8()
        var fx1Value = r.u8()
        let fx0Type = r.u8()
        var fx0Value = r.u8()
        if fx1Type == 0 { fx1Value = 0 }
        if fx0Type == 0 { fx0Value = 0 }
        return StepData(note: note, instrument: instrument,
                        fx: [FX(type: PolyendFX.record(fx0Type), value: fx0Value),
                             FX(type: PolyendFX.record(fx1Type), value: fx1Value)])
    }

    private static func writeHeader(_ w: PolyendWriter, _ header: PatternHeader) {
        w.ascii(String(header.idFile.prefix(2)), 2)
        w.u16(header.type)
        for i in 0 ..< 4 { w.u8(i < header.fwVersion.count ? header.fwVersion[i] : 0) }
        let parts = header.fileStructureVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< 4 { w.u8(i < parts.count ? parts[i] : 0) }
        w.u16(header.size)
    }

    private static func writeTrack(_ w: PolyendWriter, _ track: TrackData) {
        w.u8(track.length)
        for i in 0 ..< PatternConstants.stepCount {
            if i < track.steps.count {
                writeStep(w, track.steps[i])
            } else {
                w.skip(PatternConstants.stepSize)   // empty step = zeros
            }
        }
    }

    private static func writeStep(_ w: PolyendWriter, _ step: StepData) {
        w.i8(step.note)
        w.u8(step.instrument)
        let fx1 = step.fx.count > 1 ? step.fx[1] : FX(type: PolyendFX.none, value: 0)
        let fx0 = step.fx.count > 0 ? step.fx[0] : FX(type: PolyendFX.none, value: 0)
        let fx1Index = fx1.type.index
        let fx0Index = fx0.type.index
        w.u8(fx1Index)
        w.u8(fx1Index == 0 ? 0 : fx1.value)
        w.u8(fx0Index)
        w.u8(fx0Index == 0 ? 0 : fx0.value)
    }
}
