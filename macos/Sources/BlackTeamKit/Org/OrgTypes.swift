import Foundation

// An organization: the Room (Room/, App/BackendRoom.swift) grown into a small company on ONE project. It has roles (each a roster-style agent with a
// charter), tickets that move through stages, and an owner (the person) who approves what matters. Nothing here is a second system: a stage is a
// room task run by the role's room member, the usual privacy gate decides every run, and the background service's Inbox carries the gates.
// The values live here; the storage is Org/OrgStore.swift and the running of it is Org/OrgRunner.swift.

public enum OrgLimits {
    public static let roles = 16
    public static let tickets = 200
    public static let name = 60
    public static let title = 120
    public static let body = 4000
    public static let charter = 2000
    public static let skills = 8
    public static let skill = 300
    public static let note = 1000
    public static let history = 80
    /// The most one artifact keeps (a diff is clipped, with a line saying so).
    public static let artifact = 60_000
    /// How many times review (and, separately, QA) may send a ticket back to Build before the owner is asked to decide.
    public static let sendBacks = 2
    public static let buildTasks = 6
    public static let split = 5
    public static let usage = 3000
    /// What one stage's message may reach (UTF-16 units); the oldest artifact text is clipped first.
    public static let message = 14_000
}

public enum OrgStage: String, Codable, CaseIterable, Sendable {
    case intake, spec, design, plan, build, review, qa, ship

    public var title: String {
        switch self {
        case .intake: return "Intake"
        case .spec: return "Spec"
        case .design: return "Design"
        case .plan: return "Plan"
        case .build: return "Build"
        case .review: return "Review"
        case .qa: return "QA"
        case .ship: return "Ship"
        }
    }
    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// How much a role may do on its own, the same words as the schedules and the Room's agents: read only, ask first, edit files in the project, auto.
public enum OrgAccess: String, Codable, CaseIterable, Sendable {
    case read, ask, edit, auto
    public var title: String {
        switch self {
        case .read: return "Read only"
        case .ask: return "Ask me first"
        case .edit: return "Edit files in the project"
        case .auto: return "Automatic"
        }
    }
    var unattended: UnattendedPermission {
        switch self { case .read: return .readOnly; case .ask: return .ask; case .edit, .auto: return .allowInProject }
    }
    var agent: AgentPermission {
        switch self { case .read, .ask: return .ask; case .edit: return .edit; case .auto: return .auto }
    }
}

/// What the person pays per million tokens of a role's model. Entered by the person; nothing here is built in.
public struct OrgPrice: Codable, Equatable, Sendable {
    public var inPerMillion: Double
    public var outPerMillion: Double
    public init(inPerMillion: Double, outPerMillion: Double) { self.inPerMillion = inPerMillion; self.outPerMillion = outPerMillion }
    func money(prompt: Int, completion: Int) -> Double { (Double(prompt) * inPerMillion + Double(completion) * outPerMillion) / 1_000_000 }
}

/// Ceilings per day on paid work. Nil is no ceiling. Local work is measured but never limited.
public struct OrgBudget: Codable, Equatable, Sendable {
    public var paidTokensPerDay: Int?
    public var moneyPerDay: Double?
    public init(paidTokensPerDay: Int? = nil, moneyPerDay: Double? = nil) { self.paidTokensPerDay = paidTokensPerDay; self.moneyPerDay = moneyPerDay }
}

public struct OrgRole: Codable, Equatable, Sendable {
    public var id: String
    /// lead, product, designer, architect, engineer, reviewer, qa, docs, release, or custom.
    public var kind: String
    public var name: String
    /// A short brief of responsibilities and standards, given to the role at the start of every stage it runs.
    public var charter: String
    /// Plain guidance notes the role follows (the engine has no skills folder yet).
    public var skills: [String]
    /// A saved model's key (local or cloud). Exactly one of `modelKey` and `agent` is set; neither means the role is not set up yet.
    public var modelKey: String?
    /// "claude-code" or "codex".
    public var agent: String?
    /// Models only: "chat" or "code".
    public var work: String?
    public var access: OrgAccess
    public var price: OrgPrice?
    public var budget: OrgBudget?
    /// Where this role came from in the roster, when it was filled from there. Informational.
    public var rosterId: String?

