import Foundation

// The ledger and the ceilings. One line is saved for every stage run: who ran it, whether it was paid or local, the tokens the engine or the
// service reported, and how long it took. Money is tokens times the price the PERSON entered for the role; nothing is built in, and a paid run
// whose tokens or price are not known is counted as not measured, never guessed.

extension Backend {
    /// Today's date on this computer, `yyyy-MM-dd`.
    func orgDay(_ date: Date? = nil) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date ?? now())
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    func orgMoney(_ value: Double) -> String { String(format: "%.2f", value) }

    func orgSpend(_ entries: [OrgUsageEntry]) -> OrgSpend {
        var s = OrgSpend(paidTokens: 0, localTokens: 0, money: 0, unmeasured: 0)
        for e in entries {
            let tokens = (e.prompt ?? 0) + (e.completion ?? 0)
            if e.paid {
                s.paidTokens += tokens
                if e.prompt == nil || e.completion == nil { s.unmeasured += 1 }
                if let money = e.money { s.money += money }
            } else { s.localTokens += tokens }
        }
        return s
    }

    /// Who did what on a day, paid and local apart, with the one plain sentence the Room's ledger also uses.
    func orgLedger(usage: [OrgUsageEntry], day: String) -> OrgLedger {
        let today = usage.filter { $0.day == day }
        var order: [String] = []
        for e in today where !order.contains(e.roleId) { order.append(e.roleId) }
        var lines: [OrgLedgerLine] = []
        for id in order {
            let mine = today.filter { $0.roleId == id }
            guard let first = mine.first else { continue }
            lines.append(OrgLedgerLine(roleName: first.roleName, paid: first.paid, prompt: mine.reduce(0) { $0 + ($1.prompt ?? 0) },
                                       completion: mine.reduce(0) { $0 + ($1.completion ?? 0) }, seconds: mine.reduce(0) { $0 + $1.seconds }, runs: mine.count,
                                       money: mine.reduce(0) { $0 + ($1.money ?? 0) }, unmeasured: mine.filter { $0.paid && ($0.prompt == nil || $0.completion == nil) }.count))
        }
        let local = lines.filter { !$0.paid }.reduce(0) { $0 + $1.tokens }, paid = lines.filter(\.paid).reduce(0) { $0 + $1.tokens }
        let money = lines.reduce(0) { $0 + $1.money }
        var text = "Local agents did \(EText.grouped(local)) tokens of work today; paid agents used \(EText.grouped(paid))."
        if money > 0 { text += " Paid work cost about \(orgMoney(money)) at your prices." }
        let missing = lines.filter { $0.unmeasured > 0 }.map(\.roleName)
        if !missing.isEmpty { text += " Not measured: \(missing.joined(separator: ", ")) (no usage was reported)." }
        return OrgLedger(day: day, lines: lines, localTokens: local, paidTokens: paid, money: money, summary: text)
    }

    /// Words for the first ceiling that is reached today, or nil. Reached means at or over.
    func orgCeiling(_ org: Organization, usage: [OrgUsageEntry], day: String) -> String? {
        let today = usage.filter { $0.day == day }
        func check(_ budget: OrgBudget?, _ entries: [OrgUsageEntry], _ whose: String) -> String? {
            guard let budget else { return nil }
            let spend = orgSpend(entries)
            if let limit = budget.paidTokensPerDay, spend.paidTokens >= limit {
                return "\(whose) reached its ceiling for today: \(EText.grouped(spend.paidTokens)) of \(EText.grouped(limit)) tokens on paid services."
            }
            if let limit = budget.moneyPerDay, spend.money >= limit {
                return "\(whose) reached its money ceiling for today: \(orgMoney(spend.money)) of \(orgMoney(limit))."
            }
            return nil
        }
        if let why = check(org.budget, today, org.name) { return why }
        for role in org.roles { if let why = check(role.budget, today.filter { $0.roleId == role.id }, role.name) { return why } }
        return nil
    }

    /// Saves one run's usage. `thread` is the member's conversation, which holds the tokens the engine or service reported.
    func orgRecordUsage(_ org: Organization, ticket: OrgTicket, stage: OrgStage, role: OrgRole, member: String, paid: Bool, threadId: String?, seconds: Int) {
        var prompt: Int?, completion: Int?
        if let threadId, let thread = history.get(threadId), let raw = thread[paid ? "usage" : "localUsage"], raw.object != nil {
            let u = CloudUsage(json: raw)
            prompt = u.prompt; completion = u.completion
        }
        var money: Double?
        if paid, let p = prompt, let c = completion, let price = role.price { money = price.money(prompt: p, completion: c) }
        let entry = OrgUsageEntry(at: roomNow(), day: orgDay(), ticketId: ticket.id, ticket: ticket.label, stage: stage.rawValue, roleId: role.id, roleName: role.name,
                                  memberName: member, paid: paid, prompt: prompt, completion: completion, seconds: seconds, money: money)
        orgLock.lock(); defer { orgLock.unlock() }
        var all = OrgStore.usage(dataFolder, org.projectId)
        all.append(entry)
        try? OrgStore.saveUsage(all, dataFolder, org.projectId)
    }

    /// Pauses the organization at a ceiling and leaves a note in the Inbox. Returns true when it paused.
    @discardableResult
    func orgEnforceCeiling(_ projectId: String) -> Bool {
        guard let org = orgLoad(projectId), !org.paused,
              let why = orgCeiling(org, usage: OrgStore.usage(dataFolder, projectId), day: orgDay()) else { return false }
        _ = try? orgMutate(projectId) { $0.paused = true; $0.pausedReason = why }
        orgInboxNote(org, title: "\(org.name) is paused", text: why + " Nothing more runs until you raise the ceiling or wait for tomorrow, then resume it.")
        return true
    }
}
