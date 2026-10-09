//
//  FileCommands.swift
//  Yattee
//
//  Menu bar commands for file operations.
//

import SwiftUI

#if !os(tvOS)
/// File-related menu bar commands.
struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(AppLocalization.string("menu.file.openLink")) {
                NotificationCenter.default.post(name: .showOpenLinkSheet, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }
}
#endif

#if os(macOS)
/// App menu Settings… item that opens the dedicated Settings window.
struct SettingsWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AppLocalization.string("menu.app.settings")) {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: [.command])
    }
}
#endif
