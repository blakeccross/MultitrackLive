import SwiftData
import SwiftUI

enum SongDetailTab: String, CaseIterable, Identifiable {
    case mix
    case edit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mix: return "Mix"
        case .edit: return "Edit"
        }
    }
}

struct SongDetailView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var song: Song

    @State private var selectedTab: SongDetailTab
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

    init(song: Song, initialTab: SongDetailTab = .mix) {
        self.song = song
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        songDetailContent
            .navigationTitle(song.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Ableton File") {
                        showingAbletonImporter = true
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
            }
    }

    private var songDetailContent: some View {
        VStack(spacing: 0) {
            if let bpm = song.bpm {
                HStack {
                    Label(String(format: "%.1f BPM", bpm), systemImage: "metronome")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let timeSignature = song.timeSignatureDisplay {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Label(timeSignature, systemImage: "music.quarternote.3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !arrangementMarkers.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(arrangementMarkers.count) sections")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            Picker("Mode", selection: $selectedTab) {
                ForEach(SongDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if let viewModel {
                ZStack {
                    switch selectedTab {
                    case .mix:
                        MixView(song: song, viewModel: viewModel)
                    case .edit:
                        EditView(
                            song: song,
                            viewModel: viewModel,
                            arrangementMarkers: arrangementMarkers,
                            arrangementSlots: $arrangementSlots,
                            clipTrims: $clipTrims,
                            removedClips: $removedClips,
                            loopSlotIDs: $loopSlotIDs,
                            tempoChanges: $tempoChanges
                        )
                    }

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

    private func handleAppear() {
        if viewModel == nil {
            let model = SongEditorViewModel(song: song)
            model.loadSong()
            viewModel = model
        }
        reloadArrangementMarkers()
        reloadTempoChanges()
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
        viewModel.syncTempoMap(tempoChanges)
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
        if let initial = result.timeSignatures.sortedByTime.first {
            message += " Time signature: \(initial.displayName)."
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
        SongDetailView(song: Song(name: "Preview"))
    }
}
