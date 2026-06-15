import SwiftData
import SwiftUI

struct ManageOutputsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\TrackGroup.sortOrder), SortDescriptor(\TrackGroup.name)])
    private var groups: [TrackGroup]

    var onRoutingChanged: (() -> Void)?

    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedDeviceUID: String?
    @State private var channelCount = 2
    @State private var groupDestinations: [UUID: OutputDestination] = [:]
    @State private var ungroupedDestination: OutputDestination = .defaultDestination

    private let groupNameWidth: CGFloat = 92
    private let destinationControlWidth: CGFloat = 108

    private var stereoDestinations: [OutputDestination] {
        OutputRoutingStore.destinations(for: channelCount).stereo
    }

    private var monoDestinations: [OutputDestination] {
        OutputRoutingStore.destinations(for: channelCount).mono
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    deviceSection
                    groupOutputsSection
                    footerText
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Manage Outputs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadState)
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 520)
        #endif
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Output Device")

            if devices.isEmpty {
                Text("No output devices found.")
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: $selectedDeviceUID) {
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: selectedDeviceUID) { _, newValue in
                    applyDeviceSelection(newValue)
                }
            }

            Text("\(channelCount) output channels available")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if os(iOS)
            Text("On iOS, connect a multi-channel USB interface for additional outputs. Device selection follows the current audio route.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private var groupOutputsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Group Outputs")

            VStack(spacing: 0) {
                ForEach(groups) { group in
                    groupRouteRow(title: group.name, routeID: group.id)
                    if group.id != groups.last?.id {
                        Divider()
                    }
                }

                if !groups.isEmpty {
                    Divider()
                }

                groupRouteRow(title: "No Group", routeID: OutputRoutingStore.ungroupedRouteID)
            }
            .padding(.vertical, 4)
            .background(controlBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footerText: some View {
        Text("Assign each track group to a stereo pair or mono output channel on the selected device.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    @ViewBuilder
    private func groupRouteRow(title: String, routeID: UUID) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .lineLimit(1)
                .frame(width: groupNameWidth, alignment: .leading)

            Spacer(minLength: 0)

            destinationMenu(
                selection: binding(for: routeID),
                label: destinationLabel(for: routeID)
            )
            .frame(width: destinationControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func binding(for routeID: UUID) -> Binding<OutputDestination> {
        Binding(
            get: {
                if routeID == OutputRoutingStore.ungroupedRouteID {
                    return ungroupedDestination
                }
                return groupDestinations[routeID] ?? .defaultDestination
            },
            set: { newValue in
                if routeID == OutputRoutingStore.ungroupedRouteID {
                    ungroupedDestination = newValue
                } else {
                    groupDestinations[routeID] = newValue
                }
                OutputRoutingStore.setRoute(newValue, for: routeID, in: modelContext)
                scheduleRoutingChange()
            }
        )
    }

    private func destinationLabel(for routeID: UUID) -> String {
        if routeID == OutputRoutingStore.ungroupedRouteID {
            return ungroupedDestination.displayLabel
        }
        return (groupDestinations[routeID] ?? .defaultDestination).displayLabel
    }

    private func destinationMenu(
        selection: Binding<OutputDestination>,
        label: String
    ) -> some View {
        Menu {
            Section("Stereo") {
                ForEach(stereoDestinations) { destination in
                    Button {
                        selection.wrappedValue = destination
                    } label: {
                        if selection.wrappedValue == destination {
                            Label(destination.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(destination.displayLabel)
                        }
                    }
                }
            }

            Section("Mono") {
                ForEach(monoDestinations) { destination in
                    Button {
                        selection.wrappedValue = destination
                    } label: {
                        if selection.wrappedValue == destination {
                            Label(destination.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(destination.displayLabel)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(secondaryControlBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var controlBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    private var secondaryControlBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .tertiarySystemGroupedBackground)
        #endif
    }

    private func loadState() {
        OutputRoutingStore.ensureConfig(in: modelContext)
        devices = AudioOutputDeviceService.availableDevices()
        let config = OutputRoutingStore.config(in: modelContext)

        if let uid = config.selectedDeviceUID, devices.contains(where: { $0.id == uid }) {
            selectedDeviceUID = uid
            channelCount = AudioOutputDeviceService.channelCount(for: uid)
        } else if let first = devices.first {
            selectedDeviceUID = first.id
            channelCount = first.channelCount
            OutputRoutingStore.setSelectedDevice(uid: first.id, in: modelContext)
        } else {
            selectedDeviceUID = nil
            channelCount = AudioOutputDeviceService.currentSystemChannelCount()
        }

        var loaded: [UUID: OutputDestination] = [:]
        for group in groups {
            loaded[group.id] = OutputRoutingStore.route(for: group.id, in: modelContext)
        }
        groupDestinations = loaded
        ungroupedDestination = OutputRoutingStore.ungroupedRoute(in: modelContext)
    }

    private func applyDeviceSelection(_ uid: String?) {
        OutputRoutingStore.setSelectedDevice(uid: uid, in: modelContext)
        channelCount = AudioOutputDeviceService.channelCount(for: uid)

        scheduleRoutingChange {
            if let uid {
                _ = AudioOutputDeviceService.setSystemDefaultOutputDevice(uid: uid)
            }
        }
    }

    private func scheduleRoutingChange(_ preparation: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            preparation?()
            onRoutingChanged?()
        }
    }
}
