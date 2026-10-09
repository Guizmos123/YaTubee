//
//  InstancePickerSheet.swift
//  Yattee
//
//  Quick instance picker sheet for switching between backends.
//

import SwiftUI

struct InstancePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    private var instancesManager: InstancesManager? { appEnvironment?.instancesManager }

    var body: some View {
        NavigationStack {
            List {
                if let instancesManager {
                    // Enabled instances
                    Section(AppLocalization.string("instance.enabled")) {
                        ForEach(instancesManager.enabledInstances, id: \.url) { instance in
                            let isActive = instance.id == instancesManager.activeInstance?.id
                            PickerInstanceRow(instance: instance, isEnabled: true, isPrimary: isActive) {
                                instancesManager.setActive(instance)
                            }
                        }
                    }

                    // Disabled instances
                    let disabledInstances = instancesManager.instances.filter { !$0.isEnabled }
                    if !disabledInstances.isEmpty {
                        Section(AppLocalization.string("instance.disabled")) {
                            ForEach(disabledInstances, id: \.url) { instance in
                                PickerInstanceRow(instance: instance, isEnabled: false, isPrimary: false) {
                                    instancesManager.toggleEnabled(instance)
                                }
                            }
                        }
                    }

                    // Add instance
                    Section {
                        NavigationLink {
                            QuickAddInstanceView()
                        } label: {
                            Label(AppLocalization.string("instance.add"), systemImage: "plus.circle")
                        }
                    }
                }
            }
            .reactiveNavigationTitle(AppLocalization.string("instance.picker.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                sheetCloseToolbarItem { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 500)
        #endif
    }
}

// MARK: - Picker Instance Row

private struct PickerInstanceRow: View {
    let instance: Instance
    let isEnabled: Bool
    let isPrimary: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: instanceIcon)
                .font(.title3)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.displayName)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                HStack(spacing: 4) {
                    Text(instance.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(verbatim: "•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(instance.url.host ?? "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Checkmark for primary, or plus for disabled
            if isEnabled {
                if isPrimary {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }

    private var instanceIcon: String {
        switch instance.type {
        case .invidious:
            return "play.rectangle"
        case .piped:
            return "waveform"
        case .peertube:
            return "film"
        case .yatteeServer:
            return "server.rack"
        }
    }
}

// MARK: - Quick Add Instance View

private struct QuickAddInstanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    @State private var urlString = ""
    @State private var isDetecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField(AppLocalization.string("instance.url.placeholder"), text: $urlString)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text(AppLocalization.string("instance.url.header"))
            } footer: {
                Text(AppLocalization.string("instance.url.footer"))
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .reactiveNavigationTitle(AppLocalization.string("instance.add"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    addInstance()
                } label: {
                    if isDetecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(AppLocalization.string("common.add"))
                    }
                }
                .disabled(urlString.isEmpty || isDetecting)
            }
        }
    }

    private func addInstance() {
        guard let appEnvironment else { return }

        // Normalize URL
        var normalizedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
        }

        guard let url = URL(string: normalizedURL) else {
            errorMessage = AppLocalization.string("instance.error.invalidURL")
            return
        }

        isDetecting = true
        errorMessage = nil

        Task {
            let type = await appEnvironment.instanceDetector.detect(url: url)

            await MainActor.run {
                if let type {
                    let instance = Instance(type: type, url: url, name: url.host ?? normalizedURL, isEnabled: true)
                    appEnvironment.instancesManager.addInstance(instance)
                    dismiss()
                } else {
                    errorMessage = AppLocalization.string("instance.error.detectionFailed")
                    isDetecting = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    InstancePickerSheet()
        .appEnvironment(.preview)
}
