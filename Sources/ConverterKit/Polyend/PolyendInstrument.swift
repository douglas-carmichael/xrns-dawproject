import Foundation

// Port of tracker-lib src/instruments/instrument.ts. A .pti is:
//   header (16) + main fields (374) + sample PCM + CRC (4)
// PCM is 16-bit 44.1kHz, stored de-interleaved (planar: all-left then all-right)
// for stereo. Many parameters are stored scaled (volume ×50, panning ×50+50,
// resonance ×4.3, sends ×100); we read/write with the same scaling as the TS.
//
// We keep the sample as interleaved Int16 in `InstrumentData.pcm` rather than the
// TS's wrapped WAV ArrayBuffer — the on-disk bytes are identical; only the
// in-memory container differs, which suits the IR bridge.
enum PolyendInstrument {
    static func parse(_ data: Data) throws -> InstrumentData {
        var r = PolyendReader(data)
        let fileSize = r.count

        let header = readHeader(&r)
        guard header.idFile == InstrumentConstants.fileIdentifier else {
            throw PolyendError.invalidSignature(expected: InstrumentConstants.fileIdentifier, got: header.idFile)
        }
        r.skip(InstrumentConstants.paddingAfterHeader)

        let isActive = r.u8() == 1
        r.skip(3)

        var sample = readSampleBankSlot(&r)
        r.skip(4) // reserved

        let playmode = r.u8()
        r.skip(1)
        let startPoint = r.u16()
        let loopPoint1 = r.u16()
        let loopPoint2 = r.u16()
        let endPoint = r.u16()
        r.skip(2)
        let wavetableCurrentWindow = r.u32()

        var envelopes: [(env: Envelope, loop: Bool, enabled: Bool)] = []
        for _ in 0 ..< InstrumentConstants.envelopeCount { envelopes.append(readEnvelope(&r)) }
        var lfos: [LFO] = []
        for _ in 0 ..< InstrumentConstants.lfoCount { lfos.append(readLFO(&r)) }
        var automations: [Automation] = []
        for i in 0 ..< InstrumentConstants.envelopeCount {
            let e = envelopes[i]
            automations.append(Automation(enabled: e.enabled, isLFO: e.loop, envelope: e.env, lfo: lfos[i]))
        }

        let cutoff = r.f32()
        let resonance = r.f32() / 4.3
        let filterType = r.u8()
        let filterEnabled = r.u8() == 1
        let tune = r.i8()
        let finetune = r.i8()
        let volume = Float(max(0, min(100, r.u8()))) / 50
        r.skip(3)
        let panning = Float(max(0, min(100, r.i16())) - 50) / 50
        let delaySend = Float(r.u8()) / 100
        r.skip(1)

        var slices: [Int] = []
        for _ in 0 ..< InstrumentConstants.slicesCount { slices.append(r.u16()) }
        let numSlices = r.u8()
        let selectedSlice = r.u8()
        let granular = readGranular(&r)
        let reverbSend = Float(r.u8()) / 100
        let overdrive = Float(r.u8()) / 100
        let bitdepth = r.u8()
        r.skip(1) // reserved
        r.skip(2) // final padding — kept symmetric with write (the TS omits it on read, its off-by-2)

        // Remaining bytes (minus the trailing CRC) are the sample PCM.
        let audioOffset = r.offset
        let rawLen = max(0, fileSize - InstrumentConstants.crcSize - audioOffset)
        let rawBytes = r.slice(rawLen)
        let (pcm, channels, frames) = deplanarize(rawBytes, headerLength: sample.length)
        sample.length = frames
        sample.channels = channels

        let crc = r.u32()
        let crcStr = "0x" + String(crc, radix: 16, uppercase: true)

        return InstrumentData(
            header: header, isActive: isActive, sample: sample, playmode: playmode,
            startPoint: startPoint, loopPoint1: loopPoint1, loopPoint2: loopPoint2, endPoint: endPoint,
            wavetableCurrentWindow: wavetableCurrentWindow, automations: automations,
            cutoff: cutoff, resonance: resonance, filterType: filterType, filterEnabled: filterEnabled,
            tune: tune, finetune: finetune, volume: volume, panning: panning,
            delaySend: delaySend, reverbSend: reverbSend, slices: slices,
            numSlices: numSlices, selectedSlice: selectedSlice, granular: granular,
            overdrive: overdrive, bitdepth: bitdepth, crc: crcStr, pcm: pcm)
    }

