import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// How Claude Code and Codex reach the room's tools during a driven run.
//
//   agent  --stdio-->  `black-team mcp-room --run <file>`  --unix socket + secret-->  the running Black Team (RoomBridge, below)
//
// The agent is launched with an MCP server for that one launch only (AgentTools.arguments); its own configuration files are not touched.
// The server is this program with a subcommand. It talks to the running engine over a socket that exists only while the run does:
// a file in a private folder (owner only), no network port, and the first line carries a secret made for this run. Nothing else listens.

/// A Model Context Protocol server over lines of JSON (the stdio transport): initialize, ping, tools/list and tools/call.
public final class RoomMCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    private let call: @Sendable (String, JSONValue) async -> RoomToolReply

    public init(call: @escaping @Sendable (String, JSONValue) async -> RoomToolReply) { self.call = call }

    private func result(_ id: JSONValue, _ value: JSONValue) -> String { JSONValue.object(["jsonrpc": "2.0", "id": id, "result": value]).text() }
    private func failure(_ id: JSONValue, _ code: Int, _ message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]).text()
    }

    /// The reply line to one request line, or nil when it needs none (a notification).
    public func handle(_ line: String) async -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let request = try? JSONValue.parse(Data(text.utf8)), request.object != nil else { return failure(.null, -32700, "Parse error") }
        guard let method = request["method"]?.string else { return request["id"] == nil ? nil : failure(request["id"] ?? .null, -32600, "Invalid request") }
        // A notification has no id and gets no answer.
        guard let id = request["id"] else { return nil }
        switch method {
        case "initialize":
            let wanted = request["params"]?["protocolVersion"]?.string ?? Self.protocolVersion
            return result(id, ["protocolVersion": .string(wanted), "capabilities": ["tools": [:]],
                               "serverInfo": ["name": "black-team-room", "version": "1"]])
        case "ping": return result(id, [:])
        case "tools/list": return result(id, ["tools": .array(RoomTools.mcpTools)])
        case "tools/call":
            guard let name = request["params"]?["name"]?.string else { return failure(id, -32602, "A tool name is required.") }
            guard RoomTools.names.contains(name) else {
                return result(id, ["content": [["type": "text", "text": .string("Unknown tool \(name). Tools: team, delegate.")]], "isError": true])
            }
            let reply = await call(name, request["params"]?["arguments"] ?? [:])
            return result(id, ["content": [["type": "text", "text": .string(reply.text)]], "isError": .bool(reply.isError)])
        default: return failure(id, -32601, "Method not found: \(method)")
        }
    }

    /// Answers every line of `lines` until it ends, several at once (an agent may call two tools together), then returns.
    public func serve(lines: AsyncStream<String>, write: @escaping @Sendable (String) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                group.addTask { if let answer = await self.handle(line) { write(answer) } }
            }
        }
    }

    /// Lines read from a file handle (standard input, or a pipe in a test), on a thread of their own.
    public static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let at = buffer.firstIndex(of: 0x0A) {
                        continuation.yield(String(decoding: buffer[buffer.startIndex..<at], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...at)
                    }
                }
                if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                continuation.finish()
            }
            thread.name = "black-team.mcp-room.input"
            thread.start()
        }
    }

    /// `black-team mcp-room --run <file>`: the server on standard input and output, its tools answered by the running Black Team.
    public static func runStdio(runFile: String, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let server = RoomMCPServer { name, arguments in await RoomBridgeClient.call(runFile: runFile, tool: name, arguments: arguments) }
        let lock = NSLock()
        await server.serve(lines: lines(from: input)) { line in
            lock.lock(); output.write(Data((line + "\n").utf8)); lock.unlock()
        }
    }
}

// MARK: The channel

enum BridgeSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        #if !os(Linux)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// Bytes up to the first newline (not included), or nil at the end of the stream or past `limit`. `seconds` bounds each wait.
    static func readLine(_ fd: Int32, limit: Int, seconds: Int32?) -> Data? {
        var out = Data()
        var byte: UInt8 = 0
        while out.count <= limit {
            if let seconds {
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&item, 1, seconds * 1000) <= 0 { return nil }
            }
            let n = read(fd, &byte, 1)
            if n <= 0 { return out.isEmpty ? nil : out }
            if byte == 0x0A { return out }
            out.append(byte)
        }
        return nil
    }

    static func samePerson(_ fd: Int32) -> Bool {
        #if os(Linux)
        // The socket file is in a private folder and mode 0600, so only this person's programs can reach it at all.
        return true
        #else
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
        #endif
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = x.count ^ y.count
        for i in 0..<min(x.count, y.count) { difference |= Int(x[i] ^ y[i]) }
        return difference == 0
    }
}

/// The listening end, inside the running Black Team, for one driven run.
final class RoomBridge: @unchecked Sendable {
    let program: String
    let runFile: String
    private let socketPath: String
    private let secret: String
    private let host: RoomToolHost
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var folders: [String] = []
    private var stopped = false

    private init(program: String, runFile: String, socketPath: String, secret: String, host: RoomToolHost, folders: [String]) {
        self.program = program; self.runFile = runFile; self.socketPath = socketPath; self.secret = secret; self.host = host; self.folders = folders
    }

