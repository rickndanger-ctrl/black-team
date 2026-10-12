import SwiftUI
import AppKit
import BlackTeamKit

/// The "Take Camp with you." card's state (PhoneSettings.jsx, Companion.jsx `PhonePairing`): what Tailscale and the
/// phone server are doing, the pairing link while access is ready, and the actions on them.
@MainActor
final class PhoneModel: ObservableObject {
    enum Phase: Equatable {
        case checking, notInstalled, signedOut, off, problem, ready
    }

    @Published var state: PhoneState?
    @Published var detection: PhoneDetection?
    /// The link with its pairing secret. Held only while access is ready, and never written anywhere.
    @Published var link: String?
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var copied = false
    @Published var confirmReset = false
    @Published var confirmOff = false
    /// False in the snapshot tests, which set the state by hand and must not ask Tailscale.
    var autoRefresh = true

    var phase: Phase {
        guard let state else { return .checking }
        if state.connected { return link == nil ? .checking : .ready }
        if state.enabled { return .problem }
        if let detection {
            if !detection.installed { return .notInstalled }
            if !detection.online { return .signedOut }
        }
        return .off
    }

    /// Why an enabled setup is not connected, in words for the person.
    var problemText: String {
        state?.problem ?? "Phone access is on, but it is not connected yet. Choose Try again, or turn it off."
    }

    func refresh(_ app: AppModel) async {
        if busy { return }
        do {
            let next = try await app.backend.phoneState(fresh: true)
            state = next
            if next.connected {
                link = try? await app.backend.phonePairingLink()
                detection = nil
            } else {
                link = nil
                detection = next.enabled ? nil : await app.backend.phoneDetect()
            }
        } catch { self.error = plainMessage(error) }
    }

    /// Runs one action; its error appears in the card, never as an alert.
    private func run(_ app: AppModel, _ work: () async throws -> Void) async {
        if busy { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do { try await work() } catch { self.error = plainMessage(error) }
        busy = false
        await refresh(app)
    }

    func enable(_ app: AppModel) async {
        await run(app) { _ = try await app.backend.phoneEnable() }
        if phase == .ready { notice = "Private phone access is ready. Scan the QR code on your phone." }
    }

    func disable(_ app: AppModel) async {
        await run(app) {
            let result = try await app.backend.phoneDisable()
            self.notice = result.warning ?? "Phone access turned off."
        }
    }

    func reset(_ app: AppModel) async {
        await run(app) {
            try app.backend.phoneResetPairing()
            self.notice = "Phone pairing reset. Every phone is unpaired; scan the new code to pair again."
        }
    }

    func copy() {
        guard let link else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(link, forType: .string)
        copied = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copied = false
        }
    }
}
