import XCTest
@testable import BlackTeamKit

/// Every tool call is checked against that tool's JSON schema before it runs; a mismatch is an observation, never a crash.
final class ToolValidationTests: XCTestCase {
    var scratch = ""
    override func setUpWithError() throws {
        scratch = try XCTUnwrap(PathUtil.realpath(NSTemporaryDirectory())) + "/bt-validate-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: scratch + "/ws", withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: scratch) }

    func tools() throws -> Tools {
        try Tools(workspace: scratch + "/ws", artifacts: scratch + "/art", undoDir: scratch + "/undo", home: scratch, useRtk: false)
    }

    func refusal(_ name: String, _ args: JSONValue) async throws -> String {
        let result = try await tools().call(name, args)
        XCTAssertTrue(result.error)
        return result.output
    }

    func testARequiredArgumentThatIsMissingOrNullIsNamed() async throws {
        let expected = "Error: argument `path` is required. Call read again with corrected arguments."
        let missing = try await refusal("read", [:])
        let empty = try await refusal("read", ["path": .null])
        XCTAssertEqual(missing, expected)
        XCTAssertEqual(empty, expected)
        let both = try await refusal("edit", ["new": "x"])
        XCTAssertEqual(both, "Error: argument `path` is required; argument `old` is required. Call edit again with corrected arguments.")
    }

    func testTypesAreExact() async throws {
        var out = try await refusal("read", ["path": "a.txt", "lines": "ten"])
        XCTAssertEqual(out, "Error: argument `lines` must be a whole number. Call read again with corrected arguments.")
        out = try await refusal("read", ["path": "a.txt", "start": 1.5])
        assertMatch(out, "argument `start` must be a whole number")
        out = try await refusal("read", ["path": 7])
        assertMatch(out, "argument `path` must be text")
        out = try await refusal("run", ["command": "ls", "timeout": true])
        assertMatch(out, "argument `timeout` must be a whole number")
        out = try await refusal("map", ["question": "x", "refresh": "yes"])
        assertMatch(out, "argument `refresh` must be true or false")
        out = try await refusal("todo", ["items": "x"])
        assertMatch(out, "argument `items` must be a list")
        out = try await refusal("todo", ["items": [["text": "a", "done": "yes"]]])
        assertMatch(out, "argument `items\\[1\\]\\.done` must be true or false")
        out = try await refusal("todo", ["items": [["done": true]]])
        assertMatch(out, "argument `items\\[1\\]\\.text` is required")
        out = try await refusal("todo", ["items": ["not an object"]])
        assertMatch(out, "argument `items\\[1\\]` must be an object")
    }

    func testAFieldTheToolDoesNotTakeIsNamedWithWhatItDoesTake() async throws {
        let out = try await refusal("read", ["path": "a.txt", "file": "b"])
        XCTAssertEqual(out, "Error: `file` is not an argument of read (it takes: lines, path, start). Call read again with corrected arguments.")
        let nested = try await refusal("todo", ["items": [["text": "a", "owner": "me"]]])
        assertMatch(nested, "`items\\[1\\]\\.owner` is not a field here \\(allowed: done, text\\)")
    }

    func testLengthLimitsFromTheSchemas() async throws {
        var out = try await refusal("run", ["command": .string(String(repeating: "x", count: 4001))])
        assertMatch(out, "argument `command` is too long \\(4,001 characters; the most allowed is 4,000\\)")
        out = try await refusal("run", ["command": ""])
        assertMatch(out, "argument `command` must not be empty")
        out = try await refusal("edit", ["path": "a", "old": "", "new": "b"])
        assertMatch(out, "argument `old` must not be empty")
        out = try await refusal("write", ["path": "a", "content": .string(String(repeating: "x", count: 400_001))])
        assertMatch(out, "argument `content` is too long")
        out = try await refusal("todo", ["items": .array(Array(repeating: ["text": "x"] as JSONValue, count: 41))])
        assertMatch(out, "argument `items` has too many items \\(41; the most allowed is 40\\)")
    }

    func testEnumsAndPatternsAreChecked() {
        let schemas = SkillTools.schemas
        XCTAssertEqual(ToolArguments.refusal("save_skill", ["name": "ok", "description": "d", "body": "b", "where": "elsewhere"], in: schemas),
                       "Error: argument `where` must be one of: mine, project. Call save_skill again with corrected arguments.")
        assertMatch(ToolArguments.refusal("save_skill", ["name": "Bad Name", "description": "d", "body": "b"], in: schemas) ?? "", "argument `name` is not in the right form")
        XCTAssertNil(ToolArguments.refusal("save_skill", ["name": "good-name", "description": "d", "body": "b", "where": "project"], in: schemas))
        XCTAssertNil(ToolArguments.refusal("not-a-tool", [:], in: schemas))
    }

    func testNumberRangesWhenASchemaStatesThem() {
        let schema: JSONValue = ["type": "function", "function": ["name": "pick", "parameters": ["type": "object", "properties": ["count": ["type": "integer", "minimum": 1, "maximum": 5]], "required": ["count"]]]]
        XCTAssertEqual(ToolArguments.refusal("pick", ["count": 0], schema: schema), "Error: argument `count` must be at least 1. Call pick again with corrected arguments.")
        XCTAssertEqual(ToolArguments.refusal("pick", ["count": 9], schema: schema), "Error: argument `count` must be at most 5. Call pick again with corrected arguments.")
        XCTAssertNil(ToolArguments.refusal("pick", ["count": 3], schema: schema))
    }

    func testArgumentsThatAreNotAnObjectAreRefusedNotACrash() async throws {
        let list = try await tools().call("read", .array([]))
        XCTAssertEqual(list.output, "Error: the arguments must be a JSON object. Call read again with corrected arguments.")
        let text = try await tools().call("list", "x")
        XCTAssertTrue(text.error)
    }

    func testValidCallsStillRunAndOptionalNullsAreIgnored() async throws {
        try "one\n".write(toFile: scratch + "/ws/a.txt", atomically: false, encoding: .utf8)
        let result = try await tools().call("read", ["path": "a.txt", "start": .null, "lines": 1])
        XCTAssertFalse(result.error)
        assertMatch(result.output, "^1\\|one")
    }

    func testRunResultsAlwaysStartWithTheExitStatusThenTheOutput() async throws {
        let t = try tools()
        var result = await t.call("run", ["command": "echo out; echo err 1>&2; exit 3"])
        XCTAssertTrue(result.error)
        assertMatch(result.output, "^exit 3\\n")
        XCTAssertTrue(result.output.contains("out") && result.output.contains("err"))
        result = await t.call("run", ["command": "true"])
        XCTAssertEqual(result.output, "exit 0\n(no output)")
        XCTAssertFalse(result.error)
        result = await t.call("run", ["command": "sleep 5", "timeout": 1])
        assertMatch(result.output, "^timed out after 1s\\n")
    }

    func assertMatch(_ text: String, _ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), "\(text.debugDescription) !~ \(pattern)", file: file, line: line)
    }
}
