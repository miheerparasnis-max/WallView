import SwiftUI
import UIKit

/// Hosts the AR flow's steps: the "Scan the Floor" instruction, live floor
/// scanning, yellow-line alignment, the look-up prompt, and finally painting
/// placement/select/resize. One `ARSessionManager`/`ARView` persists across all
/// of these; only the SwiftUI overlay switches, driven by `sessionManager.stage`.
struct ARFlowView: View {
    @StateObject private var viewModel: ARFlowViewModel
    // `ARSessionManager` is a plain (non-`@Published`) property of
    // `ARFlowViewModel`, so observing only `viewModel` does NOT re-render
    // this view when `sessionManager`'s own `@Published` properties (like
    // `stage`) change — SwiftUI doesn't bubble up nested ObservableObjects.
    // That was the actual bug behind the AR view getting stuck showing
    // Step 1's UI forever after `stage` had already advanced past it.
    @ObservedObject private var sessionManager: ARSessionManager
    @Environment(\.dismiss) private var dismiss

    init(paintings: [PaintingModel]) {
        let model = ARFlowViewModel(paintings: paintings)
        _viewModel = StateObject(wrappedValue: model)
        _sessionManager = ObservedObject(wrappedValue: model.sessionManager)
    }

    var body: some View {
        Group {
            if viewModel.cameraAuthState == .denied {
                CameraPermissionDeniedView()
            } else if viewModel.hasStartedARSession {
                arContent
            } else {
                ScanFloorInstructionView { viewModel.requestCameraAndStart() }
            }
        }
        .navigationBarBackButtonHidden(true)
        .onDisappear { viewModel.sessionManager.pause() }
    }

    private var arContent: some View {
        ZStack {
            // Clean camera passthrough — no scan panels, no AR-anchored marker
            // geometry. Everything the user sees during scanning is 2D overlay.
            ARViewContainer(sessionManager: sessionManager)
                .ignoresSafeArea()

            // The yellow alignment line: a plain 2D rectangle pinned to the
            // vertical centre of the screen, shown only once 2 m² of floor has
            // been scanned. Deliberately *not* an AR entity — it must stay
            // exactly at screen centre and never move with the camera.
            if sessionManager.showAlignmentLine {
                AlignmentLine()
            }

            // Drawn here, as a sibling of the ARView rather than inside
            // `PlacementOverlay`, and with its own `.ignoresSafeArea()` so its
            // coordinate space matches the ARView's exactly. `arView.project()`
            // returns points relative to the full screen; the stage overlays are
            // laid out inside the safe area, so drawing projected points there
            // shifted every symbol and the grip by the safe-area inset.
            SelectionOverlay(sessionManager: sessionManager)
                .ignoresSafeArea()

            if let error = sessionManager.sessionErrorMessage {
                ARErrorBanner(message: error)
            } else {
                switch sessionManager.stage {
                case .floorScan:
                    FloorScanOverlay(sessionManager: sessionManager, onBack: { dismiss() })
                case .markerPlacement:
                    MarkerPlacementOverlay(viewModel: viewModel, sessionManager: sessionManager, onBack: { dismiss() })
                case .lookUp:
                    LookUpOverlay()
                case .placement:
                    PlacementOverlay(viewModel: viewModel, sessionManager: sessionManager, onBack: { dismiss() })
                }
            }
        }
        // One sheet slot, presented from stored state with a stable identity —
        // see `ARFlowSheet`.
        .sheet(item: $viewModel.activeSheet) { sheet in
            switch sheet {
            case .share(let item):
                ShareSheet(image: item.image)
            case .addPicture:
                AddPictureFlow(
                    onCancel: { viewModel.activeSheet = nil },
                    onFinish: { viewModel.addPictures($0) }
                )
            }
        }
        .alert("Couldn't capture the screen", isPresented: $viewModel.captureFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}

// MARK: - The yellow alignment line

/// A fixed, screen-space horizontal line at the vertical centre of the display.
/// Pure UI: no world anchoring, no projection, so device rotation/movement in
/// AR space leaves it exactly where it is.
private struct AlignmentLine: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.yellow)
                .frame(maxWidth: .infinity)
                .frame(height: 4)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Step 0: instruction

private struct ScanFloorInstructionView: View {
    let onStart: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("1. Scan the Floor - Slowly move your phone to scan the floor.")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button(action: onStart) {
                    Text("Start")
                        .font(.headline)
                        .frame(width: 200)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 16)
            }
        }
    }
}

