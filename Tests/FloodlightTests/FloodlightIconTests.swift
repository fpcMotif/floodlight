import AppKit
import XCTest
@testable import Floodlight

final class FloodlightIconTests: XCTestCase {
    func testMenuBarIconLoadsAsTemplateVectorArtwork() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/Floodlight/Resources")
            .appendingPathComponent("FloodlightMenuBar.svg")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let image = FloodlightMenuBarIcon.image(resourceURL: sourceURL)

        XCTAssertTrue(source.contains("<svg"))
        XCTAssertFalse(source.contains("Floodlight"))
        XCTAssertTrue(image.isValid)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testMissingVectorResourceUsesTemplateFallback() {
        let image = FloodlightMenuBarIcon.image(
            resourceURL: URL(fileURLWithPath: "/missing/FloodlightMenuBar.svg")
        )

        XCTAssertTrue(image.isValid)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }
}
