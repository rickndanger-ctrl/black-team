import SwiftUI
import BlackTeamKit

/// What the local models remember (Memory.jsx): graph, notes, projects, search, the keeper's log.
struct MemoryPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MemoryContent(model: model, memory: model.memory)
            .task { await model.memory.load(model) }
            .onChange(of: model.status?.threads.count) { _ in Task { await model.memory.load(model) } }
    }
}

struct MemoryContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var memory: MemoryModel
    @Environment(\.btTheme) private var theme
    @Environment(\.btMetrics) private var metrics
    @Environment(\.btFlatLayout) private var flat

    var body: some View {
        if model.status?.memory != true {
            BTBanner(kind: .notice, message: "Memory is unavailable.")
        } else if let data = memory.data {
            // `.memory { display: grid; gap: 14px }`
            VStack(alignment: .leading, spacing: 14) {
                bar
                usage(data)
                if !memory.message.isEmpty { Text(memory.message).btBody(12, 1.5, theme.ink2) }
                if data.notes.allSatisfy({ $0.kind == .core }) && !data.coreWritten { intro }
                if let hits = memory.hits { results(hits) }
                else {
                    switch memory.tab {
                    case .graph: graph(data)
                    case .notes: notes(data)
                    case .projects: projects
                    }
                }
                if !data.keeper.actions.isEmpty, memory.tab != .notes, memory.hits == nil { keeper(data.keeper.actions) }
            }
            .confirmationDialog("Move \u{201C}\(memory.note?.title ?? "")\u{201D} to the vault\u{2019}s trash?", isPresented: $memory.confirmDelete, titleVisibility: .visible) {
                Button("Move to trash", role: .destructive) { Task { await memory.remove() } }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            Text("Opening memory\u{2026}").btBody(12.5, 1.5, theme.muted).frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }

    // MARK: Bar and usage

    private var bar: some View {
        HStack(spacing: 10) {
            BTSegmented(options: [(MemoryTab.graph, "Graph"), (.notes, "Notes"), (.projects, "Projects")], selection: $memory.tab)
            BTTextField("Search memory", text: $memory.query, size: 12.5).frame(maxWidth: .infinity).frame(minWidth: 160).accessibilityLabel("Search memory")
            if let naming = memory.naming {
                HStack(spacing: 8) {
                    BTTextField("Name the new note", text: Binding(get: { naming }, set: { memory.naming = String($0.prefix(80)) }), size: 12.5)
                        .onSubmit { Task { await memory.create() } }.onExitCommand { memory.naming = nil }
                    Button("Create") { Task { await memory.create() } }.buttonStyle(.btPrimary).disabled(memory.busy || naming.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .frame(minWidth: 220)
            } else {
                Button("\u{FF0B} Note") { memory.naming = "" }.buttonStyle(.btSecondary).disabled(memory.busy)
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
    }

    private func usage(_ data: MemoryOverview) -> some View {
        let usage = data.keeper.usage
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("VAULT").font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.faint).frame(height: 11.9, alignment: .leading)
                Text("\(usage.notes) notes \u{00B7} \(usage.percent)% of limit").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink).frame(height: 19, alignment: .leading)
            }
            Rectangle().fill(theme.line).frame(height: 4)
                .overlay(alignment: .leading) { GeometryReader { geo in Rectangle().fill(theme.accent).frame(width: geo.size.width * CGFloat(min(100, usage.percent)) / 100) } }
                .clipShape(RoundedRectangle(cornerRadius: 4)).frame(maxWidth: .infinity)
            Text((usage.oversized.isEmpty ? "All notes within limits" : "\(usage.oversized.count) note\(usage.oversized.count > 1 ? "s" : "") over the per-note limit")
                 + (usage.archived > 0 ? " \u{00B7} \(usage.archived) archived" : ""))
                .font(BTFont.body(11)).foregroundStyle(theme.muted).lineLimit(1).fixedSize()
            Button("Tidy now") { Task { await memory.tidy() } }.buttonStyle(.btSecondary).disabled(memory.busy || model.status?.job?.state == "running")
                .environment(\.btControlHeight, 32)
        }
        .padding(.horizontal, 17).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
        .help("Everything in the Black Team vault, against its limit")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            (Text("Your vault is set up and waiting. ").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink)
             + Text("Code saves facts here as it works, and writes a journal for each project. Chat looks things up here for every message. ")
             + Text("Remember this").foregroundStyle(theme.ink)
             + Text(" under any reply saves it too. Nothing in this folder leaves your computer."))
                .font(BTFont.body(12.5)).foregroundStyle(theme.ink2).btLines(12.5, 1.7).padding(.bottom, 10)
            Text("Start with Core: a few lines every conversation is told, such as how you like answers and what you are working on.")
                .btBody(12.5, 1.7, theme.ink2).padding(.bottom, 10)
            HStack { Button("Write Core") { Task { await memory.open("Core") } }.buttonStyle(.btPrimary).disabled(memory.busy); Spacer(minLength: 0) }.padding(.top, 4)
        }
        .padding(.horizontal, 23).padding(.vertical, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line2, lineWidth: 1))
        .padding(.bottom, 2)
    }

    // MARK: Tabs

    private func graph(_ data: MemoryOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MemoryGraphView(graph: data.graph, positions: memory.positions, selected: memory.note?.id) { id in Task { await memory.open(id) } }
            HStack(spacing: 14) {
                legend(theme.accent, "Project memory"); legend(theme.muted, "General notes"); legend(theme.ok, "Core"); legend(.clear, "Linked, not written yet", hollow: true)
                Spacer(minLength: 0)
                Text("\(data.graph.nodes.filter { !$0.missing }.count) notes \u{00B7} \(data.graph.edges.count) links \u{00B7} click a note to open it")
                    .font(BTFont.body(11)).foregroundStyle(theme.faint)
            }
        }
    }

    private func legend(_ color: Color, _ text: String, hollow: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(hollow ? .clear : color)
                .overlay(Circle().stroke(theme.line2, style: StrokeStyle(lineWidth: 1, dash: hollow ? [2, 2] : [])).opacity(hollow ? 1 : 0))
                .frame(width: 9, height: 9)
            Text(text).font(BTFont.body(11)).foregroundStyle(theme.muted)
        }
    }

    private func notes(_ data: MemoryOverview) -> some View {
        var groups: [(String, [NoteSummary])] = []
        for note in data.notes where note.kind != .archive {
            let folder = note.id.contains("/") ? String(note.id[..<note.id.lastIndex(of: "/")!]) : "Vault"
            if let at = groups.firstIndex(where: { $0.0 == folder }) { groups[at].1.append(note) } else { groups.append((folder, [note])) }
        }
        return notesBody(groups)
    }

    private func notesBody(_ groups: [(String, [NoteSummary])]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.0) { folder, list in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(folder).font(BTFont.mono(9)).tracking(0.9).foregroundStyle(theme.faint)
                            .frame(height: 11.9, alignment: .leading).padding(.leading, 10).padding(.bottom, 6)
                        ForEach(list, id: \.id) { note in
                            Button { Task { await memory.open(note.id) } } label: {
                                Text(note.title).btBody(12, 1.5, memory.note?.id == note.id ? theme.ink : theme.ink2)
                                    .padding(.horizontal, 10).padding(.vertical, 8 - 0).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(memory.note?.id == note.id ? theme.surface2 : .clear))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
            .padding(.trailing, 4)
            .frame(width: 240, alignment: .topLeading)
            editor.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 420, alignment: .topLeading)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = memory.note {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(note.title).font(BTFont.body(15, .semibold)).foregroundStyle(theme.ink).frame(height: 22.5, alignment: .leading)
                        Text("\(note.id).md \u{00B7} \(Date(timeIntervalSince1970: note.updated / 1000).formatted(date: .numeric, time: .standard))")
                            .font(BTFont.mono(10)).foregroundStyle(theme.faint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Button("Delete") { memory.confirmDelete = true }.buttonStyle(.btSecondary).disabled(memory.busy)
                        Button(memory.dirty ? "Save" : "Saved") { Task { await memory.save() } }.buttonStyle(.btPrimary)
                            .disabled(memory.busy || !memory.dirty).keyboardShortcut("s", modifiers: .command)
                    }
                }
                noteField(note)
                Text("Markdown. Link notes with [[Note name]]. The note named Core is told to every conversation. Stored only in the Black Team vault on this computer.")
                    .btBody(10.5, 1.5, theme.faint)
            } else {
                Text("Choose a note, or open one from the graph.").btBody(12.5, 1.5, theme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
    }

    /// The note's text: 13 point mono on a 1.7 line in a 10 point card, at least 46 percent of the window high.
    @ViewBuilder private func noteField(_ note: OpenNote) -> some View {
        let minHeight = metrics.windowHeight * 0.46
        if flat {
            Text(memory.draft).btBody(13, 1.7, theme.ink, mono: true)
                .padding(.horizontal, 19).padding(.vertical, 17)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
        } else {
            TextEditor(text: $memory.draft)
                .font(BTFont.mono(13)).lineSpacing(13 * 1.7 - BTFont.natural(13, mono: true)).scrollContentBackground(.hidden).foregroundStyle(theme.ink)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .frame(minHeight: minHeight)
                .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
                .accessibilityLabel("Note \(note.title)")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 21).padding(.vertical, 19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
            .padding(.bottom, 14)
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text).font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.faint).frame(height: 11.9, alignment: .leading).padding(.bottom, 8)
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 0) {
            card {
                cardLabel("NEW PROJECT")
                Text("Start a project").font(BTFont.body(16, .semibold)).foregroundStyle(theme.ink).btLines(16, 1.5)
                Text("A project gets a folder inside your workspace and its own notes and journal in memory. Code conversations in that folder are journaled automatically.")
                    .btBody(12.5, 1.7, theme.ink2).padding(.top, 8).padding(.bottom, 14)
                HStack(spacing: 8) {
                    BTTextField("Project name", text: Binding(get: { memory.projectName }, set: { memory.projectName = String($0.prefix(60)) }), size: 12.5)
                        .onSubmit { if !memory.projectName.trimmingCharacters(in: .whitespaces).isEmpty { Task { await memory.createProject() } } }
                        .disabled(memory.busy)
                    Button("Create project") { Task { await memory.createProject() } }.buttonStyle(.btPrimary)
                        .disabled(memory.busy || memory.projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if model.projects.isEmpty {
                Text("No projects yet.").btBody(12.5, 1.5, theme.muted).frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ForEach(model.projects, id: \.id) { project in
                    card {
                        cardLabel(project.exists ? "PROJECT" : "FOLDER MISSING")
                        Text(project.name).font(BTFont.body(16, .semibold)).foregroundStyle(theme.ink).btLines(16, 1.5)
                        Text(project.workspace).btBody(12.5, 1.7, theme.ink2).padding(.top, 8).padding(.bottom, 14)
                        HStack(spacing: 10) {
                            Button("Work on it in Code") { model.openProject(project) }.buttonStyle(.btPrimary).disabled(!project.exists)
                            Button("Open its notes") { Task { await memory.open("\(project.notes)/Overview") } }.buttonStyle(.btSecondary)
                        }
                    }
                }
            }
        }
    }

    private func results(_ hits: [SearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if hits.isEmpty { Text("Nothing matches.").btBody(12.5, 1.5, theme.muted).frame(maxWidth: .infinity).padding(.vertical, 40) }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                Button { Task { await memory.open(hit.id) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.title).font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink)
                        Text("\(hit.id) \u{00B7} line \(hit.line)").font(BTFont.mono(10)).foregroundStyle(theme.faint)
                        Text(hit.text).btBody(12, 1.5, theme.ink2)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func keeper(_ actions: [KeeperEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KEEPER \u{00B7} RECENT UPKEEP").font(BTFont.mono(9)).tracking(1.26).foregroundStyle(theme.faint).frame(height: 11.9, alignment: .leading).padding(.bottom, 8)
            ForEach(Array(actions.prefix(5).enumerated()), id: \.offset) { _, action in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Date(timeIntervalSince1970: action.at / 1000).formatted(date: .numeric, time: .omitted)).font(BTFont.mono(10)).foregroundStyle(theme.faint)
                    Text(action.text).btBody(12, 1.5, theme.ink2)
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(theme.line, lineWidth: 1))
    }
}