// MARK: - Step 1: floor scan

private struct FloorScanOverlay: View {
    @ObservedObject var sessionManager: ARSessionManager
    let onBack: () -> Void

    var body: some View {
        VStack {
            HStack {
                BackButton(action: onBack)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.leading, 12)

            // Minimal progress indicator only — the camera view itself stays a
            // clean passthrough during scanning.
            VStack(spacing: 8) {
                Text(sessionManager.isFloorAreaSufficient ? "Floor scanned — hold still" : "Slowly move your phone to scan the floor.")
                    .font(.subheadline.bold())
                Text(String(format: "%.1f / %.1f m² scanned", sessionManager.scannedAreaSquareMeters, ARSessionManager.floorAreaThresholdSquareMeters))
                    .font(.caption.monospacedDigit())
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 4)

            Spacer()

            HStack {
                Spacer()
                Button {
                    sessionManager.rescan()
                } label: {
                    Text("RESCAN")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(.trailing, 12)
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Step 2: place marker

private struct MarkerPlacementOverlay: View {
    let viewModel: ARFlowViewModel
    @ObservedObject var sessionManager: ARSessionManager
    let onBack: () -> Void

    var body: some View {
        VStack {
            HStack {
                BackButton(action: onBack)
                Spacer()
                ShareButton { viewModel.capture() }
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)

            Text(sessionManager.paintingCount > 1
                 ? "Align the yellow line at the bottom of the wall, then press SET MARKER to lay out your \(sessionManager.paintingCount) photos"
                 : "Align the yellow line at the bottom of the wall, then press SET MARKER")
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)

            Spacer()

            HStack {
                Spacer()

                Button {
                    sessionManager.setMarker()
                } label: {
                    Text("SET MARKER")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                // Always tappable — never gated behind a condition that could
                // get stuck false. `setMarker()` handles the "no valid marker
                // data yet" case itself, so this is a soft hint only.
                .opacity(sessionManager.isMarkerLineValid ? 1 : 0.5)

                Spacer()

                Button {
                    viewModel.rescan()
                } label: {
                    Text("RESCAN")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(.trailing, 12)
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Step 3: look up

private struct LookUpOverlay: View {
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.up")
                .font(.system(size: 40, weight: .bold))
                .offset(y: bounce ? -10 : 0)
            Text("LOOK UP")
                .font(.title.bold())
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                bounce = true
            }
        }
    }
}

// MARK: - Step 4 / 5: placement, move-picture prompt, select + resize

private struct PlacementOverlay: View {
    let viewModel: ARFlowViewModel
    @ObservedObject var sessionManager: ARSessionManager
    let onBack: () -> Void

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    BackButton(action: onBack)
                    Spacer()
                    GalleryCountBadge(count: sessionManager.paintingCount)
                    Spacer()
                    AddPhotoButton { viewModel.presentAddPicture() }
                    ShareButton { viewModel.capture() }
                }
                .padding(.top, 8)
                .padding(.horizontal, 12)

                if sessionManager.showMovePicturePrompt {
                    Text(sessionManager.paintingCount > 1
                         ? "Tap a picture to select it, drag to reposition"
                         : "Move Picture — position the picture on your wall")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                Spacer()

                HStack {
                    Spacer()
                    Button {
                        viewModel.rescan()
                    } label: {
                        Text("RESCAN")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.trailing, 12)
                }
                .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sessionManager.showMovePicturePrompt)
    }
}

// MARK: - Adding a picture from inside AR

/// The in-AR "+" flow: pick photos, then choose each one's frame, then hand
/// finished `PaintingModel`s back to be placed.
///
/// Both steps live inside the *same* sheet, swapped by local state rather than
/// presented as two sheets in sequence. Chaining two presentations through one
/// sheet slot means asking SwiftUI to dismiss and re-present in the same
/// update, which is the flaky pattern this file has been bitten by before.
private struct AddPictureFlow: View {
    let onCancel: () -> Void
    let onFinish: ([PaintingModel]) -> Void

    @State private var photos: [GalleryPhoto] = []

    var body: some View {
        if photos.isEmpty {
            PhotoPickerView { images in
                // An empty result means the picker was cancelled.
                guard !images.isEmpty else {
                    onCancel()
                    return
                }
                photos = images.map { GalleryPhoto(image: $0) }
            }
        } else {
            // No NavigationStack: the frame picker draws its own header and
            // pushes nothing, so wrapping it would only add an empty nav bar.
            SelectFrameView(photos: photos, confirmTitle: "ADD TO WALL") { paintings in
                onFinish(paintings)
            }
        }
    }
}

// MARK: - Selection overlay

/// The selected picture's affordances — dimension symbols, resize grip, delete
/// button — plus, separately, the highlight shown only while it is actually
/// being dragged or resized.
///
/// The two are deliberately different visuals with different lifetimes:
/// selection persists after a tap, the highlight lasts exactly as long as the
/// gesture.
///
/// Lives in the ARView's coordinate space (hence `.ignoresSafeArea()` at the
/// call site): every point it draws comes from `arView.project()`, which is
/// relative to the full screen. Laying this out inside the safe area — which is
/// what happened when it was part of `PlacementOverlay` — offset everything it
/// draws by the safe-area inset: downward in portrait, sideways in landscape.
private struct SelectionOverlay: View {
    @ObservedObject var sessionManager: ARSessionManager

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Pins the ZStack's own origin to the screen's top-left, so
            // `.position` and the shapes' absolute coordinates are both
            // measured from the same origin `arView.project()` uses.
            Color.clear
                .allowsHitTesting(false)

            if let corners = sessionManager.paintingCorners {
                Group {
                    // The highlight — and nothing else here — is scoped to an
                    // active drag/resize.
                    if sessionManager.isInteracting {
                        PaintingHighlight(corners: corners)
                    }

                    // Height: flush along the picture's right edge, end caps
                    // exactly on the top and bottom edges.
                    DimensionSymbol(
                        start: corners.topRight,
                        end: corners.bottomRight,
                        text: "\(sessionManager.heightInches) in"
                    )

                    // Width: flush along the picture's bottom edge, end caps
                    // exactly on the left and right edges.
                    DimensionSymbol(
                        start: corners.bottomLeft,
                        end: corners.bottomRight,
                        text: "\(sessionManager.widthInches) in"
                    )

                    if let point = sessionManager.handleScreenPoint {
                        ResizeGrip()
                            // Centred on the corner, so the circle straddles it —
                            // half over the picture, half outside.
                            .position(point)
                    }
                }
                .allowsHitTesting(false)

                // The one interactive element in this layer; everything else
                // stays transparent to touches so the ARView keeps receiving
                // its own tap/pan gestures.
                DeleteButton { sessionManager.deleteSelectedPainting() }
                    .position(corners.topLeft)
            }
        }
    }
}

/// The highlight: an accent-coloured outline tracing the picture's actual
/// projected quad, shown only while it is being dragged or resized.
private struct PaintingHighlight: View {
    let corners: ARSessionManager.ProjectedCorners

    var body: some View {
        QuadShape(corners: corners)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
            .shadow(color: Color.accentColor.opacity(0.8), radius: 6)
            .background(
                QuadShape(corners: corners)
                    .fill(Color.accentColor.opacity(0.12))
            )
    }
}

private struct QuadShape: Shape {
    let corners: ARSessionManager.ProjectedCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: corners.topLeft)
        path.addLine(to: corners.topRight)
        path.addLine(to: corners.bottomRight)
        path.addLine(to: corners.bottomLeft)
        path.closeSubpath()
        return path
    }
}

/// Removes the selected picture from the wall. Sits on the picture's top-left
/// corner — the one corner neither dimension symbol nor the resize grip uses.
private struct DeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash.fill")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.red, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(radius: 3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dimension symbols

/// A standard dimension indicator: a double-headed arrow running between two
/// perpendicular end caps, with the measurement centred on it.
///
/// `start`/`end` are the two picture corners the symbol measures between, and
/// the symbol is drawn directly on the line between them — flush against that
/// edge of the picture, with the end caps landing exactly on its corners. It
/// used to be pushed 34 points outward from the picture's centre, which is what
/// left the symbols floating off to the side instead of against the artwork.
private struct DimensionSymbol: View {
    let start: CGPoint
    let end: CGPoint
    let text: String

