import XCTest
@testable import BlackTeamKit

final class HistoryTests: XCTestCase {
    private func uuid() -> String { UUID().uuidString.lowercased() }

    func testSavesAreAtomicPrivateAndKeepRequestIndex() throws {
        let stateDir = makeTemporaryFolder(self) + "/state"
        let history = try History(stateDir: stateDir)
        var thread = history.create("  A private\n conversation  ")
        XCTAssertEqual(thread["title"]?.string, " A private conversation ")
        let request: JSONValue = ["id": .string(uuid()), "hash": .string(String(repeating: "a", count: 64)), "state": "done"]
        thread = {
            var object = thread.object!
            object["messages"] = [["id": .string(uuid()), "role": "user", "content": "original 🖤", "state": "done"],
                                  ["id": .string(uuid()), "role": "assistant", "content": "completed response", "state": "done"]]
            return .object(object)
        }()
        history.remember(&thread, request)
        try history.save(thread)
        let id = thread["id"]!.string!
        let file = stateDir + "/conversations/" + id + ".json"
        XCTAssertEqual(mode(stateDir), 0o700)
        XCTAssertEqual(mode((file as NSString).deletingLastPathComponent), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: (file as NSString).deletingLastPathComponent), [id + ".json"])
        let read = try History(stateDir: stateDir)
        XCTAssertEqual(read.get(id)?["messages"], thread["messages"])
        XCTAssertEqual(read.request(request["id"]!.string!)?["threadId"]?.string, id)
        XCTAssertEqual(read.request(request["id"]!.string!)?["state"]?.string, "done")
        let summary = try JSONValue.parse(JSONEncoder().encode(read.list()[0]))
        // privacy and provider (a host name, never an address) are how the app says where a conversation may go.
        XCTAssertEqual(Set(summary.object!.keys), ["id", "kind", "title", "updated", "privacy", "provider"])
    }

    func testRestartInterruptsRunningWork() throws {
        let stateDir = makeTemporaryFolder(self) + "/state"
        let original = try History(stateDir: stateDir)
        var thread = original.create("question")
        var object = thread.object!
        object["messages"] = [["id": .string(uuid()), "role": "user", "content": "question", "state": "done"],
                              ["id": .string(uuid()), "role": "assistant", "content": "partial answer", "state": "writing"]]
        thread = .object(object)
        let request: JSONValue = ["id": .string(uuid()), "hash": .string(String(repeating: "a", count: 64)), "state": "running"]
        original.remember(&thread, request)
        try original.save(thread)
        let restarted = try History(stateDir: stateDir)
        let id = thread["id"]!.string!
        XCTAssertEqual(restarted.get(id)?["messages"]?[1]?["content"]?.string, "partial answer")
        XCTAssertEqual(restarted.get(id)?["messages"]?[1]?["state"]?.string, "interrupted")
        XCTAssertEqual(restarted.request(request["id"]!.string!)?["state"]?.string, "interrupted")
        let persisted = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: stateDir + "/conversations/" + id + ".json")))
        XCTAssertEqual(persisted["requests"]?[0]?["state"]?.string, "interrupted")
        XCTAssertEqual(persisted["messages"]?[1]?["state"]?.string, "interrupted")
    }

    func testDamagedMismatchedAndOversizedFilesAreRejectedUntouched() throws {
        let stateDir = makeTemporaryFolder(self) + "/state"
        _ = try History(stateDir: stateDir)
        let id = uuid(), file = stateDir + "/conversations/" + id + ".json"
        let contents = ["{", #"{"id":"\#(uuid())","messages":[]}"#, #"{"id":"\#(id)","messages":"wrong"}"#, String(repeating: "x", count: 8 * 1024 * 1024 + 1)]
        for text in contents {
            try text.write(toFile: file, atomically: false, encoding: .utf8)
            XCTAssertThrowsError(try History(stateDir: stateDir))
            XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), text)
        }
    }

    func testSymlinksAreRejectedAndWritesDoNotFollowThem() throws {
        let directory = makeTemporaryFolder(self), stateDir = directory + "/state"
        let target = directory + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: stateDir, withDestinationPath: target)
        XCTAssertThrowsError(try History(stateDir: stateDir)) { XCTAssertTrue(($0 as! BlackTeamError).message.contains("symbolic link")) }
        try FileManager.default.removeItem(atPath: stateDir)
        let history = try History(stateDir: stateDir)
        let thread = history.create("question")
        let outside = directory + "/outside.json"
        try "preserve outside".write(toFile: outside, atomically: true, encoding: .utf8)
        let file = history.dir + "/" + thread["id"]!.string! + ".json"
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: outside)
        XCTAssertThrowsError(try History(stateDir: stateDir)) { XCTAssertTrue(($0 as! BlackTeamError).message.contains("symbolic links")) }
        try writeJSON(file, ["value": "owned replacement"] as JSONValue)
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "preserve outside")
        XCTAssertFalse(CoreFS.isSymlink(file))
    }

    func testTitleIsCutAt72UnitsAndIDsAreChecked() {
        let history = try! History(stateDir: makeTemporaryFolder(self) + "/state")
        XCTAssertEqual(history.create(String(repeating: "a", count: 100))["title"]?.string?.count, 72)
        XCTAssertTrue(History.validID(UUID().uuidString.lowercased()))
        XCTAssertFalse(History.validID(UUID().uuidString))
        XCTAssertFalse(History.validID(String(repeating: "a", count: 35)))
    }
}
