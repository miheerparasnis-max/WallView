import ARKit
import RealityKit
import Combine
import UIKit
import simd

/// Drives the entire AR flow: real-geometry horizontal floor-plane scanning,
/// the screen-space yellow line the user aligns to the real wall/floor edge, the
/// *computed* vertical wall plane derived from that floor scan + line (the
/// app's core reliability trick — deliberately not ARKit's own vertical plane
/// detection, which is unreliable on plain walls), and finally placing,
/// selecting/resizing, and repositioning the framed painting on that computed
/// plane.
///
/// SwiftUI observes this class's `@Published` state; `ARViewContainer`'s
/// `Coordinator` is the only thing that calls into it in response to gestures,
/// so all AR/ARKit-facing logic lives in one place.
final class ARSessionManager: NSObject, ObservableObject {

    enum Stage {
        case floorScan
        case markerPlacement
        case lookUp
        case placement
    }

    /// The picture's four corners in screen space, in a fixed order so the
    /// overlay can anchor each dimension symbol to a specific edge.
    struct ProjectedCorners: Equatable {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint

    }

    static let floorAreaThresholdSquareMeters: Float = 2.0

    /// Touches starting within this many points of the grip begin a resize.
    /// Screen-space proximity, not a 3D hit test — the grip is a 2D overlay, so
    /// the touch target is defined where the user sees it.
    static let resizeHandleTouchRadius: CGFloat = 44

    /// Area must drop below this (not merely below the threshold) before the
    /// scan is considered insufficient again — hysteresis, so a plane anchor
    /// being merged away for one frame doesn't reset the user's progress.
    private static let floorAreaReleaseThreshold: Float = 1.75

    /// Time constant of the low-pass filter applied to the raw measured area.
    /// ARKit's per-frame plane geometry is noisy — extents jump as planes are
    /// extended, merged, and re-fit — so the published progress follows a
    /// smoothed value rather than the raw sum.
    private static let areaSmoothingTimeConstant: Float = 0.6

    /// Hard ceiling on how fast the smoothed area may rise. Without this, the
    /// instant ARKit merges two planes into one large one the measured area can
    /// jump from ~0.3 m² to well past the threshold in a single frame, which is
    /// what made scanning "complete almost instantly" and inaccurately. At this
    /// rate a scan needs at least ~4 s of genuine coverage to reach 2 m².
    private static let maxAreaGrowthSquareMetersPerSecond: Float = 0.5

    /// Area must stay sufficient continuously for this long before the scan
    /// auto-advances — debounces a single noisy frame from completing the scan.
    private static let requiredStableDuration: TimeInterval = 1.25

    /// Floor never completes sooner than this after the scan begins, regardless
    /// of measured area.
    private static let minimumScanDuration: TimeInterval = 3.0

    /// Height above the floor of the *centre* of the hung composition.
    ///
    /// The reference point is correct — gallery convention measures to the
    /// centre of the work, not its top or bottom — but the value was the museum
    /// standard of 57in, which is calibrated to average standing eye level and
    /// hangs noticeably high in a room with furniture. 52in drops the whole
    /// composition ~5in for a more natural domestic height. This is the single
    /// knob for how high pictures hang.
    static let hangingHeightInches: Float = 52

    /// Planes whose centre is within this vertical distance of the lowest
    /// detected surface count as "the floor". Excludes tables, beds, and
    /// counters, which ARKit also reports as horizontal planes and which
    /// previously inflated the scanned area.
    private static let floorClusterHeightToleranceMeters: Float = 0.25

    // MARK: Published state

    @Published private(set) var stage: Stage = .floorScan
    @Published var sessionErrorMessage: String?

    /// Smoothed floor area (m²) — drives the scan progress readout.
    @Published private(set) var scannedAreaSquareMeters: Float = 0
    @Published private(set) var isFloorAreaSufficient = false

    /// True once ≥ 2 m² of floor has been scanned. Gates the screen-space
    /// yellow alignment line (a plain 2D overlay in `ARFlowView` — deliberately
    /// not an AR-anchored entity, so it stays pinned to the vertical centre of
    /// the screen and never drifts with the camera).
    @Published private(set) var showAlignmentLine = false

    /// Whether a floor hit is currently available under the screen centre, i.e.
    /// whether "SET MARKER" has something to capture.
    @Published private(set) var isMarkerLineValid = false

    /// Step 4 — shown briefly right after the picture is anchored, then fades.
    @Published var showMovePicturePrompt = false

    /// Step 5 — the tapped picture. Persists until the user taps elsewhere or
    /// deletes it, and controls the *affordances*: dimension symbols, resize
    /// grip, delete button.
    @Published private(set) var selectedPaintingID: UUID?

    /// The picture being manipulated right now. Set when a drag or resize
    /// begins, cleared the instant it ends, and it alone controls the
    /// **highlight** — which is a genuinely separate visual from the
    /// affordances above. Conflating the two is what made this look unfixable:
    /// selection and active manipulation are different states with different
    /// lifetimes, and they need different visuals.
    @Published private(set) var activePaintingID: UUID?

