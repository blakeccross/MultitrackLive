import SwiftData
import SwiftUI

struct MixView: View {
    @Environment(\.modelContext) private var modelContext

    let song: Song
    let viewModel: SongEditorViewModel

    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 16) {
                TransportControls(
                    audioEngine: audioEngine,
                    isLoaded: viewModel.isLoaded,
                    duration: audioEngine.duration,
                    onPlay: viewModel.play,
                    onPause: viewModel.pause,
                    onStop: viewModel.stop
                )

                if let loadError = viewModel.loadError {
                    ContentUnavailableView("Cannot Preview", systemImage: "exclamationmark.triangle", description: Text(loadError))
                        .frame(maxHeight: 200)
                } else if song.sortedTracks.isEmpty {
                    ContentUnavailableView("No Tracks", systemImage: "waveform", description: Text("Import stems to start mixing."))
                        .frame(maxHeight: 200)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .bottom, spacing: 1) {
                            ForEach(song.sortedTracks) { track in
                                MixerStripView(track: track) {
                                    viewModel.updateMix(for: track, context: modelContext)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.dawLaneBackground)
                }

                Button("Add More Tracks") {
                    showingImporter = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .sheet(isPresented: $showingImporter) {
            TrackImportView(song: song) { _ in
                viewModel.loadSong()
            }
        }
    }
}

private struct MixerStripView: View {
    @Bindable var track: AudioTrack
    let onChange: () -> Void

    private let stripWidth: CGFloat = 64
    private let faderHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 8) {
            Text(track.displayName)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: stripWidth)

            VerticalVolumeFader(value: $track.volume, onEditingEnded: onChange)
                .frame(width: 24, height: faderHeight)

            HStack(spacing: 4) {
                MixerStripButton(
                    label: "M",
                    isActive: track.isMuted,
                    activeColor: .dawMuteActive
                ) {
                    track.isMuted.toggle()
                    onChange()
                }

                MixerStripButton(
                    label: "S",
                    isActive: track.isSolo,
                    activeColor: .dawSoloActive
                ) {
                    track.isSolo.toggle()
                    onChange()
                }
            }

            Slider(value: $track.pan, in: -1...1) { editing in
                if !editing { onChange() }
            }
            .controlSize(.mini)
            .frame(width: stripWidth)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(width: stripWidth + 12)
        .background(Color.dawTrackHeaderBackground)
    }
}

private struct MixerStripButton: View {
    let label: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 26, height: 22)
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.primary.opacity(0.75))
                .background(isActive ? activeColor : Color.dawMixButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

private struct VerticalVolumeFader: View {
    @Binding var value: Double
    let onEditingEnded: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Slider(value: $value, in: 0...1) { editing in
                if !editing {
                    onEditingEnded()
                }
            }
            .rotationEffect(.degrees(-90))
            .frame(width: geometry.size.height, height: 32)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

struct TransportControls: View {
    @Bindable var audioEngine: AudioEngineManager
    let isLoaded: Bool
    let duration: TimeInterval
    let onPlay: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .disabled(!isLoaded)

                Button(action: audioEngine.isPlaying ? onPause : onPlay) {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .disabled(!isLoaded)
            }

            TransportElapsedTimeLabel(audioEngine: audioEngine, duration: duration)
        }
    }
}

#Preview {
    MixView(song: Song(name: "Preview"), viewModel: SongEditorViewModel(song: Song(name: "Preview")))
}
