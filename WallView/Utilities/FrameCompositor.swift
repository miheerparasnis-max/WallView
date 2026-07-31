import UIKit

/// Renders each `FrameStyle` as a flat, composited image (source photo plus a
/// Core Graphics-drawn border and, for matted styles, an inner mat) rather than
/// a 3D frame mesh. This runs once per photo/frame-style combination and the
/// result becomes the AR texture, which is far simpler and cheaper than
/// building and lighting separate 3D frame geometry.
///
/// The catalog is large enough that the picker grid would otherwise re-composite
/// dozens of images on every scroll tick, so results are cached (see `thumbnail`).
enum FrameCompositor {

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    static func composite(image: UIImage, style: FrameStyle) -> UIImage {
        guard style.frameFraction > 0 || style.matColor != nil else { return image }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let minDim = min(size.width, size.height)
        let frameBorder = minDim * style.frameFraction
        let matBorder = minDim * style.matFraction

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let fullRect = CGRect(origin: .zero, size: size)

            drawFrameBackground(colors: style.frameColors, in: fullRect, context: cg)

            // The boundary between the outer frame border and the mat/photo —
            // this is what the beveled highlight/keyline detailing traces.
            let matOuterRect = fullRect.insetBy(dx: frameBorder, dy: frameBorder)

            if let matColor = style.matColor {
                cg.setFillColor(matColor.cgColor)
                cg.fill(matOuterRect)
            }

            let photoRect = matOuterRect.insetBy(dx: matBorder, dy: matBorder)
            image.draw(in: photoRect)

            if style.keyline {
                cg.setStrokeColor(UIColor.gray.withAlphaComponent(0.6).cgColor)
                cg.setLineWidth(1)
                cg.stroke(matOuterRect)
            }

            if style.beveled {
                let bevel = max(2, frameBorder * 0.25)
                let highlightRect = matOuterRect.insetBy(dx: -bevel, dy: -bevel)
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
                cg.setLineWidth(bevel)
                cg.stroke(highlightRect)

                cg.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
                cg.setLineWidth(1.5)
                cg.stroke(matOuterRect)
            }
        }
    }

    /// A small, cached composite for the picker grid. `sourceKey` identifies the
    /// photo the thumbnails were built from, so switching photos doesn't serve
    /// stale cache entries.
    static func thumbnail(image: UIImage, style: FrameStyle, sourceKey: String, maxDimension: CGFloat = 300) -> UIImage {
        let key = "\(sourceKey)|\(style.id)|\(Int(maxDimension))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let scaled = downscaled(image, maxDimension: maxDimension)
        let result = composite(image: scaled, style: style)
        cache.setObject(result, forKey: key)
        return result
    }

    /// Proportionally shrinks an image so its longest side is `maxDimension`.
    /// Exposed so callers rendering many composites from one photo can downscale
    /// once up front instead of once per composite.
    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func drawFrameBackground(colors: [UIColor], in rect: CGRect, context cg: CGContext) {
        guard let first = colors.first else { return }
        guard colors.count > 1 else {
            cg.setFillColor(first.cgColor)
            cg.fill(rect)
            return
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgColors = colors.map(\.cgColor)
        let step = 1.0 / CGFloat(colors.count - 1)
        let locations = (0..<colors.count).map { CGFloat($0) * step }
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors as CFArray, locations: locations) else { return }
        cg.saveGState()
        cg.addRect(rect)
        cg.clip()
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )
        cg.restoreGState()
    }
}
