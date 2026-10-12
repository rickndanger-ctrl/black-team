import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BlackTeamKit

// Image attachments in Chat: the previews (`.image-attachments` in app.css), the notice for a model that needs its vision
// file, and where a picture can come from (the chooser, a drop, the clipboard).

/// A picture the person attached that has been prepared (resized, JPEG) and is waiting in memory for the message to be sent.
struct DraftImage: Identifiable, Equatable {
    let id = UUID()
    var upload: ImageUpload
    var preview: NSImage?
    var name: String { upload.name }

    init(_ upload: ImageUpload) {
        self.upload = upload
        preview = NSImage(data: upload.data)
    }

    static func == (a: DraftImage, b: DraftImage) -> Bool { a.id == b.id }
}

/// Where a picture comes from, before it is prepared.
enum ImageSource: Sendable {
    case url(URL)
    case data(Data, name: String)

    func prepare() throws -> ImageUpload {
        switch self {
        case .url(let url): return try ImagePreparer.prepare(url: url)
        case .data(let data, let name): return try ImagePreparer.prepare(data: data, name: name)
        }
    }
}

/// What a figure shows: a name, a picture (nil when the file is gone), and whether it can be removed.
struct PreviewItem: Identifiable {
    var id: String
    var name: String
    var image: NSImage?
}

/// `.image-attachments`: 112 point figures, the picture in an 84 point area, its name under it, and a round remove button.
struct ImagePreviews: View {
    let items: [PreviewItem]
    var onRemove: ((String) -> Void)?
    var disabled = false
    @Environment(\.btTheme) private var theme

    var body: some View {
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in figure(item) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
    }

    private func figure(_ item: PreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let image = item.image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(theme.line)
                }
            }
            .frame(width: 100, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            Text(item.name).font(BTFont.body(11)).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.tail)
                .frame(width: 100, height: 17, alignment: .leading).padding(.top, 5)
        }
        .padding(6)
        .frame(width: 112, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button { onRemove(item.id) } label: {
                    Text("\u{00D7}").font(BTFont.body(13, .medium)).foregroundStyle(theme.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.surface))
                        .overlay(Circle().inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
                .accessibilityLabel("Remove \(item.name)")
                .padding(2)
            }
        }
        .accessibilityElement(children: onRemove == nil ? .ignore : .contain)
        .accessibilityLabel(onRemove == nil ? item.name : "")
    }
}

