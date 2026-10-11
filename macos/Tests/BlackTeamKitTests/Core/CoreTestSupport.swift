import XCTest
@testable import BlackTeamKit

/// A fresh temporary folder, removed when the test ends.
func makeTemporaryFolder(_ test: XCTestCase) -> String {
    let dir = NSTemporaryDirectory() + "black-team-core-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
    return dir
}

func mode(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int ?? -1) & 0o777
}
