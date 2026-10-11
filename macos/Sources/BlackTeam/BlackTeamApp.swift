import SwiftUI
import AppKit
import BlackTeamUI

@main
struct BlackTeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        Fonts.register()
    }

    var body: some Scene {
        Window("Black Team", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { AppCommands(model: model) }
    }
}

/// The menu bar: New Chat, New Code conversation, Settings, Stop response and a normal About panel.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Black Team") { model.showAbout() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { model.openSettings() }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { model.newChat() }.keyboardShortcut("n", modifiers: .command)
            Button("New Code Conversation") { model.newCodeConversation() }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Conversation") {
            Button("Stop Response") { model.stopResponse() }.keyboardShortcut(".", modifiers: .command).disabled(!model.canStopResponse)
            Divider()
            Button("Workspace") { model.goToWorkspace() }.keyboardShortcut("1", modifiers: .command)
            Button("Chat") { model.goToChat() }.keyboardShortcut("2", modifiers: .command)
            Button("Code") { model.goToCode() }.keyboardShortcut("3", modifiers: .command)
            Button("Memory") { model.goToMemory() }.keyboardShortcut("4", modifiers: .command)
        }
    }
}

/// Quits when the window closes and makes sure no model server is left running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
