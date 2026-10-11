import SwiftUI
import BlackTeamKit

/// "Get a starter model": one click on a brand-new Mac. The model recommended for this Mac is chosen already.
struct StarterPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var starter: StarterDownload
    @Environment(\.btTheme) private var theme

    private var running: Bool { starter.phase == .running }

    var body: some View {
        BTPanel {
            VStack(alignment: .leading, spacing: 18) {
                BTSectionHeader(eyebrow: "Get a starter model", title: "Download a model to this Mac",
                                intro: "No account and no other app needed. Pick a size, press Download, and Black Team sets everything up.")
                if let catalogue = starter.catalogue {
                    Text("This Mac has \(Fmt.gb(catalogue.memoryBytes)) of memory. The recommended model fits it comfortably.")
                        .font(BTFont.body(12)).foregroundStyle(theme.muted)
                    VStack(spacing: 6) {
                        ForEach(catalogue.models) { entry in choice(entry) }
                    }
                    .disabled(running)
                    if let entry = starter.selected { detail(entry, runtime: catalogue.runtime) }
                    progressArea
                }
            }
        }
        .padding(.bottom, 20)
        .accessibilityElement(children: .contain)
    }

    private func choice(_ entry: StarterEntry) -> some View {
        let selected = entry.id == starter.selected?.id
        return Button { starter.selectedID = entry.id } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(selected ? theme.accent : theme.line2, lineWidth: 1).frame(width: 16, height: 16)
                    if selected { Circle().fill(theme.accent).frame(width: 8, height: 8) }
                }
                Text(entry.model.name).font(BTFont.body(13, .medium)).foregroundStyle(theme.ink)
                if entry.recommended { BTStatusPill(text: "Recommended for this Mac", kind: .ok) }
                if entry.installed { BTStatusPill(text: "Downloaded", kind: .neutral) }
                Spacer()
                if !entry.fits { Text("Needs more memory than is comfortable").font(BTFont.body(11)).foregroundStyle(theme.warn) }
                Text(Fmt.size(entry.model.bytes)).font(BTFont.mono(11.5)).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? theme.surface2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? theme.line2 : theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detail(_ entry: StarterEntry, runtime: InstalledRuntime?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.model.name).font(BTFont.body(15, .semibold)).foregroundStyle(theme.ink)
            Text("\(Fmt.size(entry.model.bytes)) \u{00B7} \(entry.model.license) licence \u{00B7} \(Fmt.number(entry.model.contextSize)) tokens of context")
                .font(BTFont.mono(11)).foregroundStyle(theme.muted)
            Text(entry.model.summary).font(BTFont.body(12.5)).lineSpacing(4).foregroundStyle(theme.ink2)
            Text("The download comes from Hugging Face" + (runtime == nil ? " and GitHub (the llama.cpp program that runs the model)" : "")
                 + ". Once it has finished, everything runs on this Mac and nothing you write leaves it.")
                .font(BTFont.body(12)).lineSpacing(4).foregroundStyle(theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme.line, lineWidth: 1))
    }

    @ViewBuilder private var progressArea: some View {
        switch starter.phase {
        case .idle:
            downloadButton(label: starter.selected?.installed == true ? "Use this model" : "Download \(starter.selected.map { Fmt.size($0.model.bytes) } ?? "")")
        case .running:
            runningArea
        case .paused:
            BTBanner(kind: .notice, message: "Download paused. What was already downloaded is kept, so Resume continues where it stopped.")
            downloadButton(label: "Resume download")
        case .failed(let text):
            BTBanner(kind: .error, message: text)
            downloadButton(label: "Try again")
            Text("Try again continues where the download stopped.").font(BTFont.body(11.5)).foregroundStyle(theme.muted)
        case .done:
            HStack(spacing: 8) { BTSpinner(); Text("Finishing up\u{2026}").font(BTFont.body(12.5)).foregroundStyle(theme.muted) }
        }
    }

    private func downloadButton(label: String) -> some View {
        HStack {
            Button { starter.start(model) } label: { Text(label) }
                .buttonStyle(.btPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(starter.selected == nil || model.busy)
            Spacer()
        }
    }

    private var runningArea: some View {
        let progress = starter.progress
        return VStack(alignment: .leading, spacing: 10) {
            Text(progress?.stage ?? "Getting ready\u{2026}").font(BTFont.body(13, .semibold)).foregroundStyle(theme.ink)
            BTProgressBar(value: progress?.fraction)
            HStack(spacing: 8) {
                Text(stats).font(BTFont.mono(11.5)).foregroundStyle(theme.muted)
                Spacer()
                Button("Cancel") { starter.cancel(model.backend) }.buttonStyle(.btSecondary)
            }
        }
    }

    private var stats: String {
        guard let progress = starter.progress, let fraction = progress.fraction else { return "Working\u{2026}" }
        var parts = ["\(Int((fraction * 100).rounded()))%"]
        if progress.bytesPerSecond > 1 { parts.append(Fmt.speed(bytesPerSecond: progress.bytesPerSecond)) }
        if let seconds = starter.secondsRemaining { parts.append(Fmt.remaining(seconds: seconds)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
