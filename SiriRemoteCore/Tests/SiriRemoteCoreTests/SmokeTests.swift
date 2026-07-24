import XCTest
@testable import SiriRemoteCore

final class SmokeTests: XCTestCase {
    func testPackageLoads() {
        XCTAssertEqual(SiriRemoteCore.version, "0.1.0")
    }
}
