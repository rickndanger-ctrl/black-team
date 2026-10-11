import SwiftUI
import AppKit
import BlackTeamKit

/// Navigation, projects with their conversations nested under them, and the conversations that belong to none
/// (`.app-sidebar` in app.css).
struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btFlatLayout) private var flat
    @Environment(\.btMetrics) private var metrics
    @AppStorage(ThemeSetting.storageKey) private var storedTheme = ThemeSetting.system.rawValue
    @State private var naming: String?
    @State private var renaming: String?
    @State private var renameText = ""

    private var loose: [ThreadSummary] {
        model.threads.filter { item in item.project == nil || !model.projects.contains { $0.id == item.project } }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                BrandWordmark().padding(.bottom, 30)
                Text("CONTROL ROOM").font(BTFont.mono(9)).tracking(1.44).foregroundStyle(theme.faint)
                    .frame(height: 13.5).padding(.horizontal, 12).padding(.bottom, 10)
                VStack(spacing: 2) {
                    navRow("Workspace", .grid, selected: model.page == .workspace) { model.navigate(.workspace) }
                    navRow("Chat / Code", .chat, selected: model.page == .conversation) { model.showMode(model.currentKind) }
                    navRow("Memory", .activity, selected: model.page == .memory) { model.navigate(.memory) }
                    navRow("Settings", .chip, selected: model.page == .settings) { model.navigate(.settings) }
                }
                .padding(.bottom, 26)
                lists
                Spacer(minLength: 0)
                ThemePicker(stored: $storedTheme)
                footer
            }
            .padding(.top, metrics.sidebarTop).padding(.horizontal, metrics.sidebarSide).padding(.bottom, 20)
            .frame(width: metrics.sidebarWidth - 1, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(theme.line).frame(width: 1)
        }
        .frame(width: metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(theme.sidebar.ignoresSafeArea())
    }

    // MARK: Navigation

    private func navRow(_ title: String, _ icon: BTIcon, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IconView(icon, size: 16)
                Text(title).font(BTFont.body(12.5, .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? theme.ink : theme.muted)
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? theme.surface2 : .clear))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 2).padding(.vertical, 11) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Projects and conversations

    @ViewBuilder private var lists: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            heading("Projects", help: "New project", expanded: naming != nil) { naming = naming == nil ? "" : nil }
            if let name = naming {
                BTTextField("Project name", text: Binding(get: { name }, set: { naming = String($0.prefix(60)) }), compactHeight: 30)
                    .onSubmit { let value = name; naming = nil; Task { await model.createProject(name: value) } }
                    .onExitCommand { naming = nil }
                    .padding(.leading, 12).padding(.trailing, 4).padding(.bottom, 6)
            }
            if model.projects.isEmpty {
                if naming == nil { sideNote("Press + to start a project.") }
            } else {
                ForEach(model.projects, id: \.id) { project in projectBlock(project) }
            }
            heading("Conversations", help: "New conversation", expanded: false) { model.startChat(model.currentKind) }
            if loose.isEmpty { sideNote("Your conversations will appear here.") }
            ForEach(loose, id: \.id) { item in conversationRow(item, nested: false) }
        }
        .padding(.top, 8).padding(.bottom, 20)
        if flat { content.frame(maxWidth: .infinity, alignment: .topLeading) } else {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }.scrollIndicators(.automatic).frame(minHeight: 40)
        }
    }

    private func heading(_ title: String, help: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(title.uppercased()).font(BTFont.mono(9)).tracking(1.44).foregroundStyle(theme.faint)
            Spacer(minLength: 0)
            Button(action: action) {
                Text(expanded ? "\u{00D7}" : "+").font(BTFont.body(13)).foregroundStyle(theme.muted)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.line2, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.locked)
            .help(help).accessibilityLabel(help)
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.top, 10).padding(.bottom, 4)
    }

    private func sideNote(_ text: String) -> some View {
        Text(text).btBody(11, 1.5, theme.faint).padding(.leading, 12).padding(.trailing, 12).padding(.top, 2).padding(.bottom, 6)
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
                    if !mine.isEmpty { Text("\(mine.count)").font(BTFont.mono(10)).foregroundStyle(theme.faint) }
                }
                .foregroundStyle(open ? theme.ink : theme.ink2)
                .padding(.horizontal, 13).padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(open ? theme.surface2 : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(.clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!project.exists || model.locked)
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.workspace)]) }
                    .disabled(!project.exists)
            }
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                if mine.isEmpty { Text("No conversations yet. Send a message to start.").btBody(11, 1.5, theme.faint).padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6) }
                ForEach(mine, id: \.id) { conversationRow($0, nested: true) }
            }
        }
    }

    private func conversationRow(_ item: ThreadSummary, nested: Bool) -> some View {
        let selected = model.threadId == item.id && model.page == .conversation
        return Group {
            if renaming == item.id {
                BTTextField("Title", text: $renameText, compactHeight: 30)
                    .onSubmit { let id = item.id, text = renameText; renaming = nil; Task { await model.rename(id, to: text) } }
                    .onExitCommand { renaming = nil }
            } else {
                Button { model.openConversation(item) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title.isEmpty ? "Untitled conversation" : item.title).font(BTFont.body(12)).lineSpacing(max(0, 12 * 1.45 - BTFont.natural(12)))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        Text("\(item.kind == "agent" ? "Code" : "Chat") \u{00B7} \(Fmt.shortDate(iso: item.updated))")
                            .font(BTFont.mono(9)).tracking(0.72).foregroundStyle(theme.faint).padding(.top, 5)
                    }
                    .foregroundStyle(selected ? theme.ink : theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? theme.surface2 : .clear))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? theme.line : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.locked)
                .contextMenu {
                    Button("Rename\u{2026}") { renameText = item.title; renaming = item.id }
                        .disabled(model.activeJob && model.status?.job?.threadId == item.id)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.leading, nested ? 14 : 0)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(theme.ok).frame(width: 6, height: 6)
                Text("ON THIS COMPUTER").font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.ink2)
            }
            .frame(height: 14.4)
            Text("Your model. Your conversations.").btBody(11, 1.5, theme.muted).padding(.vertical, 6 - 0)
            Text("BLACK TEAM \(model.version)").font(BTFont.mono(9)).tracking(0.36).foregroundStyle(theme.faint).frame(height: 14.4)
        }
        .padding(.top, 14).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .btRule()
        .padding(.top, 14)
    }
}

/// The Covert / Light / Ghost picker at the foot of the sidebar (`.theme-picker`).
struct ThemePicker: View {
    @Binding var stored: String
    @Environment(\.btTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach([ThemeSetting.covert, .light, .ghost]) { option in
                let selected = theme.id.rawValue == option.rawValue
                Button { stored = option.rawValue } label: {
                    Text(option.label).font(BTFont.mono(9)).tracking(1.08)
                        .foregroundStyle(selected ? theme.ink : theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.surface2 : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? theme.line2 : .clear, lineWidth: 1))
                        .btShadow(selected ? theme.shadow : .none)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        .accessibilityLabel("Appearance")
    }
}
