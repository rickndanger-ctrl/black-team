import XCTest
@testable import BlackTeamKit

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let value = try JSONValue.parse(#"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#)
        XCTAssertEqual(value["a"]?[0]?.int, 1)
        XCTAssertEqual(value["b"]?["c"]?.string, "d")
        XCTAssertEqual(value.text(), #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#)
    }
}
