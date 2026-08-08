import SwiftData
import SwiftUI

/// Shared audio output device, group routing, and LTC controls.
/// Used by the Manage Outputs sheet and the macOS Settings panes.
struct OutputRoutingSettingsForm: View {
    struct Sections: OptionSet {
        let rawValue: Int

        static let device = Sections(rawValue: 1 << 0)
        static let groupOutputs = Sections(rawValue: 1 << 1)
        static let timecode = Sections(rawValue: 1 << 2)
        static let footer = Sections(rawValue: 1 << 3)

        static let all: Sections = [.device, .groupOutputs, .timecode, .footer]
        static let audio: Sections = [.device, .groupOutputs, .footer]
        static let timecodeOnly: Sections = [.timecode]
    }

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\TrackGroup.sortOrder), SortDescriptor(\TrackGroup.name)])
    private var groups: [TrackGroup]

    var sections: Sections = .all
    var onRoutingChanged: (() -> Void)?

    @State private var devices: [AudioOutputDevice] = []
    @State private var selectedDeviceUID: String?
    @State private var channelCount = 2
    @State private var groupDestinations: [UUID: OutputDestination] = [:]
    @State private var ungroupedDestination: OutputDestination = .defaultDestination
    @State private var timecodeEnabled = false
    @State private var timecodeMode: TimecodeMode = .resetPerSong
    @State private var timecodeStartingHour = 1
    @State private var timecodeFrameRate: TimecodeFrameRate = .fps30

    private let groupNameWidth: CGFloat = 92
    private let destinationControlWidth: CGFloat = 108

    private var stereoDestinations: [OutputDestination] {
        OutputRoutingStore.destinations(for: channelCount).stereo
    }

    private var monoDestinations: [OutputDestination] {
        OutputRoutingStore.destinations(for: channelCount).mono
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            if sections.contains(.device) {
                deviceSection
            }
            if sections.contains(.groupOutputs) {
                groupOutputsSection
            }
            if sections.contains(.timecode) {
                timecodeSection
            }
            if sections.contains(.footer) {
                footerText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: loadState)
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
        Text("Assign each track group to a stereo pair or mono output channel on the selected device. Route the Timecode group to a dedicated mono output for lighting or video gear.")
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timecodeSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Timecode (LTC)")

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Toggle("Enable LTC", isOn: $timecodeEnabled)
                    .tint(AppColors.accent)
                    .onChange(of: timecodeEnabled) { _, _ in
                        persistTimecodeSettings()
                    }

                if timecodeEnabled {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Mode")
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)

                        #if os(macOS)
                        Picker("Timecode Mode", selection: $timecodeMode) {
                            ForEach(TimecodeMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .onChange(of: timecodeMode) { _, _ in
                            persistTimecodeSettings()
                        }
                        #else
                        Picker("Timecode Mode", selection: $timecodeMode) {
                            ForEach(TimecodeMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .onChange(of: timecodeMode) { _, _ in
                            persistTimecodeSettings()
                        }
                        #endif
                    }

                    HStack {
                        Text("Starting hour")
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer()
                        Stepper(
                            value: $timecodeStartingHour,
                            in: 0...23
                        ) {
                            Text(String(format: "%02d", timecodeStartingHour))
                                .monospacedDigit()
                                .foregroundStyle(AppColors.textPrimary)
                        }
                        .onChange(of: timecodeStartingHour) { _, _ in
                            persistTimecodeSettings()
                        }
                    }

                    HStack {
                        Text("Frame rate")
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer()
                        Picker("Frame rate", selection: $timecodeFrameRate) {
                            ForEach(TimecodeFrameRate.allCases) { rate in
                                Text(rate.displayName).tag(rate)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140, alignment: .trailing)
                        .onChange(of: timecodeFrameRate) { _, _ in
                            persistTimecodeSettings()
                        }
                    }
                }
            }
            .padding(AppSpacing.sm)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
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
        TimecodeSettingsStore.ensureConfig(in: modelContext)
        TrackGroupStore.ensureDefaults(in: modelContext)
        _ = TimecodePlaybackSupport.resolveGroupID(in: modelContext)

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

        let timecode = TimecodeSettingsStore.settings(in: modelContext)
        timecodeEnabled = timecode.isEnabled
        timecodeMode = timecode.mode
        timecodeStartingHour = timecode.startingHour
        timecodeFrameRate = timecode.frameRate
    }

    private func persistTimecodeSettings() {
        TimecodeSettingsStore.save({ settings in
            settings.isEnabled = timecodeEnabled
            settings.mode = timecodeMode
            settings.startingHour = timecodeStartingHour
            settings.frameRate = timecodeFrameRate
        }, in: modelContext)
        scheduleRoutingChange()
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
            NotificationCenter.default.post(name: .outputRoutingDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let outputRoutingDidChange = Notification.Name("com.blakecross.MultitrackLive.outputRoutingDidChange")
}