    public var service: AgentService? { AgentService.forEngine(agent) }
    var isSetUp: Bool { (modelKey == nil) != (agent == nil) }
}

public struct OrgTemplate: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var kinds: [String]
}

public struct Organization: Codable, Equatable, Sendable {
    public var version = 1
    public var projectId: String
    public var name: String
    public var template: String
    public var roles: [OrgRole]
    /// Stages after which the owner must approve (default: spec and ship).
    public var gates: [String]
    /// Continuous pickup is on: with the background service, or the window open, tickets are picked up when the computer is idle.
    public var running: Bool
    public var paused: Bool
    public var pausedReason: String
    /// The services the owner agreed to at the last start, and the digest of that agreement.
    public var confirmed: [String]
    public var agreement: String
    public var budget: OrgBudget
    /// When the daily stand-up report is made, in the schedules' words ("daily at 9:00"), or empty for never.
    public var standupAt: String
    /// When the last stand-up was made (ISO time), and when the next is due (seconds since 1970).
    public var standupLast: String
    public var standupNext: Double? = nil
    /// Tickets that appear on a schedule ("weekdays at 9:00: check the dependencies").
    public var routines: [OrgRoutine] = []
    public var nextNumber: Int
    public var created: String
    /// An Obsidian board this organization takes its tickets from, when linked (Org/OrgBoard.swift). Only paths and two switches; no secrets.
    public var board: OrgBoard? = nil

    public func role(_ id: String) -> OrgRole? { roles.first { $0.id == id } }
    public func roles(of kind: String) -> [OrgRole] { roles.filter { $0.kind == kind } }
    public func gated(_ stage: OrgStage) -> Bool { gates.contains(stage.rawValue) }
}

public struct OrgRoutine: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    /// In the schedules' words: "every 6 hours", "weekdays at 9:00".
    public var whenText: String
    public var next: Double?
}

// MARK: Tickets

public struct OrgArtifact: Codable, Equatable, Sendable {
    /// The file name inside the ticket's folder, such as "spec.md" or "review-2.md".
    public var name: String
    public var stage: String
    public var title: String
    public var created: String
    public var bytes: Int
    public var role: String
}

public struct OrgEvent: Codable, Equatable, Sendable {
    public var at: String
    public var stage: String?
    public var role: String?
    public var text: String
    /// An artifact this event saved on the board, as a path under the board's Artifacts folder (`T-7/spec.md`).
    public var link: String? = nil
}

/// What a ticket is waiting for the owner to do.
public struct OrgGate: Codable, Equatable, Sendable {
    /// The stage that finished (an "approval" gate), or the one that needs the answer.
    public var stage: String
    /// approval, question, privacy or escalation.
    public var kind: String
    public var question: String
    public var artifact: String?
    public var inboxId: String
    public var created: String
    /// Privacy gates: the service the ticket would newly go to.
    public var service: String? = nil
}

public struct OrgBuildTask: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var done: Bool
    public var result: String
    public var role: String?
}

