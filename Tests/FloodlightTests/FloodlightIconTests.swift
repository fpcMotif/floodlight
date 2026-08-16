import AppKit
import Testing
@testable import Floodlight

struct FloodlightIconTests {
    @Test func menuBarIconLoadsAsTemplateVectorArtwork() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/Floodlight/Resources")
            .appendingPathComponent("FloodlightMenuBar.svg")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let image = FloodlightMenuBarIcon.image(resourceURL: sourceURL)

        #expect(source.contains("<svg"))
        #expect(!source.contains("Floodlight"))
        #expect(image.isValid)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func missingVectorResourceUsesTemplateFallback() {
        let image = FloodlightMenuBarIcon.image(
            resourceURL: URL(fileURLWithPath: "/missing/FloodlightMenuBar.svg")
        )

        #expect(image.isValid)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }
}
