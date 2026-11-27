import AppKit
import SwiftUI

/// Logos's waveform mark: six rounded bars of uneven height on one center line.
/// The menu bar icon, the app icon, the site's favicon, and its share image all
/// draw it from here, so they always match.
enum Glyph {
    /// Bar heights, as a fraction of the glyph's height, from left to right.
    static let heights: [CGFloat] = [0.22, 0.6, 1.0, 0.5, 0.78, 0.3]
    /// Each bar's width as a fraction of the glyph's height.
    static let barWidth: CGFloat = 0.075
    /// The glyph's width over its height.
    static let aspect: CGFloat = 0.86

    /// The bars as rounded rectangles filling `rect`, which should have `aspect`.
    static func bars(in rect: CGRect) -> [CGRect] {
        let width = barWidth * rect.height
        let step = (rect.width - width) / CGFloat(heights.count - 1)
        return heights.enumerated().map { i, fraction in
            let height = max(width, fraction * rect.height)
            return CGRect(x: rect.minX + CGFloat(i) * step, y: rect.midY - height / 2, width: width, height: height)
        }
    }

    static func path(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for bar in bars(in: rect) {
            path.addRoundedRect(in: bar, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2)
        }
        return path
    }

    /// A rect with the glyph's aspect, `height` tall, centered in `bounds`.
    static func rect(height: CGFloat, centeredIn bounds: CGRect) -> CGRect {
        let width = height * aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    /// The menu bar icon. While recording, the glyph is cut out of a filled circle.
    static func menuBarImage(recording: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if recording {
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: bounds.insetBy(dx: 0.5, dy: 0.5))
                context.setBlendMode(.destinationOut)
                context.addPath(path(in: rect(height: 10, centeredIn: bounds)))
            } else {
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(path(in: rect(height: 15, centeredIn: bounds)))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Logos"
        return image
    }

    /// The glyph as SVG rounded rectangles, for the site's favicon. The bars are
    /// centered vertically, so SVG's downward y axis draws them the same.
    static func svgRects(in rect: CGRect, fill: String) -> String {
        bars(in: rect).map { bar in
            func f(_ value: CGFloat) -> String { String(format: "%.2f", value) }
            return "<rect x=\"\(f(bar.minX))\" y=\"\(f(bar.minY))\" width=\"\(f(bar.width))\" height=\"\(f(bar.height))\" rx=\"\(f(bar.width / 2))\" fill=\"\(fill)\"/>"
        }.joined()
    }
}

/// The glyph as a SwiftUI shape.
struct GlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(Glyph.path(in: Glyph.rect(height: min(rect.height, rect.width / Glyph.aspect), centeredIn: rect)))
    }
}
