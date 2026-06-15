import SwiftUI

struct LivePlaybackView: View {
    @Environment(\.dismiss) private var dismiss

    let setlist: Setlist

    @State private var coordinator = PlaybackCoordinator()
    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false

    var body: some View {
        VStack(spacing: 0) {
            currentSongSection
                .padding()

            Divider()

            setlistSection
        }
        .navigationTitle(setlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Stop") {
                    clearMarkerCue()
                    coordinator.stop()
                    dismiss()
                }
            }
        }
        .background {
            SectionCueMonitor(
                cuedSectionID: cuedSectionID,
                cueFireTime: cueFireTime,
                onFire: fireMarkerCue
            )
        }
        .task(id: cuedSectionID) {
            guard cuedSectionID != nil else {
                cueFlashPhase = false
                return
            }
            cueFlashPhase = true
            while !Task.isCancelled, cuedSectionID != nil {
                try? await Task.sleep(for: .milliseconds(350))
                cueFlashPhase.toggle()
            }
        }
        .onChange(of: coordinator.currentSong?.id) { _, _ in
            clearMarkerCue()
        }
        .onAppear {
            coordinator.configure(setlist: setlist)
        }
        .onDisappear {
            clearMarkerCue()
            coordinator.stop()
        }
    }

    private var currentSongSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let loadError = coordinator.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let snapshot = coordinator.currentWaveformSnapshot {
                LiveSetlistWaveformScrollView(
                    currentSnapshot: snapshot,
                    nextSnapshot: coordinator.nextWaveformSnapshot,
                    playbackDuration: audioEngine.duration,
                    cuedSectionID: cuedSectionID,
                    cueFlashPhase: cueFlashPhase,
                    onSeek: coordinator.seek,
                    onCueSection: cueSection
                )
            }

            TransportControls(
                audioEngine: audioEngine,
                isLoaded: coordinator.isLoaded,
                duration: audioEngine.duration,
                onPlay: coordinator.play,
                onPause: coordinator.pause,
                onStop: {
                    clearMarkerCue()
                    coordinator.stop()
                }
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 24) {
                Button {
                    coordinator.goToPreviousSong(autoPlay: audioEngine.isPlaying)
                } label: {
                    Label("Previous", systemImage: "backward.fill")
                }
                .disabled(coordinator.previousSong == nil)

                Spacer()

                Button {
                    coordinator.goToNextSong(autoPlay: audioEngine.isPlaying)
                } label: {
                    Label("Next", systemImage: "forward.fill")
                }
                .disabled(coordinator.nextSong == nil)
            }
            .buttonStyle(.bordered)
        }
    }

    private var setlistSection: some View {
        List {
            Section("Setlist") {
                ForEach(Array(coordinator.songs.enumerated()), id: \.element.id) { index, song in
                    SetlistPlaybackRow(
                        song: song,
                        index: index,
                        currentIndex: coordinator.currentIndex,
                        isPlaying: audioEngine.isPlaying
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.goToSong(at: index, autoPlay: audioEngine.isPlaying)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func clearMarkerCue(cancellingScheduledTransition: Bool = true) {
        if cancellingScheduledTransition, cuedSectionID != nil {
            coordinator.cancelScheduledSectionTransition()
        }
        cuedSectionID = nil
        cueFireTime = nil
        cueFlashPhase = false
    }

    private func cueSection(_ section: ArrangementDisplaySection) {
        if !audioEngine.isPlaying {
            clearMarkerCue()
            coordinator.seek(to: section.timelineStartSeconds)
            return
        }

        cuedSectionID = section.id
        cueFireTime = sectionCueFireTime(for: section)

        guard coordinator.isLoaded else { return }
        coordinator.scheduleSectionTransition(
            to: section.timelineStartSeconds,
            at: cueFireTime ?? section.timelineStartSeconds
        )
    }

    private func sectionCueFireTime(for cuedSection: ArrangementDisplaySection) -> TimeInterval {
        let sections = coordinator.currentWaveformSnapshot?.sections ?? []

        if let currentSection = sections.first(where: {
            audioEngine.currentTime >= $0.timelineStartSeconds
                && audioEngine.currentTime < $0.timelineEndSeconds
        }) {
            return currentSection.timelineEndSeconds
        }

        return sections
            .map(\.timelineEndSeconds)
            .first(where: { $0 > audioEngine.currentTime })
            ?? cuedSection.timelineEndSeconds
    }

    private func fireMarkerCue() {
        guard let cueFireTime, let cuedSectionID else { return }
        guard audioEngine.currentTime >= cueFireTime else { return }
        guard let section = coordinator.currentWaveformSnapshot?.sections.first(where: { $0.id == cuedSectionID }) else {
            clearMarkerCue(cancellingScheduledTransition: false)
            return
        }

        coordinator.snapToScheduledSection(section.timelineStartSeconds)
        clearMarkerCue(cancellingScheduledTransition: false)
    }
}

private struct SetlistPlaybackRow: View {
    let song: Song
    let index: Int
    let currentIndex: Int
    let isPlaying: Bool

    private var isFinished: Bool {
        index < currentIndex
    }

    private var isCurrent: Bool {
        index == currentIndex
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Text(song.name)
                .font(isCurrent ? .body.weight(.semibold) : .body)
                .foregroundStyle(isFinished ? .secondary : .primary)
                .lineLimit(2)

            Spacer()

            if isCurrent {
                PlayingBadge(isPlaying: isPlaying)
            } else if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .opacity(isFinished ? 0.55 : 1)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.08) : nil)
    }
}

private struct PlayingBadge: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.caption2)
            Text(isPlaying ? "Playing" : "Paused")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor)
        .clipShape(Capsule())
    }
}

#Preview {
    NavigationStack {
        LivePlaybackView(setlist: Setlist(name: "Sunday"))
    }
}
