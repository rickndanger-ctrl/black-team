import Foundation

/// Prepared images live as private files, `<data>/attachments/<conversation id>/<image id>.<jpg|png|webp>`, never inside the
/// conversation (a conversation is capped at 5 MiB, and the phone API sends conversations out). The message keeps `ImageRef`s.
/// Files belong to their conversation and stay while it exists; there is no way to delete a conversation yet, so nothing else
/// removes them. A submit that fails after the files were written removes them again (`remove`).
public final class ImageStore: @unchecked Sendable {
    public let root: String

    public init(dataFolder: String) { root = dataFolder + "/attachments" }

    private func folder(_ threadId: String) throws -> String {
        guard History.validID(threadId) else { throw BlackTeamError("Invalid conversation ID.") }
        return root + "/" + threadId
    }

    /// Writes each image (already validated by `ImageRules.validate`) and returns what the message should keep.
    public func save(_ images: [ImageUpload], kinds: [ImageRules.Kind], threadId: String) throws -> [ImageRef] {
        let directory = try folder(threadId)
        var written: [String] = []
        do {
            try privateDirectory(root)
            try privateDirectory(directory)
            var refs: [ImageRef] = []
            for (image, kind) in zip(images, kinds) {
                guard let size = ImagePreparer.dimensions(of: image.data) else { throw BlackTeamError(ImageRules.badDataMessage) }
                let id = UUID().uuidString.lowercased()
                let file = "\(directory)/\(id).\(kind.fileExtension)"
                try CoreFS.writeAtomic(file, image.data, temporary: "\(file).\(CoreFS.hex(6)).tmp")
                chmod(file, 0o600)
                written.append(file)
                refs.append(ImageRef(id: id, name: image.name, bytes: image.data.count, width: size.width, height: size.height))
            }
            return refs
        } catch {
            written.forEach { unlink($0) }
            rmdir(directory)
            throw error
        }
    }

    /// Takes back files a failed submit wrote. The folder goes too when nothing else is in it.
    public func remove(_ refs: [ImageRef], threadId: String) {
        guard let directory = try? folder(threadId) else { return }
        for ref in refs { for kind in [ImageRules.Kind.jpeg, .png, .webp] { unlink("\(directory)/\(ref.id).\(kind.fileExtension)") } }
        rmdir(directory)
    }

    /// An image's bytes and type. The ids must have the right shape, the file must be a plain file (not a link) and lie inside the
    /// conversation's own folder once symbolic links are resolved.
    public func read(threadId: String, imageId: String) throws -> (data: Data, mime: String) {
        let missing = BlackTeamError("That image is no longer stored.")
        let directory = try folder(threadId)
        guard History.validID(imageId) else { throw missing }
        guard let resolvedDirectory = realpath(directory, nil) else { throw missing }
        let base = String(cString: resolvedDirectory); free(resolvedDirectory)
        for kind in [ImageRules.Kind.jpeg, .png, .webp] {
            let file = "\(directory)/\(imageId).\(kind.fileExtension)"
            guard !CoreFS.isSymlink(file), CoreFS.exists(file), let resolved = realpath(file, nil) else { continue }
            let real = String(cString: resolved); free(resolved)
            let info = CoreFS.stat(real)
            guard real.hasPrefix(base + "/"), (info.mode & S_IFMT) == S_IFREG, info.size <= ImageRules.maxBytes,
                  let data = FileManager.default.contents(atPath: real), ImageRules.kind(of: data) == kind else { throw missing }
            return (data, kind.mime)
        }
        throw missing
    }
}