    static func write(_ inst: InstrumentData) -> Data {
        let channels = max(1, inst.sample.channels)
        let frames = inst.sample.length
        let rawBytes = planarize(inst.pcm, channels: channels, frames: frames)

        let size = InstrumentConstants.headerSize + InstrumentConstants.mainFieldsSize
            + rawBytes.count + InstrumentConstants.crcSize
        let w = PolyendWriter(size: size)

        writeHeader(w, inst.header)
        w.skip(InstrumentConstants.paddingAfterHeader)

        w.u8(inst.isActive ? 1 : 0)
        w.skip(3)
        writeSampleBankSlot(w, inst.sample)
        w.skip(4) // reserved
        w.u8(inst.playmode)
        w.skip(1)
        w.u16(inst.startPoint)
        w.u16(inst.loopPoint1)
        w.u16(inst.loopPoint2)
        w.u16(inst.endPoint)
        w.skip(2)
        w.u32(inst.wavetableCurrentWindow)

        for a in inst.automations { writeEnvelope(w, a) }
        for a in inst.automations { writeLFO(w, a.lfo) }

        w.f32(inst.cutoff)
        w.f32(inst.resonance * 4.3)
        w.u8(inst.filterType)
        w.u8(inst.filterEnabled ? 1 : 0)
        w.i8(inst.tune)
        w.i8(inst.finetune)
        w.u8(Int(inst.volume * 50))
        w.skip(3)
        w.i16(Int((inst.panning * 50 + 50).rounded()))
        w.u8(Int((inst.delaySend * 100).rounded()))
        w.skip(1)

        for i in 0 ..< InstrumentConstants.slicesCount {
            w.u16(i < inst.slices.count ? inst.slices[i] : 0)
        }
        w.u8(inst.numSlices)
        w.u8(inst.selectedSlice)
        writeGranular(w, inst.granular)
        w.u8(Int((inst.reverbSend * 100).rounded()))
        w.u8(Int((inst.overdrive * 100).rounded()))
        w.u8(inst.bitdepth)
        w.skip(1) // reserved
        w.skip(2) // final padding (matches hardware; see read counterpart)

        w.raw(rawBytes)
        w.u32(0) // CRC (cosmetic / unused)
        return w.data
    }

    /// Mirrors Tracker.createInstrument defaults, with the sample supplied as
    /// interleaved 16-bit PCM (empty for a sample-less instrument).
    static func create(name: String = "untitled", pcm: [Int16] = [], channels: Int = 1) -> InstrumentData {
        let ch = max(1, channels)
        let frames = pcm.isEmpty ? 0 : pcm.count / ch
        var automations: [Automation] = []
        for i in 0 ..< InstrumentConstants.envelopeCount {
            automations.append(Automation(
                enabled: i == 0, isLFO: false,
                envelope: Envelope(amount: 1, delay: 0, attack: 0, decay: 0, sustain: 1, release: 1000),
                lfo: LFO(shape: LFOShape.triangle.rawValue, speed: LFOSpeed.s4.rawValue, amount: 0)))
        }
        let sample = SampleBankSlot(type: SampleType.waveFile.rawValue, filename: name, length: frames,
                                    wavetableWindowSize: 256, wavetableWindowCount: 0, channels: ch)
        let header = InstrumentHeader(idFile: InstrumentConstants.fileIdentifier, type: InstrumentConstants.type,
                                      fwVersion: "1.9.1.1", fileStructureVersion: "9.9.9.9", size: 372)
        return InstrumentData(
            header: header, isActive: true, sample: sample, playmode: InstrumentPlayMode.oneShot.rawValue,
            startPoint: 0, loopPoint1: 0, loopPoint2: InstrumentConstants.max16Bit - 1,
            endPoint: InstrumentConstants.max16Bit, wavetableCurrentWindow: 0, automations: automations,
            cutoff: 1.0, resonance: 0.0, filterType: InstrumentFilterType.lowPass.rawValue, filterEnabled: false,
            tune: 0, finetune: 0, volume: 1.0, panning: 0.0, delaySend: 0.0, reverbSend: 0.0,
            slices: [Int](repeating: 0, count: InstrumentConstants.slicesCount), numSlices: 0, selectedSlice: 0,
            granular: Granular(grainLength: 4410, currentPosition: 0,
                               shape: GranularShape.triangle.rawValue, type: GranularType.forward.rawValue),
            overdrive: 0, bitdepth: 16, crc: "", pcm: pcm)
    }

    // MARK: - Audio (de)planarization

    /// Planar/interleaved + channel detection, matching the TS parse: pick stereo
    /// vs mono by which expected byte length the raw block is closest to.
    private static func deplanarize(_ raw: [UInt8], headerLength: Int) -> (pcm: [Int16], channels: Int, frames: Int) {
        let rawLen = raw.count
        guard rawLen >= 2 else { return ([], 1, 0) }
        let expectedMono = headerLength * 2
        let expectedStereo = headerLength * 4
        let channels = abs(rawLen - expectedStereo) < abs(rawLen - expectedMono) ? 2 : 1
        let bytesPerFrame = channels * 2
        let frames = rawLen / bytesPerFrame

        var shorts = [Int16](repeating: 0, count: rawLen / 2)
        for i in 0 ..< shorts.count {
            shorts[i] = Int16(bitPattern: UInt16(raw[i * 2]) | (UInt16(raw[i * 2 + 1]) << 8))
        }
        if channels == 2 {
            var pcm = [Int16](repeating: 0, count: frames * 2)
            for i in 0 ..< frames {
                pcm[i * 2] = shorts[i]            // left block
                pcm[i * 2 + 1] = shorts[frames + i] // right block
            }
            return (pcm, 2, frames)
        }
        return (shorts, 1, frames)
    }

