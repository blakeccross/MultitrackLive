import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum LiveGroupMixerDetent: Equatable {
    case hidden
    case visible

    static let heightFraction: CGFloat = 0.48
    static let minimumMixerHeight: CGFloat = 140
    static let minimumMainHeight: CGFloat = 200
}

enum LivePlaybackSidebarMetrics {
    static let appStorageKey = "livePlaybackSidebarWidth"
    static let defaultSidebarWidth: CGFloat = 300
    static let defaultSidebarWidthStorageValue = Double(defaultSidebarWidth)
    static let minimumSidebarWidth: CGFloat = 240
    static let maximumSidebarWidth: CGFloat = 520
    static let minimumMainWidth: CGFloat = 280
    static let resizeHitAreaWidth: CGFloat = 10
    private static let resizeAdjustmentStep: CGFloat = 16

    static func clampedSidebarWidth(_ width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let availableMaximum = max(minimumSidebarWidth, totalWidth - minimumMainWidth)
        let cappedMaximum = min(maximumSidebarWidth, availableMaximum)
        return min(cappedMaximum, max(minimumSidebarWidth, width))
    }

    static func sidebarWidth(fromStorage value: Double, totalWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        clampedSidebarWidth(CGFloat(value), totalWidth: totalWidth)
    }

    static func storageValue(forWidth width: CGFloat, totalWidth: CGFloat = .greatestFiniteMagnitude) -> Double {
        Double(clampedSidebarWidth(width, totalWidth: totalWidth))
    }

    static func adjustedSidebarWidth(_ width: CGFloat, direction: AccessibilityAdjustmentDirection, totalWidth: CGFloat) -> CGFloat {
        let delta: CGFloat
        switch direction {
        case .increment:
            delta = resizeAdjustmentStep
        case .decrement:
            delta = -resizeAdjustmentStep
        @unknown default:
            delta = 0
        }
        return clampedSidebarWidth(width + delta, totalWidth: totalWidth)
    }
}

private struct LivePlaybackSidebarResizeHandle: View {
    @Binding var width: CGFloat
    let totalWidth: CGFloat
    let onResizeEnded: () -> Void

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: LivePlaybackSidebarMetrics.resizeHitAreaWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }
                    let proposed = (dragStartWidth ?? width) + value.translation.width
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        width = LivePlaybackSidebarMetrics.clampedSidebarWidth(proposed, totalWidth: totalWidth)
                    }
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    onResizeEnded()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Song library width")
        .accessibilityValue("\(Int(LivePlaybackSidebarMetrics.clampedSidebarWidth(width, totalWidth: totalWidth))) points")
        .accessibilityAdjustableAction { direction in
            width = LivePlaybackSidebarMetrics.adjustedSidebarWidth(width, direction: direction, totalWidth: totalWidth)
            onResizeEnded()
        }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.resizeLeftRight.push()
            case .ended:
                NSCursor.pop()
            }
        }
        #endif
    }
}

struct LivePlaybackSidebarLayout<Sidebar: View, MainContent: View>: View {
    @Binding var isVisible: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let mainContent: () -> MainContent

    @AppStorage(LivePlaybackSidebarMetrics.appStorageKey)
    private var storedSidebarWidth = LivePlaybackSidebarMetrics.defaultSidebarWidthStorageValue

    @State private var sidebarWidth = LivePlaybackSidebarMetrics.defaultSidebarWidth

    var body: some View {
        GeometryReader { geometry in
            let clampedWidth = LivePlaybackSidebarMetrics.clampedSidebarWidth(
                sidebarWidth,
                totalWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                if isVisible {
                    sidebar()
                        .frame(width: clampedWidth)
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))

                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(width: 0.5)
                }

                mainContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) {
                if isVisible {
                    LivePlaybackSidebarResizeHandle(
                        width: $sidebarWidth,
                        totalWidth: geometry.size.width,
                        onResizeEnded: {
                            persistSidebarWidth(totalWidth: geometry.size.width)
                        }
                    )
                    .offset(
                        x: clampedWidth + 0.25 - (LivePlaybackSidebarMetrics.resizeHitAreaWidth / 2)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .onChange(of: geometry.size.width) { _, newWidth in
                let clamped = LivePlaybackSidebarMetrics.clampedSidebarWidth(sidebarWidth, totalWidth: newWidth)
                guard clamped != sidebarWidth else { return }
                sidebarWidth = clamped
                persistSidebarWidth(totalWidth: newWidth)
            }
        }
        .animation(AppAnimation.springSmooth, value: isVisible)
        .animation(.none, value: sidebarWidth)
        .onAppear {
            sidebarWidth = LivePlaybackSidebarMetrics.sidebarWidth(fromStorage: storedSidebarWidth)
        }
    }

    private func persistSidebarWidth(totalWidth: CGFloat) {
        storedSidebarWidth = LivePlaybackSidebarMetrics.storageValue(
            forWidth: sidebarWidth,
            totalWidth: totalWidth
        )
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
        .animation(AppAnimation.fadeQuick, value: mixerDetent)
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
        .animation(AppAnimation.fadeQuick, value: mixerDetent)
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
                .fill(AppColors.backgroundSecondary)
                .ignoresSafeArea(.all, edges: .bottom)
            #else
            AppColors.backgroundSecondary
            #endif
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColors.separator)
                .frame(height: 0.5)
        }
    }

    #if os(iOS)
    private var drawerHandle: some View {
        Capsule()
            .fill(AppColors.textTertiary.opacity(0.6))
            .frame(width: 40, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }
    #endif

    #if os(iOS)
    private var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: AppRadius.lg,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: AppRadius.lg,
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
            let stripHeight = geometry.size.height - AppSpacing.xs - AppSpacing.sm

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppSpacing.sm) {
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
                            stripHeight: stripHeight,
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
                            stripHeight: stripHeight,
                            stripWidth: stripWidth,
                            onMixChange: onMixChange
                        )
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.xs)
                .padding(.bottom, AppSpacing.sm)
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

    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            GeometryReader { geometry in
                MixerFaderColumn(
                    value: $volume,
                    meterLevel: meterLevel,
                    height: max(60, geometry.size.height),
                    onValueChanged: onMixChange
                )
            }
            .frame(minHeight: 60)

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
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: stripWidth, alignment: .center)
                .frame(minHeight: 28)
        }
        .padding(AppSpacing.sm)
    }
}
