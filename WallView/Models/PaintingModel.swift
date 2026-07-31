import UIKit
import simd

/// One photo the user has added to the gallery, with a stable identity so the
/// frame picker can key per-photo frame choices to it before any
/// `PaintingModel` exists.
struct GalleryPhoto: Identifiable, Hashable {
    let id = UUID()
    let image: UIImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Data describing one painting in the gallery the user is previewing: the
/// photo they picked, the frame style they chose for it, its current real-world
/// size in inches, and its position on the computed wall plane.
struct PaintingModel: Identifiable {
    let id: UUID

    /// The original, unframed photo the user selected on Screen 2.
    var sourceImage: UIImage

    /// The frame style chosen for this photo on Screen 3.
    var frameStyle: FrameStyle = .unframed

    /// Current real-world width/height in whole inches. Resizing snaps to
    /// whole-inch increments only — no fractional sizes.
    var widthInches: Int = 24
    var heightInches: Int = 36

    /// The painting's live position on the wall plane, expressed as an offset
    /// in meters from the wall-plane origin (the marker line's midpoint):
    /// `x` along the plane's right axis, `y` along world-up.
    var centerOffsetXMeters: Float = 0
    var centerOffsetYMeters: Float = 0

    init(id: UUID = UUID(), sourceImage: UIImage, frameStyle: FrameStyle = .unframed, widthInches: Int = 24, heightInches: Int = 36) {
        self.id = id
        self.sourceImage = sourceImage
        self.frameStyle = frameStyle
        self.widthInches = widthInches
        self.heightInches = heightInches
    }

    var widthMeters: Float {
        Float(widthInches) * 0.0254
    }

    var heightMeters: Float {
        Float(heightInches) * 0.0254
    }

    /// The photo composited with the chosen frame's border/mat, generated once
    /// per frame-style change and reused as the AR texture — see `FrameCompositor`.
    var framedImage: UIImage {
        FrameCompositor.composite(image: sourceImage, style: frameStyle)
    }
}

// MARK: - Gallery layout

/// Lays a gallery of paintings out across the available wall area: evenly
/// spaced, wrapped into rows, and — by construction — never overlapping.
///
/// The non-overlap guarantee comes from the structure of the algorithm rather
/// than from a collision check afterwards. Items are wrapped into rows; each
/// row occupies a horizontal band whose height is its tallest item, and bands
/// are stacked with a gap between them, so no two rows can ever intersect
/// vertically. Within a row, each item's x-interval is advanced by its own
/// width plus the gap, so no two items in a row can intersect horizontally.
/// Scaling is therefore only ever about *fitting* the wall nicely — if a
/// gallery is too large to fit even at minimum size, it overflows the ideal
/// band rather than overlapping.
enum GalleryLayout {

    /// Gap between adjacent paintings, horizontally and between rows.
    static let gapMeters: Float = 0.12

    /// The usable wall region the gallery is centred in. There's no measurement
    /// of how wide the real wall is — ARKit was never asked to find it — so
    /// this is a deliberate, reasonable interior-wall assumption.
    static let availableWidthMeters: Float = 3.0
    static let availableHeightMeters: Float = 1.6

    /// Paintings never scale below this, so a very large gallery stays visible
    /// rather than shrinking to invisible slivers.
    static let minimumInches = 6

    struct Placement {
        let id: UUID
        let widthInches: Int
        let heightInches: Int
        /// Offset in meters from the centre of the available region.
        let offsetXMeters: Float
        let offsetYMeters: Float
    }

