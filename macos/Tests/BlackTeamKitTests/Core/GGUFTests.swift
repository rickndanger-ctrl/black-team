import XCTest
@testable import BlackTeamKit

/// A small, real GGUF header: version 3, no tensors, a few metadata pairs including a long array.
enum GGUFPair {
    case string(String, String), u32(String, UInt32), u64(String, UInt64), strings(String, [String])
}

func writeGGUF(_ file: String, _ pairs: [GGUFPair]) {
    var data = Data("GGUF".utf8)
    func u32(_ n: UInt32) { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
    func u64(_ n: UInt64) { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
    func str(_ s: String) { u64(UInt64(s.utf8.count)); data.append(Data(s.utf8)) }
    u32(3); u64(0); u64(UInt64(pairs.count))
    for pair in pairs {
        switch pair {
        case .string(let key, let value): str(key); u32(8); str(value)
        case .u32(let key, let value): str(key); u32(4); u32(value)
        case .u64(let key, let value): str(key); u32(10); u64(value)
        case .strings(let key, let value): str(key); u32(9); u32(8); u64(UInt64(value.count)); value.forEach(str)
        }
    }
    try! FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: file))
}

final class GGUFTests: XCTestCase {
    func testReadsNameArchitectureContextAndLayersFromTheHeaderOnly() throws {
        let dir = makeTemporaryFolder(self)
        let tokens = (0..<5000).map { "tok\($0)" }
        let file = dir + "/m.gguf"
        writeGGUF(file, [.string("general.architecture", "qwen35"), .string("general.name", "Qwen3.8-27B"), .string("general.size_label", "27B"),
                         .strings("tokenizer.ggml.tokens", tokens), .u32("qwen35.context_length", 262144), .u64("qwen35.block_count", 65)])
        XCTAssertEqual(try describeModel(file), ModelDescription(name: "Qwen3.8-27B", architecture: "qwen35", sizeLabel: "27B", trainingContext: 262144, layers: 65, experts: nil))
        // The token table is skipped, not kept.
        let found = try readMetadata(file, wanted: { $0 == "general.name" })
        XCTAssertEqual(Array(found.metadata.keys), ["general.name"])
        XCTAssertEqual(try readMetadata(file).metadata["tokenizer.ggml.tokens"]?.array?.count, 64)
        try "plain text that is long enough to read".write(toFile: dir + "/not.gguf", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try describeModel(dir + "/not.gguf")) { XCTAssertTrue(($0 as! BlackTeamError).message.contains("Not a GGUF")) }
    }

    func testTruncatedHeaderIsReported() throws {
        let dir = makeTemporaryFolder(self)
        writeGGUF(dir + "/m.gguf", [.string("general.name", "x")])
        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/m.gguf"))
        try data.prefix(data.count - 3).write(to: URL(fileURLWithPath: dir + "/cut.gguf"))
        XCTAssertThrowsError(try describeModel(dir + "/cut.gguf")) { XCTAssertEqual(($0 as! BlackTeamError).message, "GGUF file ends inside its metadata.") }
    }
}
