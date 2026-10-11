import SwiftUI
import BlackTeamKit

/// "Check for runtime update": whether the llama.cpp Black Team downloaded has a newer build, and installing it.
/// Nothing is checked or downloaded until the person asks.
@MainActor
final class RuntimeUpdates: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(String)
        case installing(String, Double?)
        case installed(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    private var release: RuntimeRelease?
    private var installer: RuntimeInstaller?

    private func installer(for app: AppModel) -> RuntimeInstaller {
        if let installer { return installer }
        let made = RuntimeInstaller(dataFolder: URL(fileURLWithPath: app.backend.dataFolder))
        installer = made
        return made
    }

    func check(_ app: AppModel) {
        guard phase != .checking else { return }
        phase = .checking
        let installer = installer(for: app)
        Task {
            do {
                if let found = try await installer.updateAvailable() {
                    release = found
                    phase = .available(found.tag)
                } else { phase = .upToDate }
            } catch { phase = .failed(plainMessage(error)) }
        }
    }

    func install(_ app: AppModel) {
        guard let release else { return }
        let installer = installer(for: app)
        phase = .installing(release.tag, nil)
        Task {
            do {
                let done = try await installer.install(release, force: false, progress: { event in
                    if case .downloading(let p) = event { DispatchQueue.main.async { self.phase = .installing(release.tag, p.fraction) } }
                })
                phase = .installed(done.tag)
                await app.refresh()
            } catch { phase = .failed(plainMessage(error)) }
        }
    }
}