    /// The program that provides `mcp-room`: `black-team` beside the running program (the Mac app holds its command next to the app), else this program.
    static func defaultProgram() -> String {
        #if os(Linux)
        let running = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
        #else
        let running = Bundle.main.executablePath ?? CommandLine.arguments[0]
        #endif
        let folder = (running as NSString).deletingLastPathComponent
        let sibling = folder + "/black-team"
        if (running as NSString).lastPathComponent != "black-team", access(sibling, X_OK) == 0 { return sibling }
        return running
    }

    static func start(dataFolder: String, host: RoomToolHost, program: String) throws -> RoomBridge {
        signal(SIGPIPE, SIG_IGN)
        let folder = dataFolder + "/room-runs"
        try privateDirectory(folder)
        let id = EText.hex(8)
        var socketFolder = folder
        var socketPath = folder + "/" + id + ".sock"
        var made: [String] = []
        // A socket path is limited to about a hundred bytes; a long data folder uses a short private folder in the temporary directory instead.
        if BridgeSocket.address(socketPath) == nil || socketPath.utf8.count > 100 {
            socketFolder = NSTemporaryDirectory() + "bt-" + id
            try privateDirectory(socketFolder)
            made.append(socketFolder)
            socketPath = socketFolder + "/r.sock"
        }
        guard var address = BridgeSocket.address(socketPath) else { throw BlackTeamError("Black Team could not open a private channel for this run.") }
        #if os(Linux)
        let fd = socket(AF_UNIX, posixSockStream, 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw BlackTeamError("Black Team could not open a private channel for this run.") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd); unlink(socketPath); made.forEach { try? FileManager.default.removeItem(atPath: $0) }
            throw BlackTeamError("Black Team could not open a private channel for this run.")
        }
        let secret = EText.hex(32)
        let runFile = folder + "/" + id + ".json"
        try writeJSON(runFile, JSONValue.object(["socket": .string(socketPath), "secret": .string(secret)]))
        let bridge = RoomBridge(program: program, runFile: runFile, socketPath: socketPath, secret: secret, host: host, folders: made)
        bridge.lock.lock(); bridge.listener = fd; bridge.lock.unlock()
        let thread = Thread { bridge.acceptLoop(fd) }
        thread.name = "black-team.room-bridge"
        thread.start()
        return bridge
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&item, 1, 200) <= 0 { continue }
            let connection = accept(fd, nil, nil)
            if connection < 0 { continue }
            let thread = Thread { [self] in serve(connection) }
            thread.name = "black-team.room-bridge.call"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        func answer(_ reply: RoomToolReply) { BridgeSocket.writeAll(fd, Data((JSONValue.object(["text": .string(reply.text), "error": .bool(reply.isError)]).text() + "\n").utf8)) }
        guard BridgeSocket.samePerson(fd), let line = BridgeSocket.readLine(fd, limit: 1_048_576, seconds: 10),
              let request = try? JSONValue.parse(line), let given = request["secret"]?.string, BridgeSocket.same(given, secret) else {
            answer(RoomToolReply("Not allowed.", isError: true)); return
        }
        guard let tool = request["tool"]?.string, RoomTools.names.contains(tool) else { answer(RoomToolReply("Unknown tool.", isError: true)); return }
        let done = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        Task { [host] in box.value = await host.callTool(tool, request["arguments"] ?? [:]); done.signal() }
        done.wait()
        answer(box.value)
    }

    /// Closes the socket and deletes the run's files. A call that arrives afterwards finds nothing.
    func stop() {
        lock.lock(); stopped = true; let fd = listener; listener = -1; lock.unlock()
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
        unlink(socketPath)
        try? FileManager.default.removeItem(atPath: runFile)
        folders.forEach { try? FileManager.default.removeItem(atPath: $0) }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = RoomToolReply("No answer.", isError: true)
    var value: RoomToolReply { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

/// The calling end, inside `black-team mcp-room`.
enum RoomBridgeClient {
    static func call(runFile: String, tool: String, arguments: JSONValue) async -> RoomToolReply {
        await withCheckedContinuation { (continuation: CheckedContinuation<RoomToolReply, Never>) in
            let thread = Thread { continuation.resume(returning: exchange(runFile: runFile, tool: tool, arguments: arguments)) }
            thread.start()
        }
    }

    private static func exchange(runFile: String, tool: String, arguments: JSONValue) -> RoomToolReply {
        let gone = RoomToolReply("The room is no longer running, so this tool cannot be used. Finish your answer without it.", isError: true)
        guard let data = FileManager.default.contents(atPath: runFile), let file = try? JSONValue.parse(data), let path = file["socket"]?.string,
              let secret = file["secret"]?.string, var address = BridgeSocket.address(path) else { return gone }
        #if os(Linux)
        let fd = socket(AF_UNIX, posixSockStream, 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return gone }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { return gone }
        BridgeSocket.writeAll(fd, Data((JSONValue.object(["secret": .string(secret), "tool": .string(tool), "arguments": arguments]).text() + "\n").utf8))
        // A delegation can take many minutes: wait for the answer as long as the connection stays open.
        guard let line = BridgeSocket.readLine(fd, limit: 4_000_000, seconds: nil), let reply = try? JSONValue.parse(line), let text = reply["text"]?.string else { return gone }
        return RoomToolReply(text, isError: reply["error"]?.bool == true)
    }
}
