import XCTest
@testable import BlackTeamKit

final class AgentSnapshotsTests: XCTestCase {
    var base: String!
    var workspace: String { base + "/proj" }
    var data: String { base + "/data" }

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "agent-snap-" + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: workspace + "/sub", withIntermediateDirectories: true)
        try "original greet\n".write(toFile: workspace + "/greet.py", atomically: true, encoding: .utf8)
        try "nested\n".write(toFile: workspace + "/sub/notes.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func id() -> String { UUID().uuidString.lowercased() }

    func testRollBackPutsChangedFilesBackAndRemovesNewOnes() throws {
        let snapshots = AgentSnapshots(dataFolder: data)
        let thread = id(), run = id()
        XCTAssertEqual(try snapshots.take(threadId: thread, runId: run, workspace: workspace), .saved(files: 2))
        // What a task might do: edit a file, create one, and touch a folder that is never archived.
        try "changed by the agent\n".write(toFile: workspace + "/greet.py", atomically: true, encoding: .utf8)
        try "new file\n".write(toFile: workspace + "/added.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: workspace + "/node_modules", withIntermediateDirectories: true)
        try "dependency\n".write(toFile: workspace + "/node_modules/dep.js", atomically: true, encoding: .utf8)

        let restored = try snapshots.restore(threadId: thread, runId: run, workspace: workspace)
        XCTAssertEqual(restored.restored, ["greet.py"])
        XCTAssertEqual(restored.removed, ["added.txt"])
        XCTAssertEqual(try String(contentsOfFile: workspace + "/greet.py", encoding: .utf8), "original greet\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace + "/added.txt"))
        XCTAssertEqual(try String(contentsOfFile: workspace + "/sub/notes.txt", encoding: .utf8), "nested\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/node_modules/dep.js"), "excluded folders are never touched")
    }

    func testTheArchiveIsPrivateAndExcludesRebuiltFolders() throws {
        try FileManager.default.createDirectory(atPath: workspace + "/.git", withIntermediateDirectories: true)
        try "git\n".write(toFile: workspace + "/.git/HEAD", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: workspace + "/build", withIntermediateDirectories: true)
        try "out\n".write(toFile: workspace + "/build/out.bin", atomically: true, encoding: .utf8)
        let snapshots = AgentSnapshots(dataFolder: data)
        let thread = id(), run = id()
        XCTAssertEqual(try snapshots.take(threadId: thread, runId: run, workspace: workspace), .saved(files: 2))
        let archive = data + "/agent-snapshots/" + thread + "/" + run + ".tar"
        let mode = try FileManager.default.attributesOfItem(atPath: archive)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let listing = try runProcess("/usr/bin/tar", ["-tf", archive]).joined(separator: "\n")
        XCTAssertTrue(listing.contains("greet.py"))
        XCTAssertFalse(listing.contains(".git"))
        XCTAssertFalse(listing.contains("build/"))
    }

    func testOnlyTheNewestFiveSnapshotsAreKept() throws {
        let snapshots = AgentSnapshots(dataFolder: data)
        let thread = id()
        var runs: [String] = []
        for _ in 0..<6 {
            let run = id()
            runs.append(run)
            XCTAssertEqual(try snapshots.take(threadId: thread, runId: run, workspace: workspace), .saved(files: 2))
            // Modification dates must differ for the order to be clear.
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(snapshots.exists(threadId: thread, runId: runs[0]))
        for run in runs.dropFirst() { XCTAssertTrue(snapshots.exists(threadId: thread, runId: run)) }
    }

    func testAFolderWithTooManyFilesIsNotArchived() throws {
        for index in 0..<(AgentSnapshots.maxFiles + 1) {
            FileManager.default.createFile(atPath: workspace + "/many-\(index).txt", contents: nil)
        }
        let snapshots = AgentSnapshots(dataFolder: data)
        let run = id()
        guard case .skipped(let reason) = try snapshots.take(threadId: id(), runId: run, workspace: workspace) else {
            return XCTFail("a folder over the file limit must be skipped")
        }
        XCTAssertTrue(reason.contains("20,000"))
        XCTAssertFalse(snapshots.exists(threadId: "", runId: run))
    }

    func testRollBackNeedsASnapshotAndValidIDs() throws {
        let snapshots = AgentSnapshots(dataFolder: data)
        XCTAssertThrowsError(try snapshots.restore(threadId: id(), runId: id(), workspace: workspace))
        XCTAssertThrowsError(try snapshots.take(threadId: "../escape", runId: id(), workspace: workspace))
    }

    func testAnEmptyFolderCanBeSnapshotted() throws {
        let empty = base + "/empty"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let snapshots = AgentSnapshots(dataFolder: data)
        let thread = id(), run = id()
        XCTAssertEqual(try snapshots.take(threadId: thread, runId: run, workspace: empty), .saved(files: 0))
        try "made by the task\n".write(toFile: empty + "/new.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try snapshots.restore(threadId: thread, runId: run, workspace: empty).removed, ["new.txt"])
    }
}

/// Runs a system tool with arguments and returns its standard output lines.
func runProcess(_ program: String, _ arguments: [String]) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: program)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}
