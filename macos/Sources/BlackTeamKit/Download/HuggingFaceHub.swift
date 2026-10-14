import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Finding a GGUF model on Hugging Face and getting its facts from the Hugging Face API. Only when the person asks (a search, opening a
// repository, a download), only huggingface.co, no sign-in and no cookies. The size and SHA-256 of a file come from the API
// (`/api/models/<repo>/tree/main`: `size` and `lfs.oid`) and the downloader checks the finished file against them.

/// One repository in a search.
public struct HubSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var repo: String
    public var author: String
    public var downloads: Int
    public var likes: Int
    /// The repository asks people to accept terms first.
    public var gated: Bool
    public var updated: String?
    public var id: String { repo }
}

/// One `.gguf` file in a repository.
public struct HubFile: Codable, Sendable, Equatable, Identifiable {
    /// Path in the repository (may include a folder).
    public var path: String
    public var name: String
    public var bytes: Int64
    /// From the API's `lfs.oid`. Nil only for a file the API gave no hash for, which is never offered for download.
    public var sha256: String?
    /// "Q4_K_M", "MXFP4", "F16" ... or "" when the name does not say.
    public var quant: String
    /// One part of a model split over several files.
    public var split: Bool
    public var id: String { path }
}

/// What a model-listing screen needs about one file on this computer.
public struct HubFileAssessment: Codable, Sendable, Equatable, Identifiable {
    public var file: HubFile
    public var fit: FitLevel
    public var neededBytes: Int64
    public var fitsDisk: Bool
    public var speed: SpeedEstimate
    /// The quantisation Black Team suggests for this computer (Q4_K_M-class when it fits).
    public var suggested: Bool
    /// Why this file cannot be downloaded, when it cannot.
    public var unavailable: String?
    public var id: String { file.path }
}

public struct HubRepo: Codable, Sendable, Equatable {
    public var repo: String
    public var license: String
    public var gated: Bool
    public var trainingContext: Int?
    public var toolCalling: Bool
    public var vision: Bool
    /// The page to read about the model.
    public var page: String
    /// A model from the Black Team catalogue, not from someone else.
    public var inCatalogue: Bool
    public var files: [HubFileAssessment]
    /// Companions in the same repository, offered with the download.
    public var visionFile: HubFile?
    public var draftFile: HubFile?
    /// Set when the repository cannot be downloaded (it asks for sign-in), in plain words.
    public var problem: String?
}

public enum HuggingFaceHub {
    public static let host = "huggingface.co"

    // MARK: Names that are safe to put in a URL or a file name

    public static func isValidRepo(_ repo: String) -> Bool {
        repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$"#, options: .regularExpression) != nil
            && !repo.contains("..")
    }

    /// A path inside a repository: segments of letters, digits and `._-`, ending in `.gguf`, never `..`.
    public static func isValidPath(_ path: String) -> Bool {
        guard path.count <= 300, path.lowercased().hasSuffix(".gguf") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.range(of: #"^[A-Za-z0-9][A-Za-z0-9._()+=,@ -]*$"#, options: .regularExpression) != nil
        }
    }

    /// The address of a file, always on huggingface.co.
    public static func fileURL(repo: String, path: String) -> URL? {
        guard isValidRepo(repo), isValidPath(path) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host
        parts.percentEncodedPath = "/" + repo + "/resolve/main/" + path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return parts.url
    }

    public static func pageURL(repo: String) -> String { "https://\(host)/\(repo)" }

    // MARK: Reading the API's answers

    public static func parseSearch(_ data: Data) throws -> [HubSearchResult] {
        guard let list = try? JSONValue.parse(data).array else { throw BlackTeamError("Hugging Face sent an answer Black Team could not read.") }
        return list.compactMap { item in
            guard let repo = item["id"]?.string, isValidRepo(repo) else { return nil }
            let gated: Bool = { if let flag = item["gated"]?.bool { return flag }; return item["gated"]?.string != nil }()
            return HubSearchResult(repo: repo, author: item["author"]?.string ?? String(repo.split(separator: "/").first ?? ""),
                                   downloads: item["downloads"]?.int ?? 0, likes: item["likes"]?.int ?? 0, gated: gated, updated: item["lastModified"]?.string)
        }
    }

