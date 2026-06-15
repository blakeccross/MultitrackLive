import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TrackLaneHeaderView: View {
    @Bindable var track: AudioTrack
    let fileDuration: TimeInterval
    let laneHeight: CGFloat
    let groups: [TrackGroup]
    let onMixChange: () -> Void
    let onGroupChange: () -> Void
    let onManageGroups: () -> Void

    private var effectiveEnd: TimeInterval {
        track.trimEndSeconds ?? fileDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(track.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatTime(effectiveEnd - track.trimStartSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            groupPicker

            HStack(spacing: 6) {
                TrackMixButton(
                    label: "M",
                    isActive: track.isMuted,
                    activeColor: .dawMuteActive
                ) {
                    track.isMuted.toggle()
                    onMixChange()
                }

                TrackMixButton(
                    label: "S",
                    isActive: track.isSolo,
                    activeColor: .dawSoloActive
                ) {
                    track.isSolo.toggle()
                    onMixChange()
                }

                VStack(alignment: .leading, spacing: 4) {
                    TrackMixSliderRow(
                        label: "Vol",
                        valueLabel: String(format: "%.0f", track.volume * 100),
                        value: $track.volume,
                        range: 0...1,
                        onEditingEnded: onMixChange
                    )

                    TrackMixSliderRow(
                        label: "Pan",
                        valueLabel: panLabel,
                        value: $track.pan,
                        range: -1...1,
                        onEditingEnded: onMixChange
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: TimelineLayout.trackHeaderWidth, height: laneHeight, alignment: .topLeading)
        .background(Color.dawTrackHeaderBackground)
    }

    private var panLabel: String {
        if track.pan < -0.05 { return "L\(Int(abs(track.pan * 100)))" }
        if track.pan > 0.05 { return "R\(Int(track.pan * 100))" }
        return "C"
    }

    private var groupPicker: some View {
        Menu {
            Button("No Group") {
                track.group = nil
                onGroupChange()
            }

            ForEach(groups) { group in
                Button(group.name) {
                    track.group = group
                    onGroupChange()
                }
            }

            Divider()

            Button("Manage Groups…") {
                onManageGroups()
            }
        } label: {
            HStack(spacing: 4) {
                Text(track.group?.name ?? "No Group")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(track.group == nil ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.dawMixButtonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct TrackMixButton: View {
    let label: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 22, height: 20)
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.primary.opacity(0.75))
                .background(isActive ? activeColor : Color.dawMixButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.primary.opacity(isActive ? 0 : 0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct TrackMixSliderRow: View {
    let label: String
    let valueLabel: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingEnded: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            Slider(value: $value, in: range) { editing in
                if !editing {
                    onEditingEnded()
                }
            }
            .controlSize(.mini)

            Text(valueLabel)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

struct WaveformLaneView: View {
    @Bindable var track: AudioTrack

    let fileURL: URL
    let fileDuration: TimeInterval
    let timelineDuration: TimeInterval
    let timelineContentWidth: CGFloat
    let arrangementSections: [ArrangementDisplaySection]
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var selectedClip: SelectedArrangementClip?
    let markers: [ArrangementMarker]
    let laneHeight: CGFloat
    let onTrimChange: () -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void
    let loopSlotIDs: Set<UUID>
    let onToggleLoopSection: (ArrangementDisplaySection) -> Void
    let onClipTrimCommitted: () -> Void

    @State private var sourcePeaks: [Float] = []
    @State private var cachedDisplayPeaks: [Float] = []
    @State private var activeHandle: TrimHandle?
    @State private var dragStartTime: TimeInterval?
    @State private var activeClipTrim: ActiveClipTrim?
    @State private var clipTrimDragStart: ClipTrimDragStart?
    @State private var previewClipTrims: PreviewClipTrims?

    private struct ActiveClipTrim: Equatable {
        let slotID: UUID
        let edge: ArrangementClipTrimEdge
    }

    private struct ClipTrimDragStart: Equatable {
        let leadingTrim: TimeInterval
        let trailingTrim: TimeInterval
    }

    private struct PreviewClipTrims: Equatable {
        let slotID: UUID
        let leading: TimeInterval
        let trailing: TimeInterval
    }

    private enum ArrangementClipTrimEdge {
        case leading
        case trailing
    }

    private let clipEdgeHitWidth: CGFloat = 10

    private enum TrimHandle {
        case start
        case end
    }

    private var waveformDrawHeight: CGFloat {
        laneHeight
    }

    private var effectiveEnd: TimeInterval {
        track.trimEndSeconds ?? fileDuration
    }

    private var safeTimelineDuration: TimeInterval {
        max(timelineDuration, 0.001)
    }

    private var usesArrangementLayout: Bool {
        !arrangementSections.isEmpty
    }

    private var displayPeaksCacheKey: String {
        let sectionKey = arrangementSections
            .map { "\($0.id.uuidString)|\($0.timelineStartSeconds)|\($0.timelineEndSeconds)" }
            .joined(separator: ",")
        return "\(timelineContentWidth)|\(timelineDuration)|\(fileDuration)|\(sourcePeaks.count)|\(sectionKey)|\(usesArrangementLayout)"
    }

    private func refreshCachedDisplayPeaks() {
        if usesArrangementLayout {
            cachedDisplayPeaks = WaveformPeakResampler.arrangedDisplayPeaks(
                from: sourcePeaks,
                fileDuration: fileDuration,
                sections: arrangementSections,
                timelineDuration: safeTimelineDuration,
                contentWidth: timelineContentWidth
            )
        } else {
            cachedDisplayPeaks = WaveformPeakResampler.displayPeaks(
                from: sourcePeaks,
                contentWidth: timelineContentWidth
            )
        }
    }

    var body: some View {
        waveformArea
            .frame(width: timelineContentWidth, height: laneHeight)
            .background(Color.dawLaneBackground)
            .onAppear {
                hydratePeaksFromCache()
                refreshCachedDisplayPeaks()
            }
            .task(id: fileURL.path) {
                if let cached = WaveformCache.shared.cachedPeaks(for: fileURL) {
                    sourcePeaks = cached
                } else {
                    sourcePeaks = await WaveformCache.shared.peaks(for: fileURL)
                }
                refreshCachedDisplayPeaks()
            }
            .onChange(of: displayPeaksCacheKey) { _, _ in
                refreshCachedDisplayPeaks()
            }
    }

    private var clipBaselineRanges: [ClosedRange<CGFloat>] {
        if usesArrangementLayout {
            arrangementSections.map { section in
                let bounds = clipTimelineBounds(for: section)
                let startX = TimelineLayout.xPosition(
                    for: bounds.start,
                    duration: safeTimelineDuration,
                    contentWidth: timelineContentWidth
                )
                let endX = TimelineLayout.xPosition(
                    for: bounds.end,
                    duration: safeTimelineDuration,
                    contentWidth: timelineContentWidth
                )
                return startX...endX
            }
        } else {
            [trimStartX...trimEndX]
        }
    }

    private var waveformArea: some View {
        ZStack(alignment: .leading) {
            WaveformBarsCanvas(
                bars: cachedDisplayPeaks,
                showsEmptyBaseline: !usesArrangementLayout,
                baselineRanges: clipBaselineRanges
            )
                .equatable()

            if !usesArrangementLayout {
                trimOverlay
            }

            clipLayer
        }
        .frame(width: timelineContentWidth, height: waveformDrawHeight)
    }

    private var trimStartX: CGFloat {
        TimelineLayout.xPosition(
            for: track.trimStartSeconds,
            duration: safeTimelineDuration,
            contentWidth: timelineContentWidth
        )
    }

    private var trimEndX: CGFloat {
        TimelineLayout.xPosition(
            for: effectiveEnd,
            duration: safeTimelineDuration,
            contentWidth: timelineContentWidth
        )
    }

    private var trimOverlay: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, trimStartX))
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, timelineContentWidth - trimEndX))
        }
    }

    private var clipLayer: some View {
        ZStack(alignment: .leading) {
            if usesArrangementLayout {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedClip?.trackID == track.id {
                            selectedClip = nil
                        }
                    }

                ForEach(arrangementSections) { section in
                    arrangementClip(for: section)
                }
            } else {
                sourceTrackClip
            }
        }
    }

    private var sourceTrackClip: some View {
        let clipWidth = max(0, trimEndX - trimStartX)
        let isSelected = selectedClip == SelectedArrangementClip(slotID: track.id, trackID: track.id)

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.dawClipBackgroundSelected : Color.dawClipBackground)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedClip = SelectedArrangementClip(slotID: track.id, trackID: track.id)
                }

            if isSelected {
                Rectangle()
                    .stroke(Color.dawClipBorder, lineWidth: 2)
            }

            trimHandle(at: trimStartX, handle: .start)
            trimHandle(at: trimEndX, handle: .end)
        }
        .frame(width: clipWidth, height: laneHeight)
        .overlay { ClipSideBorders() }
        .offset(x: trimStartX)
    }

    @ViewBuilder
    private func arrangementClip(for section: ArrangementDisplaySection) -> some View {
        let bounds = clipTimelineBounds(for: section)
        let startX = TimelineLayout.xPosition(
            for: bounds.start,
            duration: safeTimelineDuration,
            contentWidth: timelineContentWidth
        )
        let endX = TimelineLayout.xPosition(
            for: bounds.end,
            duration: safeTimelineDuration,
            contentWidth: timelineContentWidth
        )
        let clipWidth = max(0, endX - startX)
        let isSelected = selectedClip == SelectedArrangementClip(
            slotID: section.id,
            trackID: track.id
        )

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.dawClipBackgroundSelected : Color.dawClipBackground)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedClip = SelectedArrangementClip(slotID: section.id, trackID: track.id)
                }
                .contextMenu {
                    Button("Cue Section") {
                        onCueSection(section)
                    }
                    if loopSlotIDs.contains(section.id) {
                        Button("Remove Loop") {
                            onToggleLoopSection(section)
                        }
                    } else {
                        Button("Loop Section") {
                            onToggleLoopSection(section)
                        }
                    }
                }

            if isSelected {
                Rectangle()
                    .stroke(Color.dawClipBorder, lineWidth: 2)
            }

            clipTrimHandle(section: section, edge: .leading, clipWidth: clipWidth, isSelected: isSelected)
            clipTrimHandle(section: section, edge: .trailing, clipWidth: clipWidth, isSelected: isSelected)
        }
        .frame(width: clipWidth, height: laneHeight)
        .overlay { ClipSideBorders() }
        .offset(x: startX)
    }

    private func clipTrimHandle(
        section: ArrangementDisplaySection,
        edge: ArrangementClipTrimEdge,
        clipWidth: CGFloat,
        isSelected: Bool
    ) -> some View {
        let handleWidth = min(clipEdgeHitWidth, max(4, clipWidth / 3))

        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: handleWidth, height: laneHeight)
            .overlay(alignment: edge == .leading ? .leading : .trailing) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.dawClipBorder.opacity(isClipTrimActive(sectionID: section.id, edge: edge) ? 1 : 0.85))
                    .frame(width: 3, height: laneHeight * 0.55)
                    .padding(.horizontal, 1)
                    .opacity(isSelected || isClipTrimActive(sectionID: section.id, edge: edge) ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            .gesture(clipTrimDragGesture(for: section, edge: edge, clipWidth: clipWidth))
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

    private func clipTrimDragGesture(
        for section: ArrangementDisplaySection,
        edge: ArrangementClipTrimEdge,
        clipWidth: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if activeClipTrim?.slotID != section.id || activeClipTrim?.edge != edge {
                    activeClipTrim = ActiveClipTrim(slotID: section.id, edge: edge)
                    let current = SongArrangementStore.trims(
                        slotID: section.id,
                        trackID: track.id,
                        in: clipTrims
                    )
                    clipTrimDragStart = ClipTrimDragStart(
                        leadingTrim: current.leading,
                        trailingTrim: current.trailing
                    )
                }

                guard let clipTrimDragStart,
                      let slot = arrangementSlots.first(where: { $0.id == section.id }),
                      let marker = markers.first(where: { $0.id == slot.markerID }),
                      clipWidth > 0,
                      section.duration > 0 else { return }

                let deltaSource = TimeInterval(value.translation.width / clipWidth) * section.duration
                var leading = clipTrimDragStart.leadingTrim
                var trailing = clipTrimDragStart.trailingTrim

                switch edge {
                case .leading:
                    leading += deltaSource
                case .trailing:
                    trailing -= deltaSource
                }

                let clamped: (leading: TimeInterval, trailing: TimeInterval) = {
                    var draftTrims = clipTrims
                    SongArrangementStore.setTrims(
                        slotID: section.id,
                        trackID: track.id,
                        leading: leading,
                        trailing: trailing,
                        in: &draftTrims
                    )
                    return SongArrangementStore.clampedTrims(
                        slotID: section.id,
                        trackID: track.id,
                        marker: marker,
                        markers: markers,
                        clipTrims: draftTrims,
                        sourceDuration: fileDuration
                    )
                }()
                previewClipTrims = PreviewClipTrims(
                    slotID: section.id,
                    leading: clamped.leading,
                    trailing: clamped.trailing
                )
            }
            .onEnded { _ in
                defer {
                    activeClipTrim = nil
                    clipTrimDragStart = nil
                    previewClipTrims = nil
                }

                guard let previewClipTrims, previewClipTrims.slotID == section.id else { return }

                SongArrangementStore.setTrims(
                    slotID: section.id,
                    trackID: track.id,
                    leading: previewClipTrims.leading,
                    trailing: previewClipTrims.trailing,
                    in: &clipTrims
                )
                onClipTrimCommitted()
            }
    }

    private func clipTimelineBounds(for section: ArrangementDisplaySection) -> (start: TimeInterval, end: TimeInterval) {
        guard let previewClipTrims, previewClipTrims.slotID == section.id else {
            return (section.timelineStartSeconds, section.timelineEndSeconds)
        }

        let committed = SongArrangementStore.trims(
            slotID: section.id,
            trackID: track.id,
            in: clipTrims
        )
        let trackUntrimmedDuration = section.timelineEndSeconds
            + committed.trailing
            - section.columnStartSeconds

        return (
            section.columnStartSeconds + previewClipTrims.leading,
            section.columnStartSeconds + trackUntrimmedDuration - previewClipTrims.trailing
        )
    }

    private func isClipTrimActive(sectionID: UUID, edge: ArrangementClipTrimEdge) -> Bool {
        activeClipTrim?.slotID == sectionID && activeClipTrim?.edge == edge
    }

    private func hydratePeaksFromCache() {
        if let cached = WaveformCache.shared.cachedPeaks(for: fileURL) {
            sourcePeaks = cached
        }
    }

    private func trimHandle(at x: CGFloat, handle: TrimHandle) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(handle == activeHandle ? Color.dawClipBorder : Color.dawClipBorder.opacity(0.85))
            .frame(width: 8, height: laneHeight - 8)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 2, height: (laneHeight - 8) * 0.35)
            }
            .offset(x: x - 4, y: 4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        activeHandle = handle
                        if dragStartTime == nil {
                            dragStartTime = handle == .start ? track.trimStartSeconds : effectiveEnd
                        }
                        guard let dragStartTime else { return }
                        let deltaTime = TimeInterval(value.translation.width / timelineContentWidth) * safeTimelineDuration
                        applyTrimTime(handle: handle, time: dragStartTime + deltaTime)
                    }
                    .onEnded { _ in
                        activeHandle = nil
                        dragStartTime = nil
                        onTrimChange()
                    }
            )
    }

    private func applyTrimTime(handle: TrimHandle, time: TimeInterval) {
        let minGap: TimeInterval = 0.1

        switch handle {
        case .start:
            let maxStart = effectiveEnd - minGap
            track.trimStartSeconds = min(max(0, time), maxStart)
        case .end:
            let minEnd = track.trimStartSeconds + minGap
            track.trimEndSeconds = min(max(minEnd, time), fileDuration)
        }
    }
}

