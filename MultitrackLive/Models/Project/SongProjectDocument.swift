import Foundation
import SwiftData

struct SongProjectMetadata: Codable, Hashable {
    var bpm: Double?
    var timeSignatureNumerator: Int?
    var timeSignatureDenominator: Int?
    var transposeSemitones: Int
    var transposeHighQuality: Bool

    init(from song: Song) {
        bpm = song.bpm
        timeSignatureNumerator = song.timeSignatureNumerator
        timeSignatureDenominator = song.timeSignatureDenominator
        transposeSemitones = song.transposeSemitones
        transposeHighQuality = song.transposeHighQuality
    }

    func apply(to song: Song) {
        song.bpm = bpm
        song.timeSignatureNumerator = timeSignatureNumerator
        song.timeSignatureDenominator = timeSignatureDenominator
        song.transposeSemitones = transposeSemitones
        song.transposeHighQuality = transposeHighQuality
    }
}

struct ProjectTrackMix: Codable, Hashable {
    var volume: Double
    var isMuted: Bool
    var isSolo: Bool
    var trimStartSeconds: Double
    var trimEndSeconds: Double?
    var excludeFromTranspose: Bool

    init(from track: AudioTrack) {
        volume = track.volume
        isMuted = track.isMuted
        isSolo = track.isSolo
        trimStartSeconds = track.trimStartSeconds
        trimEndSeconds = track.trimEndSeconds
        excludeFromTranspose = track.excludeFromTranspose
    }

    func apply(to track: AudioTrack) {
        track.volume = volume
        track.isMuted = isMuted
        track.isSolo = isSolo
        track.trimStartSeconds = trimStartSeconds
        track.trimEndSeconds = trimEndSeconds
        track.excludeFromTranspose = excludeFromTranspose
    }
}

struct ProjectTrack: Codable, Hashable, Identifiable {
    let id: UUID
    var displayName: String
    var sortOrder: Int
    var media: MediaReference
    var mix: ProjectTrackMix
    var groupName: String?
}

struct ProjectMIDITrack: Codable, Hashable, Identifiable {
    let id: UUID
    var displayName: String
    var sortOrder: Int
    var deviceName: String?
}

struct SongProjectArrangement: Codable {
    var markers: [ArrangementMarker]
    var sequence: SongArrangement
}

struct SongProjectDocument: Codable, Identifiable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var metadata: SongProjectMetadata
    var tracks: [ProjectTrack]
    var midiTracks: [ProjectMIDITrack]
    var arrangement: SongProjectArrangement
    var tempo: [TempoChange]
    var timeSignatures: [TimeSignatureChange]
    var midiEvents: [MIDIEvent]
    /// Read-only performance cache metadata. Audio files live under `Baked/`.
    var bakeManifest: SongBakeManifest?

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        modifiedAt: Date = Date(),
        metadata: SongProjectMetadata,
        tracks: [ProjectTrack] = [],
        midiTracks: [ProjectMIDITrack] = [],
        arrangement: SongProjectArrangement,
        tempo: [TempoChange] = [],
        timeSignatures: [TimeSignatureChange] = [],
        midiEvents: [MIDIEvent] = [],
        bakeManifest: SongBakeManifest? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.metadata = metadata
        self.tracks = tracks
        self.midiTracks = midiTracks
        self.arrangement = arrangement
        self.tempo = tempo
        self.timeSignatures = timeSignatures
        self.midiEvents = midiEvents
        self.bakeManifest = bakeManifest
    }
}
