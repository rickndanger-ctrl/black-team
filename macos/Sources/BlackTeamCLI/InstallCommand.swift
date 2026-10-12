import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A phrase that is inside every Black Team command-line program and nothing else, so `install-command` can tell a link to one
/// from a link to something that merely has the same name.
let blackTeamProgramMarker = "black-team-command-marker-3f9c61d2-7a1e-4b0b-9a53-0c5e8d1f42aa"

/// `black-team install-command [--to <folder>]`.
func runInstallCommand(_ args: [String]) -> Int32 {
    var folder = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.local/bin"
    var rest = args
    if let at = rest.firstIndex(of: "--to") {
        guard at + 1 < rest.count else { emitError("--to needs a folder.\n"); return 2 }
        folder = rest[at + 1]
        rest.removeSubrange(at...(at + 1))
    }
    if let extra = rest.first { emitError("Unexpected \(extra). Usage: black-team install-command [--to <folder>]\n"); return 2 }
    if folder.hasPrefix("~") { folder = NSHomeDirectory() + folder.dropFirst() }
    folder = URL(fileURLWithPath: folder).standardizedFileURL.path
    guard let own = Bundle.main.executablePath.flatMap({ realpath($0, nil).map { p -> String in defer { free(p) }; return String(cString: p) } }) else {
        emitError("Could not find this program on disk.\n"); return 1
    }
    let target = folder + "/black-team"
    var info = stat()
    if lstat(target, &info) == 0 {
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        var resolved: String?
        if isLink, let real = realpath(target, nil) { resolved = String(cString: real); free(real) }
        if let resolved, resolved == own || isBlackTeamProgram(resolved) {
            // Ours: replaced below.
        } else {
            let what = isLink ? (resolved.map { "a link to \($0)" } ?? "a link that points nowhere") : "a file that is not a link to a Black Team program"
            emitError("\(target) already exists and is \(what), so it was left alone.\nTo install somewhere else: black-team install-command --to <folder>  (for example --to ~/bin)\n")
            return 1
        }
    }
    do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch {
        emitError("Could not create \(folder): \(error.localizedDescription)\n"); return 1
    }
    unlink(target)
    guard symlink(own, target) == 0 else { emitError("Could not link \(target): \(String(cString: strerror(errno)))\n"); return 1 }
    print("Linked \(target) -> \(own)")
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
    if path.contains(folder) {
        print("\(folder) is on your PATH. Open a new terminal and type: black-team")
    } else {
        let shell = (ProcessInfo.processInfo.environment["SHELL"] ?? "").split(separator: "/").last.map(String.init) ?? ""
        print("\(folder) is not on your PATH yet. Add this line to your shell's start-up file and open a new terminal:")
        switch shell {
        case "fish": print("  fish_add_path \"\(folder)\"   (run it once)")
        case "zsh": print("  echo 'export PATH=\"\(folder):$PATH\"' >> ~/.zshrc")
        default: print("  echo 'export PATH=\"\(folder):$PATH\"' >> ~/.bashrc")
        }
    }
    if own.contains("/.build/") { print("Note: this program is in a build folder; if you rebuild somewhere else, run install-command again.") }
    return 0
}

/// Whether a file is a Black Team command-line program: it contains the marker phrase.
func isBlackTeamProgram(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    let needle = Data(blackTeamProgramMarker.utf8)
    var carry = Data()
    while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        let window = carry + chunk
        if window.range(of: needle) != nil { return true }
        carry = window.suffix(needle.count)
    }
    return false
}
