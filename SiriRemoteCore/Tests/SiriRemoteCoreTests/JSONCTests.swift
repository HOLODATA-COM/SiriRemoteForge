import XCTest
@testable import SiriRemoteCore

final class JSONCTests: XCTestCase {
    func testStripsLineComment() {
        XCTAssertEqual(JSONC.strip("{ \"a\": 1 // hi\n}"), "{ \"a\": 1 \n}")
    }
    func testKeepsSlashesInsideStrings() {
        let s = "{ \"url\": \"http://x\" }"
        XCTAssertEqual(JSONC.strip(s), s)
    }
    func testHandlesEscapedQuoteInString() {
        let s = "{ \"a\": \"x\\\"//y\" }"
        XCTAssertEqual(JSONC.strip(s), s)
    }
}
