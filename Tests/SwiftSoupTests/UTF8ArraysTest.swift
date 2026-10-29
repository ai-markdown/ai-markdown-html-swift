import XCTest
@testable import AIMarkdownHTML

final class UTF8ArraysTest: XCTestCase {
    func testCommonTagConstants() {
        XCTAssertEqual(UTF8Arrays.embed, "embed".utf8Array)
        XCTAssertEqual(UTF8Arrays.noframes, "noframes".utf8Array)
        XCTAssertEqual(UTF8Arrays.noscript, "noscript".utf8Array)
    }
}
