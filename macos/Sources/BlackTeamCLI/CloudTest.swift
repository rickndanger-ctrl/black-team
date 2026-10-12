import Foundation
import BlackTeamKit

// A stand-in for a cloud service, for testing the wire format without a real key. BLACK_TEAM_CLOUD_TEST_HOST=<host:port> lets
// THIS command-line tool accept `http://<host:port>/v1` as a cloud address, and only when the host is 127.0.0.1 or localhost.
// The check lives here, in the black-team command: BlackTeamKit's default (`CloudRules.standard`) never reads the variable, and
// the Black Team app does not contain this file or the variable's name. Real https addresses are still checked as usual.
func cloudRulesForThisRun() -> CloudRules {
    guard let hostPort = ProcessInfo.processInfo.environment["BLACK_TEAM_CLOUD_TEST_HOST"], !hostPort.isEmpty else { return .standard }
    let pieces = hostPort.split(separator: ":").map(String.init)
    guard pieces.count == 2, ["127.0.0.1", "localhost"].contains(pieces[0]), let port = Int(pieces[1]), (1...65535).contains(port) else {
        fail("BLACK_TEAM_CLOUD_TEST_HOST must be 127.0.0.1:<port> or localhost:<port>.", code: 2)
    }
    FileHandle.standardError.write(Data("NOTE: BLACK_TEAM_CLOUD_TEST_HOST is set. http://\(hostPort)/v1 is accepted as a cloud address in this run. No real cloud service should be in use.\n".utf8))
    return CloudRules { value in
        if let real = try? cloudEndpoint(value) { return real }
        guard let parts = URLComponents(string: value), parts.scheme == "http", parts.host == pieces[0], parts.port == port, ["/v1", "/v1/"].contains(parts.path),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw BlackTeamError("In this test run a cloud address must be http://\(hostPort)/v1 or a real https address.")
        }
        return CloudEndpoint(base: "http://\(hostPort)/v1", host: hostPort)
    }
}
