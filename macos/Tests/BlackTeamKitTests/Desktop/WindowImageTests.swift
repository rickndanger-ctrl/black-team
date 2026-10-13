import XCTest
@testable import BlackTeamKit

// Picture attachments through the desktop window's routes. The phone's web app has no image support: it is refused, and a conversation
// reaches it without picture references, as on the Mac.
final class WindowImageTests: XCTestCase {
    func upload(_ r: WindowRig, _ bytes: Data = tinyPNG, name: String = "pic.png", phone: Bool = false) async -> WindowAnswer {
        await r.http("POST", "/api/image?name=\(name)", raw: bytes, contentType: "image/png", phone: phone)
    }

    func testAttachingAPictureSendingItAndReadingItBack() async throws {
        let r = try await WindowRig(self, images: true)
        let up = await upload(r)
        XCTAssertEqual(up.status, 200, up.text)
        XCTAssertEqual(up["name"]?.string, "pic.png"); XCTAssertEqual(up["width"]?.int, 1); XCTAssertEqual(up["height"]?.int, 1)
        XCTAssertGreaterThan(up["bytes"]?.int ?? 0, 0)
        let id = try XCTUnwrap(up["id"]?.string)
        let sent = await r.chat("what is this", ["images": [.string(id)]])
        XCTAssertEqual(sent.status, 202, sent.text)
        let threadId = try XCTUnwrap(sent["threadId"]?.string)
        // The conversation keeps a reference, never the picture; the model got the picture as a data URL.
        let view = await r.desktop("GET", "/api/thread/\(threadId)")
        let ref = try XCTUnwrap(view["messages"]?[0]?["images"]?[0])
        XCTAssertEqual(ref["name"]?.string, "pic.png"); XCTAssertEqual(ref["width"]?.int, 1)
        XCTAssertFalse(r.thread(threadId).text().contains("base64"))
        XCTAssertTrue(r.requestText.contains("data:image/"))
        // The file is private, and what is served is that file (a PNG is kept as it is on Linux; the Mac re-encodes pictures as JPEG).
        let folder = r.fixture.stateDir + "/attachments/\(threadId)"
        let stored = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: folder).first { $0.hasPrefix(ref["id"]?.string ?? "-") })
        XCTAssertEqual(mode(folder + "/" + stored), 0o600); XCTAssertEqual(mode(folder), 0o700)
        let image = await r.bytes("/api/image/\(threadId)/\(ref["id"]?.string ?? "")")
        XCTAssertEqual(image.status, 200); XCTAssertTrue(image.type.hasPrefix("image/"))
        XCTAssertEqual(image.data, try Data(contentsOf: URL(fileURLWithPath: folder + "/" + stored)))
        // The staged copy is gone once sent.
        let again = await r.chat("again", ["images": [.string(id)]], wait: false)
        XCTAssertEqual(again.status, 400); XCTAssertEqual(again.error, "That picture is no longer attached. Attach it again.")
        // An empty message with a picture asks for a description, as on the Mac.
        let second = await upload(r)
        let bare = await r.chat("", ["images": [second["id"] ?? .null], "threadId": .string(threadId)])
        XCTAssertEqual(bare.status, 202, bare.text)
        XCTAssertEqual(r.thread(threadId)["messages"]?.array?.dropFirst(2).first?["content"]?.string, "Describe these images.")
        let missing = await r.bytes("/api/image/\(threadId)/\(newID())")
        XCTAssertEqual(missing.status, 404)
        let badPath = await r.bytes("/api/image/../../config.json")
        XCTAssertEqual(badPath.status, 404)
    }

    func testPicturesGoToACloudServiceOnlyWithTheConversationAndAreNamedInTheNotice() async throws {
        let r = try await WindowRig(self, images: true)
        try await r.addCloud()
        let check = await r.desktop("GET", "/api/privacy")
        XCTAssertEqual(check["willLeave"]?.array?.compactMap { $0.string }, ["your messages, and any pictures you attach"])
        let up = await upload(r)
        let sent = await r.chat("what is this", ["images": [up["id"] ?? .null]])
        XCTAssertEqual(sent.status, 202, sent.text)
        let cloud = r.requests.list.filter { $0.url?.host == r.host }
        XCTAssertEqual(cloud.count, 1)
        XCTAssertTrue(String(decoding: cloud[0].httpBody ?? Data(), as: UTF8.self).contains("data:image/"))
        XCTAssertFalse(r.requestText.contains("Vault-Secret"))
    }

    func testBadPicturesAreRefusedInTheMacsWords() async throws {
        let r = try await WindowRig(self, images: true)
        let empty = await r.http("POST", "/api/image?name=a.png", raw: Data(), contentType: "image/png")
        XCTAssertEqual(empty.status, 400); XCTAssertEqual(empty.error, ImageRules.badDataMessage)
        let text = await upload(r, Data("not a picture".utf8), name: "a.txt")
        XCTAssertEqual(text.status, 400); XCTAssertEqual(text.error, ImagePreparer.notAnImage)
        let huge = await upload(r, Data(count: ImageRules.maxSourceBytes + 2048))
        XCTAssertEqual(huge.status, 413); XCTAssertEqual(huge.error, "Request is too large.")
        var ids: [JSONValue] = []
        for _ in 0..<5 { ids.append(await upload(r)["id"] ?? .null) }
        let many = await r.chat("five", ["images": .array(ids)], wait: false)
        XCTAssertEqual(many.status, 400); XCTAssertEqual(many.error, ImageRules.tooManyMessage)
        let odd = await r.chat("odd", ["images": [5]], wait: false)
        XCTAssertEqual(odd.status, 400); XCTAssertEqual(odd.error, ImageRules.invalidAttachment)
        let discard = await r.desktop("POST", "/api/image/discard", ["ids": .array(ids)])
        XCTAssertEqual(discard["discarded"]?.bool, true)
        let gone = await r.chat("gone", ["images": [ids[0]]], wait: false)
        XCTAssertEqual(gone.error, "That picture is no longer attached. Attach it again.")
        XCTAssertEqual(r.backend.threads().count, 0, "a refused message leaves nothing behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.fixture.stateDir + "/attachments"))
    }

    func testAPhoneCannotAttachOrSeePictures() async throws {
        let r = try await WindowRig(self, images: true)
        let up = await upload(r)
        let sent = await r.chat("what is this", ["images": [up["id"] ?? .null]])
        let threadId = try XCTUnwrap(sent["threadId"]?.string)
        let ref = try XCTUnwrap(r.thread(threadId)["messages"]?[0]?["images"]?[0]?["id"]?.string)
        let before = r.requests.count
        // Upload, read and send with a picture: all refused, with nothing read of the body.
        let phoneUp = await upload(r, phone: true)
        XCTAssertEqual(phoneUp.status, 403); XCTAssertEqual(phoneUp.error, DesktopRefusal.pictures)
        let phoneHuge = await r.http("POST", "/api/image?name=a.png", raw: Data(count: ImageRules.maxSourceBytes + 2048), contentType: "image/png", phone: true)
        XCTAssertEqual(phoneHuge.status, 403)
        let read = await r.bytes("/api/image/\(threadId)/\(ref)", phone: true)
        XCTAssertEqual(read.status, 403)
        let send = await r.chat("hi", ["images": [up["id"] ?? .null], "threadId": .string(threadId)], phone: true, wait: false)
        XCTAssertEqual(send.status, 403); XCTAssertEqual(send.error, DesktopRefusal.pictures)
        XCTAssertEqual(r.requests.count, before)
        // The phone's view of the conversation has the text and no picture references.
        let view = await r.phone("GET", "/api/thread/\(threadId)")
        XCTAssertEqual(view.status, 200)
        XCTAssertNil(view["messages"]?[0]?["images"]); XCTAssertEqual(view["messages"]?[0]?["content"]?.string, "what is this")
        XCTAssertFalse(view.text.contains(ref))
    }
}
