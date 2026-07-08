import Foundation
import SwiftData

struct TrackEditSnapshot: Equatable, Hashable {
    let trackID: UUID
    var volume: Double
    var isMuted: Bool
    var isSolo: Bool
    var trimStartSeconds: Double
    var trimEndSeconds: Double?
    var excludeFromTranspose: Bool
    var groupName: String?
}

struct SongMetadataSnapshot: Equatable, Hashable {
    var bpm: Double?
    var timeSignatureNumerator: Int?
    var timeSignatureDenominator: Int?
    var transposeSemitones: Int
    var transposeHighQuality: Bool
    var clickTrackEnabled: Bool
    var clickTrackVolume: Double
    var clickTrackSubdivision: String
}

struct SongEditSnapshot: Equatable {
    var markers: [ArrangementMarker]
    var arrangementSlots: [ArrangementSlot]
    var clipTrims: [ArrangementClipTrim]
    var removedClips: [ArrangementRemovedClip]
    var clipGaps: [ArrangementClipGap]
    var clipRegions: [ClipRegion]
    var loopSlotIDs: Set<UUID>
    var tempoChanges: [TempoChange]
    var timeSignatureChanges: [TimeSignatureChange]
    var midiEvents: [MIDIEvent]
    var songMetadata: SongMetadataSnapshot
    var tracks: [TrackEditSnapshot]

    static func capture(
        song: Song,
        markers: [ArrangementMarker],
        arrangementSlots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap],
        clipRegions: [ClipRegion],
        loopSlotIDs: Set<UUID>,
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange],
        midiEvents: [MIDIEvent]
    ) -> SongEditSnapshot {
        SongEditSnapshot(
            markers: markers,
            arrangementSlots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            loopSlotIDs: loopSlotIDs,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            midiEvents: midiEvents,
            songMetadata: SongMetadataSnapshot(
                bpm: song.bpm,
                timeSignatureNumerator: song.timeSignatureNumerator,
                timeSignatureDenominator: song.timeSignatureDenominator,
                transposeSemitones: song.transposeSemitones,
                transposeHighQuality: song.transposeHighQuality,
                clickTrackEnabled: song.clickTrackEnabled,
                clickTrackVolume: song.clickTrackVolume,
                clickTrackSubdivision: song.clickTrackSubdivision
            ),
            tracks: song.sortedTracks.map { track in
                TrackEditSnapshot(
                    trackID: track.id,
                    volume: track.volume,
                    isMuted: track.isMuted,
                    isSolo: track.isSolo,
                    trimStartSeconds: track.trimStartSeconds,
                    trimEndSeconds: track.trimEndSeconds,
                    excludeFromTranspose: track.excludeFromTranspose,
                    groupName: track.group?.name
                )
            }
        )
    }

    func applyMetadata(to song: Song) {
        song.bpm = songMetadata.bpm
        song.timeSignatureNumerator = songMetadata.timeSignatureNumerator
        song.timeSignatureDenominator = songMetadata.timeSignatureDenominator
        song.transposeSemitones = songMetadata.transposeSemitones
        song.transposeHighQuality = songMetadata.transposeHighQuality
        song.clickTrackEnabled = songMetadata.clickTrackEnabled
        song.clickTrackVolume = songMetadata.clickTrackVolume
        song.clickTrackSubdivision = songMetadata.clickTrackSubdivision
    }

    func applyTracks(to song: Song, context: ModelContext) {
        let groups = (try? context.fetch(FetchDescriptor<TrackGroup>())) ?? []
        let groupsByName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })

        for trackSnapshot in tracks {
            guard let track = song.sortedTracks.first(where: { $0.id == trackSnapshot.trackID }) else { continue }
            track.volume = trackSnapshot.volume
            track.isMuted = trackSnapshot.isMuted
            track.isSolo = trackSnapshot.isSolo
            track.trimStartSeconds = trackSnapshot.trimStartSeconds
            track.trimEndSeconds = trackSnapshot.trimEndSeconds
            track.excludeFromTranspose = trackSnapshot.excludeFromTranspose
            if let groupName = trackSnapshot.groupName {
                track.group = groupsByName[groupName]
            } else {
                track.group = nil
            }
        }
    }

    func normalizedTempoChanges(defaultBPM: Double) -> [TempoChange] {
        tempoChanges.normalizedEnsuringInitialMarker(defaultBPM: defaultBPM)
    }

    func normalizedTimeSignatureChanges(
        defaultNumerator: Int,
        defaultDenominator: Int
    ) -> [TimeSignatureChange] {
        timeSignatureChanges.normalizedEnsuringInitialMarker(
            defaultNumerator: defaultNumerator,
            defaultDenominator: defaultDenominator
        )
    }
}