/// Where the previews would be, when the model in use cannot read images yet: one button fetches its vision file.
struct VisionNotice: View {
    @ObservedObject var model: AppModel
    let bytes: Int64
    @Environment(\.btTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.visionInstall.running {
                Text(model.visionInstall.progress?.stage ?? "Getting ready\u{2026}").font(BTFont.body(12.5, .semibold)).foregroundStyle(theme.ink)
                BTProgressBar(value: model.visionInstall.progress?.fraction)
                HStack(spacing: 8) {
                    Text(stats).font(BTFont.mono(11.5)).foregroundStyle(theme.muted)
                    Spacer()
                    Button("Cancel") { model.cancelVisionInstall() }.buttonStyle(.btSecondary)
                }
            } else {
                HStack(spacing: 14) {
                    Text("This model needs its vision file before it can read images.").btBody(12, 1.6, theme.ink)
                    Spacer(minLength: 0)
                    Button { model.installVision() } label: { Text("Download vision file, \(Fmt.size(bytes))") }.buttonStyle(.btSecondary)
                }
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).inset(by: 0.5).stroke(theme.line2, lineWidth: 1))
        .padding(.vertical, 10)
    }

    private var stats: String {
        guard let progress = model.visionInstall.progress, let fraction = progress.fraction else { return "Working\u{2026}" }
        var parts = ["\(Int((fraction * 100).rounded()))%"]
        if progress.bytesPerSecond > 1 { parts.append(Fmt.speed(bytesPerSecond: progress.bytesPerSecond)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Reads pictures off a pasteboard: image files copied in Finder, or image data (a screenshot, a copied picture).
enum ImagePasteboard {
    static func sources(_ board: NSPasteboard = .general) -> [ImageSource] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            if !images.isEmpty { return images.map { .url($0) } }
        }
        // Text copied from a page comes with a picture sometimes; the words win.
        if board.string(forType: .string) != nil { return [] }
        if let png = board.data(forType: .png) { return [.data(png, name: "Pasted image.png")] }
        if let tiff = board.data(forType: .tiff) { return [.data(tiff, name: "Pasted image.tiff")] }
        return []
    }

    static func hasImage(_ board: NSPasteboard = .general) -> Bool { !sources(board).isEmpty }
}

extension AppModel {
    /// The model in use needs its vision file and the person is attaching pictures (or is fetching it).
    var visionNoticeShown: Bool {
        currentKind == .chat && status?.vision.needsFile == true && (!draftImages.isEmpty || visionInstall.running)
    }
    var imageAreaShown: Bool { currentKind == .chat && (!draftImages.isEmpty || visionNoticeShown) }

    var draftImages: [DraftImage] { pending?.images ?? drafts.draft(draftKey).images }

    var previewItems: [PreviewItem] { draftImages.map { PreviewItem(id: $0.id.uuidString, name: $0.name, image: $0.preview) } }

    /// The "+ Files" chooser.
    func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Choose images"
        panel.message = "Choose up to 4 images to send with your message"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { addImages(panel.urls.map { .url($0) }) }
    }

    /// Prepares pictures off the main thread and adds them to this conversation's draft; errors appear in the banner.
    func addImages(_ sources: [ImageSource]) {
        guard !sources.isEmpty, !preparing else { return }
        guard currentKind == .chat else { error = ImageRules.codeRefusal; return }
        let key = draftKey
        if drafts.draft(key).images.count + sources.count > ImageRules.maxImages { error = ImageRules.tooManyPerMessage; return }
        preparing = true
        error = nil
        Task { [weak self] in
            do {
                let prepared = try await Task.detached { try sources.map { try $0.prepare() } }.value
                guard let self else { return }
                var images = self.drafts.draft(key).images
                if images.count + prepared.count > ImageRules.maxImages { throw BlackTeamError(ImageRules.tooManyPerMessage) }
                images += prepared.map { DraftImage($0) }
                self.drafts.set(key, images: images)
            } catch { self?.error = plainMessage(error) }
            self?.preparing = false
        }
    }

    func removeImage(_ id: String) {
        guard pending == nil else { return }
        let key = draftKey
        drafts.set(key, images: drafts.draft(key).images.filter { $0.id.uuidString != id })
    }

    /// A stored picture of a sent message, cached after the first read.
    func sentImage(threadId: String?, _ ref: ImageRef) -> NSImage? {
        guard let threadId else { return nil }
        let key = "\(threadId)/\(ref.id)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let file = try? backend.image(threadId: threadId, imageId: ref.id), let image = NSImage(data: file.data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Vision file

    func installVision() {
        guard !visionInstall.running else { return }
        visionInstall = VisionInstall(running: true, progress: SetupProgress(stage: "Getting ready\u{2026}"))
        error = nil
        let backend = self.backend
        Task { [weak self] in
            do {
                let result = try await backend.installVision { value in DispatchQueue.main.async { self?.visionInstall.progress = value } }
                self?.visionInstall = VisionInstall()
                self?.notice = result.restarted ? "Vision file added. Your model is restarting to load it." : "Vision file added. Your next message can include images."
                self?.record("Added the vision file for \(self?.modelName ?? "the model")")
            } catch {
                self?.visionInstall = VisionInstall()
                if !(error is CancellationError) { self?.error = plainMessage(error) }
                else { self?.notice = "Download paused. What was already downloaded is kept, so the button continues where it stopped." }
            }
            await self?.refresh()
        }
    }

    func cancelVisionInstall() { backend.cancelVisionInstall() }
}

struct VisionInstall: Equatable {
    var running = false
    var progress: SetupProgress?
}
