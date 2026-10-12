import Foundation

// A deliberately small HTTP/1.1 reader and writer for the phone server. It accepts only what the web app
// and Tailscale Serve send, and refuses everything else. One request per connection (`Connection: close`).

struct HTTPFailure: Error {
    var status: Int
    var message: String
    init(_ message: String, _ status: Int = 400) { self.message = message; self.status = status }
}

struct HTTPHead {
    var method: String
    var target: String
    /// The path as sent: percent-escapes are not decoded and dot segments are not resolved.
    var path: String
    var query: [(name: String, value: String)]
    /// Header names in lower case. A repeated header that carries a decision is refused while parsing.
    var headers: [String: String]
    var contentLength: Int

    func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
}

enum HTTPLimits {
    static let headBytes = 16 * 1024
    static let targetBytes = 8192
    static let headerCount = 100
    /// The largest body any route reads (memory notes); other routes read 64 KiB.
    static let bodyBytes = 900 * 1024
}

enum HTTPParser {
    private static let tokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    /// Headers whose repeat could change who a request appears to come from or what it contains.
    private static let single: Set<String> = ["host", "origin", "content-length", "content-type", "cookie", "tailscale-user-login", "authorization", "transfer-encoding"]

    /// Finds the end of the header block, or nil when more bytes are needed. Throws once it is clearly too long.
    static func headEnd(in data: Data) throws -> Int? {
        let marker: [UInt8] = [13, 10, 13, 10]
        let bytes = [UInt8](data.prefix(HTTPLimits.headBytes + 4))
        if bytes.count >= 4 {
            for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
                if index > HTTPLimits.headBytes { break }
                return index + marker.count
            }
        }
        if data.count > HTTPLimits.headBytes { throw HTTPFailure("Request headers are too large.", 431) }
        return nil
    }

    /// `block` is the header block without the blank line that ends it.
    static func parseHead(_ block: Data) throws -> HTTPHead {
        let bad = HTTPFailure("Malformed request.")
        guard block.count <= HTTPLimits.headBytes + 4 else { throw HTTPFailure("Request headers are too large.", 431) }
        for byte in block where byte == 0 || (byte < 0x20 && byte != 13 && byte != 10 && byte != 9) || byte == 0x7f { throw bad }
        guard let text = String(data: block, encoding: .utf8) else { throw bad }
        // Every line ends with CRLF; a bare CR or LF is refused.
        var lines = text.components(separatedBy: "\r\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines where line.contains("\r") || line.contains("\n") { throw bad }
        guard let requestLine = lines.first, !requestLine.isEmpty else { throw bad }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw bad }
        let method = parts[0], target = parts[1], version = parts[2]
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else { throw bad }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw HTTPFailure("HTTP version not supported.", 505) }
        guard ["GET", "HEAD", "POST"].contains(method) else { throw HTTPFailure("Method not allowed.", 405) }
        guard target.hasPrefix("/"), target.utf8.count <= HTTPLimits.targetBytes, !target.contains("#"),
              target.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { throw HTTPFailure("Invalid URL.") }
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count > 1 ? parseQuery(String(split[1])) : []

        var headers: [String: String] = [:]
        guard lines.count - 1 <= HTTPLimits.headerCount else { throw HTTPFailure("Too many headers.", 431) }
        for line in lines.dropFirst() {
            // Folded header lines are obsolete and a classic smuggling tool.
            guard let first = line.utf8.first, first != 32, first != 9, let colon = line.firstIndex(of: ":") else { throw bad }
            let name = String(line[..<colon])
            guard !name.isEmpty, name.utf8.allSatisfy({ tokenCharacters.contains($0) }) else { throw bad }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let key = name.lowercased()
            if let existing = headers[key] {
                if single.contains(key) { throw HTTPFailure("Repeated header.") }
                headers[key] = existing + ", " + value
            } else { headers[key] = value }
        }
        if headers["transfer-encoding"] != nil { throw HTTPFailure("Chunked and encoded request bodies are not supported.", 501) }
        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.count <= 10, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = Int(raw) else { throw bad }
            length = number
        }
        if method != "POST" && length > 0 { throw HTTPFailure("This request must not have a body.") }
        if method == "POST" && headers["content-length"] == nil { throw HTTPFailure("A Content-Length is required.", 411) }
        return HTTPHead(method: method, target: target, path: path, query: query, headers: headers, contentLength: length)
    }

    /// `URLSearchParams`: `+` is a space and escapes are decoded.
    static func parseQuery(_ text: String) -> [(name: String, value: String)] {
        func decode(_ piece: Substring) -> String {
            let spaced = piece.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        return text.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(halves[0]), halves.count > 1 ? decode(halves[1]) : "")
        }
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    mutating func set(_ name: String, _ value: String) {
        headers.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
        headers.append((name, value))
    }

    static func json(_ status: Int, _ value: JSONValue) -> HTTPResponse {
        var response = HTTPResponse(status: status, body: Data(value.text().utf8))
        response.set("Content-Type", "application/json; charset=utf-8")
        return response
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse { json(status, ["error": .string(message)]) }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return status < 500 ? "Error" : "Internal Server Error"
        }
    }

    /// The bytes to send. A HEAD response has the headers of the GET, with its length, and no body.
    func serialized(head: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers where name.lowercased() != "content-length" && name.lowercased() != "connection" {
            // A header value can never carry a line break, so a bad name or value cannot split the response.
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            text += "\(name): \(clean)\r\n"
        }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(text.utf8)
        if !head { data.append(body) }
        return data
    }
}