private struct ClipSideBorders: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.dawClipSideBorder)
                .frame(width: 1)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.dawClipSideBorder)
                .frame(width: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct WaveformBarsCanvas: View, Equatable {
    let bars: [Float]
    var showsEmptyBaseline = true
    var baselineRanges: [ClosedRange<CGFloat>] = []

    private let minBarHeight: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            drawWaveform(in: &context, size: size)
        }
        .drawingGroup()
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let fillColor = Color.dawWaveformFill

        if !bars.isEmpty {
            let barWidth = size.width / CGFloat(bars.count)
            let maxBarHeight = midY * 0.92

            if baselineRanges.isEmpty {
                drawFilledWaveformSegment(
                    in: &context,
                    range: 0...(size.width),
                    bars: bars,
                    barWidth: barWidth,
                    midY: midY,
                    maxBarHeight: maxBarHeight,
                    fillColor: fillColor
                )
            } else {
                for range in baselineRanges {
                    drawFilledWaveformSegment(
                        in: &context,
                        range: range,
                        bars: bars,
                        barWidth: barWidth,
                        midY: midY,
                        maxBarHeight: maxBarHeight,
                        fillColor: fillColor
                    )
                }
            }
        } else if showsEmptyBaseline {
            let ranges = baselineRanges.isEmpty ? [0...(size.width)] : baselineRanges
            for range in ranges {
                let startX = max(0, range.lowerBound)
                let endX = min(size.width, range.upperBound)
                drawSilentSegment(in: &context, startX: startX, endX: endX, midY: midY, fillColor: fillColor)
            }
        }
    }

    private func drawFilledWaveformSegment(
        in context: inout GraphicsContext,
        range: ClosedRange<CGFloat>,
        bars: [Float],
        barWidth: CGFloat,
        midY: CGFloat,
        maxBarHeight: CGFloat,
        fillColor: Color
    ) {
        let startX = max(0, range.lowerBound)
        let endX = min(range.upperBound, CGFloat(bars.count) * barWidth)
        guard endX > startX else { return }

        let startIndex = max(0, Int(floor(startX / barWidth)))
        let endIndex = min(bars.count - 1, Int(floor((endX - 0.001) / barWidth)))
        guard startIndex <= endIndex else {
            drawSilentSegment(in: &context, startX: startX, endX: endX, midY: midY, fillColor: fillColor)
            return
        }

        func barHeight(at index: Int) -> CGFloat {
            max(minBarHeight, CGFloat(bars[index]) * maxBarHeight)
        }

        func barCenterX(at index: Int) -> CGFloat {
            CGFloat(index) * barWidth + barWidth * 0.5
        }

        var path = Path()
        path.move(to: CGPoint(x: startX, y: midY))

        for index in startIndex...endIndex {
            path.addLine(to: CGPoint(x: barCenterX(at: index), y: midY - barHeight(at: index)))
        }

        path.addLine(to: CGPoint(x: endX, y: midY))

        for index in stride(from: endIndex, through: startIndex, by: -1) {
            path.addLine(to: CGPoint(x: barCenterX(at: index), y: midY + barHeight(at: index)))
        }

        path.addLine(to: CGPoint(x: startX, y: midY))
        path.closeSubpath()
        context.fill(path, with: .color(fillColor))
    }

    private func drawSilentSegment(
        in context: inout GraphicsContext,
        startX: CGFloat,
        endX: CGFloat,
        midY: CGFloat,
        fillColor: Color
    ) {
        guard endX > startX else { return }

        let rect = CGRect(x: startX, y: midY - minBarHeight, width: endX - startX, height: minBarHeight * 2)
        context.fill(Path(rect), with: .color(fillColor))
    }
}
