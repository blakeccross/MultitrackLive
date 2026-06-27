import SwiftUI

struct ArrangementEditorMenu: View {
    @Binding var slots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var removedClips: [ArrangementRemovedClip]
    @Binding var clipGaps: [ArrangementClipGap]
    @Binding var clipRegions: [ClipRegion]
    @Binding var loopSlotIDs: Set<UUID>
    let markers: [ArrangementMarker]
    let onPersist: () -> Void

    private var markersByID: [UUID: ArrangementMarker] {
        Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Song Arrangement")
                .font(.headline)

            Text("Drag to reorder. Duplicate or remove sections below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if slots.isEmpty {
                ContentUnavailableView(
                    "No Sections",
                    systemImage: "music.note.list",
                    description: Text("Import an Ableton file to add section markers.")
                )
                .frame(minWidth: 300, minHeight: 180)
            } else {
                List {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: slot, at: index))
                                    .font(.body.weight(.medium))
                                if let marker = markersByID[slot.markerID] {
                                    Text(formatSourceTime(marker.startSeconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                duplicate(slot)
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .buttonStyle(.borderless)
                            .help("Duplicate section")

                            Button(role: .destructive) {
                                remove(slot)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove section")
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .frame(minWidth: 320, minHeight: 220, maxHeight: 420)
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                #endif
            }
        }
        .padding()
    }

    private func displayName(for slot: ArrangementSlot, at index: Int) -> String {
        markersByID[slot.markerID]?.name ?? "Section \(index + 1)"
    }

    private func formatSourceTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "Source %d:%02d", minutes, seconds)
    }

    private func move(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        onPersist()
    }

    private func duplicate(_ slot: ArrangementSlot) {
        guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        let copy = ArrangementSlot(markerID: slot.markerID)
        slots.insert(copy, at: index + 1)
        onPersist()
    }

    private func remove(_ slot: ArrangementSlot) {
        slots.removeAll { $0.id == slot.id }
        clipTrims.removeAll { $0.slotID == slot.id }
        removedClips.removeAll { $0.slotID == slot.id }
        clipGaps.removeAll { $0.slotID == slot.id }
        clipRegions.removeAll { $0.slotID == slot.id }
        loopSlotIDs.remove(slot.id)
        onPersist()
    }
}
