import Foundation

// Port of tracker-lib src/projects/project.ts. A .mt holds the song: header +
// 255-entry playlist + a large block addressed by fixed absolute offsets
// (tempo, project/track names, delay/reverb). Writing patches those offsets
// into the embedded template so untouched regions match hardware output.
enum PolyendProject {
    // Absolute offsets within the .mt body.
    private enum Off {
        static let tempo = 0x1C0
        static let delayFeedback = 0x11A
        static let delayTime = 0x11C
        static let delayParams = 0x11F
        static let reverbSize = 0x418
        static let reverbDamp = 0x41C
        static let reverbPredelay = 0x420
        static let reverbDiffusion = 0x424
        static let trackNames = 0x428          // 8 × 21 bytes
        static let trackNamesShort = 0x603     // 8 × 8 bytes (non-legacy)
        static let reverbVolume = 0x538
        static let delayVolume = 0x539
        static let reverbMute = 0x53A
        static let delayMute = 0x53B
        static let projectNameLatest = 0x810   // fileStructureVersion > 16
        static let projectNameOlder = 0x80C    // > 15
        static let projectNameLegacy = 0x600
    }

    static func parse(_ data: Data) throws -> ProjectData {
        var r = PolyendReader(data)
        let fileSize = r.count

        let header = readHeader(&r)
        guard header.idFile == ProjectConstants.fileIdentifier else {
            throw PolyendError.invalidSignature(expected: ProjectConstants.fileIdentifier, got: header.idFile)
        }
        r.skip(ProjectConstants.paddingAfterHeader)

        var playlist: [Int] = []
        playlist.reserveCapacity(ProjectConstants.playlistSize)
        for _ in 0 ..< ProjectConstants.playlistSize { playlist.append(r.u8()) }
        let playlistPos = r.u8()
        let song = SongData(playlist: playlist, playlistPos: playlistPos)

        let values = readOtherData(r, header: header)

        let version = majorVersion(header.fileStructureVersion)
        let projectName = r.asciiAt(projectNameOffset(version), ProjectConstants.projectNameSize)

        let crc = r.u32At(fileSize - ProjectConstants.crcSize)
        let crcStr = "0x" + String(crc, radix: 16, uppercase: true)

        return ProjectData(crc: crcStr, header: header, projectName: projectName,
                           song: song, values: values)
    }

    static func write(_ project: ProjectData) -> Data {
        let w = PolyendWriter(template: PolyendProjectTemplate.buffer())

        writeHeader(w, project.header)
        w.skip(ProjectConstants.paddingAfterHeader)
        for i in 0 ..< ProjectConstants.playlistSize {
            w.u8(i < project.song.playlist.count ? project.song.playlist[i] : 0)
        }
        w.u8(project.song.playlistPos)

        // Other data (absolute; the TS always writes the latest layout, v >= 17).
        w.f32At(Off.tempo, project.values.globalTempo)
        w.asciiAt(Off.projectNameLatest, project.projectName, ProjectConstants.projectNameSize)

        for i in 0 ..< 8 {
            let name = i < project.values.trackNames.count ? project.values.trackNames[i] : ""
            w.asciiAt(Off.trackNames + i * ProjectConstants.trackNameSize, name, ProjectConstants.trackNameSize)
        }
        for i in 8 ..< 16 {
            let name = i < project.values.trackNames.count ? project.values.trackNames[i] : ""
            w.asciiAt(Off.trackNamesShort + (i - 8) * ProjectConstants.trackNameSizeShort,
                      name, ProjectConstants.trackNameSizeShort)
        }

        w.u8At(Off.delayFeedback, project.values.delayFeedback)
        w.u16At(Off.delayTime, project.values.delayTime)
        w.u8At(Off.delayParams, project.values.delayParams)
        w.f32At(Off.reverbSize, project.values.reverb.size)
        w.f32At(Off.reverbDamp, project.values.reverb.damp)
        w.f32At(Off.reverbPredelay, project.values.reverb.predelay)
        w.f32At(Off.reverbDiffusion, project.values.reverb.diffusion)
        w.u8At(Off.reverbVolume, project.values.reverbVolume)
        w.u8At(Off.delayVolume, project.values.delayVolume)
        w.u8At(Off.reverbMute, project.values.reverbMute)
        w.u8At(Off.delayMute, project.values.delayMute)

        return w.data
    }

