import Foundation
#if canImport(FoundationNetworking)
// Public types such as HTTPFetch mention URLRequest, so importers of the kit get it too.
@_exported import FoundationNetworking
#endif
// CryptoKit on Apple platforms; Apple's swift-crypto (same API) on Linux.
#if canImport(CryptoKit)
@_exported import CryptoKit
#else
@_exported import Crypto
#endif

// The C `stat` struct under a name that cannot be mistaken for a `stat(_:)` method of the surrounding type.
typealias CStat = stat

#if os(Linux)
/// Linux has no autorelease pools; the body simply runs.
func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif

/// Global C calls reachable from inside types that have members of the same name (`read`, `realpath`).
func cRealpath(_ path: String) -> UnsafeMutablePointer<CChar>? { realpath(path, nil) }
func cRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
