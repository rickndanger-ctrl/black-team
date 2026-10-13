import XCTest
@testable import BlackTeamKit

final class ImageBackendTests: XCTestCase {
    func jpeg(_ name: String = "red.jpg", width: Int = 64, height: Int = 48) -> ImageUpload { ImageUpload(name: name, data: TestImage.jpeg(width: width, height: height)) }

    /// A backend whose model has a vision projector (a file that passes the GGUF check).
    func visionFixture(server: Bool = false) throws -> BackendFixture {
        let fixture = try BackendFixture(self, server: server)
        if !server {
            let projector = fixture.files.dir + "/mmproj-test.gguf"
            FileManager.default.createFile(atPath: projector, contents: try Data(contentsOf: URL(fileURLWithPath: fixture.files.model)))
            try fixture.rewriteConfig { $0.model.mmproj = projector }
        }
        return fixture
    }

    func attachmentFiles(_ fixture: BackendFixture) -> [String] {
        let root = fixture.stateDir + "/attachments"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return folders.flatMap { folder in ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? []).map { folder + "/" + $0 } }
    }

    func testAMessageWithImagesIsSentAsTextThenImagePartsAndStoredByReference() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let image = jpeg()
        let sent = try backend.submit(message: "What colour is this?", requestId: newID(), images: [image])
        await backend.waitForIdle()
        let body = fixture.requests.body(0)
        let user = try XCTUnwrap(body["messages"]?.array?.last)
        XCTAssertEqual(user["role"]?.string, "user")
        XCTAssertNil(user["images"])
        let parts = try XCTUnwrap(user["content"]?.array)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], ["type": "text", "text": "What colour is this?"])
        XCTAssertEqual(parts[1]["type"]?.string, "image_url")
        XCTAssertEqual(parts[1]["image_url"]?["url"]?.string, "data:image/jpeg;base64," + image.data.base64EncodedString())
        // The conversation holds the reference only: no image data, and well under the 5 MiB cap.
        let thread = try XCTUnwrap(backend.history.get(sent.threadId))
        let saved = try XCTUnwrap(thread["messages"]?[0]?["images"]?.array)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(Set(saved[0].object?.keys.map { $0 } ?? []), ["id", "name", "bytes", "width", "height"])
        XCTAssertEqual(saved[0]["width"]?.int, 64)
        let onDisk = try String(contentsOfFile: backend.history.dir + "/" + sent.threadId + ".json", encoding: .utf8)
        XCTAssertFalse(onDisk.contains("base64"))
        XCTAssertFalse(onDisk.contains("data:image"))
        XCTAssertLessThan(onDisk.utf8.count, 5_000)
        let ref = try XCTUnwrap(ImageRef(saved[0]))
        XCTAssertEqual(try backend.image(threadId: sent.threadId, imageId: ref.id).data, image.data)
    }

    func testEarlierImagesAreSentAgainWithEveryLaterTurn() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let first = jpeg("one.jpg"), second = jpeg("two.jpg", width: 32, height: 32)
        let one = try backend.submit(message: "First image", requestId: newID(), images: [first])
        await backend.waitForIdle()
        try backend.submit(message: "And now this one", requestId: newID(), threadId: one.threadId, images: [second])
        await backend.waitForIdle()
        XCTAssertEqual(fixture.requests.count, 2)
        let messages = try XCTUnwrap(fixture.requests.body(1)["messages"]?.array)
        // system, user (first image), assistant, user (second image)
        XCTAssertEqual(messages.map { $0["role"]?.string }, ["system", "user", "assistant", "user"])
        let urls = messages.compactMap { $0["content"]?.array }.flatMap { $0 }.compactMap { $0["image_url"]?["url"]?.string }
        XCTAssertEqual(urls, ["data:image/jpeg;base64," + first.data.base64EncodedString(), "data:image/jpeg;base64," + second.data.base64EncodedString()])
        XCTAssertEqual(messages[2]["content"]?.string, "Private \u{1F5A4} caf\u{00E9}")
    }

    func testAMessageWithoutImagesStaysPlainText() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        try backend.submit(message: "just text", requestId: newID())
        await backend.waitForIdle()
        XCTAssertEqual(fixture.requests.body(0)["messages"]?.array?.last?["content"]?.string, "just text")
    }

    func testAnEmptyMessageWithImagesBecomesDescribeTheseImages() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let sent = try backend.submit(message: "   ", requestId: newID(), images: [jpeg()])
        await backend.waitForIdle()
        XCTAssertEqual(backend.history.get(sent.threadId)?["messages"]?[0]?["content"]?.string, "Describe these images.")
        XCTAssertThrowsError(try backend.submit(message: "  ", requestId: newID()))
    }

    func testCodeRefusesImagesWithTheDailyMessage() throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        XCTAssertThrowsError(try backend.submit(message: "look", kind: "agent", requestId: newID(), images: [jpeg()])) {
            XCTAssertEqual($0 as? BlackTeamError, BlackTeamError("Use Chat mode to send images in this local test."))
        }
        XCTAssertEqual(attachmentFiles(fixture), [])
        XCTAssertEqual(backend.threads().count, 0)
    }

    func testRefusedSubmitsLeaveNoFilesBehind() throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let five = (0..<5).map { jpeg("\($0).jpg") }
        XCTAssertThrowsError(try backend.submit(message: "x", requestId: newID(), images: five)) { XCTAssertEqual(messageOf($0), "Choose up to 4 images.") }
        XCTAssertThrowsError(try backend.submit(message: "x", requestId: newID(), images: [ImageUpload(name: "bad", data: Data("junk".utf8))]))
        XCTAssertThrowsError(try backend.submit(message: "x", mode: "nonsense", requestId: newID(), images: [jpeg()]))
        XCTAssertThrowsError(try backend.submit(message: "x", requestId: newID(), threadId: newID(), images: [jpeg()]))
        XCTAssertEqual(attachmentFiles(fixture), [])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: fixture.stateDir + "/attachments")) ?? [], [])
    }

    func testTheImagesArePartOfTheRequestFingerprint() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let id = newID()
        let image = jpeg()
        let sent = try backend.submit(message: "same words", requestId: id, images: [image])
        XCTAssertEqual(try backend.submit(message: "same words", requestId: id, images: [image]), sent)
        XCTAssertThrowsError(try backend.submit(message: "same words", requestId: id, images: [jpeg("other.jpg", width: 10, height: 10)])) {
            XCTAssertEqual($0 as? BlackTeamError, BlackTeamError("Request ID was already used for another message."))
        }
        XCTAssertThrowsError(try backend.submit(message: "same words", requestId: id)) {
            XCTAssertEqual($0 as? BlackTeamError, BlackTeamError("Request ID was already used for another message."))
        }
        await backend.waitForIdle()
        XCTAssertEqual(attachmentFiles(fixture).count, 1, "a repeated request stores nothing twice")
    }

    func testAModelWithoutAProjectorIsRefusedBeforeAnythingIsStored() throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        XCTAssertThrowsError(try backend.submit(message: "look", requestId: newID(), images: [jpeg()])) {
            assertMatch(messageOf($0), "vision-capable model and its matching projector")
        }
        XCTAssertEqual(attachmentFiles(fixture), [])
    }

    func testAServerModelIsTriedWithoutAProjector() async throws {
        let fixture = try visionFixture(server: true)
        let backend = try fixture.make()
        try backend.submit(message: "look", requestId: newID(), images: [jpeg()])
        await backend.waitForIdle()
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testAServerRefusalShowsTheVisionMessage() async throws {
        let fixture = try visionFixture()
        fixture.reply = { _ in sse("{\"error\":\"image input is not supported\"}", status: 500) }
        let backend = try fixture.make()
        let sent = try backend.submit(message: "look", requestId: newID(), images: [jpeg()])
        await backend.waitForIdle()
        let reply = lastMessage(backend, sent.threadId)
        XCTAssertEqual(reply["state"]?.string, "error")
        assertMatch(reply["error"]?.string ?? "", "Image chat needs a vision-capable model and its matching projector loaded")
        assertMatch(reply["error"]?.string ?? "", "500")
    }

    func testAFailedTextOnlyRequestKeepsItsOwnMessage() async throws {
        let fixture = try BackendFixture(self)
        fixture.reply = { _ in sse("", status: 500) }
        let backend = try fixture.make()
        let sent = try backend.submit(message: "hi", requestId: newID())
        await backend.waitForIdle()
        assertMatch(lastMessage(backend, sent.threadId)["error"]?.string ?? "", "Check your model and context settings")
    }

    func testAMissingStoredImageFailsTheTurnPlainly() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let sent = try backend.submit(message: "look", requestId: newID(), images: [jpeg()])
        await backend.waitForIdle()
        for file in attachmentFiles(fixture) { try FileManager.default.removeItem(atPath: fixture.stateDir + "/attachments/" + file) }
        try backend.submit(message: "again", requestId: newID(), threadId: sent.threadId)
        await backend.waitForIdle()
        XCTAssertEqual(lastMessage(backend, sent.threadId)["error"]?.string, "That image is no longer stored.")
    }

    func testThePhoneSeesTheTextOfAnImageMessageWithoutImageReferences() async throws {
        let fixture = try visionFixture()
        let backend = try fixture.make()
        let sent = try backend.submit(message: "a picture", requestId: newID(), images: [jpeg()])
        await backend.waitForIdle()
        let phone = BackendPhone(backend)
        let thread = try XCTUnwrap(phone.thread(sent.threadId))
        let messages = try XCTUnwrap(thread["messages"]?.array)
        XCTAssertEqual(messages[0]["content"]?.string, "a picture")
        XCTAssertTrue(messages.allSatisfy { $0["images"] == nil })
        XCTAssertFalse(thread.text().contains("base64"))
        XCTAssertNotNil(backend.thread(sent.threadId)?["messages"]?[0]?["images"], "the Mac window still has them")
    }

    // MARK: Vision file

    func testVisionStatusLogic() throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        let folder = fixture.stateDir
        func status(_ change: (inout ModelConfig) -> Void) -> VisionStatus {
            var model = ModelConfig(name: "m", file: "/somewhere/else.gguf", runtime: "/r")
            change(&model)
            return backend.visionStatus(model)
        }
        XCTAssertEqual(status { $0.source = "server"; $0.endpoint = "http://127.0.0.1:1/v1"; $0.id = "x" }.canSee, true)
        XCTAssertEqual(status { $0.mmproj = "/p/mmproj.gguf" }, VisionStatus(canSee: true, summary: "Can read images."))
        let small = StarterModels.all[0]
        let needs = status { $0.file = small.destination(in: URL(fileURLWithPath: folder)).path }
        XCTAssertEqual(needs.canSee, false)
        XCTAssertEqual(needs.needsFile, true)
        XCTAssertEqual(needs.bytes, 204_987_232)
        XCTAssertEqual(needs.summary, "Needs its vision file (205 MB).")
        let qwen14 = StarterModels.model(id: "qwen3-14b")!
        XCTAssertEqual(status { $0.file = qwen14.destination(in: URL(fileURLWithPath: folder)).path }, VisionStatus(canSee: false, summary: "No vision file known."))
        XCTAssertEqual(status { _ in }, VisionStatus(canSee: false, summary: "No vision file known."))
        let ornith = StarterModels.model(id: "ornith-1.5-9b")!
        XCTAssertEqual(status { $0.file = ornith.destination(in: URL(fileURLWithPath: folder)).path }.summary, "Needs its vision file (922 MB).")
    }

    func testTheCatalogueHasRealVisionFilesWithDistinctLocalNames() {
        let withVision = StarterModels.all.compactMap(\.vision)
        XCTAssertEqual(StarterModels.all.filter { $0.vision == nil }.map(\.id), ["qwen3-14b"])
        XCTAssertEqual(Set(withVision.map(\.localName)).count, withVision.count)
        for vision in withVision {
            XCTAssertEqual(vision.sha256.count, 64)
            XCTAssertTrue(vision.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertTrue(vision.localName.hasSuffix(".gguf"))
            XCTAssertNotNil(vision.localName.range(of: #"(^|[-_.])mmproj([-_.]|$)"#, options: .regularExpression), "the model finder must recognise it as a projector")
            XCTAssertEqual(vision.url.host, "huggingface.co")
        }
        XCTAssertEqual(StarterModels.model(id: "ornith-1.5-9b")?.vision?.filename, "mmproj-Ornith-1.5-9B-BF16.gguf")
        XCTAssertEqual(StarterModels.model(id: "qwen3.5-4b")?.vision?.filename, "mmproj-F16.gguf")
    }

    func starterFixture() throws -> (BackendFixture, StarterModel, StubDownloader) {
        let fixture = try BackendFixture(self)
        let model = StarterModels.all[0]
        let file = model.destination(in: URL(fileURLWithPath: fixture.stateDir)).path
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: try Data(contentsOf: URL(fileURLWithPath: fixture.files.model)))
        try fixture.rewriteConfig { $0.model.file = file }
        let downloader = StubDownloader()
        fixture.downloader = downloader
        return (fixture, model, downloader)
    }

    func testInstallingTheVisionFileDownloadsItSetsMmprojAndUpdatesTheSavedModel() async throws {
        let (fixture, model, downloader) = try starterFixture()
        let backend = try fixture.make()
        XCTAssertEqual(try backend.visionStatus().needsFile, true)
        let steps = RuntimeBox<[String]>([])
        let result = try await backend.installVision { _ in steps.update { $0.append("step") } }
        _ = result
        XCTAssertEqual(downloader.requests.count, 1)
        let request = downloader.requests[0]
        let vision = try XCTUnwrap(model.vision)
        XCTAssertEqual(request.url, vision.url)
        XCTAssertEqual(request.expectedSHA256, vision.sha256)
        XCTAssertEqual(request.expectedSize, vision.bytes)
        XCTAssertEqual(request.destination.lastPathComponent, "Qwen3.5-0.8B-mmproj-F16.gguf")
        XCTAssertEqual(result.restarted, false)
        let config = try fixture.files.store.read()
        XCTAssertEqual(config.model.mmproj, request.destination.path)
        XCTAssertEqual(backend.savedModels.list(active: config.model).first?.key, keyOf(config.model))
        XCTAssertEqual(backend.savedModels.find(keyOf(config.model))?.mmproj, request.destination.path)
        XCTAssertEqual(try backend.visionStatus(), VisionStatus(canSee: true, summary: "Can read images."))
        XCTAssertFalse(steps.value.isEmpty)
        // Already installed: asking again is refused rather than downloading twice.
        do { _ = try await backend.installVision(); XCTFail("should refuse") } catch { XCTAssertEqual(messageOf(error), "This model already has its vision file.") }
        XCTAssertEqual(downloader.requests.count, 1)
    }

    func testAStarterModelTooSmallToThinkAnswersAtOnceWhateverThePace() async throws {
        // The fixture's model is the smallest starter, which is marked as not thinking.
        let (fixture, model, _) = try starterFixture()
        XCTAssertEqual(model.thinks, false)
        XCTAssertEqual(StarterModels.all.filter { !$0.thinks }.map(\.id), ["qwen3.5-0.8b"])
        let backend = try fixture.make()
        _ = try backend.submit(message: "What is 17 plus 25?", mode: "deep", requestId: newID())
        await backend.waitForIdle()
        let body = fixture.requests.body(0)
        XCTAssertEqual(body["reasoning_effort"]?.string, "none")
        XCTAssertEqual(body["chat_template_kwargs"]?["enable_thinking"]?.bool, false)
        XCTAssertNil(body["thinking_budget_tokens"])
        XCTAssertEqual(body["messages"]?[0]?["content"]?.string?.hasPrefix(ChatStream.SYSTEM), true)
    }

    func testTheWindowStartsTheVisionDownloadAndReadsItsProgressFromStatus() async throws {
        let (fixture, _, downloader) = try starterFixture()
        let backend = try fixture.make()
        let control = DesktopControl(backend)
        let before = try await control.handle("status")
        XCTAssertEqual(before["visionInstall"]?["running"]?.bool, false)
        XCTAssertEqual(before["visionInstall"]?["done"]?.bool, false)
        let started = try await control.handle("vision-install")
        XCTAssertEqual(started["started"]?.bool, true)
        var last: JSONValue = .null
        for _ in 0..<200 {
            last = try await control.handle("status")
            if last["visionInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["visionInstall"]?["error"]?.string, "")
        XCTAssertEqual(last["visionInstall"]?["done"]?.bool, true)
        XCTAssertEqual(last["vision"]?["canSee"]?.bool, true, "\(last["vision"] ?? .null) \(last["visionInstall"] ?? .null) \(last["config"]?["model"]?["mmproj"] ?? .null)")
        XCTAssertEqual(downloader.requests.count, 1)
        XCTAssertEqual(try fixture.files.store.read().model.mmproj, downloader.requests[0].destination.path)
        // Asking again: the engine's own refusal arrives as the download's error, in its words.
        _ = try await control.handle("vision-install")
        for _ in 0..<200 {
            last = try await control.handle("status")
            if last["visionInstall"]?["running"]?.bool == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(last["visionInstall"]?["error"]?.string, "This model already has its vision file.")
        XCTAssertEqual(downloader.requests.count, 1)
        // Not for a phone, and no settings are accepted.
        do { _ = try await control.handle("vision-install", nil, access: .phone); XCTFail("a phone must be refused") } catch {}
        do { _ = try await control.handle("vision-install", ["file": "x"]); XCTFail("should refuse") } catch { XCTAssertEqual(messageOf(error), "Unsupported setup setting.") }
        let stopped = try await control.handle("vision-cancel")
        XCTAssertEqual(stopped["stopped"]?.bool, true)
    }

    func testInstallingRestartsARunningModelSoTheProjectorLoads() async throws {
        let (fixture, _, _) = try starterFixture()
        fixture.runtime.state = .ready
        fixture.runtime.stopAction = { [runtime = fixture.runtime] in runtime.state = .off }
        let backend = try fixture.make()
        let result = try await backend.installVision()
        XCTAssertEqual(result.restarted, true)
        XCTAssertEqual(fixture.runtime.stops, [false])
        let restarted = await waitUntil { fixture.runtime.starts == 1 }
        XCTAssertTrue(restarted)
    }

    func testInstallingIsRefusedWhenThereIsNothingToInstallOrAResponseIsRunning() async throws {
        let fixture = try BackendFixture(self)
        let backend = try fixture.make()
        do { _ = try await backend.installVision(); XCTFail("should refuse") } catch { XCTAssertEqual(messageOf(error), "No vision file is known for this model.") }
        let (busyFixture, _, downloader) = try starterFixture()
        let gate = BackendGate()
        busyFixture.runtime.startAction = { await gate.wait(); return "http://127.0.0.1:5555/v1" }
        let busy = try busyFixture.make()
        try busy.submit(message: "busy", requestId: newID())
        do { _ = try await busy.installVision(); XCTFail("should refuse") } catch { assertMatch(messageOf(error), "Wait for the response") }
        XCTAssertEqual(downloader.requests.count, 0)
        await gate.open()
        await busy.waitForIdle()
    }
}