    /// Computes each painting's size and position. Sizes are only ever reduced,
    /// never enlarged, so a user's manual resize is respected unless the
    /// gallery genuinely doesn't fit.
    static func layout(
        paintings: [PaintingModel],
        availableWidth: Float = availableWidthMeters,
        availableHeight: Float = availableHeightMeters,
        gap: Float = gapMeters
    ) -> [Placement] {
        guard !paintings.isEmpty else { return [] }

        // Find the largest scale (≤ 1) at which the gallery fits the region.
        // Each trial re-wraps from scratch, because scaling changes how many
        // items fit per row and therefore the row count and total height.
        var scale: Float = 1
        for _ in 0..<12 {
            let sizes = paintings.map { scaledSize(of: $0, scale: scale) }
            let rows = wrap(sizes: sizes, availableWidth: availableWidth, gap: gap)
            let totalHeight = totalHeight(of: rows, sizes: sizes, gap: gap)
            let widest = widestRow(rows, sizes: sizes, gap: gap)

            let heightFit = totalHeight <= availableHeight
            let widthFit = widest <= availableWidth
            if heightFit && widthFit { break }

            let heightRatio = heightFit ? 1 : availableHeight / max(totalHeight, 0.0001)
            let widthRatio = widthFit ? 1 : availableWidth / max(widest, 0.0001)
            let next = scale * min(heightRatio, widthRatio) * 0.98
            // Once every painting is already at the minimum size, shrinking
            // further changes nothing — stop and let the gallery overflow the
            // ideal band instead of looping pointlessly.
            if next >= scale || allAtMinimum(paintings, scale: next) { break }
            scale = next
        }

        // Final pass uses the sizes the paintings will actually be given, so
        // positions are computed from the same integers that get rendered and
        // the gaps come out exactly even.
        let finalSizes = paintings.map { scaledSize(of: $0, scale: scale) }
        let rows = wrap(sizes: finalSizes, availableWidth: availableWidth, gap: gap)
        let rowHeights = rows.map { row in row.map { finalSizes[$0].height }.max() ?? 0 }
        let stackHeight = rowHeights.reduce(0, +) + gap * Float(max(rows.count - 1, 0))

        var placements: [Placement] = []
        // Rows run top to bottom, the whole stack centred vertically on the
        // region's centre.
        var rowTop = stackHeight / 2

        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            let rowWidth = row.map { finalSizes[$0].width }.reduce(0, +) + gap * Float(max(row.count - 1, 0))
            let rowCenterY = rowTop - rowHeight / 2

            // Each row is centred horizontally, so the gallery reads as a
            // deliberate composition rather than being left-aligned.
            var cursorX = -rowWidth / 2

            for index in row {
                let size = finalSizes[index]
                placements.append(
                    Placement(
                        id: paintings[index].id,
                        widthInches: size.widthInches,
                        heightInches: size.heightInches,
                        offsetXMeters: cursorX + size.width / 2,
                        offsetYMeters: rowCenterY
                    )
                )
                cursorX += size.width + gap
            }

            rowTop -= rowHeight + gap
        }

        return placements
    }

    // MARK: Internals

    private struct SizedItem {
        let widthInches: Int
        let heightInches: Int
        var width: Float { Float(widthInches) * 0.0254 }
        var height: Float { Float(heightInches) * 0.0254 }
    }

    /// Scaled size in whole inches. Rounded *down* so a size can never grow
    /// past what the fitting pass measured — rounding up could reintroduce the
    /// overflow the scale was chosen to avoid.
    private static func scaledSize(of painting: PaintingModel, scale: Float) -> SizedItem {
        SizedItem(
            widthInches: max(minimumInches, Int((Float(painting.widthInches) * scale).rounded(.down))),
            heightInches: max(minimumInches, Int((Float(painting.heightInches) * scale).rounded(.down)))
        )
    }

    private static func allAtMinimum(_ paintings: [PaintingModel], scale: Float) -> Bool {
        paintings.allSatisfy { painting in
            let size = scaledSize(of: painting, scale: scale)
            return size.widthInches == minimumInches && size.heightInches == minimumInches
        }
    }

    /// Greedy row wrapping: fill a row until the next item wouldn't fit, then
    /// start a new one. A row always holds at least one item, so an item wider
    /// than the whole region gets its own row rather than an infinite loop.
    private static func wrap(sizes: [SizedItem], availableWidth: Float, gap: Float) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var currentWidth: Float = 0

        for index in sizes.indices {
            let width = sizes[index].width
            let projected = current.isEmpty ? width : currentWidth + gap + width
            if !current.isEmpty && projected > availableWidth {
                rows.append(current)
                current = [index]
                currentWidth = width
            } else {
                current.append(index)
                currentWidth = projected
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private static func totalHeight(of rows: [[Int]], sizes: [SizedItem], gap: Float) -> Float {
        let heights = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }
        return heights.reduce(0, +) + gap * Float(max(rows.count - 1, 0))
    }

    private static func widestRow(_ rows: [[Int]], sizes: [SizedItem], gap: Float) -> Float {
        rows.map { row in
            row.map { sizes[$0].width }.reduce(0, +) + gap * Float(max(row.count - 1, 0))
        }.max() ?? 0
    }
}