    /// How many paintings are in the gallery — drives the AR overlay's count
    /// badge and the "add photo" affordance.
    @Published private(set) var paintingCount = 0

    /// Whether a painting is being dragged/resized right now — the highlight,
    /// and only the highlight, is scoped to this.
    var isInteracting: Bool { activePaintingID != nil }

    @Published var widthInches: Int = 24
    @Published var heightInches: Int = 36

    /// The picture's four corners projected into screen space, recomputed every
    /// frame while selected. The dimension symbols anchor their end caps
    /// directly to these, so they stay locked to the picture's real edges at
    /// any viewing angle instead of approximating from separately-computed 3D
    /// midpoints.
    @Published var paintingCorners: ProjectedCorners?

    /// Where the resize grip is drawn — the bottom-right corner of the
    /// picture's *screen-space* bounding box, so it lands on the corner the
    /// user actually sees regardless of size, aspect ratio, or viewing angle.
    @Published var handleScreenPoint: CGPoint?

    // MARK: AR scene references

    weak var arView: ARView?

    private var floorY: Float = 0
    private var floorReferencePoint: SIMD3<Float> = .zero

    /// Every horizontal `ARPlaneAnchor` ARKit is currently tracking, keyed by
    /// identifier. Keyed (rather than appended to an array) because ARKit hands
    /// back re-fitted anchor *instances* on update; replacing by identifier is
    /// what guarantees the area is computed from current geometry instead of a
    /// stale snapshot taken when the plane was first detected.
    private var trackedHorizontalPlanes: [UUID: ARPlaneAnchor] = [:]

    /// Filter/debounce state for the floor scan.
    private var smoothedAreaSquareMeters: Float = 0
    private var areaSufficientSince: Date?
    private var scanStartedAt: Date?
    private var lastScanUpdateTimestamp: TimeInterval?

    private var markerLastMidpoint: SIMD3<Float>?
    private var markerLastDirection: SIMD3<Float>?

    /// The computed wall plane's basis, fixed at "SET MARKER" time. This is
    /// the load-bearing state of the whole app: everything about the placed
    /// painting is expressed relative to these three vectors + origin, never
    /// re-derived from ARKit plane detection.
    private(set) var wallOrigin: SIMD3<Float> = .zero
    private(set) var wallRight: SIMD3<Float> = SIMD3(1, 0, 0)
    private(set) var wallUp: SIMD3<Float> = ARGeometry.worldUp
    private(set) var wallNormal: SIMD3<Float> = SIMD3(0, 0, 1)

    private var wallAnchor: AnchorEntity?
    /// The gallery, in the order the user added the photos. Layout order
    /// follows this order, so the wall composition matches the strip the user
    /// arranged on Screen 3.
    private var paintings: [PaintingModel] = []

    /// One `ModelEntity` per painting, keyed by the painting's id. Entities are
    /// named with that same id string, which is how a hit test on the scene
    /// resolves back to a specific painting.
    private var paintingEntities: [UUID: ModelEntity] = [:]

    private var lookUpTimer: Timer?
    private var movePicturePromptTimer: Timer?
    private var repositionGrabOffset: (x: Float, y: Float)?

    // MARK: Session lifecycle

