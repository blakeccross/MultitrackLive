import SwiftUI

struct TransportStatusSnapshot {
    let position: String
    let bpm: String
    let meter: String
    let key: String
}

struct SharedTransportStrip<BPMPopover: View, MeterPopover: View>: View {
    let snapshot: TransportStatusSnapshot
    let buttonSize: CGFloat
    let isPlaying: Bool
    let isLoaded: Bool
    let isLooping: Bool
    let canLoop: Bool
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onToggleLoop: () -> Void
    var onReadoutHeightChange: ((CGFloat) -> Void)? = nil
    var isFollowing: Bool? = nil
    var onToggleFollow: (() -> Void)? = nil

    @Binding private var showingBPMPopover: Bool
    @Binding private var showingMeterPopover: Bool
    private let bpmPopover: () -> BPMPopover
    private let meterPopover: () -> MeterPopover
    private let showsBPMPopover: Bool
    private let showsMeterPopover: Bool

    private var transportActiveGreen: Color { Color(red: 0.49, green: 0.75, blue: 0.48) }

    init(
        snapshot: TransportStatusSnapshot,
        buttonSize: CGFloat,
        isPlaying: Bool,
        isLoaded: Bool,
        isLooping: Bool,
        canLoop: Bool,
        onStop: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onToggleLoop: @escaping () -> Void,
        onReadoutHeightChange: ((CGFloat) -> Void)? = nil,
        isFollowing: Bool? = nil,
        onToggleFollow: (() -> Void)? = nil,
        showingBPMPopover: Binding<Bool> = .constant(false),
        showingMeterPopover: Binding<Bool> = .constant(false),
        @ViewBuilder bpmPopover: @escaping () -> BPMPopover,
        @ViewBuilder meterPopover: @escaping () -> MeterPopover
    ) {
        self.snapshot = snapshot
        self.buttonSize = buttonSize
        self.isPlaying = isPlaying
        self.isLoaded = isLoaded
        self.isLooping = isLooping
        self.canLoop = canLoop
        self.onStop = onStop
        self.onPlay = onPlay
        self.onPause = onPause
        self.onToggleLoop = onToggleLoop
        self.onReadoutHeightChange = onReadoutHeightChange
        self.isFollowing = isFollowing
        self.onToggleFollow = onToggleFollow
        _showingBPMPopover = showingBPMPopover
        _showingMeterPopover = showingMeterPopover
        self.bpmPopover = bpmPopover
        self.meterPopover = meterPopover
        self.showsBPMPopover = BPMPopover.self != EmptyView.self
        self.showsMeterPopover = MeterPopover.self != EmptyView.self
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            if let isFollowing, let onToggleFollow {
                Button(action: onToggleFollow) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: buttonSize * 0.38, weight: .semibold))
                        .foregroundStyle(
                            isFollowing
                                ? Color.white
                                : Color(red: 0.78, green: 0.80, blue: 0.82)
                        )
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isLoaded)
                .opacity(isLoaded ? 1 : 0.4)
                .accessibilityLabel(
                    isFollowing ? "Stop Following Playhead" : "Follow Playhead"
                )
            }

            transportMetadata

            HStack(spacing: 0) {
                AppIconButton(
                    systemImage: "stop.fill",
                    size: buttonSize,
                    isEnabled: isLoaded,
                    accessibilityLabel: "Stop"
                ) {
                    onStop()
                }

                AppIconButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    size: buttonSize,
                    isActive: isPlaying,
                    isEnabled: isLoaded,
                    cornerRadius: buttonSize * 0.14,
                    activeBackgroundColor: transportActiveGreen,
                    accessibilityLabel: isPlaying ? "Pause" : "Play"
                ) {
                    if isPlaying {
                        onPause()
                    } else {
                        onPlay()
                    }
                }

                AppIconButton(
                    systemImage: "repeat",
                    size: buttonSize,
                    isActive: isLooping,
                    isEnabled: isLoaded && canLoop,
                    cornerRadius: buttonSize * 0.14,
                    accessibilityLabel: isLooping ? "End Loop" : "Loop Section"
                ) {
                    onToggleLoop()
                }
            }
            .padding(.horizontal, 3)
            .frame(height: buttonSize)
            .background {
                RoundedRectangle(cornerRadius: buttonSize * 0.16, style: .continuous)
                    .fill(Color.black.opacity(0.30))
                    .overlay {
                        RoundedRectangle(cornerRadius: buttonSize * 0.16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.5)
                    }
            }

            TransportStatusReadout(position: snapshot.position)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: SharedTransportReadoutHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .onPreferenceChange(SharedTransportReadoutHeightPreferenceKey.self) { height in
                    guard height > 0 else { return }
                    onReadoutHeightChange?(height)
                }
        }
    }

    private var transportMetadata: some View {
        HStack(spacing: AppSpacing.sm) {
            Group {
                if showsBPMPopover {
                    Button {
                        showingBPMPopover = true
                    } label: {
                        metadataText(snapshot.bpm)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingBPMPopover, arrowEdge: .bottom) {
                        bpmPopover()
                    }
                } else {
                    metadataText(snapshot.bpm)
                }
            }
            .accessibilityLabel("Tempo \(snapshot.bpm)")

            metadataDivider

            Group {
                if showsMeterPopover {
                    Button {
                        showingMeterPopover = true
                    } label: {
                        metadataText(snapshot.meter)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingMeterPopover, arrowEdge: .bottom) {
                        meterPopover()
                    }
                } else {
                    metadataText(snapshot.meter)
                }
            }
            .accessibilityLabel("Time signature \(snapshot.meter)")

            metadataDivider

            metadataText(snapshot.key)
                .accessibilityLabel("Key \(snapshot.key)")
        }
        .fixedSize()
    }

    private func metadataText(_ value: String) -> some View {
        Text(value)
            .font(AppTypography.monoValue())
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var metadataDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 0.5, height: 12)
            .accessibilityHidden(true)
    }
}

extension SharedTransportStrip where BPMPopover == EmptyView, MeterPopover == EmptyView {
    init(
        snapshot: TransportStatusSnapshot,
        buttonSize: CGFloat,
        isPlaying: Bool,
        isLoaded: Bool,
        isLooping: Bool,
        canLoop: Bool,
        onStop: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onToggleLoop: @escaping () -> Void,
        onReadoutHeightChange: ((CGFloat) -> Void)? = nil,
        isFollowing: Bool? = nil,
        onToggleFollow: (() -> Void)? = nil
    ) {
        self.init(
            snapshot: snapshot,
            buttonSize: buttonSize,
            isPlaying: isPlaying,
            isLoaded: isLoaded,
            isLooping: isLooping,
            canLoop: canLoop,
            onStop: onStop,
            onPlay: onPlay,
            onPause: onPause,
            onToggleLoop: onToggleLoop,
            onReadoutHeightChange: onReadoutHeightChange,
            isFollowing: isFollowing,
            onToggleFollow: onToggleFollow,
            showingBPMPopover: .constant(false),
            showingMeterPopover: .constant(false),
            bpmPopover: { EmptyView() },
            meterPopover: { EmptyView() }
        )
    }
}

private struct SharedTransportReadoutHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
