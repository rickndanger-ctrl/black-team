import XCTest
@testable import BlackTeamKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A pretend huggingface.co: answers by path, remembers what was asked.
final class HubSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var routes: [String: (Int, String)] = [:]
    var failure: Error?
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    var fetch: HTTPFetch {
        { [self] request in
            lock.lock(); _requests.append(request); let routes = self.routes, failure = self.failure; lock.unlock()
            if let failure { throw failure }
            let path = request.url?.path ?? ""
            let (status, body) = routes[path] ?? (404, "{\"error\":\"Repository not found\"}")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }

    /// The routes for unsloth/gemma-4-12b-it-GGUF as recorded.
    static func recorded() -> HubSpy {
        let spy = HubSpy()
        spy.routes["/api/models"] = (200, HubFixtures.search)
        spy.routes["/api/models/unsloth/gemma-4-12b-it-GGUF"] = (200, HubFixtures.info)
        spy.routes["/api/models/unsloth/gemma-4-12b-it-GGUF/tree/main"] = (200, HubFixtures.tree)
        spy.routes["/api/models/unsloth/Qwen3.5-122B-A10B-GGUF"] = (200, HubFixtures.info)
        spy.routes["/api/models/unsloth/Qwen3.5-122B-A10B-GGUF/tree/main"] = (200, HubFixtures.splitTree)
        return spy
    }
}

final class HuggingFaceHubTests: XCTestCase {
    let gib: Int64 = 1 << 30
    var mac16: HardwareProfile {
        HardwareProfile(cpuName: "Apple M2", cores: 8, totalMemory: 16 * gib, availableMemory: 10 * gib, freeDisk: 200 * gib, appleSilicon: true,
                        gpu: .init(name: "Apple M2", vendor: "Apple", vramBytes: nil, vramSource: "shared"), gpuUsable: true)
    }

    // MARK: Reading recorded answers

