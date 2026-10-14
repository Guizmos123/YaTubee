//
//  SubscriptionsSettingsView.swift
//  Yattee
//
//  Settings for importing and exporting subscriptions.
//

import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)

// MARK: - Export File Wrapper

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct SubscriptionsSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    // Import state
    @State private var showingImportPicker = false
    @State private var isImporting = false
    @State private var importResult: (imported: Int, skipped: Int, format: String)?
    @State private var showingImportResult = false
    @State private var importError: String?
    @State private var showingImportError = false

    // Export state
    @State private var selectedExportFormat: SubscriptionExportFormat = .json
    @State private var exportFile: ExportFile?
    @State private var isExporting = false

    // Local data deletion state
    @State private var showingDeleteLocalConfirmation = false

    private var dataManager: DataManager? {
        appEnvironment?.dataManager
    }

    private var settingsManager: SettingsManager? {
        appEnvironment?.settingsManager
    }

    /// Subscription count in the local source of truth.
    private var subscriptionCount: Int {
        dataManager?.subscriptionCount ?? 0
    }

    private var localFeedSourcePreference: LocalFeedSourcePreference {
        settingsManager?.localFeedSourcePreference ?? .automatic
    }

    var body: some View {
        List {
            feedSourceSection
            importSection
            exportSection
            localDataSection
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.subscriptions.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImportPicker) {
            SubscriptionFilePickerView { url in
                handleImportedFile(url)
            }
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        #endif
        .alert(
            AppLocalization.string("settings.subscriptions.import.success.title"),
            isPresented: $showingImportResult
        ) {
            Button(AppLocalization.string("common.ok")) {}
        } message: {
            if let result = importResult {
                Text(AppLocalization.string("settings.subscriptions.import.success.message \(result.imported) \(result.skipped) \(result.format)"))
            }
        }
        .alert(
            AppLocalization.string("settings.subscriptions.import.error.title"),
            isPresented: $showingImportError
        ) {
            Button(AppLocalization.string("common.ok")) {}
        } message: {
            if let error = importError {
                Text(error)
            }
        }
        .confirmationDialog(
            AppLocalization.string("settings.subscriptions.localData.delete.confirmation.title \(subscriptionCount)"),
            isPresented: $showingDeleteLocalConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("settings.subscriptions.localData.delete.confirmation.action"), role: .destructive) {
                deleteLocalSubscriptions()
            }
        } message: {
            Text(AppLocalization.string("settings.subscriptions.localData.delete.confirmation.message"))
        }
        .presentationCompactAdaptation(.sheet)
    }

    // MARK: - Feed Source Section

    @ViewBuilder
    private var feedSourceSection: some View {
        Section {
            Picker(
                AppLocalization.string("settings.subscriptions.feedSource.label"),
                selection: Binding(
                    get: { localFeedSourcePreference },
                    set: { selectLocalFeedSource($0) }
                )
            ) {
                Text(AppLocalization.string("settings.subscriptions.feedSource.automatic"))
                    .tag(LocalFeedSourcePreference.automatic)
                ForEach(localFeedSourceChoices, id: \.preference) { choice in
                    Text(choice.title).tag(choice.preference)
                }
            }
        } footer: {
            Text(AppLocalization.string("settings.subscriptions.feedSource.footer"))
        }
    }

    private var localFeedSourceChoices: [(preference: LocalFeedSourcePreference, title: String)] {
        guard let appEnvironment else { return [] }
        return appEnvironment.instancesManager.instances.compactMap { instance in
            guard instance.isEnabled else { return nil }
            let name = instance.name?.isEmpty == false
                ? instance.name!
                : (instance.url.host ?? instance.type.displayName)
            switch instance.type {
            case .yatteeServer:
                return (.yatteeServer(instance.id), "Yattee Server — \(name)")
            case .invidious:
                return (.invidious(instance.id), "Invidious — \(name)")
            case .piped, .peertube:
                return nil
            }
        }
    }

    private func selectLocalFeedSource(_ preference: LocalFeedSourcePreference) {
        settingsManager?.localFeedSourcePreference = preference
        SubscriptionFeedCache.shared.handleAccountChange()
        Task {
            guard let appEnvironment else { return }
            await SubscriptionFeedCache.shared.refresh(using: appEnvironment)
        }
    }

    // MARK: - Import Section

    @ViewBuilder
    private var importSection: some View {
        Section {
            Button {
                showImportPicker()
            } label: {
                HStack {
                    Label(AppLocalization.string("settings.subscriptions.import.button"), systemImage: "square.and.arrow.down")
                    Spacer()
                    if isImporting {
                        ProgressView()
                    }
                }
            }
            .disabled(isImporting)
        } header: {
            Text(AppLocalization.string("settings.subscriptions.import.title"))
        } footer: {
            Text(AppLocalization.string("settings.subscriptions.import.footer"))
        }
    }

    // MARK: - Export Section

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Picker(AppLocalization.string("settings.subscriptions.export.format"), selection: $selectedExportFormat) {
                ForEach(SubscriptionExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }

            Button {
                exportSubscriptions()
            } label: {
                HStack {
                    Label(AppLocalization.string("settings.subscriptions.export.button"), systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExporting {
                        ProgressView()
                    }
                }
            }
            .disabled(subscriptionCount == 0 || isExporting)
        } header: {
            Text(AppLocalization.string("settings.subscriptions.export.title"))
        } footer: {
            Text(AppLocalization.string("settings.subscriptions.export.footer \(subscriptionCount)"))
        }
    }

    // MARK: - Local Data Section

    @ViewBuilder
    private var localDataSection: some View {
        if subscriptionCount > 0 {
            Section {
                Button(role: .destructive) {
                    showingDeleteLocalConfirmation = true
                } label: {
                    Label(AppLocalization.string("settings.subscriptions.localData.delete.button"), systemImage: "trash")
                }
            } header: {
                Text(AppLocalization.string("settings.subscriptions.localData.title"))
            } footer: {
                Text(AppLocalization.string("settings.subscriptions.localData.footer \(subscriptionCount)"))
            }
        }
    }

    // MARK: - Actions

    private func showImportPicker() {
        #if os(iOS)
        showingImportPicker = true
        #elseif os(macOS)
        showMacOSImportPanel()
        #endif
    }

    #if os(macOS)
    private func showMacOSImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.commaSeparatedText,
            UTType(filenameExtension: "opml") ?? .xml,
            UTType.xml
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = AppLocalization.string("settings.subscriptions.import.panel.message")

        if panel.runModal() == .OK, let url = panel.url {
            handleImportedFile(url)
        }
    }
    #endif

    private func handleImportedFile(_ url: URL) {
        isImporting = true

        Task {
            do {
                // Read file data
                let data: Data
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    data = try Data(contentsOf: url)
                } else {
                    data = try Data(contentsOf: url)
                }

                // Parse subscriptions
                let parseResult = try SubscriptionImportExport.parseAuto(data)

                guard let dataManager else {
                    throw SubscriptionImportError.invalidData
                }
                let importStats = dataManager.importSubscriptionsFromExternal(parseResult.channels)

                await MainActor.run {
                    isImporting = false
                    importResult = (imported: importStats.imported, skipped: importStats.skipped, format: parseResult.format)
                    showingImportResult = true
                    LoggingService.shared.logSubscriptions("Import completed: \(importStats.imported) imported, \(importStats.skipped) skipped")
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                    showingImportError = true
                    LoggingService.shared.logSubscriptionsError("Import failed", error: error)
                }
            }
        }
    }

    private func exportSubscriptions() {
        isExporting = true
        Task {
            await performExport()
            isExporting = false
        }
    }

    /// Exports subscriptions from the local source of truth.
    private func performExport() async {
        guard let dataManager else { return }
        let subscriptions = dataManager.allSubscriptions

        let data: Data?
        switch selectedExportFormat {
        case .json:
            data = SubscriptionImportExport.exportToJSON(subscriptions)
        case .opml:
            data = SubscriptionImportExport.exportToOPML(subscriptions)
        }

        guard let exportData = data else {
            LoggingService.shared.logSubscriptionsError("Failed to generate export data")
            return
        }

        let filename = SubscriptionImportExport.generateExportFilename(format: selectedExportFormat)

        #if os(iOS)
        // Write to temp file and share
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try exportData.write(to: tempURL)
            exportFile = ExportFile(url: tempURL)
        } catch {
            LoggingService.shared.logSubscriptionsError("Failed to write export file", error: error)
        }
        #elseif os(macOS)
        showMacOSSavePanel(data: exportData, filename: filename)
        #endif
    }

    private func deleteLocalSubscriptions() {
        dataManager?.deleteAllSubscriptions()
        appEnvironment?.toastManager.showSuccess(AppLocalization.string("settings.subscriptions.localData.deleted.title"))
    }

    #if os(macOS)
    private func showMacOSSavePanel(data: Data, filename: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = selectedExportFormat == .json ? [.json] : [UTType(filenameExtension: "opml") ?? .xml]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                LoggingService.shared.logSubscriptions("Exported subscriptions to \(url.path)")
            } catch {
                LoggingService.shared.logSubscriptionsError("Failed to save export", error: error)
            }
        }
    }
    #endif
}

// MARK: - File Picker (iOS)

#if os(iOS)
struct SubscriptionFilePickerView: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .commaSeparatedText,
            UTType(filenameExtension: "opml") ?? .xml,
            .xml,
            .text
        ]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void

        init(onSelect: @escaping (URL) -> Void) {
            self.onSelect = onSelect
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onSelect(url)
        }
    }
}
#endif

// MARK: - Preview

#Preview {
    NavigationStack {
        SubscriptionsSettingsView()
    }
    .appEnvironment(.preview)
}
#endif
