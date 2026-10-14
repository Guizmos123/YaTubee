//
//  MiniPlayerEditorView.swift
//  Yattee
//
//  Settings editor for mini player behavior.
//

import SwiftUI

struct MiniPlayerEditorView: View {
    @Bindable var viewModel: PlayerControlsSettingsViewModel

    // Local state for immediate UI updates
    @State private var showVideo: Bool = true
    @State private var videoTapAction: MiniPlayerVideoTapAction = .startPiP

    var body: some View {
        List {
            previewSection
            videoSection
            if viewModel.miniPlayerStyle.supportsCustomizableButtons {
                buttonsSection
                addButtonSection
            }
        }
        .reactiveNavigationTitle(AppLocalization.string("settings.playerControls.miniPlayer"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #elseif os(macOS)
        .formStyle(.grouped)
        #endif
        .opaqueSettingsFormBackground()
        .onAppear {
            syncLocalState()
        }
        .onChange(of: viewModel.activePreset?.id) { _, _ in
            syncLocalState()
        }
    }

    // MARK: - Preview and Style

    private var previewSection: some View {
        Section {
            MiniPlayerPreviewView(
                style: viewModel.miniPlayerStyle,
                buttons: viewModel.miniPlayerButtons,
                controlsFadeOpacity: viewModel.currentLayout.globalSettings.controlsFadeOpacity
            )
            .frame(height: 200)
            .listRowInsets(EdgeInsets())

            Picker(
                AppLocalization.string("settings.playerControls.miniPlayer.style"),
                selection: Binding(
                    get: { viewModel.miniPlayerStyle },
                    set: { viewModel.syncMiniPlayerStyle($0) }
                )
            ) {
                ForEach(MiniPlayerStyle.allCases, id: \.self) { style in
                    Text(styleName(style)).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .disabled(!viewModel.canEditActivePreset)
        }
    }

    // MARK: - Video Section

    private var videoSection: some View {
        Section {
            Toggle(
                AppLocalization.string("settings.behavior.miniPlayer.showVideo"),
                isOn: $showVideo
            )
            .disabled(!viewModel.canEditActivePreset)
            .onChange(of: showVideo) { _, newValue in
                guard newValue != viewModel.miniPlayerShowVideo else { return }
                viewModel.syncMiniPlayerShowVideo(newValue)
            }

            if showVideo {
                Picker(
                    AppLocalization.string("settings.behavior.miniPlayer.videoTapAction"),
                    selection: $videoTapAction
                ) {
                    ForEach(MiniPlayerVideoTapAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .disabled(!viewModel.canEditActivePreset)
                .onChange(of: videoTapAction) { _, newValue in
                    guard newValue != viewModel.miniPlayerVideoTapAction else { return }
                    viewModel.syncMiniPlayerVideoTapAction(newValue)
                }
            }
        } header: {
            Text(AppLocalization.string("settings.behavior.miniPlayer.video.header"))
        } footer: {
            Text(AppLocalization.string("settings.behavior.miniPlayer.showVideo.footer"))
        }
    }

    // MARK: - Buttons Section

    private var buttonsSection: some View {
        Section {
            if viewModel.miniPlayerButtons.isEmpty {
                Text(AppLocalization.string("miniPlayer.buttons.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(viewModel.miniPlayerButtons.enumerated()), id: \.element.id) { _, config in
                    buttonRow(for: config)
                }
                .onMove { source, destination in
                    viewModel.moveMiniPlayerButtons(fromOffsets: source, toOffset: destination)
                }
                .onDelete { indexSet in
                    indexSet.forEach { viewModel.removeMiniPlayerButton(at: $0) }
                }
            }
        } header: {
            Text(AppLocalization.string("miniPlayer.buttons.header"))
        } footer: {
            Text(AppLocalization.string("miniPlayer.buttons.footer"))
        }
        .disabled(!viewModel.canEditActivePreset)
    }

    @ViewBuilder
    private func buttonRow(for config: ControlButtonConfiguration) -> some View {
        Group {
            if config.buttonType.hasSettings {
                NavigationLink {
                    MiniPlayerButtonConfigurationView(
                        buttonID: config.id,
                        viewModel: viewModel
                    )
                } label: {
                    buttonRowContent(for: config)
                }
            } else {
                buttonRowContent(for: config)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                if let index = viewModel.miniPlayerButtons.firstIndex(where: { $0.id == config.id }) {
                    viewModel.removeMiniPlayerButton(at: index)
                }
            } label: {
                Label(
                    AppLocalization.string("settings.playerControls.delete"),
                    systemImage: "trash"
                )
            }
        }
    }

    @ViewBuilder
    private func buttonRowContent(for config: ControlButtonConfiguration) -> some View {
        HStack {
            Image(systemName: buttonIcon(for: config))
                .frame(width: 24)
                .foregroundStyle(.secondary)
            Text(config.buttonType.displayName)

            // Show configuration summary for configurable buttons
            if let summary = configurationSummary(for: config) {
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    /// Returns the appropriate icon for a button, using configuration-specific icons when available.
    private func buttonIcon(for config: ControlButtonConfiguration) -> String {
        if config.buttonType == .seek, let seekSettings = config.seekSettings {
            return seekSettings.systemImage
        }
        return config.buttonType.systemImage
    }

    /// Returns a summary string for buttons with configurable settings.
    private func configurationSummary(for config: ControlButtonConfiguration) -> String? {
        if config.buttonType == .seek, let seekSettings = config.seekSettings {
            return "\(seekSettings.seconds)s \(seekSettings.direction.displayName)"
        }
        return nil
    }

    // MARK: - Add Button Section

    private var addButtonSection: some View {
        Section {
            ForEach(availableButtons, id: \.self) { buttonType in
                Button {
                    viewModel.addMiniPlayerButton(buttonType)
                } label: {
                    HStack {
                        Image(systemName: buttonType.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        Text(buttonType.displayName)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } header: {
            Text(AppLocalization.string("miniPlayer.addButton.header"))
        }
        .disabled(!viewModel.canEditActivePreset)
    }

    // MARK: - Helpers

    /// Button types available to add (not already in the mini player).
    /// Seek buttons can be added multiple times (like spacers), others are unique.
    private var availableButtons: [ControlButtonType] {
        let usedTypes = Set(viewModel.miniPlayerButtons.map(\.buttonType))
        return ControlButtonType.availableForMiniPlayer.filter { buttonType in
            // Seek can be added multiple times (e.g., backward + forward)
            buttonType == .seek || !usedTypes.contains(buttonType)
        }
    }

    private func styleName(_ style: MiniPlayerStyle) -> String {
        switch style {
        case .bar:
            AppLocalization.string("settings.playerControls.miniPlayer.style.bar")
        case .video:
            AppLocalization.string("settings.playerControls.miniPlayer.style.video")
        case .bubble:
            AppLocalization.string("settings.playerControls.miniPlayer.style.bubble")
        }
    }

    private func syncLocalState() {
        showVideo = viewModel.miniPlayerShowVideo
        videoTapAction = viewModel.miniPlayerVideoTapAction
    }
}

// MARK: - Mini Player Preview

private struct MiniPlayerPreviewView: View {
    let style: MiniPlayerStyle
    let buttons: [ControlButtonConfiguration]
    let controlsFadeOpacity: Double

    private let buttonSize: CGFloat = 28
    private let buttonSpacing: CGFloat = 4
    private let previewCornerRadius: CGFloat = 8
    private let contentPadding: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width
            let containerHeight = geometry.size.height
            let previewHeight = min(
                containerHeight,
                containerWidth / MiniPlayerStyleMetrics.videoAspectRatio
            )

            previewCanvas(width: containerWidth, height: previewHeight)
                .frame(width: containerWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius))
                .position(x: containerWidth / 2, y: containerHeight / 2)
        }
    }

    private func previewCanvas(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            PlayerControlsPreviewBackdrop(opacity: controlsFadeOpacity)
                .frame(width: width, height: height)

            previewContent(availableWidth: width - (contentPadding * 2))
                .padding(.horizontal, contentPadding)
                .padding(.bottom, contentPadding)
        }
        .frame(width: width, height: height, alignment: .bottom)
    }

    @ViewBuilder
    private func previewContent(availableWidth: CGFloat) -> some View {
        switch style {
        case .bar:
            barPreview
        case .video:
            videoPreview(availableWidth: availableWidth)
        case .bubble:
            bubblePreview
        }
    }

    private var barPreview: some View {
        HStack(spacing: 12) {
            // Video thumbnail placeholder (always shown - matches actual mini player behavior)
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 60, height: 34)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }

            // Title/channel placeholders
            VStack(alignment: .leading, spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 100, height: 12)

                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary.opacity(0.5))
                    .frame(width: 70, height: 10)
            }

            Spacer()

            // Buttons
            HStack(spacing: buttonSpacing) {
                ForEach(buttons) { config in
                    CompactPreviewButtonView(configuration: config, size: buttonSize)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func videoPreview(availableWidth: CGFloat) -> some View {
        let cardWidth = availableWidth * 0.68

        return Image("PlayerControlsPreviewBackground")
            .resizable()
            .scaledToFill()
            .frame(
                width: cardWidth,
                height: cardWidth / MiniPlayerStyleMetrics.videoAspectRatio
            )
            .clipped()
            .overlay(alignment: .topTrailing) {
                videoControls
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bubblePreview: some View {
        Image("PlayerControlsPreviewBackground")
            .resizable()
            .scaledToFill()
            .frame(
                width: MiniPlayerStyleMetrics.recommendedBubbleDiameter,
                height: MiniPlayerStyleMetrics.recommendedBubbleDiameter
            )
            .clipShape(Circle())
    }

    private var videoControls: some View {
        HStack(spacing: 2) {
            ForEach(MiniPlayerSettings.videoButtons(from: buttons)) { configuration in
                CompactPreviewButtonView(configuration: configuration, size: 24)
                    .glassBackground(.regular, in: .circle, fallback: .ultraThinMaterial)
            }
        }
        .allowsHitTesting(false)
    }

}

// MARK: - Mini Player Button Configuration View

/// View for configuring a single mini player button's settings.
struct MiniPlayerButtonConfigurationView: View {
    let buttonID: UUID
    @Bindable var viewModel: PlayerControlsSettingsViewModel

    // Local state for immediate UI updates
    @State private var seekSeconds: Double = 10
    @State private var seekDirection: SeekDirection = .forward

    /// Look up the current configuration from the view model's mini player settings.
    private var configuration: ControlButtonConfiguration? {
        viewModel.miniPlayerButtons.first { $0.id == buttonID }
    }

    var body: some View {
        if let config = configuration {
            Form {
                // Type-specific settings
                if config.buttonType.hasSettings {
                    typeSpecificSettings(for: config)
                }
            }
            .reactiveNavigationTitle(config.buttonType.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #elseif os(macOS)
            .formStyle(.grouped)
            #endif
            .opaqueSettingsFormBackground()
            .onAppear {
                syncFromConfiguration(config)
            }
        } else {
            ContentUnavailableView(
                AppLocalization.string("settings.playerControls.buttonNotFound"),
                systemImage: "exclamationmark.triangle"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sync from Configuration

    private func syncFromConfiguration(_ config: ControlButtonConfiguration) {
        switch config.settings {
        case .seek(let settings):
            seekSeconds = Double(settings.seconds)
            seekDirection = settings.direction
        default:
            break
        }
    }

    // MARK: - Type-Specific Settings

    @ViewBuilder
    private func typeSpecificSettings(for config: ControlButtonConfiguration) -> some View {
        switch config.buttonType {
        case .seek:
            seekSettingsSection
        default:
            EmptyView()
        }
    }

    // MARK: - Seek Settings

    @ViewBuilder
    private var seekSettingsSection: some View {
        Section {
            // Direction picker
            Picker(
                AppLocalization.string("settings.playerControls.seek.direction"),
                selection: $seekDirection
            ) {
                ForEach(SeekDirection.allCases, id: \.self) { direction in
                    Text(direction.displayName).tag(direction)
                }
            }
            .onChange(of: seekDirection) { _, newValue in
                updateSettings(.seek(SeekSettings(seconds: Int(seekSeconds), direction: newValue)))
            }

            #if !os(tvOS)
            HStack {
                Text(AppLocalization.string("settings.playerControls.seek.seconds"))
                Spacer()
                Text("\(Int(seekSeconds))s")
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: $seekSeconds,
                in: 1...60,
                step: 1
            )
            .onChange(of: seekSeconds) { _, newValue in
                updateSettings(.seek(SeekSettings(seconds: Int(newValue), direction: seekDirection)))
            }
            #endif

            // Quick presets
            HStack {
                ForEach([5, 10, 15, 30], id: \.self) { preset in
                    Button("\(preset)s") {
                        seekSeconds = Double(preset)
                        updateSettings(.seek(SeekSettings(seconds: preset, direction: seekDirection)))
                    }
                    .buttonStyle(.bordered)
                    .tint(Int(seekSeconds) == preset ? .accentColor : .secondary)
                }
            }
        } header: {
            Text(AppLocalization.string("settings.playerControls.seek.header"))
        }
    }

    // MARK: - Update Helpers

    private func updateSettings(_ settings: ButtonSettings) {
        guard var updated = configuration else { return }
        updated.settings = settings
        viewModel.updateMiniPlayerButtonConfiguration(updated)
    }
}
