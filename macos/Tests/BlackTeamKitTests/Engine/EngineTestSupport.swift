import XCTest
@testable import BlackTeamKit

/// One scripted completion of the fake model.
struct Step {
    var text: String?
    var calls: [(String, JSONValue)] = []
    var prompt = 500
    var speed = 40.0
    var status: Int?
    var message = ""
    init(text: String? = nil, calls: [(String, JSONValue)] = [], prompt: Int = 500, speed: Double = 40, status: Int? = nil, message: String = "") {
        self.text = text; self.calls = calls; self.prompt = prompt; self.speed = speed; self.status = status; self.message = message
    }
}

/// Every request body the engine sent, in order.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [JSONValue] = []
    func add(_ body: JSONValue) { lock.lock(); bodies.append(body); lock.unlock() }
    var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return bodies }
    subscript(index: Int) -> JSONValue { all[index] }
    var count: Int { all.count }
}

func lines(_ rows: [String]) -> HTTPLines {
    HTTPLines { continuation in
        for row in rows { continuation.yield(row) }
        continuation.finish()
    }
}

func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "http://127.0.0.1:5555/v1/chat/completions")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

/// A scripted model: each entry is one streamed completion, as a server-sent-events reply.
func fakeModel(_ script: [Step], seen: Seen = Seen(), hang: Bool = false) -> HTTPStreamFetch {
    let turn = Counter()
    return { request in
        let body = try JSONValue.parse(request.httpBody ?? Data())
        seen.add(body)
        let index = turn.next()
        guard index < script.count else { throw URLError(.badServerResponse) }
        let step = script[index]
        if let status = step.status {
            return (httpResponse(status), lines([JSONValue.object(["error": ["message": .string(step.message)]]).text()]))
        }
        var chunks: [JSONValue] = []
        if let text = step.text { chunks.append(["choices": [["delta": ["content": .string(text)]]]]) }
        for (position, call) in step.calls.enumerated() {
            let arguments: String = call.1.string ?? call.1.text()
            chunks.append(["choices": [["delta": ["tool_calls": [["index": .number(Double(position)), "id": .string("call\(index + 1)\(position)"),
                                                                  "function": ["name": .string(call.0), "arguments": .string(arguments)]]]]]]])
        }
        chunks.append(["choices": [["delta": [:], "finish_reason": step.calls.isEmpty ? "stop" : "tool_calls"]],
                       "usage": ["prompt_tokens": .number(Double(step.prompt)), "completion_tokens": 20],
                       "timings": ["prompt_n": 400, "prompt_per_second": .number(step.speed), "predicted_n": 30, "predicted_per_second": 12]])
        var rows: [String] = []
        for chunk in chunks { rows += ["data: \(chunk.text())", ""] }
        rows += ["data: [DONE]", ""]
        return (httpResponse(), lines(rows))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
}

func assertMatch(_ text: String, _ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), "\(text.debugDescription) !~ \(pattern)", file: file, line: line)
}
