import SwiftUI

struct LiveSetlistNowPlayingInfoView: View {
    enum Section {
        case songInfo
        case transportAndPosition
    }

    let section: Section
    let coordinator: PlaybackCoordinator
    @Bindable var audioEngine: AudioEngineManager
    let isLoaded: Bool
    @Binding var infoPanelHeight: CGFloat
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void

    var body: some View {
        Group {
            if audioEngine.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                    sectionContent(at: audioEngine.livePlayheadTime())
                }
            } else {
                sectionContent(at: audioEngine.currentTime)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(at time: TimeInterval) -> some View {
        let snapshot = displaySnapshot(at: time)

        switch section {
        case .songInfo:
            infoContainer {
                songInfoGrid(snapshot: snapshot)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: InfoPanelHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(InfoPanelHeightPreferenceKey.self) { height in
                if height > 0 {
                    infoPanelHeight = height
                }
            }
        case .transportAndPosition:
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 12) {
                    transportButton(systemImage: "stop.fill", size: infoPanelHeight, action: onStop)
                    transportButton(
                        systemImage: audioEngine.isPlaying ? "pause.fill" : "play.fill",
                        size: infoPanelHeight,
                        action: audioEngine.isPlaying ? onPause : onPlay
                    )
                }

                infoContainer {
                    positionTimeGrid(snapshot: snapshot)
                }
            }
        }
    }

    private func songInfoGrid(snapshot: DisplaySnapshot) -> some View {
        Grid(alignment: .center, horizontalSpacing: 16) {
            GridRow(alignment: .center) {
                InfoFieldValue(snapshot.songTitle)
                InfoFieldValue(snapshot.bpm)
                InfoFieldValue(snapshot.meter)
                InfoFieldValue(snapshot.key)
            }
        }
    }

    private func positionTimeGrid(snapshot: DisplaySnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16) {
            GridRow(alignment: .center) {
                InfoFieldValue(snapshot.position)
                InfoFieldValue(snapshot.time)
            }
        }
    }

    private func infoContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func transportButton(
        systemImage: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: max(size, 1), height: max(size, 1))
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!isLoaded)
    }

    private func displaySnapshot(at time: TimeInterval) -> DisplaySnapshot {
        guard let song = coordinator.currentSong else {
            return DisplaySnapshot(
                position: "-",
                time: "-",
                songTitle: "-",
                bpm: "-",
                meter: "-",
                key: "-"
            )
        }

        let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
        let tempoChanges = projectState.tempoChanges
        let timeSignatureChanges = projectState.timeSignatureChanges
        let position = MeasureTiming.position(
            at: time,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )
        let measure = position.bar
        let signature = MeasureTiming.numeratorDenominatorForMeasure(
            measure,
            changes: timeSignatureChanges
        )
        let bpm = MeasureTiming.activeBPM(
            at: time,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )

        return DisplaySnapshot(
            position: MeasureTiming.formatPosition(position),
            time: MeasureTiming.formatElapsedTime(time),
            songTitle: song.name,
            bpm: String(format: "%.0f", bpm),
            meter: "\(signature.numerator)/\(signature.denominator)",
            key: "-"
        )
    }
}

private struct InfoPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DisplaySnapshot {
    let position: String
    let time: String
    let songTitle: String
    let bpm: String
    let meter: String
    let key: String
}

private struct InfoFieldValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title2.monospacedDigit().weight(.medium))
            .lineLimit(1)
    }
}
