import SwiftUI

struct LiveSetlistNowPlayingInfoView: View {
    let coordinator: PlaybackCoordinator
    @Bindable var audioEngine: AudioEngineManager
    let isLoaded: Bool
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void

    @State private var infoPanelHeight: CGFloat = 0

    var body: some View {
        Group {
            if audioEngine.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                    infoContent(at: audioEngine.livePlayheadTime())
                }
            } else {
                infoContent(at: audioEngine.currentTime)
            }
        }
    }

    private func infoContent(at time: TimeInterval) -> some View {
        let snapshot = displaySnapshot(at: time)

        return HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 12) {
                transportButton(systemImage: "stop.fill", size: infoPanelHeight, action: onStop)
                transportButton(
                    systemImage: audioEngine.isPlaying ? "pause.fill" : "play.fill",
                    size: infoPanelHeight,
                    action: audioEngine.isPlaying ? onPause : onPlay
                )
            }

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

            infoContainer {
                positionTimeGrid(snapshot: snapshot)
            }
        }
        .onPreferenceChange(InfoPanelHeightPreferenceKey.self) { height in
            if height > 0 {
                infoPanelHeight = height
            }
        }
    }

    private func songInfoGrid(snapshot: DisplaySnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow(alignment: .top) {
                InfoFieldLabel("Current Song")
                InfoFieldLabel("BPM")
                InfoFieldLabel("Meter")
                InfoFieldLabel("Key")
            }

            GridRow(alignment: .center) {
                Text(snapshot.songTitle)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)

                InfoFieldValue(snapshot.bpm)
                InfoFieldValue(snapshot.meter)
                InfoFieldValue(snapshot.key)
            }
        }
    }

    private func positionTimeGrid(snapshot: DisplaySnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow(alignment: .top) {
                InfoFieldLabel("Position")
                InfoFieldLabel("Time")
            }

            GridRow(alignment: .center) {
                InfoFieldValueCell(snapshot.position)
                InfoFieldValueCell(snapshot.time)
            }
        }
    }

    private func infoContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxHeight: .infinity, alignment: .top)
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

        let tempoChanges = TempoStore.loadOrMigrate(for: song)
        let timeSignatureChanges = TimeSignatureStore.loadOrMigrate(for: song, tempoChanges: tempoChanges)
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

private struct InfoField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            InfoFieldLabel(label)
            InfoFieldValue(value)
        }
    }
}

private struct InfoFieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium).monospaced())
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
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

private struct InfoFieldValueCell: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        ZStack {
            Text(" ")
                .font(.largeTitle.weight(.semibold))
                .hidden()

            InfoFieldValue(text)
        }
    }
}
