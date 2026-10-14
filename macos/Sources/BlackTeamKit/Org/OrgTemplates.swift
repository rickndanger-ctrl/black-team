import Foundation

// The built-in roles and the three starting organizations. Everything is editable once made; these are only the first draft.

enum OrgKind {
    static let lead = "lead", product = "product", designer = "designer", architect = "architect", engineer = "engineer"
    static let reviewer = "reviewer", qa = "qa", docs = "docs", release = "release", custom = "custom"
}

enum OrgTemplates {
    static let list: [OrgTemplate] = [
        OrgTemplate(id: "software", name: "Software company",
                    summary: "Lead, product manager, designer, architect, engineer, reviewer, QA, docs writer and release manager.",
                    kinds: [OrgKind.lead, OrgKind.product, OrgKind.designer, OrgKind.architect, OrgKind.engineer, OrgKind.reviewer, OrgKind.qa, OrgKind.docs, OrgKind.release]),
        OrgTemplate(id: "studio", name: "Design studio", summary: "Lead, designer and reviewer. For mockups, design tokens and UI specs.",
                    kinds: [OrgKind.lead, OrgKind.designer, OrgKind.reviewer]),
        OrgTemplate(id: "small", name: "Small team", summary: "Lead, one engineer and a reviewer. The cheapest way to try it.",
                    kinds: [OrgKind.lead, OrgKind.engineer, OrgKind.reviewer]),
    ]

    static func template(_ id: String) -> OrgTemplate? { list.first { $0.id == id } }

    /// The default name, charter and guidance notes of a built-in role.
    static func defaults(_ kind: String) -> (name: String, charter: String, skills: [String], access: OrgAccess, work: String) {
        switch kind {
        case OrgKind.lead:
            return ("Lead", "You run this company for its owner. You read each new ticket, decide how big it is and whether it touches the user interface, split a large request into small tickets, and decide what to do when the team disagrees. You keep tickets small: a local model on a CPU is slow, so one ticket should be a few hours of work at most. You do not write the code yourself.",
                    ["Prefer several small tickets to one large one.", "Say plainly what is unclear instead of guessing."], .read, "code")
        case OrgKind.product:
            return ("Product manager", "You turn a request into a spec the team can build and check. State the goal in two sentences, what is in and out of scope, and a numbered list of acceptance criteria, each one something a person could check by running the program. If the request is too unclear to write criteria, ask the owner ONE question instead.",
                    ["Every acceptance criterion is checkable and says what to do and what to see.", "Keep the spec under one page."], .read, "chat")
        case OrgKind.designer:
            return ("Designer", "You design the user interface for a ticket. Write a short design spec (who uses it, the screens or states, the behaviour, empty and error states) and produce a real HTML and CSS mockup plus design tokens (colours, spacing, type) in the project's own style. Reuse the tokens and components the project already has before inventing new ones.",
                    ["Plain wording for a non-technical person.", "Keyboard and screen-reader friendly: labels, focus order, contrast.", "Both light and dark themes when the project has them."], .read, "chat")
        case OrgKind.architect:
            return ("Architect", "You decide the structure of the change and break the spec into engineering tasks. Read the code first. Name the files each task touches, keep each task small enough for one sitting, and put them in a sensible order. Follow the project's existing layout and conventions; do not add a new framework without a strong reason.",
                    ["At most six tasks.", "Each task names the files it changes and how to know it is done."], .read, "code")
        case OrgKind.engineer:
            return ("Engineer", "You build one task at a time in the ticket's own branch. Read the surrounding code and follow its conventions. Make the smallest change that meets the task, add or update tests for what you change, run them when you can, and reply with what you changed and what you checked.",
                    ["Match the surrounding code's style and naming.", "Do not change files outside the task.", "Never leave a task half done: say plainly what is not finished."], .edit, "code")
        case OrgKind.reviewer:
            return ("Reviewer", "You review the change against the spec and the codebase's conventions. Look for bugs, missing cases, missing tests, files changed that should not have been, and style that does not match. Be specific: name the file and the problem. Accept only when the change meets the spec; otherwise ask for changes and say exactly which.",
                    ["Judge the change against the acceptance criteria, not your taste.", "Separate must-fix problems from suggestions."], .read, "code")
        case OrgKind.qa:
            return ("QA", "You check that the ticket really works. Run the project's tests, then check each acceptance criterion one by one and say whether it is met and how you know. Write the tests that are missing. Report plainly: do not call something working that you did not run.",
                    ["Run the real test command for the project.", "One line per acceptance criterion: met or not met, and the evidence."], .edit, "code")
        case OrgKind.docs:
            return ("Docs writer", "You write the documentation for the change: what it is, how to use it, what to expect. Plain words for a non-technical reader, short sentences, examples. Say what it does not do.",
                    ["No marketing words.", "Show the exact command or the exact button."], .read, "chat")
        case OrgKind.release:
            return ("Release manager", "You prepare the change for the owner: a summary of what changed and why, the acceptance criteria and how each was checked, what review and QA found, what to watch for, and the branch to merge. You never merge anything; merging is the owner's decision.",
                    ["Lead with what changed for a person using the product.", "List anything unfinished or risky first."], .read, "chat")
        default:
            return ("Specialist", "Describe what this role is responsible for and the standards it holds.", [], .read, "chat")
        }
    }

    static func role(_ kind: String) -> OrgRole {
        let d = defaults(kind)
        return OrgRole(id: UUID().uuidString.lowercased(), kind: kind, name: d.name, charter: d.charter, skills: d.skills, modelKey: nil, agent: nil, work: nil,
                       access: d.access, price: nil, budget: nil, rosterId: nil)
    }
}
