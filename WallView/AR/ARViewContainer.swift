import SwiftUI
import ARKit
import RealityKit

/// SwiftUI bridge to RealityKit's `ARView` for the whole AR flow (Screens
/// 4–8). One `ARView`/`ARSessionManager` persists across the floor-scan →
/// marker-placement → look-up → painting-placement stages; only the SwiftUI
/// overlay changes per stage, driven by `sessionManager.stage`.
struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        sessionManager.start(arView: arView)

        // Tap and pan are independent recognizers with no dependency between
        // them: a stationary tap never satisfies the pan's slop threshold, and
        // a drag never fires the tap, so neither needs `require(toFail:)` and
        // selection never waits on a gesture that may not happen.
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapRecognizer)

        let panRecognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panRecognizer)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager)
    }

    final class Coordinator: NSObject {
        let sessionManager: ARSessionManager

        private enum DragMode {
            case none, resize, reposition
        }
        private var dragMode: DragMode = .none

        init(sessionManager: ARSessionManager) {
            self.sessionManager = sessionManager
        }

        /// Step 5: a single tap selects the picture under it — immediately
        /// showing its dimension symbols, resize grip, and delete button — or
        /// deselects when the tap lands on empty space. No press-and-hold: a
        /// tap that lands on the resize grip is ignored rather than treated as
        /// a miss, so a slightly-off tap can't dismiss what it was aiming at.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard sessionManager.stage == .placement, let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            if sessionManager.resizeTarget(atScreenPoint: point) != nil { return }
            sessionManager.selectPainting(atScreenPoint: point)
        }

        /// Step 5: single-finger drag either resizes (when starting on the
        /// corner grip, which only exists once selected) or repositions
        /// (anywhere else on the painting — reposition works immediately,
        /// without needing to select first). Pinch is intentionally not
        /// wired up for resize, per the reference app's fix for
        /// accidental-resize complaints — the corner grip is the only way
        /// to resize.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard sessionManager.stage == .placement, let view = recognizer.view else { return }
            let point = recognizer.location(in: view)

            switch recognizer.state {
            case .began:
                // Corner first: a touch near a picture's bottom-right corner
                // resizes, anything else on the picture repositions.
                if let id = sessionManager.resizeTarget(atScreenPoint: point) {
                    dragMode = .resize
                    sessionManager.beginResize(paintingID: id)
                } else if sessionManager.beginReposition(atScreenPoint: point) {
                    dragMode = .reposition
                } else {
                    dragMode = .none
                }

            case .changed:
                switch dragMode {
                case .resize:
                    sessionManager.continueResize(atScreenPoint: point)
                case .reposition:
                    sessionManager.continueReposition(atScreenPoint: point)
                case .none:
                    break
                }

            case .ended, .cancelled, .failed:
                // The highlight is scoped to the gesture, so lifting the finger
                // returns the picture to its normal appearance immediately.
                if dragMode != .none {
                    sessionManager.endInteraction()
                }
                dragMode = .none

            default:
                break
            }
        }
    }
}
