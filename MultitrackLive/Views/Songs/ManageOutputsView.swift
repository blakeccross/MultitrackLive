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
        AppSheetContainer {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.xl) {
                        deviceSection
                        groupOutputsSection
                        footerText
                    }
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Manage Outputs")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                        .foregroundStyle(AppColors.accent)
                    }
                }
                .onAppear(perform: loadState)
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 520)
        #endif
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Output Device")

            if devices.isEmpty {
                Text("No output devices found.")
                    .appCaptionText()
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
                .padding(AppSpacing.sm)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                .onChange(of: selectedDeviceUID) { _, newValue in
                    applyDeviceSelection(newValue)
                }
            }

            Text("\(channelCount) output channels available")
                .appCaptionText()

            #if os(iOS)
            Text("On iOS, connect a multi-channel USB interface for additional outputs. Device selection follows the current audio route.")
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private var groupOutputsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Group Outputs")

            VStack(spacing: 0) {
                ForEach(groups) { group in
                    groupRouteRow(title: group.name, routeID: group.id)
                    if group.id != groups.last?.id {
                        Rectangle()
                            .fill(AppColors.separator)
                            .frame(height: 0.5)
                            .padding(.leading, AppSpacing.sm)
                    }
                }

                if !groups.isEmpty {
                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(height: 0.5)
                        .padding(.leading, AppSpacing.sm)
                }

                groupRouteRow(title: "No Group", routeID: OutputRoutingStore.ungroupedRouteID)
            }
            .padding(.vertical, AppSpacing.xs)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }

    private var footerText: some View {
        Text("Assign each track group to a stereo pair or mono output channel on the selected device.")
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func groupRouteRow(title: String, routeID: UUID) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Text(title)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .frame(width: groupNameWidth, alignment: .leading)

            Spacer(minLength: 0)

            destinationMenu(
                selection: binding(for: routeID),
                label: destinationLabel(for: routeID)
            )
            .frame(width: destinationControlWidth, alignment: .trailing)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .frame(minHeight: AppSpacing.rowMinHeight)
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
            HStack(spacing: AppSpacing.xs) {
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .font(.callout)
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(AppColors.surfaceElevated, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
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