    /// The part of `/api/models/<repo>` that Black Team reads.
    struct Info: Equatable {
        var license: String
        var gated: Bool
        var trainingContext: Int?
        var toolCalling: Bool
        var vision: Bool
    }

    static func parseInfo(_ data: Data) throws -> Info {
        guard let value = try? JSONValue.parse(data), value.object != nil else { throw BlackTeamError("Hugging Face sent an answer Black Team could not read.") }
        let tags = (value["tags"]?.array ?? []).compactMap(\.string)
        var license = value["cardData"]?["license"]?.string ?? ""
        if license.isEmpty, let tag = tags.first(where: { $0.hasPrefix("license:") }) { license = String(tag.dropFirst(8)) }
        let template = value["gguf"]?["chat_template"]?.string ?? ""
        let gated: Bool = { if let flag = value["gated"]?.bool { return flag }; return value["gated"]?.string != nil }()
        return Info(license: license, gated: gated, trainingContext: value["gguf"]?["context_length"]?.int,
                    toolCalling: template.lowercased().contains("tool"),
                    vision: tags.contains("image-text-to-text") || tags.contains("vision"))
    }

    static let splitPattern = #"-\d{5}-of-\d{5}\.gguf$"#

    /// Every `.gguf` file with its size and hash. Folders are walked by the API (`recursive=true`).
    static func parseTree(_ data: Data) throws -> [HubFile] {
        guard let list = try? JSONValue.parse(data).array else { throw BlackTeamError("Hugging Face sent an answer Black Team could not read.") }
        var files: [HubFile] = []
        for item in list where item["type"]?.string == "file" {
            guard let path = item["path"]?.string, isValidPath(path) else { continue }
            let size = Int64(item["lfs"]?["size"]?.double ?? item["size"]?.double ?? 0)
            guard size > 0 else { continue }
            let hash = item["lfs"]?["oid"]?.string?.lowercased()
            let name = (path as NSString).lastPathComponent
            files.append(HubFile(path: path, name: name, bytes: size, sha256: hash.flatMap { isHash($0) ? $0 : nil }, quant: quantisation(of: name),
                                 split: name.range(of: splitPattern, options: [.regularExpression, .caseInsensitive]) != nil))
        }
        return files
    }

