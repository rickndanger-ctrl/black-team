import Foundation

// Reads what a GGUF model says about itself: its name, architecture, training
// context and layer count. Only the header's key-value section is read, never
// the weights, so a 20 GB file costs a few kilobytes.

private let ggufLimit = 16 * 1024 * 1024
private let ggufTypes: [UInt32: String] = [0: "u8", 1: "i8", 2: "u16", 3: "i16", 4: "u32", 5: "i32", 6: "f32", 7: "bool", 8: "string", 9: "array", 10: "u64", 11: "i64", 12: "f64"]
private let ggufSizes: [String: Int] = ["u8": 1, "i8": 1, "u16": 2, "i16": 2, "u32": 4, "i32": 4, "f32": 4, "bool": 1, "u64": 8, "i64": 8, "f64": 8]

public struct GGUFMetadata: Equatable, Sendable {
    public var version: Int
    public var metadata: [String: JSONValue]
}

/// Reads the header's key-value pairs. `wanted` chooses which keys are kept (all when nil);
/// other values are read past and dropped. Arrays keep at most 64 items.
public func readMetadata(_ file: String, wanted: ((String) -> Bool)? = nil) throws -> GGUFMetadata {
    guard let handle = FileHandle(forReadingAtPath: file) else { throw BlackTeamError("GGUF model cannot be read: ENOENT.") }
    defer { try? handle.close() }
    var buffer = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
    var capacity = 64 * 1024
    var at = 0
    func need(_ bytes: Int) throws {
        while at + bytes > buffer.count {
            if capacity >= ggufLimit { throw BlackTeamError("GGUF metadata is larger than expected.") }
            capacity = min(ggufLimit, capacity * 2)
            try handle.seek(toOffset: UInt64(buffer.count))
            let more = (try? handle.read(upToCount: capacity - buffer.count)) ?? Data()
            if more.isEmpty { throw BlackTeamError("GGUF file ends inside its metadata.") }
            buffer.append(more)
        }
    }
    func load<T: FixedWidthInteger>(_ type: T.Type) -> T {
        buffer.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: T.self)) }
    }
    func scalar(_ type: String) throws -> JSONValue {
        let size = ggufSizes[type]!
        try need(size)
        let value: JSONValue
        switch type {
        case "u8": value = .number(Double(load(UInt8.self)))
        case "i8": value = .number(Double(load(Int8.self)))
        case "u16": value = .number(Double(load(UInt16.self)))
        case "i16": value = .number(Double(load(Int16.self)))
        case "u32": value = .number(Double(load(UInt32.self)))
        case "i32": value = .number(Double(load(Int32.self)))
        case "f32": value = .number(Double(Float(bitPattern: load(UInt32.self))))
        case "bool": value = .bool(load(UInt8.self) != 0)
        case "u64": value = .number(Double(load(UInt64.self)))
        case "i64": value = .number(Double(load(Int64.self)))
        default: value = .number(Double(bitPattern: load(UInt64.self)))
        }
        at += size
        return value
    }
    func unsigned(_ type: String) throws -> UInt64 { UInt64(try scalar(type).double ?? 0) }
    func string() throws -> String {
        let length = try unsigned("u64")
        if length > UInt64(ggufLimit) { throw BlackTeamError("GGUF string is too long.") }
        try need(Int(length))
        let value = String(decoding: buffer[at..<(at + Int(length))], as: UTF8.self)
        at += Int(length)
        return value
    }
    func value(_ type: String, _ keep: Bool) throws -> JSONValue {
        if type == "string" { return .string(try string()) }
        if type == "array" {
            let inner = ggufTypes[UInt32(try unsigned("u32"))]
            let count = try unsigned("u64")
            guard let inner, inner != "array" else { throw BlackTeamError("Unsupported GGUF array.") }
            // Token tables run to hundreds of thousands of entries; only skip through them unless wanted.
            var out: [JSONValue] = []
            var index: UInt64 = 0
            while index < count {
                let item = try value(inner, false)
                if keep && out.count < 64 { out.append(item) }
                index += 1
            }
            return keep ? .array(out) : .null
        }
        return try scalar(type)
    }
    try need(4)
    if String(decoding: buffer[0..<4], as: UTF8.self) != "GGUF" { throw BlackTeamError("Not a GGUF file.") }
    at = 4
    let version = Int(try unsigned("u32"))
    if ![2, 3].contains(version) { throw BlackTeamError("Unsupported GGUF version.") }
    _ = try unsigned("u64") // tensor count
    let pairs = try unsigned("u64")
    if pairs > 100000 { throw BlackTeamError("GGUF metadata is larger than expected.") }
    var metadata: [String: JSONValue] = [:]
    for _ in 0..<pairs {
        let key = try string()
        guard let type = ggufTypes[UInt32(try unsigned("u32"))] else { throw BlackTeamError("Unsupported GGUF value type.") }
        let keep = wanted?(key) ?? true
        let read = try value(type, keep)
        if keep { metadata[key] = read }
    }
    return GGUFMetadata(version: version, metadata: metadata)
}

/// The few facts Black Team uses to start a model well.
public struct ModelDescription: Equatable, Codable, Sendable {
    public var name: String
    public var architecture: String
    public var sizeLabel: String
    public var trainingContext: Int?
    public var layers: Int?
    public var experts: Int?
}

public func describeModel(_ file: String) throws -> ModelDescription {
    let pattern = try! NSRegularExpression(pattern: #"^general\.(name|architecture|basename|size_label|finetune|file_type)$|^[a-z0-9_]+\.(context_length|block_count|vocab_size|expert_count)$"#)
    let found = try readMetadata(file, wanted: { key in
        pattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    })
    let metadata = found.metadata
    func text(_ key: String) -> String {
        switch metadata[key] {
        case .string(let value)?: return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value)?: return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value)?: return value ? "true" : ""
        default: return ""
        }
    }
    let architecture = metadata["general.architecture"]?.string ?? ""
    func number(_ key: String) -> Int? {
        guard let value = metadata["\(architecture).\(key)"]?.double, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }
    return ModelDescription(name: text("general.name"), architecture: architecture, sizeLabel: text("general.size_label"),
                            trainingContext: number("context_length"), layers: number("block_count"), experts: number("expert_count"))
}
