import AppKit

enum FloodlightMenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(resourceURL: URL? = bundledResourceURL) -> NSImage {
        if let resourceURL,
           let image = NSImage(contentsOf: resourceURL),
           image.isValid
        {
            return prepare(image)
        }

        return prepare(fallbackImage())
    }

    private static var bundledResourceURL: URL? {
        Bundle.main.url(
            forResource: "FloodlightMenuBar",
            withExtension: "svg"
        )
    }

    private static func prepare(_ image: NSImage) -> NSImage {
        image.size = size
        image.isTemplate = true
        return image
    }

    private static func fallbackImage() -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            let scale = NSAffineTransform()
            scale.scaleX(
                by: rect.width / size.width,
                yBy: rect.height / size.height
            )
            scale.concat()

            NSColor.black.setFill()

            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: 2.25, y: 1.5))
            beam.line(to: NSPoint(x: 15.75, y: 1.5))
            beam.line(to: NSPoint(x: 11.25, y: 7.75))
            beam.line(to: NSPoint(x: 6.75, y: 7.75))
            beam.close()
            beam.fill()

            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 6.25, y: 8.75))
            handle.line(to: NSPoint(x: 11.75, y: 8.75))
            handle.line(to: NSPoint(x: 10.25, y: 11.25))
            handle.line(to: NSPoint(x: 10.25, y: 16.5))
            handle.line(to: NSPoint(x: 7.75, y: 16.5))
            handle.line(to: NSPoint(x: 7.75, y: 11.25))
            handle.close()
            handle.appendOval(
                in: NSRect(x: 8.45, y: 13.45, width: 1.1, height: 1.1)
            )
            handle.windingRule = .evenOdd
            handle.fill()
            return true
        }
    }
}