    func testSearchResultsAreParsedFromTheRecordedAnswer() throws {
        let results = try HuggingFaceHub.parseSearch(Data(HubFixtures.search.utf8))
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].repo, "ornith-ai/Ornith-1.5-9B-GGUF")
        XCTAssertEqual(results[0].author, "ornith-ai")
        XCTAssertGreaterThan(results[0].downloads, 1_000_000)
        XCTAssertGreaterThan(results[0].likes, 100)
        XCTAssertFalse(results[0].gated)
        XCTAssertEqual(results[0].updated?.hasPrefix("2026-"), true)
    }

    func testSearchKeepsGatedFlagsAndDropsAnythingThatIsNotARepoName() throws {
        let body = #"[{"id":"meta-llama/Llama-3.2-1B-GGUF","gated":"manual","downloads":5,"likes":1},{"id":"../../etc/passwd","downloads":1},{"nope":true},{"id":"a/b","gated":"auto"}]"#
        let results = try HuggingFaceHub.parseSearch(Data(body.utf8))
        XCTAssertEqual(results.map(\.repo), ["meta-llama/Llama-3.2-1B-GGUF", "a/b"])
        XCTAssertEqual(results.map(\.gated), [true, true])
        XCTAssertThrowsError(try HuggingFaceHub.parseSearch(Data("{}".utf8)))
        XCTAssertThrowsError(try HuggingFaceHub.parseSearch(Data("not json".utf8)))
    }

    func testRepositoryFactsAreParsedFromTheRecordedAnswer() throws {
        let info = try HuggingFaceHub.parseInfo(Data(HubFixtures.info.utf8))
        XCTAssertEqual(info.license, "apache-2.0")
        XCTAssertFalse(info.gated)
        XCTAssertEqual(info.trainingContext, 262144)
        XCTAssertTrue(info.toolCalling)
        XCTAssertTrue(info.vision)
    }

    func testFilesAreParsedWithSizesHashesAndQuantisations() throws {
        let files = try HuggingFaceHub.parseTree(Data(HubFixtures.tree.utf8))
        XCTAssertFalse(files.contains { $0.path == "README.md" }, "only .gguf files")
        let model = try XCTUnwrap(files.first { $0.path == "gemma-4-12b-it-Q4_K_M.gguf" })
        XCTAssertEqual(model.bytes, 7_121_861_440)
        XCTAssertEqual(model.sha256, "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42")
        XCTAssertEqual(model.quant, "Q4_K_M")
        XCTAssertFalse(model.split)
        XCTAssertEqual(files.first { $0.name == "gemma-4-12b-it-Q8_0.gguf" }?.quant, "Q8_0")
        // The same file as the catalogue knows it.
        XCTAssertEqual(model.bytes, ModelCatalogue.model(id: "gemma-4-12b")?.bytes)
        XCTAssertEqual(model.sha256, ModelCatalogue.model(id: "gemma-4-12b")?.sha256)
    }

    func testSplitModelsAreRecognisedAndNeverOffered() throws {
        let files = try HuggingFaceHub.parseTree(Data(HubFixtures.splitTree.utf8))
        XCTAssertEqual(files.filter(\.split).count, 3)
        let repo = HuggingFaceHub.describe(repo: "unsloth/Qwen3.5-122B-A10B-GGUF", info: try HuggingFaceHub.parseInfo(Data(HubFixtures.info.utf8)), files: files, hardware: mac16)
        XCTAssertEqual(repo.files.count, 3)
        XCTAssertTrue(repo.files.allSatisfy { $0.unavailable?.hasPrefix("Split into several parts") == true })
        XCTAssertFalse(repo.files.contains { $0.suggested })
        XCTAssertNotNil(repo.visionFile)
    }

    func testAFileWithoutAChecksumIsNotOfferedForDownload() throws {
        let tree = #"[{"type":"file","path":"x-Q4_K_M.gguf","size":3000000000}]"#
        let files = try HuggingFaceHub.parseTree(Data(tree.utf8))
        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files[0].sha256)
        let repo = HuggingFaceHub.describe(repo: "a/b", info: .init(license: "mit", gated: false, trainingContext: nil, toolCalling: false, vision: false), files: files, hardware: mac16)
        XCTAssertEqual(repo.files.first?.unavailable?.contains("checksum"), true)
    }

    func testQuantisationNames() {
        let cases = [("Qwen3-14B-Q4_K_M.gguf", "Q4_K_M"), ("gpt-oss-20b-MXFP4.gguf", "MXFP4"), ("Qwen3.8-27B-UD-Q4_K_M.gguf", "Q4_K_M"),
                     ("model-IQ3_XXS.gguf", "IQ3_XXS"), ("llama-3-8b.Q8_0.gguf", "Q8_0"), ("m-BF16.gguf", "BF16"), ("m-f16.gguf", "F16"),
                     ("Qwen3-4B.gguf", ""), ("Q4_K_M-00001-of-00002.gguf", "Q4_K_M"), ("gemma-4-26B-A4B-it-MXFP4_MOE.gguf", "MXFP4_MOE")]
        for (name, quant) in cases { XCTAssertEqual(HuggingFaceHub.quantisation(of: name), quant, name) }
    }

    // MARK: Which file fits

    func testQ4KMIsSuggestedWhenItFitsAndTheBiggerOnesAreMarked() async throws {
        let spy = HubSpy.recorded()
        let repo = try await HuggingFaceHub.repo("unsloth/gemma-4-12b-it-GGUF", hardware: mac16, fetch: spy.fetch)
        XCTAssertEqual(repo.license, "apache-2.0")
        XCTAssertEqual(repo.trainingContext, 262144)
        XCTAssertTrue(repo.toolCalling)
        XCTAssertTrue(repo.vision)
        XCTAssertTrue(repo.inCatalogue, "this repository is in the catalogue")
        XCTAssertEqual(repo.page, "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF")
        XCTAssertEqual(repo.files.map(\.file.name), ["gemma-4-12b-it-Q4_K_M.gguf", "gemma-4-12b-it-Q8_0.gguf"])
        XCTAssertEqual(repo.files.filter(\.suggested).map(\.file.quant), ["Q4_K_M"])
        XCTAssertEqual(repo.files[0].fit, .comfortable)
        XCTAssertEqual(repo.files[1].fit, .tooBig, "12.7 GB does not fit a 16 GB Mac")
        // Companions: F16 vision (not BF16) and the smallest MTP file; neither is listed as a model.
        XCTAssertEqual(repo.visionFile?.path, "mmproj-F16.gguf")
        XCTAssertEqual(repo.draftFile?.bytes, 465_109_248)
        XCTAssertNil(repo.problem)
    }

    func testASmallerQuantisationIsSuggestedWhenQ4DoesNotFit() throws {
        let files = [HubFile(path: "m-Q4_K_M.gguf", name: "m-Q4_K_M.gguf", bytes: 12_000_000_000, sha256: String(repeating: "a", count: 64), quant: "Q4_K_M", split: false),
                     HubFile(path: "m-Q3_K_M.gguf", name: "m-Q3_K_M.gguf", bytes: 5_000_000_000, sha256: String(repeating: "b", count: 64), quant: "Q3_K_M", split: false),
                     HubFile(path: "m-Q2_K.gguf", name: "m-Q2_K.gguf", bytes: 3_000_000_000, sha256: String(repeating: "c", count: 64), quant: "Q2_K", split: false)]
        let eight = HardwareProfile(cores: 4, totalMemory: 8 * gib, availableMemory: 7 * gib, freeDisk: 100 * gib)
        let repo = HuggingFaceHub.describe(repo: "a/m", info: .init(license: "mit", gated: false, trainingContext: nil, toolCalling: false, vision: false), files: files, hardware: eight)
        XCTAssertEqual(repo.files.first { $0.suggested }?.file.quant, "Q2_K", "Q3_K_M only fits tightly; a comfortable fit is preferred")
        XCTAssertEqual(repo.files.first { $0.file.quant == "Q4_K_M" }?.fit, .tooBig)
        XCTAssertFalse(repo.inCatalogue)
        // Nothing fits: nothing is suggested.
        let tiny = HardwareProfile(cores: 2, totalMemory: 2 * gib, freeDisk: 100 * gib)
        XCTAssertNil(HuggingFaceHub.describe(repo: "a/m", info: .init(license: "mit", gated: false, trainingContext: nil, toolCalling: false, vision: false), files: files, hardware: tiny).files.first { $0.suggested })
    }

    func testNotEnoughDiskMarksAFileAndNeverSuggestsIt() {
        var hardware = mac16; hardware.freeDisk = 4_000_000_000
        let files = [HubFile(path: "m-Q4_K_M.gguf", name: "m-Q4_K_M.gguf", bytes: 5_000_000_000, sha256: String(repeating: "a", count: 64), quant: "Q4_K_M", split: false)]
        let repo = HuggingFaceHub.describe(repo: "a/m", info: .init(license: "mit", gated: false, trainingContext: nil, toolCalling: false, vision: false), files: files, hardware: hardware)
        XCTAssertFalse(repo.files[0].fitsDisk)
        XCTAssertFalse(repo.files[0].suggested)
    }

    // MARK: What is asked, and of whom

    func testSearchAsksOnlyHuggingFaceAndSendsNothingPersonal() async throws {
        let spy = HubSpy.recorded()
        let results = try await HuggingFaceHub.search("  ornith  ", fetch: spy.fetch)
        XCTAssertEqual(results.count, 3)
        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "huggingface.co")
        XCTAssertEqual(request.url?.path, "/api/models")
        let query = request.url?.query ?? ""
        XCTAssertTrue(query.contains("search=ornith"))
        XCTAssertTrue(query.contains("filter=gguf"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no sign-in")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Black-Team")
        // Nothing is asked for an empty or absurd search.
        do { _ = try await HuggingFaceHub.search("   ", fetch: spy.fetch); XCTFail("empty") } catch { assertMatch(messageOf(error), "Type a model name") }
        do { _ = try await HuggingFaceHub.search(String(repeating: "a", count: 101), fetch: spy.fetch); XCTFail("long") } catch { assertMatch(messageOf(error), "too long") }
        XCTAssertEqual(spy.requests.count, 1)
    }

    func testRepositoryNamesAndPathsCannotEscapeHuggingFace() async throws {
        let bad = ["", "no-slash", "a/b/c", "../x/y", "a/..", "https://evil.test/x", "a/b?x=1", "a/b#c", "a b/c", "a/b\\c", "@evil.test/x", "a/b%2F..", "./x"]
        for name in bad { XCTAssertFalse(HuggingFaceHub.isValidRepo(name), name) }
        for path in ["../x.gguf", "a/../x.gguf", "/etc/x.gguf", "x.bin", "x.gguf.sh", "a//b.gguf", "a\\b.gguf", "x.gguf?download=true", ".hidden.gguf", "%2e%2e/x.gguf"] {
            XCTAssertFalse(HuggingFaceHub.isValidPath(path), path)
            XCTAssertNil(HuggingFaceHub.fileURL(repo: "a/b", path: path), path)
        }
        XCTAssertNil(HuggingFaceHub.fileURL(repo: "evil.test/../x", path: "x.gguf"))
        let url = try XCTUnwrap(HuggingFaceHub.fileURL(repo: "unsloth/gemma-4-12b-it-GGUF", path: "MTP/mtp-gemma-4-12b-it-Q8_0.gguf"))
        XCTAssertEqual(url.absoluteString, "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/MTP/mtp-gemma-4-12b-it-Q8_0.gguf")
        // An invalid name is refused before anything is sent.
        let spy = HubSpy.recorded()
        do { _ = try await HuggingFaceHub.repo("../../x", hardware: mac16, fetch: spy.fetch); XCTFail("invalid") } catch { assertMatch(messageOf(error), "not a Hugging Face repository name") }
        XCTAssertTrue(spy.requests.isEmpty)
    }

    func testDownloadRequestsAreHttpsHuggingFaceWithTheApisHash() throws {
        let files = try HuggingFaceHub.parseTree(Data(HubFixtures.tree.utf8))
        let file = try XCTUnwrap(files.first { $0.name == "gemma-4-12b-it-Q4_K_M.gguf" })
        let job = HubDownload(repo: "unsloth/gemma-4-12b-it-GGUF", file: file, vision: nil, draft: nil, license: "apache-2.0")
        let request = try XCTUnwrap(job.request(file, to: URL(fileURLWithPath: "/tmp/x/models/m.gguf")))
        XCTAssertEqual(request.url.host, "huggingface.co")
        XCTAssertEqual(request.url.scheme, "https")
        XCTAssertEqual(request.expectedSHA256, file.sha256)
        XCTAssertEqual(request.expectedSize, file.bytes)
        XCTAssertEqual(request.allowedHostSuffixes, ["huggingface.co", "hf.co"])
        // Redirects may only land on Hugging Face's own hosts (the downloader enforces it; this is the list it is given).
        XCTAssertTrue(DownloadHosts.host("cdn-lfs.hf.co", matches: request.allowedHostSuffixes))
        XCTAssertTrue(DownloadHosts.host("us.aws.cdn.hf.co", matches: request.allowedHostSuffixes))
        XCTAssertFalse(DownloadHosts.host("evilhf.co", matches: request.allowedHostSuffixes))
        XCTAssertFalse(DownloadHosts.host("huggingface.co.evil.test", matches: request.allowedHostSuffixes))
        XCTAssertFalse(DownloadHosts.host("github.com", matches: request.allowedHostSuffixes))
        // A file without a hash has no request at all.
        var unchecked = file; unchecked.sha256 = nil
        XCTAssertNil(job.request(unchecked, to: URL(fileURLWithPath: "/tmp/x/models/m.gguf")))
    }

    func testTheDownloaderRefusesAPlainHttpAddress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bt-hub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = DownloadRequest(url: URL(string: "http://huggingface.co/a/b/resolve/main/x.gguf")!, destination: folder.appendingPathComponent("x.gguf"),
                                      expectedSHA256: String(repeating: "a", count: 64), expectedSize: 10, allowedHostSuffixes: DownloadHosts.huggingFace)
        do { _ = try await Downloader(freeSpace: { _ in Int64.max }).download(request); XCTFail("http") } catch { assertMatch(messageOf(error), "https") }
    }

    func testLocalNamesAvoidClashesBetweenDifferentFilesWithTheSameName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bt-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = HubFile(path: "model-Q4_K_M.gguf", name: "model-Q4_K_M.gguf", bytes: 1000, sha256: String(repeating: "a", count: 64), quant: "Q4_K_M", split: false)
        let job = HubDownload(repo: "owner/Model-GGUF", file: file, vision: nil, draft: nil, license: "mit")
        XCTAssertEqual(job.localName(in: folder), "model-Q4_K_M.gguf")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("model-Q4_K_M.gguf").path, contents: Data(repeating: 0, count: 1000))
        XCTAssertEqual(job.localName(in: folder), "model-Q4_K_M.gguf", "the same file again is the same file")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("model-Q4_K_M.gguf").path, contents: Data(repeating: 0, count: 7))
        XCTAssertEqual(job.localName(in: folder), "owner--Model-GGUF--model-Q4_K_M.gguf")
        XCTAssertEqual(HubDownload.companionName(model: "model-Q4_K_M.gguf", kind: "mmproj"), "model-Q4_K_M-mmproj.gguf")
        XCTAssertTrue(HuggingFaceHub.isVisionFile(HubDownload.companionName(model: "model-Q4_K_M.gguf", kind: "mmproj")))
        XCTAssertTrue(HuggingFaceHub.isDraftFile(HubDownload.companionName(model: "model-Q4_K_M.gguf", kind: "mtp")))
    }

    // MARK: Failures in plain words

    func testGatedAndUnreachableRepositories() async throws {
        let spy = HubSpy.recorded()
        spy.routes["/api/models/meta-llama/Llama-3.2-1B-GGUF"] = (200, #"{"id":"meta-llama/Llama-3.2-1B-GGUF","gated":"manual","cardData":{"license":"llama3.2"},"tags":["gguf"]}"#)
        spy.routes["/api/models/meta-llama/Llama-3.2-1B-GGUF/tree/main"] = (200, #"[{"type":"file","path":"l-Q4_K_M.gguf","size":800000000,"lfs":{"oid":"\#(String(repeating: "a", count: 64))","size":800000000}}]"#)
        let gated = try await HuggingFaceHub.repo("meta-llama/Llama-3.2-1B-GGUF", hardware: mac16, fetch: spy.fetch)
        XCTAssertTrue(gated.gated)
        assertMatch(try XCTUnwrap(gated.problem), "accept its terms")
        assertMatch(gated.problem ?? "", "does not sign in")

        spy.routes["/api/models/private/thing"] = (401, "{\"error\":\"Invalid username or password.\"}")
        do { _ = try await HuggingFaceHub.repo("private/thing", hardware: mac16, fetch: spy.fetch); XCTFail("401") } catch { assertMatch(messageOf(error), "private or asks you to accept its terms") }
        spy.routes["/api/models/locked/thing"] = (403, "{}")
        do { _ = try await HuggingFaceHub.repo("locked/thing", hardware: mac16, fetch: spy.fetch); XCTFail("403") } catch { assertMatch(messageOf(error), "does not sign in to Hugging Face") }
        do { _ = try await HuggingFaceHub.repo("nobody/nothing", hardware: mac16, fetch: spy.fetch); XCTFail("404") } catch { XCTAssertEqual(messageOf(error), "Hugging Face has no repository called nobody/nothing.") }
        spy.routes["/api/models"] = (429, "{}")
        do { _ = try await HuggingFaceHub.search("x", fetch: spy.fetch); XCTFail("429") } catch { assertMatch(messageOf(error), "slow down") }
        spy.routes["/api/models"] = (503, "{}")
        do { _ = try await HuggingFaceHub.search("x", fetch: spy.fetch); XCTFail("503") } catch { assertMatch(messageOf(error), "HTTP 503") }
        spy.failure = URLError(.notConnectedToInternet)
        do { _ = try await HuggingFaceHub.search("x", fetch: spy.fetch); XCTFail("offline") } catch { assertMatch(messageOf(error), "could not reach huggingface.co") }
    }
}
