import Foundation

/// A small model offered on first run. Values were read from the Hugging Face API
/// (`/api/models/<repo>/tree/main`: size and lfs.oid = SHA-256) on 2026-10-11.
/// The projector file that lets a starter model read images (llama.cpp's `--mmproj`), from the same Hugging Face repository.
/// Saved under `localName`, so two models whose repositories both call theirs `mmproj-F16.gguf` do not collide in `<data>/models/`.
public struct StarterVision: Codable, Sendable, Equatable {
    public var repo: String
    public var filename: String
    public var localName: String
    public var bytes: Int64
    public var sha256: String

    public var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(filename)")! }

    public func destination(in dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent("models", isDirectory: true).appendingPathComponent(localName)
    }

    public func isInstalled(in dataFolder: URL) -> Bool { Downloader.fileSize(destination(in: dataFolder)) == bytes }

    public func downloadRequest(dataFolder: URL) -> DownloadRequest {
        DownloadRequest(url: url, destination: destination(in: dataFolder), expectedSHA256: sha256, expectedSize: bytes,
                        allowedHostSuffixes: DownloadHosts.huggingFace)
    }
}

public struct StarterModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// One plain sentence for the person choosing.
    public var summary: String
    public var repo: String
    public var filename: String
    public var bytes: Int64
    public var sha256: String
    public var license: String
    public var contextSize: Int
    public var toolCalling: Bool
    /// Present when the model can read images and has a projector to download.
    public var vision: StarterVision? = nil

    public var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(filename)")! }

    /// Memory the model needs with headroom: the rule of `estimateMemory` in `lib/config.cjs`
    /// (the larger of 2 GiB and a quarter of the model).
    public var minimumMemoryBytes: Int64 { StarterModels.estimatedMemory(modelBytes: bytes) }

    public func destination(in dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent("models", isDirectory: true).appendingPathComponent(filename)
    }

    public func isInstalled(in dataFolder: URL) -> Bool {
        Downloader.fileSize(destination(in: dataFolder)) == bytes
    }

    public func downloadRequest(dataFolder: URL) -> DownloadRequest {
        DownloadRequest(url: url, destination: destination(in: dataFolder), expectedSHA256: sha256, expectedSize: bytes,
                        allowedHostSuffixes: DownloadHosts.huggingFace)
    }
}

public enum StarterModels {
    private static let gib: Int64 = 1 << 30

    public static func estimatedMemory(modelBytes: Int64) -> Int64 {
        modelBytes + max(2 * gib, Int64((Double(modelBytes) * 0.25).rounded(.up)))
    }

    /// Smallest first, all Q4_K_M: Qwen3.5 in unsloth's GGUF conversions (Apache-2.0), Ornith 1.5 9B from
    /// its makers (MIT), which Rick chose as the recommended model for a 16 GB Mac, and Qwen's own Qwen3 14B (Apache-2.0).
    public static let all: [StarterModel] = [
        StarterModel(
            id: "qwen3.5-0.8b", name: "Qwen3.5 0.8B (tiny)",
            summary: "A very small model for a quick test that everything works; answers are basic.",
            repo: "unsloth/Qwen3.5-0.8B-GGUF", filename: "Qwen3.5-0.8B-Q4_K_M.gguf",
            bytes: 532_517_120, sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
            license: "Apache-2.0", contextSize: 8192, toolCalling: false,
            vision: StarterVision(repo: "unsloth/Qwen3.5-0.8B-GGUF", filename: "mmproj-F16.gguf", localName: "Qwen3.5-0.8B-mmproj-F16.gguf",
                                  bytes: 204_987_232, sha256: "56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453")),
        StarterModel(
            id: "qwen3.5-4b", name: "Qwen3.5 4B (small)",
            summary: "A good everyday chat model that runs comfortably on any recent \(Place.kind).",
            repo: "unsloth/Qwen3.5-4B-GGUF", filename: "Qwen3.5-4B-Q4_K_M.gguf",
            bytes: 2_740_937_888, sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
            license: "Apache-2.0", contextSize: 16384, toolCalling: true,
            vision: StarterVision(repo: "unsloth/Qwen3.5-4B-GGUF", filename: "mmproj-F16.gguf", localName: "Qwen3.5-4B-mmproj-F16.gguf",
                                  bytes: 672_423_616, sha256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864")),
        StarterModel(
            id: "ornith-1.5-9b", name: "Ornith 1.5 9B (medium)",
            summary: "Smarter answers and reliable use of tools; the best starting point for the Code agent.",
            repo: "ornith-ai/Ornith-1.5-9B-GGUF", filename: "Ornith-1.5-9B-Q4_K_M.gguf",
            bytes: 5_780_090_816, sha256: "70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6",
            license: "MIT", contextSize: 32768, toolCalling: true,
            vision: StarterVision(repo: "ornith-ai/Ornith-1.5-9B-GGUF", filename: "mmproj-Ornith-1.5-9B-BF16.gguf", localName: "Ornith-1.5-9B-mmproj-BF16.gguf",
                                  bytes: 921_704_672, sha256: "626f9f90627402a6bf4a999111d0fbd69b5fcca7aa8ba089d69e5f10e8858e1d")),
        StarterModel(
            id: "qwen3-14b", name: "Qwen3 14B (large)",
            summary: "The most capable of the starter models; needs a \(Place.kind) with plenty of memory.",
            repo: "Qwen/Qwen3-14B-GGUF", filename: "Qwen3-14B-Q4_K_M.gguf",
            bytes: 9_001_752_960, sha256: "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true),
    ]

    public static func model(id: String) -> StarterModel? { all.first { $0.id == id } }

    /// The largest model that fits comfortably, or the smallest one if none does (so a first run
    /// always has something to offer). A Mac shares its memory with everything else that is open,
    /// so the model with its headroom may take up to 60% of it.
    public static func recommended(forMemoryBytes memory: Int64) -> StarterModel {
        let room = memory / 10 * 6
        return all.last { $0.minimumMemoryBytes <= room } ?? all[0]
    }

    public static var recommendedForThisMac: StarterModel {
        recommended(forMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
    }

    /// Downloads a starter model into `<dataFolder>/models/`. Resumes a partial download.
    @discardableResult
    public static func install(_ model: StarterModel, dataFolder: URL, downloader: FileDownloading = Downloader(),
                               progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> URL {
        try await downloader.download(model.downloadRequest(dataFolder: dataFolder), progress: progress)
    }
}
