import XCTest
@testable import BlackTeamKit

final class ModelCatalogueTests: XCTestCase {
    func testCatalogueIsWellFormed() {
        let all = ModelCatalogue.all
        XCTAssertGreaterThanOrEqual(all.count, 11)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
        XCTAssertEqual(Set(all.map(\.filename)).count, all.count, "files are unique, so two models never share a path")
        XCTAssertEqual(all.map(\.bytes), all.map(\.bytes).sorted(), "smallest first")
        XCTAssertTrue(StarterModels.all.allSatisfy { starter in all.contains { $0.id == starter.id && $0 == starter } }, "the four starters are kept as they were")
        for model in all {
            XCTAssertGreaterThan(model.bytes, 0, model.id)
            XCTAssertTrue(isHash(model.sha256), model.id)
            XCTAssertTrue(model.filename.hasSuffix(".gguf"), model.id)
            XCTAssertTrue(HuggingFaceHub.isValidRepo(model.repo), model.id)
            XCTAssertTrue(HuggingFaceHub.isValidPath(model.filename), model.id)
            XCTAssertEqual(model.url, HuggingFaceHub.fileURL(repo: model.repo, path: model.filename), model.id)
            XCTAssertEqual(model.url.host, "huggingface.co")
            XCTAssertFalse(model.license.isEmpty, model.id)
            XCTAssertGreaterThan(model.contextSize, 0, model.id)
            XCTAssertNotNil(model.trainingContext, model.id)
            XCTAssertGreaterThanOrEqual(model.trainingContext ?? 0, model.contextSize, "\(model.id): the context to run is within what it was trained for")
            if let fraction = model.activeFraction { XCTAssertTrue(fraction > 0 && fraction < 1, model.id) }
            XCTAssertGreaterThan(model.quality, 0)
            XCTAssertFalse(model.summary.isEmpty)
            for companion in [model.vision, model.draft].compactMap({ $0 }) {
                XCTAssertGreaterThan(companion.bytes, 0, model.id)
                XCTAssertTrue(isHash(companion.sha256), model.id)
                XCTAssertTrue(HuggingFaceHub.isValidRepo(companion.repo))
                XCTAssertTrue(HuggingFaceHub.isValidPath(companion.filename))
                XCTAssertEqual(companion.repo, model.repo, "a companion comes from the model's own repository")
                XCTAssertEqual(companion.url.host, "huggingface.co")
            }
        }
        // Local names never collide, across models and their companions.
        let names = all.flatMap { [$0.filename] + [$0.vision?.localName, $0.draft?.localName].compactMap { $0 } }
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testCompanionNamesAreRecognisedBesideAModel() {
        for model in ModelCatalogue.all {
            if let vision = model.vision { XCTAssertTrue(HuggingFaceHub.isVisionFile(vision.localName), vision.localName) }
            if let draft = model.draft { XCTAssertTrue(HuggingFaceHub.isDraftFile(draft.localName), draft.localName) }
            XCTAssertFalse(HuggingFaceHub.isHelperFile(model.filename), model.filename)
        }
    }

    func testCatalogueCoversSmallLaptopsUpTo64GigabyteMachines() {
        let all = ModelCatalogue.all
        XCTAssertLessThan(all.first!.bytes, 1_000_000_000)
        XCTAssertGreaterThan(all.last!.bytes, 60_000_000_000)
        XCTAssertGreaterThanOrEqual(all.filter { $0.bytes > 14_000_000_000 }.count, 4, "sizes above 14B")
        XCTAssertNotNil(ModelCatalogue.model(id: "ornith-1.5-35b-a3b"))
        XCTAssertNotNil(ModelCatalogue.model(id: "qwen3.8-27b"))
        XCTAssertEqual(ModelCatalogue.model(id: "ornith-1.5-35b-a3b")?.repo, "ornith-ai/Ornith-1.5-35B-A3B-GGUF")
        XCTAssertEqual(ModelCatalogue.model(id: "qwen3.8-27b")?.repo, "unsloth/Qwen3.8-27B-GGUF")
    }

    func testModelInUseIsFoundByItsFile() {
        let folder = URL(fileURLWithPath: "/tmp/bt")
        let model = ModelCatalogue.model(id: "gemma-4-12b")!
        XCTAssertEqual(ModelCatalogue.model(file: "/tmp/bt/models/\(model.filename)", dataFolder: folder)?.id, "gemma-4-12b")
        XCTAssertNil(ModelCatalogue.model(file: "/elsewhere/\(model.filename)", dataFolder: folder))
    }

    func testOldStarterApiIsUnchanged() {
        XCTAssertEqual(StarterModels.all.map(\.id), ["qwen3.5-0.8b", "qwen3.5-4b", "ornith-1.5-9b", "qwen3-14b"])
        let gib: Int64 = 1 << 30
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 64 * gib).id, "qwen3-14b")
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 8 * gib).id, "qwen3.5-4b")
    }

    func isHash(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    /// Metadata only: the Hugging Face API's size and sha256 for every catalogue file, nothing downloaded.
    func testLiveCatalogueMatchesHuggingFace() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACK_TEAM_LIVE"] == "1", "live test")
        var repos: [String: [HubFile]] = [:]
        for model in ModelCatalogue.all where repos[model.repo] == nil { repos[model.repo] = try await HuggingFaceHub.facts(model.repo, fetch: LocalHTTP.fetch).1 }
        for model in ModelCatalogue.all {
            let files = try XCTUnwrap(repos[model.repo])
            for (path, bytes, sha) in [(model.filename, model.bytes, model.sha256)] + [model.vision, model.draft].compactMap({ $0 }).map({ ($0.filename, $0.bytes, $0.sha256) }) {
                let found = try XCTUnwrap(files.first { $0.path == path }, "\(model.id): \(path)")
                XCTAssertEqual(found.bytes, bytes, "\(model.id): \(path)")
                XCTAssertEqual(found.sha256, sha, "\(model.id): \(path)")
            }
        }
    }
}
