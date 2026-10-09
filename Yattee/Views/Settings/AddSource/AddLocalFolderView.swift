//
//  AddLocalFolderView.swift
//  Yattee
//
//  View for adding a local folder as a media source.
//

import SwiftUI

#if !os(tvOS)
struct AddLocalFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    // MARK: - State

    @State private var name = ""
    @State private var selectedFolderURL: URL?
    @State private var testResult: SourceTestResult?

    #if os(iOS)
    @State private var showingFolderPicker = false
    #endif

    // Closure to dismiss the parent sheet
    var dismissSheet: DismissAction?

    // MARK: - Computed Properties

    private var canAdd: Bool {
        !name.isEmpty && selectedFolderURL != nil
    }

    /// macOS surfaces toolbar confirmation items from a pushed-in-sheet view
    /// reliably only from macOS 26 onward. On older macOS we render the
    /// "Add Source" action button inline in the form instead.
    private var usesToolbarActionButton: Bool {
        #if os(macOS)
        if #available(macOS 26, *) {
            return true
        } else {
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Body

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        Form {
            nameSection
            folderSection

            if let result = testResult {
                SourceTestResultSection(result: result)
            }

            actionSection
        }
        .reactiveNavigationTitle(AppLocalization.string("sources.addLocalFolder"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerView { url in
                handleFolderSelection(url)
            }
        }
        #endif
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        Form {
            Section {
                LabeledContent(AppLocalization.string("sources.field.name")) {
                    TextField("", text: $name)
                }
            } footer: {
                Text(AppLocalization.string("sources.footer.displayName"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(AppLocalization.string("sources.header.folder")) {
                    HStack {
                        if let url = selectedFolderURL {
                            Text(url.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Text(AppLocalization.string("sources.selectFolder"))
                                .foregroundStyle(.secondary)
                        }
                        Button(AppLocalization.string("sources.selectFolder")) {
                            selectFolderMacOS()
                        }
                    }
                }
            } footer: {
                Text(AppLocalization.string("sources.footer.folder"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let result = testResult {
                SourceTestResultSection(result: result)
            }

            if !usesToolbarActionButton {
                actionSection
            }
        }
        .formStyle(.grouped)
        .reactiveNavigationTitle(AppLocalization.string("sources.addLocalFolder"))
        .toolbar {
            if usesToolbarActionButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("sources.addSource")) {
                        addSource()
                    }
                    .disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
    #endif

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(AppLocalization.string("sources.field.name"), text: $name)
        } footer: {
            Text(AppLocalization.string("sources.footer.displayName"))
        }
    }

    private var folderSection: some View {
        Section {
            #if os(iOS)
            Button {
                showingFolderPicker = true
            } label: {
                HStack {
                    if let url = selectedFolderURL {
                        Label(url.lastPathComponent, systemImage: "folder.fill")
                    } else {
                        Label(AppLocalization.string("sources.selectFolder"), systemImage: "folder.badge.plus")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            #elseif os(macOS)
            Button {
                selectFolderMacOS()
            } label: {
                HStack {
                    if let url = selectedFolderURL {
                        Label(url.lastPathComponent, systemImage: "folder.fill")
                    } else {
                        Label(AppLocalization.string("sources.selectFolder"), systemImage: "folder.badge.plus")
                    }
                    Spacer()
                }
            }
            #endif
        } header: {
            Text(AppLocalization.string("sources.header.folder"))
        } footer: {
            Text(AppLocalization.string("sources.footer.folder"))
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                addSource()
            } label: {
                Text(AppLocalization.string("sources.addSource"))
            }
            .disabled(!canAdd)
        }
    }

    // MARK: - Actions

    private func handleFolderSelection(_ url: URL) {
        selectedFolderURL = url
        if name.isEmpty {
            name = url.lastPathComponent
        }
    }

    #if os(macOS)
    private func selectFolderMacOS() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            handleFolderSelection(url)
        }
    }
    #endif

    private func addSource() {
        guard let appEnvironment,
              let url = selectedFolderURL else { return }

        Task {
            do {
                let bookmarkData = try await appEnvironment.localFileClient.createBookmark(for: url)

                await MainActor.run {
                    let source = MediaSource.localFolder(
                        name: name,
                        url: url,
                        bookmarkData: bookmarkData
                    )
                    appEnvironment.mediaSourcesManager.add(source)
                    if let dismissSheet {
                        dismissSheet()
                    } else {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(AppLocalization.string("sources.error.folderAccess \(error.localizedDescription)"))
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AddLocalFolderView()
            .appEnvironment(.preview)
    }
}
#endif
