import XCTest
@testable import BlackTeamKit

// Port of tests/phone.test.cjs.

final class FakePhoneStore: PhoneConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var phone: PhoneConfig
    init(_ phone: PhoneConfig) { self.phone = phone }
    var value: PhoneConfig { get { lock.withLock { phone } } set { lock.withLock { phone = newValue } } }
    func readPhone() throws -> PhoneConfig { value }
    func savePhone(_ phone: PhoneConfig) throws { value = phone }
}

let phoneHost = "computer.testnet.ts.net"
let phoneOwner = "owner@example.test"

func privateRoute() -> JSONValue {
    ["TCP": [String(Phone.phonePort): ["HTTPS": true]], "Web": ["\(phoneHost):\(Phone.phonePort)": ["Handlers": ["/": ["Proxy": .string(Phone.target)]]]]]
}

struct PhoneCall: Equatable { var executable: String; var args: [String]; var timeout: TimeInterval }

final class PhoneFixture: @unchecked Sendable {
    let store: FakePhoneStore
    let manager: PhoneManager
    let run: PhoneCommandRunner
    private let lock = NSLock()
    private var _calls: [PhoneCall] = []
    private var route: JSONValue
    var calls: [PhoneCall] { lock.withLock { _calls } }
    var mutations: [[String]] { calls.map(\.args).filter { $0.first == "serve" && $0.count > 1 && $0[1] != "status" } }

    init(route: JSONValue = [:], phone: PhoneConfig = PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner),
         failure: PhoneCommandError? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        store = FakePhoneStore(phone)
        self.route = route
        let state: JSONValue = ["BackendState": "Running", "Self": ["Online": true, "DNSName": .string(phoneHost + "."), "UserID": 1], "User": ["1": ["LoginName": .string(phoneOwner)]]]
        var box: PhoneFixture?
        let runner: PhoneCommandRunner = { executable, args, timeout in
            guard let me = box else { throw PhoneCommandError() }
            return try me.handle(executable, args, timeout, failure: failure, state: state)
        }
        run = runner
        manager = PhoneManager(configStore: store, run: runner, clock: clock)
        box = self
    }

    private func handle(_ executable: String, _ args: [String], _ timeout: TimeInterval, failure: PhoneCommandError?, state: JSONValue) throws -> String {
        lock.withLock { _calls.append(PhoneCall(executable: executable, args: args, timeout: timeout)) }
        if let failure { throw failure }
        if args.first == "status" { return state.text() }
        if args == ["serve", "status", "--json"] { return lock.withLock { route }.text() }
        if args.first == "serve" && args.contains("off") { lock.withLock { route = [:] }; return "" }
        if args.first == "serve" && args.contains(Phone.target) { lock.withLock { route = privateRoute() }; return "" }
        throw PhoneCommandError(message: "Unexpected mocked Tailscale command")
    }
}

func withHandler(_ route: JSONValue, _ path: String, proxy: String) -> JSONValue {
    var copy = route
    var handlers = copy["Web"]?["\(phoneHost):\(Phone.phonePort)"]?["Handlers"]?.object ?? [:]
    handlers[path] = ["Proxy": .string(proxy)]
    copy = copy.setting("Web", ["\(phoneHost):\(Phone.phonePort)": ["Handlers": .object(handlers)]])
    return copy
}

