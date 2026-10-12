import SwiftUI
import AppKit
import BlackTeamKit

/// The "Black Team Camp" window's sidebar (`.companion-nav`): pages, the way back to the Command center,
/// New conversation, projects with their conversations nested under them, conversations, theme switch and note.
struct CampSidebar: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btMetrics) private var metrics
    @AppStorage(ThemeSetting.storageKey) private var storedTheme = ThemeSetting.system.rawValue
    @State private var naming: String?
    @State private var renaming: String?
    @State private var renameText = ""
    /// The project the person is being asked about: allowing cloud models is confirmed once, on purpose.
    @State private var allowing: ProjectSummary?

    private var loose: [ThreadSummary] {
        model.threads.filter { item in item.project == nil || !model.projects.contains { $0.id == item.project } }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                BrandWordmark().padding(.bottom, 14)
                Text("WORKSPACE").font(BTFont.mono(9)).tracking(1.44).foregroundStyle(theme.faint).frame(height: 13.5).padding(.horizontal, 12)
                VStack(spacing: 2) {
                    NavRow(title: "Chat", selected: model.campPage == .chat) { model.showCamp(.chat) }
                    NavRow(title: "Room", selected: model.campPage == .room) { model.showCamp(.room) }
                    NavRow(title: "Memory", selected: model.campPage == .memory) { model.showCamp(.memory) }
                    NavRow(title: "Plugins", selected: model.campPage == .plugins) { model.showCamp(.plugins) }
                    NavRow(title: "Servers & access", selected: model.campPage == .servers) { model.showCamp(.servers) }
                    commandRow
                }
                Button { model.newConversation() } label: {
                    HStack(spacing: 8) { Text("\u{FF0B} New conversation").font(BTFont.body(12, .medium)); Spacer(minLength: 0) }
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 16).frame(height: 36)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.locked)
                .accessibilityLabel("New conversation")
                lists
                ThemePicker(stored: $storedTheme)
                TextWeightPicker().padding(.top, 6)
                Text(model.cloudSelected ? "Cloud \u{00B7} \(model.cloud.provider)" : "Private \u{00B7} On this computer").font(BTFont.mono(8)).tracking(1.12)
                    .foregroundStyle(model.cloudSelected ? theme.warn : theme.faint)
                    .lineSpacing(max(0, 8 * 1.7 - BTFont.natural(8, mono: true)))
                    .padding(.horizontal, 8).padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading).btRule()
            }
            .padding(.top, metrics.sidebarTop).padding(.horizontal, metrics.sidebarSide).padding(.bottom, 20)
            .frame(width: metrics.sidebarWidth - 1, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(theme.line).frame(width: 1)
        }
        .frame(width: metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(theme.sidebar.ignoresSafeArea())
        .confirmationDialog("Allow cloud models in \(allowing?.name ?? "this project")?", isPresented: Binding(get: { allowing != nil }, set: { if !$0 { allowing = nil } }), titleVisibility: .visible) {
            Button("Allow cloud models") { if let project = allowing { Task { await model.setProjectCloud(project, allowed: true) } }; allowing = nil }
            Button("Keep it local only", role: .cancel) { allowing = nil }
        } message: {
            Text("Conversations in this project may then use a cloud model. What you type, and in Code the files the agent reads and the output of its commands, are sent to that service. Conversations that use a local model still stay on this Mac.")
        }
    }

    /// `nav button.launch`: a hairline above, the grid icon, the name and an arrow.
    private var commandRow: some View {
        Button { model.openCommand() } label: {
            HStack(spacing: 11) {
                IconView(.grid, size: 16)
                Text("Command center").font(BTFont.body(12.5, .medium)).lineLimit(1)
                Spacer(minLength: 0)
                IconView(.arrow, size: 14).foregroundStyle(theme.faint)
            }
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 12).padding(.top, 8).frame(height: 46)
            .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel("Command center")
    }

    // MARK: Projects and conversations

    @ViewBuilder private var lists: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            heading("Projects", button: true)
            if let name = naming {
                BTTextField("Project name", text: Binding(get: { name }, set: { naming = String($0.prefix(60)) }), compactHeight: 30)
                    .onSubmit { let value = name; naming = nil; Task { await model.createProject(name: value) } }
                    .onExitCommand { naming = nil }
                    .padding(.leading, 12).padding(.trailing, 4).padding(.bottom, 4)
            }
            if model.projects.isEmpty {
                if naming == nil { sideNote("Press \u{FF0B} to start a project.") }
            } else {
                ForEach(model.projects, id: \.id) { project in projectBlock(project) }
            }
            heading("Conversations", button: false)
            ForEach(loose, id: \.id) { item in conversationRow(item, nested: false) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        if flat { content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
            ScrollView { content }.scrollIndicators(.automatic).frame(minHeight: 40)
        }
    }

    private func heading(_ title: String, button: Bool) -> some View {
        HStack(spacing: 0) {
            Text(title.uppercased()).font(BTFont.mono(9)).tracking(1.44).foregroundStyle(theme.faint)
            Spacer(minLength: 0)
            if button {
                Button { naming = naming == nil ? "" : nil } label: {
                    Text("\u{FF0B}").font(BTFont.body(13)).foregroundStyle(theme.muted)
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.locked)
                .help("New project").accessibilityLabel("New project")
            }
        }
        .frame(height: button ? 22 : 13.5)
        .padding(.leading, 12).padding(.trailing, 4).padding(.top, 10).padding(.bottom, 4)
    }

    private func sideNote(_ text: String) -> some View {
        Text(text).btBody(11, 1.5, theme.faint).padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
    }

    private func projectBlock(_ project: ProjectSummary) -> some View {
        let mine = model.threads.filter { $0.project == project.id }
        let open = model.projectId == project.id
        return VStack(alignment: .leading, spacing: 2) {
            Button { open ? model.leaveProject() : model.openProject(project) } label: {
                HStack(spacing: 9) {
                    IconView(.folder, size: 14).foregroundStyle(open ? theme.accent : theme.muted)
                    Text(project.name).font(BTFont.body(12, .medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if project.cloudAllowed { IconView(.globe, size: 12).foregroundStyle(theme.warn).help("Cloud models allowed in this project") }
                    if !mine.isEmpty { Text("\(mine.count)").font(BTFont.mono(10)).foregroundStyle(theme.faint) }
                }
                .foregroundStyle(open ? theme.ink : theme.ink2)
                .padding(.horizontal, 13).padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(open ? theme.surface2 : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!project.exists || model.locked)
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.workspace)]) }.disabled(!project.exists)
                if project.cloudAllowed {
                    Button("Make local only") { Task { await model.setProjectCloud(project, allowed: false) } }.disabled(model.busy)
                } else {
                    Button("Allow cloud models\u{2026}") { allowing = project }.disabled(model.busy)
                }
            }
            .accessibilityLabel(project.name)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                if mine.isEmpty { sideNote("No conversations yet. Send a message to start.") }
                ForEach(mine, id: \.id) { conversationRow($0, nested: true) }
            }
        }
    }

    private func conversationRow(_ item: ThreadSummary, nested: Bool) -> some View {
        let selected = model.threadId == item.id && model.campPage == .chat
        let title = item.title.isEmpty ? "Untitled conversation" : item.title
        return Group {
            if renaming == item.id {
                BTTextField("Title", text: $renameText, compactHeight: 30)
                    .onSubmit { let id = item.id, text = renameText; renaming = nil; Task { await model.rename(id, to: text) } }
                    .onExitCommand { renaming = nil }
            } else {
                Button { model.openConversation(item) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(BTFont.body(12)).lineSpacing(max(0, 12 * 1.45 - BTFont.natural(12)))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        Text("\(item.privacy == "cloud" ? "Cloud \u{00B7} \(item.provider)" : model.cloudSelected ? "On this Mac" : model.activeCard?.name ?? model.modelName) \u{00B7} \(item.kind == "agent" ? "Code" : "Chat")")
                            .font(BTFont.mono(9)).tracking(0.72).foregroundStyle(theme.faint).padding(.top, 5)
                    }
                    .foregroundStyle(selected ? theme.ink : theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 13).padding(.trailing, 10).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? theme.surface2 : .clear))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(selected ? theme.line : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.locked)
                .contextMenu {
                    Button("Rename\u{2026}") { renameText = item.title; renaming = item.id }
                        .disabled(model.activeJob && model.status?.job?.threadId == item.id)
                }
                .accessibilityLabel(title)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.leading, nested ? 14 : 0)
        .overlay(alignment: .leading) { if nested { Rectangle().fill(theme.line2).frame(width: 1).padding(.leading, 14) } }
    }
}