    private let capLength: CGFloat = 16
    private let arrowLength: CGFloat = 9

    var body: some View {
        let axis = normalized(CGPoint(x: end.x - start.x, y: end.y - start.y))
        // Perpendicular to the measured edge — the direction the end caps and
        // arrowheads spread along. Which of the two perpendiculars this is
        // doesn't matter: both are drawn symmetrically about the edge.
        let normal = CGPoint(x: -axis.y, y: axis.x)
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

        ZStack {
            DimensionShape(start: start, end: end, axis: axis, normal: normal, capLength: capLength, arrowLength: arrowLength)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.6), radius: 2)

            // Centred exactly between the two end caps. The chip's opaque
            // backing breaks the arrow line behind it, which is what makes the
            // number readable over the shaft.
            Text(text)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.75), in: Capsule())
                .position(midpoint)
        }
        .allowsHitTesting(false)
    }

    private func normalized(_ vector: CGPoint) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        guard length > 0.0001 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }
}

/// The line work of a dimension symbol: shaft, both perpendicular end caps, and
/// an arrowhead at each end pointing outward toward its cap.
private struct DimensionShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let axis: CGPoint
    let normal: CGPoint
    let capLength: CGFloat
    let arrowLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: start)
        path.addLine(to: end)

        for point in [start, end] {
            path.move(to: CGPoint(x: point.x - normal.x * capLength / 2, y: point.y - normal.y * capLength / 2))
            path.addLine(to: CGPoint(x: point.x + normal.x * capLength / 2, y: point.y + normal.y * capLength / 2))
        }

        // `axis` runs start → end, so the head at `start` points back along it
        // and the head at `end` points forward along it.
        addArrowhead(to: &path, at: start, direction: CGPoint(x: -axis.x, y: -axis.y))
        addArrowhead(to: &path, at: end, direction: axis)

        return path
    }

    private func addArrowhead(to path: inout Path, at tip: CGPoint, direction: CGPoint) {
        let base = CGPoint(x: tip.x - direction.x * arrowLength, y: tip.y - direction.y * arrowLength)
        let spread = arrowLength * 0.45
        path.move(to: CGPoint(x: base.x + normal.x * spread, y: base.y + normal.y * spread))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: base.x - normal.x * spread, y: base.y - normal.y * spread))
    }
}

