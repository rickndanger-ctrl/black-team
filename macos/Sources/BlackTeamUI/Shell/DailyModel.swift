import SwiftUI
import BlackTeamKit

/// The words a model card and the model menu use, worked out from what the Backend keeps for a saved model.
extension Fmt {
    private static func tokens(_ item: SavedModelSummary) -> [String] {
        var base = (item.location as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".gguf") { base.removeLast(5) }
        return base.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
    }

    private static func isSize(_ t: String) -> Bool { t.range(of: #"^\d+(\.\d+)?[BbMm]$"#, options: .regularExpression) != nil && t.last!.uppercased() == "B" }
    private static func isActive(_ t: String) -> Bool { t.range(of: #"^A\d+(\.\d+)?B$"#, options: .regularExpression) != nil }
    private static func isQuant(_ t: String) -> Bool { t.range(of: #"^(I?Q\d.*|F16|BF16|F32)$"#, options: [.regularExpression, .caseInsensitive]) != nil }

    /// "35B · A3B · Q4_K_M" for a model file, "Local server · 127.0.0.1:18081" for a server.
    static func modelDetail(_ item: SavedModelSummary) -> String {
        if item.isCloud { return "Cloud \u{00B7} \(item.provider)" }
        if item.source == "server" { return "Local server \u{00B7} \(item.location)" }
        let found = tokens(item).filter { isSize($0) || isActive($0) || isQuant($0) }
        return found.isEmpty ? "Model file \u{00B7} \((item.location as NSString).lastPathComponent)" : found.joined(separator: " \u{00B7} ")
    }

    /// "35B" when the file name carries a size.
    static func modelSize(_ item: SavedModelSummary) -> String? { tokens(item).first(where: isSize) }
}

/// The Command center's reading of the Backend: model cards, harness cards, the status pill.
extension AppModel {
    static let paceWords: [(id: String, title: String, detail: String)] = [
        ("fast", "Fast", "Quick replies, thinking off"),
        ("balanced", "Balanced", "Everyday coding and reasoning"),
        ("deep", "Deep", "More time for difficult tasks"),
        ("extended", "Extended", "Longest reasoning budget"),
    ]

    var pace: String {
        get { DraftStore.defaultMode }
        set { UserDefaults.standard.set(newValue, forKey: DraftStore.defaultModeKey); objectWillChange.send() }
    }

    var modelCards: [ModelCardInfo] {
        let runtime = status?.runtime
        return (status?.models ?? []).map { item in
            var state = "off"
            // A cloud model has no server to start: it is reached when a message is sent.
            if item.active, item.isCloud { state = "ready" } else if item.active {
                if runtime?.ready == true { state = "ready" }
                else if runtime?.state == "starting" { state = "starting" }
                else if runtime?.state == "error" { state = "error" }
            }
            return ModelCardInfo(id: item.key, name: item.name, detail: Fmt.modelDetail(item), active: item.active, state: state, cloud: item.isCloud, provider: item.provider)
        }
    }

    var activeCard: ModelCardInfo? { modelCards.first(where: \.active) }

    /// "Ornith 1.5 online" in the header pill, or "Models offline".
    var pillText: String {
        if let card = activeCard, card.cloud { return "Cloud \u{00B7} \(card.provider)" }
        if let card = activeCard, card.state == "ready" { return "\(card.name) online" }
        if let card = activeCard, card.state == "starting" { return "\(card.name) starting" }
        return "Models offline"
    }

    func describe(app id: String) -> String {
        switch id {
        case "claude": return "Lean local coding setup"
        case "codex": return "Coding agent and tools"
        case "pi": return "Lightweight coding agent"
        case "opencode": return "Open-source coding agent"
        case "dsh": return "DSH in your browser"
        case "aider": return "Pair programming in your terminal"
        default: return "Opens in your terminal"
        }
    }

    var harnessCards: [HarnessCardInfo] {
        var cards = [HarnessCardInfo(id: "chat", name: "Black Team Chat", detail: "A simple conversation", kind: "Built in", builtIn: true),
                     HarnessCardInfo(id: "code", name: "Black Team Code", detail: "Edits files, runs commands", kind: "Built in", builtIn: true)]
        let saved = status?.integrations?.harnesses ?? []
        let apps = installed?.apps ?? []
        for app in apps { cards.append(HarnessCardInfo(id: app.id, name: app.name, detail: describe(app: app.id), kind: "Terminal", builtIn: false)) }
        for item in saved where !apps.contains(where: { $0.id == item.id || $0.executable == item.executable }) {
            cards.append(HarnessCardInfo(id: item.id, name: item.name, detail: "Your own launcher", kind: "Terminal", builtIn: false))
        }
        return cards
    }

    var selectedHarnessCard: HarnessCardInfo {
        let cards = harnessCards
        return cards.first(where: { $0.id == selectedHarness }) ?? cards[0]
    }

    /// "Launch <name> →": built-in ones open Camp; an app is connected if needed, then opened in a terminal.
    func launchSelected() async {
        let card = selectedHarnessCard
        if card.builtIn {
            startChat(card.id == "code" ? .agent : .chat)
            openCamp()
            record("\(card.name) opened with \(modelName)")
            return
        }
        launching = true
        defer { launching = false }
        func entry() -> HarnessEntry? { status?.integrations?.harnesses.first { $0.id == card.id } }
        if entry() == nil, let app = installed?.apps.first(where: { $0.id == card.id }) { await connect(app: app) }
        if let item = entry() { await open(harness: item) }
    }

    /// The folder agents start in: the last two parts of the path, as the daily page shows it.
    var workspaceLabel: String {
        let path = status?.config.workspace ?? ""
        let parts = path.split(separator: "/").suffix(2)
        return parts.isEmpty ? "Choose folder" : parts.joined(separator: "/")
    }
}