public struct OrgTicket: Codable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var number: Int
    public var title: String
    public var body: String
    /// person, phone, schedule, lead or command.
    public var source: String
    public var created: String
    public var updated: String
    public var stage: OrgStage
    /// ready (waiting to be picked up), running, gate (waits for the owner), blocked (a run failed), done or cancelled.
    public var state: String
    public var gate: OrgGate?
    /// Why a ticket is blocked, or the last thing worth knowing.
    public var note: String
    public var ui: Bool?
    public var size: String?
    /// The branch the engineering work is on, the commit it started from and the branch the person was on. Nil when the project is not a git repository.
    public var branch: String?
    public var base: String?
    public var baseBranch: String?
    var work: String?
    var prefix: String?
    public var artifacts: [OrgArtifact]
    public var history: [OrgEvent]
    public var sendBacks: [String: Int]
    /// What review or QA found, handed to the next Build.
    public var findings: String
    public var tasks: [OrgBuildTask]
    public var answers: [String]
    public var parent: String?
    public var children: [String]
    /// The role that is working on it now.
    public var currentRole: String?
    /// A ticket that came from an Obsidian board: the note's id (`T-7`), its file in the board's Tickets folder, and the last event written to its Log.
    public var boardId: String? = nil
    public var boardFile: String? = nil
    var boardLogged: String? = nil

    /// The board's own id (`T-7`) for a ticket that came from a board, so the same name is used everywhere.
    public var label: String { boardId ?? "T-\(number)" }
    public var finished: Bool { state == "done" || state == "cancelled" }
}

/// A role as the screens read it: its settings, where it runs, whether it can be used now, and what it is doing.
public struct OrgRoleView: Codable, Equatable, Sendable {
    public var role: OrgRole
    /// "local", "cloud", or "none" for a role that has no model or agent yet.
    public var kind: String
    public var provider: String
    public var usable: Bool
    public var reason: String
    /// working, waiting (for the owner), idle, paused or not set up.
    public var status: String
    public var ticket: String?
    public var spentToday: OrgSpend
}

public struct OrgSpend: Codable, Equatable, Sendable {
    public var paidTokens: Int
    public var localTokens: Int
    public var money: Double
    /// Paid runs whose tokens or price were not available, so the totals leave them out.
    public var unmeasured: Int
}

public struct OrgUsageEntry: Codable, Equatable, Sendable {
    public var at: String
    public var day: String
    public var ticketId: String
    public var ticket: String
    public var stage: String
    public var roleId: String
    public var roleName: String
    public var memberName: String
    public var paid: Bool
    public var prompt: Int?
    public var completion: Int?
    public var seconds: Int
    public var money: Double?
}

public struct OrgLedgerLine: Codable, Equatable, Sendable {
    public var roleName: String
    public var paid: Bool
    public var prompt: Int
    public var completion: Int
    public var seconds: Int
    public var runs: Int
    public var money: Double
    public var unmeasured: Int
    public var tokens: Int { prompt + completion }
}

public struct OrgLedger: Codable, Equatable, Sendable {
    public var day: String
    public var lines: [OrgLedgerLine]
    public var localTokens: Int
    public var paidTokens: Int
    public var money: Double
    public var summary: String
}

public struct OrgChoice: Codable, Equatable, Sendable {
    /// "model" or "agent".
    public var kind: String
    public var key: String
    public var name: String
    public var cloud: Bool
    public var provider: String
}

public struct OrgState: Codable, Equatable, Sendable {
    public var projectId: String
    public var projectName: String
    public var cloudAllowed: Bool
    public var git: Bool
    public var organization: Organization?
    public var roles: [OrgRoleView]
    public var tickets: [OrgTicket]
    public var ledger: OrgLedger
    public var templates: [OrgTemplate]
    public var choices: [OrgChoice]
    /// The model slot or the room is busy right now.
    public var busy: Bool
    public var stages: [String]
    /// The linked board, when there is one (a short form; the notes themselves are `orgBoardStatus`).
    public var board: OrgBoardInfo? = nil
}

/// What starting the organization would send, and where. `orgStart` refuses unless `digest` still matches the roles as they are then.
public struct OrgAgreement: Codable, Equatable, Sendable {
    public var projectId: String
    public var text: String
    public var services: [String]
    public var leavesThisMac: Bool
    public var memoryUsed: Bool
    public var problems: [String]
    public var digest: String
}