final class PhoneManagerTests: XCTestCase {
    func testInputAcceptsPrivateTailscaleNamesOnly() throws {
        XCTAssertEqual(try validatePhone(enabled: true, hostname: "COMPUTER.testnet.ts.net.", owner: phoneOwner), PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner))
        for (host, owner) in [("example.com", phoneOwner), ("https://" + phoneHost, phoneOwner), (phoneHost + ":8449", phoneOwner), (phoneHost, "bad\nlogin"), (phoneHost, ""), ("", phoneOwner)] {
            XCTAssertThrowsError(try validatePhone(enabled: true, hostname: host, owner: owner), "\(host) \(owner)")
        }
        XCTAssertThrowsError(try validatePhone(enabled: true, hostname: phoneHost, owner: String(repeating: "a", count: 121)))
        XCTAssertNoThrow(try validatePhone(enabled: false, hostname: "", owner: ""))
    }

    func testConnectOnlyCreatesTheDedicatedPrivateRouteAndVerifiesIt() async throws {
        let f = PhoneFixture()
        let connected = try await f.manager.connect()
        XCTAssertTrue(connected.connected)
        XCTAssertEqual(connected.url, "https://\(phoneHost):\(Phone.phonePort)/")
        XCTAssertEqual(f.mutations, [["serve", "--bg", "--https=\(Phone.phonePort)", "--yes", Phone.target]])
        for call in f.calls {
            XCTAssertEqual(call.executable, "tailscale")
            XCTAssertLessThanOrEqual(call.timeout, 10)
            XCTAssertFalse(call.args.contains("funnel"))
            XCTAssertFalse(call.args.contains("reset"))
        }
        XCTAssertGreaterThanOrEqual(f.calls.filter { $0.args == ["serve", "status", "--json"] }.count, 2)
    }

    func testExistingPrivateRouteIsReusedAndDisabledPhonePerformsNoProbes() async throws {
        let f = PhoneFixture(route: privateRoute())
        let again = try await f.manager.connect()
        XCTAssertTrue(again.connected)
        XCTAssertTrue(f.mutations.isEmpty)
        let off = PhoneFixture(phone: PhoneConfig(enabled: false, hostname: phoneHost, owner: phoneOwner))
        let status = try await off.manager.status()
        XCTAssertFalse(status.connected)
        XCTAssertEqual(off.calls.count, 0)
        do { _ = try await off.manager.connect(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("enable Companion") ?? false) }
        XCTAssertEqual(off.calls.count, 0)
    }

    func testAnotherRouteExtraHandlerPublicFunnelOrWrongOwnerIsNeverOverwritten() async throws {
        let other = withHandler(privateRoute(), "/", proxy: "http://127.0.0.1:9999")
        let extra = withHandler(privateRoute(), "/other", proxy: Phone.target)
        let funnel = privateRoute().setting("AllowFunnel", ["\(phoneHost):\(Phone.phonePort)": true])
        let forward: JSONValue = ["TCP": [String(Phone.phonePort): ["TCPForward": "127.0.0.1:8888"]]]
        for route in [other, extra, funnel, forward] {
            let f = PhoneFixture(route: route)
            do { _ = try await f.manager.connect(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("will not overwrite") ?? false) }
            XCTAssertTrue(f.mutations.isEmpty)
        }
        let wrong = PhoneFixture(phone: PhoneConfig(enabled: true, hostname: phoneHost, owner: "someone@example.test"))
        do { _ = try await wrong.manager.connect(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("saved computer and owner") ?? false) }
        XCTAssertFalse(wrong.calls.contains { $0.args.first == "serve" })
    }

    func testDisconnectRemovesOnlyAnOwnedRoute() async throws {
        let f = PhoneFixture(route: privateRoute())
        let status = try await f.manager.disconnect()
        XCTAssertFalse(status.connected)
        XCTAssertEqual(f.calls.map(\.args).filter { $0.contains("off") }, [["serve", "--https=\(Phone.phonePort)", "off"]])
        let funnel = PhoneFixture(route: privateRoute().setting("AllowFunnel", ["\(phoneHost):\(Phone.phonePort)": true]))
        do { _ = try await funnel.manager.disconnect(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("no longer belongs exclusively") ?? false) }
        XCTAssertFalse(funnel.calls.contains { $0.args.contains("off") })
        // Another app's route on another port is never looked at, let alone removed.
        let theirs: JSONValue = ["TCP": ["443": ["HTTPS": true], "8443": ["HTTPS": true]],
                                 "Web": ["\(phoneHost):443": ["Handlers": ["/": ["Proxy": "http://127.0.0.1:18789"]]], "\(phoneHost):8443": ["Handlers": ["/": ["Proxy": "http://127.0.0.1:8770"]]]]]
        let untouched = PhoneFixture(route: theirs)
        _ = try await untouched.manager.disconnect()
        XCTAssertTrue(untouched.mutations.isEmpty)
    }

    func testMissingTailscaleIsADisconnectedStateAndRouteIdentityIsExact() async throws {
        let f = PhoneFixture(failure: PhoneCommandError(notFound: true, message: "private exception"))
        let detected = await f.manager.detect()
        XCTAssertFalse(detected.installed)
        XCTAssertFalse(detected.online)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(detected), as: UTF8.self).contains("private exception"))
        let status = try await f.manager.status()
        XCTAssertFalse(status.connected)
        XCTAssertEqual(phoneRouteState(privateRoute(), hostname: phoneHost), PhoneRouteState(owned: true, publicRoute: false, occupied: true))
        XCTAssertFalse(phoneRouteState(privateRoute(), hostname: "different.testnet.ts.net").owned)
    }

    func testGuidedSetupDetectsSavesAndConnects() async throws {
        let f = PhoneFixture(phone: PhoneConfig())
        let status = try await f.manager.setup()
        XCTAssertTrue(status.connected)
        XCTAssertEqual(f.store.value, PhoneConfig(enabled: true, hostname: phoneHost, owner: phoneOwner))
    }

    func testGuidedSetupNeverSwitchesAnEnabledAccountOrOverwritesAPublicRoute() async throws {
        let wrong = PhoneFixture(phone: PhoneConfig(enabled: true, hostname: phoneHost, owner: "someone@example.test"))
        do { _ = try await wrong.manager.setup(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("account or computer has changed") ?? false) }
        XCTAssertEqual(wrong.store.value.owner, "someone@example.test")
        XCTAssertFalse(wrong.calls.contains { $0.args.first == "serve" })
        let funnel = privateRoute().setting("AllowFunnel", ["\(phoneHost):\(Phone.phonePort)": true])
        let exposed = PhoneFixture(route: funnel, phone: PhoneConfig())
        do { _ = try await exposed.manager.setup(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("will not overwrite") ?? false) }
        XCTAssertTrue(exposed.mutations.isEmpty)
        let status = try await exposed.manager.status(fresh: true)
        XCTAssertFalse(status.connected)
    }

    func testGuidedSetupLeavesSettingsUnchangedWhenTailscaleIsUnavailable() async throws {
        let f = PhoneFixture(phone: PhoneConfig(), failure: PhoneCommandError(notFound: true))
        do { _ = try await f.manager.setup(); XCTFail("should refuse") } catch { XCTAssertTrue((error as? BlackTeamError)?.message.contains("Install Tailscale") ?? false) }
        XCTAssertEqual(f.store.value, PhoneConfig())
    }

    func testTurningOffBlocksRequestsEvenIfTailscaleCannotRemoveItsRoute() async throws {
        let f = PhoneFixture(failure: PhoneCommandError(notFound: true))
        let result = try await f.manager.disable()
        XCTAssertTrue(result.disabled)
        XCTAssertFalse(f.store.value.enabled)
        XCTAssertNotNil(result.warning)
        let status = try await f.manager.status()
        XCTAssertFalse(status.connected)
    }

    func testStatusIsCachedForFiveSeconds() async throws {
        let now = PhoneBox(Date(timeIntervalSince1970: 1000))
        let f = PhoneFixture(route: privateRoute(), clock: { now.value })
        _ = try await f.manager.status()
        let first = f.calls.count
        _ = try await f.manager.status()
        XCTAssertEqual(f.calls.count, first)
        now.value = Date(timeIntervalSince1970: 1006)
        _ = try await f.manager.status()
        XCTAssertGreaterThan(f.calls.count, first)
    }

    func testTheTailscaleToolIsLookedForInTheMacsUsualPlaces() {
        XCTAssertEqual(Tailscale.candidates(path: "/usr/bin:/opt/homebrew/bin:relative").prefix(4),
                       ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"])
        XCTAssertEqual(Tailscale.locate(path: "/x", isExecutable: { $0 == "/usr/local/bin/tailscale" }), "/usr/local/bin/tailscale")
        XCTAssertEqual(Tailscale.locate(path: "/x", isExecutable: { $0.hasPrefix("/Applications") || $0 == "/opt/homebrew/bin/tailscale" }), "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertNil(Tailscale.locate(path: "/x", isExecutable: { _ in false }))
    }
}

final class PhoneBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
