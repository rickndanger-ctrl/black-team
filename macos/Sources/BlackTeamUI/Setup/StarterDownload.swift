import SwiftUI
import BlackTeamKit

/// The "Get a starter model" download: what is offered, which one is chosen, and how far it has got.
@MainActor
final class StarterDownload: ObservableObject {
    enum Phase: Equatable { case idle, running, paused, failed(String), done }

    @Published var catalogue: StarterCatalogue?
    @Published var selectedID: String?
    @Published var phase: Phase = .idle
    @Published var progress: SetupProgress?
    private var cancelRequested = false

    var selected: StarterEntry? {
        guard let catalogue else { return nil }
        return catalogue.models.first { $0.id == (selectedID ?? catalogue.recommendedID) }
    }

    func load(_ backend: Backend) {
        let next = backend.starterModels()
        catalogue = next
        if selectedID == nil || !next.models.contains(where: { $0.id == selectedID }) { selectedID = next.recommendedID }
    }

    /// The model's own download: how long it still needs, when the speed is known.
    var secondsRemaining: Double? {
        guard let progress, let entry = selected, let fraction = progress.fraction, progress.bytesPerSecond > 1,
              progress.stage.hasPrefix("Downloading"), !progress.stage.contains("runtime") else { return nil }
        return Double(entry.model.bytes) * (1 - fraction) / progress.bytesPerSecond
    }

    func start(_ app: AppModel) {
        guard let entry = selected, phase != .running else { return }
        let backend = app.backend
        if let free = app.status?.hardware.disk?.available, !entry.installed, Int64(free) < entry.model.bytes {
            phase = .failed("Not enough free disk space: this model needs \(Fmt.size(entry.model.bytes)) and only \(Fmt.size(Int64(free))) is free. Free up some space and try again.")
            return
        }
        phase = .running
        cancelRequested = false
        progress = SetupProgress(stage: "Getting ready\u{2026}")
        app.error = nil
        Task { [weak self] in
            do {
                let result = try await backend.setUpStarter(modelID: entry.id, progress: { value in
                    DispatchQueue.main.async { self?.progress = value }
                })
                await MainActor.run {
                    self?.phase = .done
                    app.finishedStarter(result)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.cancelRequested || error is CancellationError { self.phase = .paused }
                    else { self.phase = .failed(plainMessage(error)) }
                    self.load(backend)
                }
            }
        }
    }

    func cancel(_ backend: Backend) {
        cancelRequested = true
        backend.cancelSetUp()
    }
}

extension AppModel {
    /// The model is saved: on to step 2, the agents found on this Mac.
    func finishedStarter(_ result: StarterSetupResult) {
        if let warning = result.warning { notice = warning }
        Task {
            await refresh()
            welcome = .agents
            starter.phase = .idle
            starter.load(backend)
        }
    }
}
