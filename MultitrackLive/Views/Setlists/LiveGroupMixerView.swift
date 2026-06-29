import SwiftData
import SwiftUI

enum LiveGroupMixerDetent: Equatable {
    case hidden
    case visible

    static let heightFraction: CGFloat = 0.48

    func height(containerHeight: CGFloat) -> CGFloat {
        switch self {
        case .hidden:
            return 0
        case .visible:
            return containerHeight * Self.heightFraction
        }
    }
}

struct LiveGroupMixerPanel: View {
    let containerHeight: CGFloat
    let onMixChange: () -> Void

    private var panelHeight: CGFloat {
        containerHeight * LiveGroupMixerDetent.heightFraction
    }

    var body: some View {
        VStack(spacing: 0) {
            drawerHandle

            LiveGroupMixerView(onMixChange: onMixChange)
                .frame(maxHeight: .infinity)
        }
        .frame(height: panelHeight)
        .frame(maxWidth: .infinity)
        .background {
            drawerShape
                .fill(drawerBackgroundFill)
                .ignoresSafeArea(.all, edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var drawerHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var drawerBackgroundFill: some ShapeStyle {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 14,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 14,
            style: .continuous
        )
    }
}

struct LiveGroupMixerView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable private var audioEngine = AudioEngineManager.shared

    @Query(sort: [SortDescriptor(\TrackGroup.sortOrder), SortDescriptor(\TrackGroup.name)])
    private var groups: [TrackGroup]

    let onMixChange: () -> Void

    @State private var routingConfig: OutputRoutingConfig?

    private let stripWidth: CGFloat = 96

    var body: some View {
        GeometryReader { geometry in
            let contentHeight = geometry.size.height

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(groups) { group in
                        LiveGroupChannelStrip(
                            title: group.name,
                            meterLevel: audioEngine.groupMeterLevel(for: group.id),
                            volume: Binding(
                                get: { group.volume },
                                set: { group.volume = $0 }
                            ),
                            isMuted: Binding(
                                get: { group.isMuted },
                                set: { group.isMuted = $0 }
                            ),
                            stripHeight: contentHeight,
                            stripWidth: stripWidth,
                            onMixChange: onMixChange
                        )
                    }

                    if let routingConfig {
                        LiveGroupChannelStrip(
                            title: "No Group",
                            meterLevel: audioEngine.groupMeterLevel(for: nil),
                            volume: Binding(
                                get: { routingConfig.ungroupedVolume },
                                set: { routingConfig.ungroupedVolume = $0 }
                            ),
                            isMuted: Binding(
                                get: { routingConfig.ungroupedIsMuted },
                                set: { routingConfig.ungroupedIsMuted = $0 }
                            ),
                            stripHeight: contentHeight,
                            stripWidth: stripWidth,
                            onMixChange: onMixChange
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        }
        .safeAreaPadding(.bottom, 4)
        .onAppear {
            routingConfig = OutputRoutingStore.config(in: modelContext)
        }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            audioEngine.refreshGroupMeters()
        }
    }
}

private struct LiveGroupChannelStrip: View {
    let title: String
    let meterLevel: Float
    @Binding var volume: Double
    @Binding var isMuted: Bool
    let stripHeight: CGFloat
    let stripWidth: CGFloat
    let onMixChange: () -> Void

    private var controlsHeight: CGFloat { 20 + 6 + 36 }

    var body: some View {
        VStack(spacing: 6) {
            MixerFaderColumn(
                value: $volume,
                meterLevel: meterLevel,
                height: max(60, stripHeight - controlsHeight - 12),
                onValueChanged: onMixChange
            )

            TrackMixButton(
                label: "M",
                isActive: isMuted,
                activeColor: .dawMuteActive
            ) {
                isMuted.toggle()
                onMixChange()
            }

            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: stripWidth, alignment: .center)
                .frame(minHeight: 28)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .background(Color.dawMixButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: stripWidth, height: stripHeight, alignment: .top)
    }
}
