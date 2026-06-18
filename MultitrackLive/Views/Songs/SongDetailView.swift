import SwiftData
import SwiftUI

struct SongDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var song: Song
    let setlistName: String

    @State private var viewModel: SongEditorViewModel?
    @State private var showingAbletonImporter = false
    @State private var abletonImportError: String?
    @State private var abletonImportSummary: String?
    @State private var arrangementMarkers: [ArrangementMarker] = []
    @State private var arrangementSlots: [ArrangementSlot] = []
    @State private var clipTrims: [ArrangementClipTrim] = []
    @State private var removedClips: [ArrangementRemovedClip] = []
    @State private var loopSlotIDs: Set<UUID> = []
    @State private var tempoChanges: [TempoChange] = []
    @State private var timeSignatureChanges: [TimeSignatureChange] = []

    var body: some View {
        songDetailContent
            .navigationTitle(song.name)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: setlistBackButtonPlacement) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text(displaySetlistName)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingAbletonImporter,
                allowedContentTypes: [AbletonProjectImporter.abletonLiveSetType],
                allowsMultipleSelection: false
            ) { result in
                handleAbletonImport(result)
            }
            .alert("Ableton Import Failed", isPresented: Binding(
                get: { abletonImportError != nil },
                set: { if !$0 { abletonImportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(abletonImportError ?? "")
            }
            .alert("Ableton Import Complete", isPresented: Binding(
                get: { abletonImportSummary != nil },
                set: { if !$0 { abletonImportSummary = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(abletonImportSummary ?? "")
            }
            .onAppear(perform: handleAppear)
            #if os(macOS)
            .focusedValue(\.songEditorActions, songEditorActions)
            #endif
            .onDisappear {
                AudioEngineManager.shared.stop()
                try? SongArrangementStore.save(
                    slots: arrangementSlots,
                    clipTrims: clipTrims,
                    removedClips: removedClips,
                    loopSlotIDs: loopSlotIDs,
                    for: song.id
                )
                try? TempoStore.save(tempoChanges, for: song.id)
                try? TimeSignatureStore.save(timeSignatureChanges, for: song.id)
            }
    }

    #if os(iOS)
    private var setlistBackButtonPlacement: ToolbarItemPlacement {
        .topBarLeading
    }
    #else
    private var setlistBackButtonPlacement: ToolbarItemPlacement {
        .navigation
    }
    #endif

    private var displaySetlistName: String {
        let trimmed = setlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Setlist" : trimmed
    }

    private var songDetailContent: some View {
        VStack(spacing: 0) {
            if let viewModel {
                ZStack {
                    EditView(
                        song: song,
                        viewModel: viewModel,
                        arrangementMarkers: arrangementMarkers,
                        arrangementSlots: $arrangementSlots,
                        clipTrims: $clipTrims,
                        removedClips: $removedClips,
                        loopSlotIDs: $loopSlotIDs,
                        tempoChanges: $tempoChanges,
                        timeSignatureChanges: $timeSignatureChanges
                    )

                    if viewModel.isReloadingSong {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(viewModel.isReloadingSong && song.transposeHighQuality ? "Processing audio…" : "Loading audio…")
                                .font(.headline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                ProgressView("Loading song...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    #if os(macOS)
    private var songEditorActions: SongEditorActions {
        SongEditorActions(
            canAutoGroup: !song.sortedTracks.isEmpty,
            autoGroup: {
                TrackGroupStore.autoAssignGroups(for: song, in: modelContext)
            },
            importAbleton: {
                showingAbletonImporter = true
            }
        )
    }
    #endif

    private func handleAppear() {
        if viewModel == nil {
            let model = SongEditorViewModel(song: song)
            model.loadSong()
            viewModel = model
        }
        reloadArrangementMarkers()
        reloadTempoChanges()
        reloadTimeSignatureChanges()
        syncArrangementPlayback()
        syncTempoPlayback()
    }

    private func reloadTempoChanges() {
        tempoChanges = TempoStore.loadOrMigrate(for: song)
        if song.bpm != tempoChanges.referenceBPM {
            song.bpm = tempoChanges.referenceBPM
            try? modelContext.save()
        }
    }

    private func reloadTimeSignatureChanges() {
        timeSignatureChanges = TimeSignatureStore.loadOrMigrate(for: song, tempoChanges: tempoChanges)
        let referenceNumerator = timeSignatureChanges.referenceNumerator
        let referenceDenominator = timeSignatureChanges.referenceDenominator
        var didChange = false
        if song.timeSignatureNumerator != referenceNumerator {
            song.timeSignatureNumerator = referenceNumerator
            didChange = true
        }
        if song.timeSignatureDenominator != referenceDenominator {
            song.timeSignatureDenominator = referenceDenominator
            didChange = true
        }
        if didChange {
            try? modelContext.save()
        }
    }

    private func reloadArrangementMarkers() {
        arrangementMarkers = ArrangementMarkerStore.load(for: song.id).sortedByTime
        let arrangement = SongArrangementStore.load(for: song.id, markers: arrangementMarkers)
        arrangementSlots = arrangement.slots
        clipTrims = arrangement.clipTrims
        removedClips = arrangement.removedClips
        loopSlotIDs = arrangement.loopSlotIDs
    }

    private func syncArrangementPlayback() {
        guard let viewModel else { return }
        viewModel.syncArrangement(
            markers: arrangementMarkers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips
        )
    }

    private func syncTempoPlayback() {
        guard let viewModel else { return }
        viewModel.syncTempoMap(tempoChanges, timeSignatureChanges: timeSignatureChanges)
    }

    private func handleAbletonImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            abletonImportError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let importResult = try AbletonProjectImporter.importFrom(url: url)
                let markers = AbletonProjectImporter.makeMarkers(from: importResult).sortedByTime
                arrangementMarkers = markers
                try AbletonProjectImporter.apply(
                    importResult,
                    markers: markers,
                    to: song,
                    context: modelContext
                )
                arrangementSlots = SongArrangementStore.defaultSlots(from: markers)
                clipTrims = []
                removedClips = []
                loopSlotIDs = []
                try SongArrangementStore.save(
                    slots: arrangementSlots,
                    clipTrims: clipTrims,
                    removedClips: removedClips,
                    loopSlotIDs: loopSlotIDs,
                    for: song.id
                )
                reloadTempoChanges()
                reloadTimeSignatureChanges()
                abletonImportSummary = importSummary(for: importResult)
                syncArrangementPlayback()
                syncTempoPlayback()
            } catch {
                abletonImportError = error.localizedDescription
            }
        }
    }

    private func importSummary(for result: AbletonProjectImporter.ImportResult) -> String {
        let bpmText = String(format: "%.1f BPM", result.bpm)
        let sectionLines = result.sections.prefix(4).map { section in
            "\(section.name) at \(formatMarkerTime(section.startSeconds))"
        }
        let extraCount = max(0, result.sections.count - 4)
        var message = "Imported \(result.sections.count) sections at \(bpmText)."
        let signatures = result.timeSignatures.sortedByMeasure
        if signatures.count == 1, let initial = signatures.first {
            message += " Time signature: \(initial.displayName)."
        } else if signatures.count > 1 {
            let summary = signatures.prefix(3).map { signature in
                if signature.startMeasure == 1 {
                    return signature.displayName
                }
                return "\(signature.displayName) at measure \(signature.startMeasure)"
            }.joined(separator: ", ")
            message += " Time signatures: \(summary)"
            if signatures.count > 3 {
                message += ", …"
            }
            message += "."
        }
        message += "\n"
        message += sectionLines.joined(separator: "\n")
        if extraCount > 0 {
            message += "\n…and \(extraCount) more."
        }
        return message
    }

    private func formatMarkerTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    NavigationStack {
        SongDetailView(song: Song(name: "Preview"), setlistName: "Preview Setlist")
    }
}
