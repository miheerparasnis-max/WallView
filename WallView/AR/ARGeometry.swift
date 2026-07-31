import simd

/// Small shared math helpers for the floor-scan → marker-line → computed-wall-plane
/// pipeline. Kept separate from `ARSessionManager` so the pure geometry is easy
/// to read (and unit test) independent of ARKit/RealityKit plumbing.
enum ARGeometry {

    static let worldUp = SIMD3<Float>(0, 1, 0)

    /// Intersects a ray (camera-through-screen-point) with an arbitrary plane
    /// defined by a point on the plane and its normal. Returns nil if the ray
    /// is parallel to the plane or points away from it.
    static func intersect(rayOrigin: SIMD3<Float>, rayDirection: SIMD3<Float>, planePoint: SIMD3<Float>, planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
        let denom = simd_dot(rayDirection, planeNormal)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(planePoint - rayOrigin, planeNormal) / denom
        guard t > 0 else { return nil }
        return rayOrigin + rayDirection * t
    }

    /// Builds a world transform whose axes are the given right/up/normal
    /// vectors (assumed orthonormal) and whose translation is `origin`. This
    /// is how the computed wall plane (Screen 6's core trick) becomes an
    /// anchor transform: no ARKit vertical-plane detection involved at all.
    static func makeTransform(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, normal: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(right, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(normal, 0),
            SIMD4<Float>(origin, 1)
        )
    }
}

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}
