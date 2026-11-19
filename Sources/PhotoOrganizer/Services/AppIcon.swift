import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the app icon: a stack of photo prints on a dusk-blue tile, the top print showing a sunset
/// over mountains with a star rating underneath. Rendered by the app itself (`--render-icon`) so the
/// icon lives in code; `scripts/build-app.sh` turns the PNG into AppIcon.icns.
enum AppIcon {
    static func writePNG(to path: String, size: Int) {
        guard let image = render(size: size),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            FileHandle.standardError.write(Data("couldn't render the icon\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func render(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw on a 1024-point canvas whatever the output size. CoreGraphics' origin is bottom-left.
        let scale = CGFloat(size) / 1024
        context.scaleBy(x: scale, y: scale)
        drawTile(in: context)
        drawStack(in: context)
        return context.makeImage()
    }

    // MARK: - Background tile (macOS icon grid: 824pt rounded square centred in 1024)

    private static func drawTile(in context: CGContext) {
        let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                          cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
        context.addPath(tile)
        context.setFillColor(color(0x1B2547))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(tile)
        context.clip()
        linearGradient(in: context, from: (0x34457E, 1), to: (0x111A36, 1),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100))
        context.restoreGState()
    }

    // MARK: - Photo prints

    private static let cardSize = CGSize(width: 440, height: 500)

    private static func drawStack(in context: CGContext) {
        let center = CGPoint(x: 512, y: 512)
        drawCard(in: context, center: CGPoint(x: center.x - 46, y: center.y + 6), angle: -14,
                 paper: 0xC9CFDD, photo: (0x5A6A9A, 0x3B4875), detailed: false)
        drawCard(in: context, center: CGPoint(x: center.x + 42, y: center.y + 2), angle: 9,
                 paper: 0xDDE1EA, photo: (0x7486B8, 0x4A5A8C), detailed: false)
        drawCard(in: context, center: CGPoint(x: center.x, y: center.y - 8), angle: -2,
                 paper: 0xF7F6F1, photo: (0xF6A35E, 0xF8D77E), detailed: true)
    }

    private static func drawCard(in context: CGContext, center: CGPoint, angle: CGFloat,
                                 paper: Int, photo: (top: Int, bottom: Int), detailed: Bool) {
        let w = cardSize.width, h = cardSize.height
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle * .pi / 180)

        // Paper, with a soft shadow.
        let card = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                          cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.4))
        context.addPath(card)
        context.setFillColor(color(paper))
        context.fillPath()
        context.restoreGState()

        // The photo: a print border on three sides and a wider strip at the bottom for the rating.
        let imageRect = CGRect(x: -w / 2 + 28, y: -h / 2 + 100, width: w - 56, height: h - 128)
        context.saveGState()
        context.addPath(CGPath(roundedRect: imageRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.clip()
        linearGradient(in: context, from: (photo.top, 1), to: (photo.bottom, 1),
                       start: CGPoint(x: 0, y: imageRect.maxY), end: CGPoint(x: 0, y: imageRect.minY))
        if detailed { drawLandscape(in: context, rect: imageRect) }
        context.restoreGState()

        if detailed { drawStars(in: context, y: -h / 2 + 50, filled: 4) }
        context.restoreGState()
    }

    private static func drawLandscape(in context: CGContext, rect: CGRect) {
        // Sunset sky: warm gradient (drawn by the caller), a low sun, then two mountain ranges.
        context.setFillColor(color(0xFFF1C9, 0.95))
        context.fillEllipse(in: CGRect(x: rect.midX + 40, y: rect.midY + 10, width: 104, height: 104))

        func range(_ points: [(CGFloat, CGFloat)], _ hex: Int) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            for (x, y) in points { path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)) }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color(hex))
            context.fillPath()
        }
        range([(0, 0.40), (0.24, 0.66), (0.47, 0.44), (0.70, 0.62), (1, 0.38)], 0x9C5E86)
        range([(0, 0.22), (0.30, 0.48), (0.55, 0.24), (0.78, 0.38), (1, 0.18)], 0x2E3766)
    }

    private static func drawStars(in context: CGContext, y: CGFloat, filled: Int) {
        let spacing: CGFloat = 66, radius: CGFloat = 24
        for index in 0..<5 {
            let center = CGPoint(x: CGFloat(index - 2) * spacing, y: y)
            let star = starPath(center: center, outer: radius, inner: radius * 0.45)
            context.addPath(star)
            if index < filled {
                context.setFillColor(color(0xF2A900))
                context.fillPath()
            } else {
                context.setStrokeColor(color(0xB9BCC6))
                context.setLineWidth(5)
                context.setLineJoin(.round)
                context.strokePath()
            }
        }
    }

    private static func starPath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for point in 0..<10 {
            let radius = point.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat.pi / 2 + CGFloat(point) * .pi / 5
            let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if point == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Helpers

    private static func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func linearGradient(in context: CGContext, from: (Int, CGFloat), to: (Int, CGFloat),
                                       start: CGPoint, end: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [color(from.0, from.1), color(to.0, to.1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
