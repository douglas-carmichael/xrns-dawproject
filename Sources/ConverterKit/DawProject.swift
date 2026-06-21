import Foundation

// MARK: - DAWproject I/O
//
// project.xml / metadata.xml are written to match the schema produced by the
// reference Java DOM. Element order matters (the schema uses xs:sequence), so
// the writer emits children in the exact order the XSD declares:
//
//   project:  Application, Transport, Structure, Arrangement, Scenes
//   channel:  Devices, Mute, Pan, Sends, Volume
//   track:    Channel, (nested Track)
//
// Cross-references (channel.destination, lanes.track) use xs:ID / xs:IDREF, so
// every referenceable element is given a unique id.

/// Sequential id generator producing "id0", "id1", …
private final class IDGen {
    private var n = 0
    func next() -> String { defer { n += 1 }; return "id\(n)" }
}

/// Format a double for DAWproject XML: plain decimal, never scientific.
private func dpNum(_ d: Double) -> String {
    if d.isInfinite { return d > 0 ? "inf" : "-inf" }
    if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
    var s = String(format: "%.6f", d)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s += "0" }
    return s
}

enum DawProjectWriter {
    static let applicationName = "xrns-dawproject"
    static let applicationVersion = "1.0"
    static let formatVersion = "1.0"

    /// Returns project.xml, metadata.xml, and any files to embed in the container.
    static func write(_ song: IRSong) -> (project: String, metadata: String, files: [(name: String, data: Data)]) {
        let ids = IDGen()
        var embeddedFiles: [(name: String, data: Data)] = []
        let project = XML("Project").attr("version", formatVersion)

        // --- Application ---
        project.add(XML("Application")
            .attr("name", applicationName)
            .attr("version", applicationVersion))

        // --- Transport ---
        let tempoID = ids.next()
        let transport = project.element("Transport")
        transport.add(realParameter(name: "Tempo", value: song.tempo, unit: "bpm",
                                     min: 20, max: 999, id: tempoID))
        transport.add(XML("TimeSignature")
            .attr("numerator", song.signatureNumerator)
            .attr("denominator", song.signatureDenominator)
            .attr("id", ids.next()))

        // --- Pre-assign ids so destinations can be resolved regardless of order ---
        struct TrackIDs { var track: String; var channel: String }
        var trackIDs: [TrackIDs] = []
        for _ in song.tracks { trackIDs.append(TrackIDs(track: ids.next(), channel: ids.next())) }
        let masterChannelID = zip(song.tracks, trackIDs).first { $0.0.role == .master }?.1.channel

        // --- Structure ---
        let structure = project.element("Structure")
        for (i, t) in song.tracks.enumerated() {
            structure.add(trackElement(t, trackID: trackIDs[i].track, channelID: trackIDs[i].channel,
                                       masterChannelID: masterChannelID, idgen: ids))
        }

        // A dedicated audio track for extracted samples (reference material).
        var samplesTrackID: String?
        if !song.extractedSamples.isEmpty {
            let trackID = ids.next()
            samplesTrackID = trackID
            let track = XML("Track").attr("contentType", "audio").attr("loaded", "true")
                .attr("id", trackID).attr("name", "Extracted Samples")
                .attr("comment", "Decoded module samples for reference; laid out sequentially after the song so they don't all sound at once.")
            let channel = track.element("Channel").attr("audioChannels", 1).attr("role", "regular").attr("solo", "false")
            if let dest = masterChannelID { channel.attr("destination", dest) }
            channel.attr("id", ids.next())
            channel.add(XML("Mute").attr("value", "false").attr("id", ids.next()).attr("name", "Mute"))
            channel.add(realParameter(name: "Pan", value: 0.5, unit: "normalized", min: 0, max: 1, id: ids.next()))
            channel.add(realParameter(name: "Volume", value: 1.0, unit: "linear", min: 0, max: 2, id: ids.next()))
            structure.add(track)
        }

        // --- Arrangement (clips placed in pattern order along the timeline) ---
        let arrangement = project.element("Arrangement").attr("id", ids.next())
        let lanes = arrangement.element("Lanes").attr("timeUnit", "beats").attr("id", ids.next())
        for (i, t) in song.tracks.enumerated() where t.clips.contains(where: { !$0.notes.isEmpty }) {
            let trackLane = lanes.element("Lanes")
                .attr("track", trackIDs[i].track)
                .attr("id", ids.next())
            let clips = trackLane.element("Clips").attr("id", ids.next())
            for clip in t.clips where !clip.notes.isEmpty {
                let clipEl = clips.element("Clip")
                    .attr("time", dpNum(clip.start))
                    .attr("duration", dpNum(clip.length))
                if let nm = clip.name { clipEl.attr("name", nm) }
                let notes = clipEl.element("Notes")
                for n in clip.notes {
                    let noteEl = XML("Note")
                        .attr("time", dpNum(n.start))
                        .attr("duration", dpNum(n.length))
                        .attr("channel", 0)
                        .attr("key", n.key)
                        .attr("vel", dpNum(n.velocity))
                        .attr("rel", dpNum(n.velocity))
                    // Within-note dynamics → CC11 (expression) so modern instruments
                    // follow the original swells/fades. Times are beats from the note.
                    if !n.expression.isEmpty {
                        let pts = noteEl.element("Points").attr("unit", "normalized").attr("id", ids.next())
                        pts.add(XML("Target").attr("expression", "channelController")
                            .attr("controller", 11).attr("channel", 0))
                        for e in n.expression {
                            pts.add(XML("RealPoint").attr("time", dpNum(e.time)).attr("value", dpNum(e.value)))
                        }
                    }
                    notes.add(noteEl)
                }
            }
        }

        // --- Extracted samples: one audio clip each, sequential, after the song ---
        if let sID = samplesTrackID {
            let lane = lanes.element("Lanes").attr("track", sID).attr("id", ids.next())
            let clips = lane.element("Clips").attr("id", ids.next())
            var cursor = song.lengthInBeats + 4.0          // start a bar past the song
            let bpm = max(1, song.tempo)
            for (i, s) in song.extractedSamples.enumerated() {
                let frames = s.pcm.count / max(1, s.channels)
                let seconds = Double(frames) / Double(max(1, s.sampleRate))
                let durationBeats = max(0.25, seconds * bpm / 60.0)
                let path = "samples/\(String(format: "%02d", i + 1))_\(sanitize(s.name)).wav"
                embeddedFiles.append((path, Wav.encode(s.pcm, sampleRate: s.sampleRate, channels: s.channels,
                                                       rootKey: s.rootKey, loopStart: s.loopStart,
                                                       loopEnd: s.loopEnd, loopType: s.loopType)))
                let clip = clips.element("Clip")
                    .attr("time", dpNum(cursor))
                    .attr("duration", dpNum(durationBeats))
                    .attr("contentTimeUnit", "seconds")
                    .attr("playStart", "0.0")
                    .attr("name", "\(s.name) (root \(Pitch.renoiseName(fromMidi: s.rootKey)))")
                clip.element("Audio")
                    .attr("sampleRate", s.sampleRate)
                    .attr("channels", 1)
                    .attr("algorithm", "raw")
                    .attr("duration", dpNum(seconds))
                    .attr("timeUnit", "seconds")
                    .attr("id", ids.next())
                    .add(XML("File").attr("path", path).attr("external", "false"))
                cursor += durationBeats + 1.0
            }
        }

        // --- Tempo automation (only emitted when the tempo actually changes) ---
        // Schema order within Arrangement is Lanes, Markers, TempoAutomation, so
        // this is added after the lanes above.
        let tempoMap = song.resolvedTempoMap
        if tempoMap.count > 1 {
            let auto = arrangement.element("TempoAutomation").attr("unit", "bpm").attr("id", ids.next())
            auto.add(XML("Target").attr("parameter", tempoID))
            for pt in tempoMap {
                auto.add(XML("RealPoint").attr("time", dpNum(pt.time)).attr("value", dpNum(pt.bpm)))
            }
        }

        // --- Scenes (clip-launcher): Renoise has no equivalent, left empty ---
        project.element("Scenes")

        let projectXML = project.document(
            declaration: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>")
        return (projectXML, metadataXML(song), embeddedFiles)
    }

    /// Make a string safe for use as a file name inside the container.
    private static func sanitize(_ name: String) -> String {
        let allowed = name.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        let s = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "sample" : String(s.prefix(40))
    }

    private static func realParameter(name: String, value: Double, unit: String,
                                      min: Double, max: Double, id: String) -> XML {
        XML(name)
            .attr("unit", unit)
            .attr("value", dpNum(value))
            .attr("min", dpNum(min))
            .attr("max", dpNum(max))
            .attr("id", id)
            .attr("name", name)
    }

    private static func trackElement(_ t: IRTrack, trackID: String, channelID: String,
                                     masterChannelID: String?, idgen: IDGen) -> XML {
        let contentType: String
        let role: String
        switch t.role {
        case .regular: contentType = "notes"; role = "regular"
        case .master: contentType = "audio notes"; role = "master"
        case .send: contentType = "audio"; role = "effect"
        }

        let track = XML("Track")
            .attr("contentType", contentType)
            .attr("loaded", "true")
            .attr("id", trackID)
            .attr("name", t.name)
            .attr("comment", t.comment)
        if let c = t.color, !c.isBlack { track.attr("color", c.hex) }

        let channel = track.element("Channel")
            .attr("audioChannels", 2)
            .attr("role", role)
            .attr("solo", t.solo ? "true" : "false")
        // Master is the routing sink; everyone else routes to it.
        if t.role != .master, let dest = masterChannelID { channel.attr("destination", dest) }
        channel.attr("id", channelID)

        // Channel children, in schema order: Mute, Pan, Volume.
        channel.add(XML("Mute")
            .attr("value", t.mute ? "true" : "false")
            .attr("id", idgen.next())
            .attr("name", "Mute"))
        channel.add(realParameter(name: "Pan", value: t.pan, unit: "normalized",
                                  min: 0, max: 1, id: idgen.next()))
        channel.add(realParameter(name: "Volume", value: t.volume, unit: "linear",
                                  min: 0, max: 2, id: idgen.next()))
        return track
    }

    private static func metadataXML(_ song: IRSong) -> String {
        let meta = XML("MetaData")
        if let t = song.title { meta.leaf("Title", t) }
        if let a = song.artist { meta.leaf("Artist", a) }
        if let c = song.comment { meta.leaf("Comment", c) }
        return meta.document(
            declaration: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>")
    }
}

// MARK: - Reader (project.xml [+ metadata.xml] -> IRSong)

enum DawProjectReader {
    static func read(project data: Data, metadata: Data?) throws -> IRSong {
        let root = try XML.parse(data)
        guard root.name == "Project" else {
            throw ConvertError.parse("root element is not <Project>")
        }
        var song = IRSong()

        if let transport = root.firstChild("Transport") {
            if let tempo = transport.firstChild("Tempo")?.attributeText("value").flatMap({ Double($0) }) {
                song.tempo = tempo
            }
            if let ts = transport.firstChild("TimeSignature") {
                song.signatureNumerator = ts.attributeText("numerator").flatMap { Int($0) } ?? 4
                song.signatureDenominator = ts.attributeText("denominator").flatMap { Int($0) } ?? 4
            }
        }

        // Structure: build tracks and index them by their xs:ID.
        var trackIndexByID: [String: Int] = [:]
        if let structure = root.firstChild("Structure") {
            for el in structure.elements(forName: "Track") {
                let idx = song.tracks.count
                if let id = el.attributeText("id") { trackIndexByID[id] = idx }
                song.tracks.append(parseTrack(el))
            }
        }

        // Arrangement: attach clips to their track via the per-track Lanes' IDREF.
        if let arrangement = root.firstChild("Arrangement") {
            if let topLanes = arrangement.firstChild("Lanes") {
                for lane in topLanes.elements(forName: "Lanes") {
                    guard let trackRef = lane.attributeText("track"),
                          let trackIdx = trackIndexByID[trackRef] else { continue }
                    for clip in collectNoteClips(in: lane) {
                        song.tracks[trackIdx].clips.append(clip)
                    }
                }
            }
            // Tempo automation → tempo map.
            if let auto = arrangement.firstChild("TempoAutomation") {
                let points = auto.elements(forName: "RealPoint").compactMap { p -> IRTempoPoint? in
                    guard let t = p.attributeText("time").flatMap({ Double($0) }),
                          let v = p.attributeText("value").flatMap({ Double($0) }) else { return nil }
                    return IRTempoPoint(time: t, bpm: v)
                }
                if !points.isEmpty { song.setTempoMap(points) }
            }
        }

        if let metadata, let metaRoot = try? XML.parse(metadata) {
            song.title = metaRoot.childText("Title")
            song.artist = metaRoot.childText("Artist")
            song.comment = metaRoot.childText("Comment")
        }
        return song
    }

    private static func parseTrack(_ el: XML) -> IRTrack {
        let channel = el.firstChild("Channel")
        let roleStr = channel?.attributeText("role") ?? "regular"
        let role: TrackRole
        switch roleStr {
        case "master": role = .master
        case "effect": role = .send
        default: role = .regular
        }

        var track = IRTrack(role: role, name: el.attributeText("name") ?? "Track")
        track.comment = el.attributeText("comment")
        if let hex = el.attributeText("color") { track.color = RGB(hex: hex) }
        if let ch = channel {
            if let v = ch.firstChild("Volume")?.attributeText("value").flatMap({ Double($0) }) { track.volume = v }
            if let p = ch.firstChild("Pan")?.attributeText("value").flatMap({ Double($0) }) { track.pan = p }
            if let m = ch.firstChild("Mute")?.attributeText("value") { track.mute = (m == "true" || m == "1") }
            if let s = ch.attributeText("solo") { track.solo = (s == "true" || s == "1") }
        }
        return track
    }

    /// Find clips holding note content within a per-track lane. Handles the
    /// common Clip>Notes layout and one level of Clip>Clips>Clip>Notes nesting.
    private static func collectNoteClips(in lane: XML) -> [IRClip] {
        var result: [IRClip] = []
        func walkClips(_ clipsEl: XML) {
            for clipEl in clipsEl.elements(forName: "Clip") {
                let time = clipEl.attributeText("time").flatMap { Double($0) } ?? 0
                let duration = clipEl.attributeText("duration").flatMap { Double($0) }
                if let notesEl = clipEl.firstChild("Notes") {
                    let notes = parseNotes(notesEl)
                    let len = duration ?? (notes.map { $0.start + $0.length }.max() ?? 0)
                    result.append(IRClip(start: time, length: len,
                                         name: clipEl.attributeText("name"), notes: notes))
                } else if let inner = clipEl.firstChild("Clips") {
                    walkClips(inner)
                }
            }
        }
        for clips in lane.elements(forName: "Clips") { walkClips(clips) }
        return result
    }

    private static func parseNotes(_ notesEl: XML) -> [IRNote] {
        notesEl.elements(forName: "Note").compactMap { n in
            guard let key = n.attributeText("key").flatMap({ Int($0) }) else { return nil }
            let time = n.attributeText("time").flatMap { Double($0) } ?? 0
            let dur = n.attributeText("duration").flatMap { Double($0) } ?? 0
            let vel = n.attributeText("vel").flatMap { Double($0) } ?? 0.78
            return IRNote(start: time, length: max(0, dur), key: key, velocity: vel)
        }
    }
}
