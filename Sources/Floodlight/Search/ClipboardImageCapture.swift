import AppKit
import FloodlightEngine
import Foundation

@MainActor
enum ClipboardImageCapture {
    static let thumbnailPointSize = 64
    static let thumbnailScale = 2

    struct Payload {
        let png: Data?
        let tiff: Data?
        let width: Int
        let height: Int
        let thumbnailPNGData: Data
        let displayName: String
    }

    static func payload(from observer: any PasteboardObserving) -> Payload? {
        let png = Self.capped(observer.pngData())
        let tiff = Self.capped(observer.tiffData())
        guard let primary = png ?? tiff else { return nil }
        guard let decoded = decode(primary) else { return nil }
        return Payload(
            png: png,
            tiff: tiff,
            width: decoded.width,
            height: decoded.height,
            thumbnailPNGData: decoded.thumbnailPNGData,
            displayName: displayName(
                bundleID: observer.frontmostApplicationBundleIdentifier,
                hasPNG: png != nil
            )
        )
    }

    private static func capped(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= ClipboardHistoryStore.maxImageByteCount else {
            return nil
        }
        return data
    }

    private static func displayName(bundleID: String?, hasPNG: Bool) -> String {
        if bundleID == "com.apple.screencapture" {
            return "Screenshot"
        }
        return hasPNG ? "PNG Image" : "TIFF Image"
    }

    private static func decode(_ data: Data) -> (width: Int, height: Int, thumbnailPNGData: Data)? {
        guard let representation = NSBitmapImageRep(data: data) else { return nil }
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        guard let thumbnailPNGData = thumbnailPNGData(from: representation) else { return nil }
        return (width, height, thumbnailPNGData)
    }

    private static func thumbnailPNGData(from representation: NSBitmapImageRep) -> Data? {
        let pixelSize = thumbnailPointSize * thumbnailScale
        guard let thumbnail = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        thumbnail.size = NSSize(width: thumbnailPointSize, height: thumbnailPointSize)

        let sourceSize = NSSize(
            width: representation.pixelsWide,
            height: representation.pixelsHigh
        )
        let scale = min(
            CGFloat(thumbnailPointSize) / sourceSize.width,
            CGFloat(thumbnailPointSize) / sourceSize.height
        )
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: (CGFloat(thumbnailPointSize) - drawSize.width) / 2,
            y: (CGFloat(thumbnailPointSize) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: thumbnail)
        NSColor.clear.setFill()
        NSBezierPath.fill(NSRect(
            x: 0,
            y: 0,
            width: thumbnailPointSize,
            height: thumbnailPointSize
        ))
        representation.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()

        return thumbnail.representation(using: .png, properties: [:])
    }
}
