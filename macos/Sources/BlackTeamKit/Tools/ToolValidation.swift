import Foundation

// Every tool call is checked against that tool's own JSON schema before it runs. A failure is an observation the model can read and
// correct (it counts as a step); it is never a crash and never reaches the tool.

enum ToolArguments {
    /// The observation to give the model when `arguments` do not fit `schema` (a `{type: "function", function: {...}}` entry), or nil.
    static func refusal(_ name: String, _ arguments: JSONValue?, schema: JSONValue) -> String? {
        guard let parameters = schema["function"]?["parameters"] else { return nil }
        let found = problems(name, arguments, parameters)
        if found.isEmpty { return nil }
        let shown = found.prefix(4).joined(separator: "; ")
        let more = found.count > 4 ? " (and \(found.count - 4) more)" : ""
        return "Error: \(shown)\(more). Call \(name) again with corrected arguments."
    }

    /// The same, finding the schema by name in a list of tool entries. Nil when the list has no such tool.
    static func refusal(_ name: String, _ arguments: JSONValue?, in schemas: [JSONValue]) -> String? {
        guard let schema = schemas.first(where: { $0["function"]?["name"]?.string == name }) else { return nil }
        return refusal(name, arguments, schema: schema)
    }

    static func problems(_ name: String, _ arguments: JSONValue?, _ parameters: JSONValue) -> [String] {
        guard case .object? = arguments else { return ["the arguments must be a JSON object"] }
        var out: [String] = []
        check(arguments!, parameters, path: "", tool: name, into: &out)
        return out
    }

    private static func label(_ path: String) -> String { "argument `\(path)`" }

    private static func check(_ value: JSONValue, _ schema: JSONValue, path: String, tool: String, into out: inout [String]) {
        let type = schema["type"]?.string
        switch type {
        case "object":
            guard case .object(let object) = value else { out.append("\(label(path)) must be an object"); return }
            let properties = schema["properties"]?.object ?? [:]
            for field in (schema["required"]?.array ?? []).compactMap(\.string) where object[field] == nil || object[field] == .null {
                out.append("\(label(path.isEmpty ? field : "\(path).\(field)")) is required")
            }
            for (field, item) in object.sorted(by: { $0.key < $1.key }) {
                let here = path.isEmpty ? field : "\(path).\(field)"
                guard let known = properties[field] else {
                    if !properties.isEmpty || path.isEmpty {
                        let takes = properties.keys.sorted()
                        out.append(path.isEmpty ? "`\(field)` is not an argument of \(tool)\(takes.isEmpty ? " (it takes none)" : " (it takes: \(takes.joined(separator: ", ")))")"
                                                : "`\(here)` is not a field here (allowed: \(takes.joined(separator: ", ")))")
                    }
                    continue
                }
                if item == .null { continue }
                check(item, known, path: here, tool: tool, into: &out)
            }
        case "string":
            guard case .string(let text) = value else { out.append("\(label(path)) must be text"); return }
            let length = text.utf16.count
            if let most = schema["maxLength"]?.int, length > most { out.append("\(label(path)) is too long (\(EText.grouped(length)) characters; the most allowed is \(EText.grouped(most)))") }
            if let least = schema["minLength"]?.int, length < least { out.append(least == 1 ? "\(label(path)) must not be empty" : "\(label(path)) is too short (at least \(least) characters)") }
            if let options = schema["enum"]?.array?.compactMap(\.string), !options.contains(text) { out.append("\(label(path)) must be one of: \(options.joined(separator: ", "))") }
            if let pattern = schema["pattern"]?.string, let expression = try? NSRegularExpression(pattern: pattern),
               expression.firstMatch(in: text, range: NSRange(location: 0, length: length)) == nil {
                out.append("\(label(path)) is not in the right form\(schema["description"]?.string.map { " (\($0))" } ?? "")")
            }
        case "integer", "number":
            guard case .number(let number) = value, number.isFinite else { out.append("\(label(path)) must be \(type == "integer" ? "a whole number" : "a number")"); return }
            if type == "integer", number.rounded() != number { out.append("\(label(path)) must be a whole number"); return }
            if let least = schema["minimum"]?.double, number < least { out.append("\(label(path)) must be at least \(EText.grouped(Int(least)))") }
            if let most = schema["maximum"]?.double, number > most { out.append("\(label(path)) must be at most \(EText.grouped(Int(most)))") }
        case "boolean":
            guard case .bool = value else { out.append("\(label(path)) must be true or false"); return }
        case "array":
            guard case .array(let list) = value else { out.append("\(label(path)) must be a list"); return }
            if let most = schema["maxItems"]?.int, list.count > most { out.append("\(label(path)) has too many items (\(list.count); the most allowed is \(most))") }
            if let item = schema["items"] {
                for (index, element) in list.enumerated() { check(element, item, path: "\(path)[\(index + 1)]", tool: tool, into: &out) }
            }
        default:
            break
        }
    }
}

extension Tools {
    /// The names of the tools this class runs.
    static let names: [String] = SCHEMAS.array?.compactMap { $0["function"]?["name"]?.string } ?? []

    /// Why these arguments cannot be used for this tool, in words the model can act on; nil when they can.
    public static func argumentProblem(_ name: String, _ arguments: JSONValue?) -> String? {
        ToolArguments.refusal(name, arguments, in: SCHEMAS.array ?? [])
    }
}
