import XCTest
@testable import BlackTeamKit

final class StarterModelsTests: XCTestCase {
    let gib: Int64 = 1 << 30

    func testCatalogueIsWellFormed() {
        XCTAssertGreaterThanOrEqual(StarterModels.all.count, 3)
        XCTAssertEqual(Set(StarterModels.all.map(\.id)).count, StarterModels.all.count)
        for model in StarterModels.all {
            XCTAssertEqual(model.sha256.count, 64, model.id)
            XCTAssertTrue(model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, model.id)
            XCTAssertTrue(model.filename.hasSuffix(".gguf"))
            XCTAssertEqual(model.url.scheme, "https")
            XCTAssertEqual(model.url.host, "huggingface.co")
            XCTAssertTrue(model.url.path.hasSuffix("/resolve/main/\(model.filename)"))
            XCTAssertFalse(model.license.isEmpty)
            XCTAssertGreaterThan(model.contextSize, 0)
        }
        XCTAssertEqual(StarterModels.all.map(\.bytes), StarterModels.all.map(\.bytes).sorted())
    }

    func testMemoryRuleIsLargerOfTwoGiBAndAQuarter() {
        XCTAssertEqual(StarterModels.estimatedMemory(modelBytes: gib), 3 * gib)
        XCTAssertEqual(StarterModels.estimatedMemory(modelBytes: 12 * gib), 15 * gib)
    }

    func testRecommendationPicksLargestThatFits() throws {
        let small = StarterModels.all[0], medium = StarterModels.all[2], large = StarterModels.all[3]
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 64 * gib), large)
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 24 * gib), large)
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 16 * gib), medium)   // 5.7 GB + 2 GiB within 60% of 16
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 8 * gib), StarterModels.all[1])
        XCTAssertEqual(StarterModels.recommended(forMemoryBytes: 1 * gib), small)   // always something to offer
    }

    func testDestinationAndRequest() {
        let data = URL(fileURLWithPath: "/tmp/bt-data")
        let model = StarterModels.all[1]
        XCTAssertEqual(model.destination(in: data).path, "/tmp/bt-data/models/\(model.filename)")
        let request = model.downloadRequest(dataFolder: data)
        XCTAssertEqual(request.expectedSize, model.bytes)
        XCTAssertEqual(request.expectedSHA256, model.sha256)
        XCTAssertTrue(request.allowedHostSuffixes.contains("hf.co"))
    }

    func testLiveStarterUrlsResolve() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLACK_TEAM_LIVE"] == "1", "live test")
        for model in StarterModels.all {
            var req = URLRequest(url: model.url); req.httpMethod = "HEAD"
            let (_, response) = try await URLSession.shared.data(for: req)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200, model.id)
            XCTAssertEqual(http.expectedContentLength, model.bytes, model.id)
        }
    }
}