    private static func planarize(_ pcm: [Int16], channels: Int, frames: Int) -> [UInt8] {
        func bytes(_ s: Int16) -> (UInt8, UInt8) {
            let u = UInt16(bitPattern: s); return (UInt8(u & 0xFF), UInt8(u >> 8))
        }
        if channels == 2 {
            let n = min(frames, pcm.count / 2)
            var raw = [UInt8](repeating: 0, count: n * 4)
            for i in 0 ..< n {
                let (l0, l1) = bytes(pcm[i * 2])
                let (r0, r1) = bytes(pcm[i * 2 + 1])
                raw[i * 2] = l0; raw[i * 2 + 1] = l1          // left block
                raw[n * 2 + i * 2] = r0; raw[n * 2 + i * 2 + 1] = r1 // right block
            }
            return raw
        }
        var raw = [UInt8](); raw.reserveCapacity(pcm.count * 2)
        for s in pcm { let (b0, b1) = bytes(s); raw.append(b0); raw.append(b1) }
        return raw
    }

    // MARK: - Header / fields

    private static func readHeader(_ r: inout PolyendReader) -> InstrumentHeader {
        let idFile = r.ascii(2)
        let type = r.u16()
        let fw = "\(r.u8()).\(r.u8()).\(r.u8()).\(r.u8())"
        let fsv = "\(r.u8()).\(r.u8()).\(r.u8()).\(r.u8())"
        let size = r.u16()
        return InstrumentHeader(idFile: idFile, type: type, fwVersion: fw, fileStructureVersion: fsv, size: size)
    }

    private static func writeHeader(_ w: PolyendWriter, _ header: InstrumentHeader) {
        w.ascii(String(header.idFile.prefix(2)), 2)
        w.u16(header.type)
        let fw = header.fwVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< 4 { w.u8(i < fw.count ? fw[i] : 0) }
        let fsv = header.fileStructureVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< 4 { w.u8(i < fsv.count ? fsv[i] : 0) }
        w.u16(header.size)
    }

    private static func readSampleBankSlot(_ r: inout PolyendReader) -> SampleBankSlot {
        let type = r.u8()
        let filename = r.ascii(32)
        r.skip(3) // padding
        r.skip(4) // reserved
        let length = Int(r.u32())
        let windowSize = r.u16()
        r.skip(2) // padding
        let windowCount = Int(r.u32())
        return SampleBankSlot(type: type, filename: filename, length: length,
                              wavetableWindowSize: windowSize, wavetableWindowCount: windowCount, channels: 0)
    }

    private static func writeSampleBankSlot(_ w: PolyendWriter, _ sample: SampleBankSlot) {
        w.u8(sample.type)
        w.ascii(sample.filename.isEmpty ? "untitled" : sample.filename, 32)
        w.skip(3) // padding
        w.raw([0x00, 0xA0, 0x26, 0x80]) // previously-"reserved" field, value from hardware
        w.u32(UInt32(sample.length))
        w.u16(2048) // wavetable window size, value from hardware
        w.skip(2)   // padding
        w.u32(UInt32(sample.wavetableWindowCount))
    }

    private static func readEnvelope(_ r: inout PolyendReader) -> (env: Envelope, loop: Bool, enabled: Bool) {
        let amount = r.f32()
        let delay = r.u16()
        let attack = r.u16()
        _ = r.u16() // hold (unused)
        let decay = r.u16()
        let sustain = r.f32()
        let release = r.u16()
        let loop = r.u8() == 1
        let enabled = r.u8() == 1
        return (Envelope(amount: amount, delay: delay, attack: attack, decay: decay, sustain: sustain, release: release),
                loop, enabled)
    }

    private static func writeEnvelope(_ w: PolyendWriter, _ a: Automation) {
        w.f32(a.envelope.amount)
        w.u16(a.envelope.delay)
        w.u16(a.envelope.attack)
        w.u16(0) // hold
        w.u16(a.envelope.decay)
        w.f32(a.envelope.sustain)
        w.u16(a.envelope.release)
        w.u8(a.isLFO ? 1 : 0)
        w.u8(a.enabled ? 1 : 0)
    }

    private static func readLFO(_ r: inout PolyendReader) -> LFO {
        let shape = r.u8()
        let speed = r.u8()
        r.skip(2)
        let amount = r.f32()
        return LFO(shape: shape, speed: speed, amount: amount)
    }

    private static func writeLFO(_ w: PolyendWriter, _ lfo: LFO) {
        w.u8(lfo.shape)
        w.u8(lfo.speed)
        w.skip(2)
        w.f32(lfo.amount)
    }

    private static func readGranular(_ r: inout PolyendReader) -> Granular {
        let grainLength = r.u16()
        let currentPosition = r.u16()
        let shape = r.u8()
        let type = r.u8()
        return Granular(grainLength: grainLength, currentPosition: currentPosition, shape: shape, type: type)
    }

    private static func writeGranular(_ w: PolyendWriter, _ g: Granular) {
        w.u16(g.grainLength)
        w.u16(g.currentPosition)
        w.u8(g.shape)
        w.u8(g.type)
    }
}
