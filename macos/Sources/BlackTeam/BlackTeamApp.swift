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
        Window("Black Team Agent", id: "main") {
            CommandRoot(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands { AppCommands(model: model) }

        Window("Black Team Camp", id: "camp") {
            CampRoot(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
    }
}

/// The menu bar: New Conversation, Command Center, Base Camp, Stop and a normal About panel.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Black Team Agent") { model.showAbout() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { model.openCamp = { openWindow(id: "camp"); NSApp.activate(ignoringOtherApps: true) }; model.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Window") {
            Button("Command Center") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("1", modifiers: .command)
            Button("Base Camp") { openWindow(id: "camp"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Stop") { model.stopResponse() }.keyboardShortcut(".", modifiers: .command).disabled(!model.canStopResponse)
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