    /// Mirrors Tracker.createProject. Track names default to Track 1–8 / Midi 9–16.
    static func create(name projectName: String) -> ProjectData {
        let truncated = String(projectName.prefix(ProjectConstants.projectNameSize))
        let header = ProjectHeader(idFile: ProjectConstants.fileIdentifier, type: ProjectConstants.type,
                                   fwVersion: "1.9.2.255", fileStructureVersion: "17.17.17.17", size: 2324)
        var playlist = [Int](repeating: 0, count: ProjectConstants.playlistSize)
        playlist[0] = 1
        let names = ["Track 1", "Track 2", "Track 3", "Track 4", "Track 5", "Track 6", "Track 7", "Track 8",
                     "Midi 9", "Midi 10", "Midi 11", "Midi 12", "Midi 13", "Midi 14", "Midi 15", "Midi 16"]
        let values = MtValues(globalTempo: 130, trackNames: names,
                              delayFeedback: 50, delayTime: 500, delayParams: 0,
                              delayVolume: 0, delayMute: 0,
                              reverb: ReverbParams(size: 0.5, damp: 0.5, predelay: 0.5, diffusion: 0.68),
                              reverbVolume: 0, reverbMute: 0)
        return ProjectData(crc: "0x0", header: header, projectName: truncated,
                           song: SongData(playlist: playlist, playlistPos: 0), values: values)
    }

    // MARK: - Private

    private static func majorVersion(_ fsv: String) -> Int {
        Int(fsv.split(separator: ".").first.map(String.init) ?? "0") ?? 0
    }

    private static func projectNameOffset(_ version: Int) -> Int {
        if version > 16 { return Off.projectNameLatest }
        if version > 15 { return Off.projectNameOlder }
        return Off.projectNameLegacy
    }

    private static func readHeader(_ r: inout PolyendReader) -> ProjectHeader {
        let idFile = r.ascii(2)
        let type = r.u16()
        let fw = "\(r.u8()).\(r.u8()).\(r.u8()).\(r.u8())"
        let fsv = "\(r.u8()).\(r.u8()).\(r.u8()).\(r.u8())"
        let size = r.u16()
        return ProjectHeader(idFile: idFile, type: type, fwVersion: fw,
                             fileStructureVersion: fsv, size: size)
    }

    private static func readOtherData(_ r: PolyendReader, header: ProjectHeader) -> MtValues {
        let globalTempo = r.f32At(Off.tempo)
        let version = majorVersion(header.fileStructureVersion)
        let legacy = version <= 15

        var trackNames: [String] = []
        for i in 0 ..< 8 {
            trackNames.append(r.asciiAt(Off.trackNames + i * ProjectConstants.trackNameSize,
                                        ProjectConstants.trackNameSize))
        }
        if !legacy {
            for i in 0 ..< 8 {
                trackNames.append(r.asciiAt(Off.trackNamesShort + i * ProjectConstants.trackNameSizeShort,
                                            ProjectConstants.trackNameSizeShort))
            }
        }

        let reverb = ReverbParams(size: r.f32At(Off.reverbSize), damp: r.f32At(Off.reverbDamp),
                                  predelay: r.f32At(Off.reverbPredelay), diffusion: r.f32At(Off.reverbDiffusion))
        return MtValues(globalTempo: globalTempo, trackNames: trackNames,
                        delayFeedback: r.u8At(Off.delayFeedback), delayTime: r.u16At(Off.delayTime),
                        delayParams: r.u8At(Off.delayParams),
                        delayVolume: r.u8At(Off.delayVolume), delayMute: r.u8At(Off.delayMute),
                        reverb: reverb, reverbVolume: r.u8At(Off.reverbVolume), reverbMute: r.u8At(Off.reverbMute))
    }

    private static func writeHeader(_ w: PolyendWriter, _ header: ProjectHeader) {
        w.ascii(String(header.idFile.prefix(2)), 2)
        w.u16(header.type)
        let fw = header.fwVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< 4 { w.u8(i < fw.count ? fw[i] : 0) }
        let fsv = header.fileStructureVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< 4 { w.u8(i < fsv.count ? fsv[i] : 0) }
        w.u16(header.size)
    }
}
