import Foundation

// THE ONE PLACE long-running helper programs are registered with the background service.
//
// To add a helper (for example a Hermes gateway for messaging platforms): return a `HelperSpec` from `specs(for:)` below, only when the
// person has turned that feature on. The service starts every spec when it starts, checks it, restarts it with a growing wait when it stops,
// and stops it when the service stops (Service/HelperSupervisor.swift). Its output goes to `<data>/run/<id>.log`.
//
//   if context.integrations.hermes.enabled && gatewayWanted {
//       list.append(HelperSpec(id: "hermes-gateway", name: "Hermes gateway", executable: python, arguments: [gatewayScript],
//                              health: { await gatewayAnswers() }))
//   }
//
// A helper is never started when the service is not running, and never through a shell. Nothing is registered today.

public struct ServiceContext: Sendable {
    public var dataFolder: String
    public var scripts: String?
    public var integrations: Integrations
    public init(dataFolder: String, scripts: String?, integrations: Integrations) {
        self.dataFolder = dataFolder; self.scripts = scripts; self.integrations = integrations
    }
}

public enum ServiceHelpers {
    /// Helpers other parts of Black Team register. Read once when the service starts.
    public static func specs(for context: ServiceContext) -> [HelperSpec] {
        return []
    }
}