    static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        // Horizontal (floor) detection only — this is the deliberate design
        // choice the whole app is built around. ARKit's vertical-plane
        // detection is unreliable on plain, low-texture walls; horizontal
        // floor detection is far more consistent, so we detect the floor and
        // *compute* the wall plane ourselves (see `setMarker`).
        config.planeDetection = [.horizontal]
        config.isLightEstimationEnabled = true
        config.environmentTexturing = .automatic
        return config
    }

    func start(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        // Defensive/explicit: `cameraMode: .ar` should default to this, but a
        // black screen instead of camera passthrough is exactly the symptom
        // of the background not being the camera feed, so we set it
        // explicitly rather than relying on the implicit default.
        arView.environment.background = .cameraFeed()

        guard ARWorldTrackingConfiguration.isSupported else {
            sessionErrorMessage = "This device doesn't support ARKit world tracking."
            return
        }
        arView.session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        beginFloorScan()
    }

    func pause() {
        lookUpTimer?.invalidate()
        movePicturePromptTimer?.invalidate()
        arView?.session.pause()
    }

    /// Returns everything to Step 1 — used by "RESCAN" from the
    /// floor-scan, marker-placement, or painting-placement screens.
    func rescan() {
        lookUpTimer?.invalidate()
        movePicturePromptTimer?.invalidate()

        markerLastMidpoint = nil
        markerLastDirection = nil
        isMarkerLineValid = false

        wallAnchor.map { arView?.scene.removeAnchor($0) }
        wallAnchor = nil
        paintingEntities.removeAll()
        selectedPaintingID = nil
        activePaintingID = nil
        showMovePicturePrompt = false
        paintingCorners = nil
        handleScreenPoint = nil

        stage = .floorScan
        beginFloorScan()
        arView?.session.run(Self.makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    /// Clears every piece of floor-scan accumulation state so a new scan starts
    /// from a genuine zero rather than inheriting the previous session's
    /// smoothed area (which is how a rescan could otherwise "complete"
    /// immediately).
    private func beginFloorScan() {
        trackedHorizontalPlanes.removeAll()
        smoothedAreaSquareMeters = 0
        scannedAreaSquareMeters = 0
        isFloorAreaSufficient = false
        showAlignmentLine = false
        areaSufficientSince = nil
        lastScanUpdateTimestamp = nil
        scanStartedAt = Date()
    }

    // MARK: Step 1 — floor scanning

    /// Sum of the true polygon areas of the planes that make up the floor.
    ///
    /// Two things this does that the previous bounding-box version did not:
    /// prefer ARKit's own `.floor` classification (falling back to "everything
    /// near the lowest detected surface") so tables and counters don't count,
    /// and integrate the actual boundary polygon rather than
    /// `extent.width * extent.height`, which over-reports every non-rectangular
    /// plane — often by 30–50% — and was a large part of why scans sometimes
    /// completed far too early.
    private func rawFloorAreaSquareMeters() -> Float {
        let planes = Array(trackedHorizontalPlanes.values)
        guard !planes.isEmpty else { return 0 }

        let classifiedFloor = planes.filter { $0.classification == .floor }
        let floorPlanes: [ARPlaneAnchor]
        if !classifiedFloor.isEmpty {
            floorPlanes = classifiedFloor
        } else {
            guard let lowestY = planes.map({ $0.transform.translation.y }).min() else { return 0 }
            floorPlanes = planes.filter {
                abs($0.transform.translation.y - lowestY) <= Self.floorClusterHeightToleranceMeters
            }
        }

        return floorPlanes.reduce(Float(0)) { $0 + Self.polygonArea(of: $1) }
    }

    /// Shoelace area of a plane's boundary polygon, in the plane's own local
    /// XZ space (which, for a horizontal plane, is metric ground area).
    private static func polygonArea(of plane: ARPlaneAnchor) -> Float {
        let vertices = plane.geometry.boundaryVertices
        guard vertices.count >= 3 else { return 0 }

        var doubleArea: Float = 0
        for index in vertices.indices {
            let current = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            doubleArea += current.x * next.z - next.x * current.z
        }
        return abs(doubleArea) / 2
    }

    /// Called every frame while `stage == .floorScan`. Advances the smoothed
    /// area toward the raw measurement (rate-limited and low-pass filtered),
    /// then auto-advances once the result has been over threshold continuously
    /// for long enough.
    private func updateFloorScanProgress(frame: ARFrame) {
        // Tracking that isn't `.normal` produces wildly unreliable plane
        // geometry — freeze progress rather than feeding that noise into the
        // filter, and require the stability window to start over once tracking
        // recovers.
        guard case .normal = frame.camera.trackingState else {
            areaSufficientSince = nil
            lastScanUpdateTimestamp = frame.timestamp
            return
        }

        let previousTimestamp = lastScanUpdateTimestamp ?? frame.timestamp
        lastScanUpdateTimestamp = frame.timestamp
        // Clamped so a dropped/stalled frame can't produce one huge time step
        // (which would defeat the growth rate limit below).
        let deltaTime = Float(min(max(frame.timestamp - previousTimestamp, 0), 0.1))
        guard deltaTime > 0 else { return }

        let raw = rawFloorAreaSquareMeters()

        let blend = 1 - exp(-deltaTime / Self.areaSmoothingTimeConstant)
        var step = (raw - smoothedAreaSquareMeters) * blend
        let maxRise = Self.maxAreaGrowthSquareMetersPerSecond * deltaTime
        step = min(step, maxRise)
        smoothedAreaSquareMeters = max(0, smoothedAreaSquareMeters + step)
        // The filter only approaches `raw` asymptotically, so a scan that
        // plateaus at barely over the threshold could otherwise creep toward it
        // forever. Once the two are close enough to be indistinguishable, snap.
        if raw > smoothedAreaSquareMeters, raw - smoothedAreaSquareMeters < 0.02 {
            smoothedAreaSquareMeters = raw
        }

        scannedAreaSquareMeters = smoothedAreaSquareMeters
        updateSufficiency()
        checkFloorScanCompletion(rawArea: raw)
    }

    /// Applies the threshold with hysteresis and maintains the "sufficient
    /// since" stopwatch that the completion check debounces against.
    private func updateSufficiency() {
        let sufficient: Bool
        if isFloorAreaSufficient {
            sufficient = smoothedAreaSquareMeters >= Self.floorAreaReleaseThreshold
        } else {
            sufficient = smoothedAreaSquareMeters >= Self.floorAreaThresholdSquareMeters
        }

        if sufficient != isFloorAreaSufficient {
            isFloorAreaSufficient = sufficient
        }
        areaSufficientSince = sufficient ? (areaSufficientSince ?? Date()) : nil

        // The yellow alignment line appears the moment 2 m² is reached and then
        // stays — it isn't re-hidden by momentary dips.
        if sufficient && !showAlignmentLine {
            showAlignmentLine = true
        }
    }

    /// Completion needs all three of: a smoothed area over threshold held
    /// continuously, a raw measurement that still agrees (so the filter's own
    /// momentum can't carry a scan over the line on its own), and a minimum
    /// elapsed scan time.
    private func checkFloorScanCompletion(rawArea: Float) {
        guard stage == .floorScan,
              isFloorAreaSufficient,
              rawArea >= Self.floorAreaThresholdSquareMeters,
              let since = areaSufficientSince,
              let started = scanStartedAt else { return }

        guard Date().timeIntervalSince(since) >= Self.requiredStableDuration,
              Date().timeIntervalSince(started) >= Self.minimumScanDuration else { return }

        captureFloor()
    }

    /// Picks the largest currently-tracked floor plane as the reference floor
    /// and captures its height/position for everything downstream (Step 2's
    /// raycasting switches to using this fixed reference instead of ARKit's
    /// live estimate).
    private func captureFloor() {
        guard let largest = trackedHorizontalPlanes.values.max(by: {
            Self.polygonArea(of: $0) < Self.polygonArea(of: $1)
        }) else { return }

        floorY = largest.transform.translation.y
        floorReferencePoint = largest.transform.translation

        stage = .markerPlacement
    }

    // MARK: Step 2 — marker line geometry

    /// The floor hit point under the screen centre — where the on-screen yellow
    /// line intersects the world. Uses a live ARKit raycast against the
    /// *estimated* horizontal plane before the floor is captured (Step 1, since
    /// there's no fixed reference yet), or ray/plane math against the one
    /// captured, fixed floor reference after (Step 2 — the "don't rely on
    /// ARKit's continued tracking" trick).
    private func currentFloorHitPoint() -> SIMD3<Float>? {
        guard let arView, arView.bounds.width > 0, arView.bounds.height > 0 else { return nil }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

        if stage == .floorScan {
            guard let hit = arView.raycast(from: center, allowing: .estimatedPlane, alignment: .horizontal).first else { return nil }
            return hit.worldTransform.translation
        } else {
            guard let ray = arView.ray(through: center) else { return nil }
            return ARGeometry.intersect(rayOrigin: ray.origin, rayDirection: ray.direction, planePoint: floorReferencePoint, planeNormal: ARGeometry.worldUp)
        }
    }

    /// Derives the current hit point + horizontal "line direction" (the axis the
    /// on-screen yellow line corresponds to in world space, perpendicular to
    /// wherever the camera is currently facing) fresh from the current frame.
    private func computeCurrentLineWorldData() -> (midpoint: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let arView, let camera = arView.session.currentFrame?.camera else { return nil }
        guard let hit = currentFloorHitPoint() else { return nil }

        let cameraForward = -SIMD3<Float>(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z)
        var forwardOnFloor = SIMD3<Float>(cameraForward.x, 0, cameraForward.z)
        if simd_length(forwardOnFloor) < 1e-4 { forwardOnFloor = SIMD3(0, 0, -1) }
        forwardOnFloor = simd_normalize(forwardOnFloor)
        let direction = simd_normalize(SIMD3<Float>(forwardOnFloor.z, 0, -forwardOnFloor.x))
        return (hit, direction)
    }

    /// Per-frame bookkeeping only — no scene changes. The alignment line is a
    /// 2D screen overlay now, so nothing needs to be drawn in the AR scene;
    /// this just keeps a last-known-good world position/direction so a
    /// momentary raycast miss at the instant of the tap doesn't lose the line.
    private func updateMarkerLineCache() {
        guard let data = computeCurrentLineWorldData() else { return }
        markerLastMidpoint = data.midpoint
        markerLastDirection = data.direction
        if !isMarkerLineValid {
            isMarkerLineValid = true
        }
    }

    /// "SET MARKER" — captures the world position/direction currently under the
    /// on-screen yellow line and constructs the computed vertical wall plane
    /// from it, then immediately places the picture on that plane (the picture
    /// existing is *why* the next step asks the user to look up — it doesn't
    /// wait for that prompt to finish).
    func setMarker() {
        guard stage == .markerPlacement else { return }
        guard let arView, let cameraTransform = arView.session.currentFrame?.camera.transform else { return }
        // Fresh read at tap time — not dependent on whatever the per-frame
        // update happened to cache a frame ago — falling back to the cached
        // value only if a fresh raycast momentarily fails (e.g. floor briefly
        // out of frame at the exact instant of the tap).
        guard let data = computeCurrentLineWorldData() ?? cachedMarkerLineWorldData() else { return }

        var right = simd_normalize(data.direction)
        let up = ARGeometry.worldUp
        var normal = simd_normalize(simd_cross(right, up))

        let cameraPosition = cameraTransform.translation
        if simd_dot(normal, cameraPosition - data.midpoint) < 0 {
            // Flip `right` (not `up`) so normal/right/up stay a proper
            // orthonormal, right-handed basis after the flip.
            right = -right
            normal = simd_normalize(simd_cross(right, up))
        }

        wallOrigin = data.midpoint
        wallRight = right
        wallUp = up
        wallNormal = normal
        isMarkerLineValid = false
        showAlignmentLine = false

        placeGallery()

        stage = .lookUp
        scheduleLookUpDismiss()
    }

    private func cachedMarkerLineWorldData() -> (midpoint: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let mid = markerLastMidpoint, let dir = markerLastDirection else { return nil }
        return (mid, dir)
    }

    // MARK: Step 3 — look up prompt

    private func scheduleLookUpDismiss() {
        lookUpTimer?.invalidate()
        lookUpTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advanceToPlacement() }
        }
    }

    /// Called every frame while `stage == .lookUp`; if the device's pitch
    /// indicates the camera is already pointed up at the wall area, dismiss
    /// immediately instead of waiting for the timeout.
    private func checkLookUpPitch() {
        guard let camera = arView?.session.currentFrame?.camera else { return }
        let forward = -SIMD3<Float>(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z)
        if forward.y > 0.35 {
            advanceToPlacement()
        }
    }

    /// The picture was already anchored to the wall inside `setMarker()` —
    /// this just flips the UI stage once the user has tilted up (or the
    /// timeout elapses) so Step 5's tap-to-select/resize interactions unlock.
    private func advanceToPlacement() {
        guard stage == .lookUp else { return }
        lookUpTimer?.invalidate()
        stage = .placement
        showMovePicturePromptTemporarily()
    }

    // MARK: Step 4 — placement + "move picture" prompt

    /// Called once, when the AR flow starts, with the gallery the user
    /// assembled on Screens 2–3. Nothing is placed until `setMarker()` computes
    /// the wall plane, but the models themselves are ready from the start.
    func configure(paintings: [PaintingModel]) {
        self.paintings = paintings
        paintingCount = paintings.count
        syncSelectedDimensions()
    }

    /// Adds already-framed pictures to the gallery mid-session. If the wall
    /// plane has already been set, the whole gallery is immediately re-laid out
    /// and rebuilt so the new pictures are spaced in with the rest rather than
    /// dropped on top of them; otherwise they just join the set awaiting
    /// "SET MARKER".
    ///
    /// Frames are chosen by the user in the add flow before this is called —
    /// nothing here reuses or guesses a frame style.
    func addPaintings(_ newPaintings: [PaintingModel]) {
        guard !newPaintings.isEmpty else { return }
        paintings.append(contentsOf: newPaintings)
        paintingCount = paintings.count

        // One re-layout for the whole batch, not one per photo.
        guard stage == .lookUp || stage == .placement else { return }
        placeGallery()
    }

    private func showMovePicturePromptTemporarily() {
        showMovePicturePrompt = true
        movePicturePromptTimer?.invalidate()
        movePicturePromptTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showMovePicturePrompt = false }
        }
    }

    /// Runs the auto-layout over the whole gallery and rebuilds the wall anchor
    /// with one entity per painting.
    ///
    /// Sizes and positions come from `GalleryLayout`, which spaces the
    /// paintings evenly and wraps them into rows — so adding photos never
    /// stacks them on top of each other, however many there are.
    private func placeGallery() {
        guard let arView, !paintings.isEmpty else { return }

        applyGalleryLayout()

        // Rebuilt from scratch rather than patched: layout can move every
        // painting, so recreating the anchor keeps scene state and model state
        // from drifting apart.
        wallAnchor.map { arView.scene.removeAnchor($0) }
        paintingEntities.removeAll()

        let transform = ARGeometry.makeTransform(origin: wallOrigin, right: wallRight, up: wallUp, normal: wallNormal)
        let anchor = AnchorEntity(world: transform)

        for painting in paintings {
            let entity = makeEntity(for: painting)
            anchor.addChild(entity)
            paintingEntities[painting.id] = entity
        }

        arView.scene.addAnchor(anchor)
        wallAnchor = anchor

        // A painting that was selected before a re-layout keeps its selection,
        // but its projected geometry is now stale.
        if let selectedPaintingID, paintings.contains(where: { $0.id == selectedPaintingID }) {
            updateProjectedGeometry()
        } else {
            select(nil)
        }
    }

    /// Assigns every painting its auto-laid-out size and position. The gallery
    /// is centred horizontally on the marker line and vertically on
    /// `hangingHeightInches` above the captured floor. Since `wallUp` is exactly
    /// world-up, the local Y offset in meters equals the world Y offset directly.
    private func applyGalleryLayout() {
        let hangingHeightMeters = Self.hangingHeightInches * 0.0254
        let centerWorldY = floorY + hangingHeightMeters
        let centerYOffset = centerWorldY - wallOrigin.y

        let placements = GalleryLayout.layout(paintings: paintings)
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })

        for index in paintings.indices {
            guard let placement = byID[paintings[index].id] else { continue }
            paintings[index].widthInches = placement.widthInches
            paintings[index].heightInches = placement.heightInches
            paintings[index].centerOffsetXMeters = placement.offsetXMeters
            paintings[index].centerOffsetYMeters = centerYOffset + placement.offsetYMeters
        }

        syncSelectedDimensions()
    }

    /// Builds one painting's textured quad. The entity is named with the
    /// painting's id so a scene hit test resolves straight back to the model.
    private func makeEntity(for painting: PaintingModel) -> ModelEntity {
        let mesh = MeshResource.generatePlane(width: 1, height: 1)
        var material = UnlitMaterial()
        if let cgImage = painting.framedImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            // Tinted pure white — i.e. not tinted at all, so the texture renders
            // as the exact image the user picked. The session used to multiply
            // this tint by ARKit's ambient colour-temperature estimate to "sit"
            // the picture in the room's lighting; under normal warm indoor light
            // (~2700K) that estimate resolves to RGB(255, 167, 87), which washed
            // every picture in a heavy orange cast.
            material.color = .init(tint: .white, texture: .init(texture))
        } else {
            material.color = .init(tint: .lightGray)
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = painting.id.uuidString
        entity.scale = SIMD3(painting.widthMeters, painting.heightMeters, 1)
        entity.position = SIMD3(painting.centerOffsetXMeters, painting.centerOffsetYMeters, 0.001)
        entity.generateCollisionShapes(recursive: false)
        return entity
    }

    /// Mirrors the selected painting's size into the published inch values the
    /// dimension symbols read.
    private func syncSelectedDimensions() {
        guard let painting = selectedPainting ?? paintings.first else { return }
        widthInches = painting.widthInches
        heightInches = painting.heightInches
    }

    private var selectedPainting: PaintingModel? {
        guard let selectedPaintingID else { return nil }
        return paintings.first { $0.id == selectedPaintingID }
    }

    private var selectedIndex: Int? {
        guard let selectedPaintingID else { return nil }
        return paintings.firstIndex { $0.id == selectedPaintingID }
    }

    /// Resolves a scene hit back to the painting it belongs to.
    private func paintingID(for entity: Entity?) -> UUID? {
        guard let entity else { return nil }
        for candidate in [entity, entity.parent].compactMap({ $0 }) {
            if let id = UUID(uuidString: candidate.name), paintingEntities[id] != nil {
                return id
            }
        }
        return nil
    }

    // MARK: Step 5 — interact, resize, reposition

    /// Selects (or deselects) a picture. Selection shows the affordances and
    /// survives until the user taps elsewhere or deletes the picture — it is
    /// deliberately *not* cleared when a gesture ends.
    private func select(_ id: UUID?) {
        selectedPaintingID = id
        if id != nil {
            syncSelectedDimensions()
            updateProjectedGeometry()
        } else {
            paintingCorners = nil
            handleScreenPoint = nil
        }
    }

    /// A single tap selects whatever picture is under it, or deselects if the
    /// tap missed every picture.
    func selectPainting(atScreenPoint point: CGPoint) {
        select(paintingID(for: entity(at: point)))
    }

    /// Starts a manipulation. Also selects, so dragging a picture that wasn't
    /// selected acts on what's under the finger.
    private func beginInteraction(with id: UUID) {
        select(id)
        activePaintingID = id
    }

    /// Ends the manipulation: the highlight drops the instant the finger lifts.
    /// Selection intentionally survives, so the affordances stay put.
    func endInteraction() {
        activePaintingID = nil
        repositionGrabOffset = nil
    }

    /// Removes a picture from the wall and re-spaces whatever is left, so the
    /// gallery stays evenly laid out after a deletion.
    func deleteSelectedPainting() {
        guard let id = selectedPaintingID else { return }

        paintings.removeAll { $0.id == id }
        paintingCount = paintings.count

        paintingEntities.removeValue(forKey: id)?.removeFromParent()

        // Every piece of state that referred to the deleted picture goes with it.
        select(nil)
        if activePaintingID == id {
            activePaintingID = nil
            repositionGrabOffset = nil
        }

        guard !paintings.isEmpty else {
            wallAnchor.map { arView?.scene.removeAnchor($0) }
            wallAnchor = nil
            return
        }
        placeGallery()
    }

    /// Whether a touch lands on the resize grip — i.e. within reach of the
    /// **selected** picture's bottom-right corner.
    ///
    /// Scoped to the selection on purpose: the grip is only drawn for the
    /// selected picture, so letting an unselected picture's corner start a
    /// resize would mean an invisible target that steals what should have been
    /// a reposition drag.
    func resizeTarget(atScreenPoint point: CGPoint) -> UUID? {
        guard let painting = selectedPainting,
              let corners = projectedCorners(for: painting) else { return nil }

        let corner = corners.bottomRight
        guard hypot(point.x - corner.x, point.y - corner.y) <= Self.resizeHandleTouchRadius else { return nil }
        return painting.id
    }

    /// Starts a resize on the painting whose corner was grabbed.
    func beginResize(paintingID id: UUID) {
        beginInteraction(with: id)
    }

    /// Raycasts a screen point against the *computed* wall plane (never an
    /// ARKit-detected plane, since ARKit was never asked to find this wall).
    func intersectWallPlane(screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let arView, let ray = arView.ray(through: screenPoint) else { return nil }
        return ARGeometry.intersect(rayOrigin: ray.origin, rayDirection: ray.direction, planePoint: wallOrigin, planeNormal: wallNormal)
    }

    /// Converts a world-space point already known to lie on the wall plane
    /// into local (x, y) meters relative to `wallOrigin`.
    func localCoordinates(ofWorldPoint point: SIMD3<Float>) -> (x: Float, y: Float) {
        let delta = point - wallOrigin
        return (simd_dot(delta, wallRight), simd_dot(delta, wallUp))
    }

    /// Call once when a reposition drag begins, so the point under the user's
    /// finger stays under their finger for the rest of the gesture. Returns
    /// whether a painting was actually grabbed.
    @discardableResult
    func beginReposition(atScreenPoint point: CGPoint) -> Bool {
        guard let id = paintingID(for: entity(at: point)) else { return false }
        beginInteraction(with: id)

        guard let painting = selectedPainting, let world = intersectWallPlane(screenPoint: point) else { return false }
        let local = localCoordinates(ofWorldPoint: world)
        repositionGrabOffset = (local.x - painting.centerOffsetXMeters, local.y - painting.centerOffsetYMeters)
        return true
    }

    func continueReposition(atScreenPoint point: CGPoint) {
        guard let grabOffset = repositionGrabOffset, let world = intersectWallPlane(screenPoint: point) else { return }
        repositionPainting(toLocalPoint: localCoordinates(ofWorldPoint: world), grabOffset: grabOffset)
    }

    func continueResize(atScreenPoint point: CGPoint) {
        guard let world = intersectWallPlane(screenPoint: point) else { return }
        resizePainting(toLocalCornerPoint: localCoordinates(ofWorldPoint: world))
    }

    private func repositionPainting(toLocalPoint local: (x: Float, y: Float), grabOffset: (x: Float, y: Float)) {
        guard let index = selectedIndex, let entity = paintingEntities[paintings[index].id] else { return }
        paintings[index].centerOffsetXMeters = local.x - grabOffset.x
        paintings[index].centerOffsetYMeters = local.y - grabOffset.y
        entity.position = SIMD3(paintings[index].centerOffsetXMeters, paintings[index].centerOffsetYMeters, 0.001)
        updateProjectedGeometry()
    }

    /// Resize-via-corner-handle: recomputes width/height from the dragged
    /// corner's local position, snapping to whole inches (never fractional),
    /// keeping the *top-left* corner fixed so the frame grows/shrinks from
    /// the corner the user is actually holding.
    private func resizePainting(toLocalCornerPoint local: (x: Float, y: Float)) {
        guard let index = selectedIndex, let entity = paintingEntities[paintings[index].id] else { return }

        let topLeftX = paintings[index].centerOffsetXMeters - paintings[index].widthMeters / 2
        let topLeftY = paintings[index].centerOffsetYMeters + paintings[index].heightMeters / 2

        let rawWidthMeters = max(0.001, local.x - topLeftX)
        let rawHeightMeters = max(0.001, topLeftY - local.y)

        let newWidthInches = max(GalleryLayout.minimumInches, Int((rawWidthMeters / 0.0254).rounded()))
        let newHeightInches = max(GalleryLayout.minimumInches, Int((rawHeightMeters / 0.0254).rounded()))

        paintings[index].widthInches = newWidthInches
        paintings[index].heightInches = newHeightInches
        paintings[index].centerOffsetXMeters = topLeftX + paintings[index].widthMeters / 2
        paintings[index].centerOffsetYMeters = topLeftY - paintings[index].heightMeters / 2

        entity.scale = SIMD3(paintings[index].widthMeters, paintings[index].heightMeters, 1)
        entity.position = SIMD3(paintings[index].centerOffsetXMeters, paintings[index].centerOffsetYMeters, 0.001)

        widthInches = newWidthInches
        heightInches = newHeightInches
        updateProjectedGeometry()
    }

    /// Projects the picture's four corners into screen space and derives the
    /// resize grip from them. Everything the overlay draws — both dimension
    /// symbols and the grip — comes from this one set of corners, which is what
    /// keeps the symbols' end caps exactly on the picture's edges and the grip
    /// exactly on its bottom-right corner at any size or aspect ratio.
    ///
    /// Called on every resize and reposition update, and every frame while
    /// selected (so everything tracks the camera moving around a stationary
    /// picture too). If any corner fails to project (e.g. briefly behind the
    /// camera) the whole set is cleared together, rather than leaving stale or
    /// wild leftover positions on screen.
    func updateProjectedGeometry() {
        guard let painting = selectedPainting, let corners = projectedCorners(for: painting) else {
            paintingCorners = nil
            handleScreenPoint = nil
            return
        }

        paintingCorners = corners
        // The picture's actual bottom-right corner, straddled by the grip.
        handleScreenPoint = corners.bottomRight
    }

    /// Projects one painting's four corners into the **ARView's** coordinate
    /// space. Every consumer — the dimension symbols, the resize grip, and the
    /// corner hit test — goes through here, so they can never disagree about
    /// where the picture is.
    ///
    /// Note the space: these points are relative to the `ARView`, which fills
    /// the whole screen (it ignores the safe area). Anything drawing them must
    /// be in that same full-screen space; see `SelectionOverlay` in
    /// `ARFlowView`, which is why it carries its own `.ignoresSafeArea()`.
    func projectedCorners(for painting: PaintingModel) -> ProjectedCorners? {
        guard let arView else { return nil }

        let halfWidth = painting.widthMeters / 2
        let halfHeight = painting.heightMeters / 2
        let cx = painting.centerOffsetXMeters
        let cy = painting.centerOffsetYMeters

        let transform = ARGeometry.makeTransform(origin: wallOrigin, right: wallRight, up: wallUp, normal: wallNormal)
        func projectLocal(_ local: SIMD3<Float>) -> CGPoint? {
            let world = transform * SIMD4<Float>(local, 1)
            return arView.project(SIMD3(world.x, world.y, world.z))
        }

        // If any corner fails to project (e.g. briefly behind the camera) the
        // whole set is discarded together, rather than leaving stale or wild
        // leftover positions on screen.
        guard let topLeft = projectLocal(SIMD3(cx - halfWidth, cy + halfHeight, 0.001)),
              let topRight = projectLocal(SIMD3(cx + halfWidth, cy + halfHeight, 0.001)),
              let bottomRight = projectLocal(SIMD3(cx + halfWidth, cy - halfHeight, 0.001)),
              let bottomLeft = projectLocal(SIMD3(cx - halfWidth, cy - halfHeight, 0.001)) else {
            return nil
        }

        return ProjectedCorners(topLeft: topLeft, topRight: topRight, bottomRight: bottomRight, bottomLeft: bottomLeft)
    }

    func entity(at screenPoint: CGPoint) -> Entity? {
        arView?.entity(at: screenPoint)
    }

    // MARK: Capture

    /// Snapshots the AR view (camera feed + placed painting) for sharing.
    /// `ARView.snapshot`'s completion arrives on an arbitrary queue, so the
    /// result is always hopped back to the main actor before it reaches SwiftUI;
    /// if the snapshot fails or the view has no size yet, the view hierarchy is
    /// rendered instead and, failing that, `nil` is reported rather than
    /// force-unwrapping anything.
    @MainActor
    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        guard let arView, arView.bounds.width > 0, arView.bounds.height > 0 else {
            completion(nil)
            return
        }

        arView.snapshot(saveToHDR: false) { image in
            Task { @MainActor in
                if let image, image.size.width > 0, image.size.height > 0 {
                    completion(image)
                } else {
                    completion(Self.renderViewHierarchy(of: arView))
                }
            }
        }
    }

    /// Main-thread-only fallback: draws whatever is currently on screen,
    /// including the SwiftUI overlays layered above the AR view.
    @MainActor
    private static func renderViewHierarchy(of arView: ARView) -> UIImage? {
        let target = arView.window ?? arView
        guard target.bounds.width > 0, target.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: target.bounds)
        return renderer.image { context in
            if !target.drawHierarchy(in: target.bounds, afterScreenUpdates: false) {
                target.layer.render(in: context.cgContext)
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        switch stage {
        case .floorScan:
            updateFloorScanProgress(frame: frame)
            updateMarkerLineCache()
        case .markerPlacement:
            updateMarkerLineCache()
        case .lookUp:
            checkLookUpPitch()
        case .placement:
            // Affordances track the *selected* picture every frame, so they
            // follow the camera moving around a stationary selection too.
            if selectedPaintingID != nil {
                updateProjectedGeometry()
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        storeHorizontalPlanes(from: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        storeHorizontalPlanes(from: anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            trackedHorizontalPlanes.removeValue(forKey: anchor.identifier)
        }
    }

    /// Records the latest instance of each horizontal plane anchor. Area itself
    /// is recomputed on the frame tick rather than here, so the filter advances
    /// on a steady clock instead of at ARKit's irregular anchor-update cadence.
    private func storeHorizontalPlanes(from anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let planeAnchor = anchor as? ARPlaneAnchor else { continue }
            if planeAnchor.alignment == .horizontal {
                trackedHorizontalPlanes[planeAnchor.identifier] = planeAnchor
            } else {
                trackedHorizontalPlanes.removeValue(forKey: planeAnchor.identifier)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionErrorMessage = error.localizedDescription
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sessionErrorMessage = "AR session interrupted."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        sessionErrorMessage = nil
    }

}
