import SwiftUI
import BlackTeamKit

/// One model the finder turned up, server or file, with what the lists need to show.
struct FoundItem: Identifiable, Equatable {
    var key: String
    var name: String
    var detail: String
    var saved: Bool
    var ignored: Bool
    var usable: Bool
    var plain: JSONValue
    var id: String { key }

    init(_ marked: MarkedServer) {
        let item = marked.server
        key = marked.key; name = item.name; saved = marked.saved; ignored = marked.ignored
        usable = !marked.saved
        let context = item.contextKnown ? "\(Fmt.number(item.context)) tokens" : "context not reported, using \(Fmt.number(item.context))"
        detail = "Running now \u{00B7} \(item.provider) \u{00B7} \(Fmt.place(item.endpoint)) \u{00B7} \(context)"
        plain = ["source": "server", "endpoint": .string(item.endpoint), "id": .string(item.id), "name": .string(item.name), "context": .number(Double(item.context))]
    }

    init(_ marked: MarkedFile) {
        let item = marked.file
        key = marked.key; name = item.name; saved = marked.saved; ignored = marked.ignored
        usable = !marked.saved && !item.runtime.isEmpty
        var text = "Model file \u{00B7} \(Fmt.gb(item.bytes)) \u{00B7} " + (item.runtime.isEmpty ? "needs llama.cpp, which was not found" : "Black Team starts it when you use it")
        if item.tooBig { text += " \u{00B7} larger than this computer\u{2019}s memory" } else if item.tight { text += " \u{00B7} may not fit beside what is loaded now" }
        detail = text
        plain = ["source": "gguf", "file": .string(item.file), "runtime": .string(item.runtime), "name": .string(item.name), "context": .number(Double(item.context))]
    }
}

/// "Find my models": running local servers and model files on this Mac (FindModels.jsx).
@MainActor
final class ModelFinder: ObservableObject {
    @Published var report: FoundModelsReport?
    @Published var looking = false
    @Published var failure: String?
    @Published var picked = Set<String>()

    var items: [FoundItem] {
        guard let report else { return [] }
        return report.servers.map(FoundItem.init) + report.files.map(FoundItem.init)
    }

    /// Found, not yet in the list, and not passed over: the home page's offer.
    var offers: [FoundItem] { items.filter { $0.usable && !$0.ignored } }

    func look(_ backend: Backend, preselect: Bool = true) async {
        looking = true
        failure = nil
        let result = await backend.findMyModels()
        report = result
        looking = false
        if preselect { picked = Set(items.filter(\.usable).map(\.key)) }
    }

    func toggle(_ item: FoundItem) {
        if picked.contains(item.key) { picked.remove(item.key) } else { picked.insert(item.key) }
    }
}
