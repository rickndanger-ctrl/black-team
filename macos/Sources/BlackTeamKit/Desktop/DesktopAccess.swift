import Foundation

// Who is asking, for everything the Linux desktop service adds beyond the phone's surface (cloud models, subscription agents, the room,
// pictures). The rule is enforced here, on the server, never by what the window chooses to show:
//   - the control channel (standard input of `desktop-service`) is only ever the Electron main process: `.desktop`;
//   - an HTTP request is `.desktop` only with the window's session cookie; a paired phone is `.phone`.
// The privacy decisions themselves stay in App/BackendCloud.swift; this file only says who may ask for them.

/// The words a phone is given for something only the desktop app may do.
public enum DesktopRefusal {
    /// Anything that is set up or decided in the app on the computer.
    public static let desktopOnly = "This can only be done in the Black Team app on your computer."
    /// Choosing what a subscription agent may do without asking.
    public static let agentPermission = "What an agent may do without asking is chosen in the Black Team app on your computer."
    /// Attaching or viewing pictures (the phone\u{2019}s web app has no image support).
    public static let pictures = "Pictures can only be attached in the Black Team app on your computer."
}

extension DesktopAccess {
    /// Throws the refusal unless this is the desktop window.
    func requireDesktop(_ message: String = DesktopRefusal.desktopOnly) throws {
        if self != .desktop { throw BlackTeamError(message) }
    }
}

/// Who is asking. The control channel is always `.desktop`.
public enum DesktopAccess: Equatable, Sendable { case desktop, phone }
