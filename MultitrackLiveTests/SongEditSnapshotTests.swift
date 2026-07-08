import SwiftData
import XCTest
@testable import MultitrackLive

final class SongEditSnapshotTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceController.modelTypes)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testCaptureApplyRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let song = Song(name: "Undo Test")
        song.bpm = 128
        song.transposeSemitones = 2
        song.clickTrackEnabled = true
        song.clickTrackVolume = 0.75

        let track = AudioTrack(displayName: "Kick", relativeFilePath: "kick.wav", sortOrder: 0)
        track.volume = 0.5
        track.isMuted = true
        track.trimStartSeconds = 1.5
        track.trimEndSeconds = 10.0
        track.song = song
        song.tracks = [track]
        context.insert(song)

        var markers = [ArrangementMarker(name: "Intro", startSeconds: 0, sortOrder: 0)]
        var slots = [ArrangementSlot(markerID: markers[0].id)]
        var tempoChanges = [TempoChange(startMeasure: 1, bpm: 128)]
        var timeSignatureChanges = [
            TimeSignatureChange(numerator: 3, denominator: 4, startMeasure: 1, sortOrder: 0)
        ]
        var midiEvents: [MIDIEvent] = []

        let snapshot = SongEditSnapshot.capture(
            song: song,
            markers: markers,
            arrangementSlots: slots,
            clipTrims: [],
            removedClips: [],
            clipGaps: [],
            clipRegions: [],
            loopSlotIDs: [],
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            midiEvents: midiEvents
        )

        song.bpm = 90
        song.transposeSemitones = -1
        song.clickTrackEnabled = false
        track.volume = 1.0
        track.isMuted = false
        markers = []
        slots = []
        tempoChanges = [TempoChange(startMeasure: 1, bpm: 90)]
        timeSignatureChanges = [
            TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0)
        ]

        markers = snapshot.markers
        slots = snapshot.arrangementSlots
        tempoChanges = snapshot.tempoChanges
        timeSignatureChanges = snapshot.timeSignatureChanges
        midiEvents = snapshot.midiEvents
        snapshot.applyMetadata(to: song)
        snapshot.applyTracks(to: song, context: context)

        let restored = SongEditSnapshot.capture(
            song: song,
            markers: markers,
            arrangementSlots: slots,
            clipTrims: [],
            removedClips: [],
            clipGaps: [],
            clipRegions: [],
            loopSlotIDs: [],
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            midiEvents: midiEvents
        )

        XCTAssertEqual(restored, snapshot)
    }
}
