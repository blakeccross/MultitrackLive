import SwiftData
import SwiftUI

enum LiveGroupMixerDetent: Equatable {
    case hidden
    case visible

    static let heightFraction: CGFloat = 0.48
    static let minimumMixerHeight: CGFloat = 140
    static let minimumMainHeight: CGFloat = 200
}

enum LivePlaybackSidebarMetrics {
    static let sidebarWidth: CGFloat = 300
}

struct LivePlaybackSidebarLayout<Sidebar: View, MainContent: View>: View {
    @Binding var isVisible: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let mainContent: () -> MainContent

    var body: some View {
        HStack(spacing: 0) {
            if isVisible {
                sidebar()
                    .frame(width: LivePlaybackSidebarMetrics.sidebarWidth)
                    .transition(.move(edge: .leading))

                Divider()
            }

            mainContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: isVisible)
    }
}

struct LivePlaybackMixerSplitLayout<MainContent: View>: View {
    @Binding var mixerDetent: LiveGroupMixerDetent
    let onMixChange: () -> Void
    @ViewBuilder let mainContent: () -> MainContent

    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        iOSLayout
        #endif
    }

    #if os(macOS)
    private var macOSLayout: some View {
        GeometryReader { geometry in
            if mixerDetent == .visible {
                VSplitView {
                    mainContent()
                        .frame(minHeight: LiveGroupMixerDetent.minimumMainHeight)

                    LiveGroupMixerPanel(onMixChange: onMixChange)
                        .frame(
                            minHeight: LiveGroupMixerDetent.minimumMixerHeight,
                            idealHeight: geometry.size.height * LiveGroupMixerDetent.heightFraction
                        )
                }
            } else {
                mainContent()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mixerDetent)
    }
    #endif

    private var iOSLayout: some View {
        GeometryReader { geometry in
            mainContent()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if mixerDetent == .visible {
                        LiveGroupMixerPanel(onMixChange: onMixChange)
                            .frame(height: geometry.size.height * LiveGroupMixerDetent.heightFraction)
                    }
                }
        }
        .animation(.easeInOut(duration: 0.2), value: mixerDetent)
    }
}

struct LiveGroupMixerPanel: View {
    let onMixChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            drawerHandle
            #endif

            LiveGroupMixerView(onMixChange: onMixChange)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            #if os(iOS)
            drawerShape
                .fill(Color(uiColor: .systemBackground))
                .ignoresSafeArea(.all, edges: .bottom)
            #else
            Color(nsColor: .windowBackgroundColor)
            #endif
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }

    #if os(iOS)
    private var drawerHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }
    #endif

    #if os(iOS)
    private var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 14,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 14,
            style: .continuous
        )
    }
    #endif
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