/// The corner resize grip.
private struct ResizeGrip: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption.bold())
            .foregroundStyle(.black)
            .frame(width: 30, height: 30)
            .background(.white, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 1))
            .shadow(radius: 2)
    }
}

// MARK: - Shared pieces

private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.45), in: Circle())
        }
    }
}

/// Opens the photo picker over the live AR session so photos can be added to
/// the gallery without leaving AR.
private struct AddPhotoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.45), in: Circle())
        }
    }
}

/// How many photos are currently on the wall — the only feedback that an added
/// photo actually joined the gallery when it lands off-screen.
private struct GalleryCountBadge: View {
    let count: Int

    var body: some View {
        if count > 1 {
            Label("\(count)", systemImage: "photo.on.rectangle.angled")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
        }
    }
}

private struct ShareButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.45), in: Circle())
        }
    }
}

private struct ARErrorBanner: View {
    let message: String

    var body: some View {
        VStack {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.bold())
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.red)
                .padding()
            Spacer()
        }
    }
}

private struct CameraPermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Camera Access Needed")
                .font(.title2.bold())
            Text("WallView needs your camera to scan your room and place the painting in AR. Enable camera access in Settings to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings").font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

/// The native iOS share sheet, carrying exactly one captured image.
private struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // Required on iPad, where an activity controller presented as a popover
        // with no source view raises instead of presenting.
        if let popover = uiViewController.popoverPresentationController, popover.sourceView == nil {
            let host = uiViewController.view
            popover.sourceView = host
            popover.sourceRect = CGRect(x: (host?.bounds.midX ?? 0), y: (host?.bounds.midY ?? 0), width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }
}
