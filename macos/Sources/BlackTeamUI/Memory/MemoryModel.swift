import SwiftUI
import BlackTeamKit

enum MemoryTab: String { case graph, notes, projects }

struct OpenNote: Equatable {
    var id: String
    var title: String
    var content: String
    var updated: Double
    init(id: String, title: String, content: String, updated: Double) { self.id = id; self.title = title; self.content = content; self.updated = updated }
    init(_ note: NoteContent) { self.init(id: note.id, title: note.title, content: note.content, updated: note.updated) }
}

/// The Memory page's state (Memory.jsx): the overview, the open note, search, and the actions on them.
@MainActor
final class MemoryModel: ObservableObject {
    @Published var data: MemoryOverview?
    @Published var tab: MemoryTab = .graph
    @Published var note: OpenNote?
    @Published var draft = ""
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var hits: [SearchHit]?
    @Published var busy = false
    @Published var projectName = ""
    @Published var message = ""
    @Published var naming: String?
    @Published var confirmDelete = false
    @Published var positions: [String: CGPoint] = [:]

    private var searchTask: Task<Void, Never>?
    private var layoutKey = ""
    private weak var app: AppModel?

    var dirty: Bool { note != nil && draft != note?.content }

    func attach(_ app: AppModel) { self.app = app }

    func load(_ app: AppModel) async {
        self.app = app
        do {
            let next = try app.backend.memoryOverview()
            data = next
            let key = next.graph.nodes.map(\.id).joined(separator: "|") + "#\(next.graph.edges.count)"
            if key != layoutKey {
                layoutKey = key
                let nodes = next.graph.nodes, edges = next.graph.edges
                let result = await Task.detached { GraphLayout.positions(nodes: nodes, edges: edges) }.value
                if key == layoutKey { positions = result }
            }
        } catch { app.error = plainMessage(error) }
    }

    func open(_ id: String) async {
        guard let app else { return }
        do {
            let opened = try app.backend.memoryNote(id)
            note = OpenNote(opened)
            draft = opened.content
            tab = .notes
            query = ""
        } catch {
            // Core and an unwritten project overview do not exist until they are written: open them empty.
            if id == "Core" || id.hasSuffix("/Overview") {
                note = OpenNote(id: id, title: id.split(separator: "/").last.map(String.init) ?? id, content: "", updated: Date().timeIntervalSince1970 * 1000)
                draft = id == "Core" ? "# Core\n\n" : ""
                tab = .notes
            } else { app.error = plainMessage(error) }
        }
    }

    func save() async {
        guard let app, let note else { return }
        busy = true; defer { busy = false }
        do {
            let saved = try app.backend.memorySave(note.id, content: draft)
            self.note = OpenNote(saved)
            draft = saved.content
            await load(app)
        } catch { app.error = plainMessage(error) }
    }

    func remove() async {
        guard let app, let note else { return }
        busy = true; defer { busy = false }
        do {
            try app.backend.memoryDelete(note.id)
            self.note = nil
            await load(app)
        } catch { app.error = plainMessage(error) }
    }

    func create() async {
        guard let app, let title = naming?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let made = try app.backend.memorySave(title, content: "# \(title)\n\n")
            naming = nil
            note = OpenNote(made)
            draft = made.content
            tab = .notes
            await load(app)
        } catch { app.error = plainMessage(error) }
    }

    func tidy() async {
        guard let app else { return }
        busy = true; message = ""; defer { busy = false }
        message = await app.backend.memoryTidy()
        await load(app)
    }

    func createProject() async {
        guard let app else { return }
        busy = true; defer { busy = false }
        do {
            let made = try app.backend.createProject(name: projectName)
            projectName = ""
            message = "Created \(made.name) in \(made.workspace)."
            await app.refresh()
            await load(app)
        } catch { app.error = plainMessage(error) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { hits = nil; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let app = self.app else { return }
            if let found = try? await app.backend.memorySearch(text), !Task.isCancelled { self.hits = found }
        }
    }
}
