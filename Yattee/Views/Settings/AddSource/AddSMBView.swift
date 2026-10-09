//
//  AddSMBView.swift
//  Yattee
//
//  View for adding an SMB (Samba) share as a media source.
//

import SwiftUI

struct AddSMBView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    // MARK: - State

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var protocolVersion: SMBProtocol = .auto

    @State private var isTesting = false
    @State private var testResult: SourceTestResult?
    @State private var testProgress: String?

    // Pre-filled from network discovery
    var prefillServer: String?
    var prefillName: String?

    // Closure to dismiss the parent sheet
    var dismissSheet: DismissAction?

    // MARK: - Computed Properties

    private var canAdd: Bool {
        !name.isEmpty && !server.isEmpty
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
            serverSection
            authSection
            protocolSection

            if let result = testResult {
                SourceTestResultSection(result: result)
            }

            actionSection
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        #if !os(tvOS)
        .reactiveNavigationTitle(AppLocalization.string("sources.addSMB"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #endif
        .onAppear {
            if let prefillServer {
                server = prefillServer
            }
            if let prefillName, name.isEmpty {
                name = prefillName
            }
        }
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
                LabeledContent(AppLocalization.string("sources.placeholder.smbServer")) {
                    TextField("", text: $server)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text(AppLocalization.string("sources.footer.smb"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(AppLocalization.string("sources.field.usernameOptional")) {
                    TextField("", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                }
                LabeledContent(AppLocalization.string("sources.field.passwordOptional")) {
                    SecureField("", text: $password)
                        .textContentType(.password)
                }
            } header: {
                Text(AppLocalization.string("sources.header.auth"))
            } footer: {
                Text(AppLocalization.string("sources.footer.auth"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(AppLocalization.string("sources.field.smbProtocol"), selection: $protocolVersion) {
                    ForEach(SMBProtocol.allCases, id: \.self) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }
            } header: {
                Text(AppLocalization.string("sources.header.advanced"))
            } footer: {
                Text(AppLocalization.string("sources.footer.smbProtocol"))
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
        .reactiveNavigationTitle(AppLocalization.string("sources.addSMB"))
        .toolbar {
            if usesToolbarActionButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        addSource()
                    } label: {
                        if isTesting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(testProgress ?? AppLocalization.string("sources.testing"))
                            }
                        } else {
                            Text(AppLocalization.string("sources.addSource"))
                        }
                    }
                    .disabled(!canAdd || isTesting)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            if let prefillServer {
                server = prefillServer
            }
            if let prefillName, name.isEmpty {
                name = prefillName
            }
        }
    }
    #endif

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            #if os(tvOS)
            TVSettingsTextField(title: AppLocalization.string("sources.field.name"), text: $name)
            #else
            TextField(AppLocalization.string("sources.field.name"), text: $name)
            #endif
        } footer: {
            Text(AppLocalization.string("sources.footer.displayName"))
        }
    }

    private var serverSection: some View {
        Section {
            #if os(tvOS)
            TVSettingsTextField(title: AppLocalization.string("sources.placeholder.smbServer"), text: $server)
            #else
            TextField(AppLocalization.string("sources.placeholder.smbServer"), text: $server, prompt: Text(AppLocalization.string("sources.placeholder.smbServer")))
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            #endif
        } footer: {
            Text(AppLocalization.string("sources.footer.smb"))
        }
    }

    private var authSection: some View {
        Section {
            #if os(tvOS)
            TVSettingsTextField(title: AppLocalization.string("sources.field.usernameOptional"), text: $username)
            TVSettingsTextField(title: AppLocalization.string("sources.field.passwordOptional"), text: $password, isSecure: true)
            #else
            TextField(AppLocalization.string("sources.field.usernameOptional"), text: $username)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            SecureField(AppLocalization.string("sources.field.passwordOptional"), text: $password)
                .textContentType(.password)
            #endif
        } header: {
            Text(AppLocalization.string("sources.header.auth"))
        } footer: {
            Text(AppLocalization.string("sources.footer.auth"))
        }
    }

    private var protocolSection: some View {
        Section {
            Picker(AppLocalization.string("sources.field.smbProtocol"), selection: $protocolVersion) {
                ForEach(SMBProtocol.allCases, id: \.self) { proto in
                    Text(proto.displayName).tag(proto)
                }
            }
        } header: {
            Text(AppLocalization.string("sources.header.advanced"))
        } footer: {
            Text(AppLocalization.string("sources.footer.smbProtocol"))
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                addSource()
            } label: {
                if isTesting {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(testProgress ?? AppLocalization.string("sources.testing"))
                    }
                } else {
                    Text(AppLocalization.string("sources.addSource"))
                }
            }
            .disabled(!canAdd || isTesting)
            #if os(tvOS)
            .buttonStyle(TVSettingsButtonStyle())
            #endif
        }
    }

    // MARK: - Actions

    private func addSource() {
        guard let appEnvironment else { return }

        let urlString = "smb://\(server)"
        guard let encodedURLString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedURLString) else {
            testResult = .failure(AppLocalization.string("sources.error.invalidSMBAddress"))
            return
        }

        isTesting = true
        testResult = nil
        testProgress = AppLocalization.string("sources.testing.connecting")

        let source = MediaSource.smb(
            name: name,
            url: url,
            username: username.isEmpty ? nil : username,
            protocolVersion: protocolVersion
        )

        Task {
            do {
                _ = try await appEnvironment.smbClient.testConnection(
                    source: source,
                    password: password.isEmpty ? nil : password
                )

                await MainActor.run {
                    if !password.isEmpty {
                        appEnvironment.mediaSourcesManager.setPassword(password, for: source)
                    }

                    appEnvironment.mediaSourcesManager.add(source)
                    isTesting = false
                    testProgress = nil
                    if let dismissSheet {
                        dismissSheet()
                    } else {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testProgress = nil
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AddSMBView()
            .appEnvironment(.preview)
    }
}
