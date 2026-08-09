import SwiftUI
import UniformTypeIdentifiers

struct LiveSetlistHeaderRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(AppColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .frame(minHeight: 40, alignment: .leading)
    }
}

struct LiveSetlistSongRow: View {
    let title: String
    let index: Int
    let currentIndex: Int
    let isPlaying: Bool
    var subtitle: String? = nil
    var hasMissingMedia: Bool = false
    var transition: SetlistTransition? = nil
    var onOverlapBadgeTap: (() -> Void)? = nil

    private var isFinished: Bool {
        index < currentIndex
    }

    private var isCurrent: Bool {
        index == currentIndex
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Text("\(index + 1).")
                .font(.subheadline.monospacedDigit().weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? AppColors.textSecondary : AppColors.textTertiary)
                .frame(width: 28, alignment: .trailing)

            if isCurrent {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppColors.accent)
                    .frame(width: 3, height: 28)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(isCurrent ? .headline.weight(.semibold) : .body.weight(.medium))
                    .foregroundStyle(isFinished ? AppColors.textTertiary : AppColors.textPrimary)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasMissingMedia {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .accessibilityLabel("Missing audio files")
                    .help("Missing audio files — use Relink Missing Files in the context menu")
            }

            if isCurrent {
                LiveSetlistPlayingBadge(isPlaying: isPlaying)
            } else if isFinished {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(AppColors.textTertiary)
                    .font(.caption)
            }

            if let transition {
                SetlistTransitionBadge(
                    transition: transition,
                    size: 24,
                    onTap: onOverlapBadgeTap
                )
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: isCurrent ? 64 : 56, alignment: .leading)
        .opacity(isFinished ? 0.55 : 1)
    }
}

extension LiveSetlistSongRow {
    init(
        song: Song,
        index: Int,
        currentIndex: Int,
        isPlaying: Bool,
        hasMissingMedia: Bool = false,
        transition: SetlistTransition? = nil,
        onOverlapBadgeTap: (() -> Void)? = nil
    ) {
        let subtitle: String? = {
            guard let bpm = song.bpm else { return nil }
            return String(format: "%.0f BPM", bpm.rounded())
        }()
        self.init(
            title: song.name,
            index: index,
            currentIndex: currentIndex,
            isPlaying: isPlaying,
            subtitle: subtitle,
            hasMissingMedia: hasMissingMedia,
            transition: transition,
            onOverlapBadgeTap: onOverlapBadgeTap
        )
    }
}

struct LiveSetlistPlayingBadge: View {
    let isPlaying: Bool

    var body: some View {
        AppBadge(
            title: isPlaying ? "Playing" : "Paused",
            systemImage: isPlaying ? "waveform" : "pause",
            style: isPlaying ? .accent : .neutral
        )
    }
}

// MARK: - Shared setlist chrome

struct LiveSetlistAddMenu: View {
    var onAddHeader: () -> Void
    var onAddSong: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Menu {
                Button(action: onAddHeader) {
                    Label("Header", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button(action: onAddSong) {
                    Label("Song", systemImage: "music.note")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Add to setlist")
            .help("Add to Setlist")
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.sm)
    }
}

struct LiveSetlistSummaryBar: View {
    let songCount: Int
    var totalDurationText: String? = nil

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Spacer(minLength: 0)

            if let totalDurationText {
                Label(
                    "Total setlist length: \(totalDurationText) · \(songCount) songs",
                    systemImage: "clock"
                )
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppColors.textTertiary)
                .accessibilityLabel("Total setlist length \(totalDurationText)")
            } else {
                Label("\(songCount) songs", systemImage: "music.note.list")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, AppSpacing.xs)
    }
}

enum LiveSetlistDurationFormat {
    static func text(for total: TimeInterval) -> String? {
        guard total >= 1 else { return nil }
        let totalMinutes = max(1, Int((total / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes) min"
        }
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
}

struct LiveSetlistReorderHandle: View {
    let accessibilityNoun: String
    let onDragBegan: () -> NSItemProvider

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColors.textTertiary)
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel("Reorder \(accessibilityNoun)")
            .help("Drag to reorder")
            .onDrag(onDragBegan) {
                // The list reorders in place, so the floating drag image would only be noise.
                Color.clear.frame(width: 1, height: 1)
            }
    }
}

/// Shared list styling used by local and remote live setlist panes.
struct LiveSetlistListChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            #if os(iOS)
            .listSectionSpacing(0)
            .contentMargins(.vertical, 0, for: .scrollContent)
            // Native List reorder (custom onDrag/onDrop is unreliable inside iOS List).
            .environment(\.editMode, .constant(.active))
            #endif
    }
}

extension View {
    func liveSetlistListChrome() -> some View {
        modifier(LiveSetlistListChromeModifier())
    }

    func liveSetlistHeaderRowChrome(isDragging: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isDragging ? 0.3 : 1)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(AppColors.backgroundSecondary)
    }

    func liveSetlistSongRowChrome(isDragging: Bool, isCurrent: Bool) -> some View {
        self
            .opacity(isDragging ? 0.3 : 1)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(
                isCurrent ? AppColors.accent.opacity(0.12) : Color.clear
            )
    }
}

/// Reorders live as the drag passes over a row. A nil `targetID` marks the list background,
/// which only needs to commit whatever order the drag left behind.
struct LiveSetlistEntryDropDelegate<ID: Hashable>: DropDelegate {
    let targetID: ID?
    let draggedID: ID?
    let onMove: (ID, ID) -> Void
    let onCommit: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID, let targetID, draggedID != targetID else { return }
        onMove(draggedID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onCommit()
        return true
    }
}
