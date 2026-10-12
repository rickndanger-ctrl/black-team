import Foundation
import CryptoKit

/// Compares two secrets in constant time (`equal` in server.cjs). Different lengths are simply unequal.
func phoneEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var difference: UInt8 = 0
    for index in x.indices { difference |= x[index] ^ y[index] }
    return difference == 0
}

/// `phone.key`: 32 random bytes as hex in the private data folder. Every pairing secret and every paired
/// phone's cookie is derived from it, so replacing it unpairs every phone at once.
///
/// The file is read again whenever a secret is needed, so `phone reset` from another process (the command-line
/// tool) takes effect in a running server at once. A key that cannot be read (removed, a symbolic link, damaged)
/// gives secrets nobody can know: every request is refused until the key is restored or reset.
public final class PhoneKeys: @unchecked Sendable {
    public let file: String

    /// Creates the key (0600) when there is none, and refuses a symbolic link or a damaged file.
    public init(folder: String) throws {
        file = folder + "/phone.key"
        _ = try Self.load(file, create: true)
    }

    private static func load(_ file: String, create: Bool = false) throws -> String {
        if CoreFS.isSymlink(file) { throw BlackTeamError("Phone pairing key must not be a symbolic link.") }
        if create && !CoreFS.exists(file) {
            let fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd < 0 { throw BlackTeamError("Could not create the phone pairing key: \(CoreFS.errnoName(errno)).") }
            defer { close(fd) }
            let text = Array(randomKey().utf8)
            if write(fd, text, text.count) != text.count { throw BlackTeamError("Could not create the phone pairing key.") }
        }
        chmod(file, 0o600)
        let fd = open(file, O_RDONLY | O_NOFOLLOW)
        if fd < 0 { throw BlackTeamError("Phone pairing key must not be a symbolic link.") }
        defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1024 else { throw damaged }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: 1025)
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.count == 64, text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { throw damaged }
        return text
    }

    private static var damaged: BlackTeamError { BlackTeamError("The phone pairing key is damaged. Restore it from your backup.") }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("No secure random numbers.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces the key (also a damaged one), which unpairs every phone and invalidates every pairing link shown so far.
    public static func reset(folder: String) throws {
        let file = folder + "/phone.key"
        try CoreFS.writeAtomic(file, Data(randomKey().utf8), temporary: "\(file).\(CoreFS.hex(10)).tmp", syncDirectory: true)
    }

    /// `phoneSecret(kind)`: HMAC-SHA256 of `["kind", hostname, owner]`, so changing the computer or the account
    /// also unpairs every phone.
    public func secret(_ kind: String, hostname: String, owner: String) -> String {
        let current = (try? Self.load(file)) ?? Self.randomKey()
        let message = JSONValue.array([.string(kind), .string(hostname), .string(owner)]).text()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(current.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
