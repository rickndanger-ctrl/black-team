import Foundation

// The Linux desktop window's way in, as lib/server.cjs had it: the window opens `/bootstrap?key=<bootstrap key>` once, is
// redirected to `/` with a session cookie, and every later request from the same address carries that cookie. Both keys are
// random for each run of the service. A phone never has this cookie; it has its own, from pairing (Phone/PhoneRouter.swift).

public final class DesktopSession: @unchecked Sendable {
    public static let cookieName = "black_team_session"
    public let bootstrapKey: String
    public let sessionKey: String
    /// For the background service's control route only (Service/ServiceRoutes.swift): written to the private connection file, so the window's
    /// main process can use it and the page, which has the session cookie, cannot.
    public let controlKey: String

    public init() {
        bootstrapKey = PhoneKeys.randomKey()
        sessionKey = PhoneKeys.randomKey()
        controlKey = PhoneKeys.randomKey()
    }

    /// The address the desktop window loads first.
    public func bootstrapURL(port: Int) -> String { "http://127.0.0.1:\(port)/bootstrap?key=\(bootstrapKey)" }
}

/// What makes a Backend the Linux desktop service rather than the Mac app or the terminal program.
public struct DesktopOptions: Sendable {
    /// The app's scripts folder (holds agent-runner.py), given by `--scripts`. Nil: Hermes is not available here.
    public var scripts: String?
    public init(scripts: String? = nil) { self.scripts = scripts }
}
