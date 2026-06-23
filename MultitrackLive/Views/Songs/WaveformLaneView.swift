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
    private enum TimelineDragSpace {
        static let name = "waveformLaneTimeline"
    }

    @Bindable var track: AudioTrack

    let fileURL: URL
    let fileDuration: TimeInterval
    let timelineDuration: TimeInterval
    let timelineContentWidth: CGFloat
    let arrangementSections: [ArrangementDisplaySection]
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var clipGaps: [ArrangementClipGap]
    @Binding var clipRegions: [ClipRegion]
    @Binding var clipSelection: TimelineClipSelection?
    let markers: [ArrangementMarker]
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let laneHeight: CGFloat
    let trackColorIndex: Int
    let onTrimChange: () -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void
    let loopSlotIDs: Set<UUID>
    let onToggleLoopSection: (ArrangementDisplaySection) -> Void
    let onClipTrimCommitted: () -> Void
    let onSeek: (TimeInterval) -> Void

    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var sourcePeaks: [Float] = []
    @State private var cachedDisplayPeaks: [Float] = []
    @State private var activeHandle: TrimHandle?
    @State private var activeClipTrim: ActiveClipTrim?
    @State private var clipTrimDragStart: ClipTrimDragStart?
    @State private var previewClipTrims: PreviewClipTrims?
    @State private var activeClipRegionTrim: (regionID: UUID, edge: ClipRegionStore.RegionTrimEdge)?
    @State private var clipRegionTrimBaseline: ClipRegion?
    @State private var previewClipRegion: ClipRegion?
    @State private var activeClipDragSelection: ClipDragSelection?

    private struct ClipDragSelection: Equatable {
        let clipID: UUID
        let startX: CGFloat
        var currentX: CGFloat
    }

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

    private enum TrimHandle {
        case start
        case end
    }

    private var clipBodyHeight: CGFloat {
        max(0, laneHeight - TimelineLayout.clipHeaderHeight)
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

    private var usesSourceLinearTimeline: Bool {
        arrangementSections.usesSourceLinearTimeline
    }

    private var showsFullSourceWaveform: Bool {
        !usesArrangementLayout || usesSourceLinearTimeline
    }

    private var displayPeaksCacheKey: String {
        let sectionKey = arrangementSections
            .map { "\($0.id.uuidString)|\($0.timelineStartSeconds)|\($0.timelineEndSeconds)" }
            .joined(separator: ",")
        let gapKey = clipGaps
            .filter { $0.trackID == track.id }
            .map { "\($0.sourceStartSeconds)|\($0.sourceEndSeconds)" }
            .joined(separator: ",")
        let regionKey = clipRegions
            .filter { $0.trackID == track.id }
            .map { "\($0.id.uuidString)|\($0.timelineStartSeconds)|\($0.timelineEndSeconds)" }
            .joined(separator: ",")
        return "\(timelineContentWidth)|\(timelineDuration)|\(fileDuration)|\(sourcePeaks.count)|\(sectionKey)|\(gapKey)|\(regionKey)|\(usesArrangementLayout)|\(usesSourceLinearTimeline)"
    }

    private func refreshCachedDisplayPeaks() {
        if showsFullSourceWaveform {
            cachedDisplayPeaks = WaveformPeakResampler.displayPeaks(
                from: sourcePeaks,
                contentWidth: timelineContentWidth
            )
        } else {
            cachedDisplayPeaks = WaveformPeakResampler.arrangedDisplayPeaks(
                from: sourcePeaks,
                fileDuration: fileDuration,
                sections: arrangementSections,
                timelineDuration: safeTimelineDuration,
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

    private func clipDisplayPeaks(timelineStart: TimeInterval, timelineEnd: TimeInterval) -> [Float] {
        WaveformPeakResampler.peaksSlice(
            from: cachedDisplayPeaks,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            timelineDuration: safeTimelineDuration
        )
    }

    private var waveformArea: some View {
        ZStack(alignment: .leading) {
            if !usesArrangementLayout {
                trimOverlay
            }

            clipLayer
        }
        .frame(width: timelineContentWidth, height: laneHeight)
        .coordinateSpace(name: TimelineDragSpace.name)
    }

    private func timelineTime(atContentX x: CGFloat) -> TimeInterval {
        TimelineLayout.time(
            at: x,
            duration: safeTimelineDuration,
            contentWidth: timelineContentWidth
        )
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
                        clipSelection = nil
                    }

                ForEach(Array(arrangementSections.enumerated()), id: \.element.id) { index, section in
                    arrangementClip(for: section, sectionIndex: index)
                }
            } else {
                ForEach(sourceTrackClipSegments, id: \.id) { segment in
                    sourceTrackClipSegment(segment)
                }
            }
        }
    }

    private struct SourceClipSegment: Identifiable {
        let id: UUID
        let slotID: UUID
        let timelineStart: TimeInterval
        let timelineEnd: TimeInterval
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
    }

    private var sourceTrackClipSegments: [SourceClipSegment] {
        let sections = SongArrangementStore.sourceTrackDisplaySections(
            trackID: track.id,
            trimStart: track.trimStartSeconds,
            trimEnd: effectiveEnd,
            clipGaps: clipGaps,
            clipRegions: clipRegions
        )
        if sections.isEmpty {
            return [
                SourceClipSegment(
                    id: track.id,
                    slotID: track.id,
                    timelineStart: track.trimStartSeconds,
                    timelineEnd: effectiveEnd,
                    sourceStart: track.trimStartSeconds,
                    sourceEnd: effectiveEnd
                ),
            ]
        }
        return sections.map { section in
            SourceClipSegment(
                id: section.id,
                slotID: section.slotID,
                timelineStart: section.timelineStartSeconds,
                timelineEnd: section.timelineEndSeconds,
                sourceStart: section.sourceStartSeconds,
                sourceEnd: section.sourceEndSeconds
            )
        }
    }

    private func sourceTrackClipSegment(_ segment: SourceClipSegment) -> some View {
        let bounds = resolvedClipBounds(clipID: segment.id, fallbackStart: segment.timelineStart, fallbackEnd: segment.timelineEnd)
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

        return clipChrome(
            clipID: segment.id,
            slotID: segment.slotID,
            title: track.displayName,
            colorIndex: trackColorIndex,
            clipWidth: clipWidth,
            timelineStart: bounds.start,
            timelineEnd: bounds.end,
            regionTrimBoundsStart: track.trimStartSeconds,
            regionTrimBoundsEnd: effectiveEnd,
            arrangementSection: nil,
            sourceTrimLeading: resolvedClipRegion(clipID: segment.id) == nil
                && segment.id == sourceTrackClipSegments.first?.id,
            sourceTrimTrailing: resolvedClipRegion(clipID: segment.id) == nil
                && segment.id == sourceTrackClipSegments.last?.id
        )
        .offset(x: startX)
    }

    @ViewBuilder
    private func arrangementClip(for section: ArrangementDisplaySection, sectionIndex: Int) -> some View {
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

        clipChrome(
            clipID: section.id,
            slotID: section.slotID,
            title: section.name,
            colorIndex: sectionIndex,
            clipWidth: clipWidth,
            timelineStart: bounds.start,
            timelineEnd: bounds.end,
            regionTrimBoundsStart: section.columnStartSeconds,
            regionTrimBoundsEnd: section.columnEndSeconds,
            arrangementSection: resolvedClipRegion(clipID: section.id) == nil ? section : nil,
            sourceTrimLeading: false,
            sourceTrimTrailing: false
        )
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
        .offset(x: startX)
    }

    private func clipChrome(
        clipID: UUID,
        slotID: UUID,
        title: String,
        colorIndex: Int,
        clipWidth: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        regionTrimBoundsStart: TimeInterval,
        regionTrimBoundsEnd: TimeInterval,
        arrangementSection: ArrangementDisplaySection?,
        sourceTrimLeading: Bool,
        sourceTrimTrailing: Bool
    ) -> some View {
        let palette = TrackClipPalette.colors(for: colorIndex)
        let isWholeSelected = isWholeClipSelected(clipID: clipID)
        let editTime = clipEditTime(clipID: clipID)
        let committedRange = committedSelectionRange(
            clipID: clipID,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let dragRange = activeClipDragSelection.flatMap { drag in
            drag.clipID == clipID ? dragSelectionRange(
                drag: drag,
                clipWidth: clipWidth,
                timelineStart: timelineStart,
                timelineEnd: timelineEnd
            ) : nil
        }

        return VStack(spacing: 0) {
            clipHeader(
                title: title,
                headerColor: palette.header,
                clipID: clipID,
                slotID: slotID,
                clipWidth: clipWidth,
                arrangementSection: arrangementSection,
                regionTrimBoundsStart: regionTrimBoundsStart,
                regionTrimBoundsEnd: regionTrimBoundsEnd,
                sourceTrimLeading: sourceTrimLeading,
                sourceTrimTrailing: sourceTrimTrailing
            )
            .frame(width: clipWidth, height: TimelineLayout.clipHeaderHeight)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(
                        isWholeSelected
                            ? palette.body.opacity(0.95)
                            : palette.body.opacity(0.72)
                    )

                WaveformBarsCanvas(
                    bars: clipDisplayPeaks(timelineStart: timelineStart, timelineEnd: timelineEnd),
                    showsEmptyBaseline: showsFullSourceWaveform,
                    fillColor: palette.header.opacity(0.82)
                )
                .allowsHitTesting(false)

                if let dragRange {
                    selectionOverlay(
                        range: dragRange,
                        clipWidth: clipWidth,
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd
                    )
                } else if let committedRange, !isWholeSelected {
                    selectionOverlay(
                        range: committedRange,
                        clipWidth: clipWidth,
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd
                    )
                }

                if isWholeSelected {
                    Rectangle()
                        .stroke(Color.dawClipBorder, lineWidth: 2)
                }

                if let editTime {
                    editCursorOverlay(
                        time: editTime,
                        clipWidth: clipWidth,
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd
                    )
                }
            }
            .frame(width: clipWidth, height: clipBodyHeight)
            .overlay { ClipSideBorders() }
            .contentShape(Rectangle())
            .gesture(
                clipBodySelectionGesture(
                    clipID: clipID,
                    slotID: slotID,
                    clipWidth: clipWidth,
                    timelineStart: timelineStart,
                    timelineEnd: timelineEnd
                )
            )
        }
        .frame(width: clipWidth, height: laneHeight, alignment: .topLeading)
    }

    private func clipHeader(
        title: String,
        headerColor: Color,
        clipID: UUID,
        slotID: UUID,
        clipWidth: CGFloat,
        arrangementSection: ArrangementDisplaySection?,
        regionTrimBoundsStart: TimeInterval,
        regionTrimBoundsEnd: TimeInterval,
        sourceTrimLeading: Bool,
        sourceTrimTrailing: Bool
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(headerColor)

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                if let region = resolvedClipRegion(clipID: clipID) {
                    clipHeaderTrimHandle(
                        icon: "[",
                        isActive: isClipRegionTrimActive(regionID: region.id, edge: .leading),
                        clipWidth: clipWidth,
                        gesture: clipRegionTrimDragGesture(
                            for: region,
                            edge: .leading,
                            boundsStart: regionTrimBoundsStart,
                            boundsEnd: regionTrimBoundsEnd
                        )
                    )
                } else if let arrangementSection {
                    clipHeaderTrimHandle(
                        icon: "[",
                        isActive: isClipTrimActive(sectionID: arrangementSection.id, edge: .leading),
                        clipWidth: clipWidth,
                        gesture: clipTrimDragGesture(
                            for: arrangementSection,
                            edge: .leading
                        )
                    )
                } else if sourceTrimLeading {
                    clipHeaderTrimHandle(
                        icon: "[",
                        isActive: activeHandle == .start,
                        clipWidth: clipWidth,
                        gesture: sourceTrackTrimDragGesture(handle: .start)
                    )
                }

                Spacer(minLength: 0)

                if let region = resolvedClipRegion(clipID: clipID) {
                    clipHeaderTrimHandle(
                        icon: "]",
                        isActive: isClipRegionTrimActive(regionID: region.id, edge: .trailing),
                        clipWidth: clipWidth,
                        gesture: clipRegionTrimDragGesture(
                            for: region,
                            edge: .trailing,
                            boundsStart: regionTrimBoundsStart,
                            boundsEnd: regionTrimBoundsEnd
                        )
                    )
                } else if let arrangementSection {
                    clipHeaderTrimHandle(
                        icon: "]",
                        isActive: isClipTrimActive(sectionID: arrangementSection.id, edge: .trailing),
                        clipWidth: clipWidth,
                        gesture: clipTrimDragGesture(
                            for: arrangementSection,
                            edge: .trailing
                        )
                    )
                } else if sourceTrimTrailing {
                    clipHeaderTrimHandle(
                        icon: "]",
                        isActive: activeHandle == .end,
                        clipWidth: clipWidth,
                        gesture: sourceTrackTrimDragGesture(handle: .end)
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectWholeClip(clipID: clipID, slotID: slotID)
        }
    }

    private func clipHeaderTrimHandle<G: Gesture>(
        icon: String,
        isActive: Bool,
        clipWidth: CGFloat,
        gesture: G
    ) -> some View {
        ClipHeaderEdgeTrimControl(
            icon: icon,
            isActive: isActive,
            isEnabled: clipWidth >= 12,
            gesture: gesture
        )
    }

    private func selectionOverlay(
        range: ClosedRange<TimeInterval>,
        clipWidth: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> some View {
        let duration = max(timelineEnd - timelineStart, 0.001)
        let startX = clipWidth * CGFloat((range.lowerBound - timelineStart) / duration)
        let endX = clipWidth * CGFloat((range.upperBound - timelineStart) / duration)
        let width = max(0, endX - startX)

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: width, height: clipBodyHeight)
                .offset(x: startX)

            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: width, height: clipBodyHeight)
                .offset(x: startX)
        }
        .allowsHitTesting(false)
    }

    private func editCursorOverlay(
        time: TimeInterval,
        clipWidth: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> some View {
        let duration = max(timelineEnd - timelineStart, 0.001)
        let x = clipWidth * CGFloat((time - timelineStart) / duration)

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: clipBodyHeight)
                .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 0)

            Triangle()
                .fill(Color.white)
                .frame(width: 8, height: 6)
                .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0)
                .offset(y: -1)
        }
        .offset(x: x - 1)
        .allowsHitTesting(false)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }

    private func clipBodySelectionGesture(
        clipID: UUID,
        slotID: UUID,
        clipWidth: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startX = min(max(0, value.startLocation.x), clipWidth)
                let currentX = min(max(0, value.location.x), clipWidth)
                guard abs(currentX - startX) >= 4 else {
                    activeClipDragSelection = nil
                    return
                }
                if activeClipDragSelection?.clipID != clipID {
                    activeClipDragSelection = ClipDragSelection(
                        clipID: clipID,
                        startX: startX,
                        currentX: currentX
                    )
                } else if var drag = activeClipDragSelection {
                    drag.currentX = currentX
                    activeClipDragSelection = drag
                }
            }
            .onEnded { value in
                defer { activeClipDragSelection = nil }

                guard clipWidth > 0 else { return }
                let startX = min(max(0, value.startLocation.x), clipWidth)
                let endX = min(max(0, value.location.x), clipWidth)
                let minX = min(startX, endX)
                let maxX = max(startX, endX)

                if maxX - minX >= 4,
                   let range = dragSelectionRange(
                       drag: ClipDragSelection(clipID: clipID, startX: minX, currentX: maxX),
                       clipWidth: clipWidth,
                       timelineStart: timelineStart,
                       timelineEnd: timelineEnd
                   ) {
                    clipSelection = .range(
                        clipID: clipID,
                        slotID: slotID,
                        trackID: track.id,
                        start: range.lowerBound,
                        end: range.upperBound
                    )
                } else {
                    let time = snappedTimelineTime(
                        atX: startX,
                        clipWidth: clipWidth,
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd
                    )
                    if !audioEngine.isPlaying {
                        onSeek(time)
                    }
                    selectWholeClip(clipID: clipID, slotID: slotID, editTime: time)
                }
            }
    }

    private func snappedTimelineTime(
        atX x: CGFloat,
        clipWidth: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> TimeInterval {
        guard clipWidth > 0 else { return timelineStart }
        let duration = max(timelineEnd - timelineStart, 0.001)
        let clampedX = min(max(0, x), clipWidth)
        let raw = timelineStart + duration * TimeInterval(clampedX / clipWidth)
        let snapped = MeasureTiming.snapToNearestBeat(
            raw,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )
        return min(max(snapped, timelineStart), timelineEnd)
    }

    private func dragSelectionRange(
        drag: ClipDragSelection,
        clipWidth: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard clipWidth > 0 else { return nil }
        let duration = max(timelineEnd - timelineStart, 0.001)
        let minX = min(drag.startX, drag.currentX)
        let maxX = max(drag.startX, drag.currentX)
        let rawStart = timelineStart + duration * TimeInterval(minX / clipWidth)
        let rawEnd = timelineStart + duration * TimeInterval(maxX / clipWidth)
        let snapped = MeasureTiming.snapTimelineRangeToGrid(
            start: rawStart,
            end: rawEnd,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )
        let start = max(timelineStart, snapped.start)
        let end = min(timelineEnd, snapped.end)
        guard end - start >= 0.05 else { return nil }
        return start...end
    }

    private func committedSelectionRange(
        clipID: UUID,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        guard let clipSelection,
              clipSelection.clipID == clipID,
              clipSelection.trackID == track.id,
              case .range(_, _, _, let start, let end) = clipSelection else {
            return nil
        }
        let overlapStart = max(start, timelineStart)
        let overlapEnd = min(end, timelineEnd)
        guard overlapEnd - overlapStart >= 0.05 else { return nil }
        return overlapStart...overlapEnd
    }

    private func isWholeClipSelected(clipID: UUID) -> Bool {
        guard let clipSelection,
              clipSelection.clipID == clipID,
              clipSelection.trackID == track.id else {
            return false
        }
        return clipSelection.isWholeClip
    }

    private func clipEditTime(clipID: UUID) -> TimeInterval? {
        guard let clipSelection,
              clipSelection.clipID == clipID,
              clipSelection.trackID == track.id,
              let editTime = clipSelection.editTime else {
            return nil
        }
        return editTime
    }

    private func selectWholeClip(clipID: UUID, slotID: UUID, editTime: TimeInterval? = nil) {
        clipSelection = .whole(clipID: clipID, slotID: slotID, trackID: track.id, editTime: editTime)
    }

    private func sourceTrackTrimDragGesture(handle: TrimHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineDragSpace.name))
            .onChanged { value in
                activeHandle = handle
                applyTrimTime(handle: handle, time: timelineTime(atContentX: value.location.x))
            }
            .onEnded { _ in
                activeHandle = nil
                onTrimChange()
            }
    }

    private func clipTrimDragGesture(
        for section: ArrangementDisplaySection,
        edge: ArrangementClipTrimEdge
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineDragSpace.name))
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
                      let slot = arrangementSlots.first(where: { $0.id == section.slotID }),
                      let marker = markers.first(where: { $0.id == slot.markerID }) else { return }

                let committed = SongArrangementStore.trims(
                    slotID: section.id,
                    trackID: track.id,
                    in: clipTrims
                )
                let untrimmedDuration = section.timelineEndSeconds
                    + committed.trailing
                    - section.columnStartSeconds
                let timelineTime = timelineTime(atContentX: value.location.x)

                var leading = clipTrimDragStart.leadingTrim
                var trailing = clipTrimDragStart.trailingTrim

                switch edge {
                case .leading:
                    leading = timelineTime - section.columnStartSeconds
                case .trailing:
                    trailing = section.columnStartSeconds + untrimmedDuration - timelineTime
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

    private func resolvedClipRegion(clipID: UUID) -> ClipRegion? {
        if let previewClipRegion, previewClipRegion.id == clipID {
            return previewClipRegion
        }
        return ClipRegionStore.region(id: clipID, in: clipRegions)
    }

    private func resolvedClipBounds(
        clipID: UUID,
        fallbackStart: TimeInterval,
        fallbackEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        guard let region = resolvedClipRegion(clipID: clipID) else {
            return (fallbackStart, fallbackEnd)
        }
        return (region.timelineStartSeconds, region.timelineEndSeconds)
    }

    private func isClipRegionTrimActive(
        regionID: UUID,
        edge: ClipRegionStore.RegionTrimEdge
    ) -> Bool {
        activeClipRegionTrim?.regionID == regionID && activeClipRegionTrim?.edge == edge
    }

    private func clipRegionTrimDragGesture(
        for region: ClipRegion,
        edge: ClipRegionStore.RegionTrimEdge,
        boundsStart: TimeInterval,
        boundsEnd: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineDragSpace.name))
            .onChanged { value in
                if activeClipRegionTrim?.regionID != region.id || activeClipRegionTrim?.edge != edge {
                    activeClipRegionTrim = (region.id, edge)
                    clipRegionTrimBaseline = ClipRegionStore.region(id: region.id, in: clipRegions) ?? region
                }

                guard let clipRegionTrimBaseline else { return }

                let timelineTime = timelineTime(atContentX: value.location.x)
                let timelineOffset: TimeInterval
                switch edge {
                case .leading:
                    timelineOffset = timelineTime - clipRegionTrimBaseline.timelineStartSeconds
                case .trailing:
                    timelineOffset = timelineTime - clipRegionTrimBaseline.timelineEndSeconds
                }

                previewClipRegion = ClipRegionStore.regionByTrimmingEdge(
                    clipRegionTrimBaseline,
                    edge: edge,
                    timelineOffset: timelineOffset,
                    in: clipRegions,
                    boundsStart: boundsStart,
                    boundsEnd: boundsEnd
                )
            }
            .onEnded { _ in
                defer {
                    activeClipRegionTrim = nil
                    clipRegionTrimBaseline = nil
                    previewClipRegion = nil
                }

                guard let previewClipRegion,
                      let index = clipRegions.firstIndex(where: { $0.id == previewClipRegion.id }) else {
                    return
                }

                clipRegions[index] = previewClipRegion
                onClipTrimCommitted()
            }
    }

    private func clipTimelineBounds(for section: ArrangementDisplaySection) -> (start: TimeInterval, end: TimeInterval) {
        if let region = resolvedClipRegion(clipID: section.id) {
            return (region.timelineStartSeconds, region.timelineEndSeconds)
        }

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

private struct ClipHeaderEdgeTrimControl<G: Gesture>: View {
    let icon: String
    let isActive: Bool
    let isEnabled: Bool
    let gesture: G

    @State private var isHovering = false

    var body: some View {
        Text(icon)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.92))
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(gesture)
            #if os(macOS)
            .opacity(isEnabled && (isHovering || isActive) ? 1 : 0)
            .onContinuousHover { phase in
                guard isEnabled else { return }
                switch phase {
                case .active:
                    isHovering = true
                    NSCursor.resizeLeftRight.push()
                case .ended:
                    isHovering = false
                    NSCursor.pop()
                }
            }
            #else
            .opacity(isEnabled && isActive ? 1 : 0)
            #endif
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
    var headerHeight: CGFloat = 0
    var fillColor: Color = Color.dawWaveformFill

    private let minBarHeight: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            drawWaveform(in: &context, size: size)
        }
        .drawingGroup()
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        let bodyHeight = max(1, size.height - headerHeight)
        let midY = headerHeight + bodyHeight / 2

        if !bars.isEmpty {
            let barWidth = size.width / CGFloat(bars.count)
            let maxBarHeight = (bodyHeight / 2) * 0.92

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