    static func isHash(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    static func isVisionFile(_ name: String) -> Bool { name.range(of: #"(^|[-_.])mmproj([-_.]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil }
    static func isDraftFile(_ name: String) -> Bool { name.range(of: #"(^|[-_.])(mtp|draft)([-_.]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil }
    static func isHelperFile(_ name: String) -> Bool { isVisionFile(name) || isDraftFile(name) }

    /// "Qwen3-14B-Q4_K_M.gguf" -> "Q4_K_M"; "gpt-oss-20b-MXFP4.gguf" -> "MXFP4"; "x-UD-Q4_K_M.gguf" -> "Q4_K_M".
    public static func quantisation(of name: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])(I?Q\d(?:_[A-Z0-9]+)*|MXFP4(?:_MOE)?|NVFP4|BF16|F16|F32)(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.matches(in: name, range: NSRange(name.startIndex..., in: name)).last, let range = Range(match.range(at: 1), in: name) else { return "" }
        return String(name[range]).uppercased()
    }

    /// Smaller number = preferred. Q4_K_M first (the best size/quality trade for most), then its neighbours, then smaller ones, then large ones.
    static let quantOrder = ["Q4_K_M", "MXFP4", "Q4_K_S", "IQ4_XS", "Q4_0", "Q4_1", "Q5_K_M", "Q5_K_S", "Q6_K", "Q3_K_M", "IQ3_M", "Q3_K_L", "Q3_K_S",
                             "IQ3_XXS", "Q8_0", "Q2_K", "IQ2_M", "IQ2_XXS", "BF16", "F16", "F32"]
    static func quantRank(_ quant: String) -> Int { quantOrder.firstIndex(of: quant) ?? quantOrder.count }

    // MARK: Putting a repository together for this computer

    /// Marks each file's fit, picks the suggested one and the companions. `info` and `files` come from the API.
    static func describe(repo: String, info: Info, files: [HubFile], hardware: HardwareProfile) -> HubRepo {
        let models = files.filter { !isHelperFile($0.name) }
        var assessed = models.map { file -> HubFileAssessment in
            let report = ModelRecommender.assess(bytes: file.bytes, activeFraction: nil, on: hardware)
            let diskOK = hardware.freeDisk.map { $0 >= file.bytes } ?? true
            var why: String?
            if file.split { why = "Split into several parts; Black Team cannot download those yet." }
            else if file.sha256 == nil { why = "Hugging Face gives no checksum for this file, so Black Team could not check it." }
            return HubFileAssessment(file: file, fit: report.fit, neededBytes: report.neededBytes, fitsDisk: diskOK, speed: report.speed, suggested: false, unavailable: why)
        }
        // Suggested: the preferred quantisation that fits comfortably, otherwise the preferred one that fits at all.
        func pickable(_ level: [FitLevel]) -> Int? {
            assessed.indices.filter { assessed[$0].unavailable == nil && assessed[$0].fitsDisk && level.contains(assessed[$0].fit) }
                .min { (quantRank(assessed[$0].file.quant), assessed[$0].file.bytes) < (quantRank(assessed[$1].file.quant), assessed[$1].file.bytes) }
        }
        if let index = pickable([.comfortable]) ?? pickable([.comfortable, .tight]) { assessed[index].suggested = true }
        assessed.sort { ($0.unavailable == nil ? 0 : 1, quantRank($0.file.quant), $0.file.bytes) < ($1.unavailable == nil ? 0 : 1, quantRank($1.file.quant), $1.file.bytes) }

        let helpers = files.filter { $0.sha256 != nil && !$0.split }
        let vision = helpers.filter { isVisionFile($0.name) }.min { visionRank($0.name) < visionRank($1.name) }
        let draft = helpers.filter { isDraftFile($0.name) }.min { $0.bytes < $1.bytes }
        let inCatalogue = ModelCatalogue.all.contains { $0.repo.lowercased() == repo.lowercased() }
        var problem: String?
        if info.gated { problem = "This repository asks you to accept its terms on huggingface.co before anyone can download from it. Black Team does not sign in to Hugging Face, so it cannot download this one. Open the page, accept the terms, and download the file yourself; Black Team will find it in your Downloads folder." }
        return HubRepo(repo: repo, license: info.license.isEmpty ? "unknown" : info.license, gated: info.gated, trainingContext: info.trainingContext,
                       toolCalling: info.toolCalling, vision: info.vision || vision != nil, page: pageURL(repo: repo), inCatalogue: inCatalogue,
                       files: assessed, visionFile: vision, draftFile: draft, problem: problem)
    }

    static func visionRank(_ name: String) -> Int {
        let upper = name.uppercased()
        return upper.contains("F16") && !upper.contains("BF16") ? 0 : upper.contains("BF16") ? 1 : upper.contains("F32") ? 3 : 2
    }

    // MARK: Asking

    /// Searches GGUF repositories, most downloaded first.
    public static func search(_ query: String, limit: Int = 20, fetch: HTTPFetch) async throws -> [HubSearchResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BlackTeamError("Type a model name to search for.") }
        guard text.count <= 100 else { throw BlackTeamError("That search is too long.") }
        let items = [URLQueryItem(name: "search", value: text), URLQueryItem(name: "filter", value: "gguf"), URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: String(max(1, min(50, limit))))]
            + ["downloads", "likes", "gated", "lastModified", "author"].map { URLQueryItem(name: "expand[]", value: $0) }
        return try parseSearch(try await get("/api/models", items, fetch: fetch))
    }

    /// The facts about one repository, with each file marked for this computer.
    public static func repo(_ repo: String, hardware: HardwareProfile, fetch: HTTPFetch) async throws -> HubRepo {
        let name = repo.trimmingCharacters(in: .whitespaces)
        guard isValidRepo(name) else { throw BlackTeamError("That is not a Hugging Face repository name. It looks like owner/model-name.") }
        let (info, files) = try await facts(name, fetch: fetch)
        return describe(repo: name, info: info, files: files, hardware: hardware)
    }

    static func facts(_ repo: String, fetch: HTTPFetch) async throws -> (Info, [HubFile]) {
        let info = try parseInfo(try await get("/api/models/\(repo)", ["gated", "gguf", "cardData", "tags"].map { URLQueryItem(name: "expand[]", value: $0) }, fetch: fetch, repo: repo))
        let tree = try await get("/api/models/\(repo)/tree/main", [URLQueryItem(name: "recursive", value: "true")], fetch: fetch, repo: repo)
        return (info, try parseTree(tree))
    }

    /// One GET on huggingface.co. The address is built here, never taken from outside, so nothing else can be asked.
    static func get(_ path: String, _ query: [URLQueryItem], fetch: HTTPFetch, repo: String? = nil) async throws -> Data {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.percentEncodedPath = path; parts.queryItems = query
        guard let url = parts.url, url.host == host else { throw BlackTeamError("That address is not on Hugging Face.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Black-Team", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let data: Data, reply: HTTPURLResponse
        do { (data, reply) = try await fetch(request) } catch is CancellationError { throw CancellationError() } catch let error as BlackTeamError { throw error } catch {
            throw BlackTeamError("Black Team could not reach huggingface.co. Check the internet connection and try again.")
        }
        switch reply.statusCode {
        case 200: break
        case 401, 403:
            throw BlackTeamError(repo == nil ? "Hugging Face did not allow this search." : "This repository is private or asks you to accept its terms on huggingface.co first. Black Team does not sign in to Hugging Face, so it cannot download it.")
        case 404: throw BlackTeamError(repo == nil ? "Hugging Face does not have that." : "Hugging Face has no repository called \(repo!).")
        case 429: throw BlackTeamError("Hugging Face asked Black Team to slow down. Wait a minute and try again.")
        default: throw BlackTeamError("Hugging Face replied with an error (HTTP \(reply.statusCode)). Please try again later.")
        }
        guard data.count <= 16 << 20 else { throw BlackTeamError("Hugging Face sent more than Black Team will read.") }
        return data
    }
}

/// A file chosen on Hugging Face (not from the catalogue), ready to download. Built only from the API's own answer.
struct HubDownload: Sendable {
    var repo: String
    var file: HubFile
    var vision: HubFile?
    var draft: HubFile?
    var license: String

    func request(_ file: HubFile, to destination: URL) -> DownloadRequest? {
        guard let url = HuggingFaceHub.fileURL(repo: repo, path: file.path), let hash = file.sha256 else { return nil }
        return DownloadRequest(url: url, destination: destination, expectedSHA256: hash, expectedSize: file.bytes, allowedHostSuffixes: DownloadHosts.huggingFace)
    }

    /// Where the model is saved in `<data>/models/`. Two repositories can call a file the same; a clash with a different file adds the owner.
    func localName(in folder: URL) -> String {
        let existing = Downloader.fileSize(folder.appendingPathComponent(file.name))
        return existing != 0 && existing != file.bytes ? repo.replacingOccurrences(of: "/", with: "--") + "--" + file.name : file.name
    }

    /// A companion is saved beside the model under a name made from the model's own, so two models never share one.
    /// The words "mmproj" and "mtp" stay in the name, which is how Black Team recognises them beside a model.
    static func companionName(model localName: String, kind: String) -> String {
        (localName as NSString).deletingPathExtension + "-" + kind + ".gguf"
    }
}
