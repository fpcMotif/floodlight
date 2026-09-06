import Foundation

/// Fixed PNG-shaped payloads for clipboard image tests. The store treats these
/// as opaque bytes; capture and restore tests that need a real bitmap generate
/// one themselves.
package enum ClipboardImageTestData {
    package static let png = Data(repeating: 0xAB, count: 64)
    package static let tiff = Data(repeating: 0xCD, count: 80)
    package static let thumbnail = Data(repeating: 0xEF, count: 32)

    /// SHA-256 of `png`, computed independently of the production hasher.
    package static let pngSHA256 =
        "ec65c8798ecf95902413c40f7b9e6d4b0068885f5f324aba1f9ba1c8e14aea61"

    /// Where `SearchCoordinator` materializes a captured image for Quick Look.
    ///
    /// Spelled out rather than asked of the production builder: what the tests
    /// pin is that the path does not move, and deriving it from the code under
    /// test would pin nothing. One independent spelling, though — not one per
    /// suite.
    package static func previewURL(entryID: String, pathExtension: String = "png") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true)
            .appendingPathComponent("\(entryID).\(pathExtension)")
    }
}
