import UIKit

/// One selectable frame in the catalog. Each style maps to a purely 2D
/// composited border/mat (see `FrameCompositor`) rather than a 3D frame mesh —
/// flat images are simpler and cheaper to render correctly than modeling frame
/// geometry, and at the AR viewing distances this app targets the difference is
/// not perceptible.
///
/// A style is the cross product of a *profile* (how wide/beveled the moulding
/// is, whether it carries a mat) and a *finish* (its colour/material), so the
/// whole catalog is generated from those two small tables rather than hand-
/// written case by case.
struct FrameStyle: Identifiable, Hashable {
    let id: String
    let category: FrameCategory
    let profileName: String
    let finishName: String

    /// Drawing spec — read directly by `FrameCompositor`.
    let frameColors: [UIColor]
    let frameFraction: CGFloat
    let matColor: UIColor?
    let matFraction: CGFloat
    let beveled: Bool
    let keyline: Bool

    var displayName: String {
        category == .none ? profileName : "\(profileName) · \(finishName)"
    }

    /// The single swatch colour used for the finish dot in the picker.
    var swatchColor: UIColor {
        frameColors.first ?? .clear
    }

    static func == (lhs: FrameStyle, rhs: FrameStyle) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Categories

enum FrameCategory: String, CaseIterable, Identifiable {
    case none
    case modern
    case classic
    case minimalist
    case ornate
    case rustic
    case matted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No Frame"
        case .modern: return "Modern"
        case .classic: return "Classic"
        case .minimalist: return "Minimalist"
        case .ornate: return "Ornate"
        case .rustic: return "Rustic"
        case .matted: return "Gallery Mat"
        }
    }
}

// MARK: - Finishes

/// A colour/material a frame profile can be rendered in. Multi-stop colour
/// arrays become a diagonal gradient (see `FrameCompositor.drawFrameBackground`),
/// which is what gives wood and metal finishes their sheen.
struct FrameFinish: Hashable {
    let id: String
    let name: String
    let colors: [UIColor]
    /// Mat colour used when this finish is paired with the matted profile.
    let matColor: UIColor

    static func == (lhs: FrameFinish, rhs: FrameFinish) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: 1)
}

extension FrameStyle {

    static let finishes: [FrameFinish] = [
        FrameFinish(id: "black", name: "Black",
                    colors: [rgb(0.06, 0.06, 0.07)],
                    matColor: .white),
        FrameFinish(id: "white", name: "White",
                    colors: [rgb(0.97, 0.97, 0.97)],
                    matColor: rgb(0.10, 0.10, 0.10)),
        FrameFinish(id: "charcoal", name: "Charcoal",
                    colors: [rgb(0.22, 0.23, 0.25)],
                    matColor: rgb(0.93, 0.93, 0.91)),
        FrameFinish(id: "naturalOak", name: "Natural Oak",
                    colors: [rgb(0.72, 0.57, 0.36), rgb(0.83, 0.70, 0.49)],
                    matColor: rgb(0.96, 0.93, 0.85)),
        FrameFinish(id: "wood", name: "Warm Wood",
                    colors: [rgb(0.42, 0.27, 0.15), rgb(0.55, 0.36, 0.20)],
                    matColor: rgb(0.96, 0.93, 0.85)),
        FrameFinish(id: "walnut", name: "Dark Walnut",
                    colors: [rgb(0.20, 0.12, 0.08), rgb(0.30, 0.18, 0.12)],
                    matColor: rgb(0.94, 0.91, 0.84)),
        FrameFinish(id: "cherry", name: "Cherry",
                    colors: [rgb(0.40, 0.14, 0.10), rgb(0.52, 0.21, 0.15)],
                    matColor: rgb(0.96, 0.94, 0.89)),
        FrameFinish(id: "driftwood", name: "Driftwood",
                    colors: [rgb(0.56, 0.55, 0.51), rgb(0.70, 0.69, 0.65)],
                    matColor: rgb(0.95, 0.95, 0.93)),
        FrameFinish(id: "gold", name: "Gold",
                    colors: [rgb(0.70, 0.55, 0.22), rgb(0.94, 0.85, 0.55), rgb(0.72, 0.57, 0.24)],
                    matColor: rgb(0.96, 0.93, 0.85)),
        FrameFinish(id: "silver", name: "Silver",
                    colors: [rgb(0.62, 0.64, 0.67), rgb(0.88, 0.89, 0.91), rgb(0.64, 0.66, 0.69)],
                    matColor: .white),
        FrameFinish(id: "champagne", name: "Champagne",
                    colors: [rgb(0.80, 0.75, 0.63), rgb(0.93, 0.89, 0.80)],
                    matColor: .white),
        FrameFinish(id: "bronze", name: "Bronze",
                    colors: [rgb(0.36, 0.26, 0.14), rgb(0.55, 0.42, 0.24), rgb(0.38, 0.28, 0.16)],
                    matColor: rgb(0.95, 0.92, 0.85))
    ]

    /// A frame profile: the geometry of the moulding, independent of colour.
    private struct Profile {
        let category: FrameCategory
        let name: String
        let frameFraction: CGFloat
        let matFraction: CGFloat
        let hasMat: Bool
        let beveled: Bool
        let keyline: Bool
    }

    private static let profiles: [Profile] = [
        Profile(category: .minimalist, name: "Minimalist", frameFraction: 0.022, matFraction: 0, hasMat: false, beveled: false, keyline: true),
        Profile(category: .modern, name: "Modern", frameFraction: 0.048, matFraction: 0, hasMat: false, beveled: false, keyline: true),
        Profile(category: .classic, name: "Classic", frameFraction: 0.075, matFraction: 0, hasMat: false, beveled: true, keyline: false),
        Profile(category: .ornate, name: "Ornate", frameFraction: 0.105, matFraction: 0, hasMat: false, beveled: true, keyline: true),
        Profile(category: .rustic, name: "Rustic", frameFraction: 0.088, matFraction: 0, hasMat: false, beveled: true, keyline: false),
        Profile(category: .matted, name: "Gallery Mat", frameFraction: 0.034, matFraction: 0.085, hasMat: true, beveled: false, keyline: true)
    ]

    /// The unframed option — always first in the catalog.
    static let unframed = FrameStyle(
        id: "none",
        category: .none,
        profileName: "No Frame (Canvas)",
        finishName: "",
        frameColors: [],
        frameFraction: 0,
        matColor: nil,
        matFraction: 0,
        beveled: false,
        keyline: false
    )

    /// The full catalog: every profile in every finish, plus the unframed option.
    static let all: [FrameStyle] = {
        var styles: [FrameStyle] = [unframed]
        for profile in profiles {
            for finish in finishes {
                styles.append(
                    FrameStyle(
                        id: "\(profile.category.rawValue).\(finish.id)",
                        category: profile.category,
                        profileName: profile.name,
                        finishName: finish.name,
                        frameColors: finish.colors,
                        frameFraction: profile.frameFraction,
                        matColor: profile.hasMat ? finish.matColor : nil,
                        matFraction: profile.hasMat ? profile.matFraction : 0,
                        beveled: profile.beveled,
                        keyline: profile.keyline
                    )
                )
            }
        }
        return styles
    }()

    /// Catalog filtered to one category; `nil` means "All".
    static func styles(in category: FrameCategory?) -> [FrameStyle] {
        guard let category else { return all }
        return all.filter { $0.category == category }
    }
}
