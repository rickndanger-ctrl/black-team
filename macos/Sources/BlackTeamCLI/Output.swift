import Foundation
import BlackTeamKit

// Small helpers every command uses.

var arguments = Array(CommandLine.arguments.dropFirst())
var asJSON = false

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func describe(_ error: Error) -> String { (error as? BlackTeamError)?.message ?? error.localizedDescription }

/// Removes `--name value` from the arguments and returns the value.
@MainActor func option(_ name: String) -> String? {
    guard let at = arguments.firstIndex(of: name) else { return nil }
    guard at + 1 < arguments.count else { fail("\(name) needs a value.\n\n\(usage)", code: 2) }
    let value = arguments[at + 1]
    arguments.removeSubrange(at...(at + 1))
    return value
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self))
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
func rate(_ bytesPerSecond: Double) -> String { String(format: "%.1f MB/s", bytesPerSecond / 1_048_576) }
