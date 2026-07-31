import SwiftUI
import AVFoundation

/// One captured screenshot, ready to hand to the share sheet.
///
/// The identity is created *once*, at capture time, and stored. The share sheet
/// used to be presented from a computed `Binding` that minted a fresh `UUID`
/// on every read — and because `ARSessionManager` publishes changes on almost
/// every AR frame, that binding re-read constantly, so SwiftUI saw the sheet's
/// item identity change under it and tried to present a new sheet while the
/// previous one was still presenting. That is what crashed the share flow.
struct ShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Everything the AR flow can present modally, as one value.
///
/// Deliberately a single enum driving a single `.sheet(item:)` rather than two
/// separate `.sheet` modifiers on the same view: stacking sheet modifiers makes
/// it possible to ask SwiftUI to present one sheet while another is still
/// presenting, which is the same class of bug that crashed the share flow. One
/// slot means only one sheet can ever be asked for.
enum ARFlowSheet: Identifiable {
    case share(ShareItem)
    case addPicture

    var id: String {
        switch self {
        case .share(let item): return "share-\(item.id)"
        case .addPicture: return "addPicture"
        }
    }
}

/// Drives `ARFlowView` (Screens 4–8): camera permission, starting the AR
/// session, and the share flow. Placement/scan/marker logic itself lives in
/// `ARSessionManager`, which this just owns and exposes.
@MainActor
final class ARFlowViewModel: ObservableObject {
    enum CameraAuthState {
        case unknown
        case authorized
        case denied
    }

    let sessionManager = ARSessionManager()

    @Published var cameraAuthState: CameraAuthState = .unknown
    @Published var hasStartedARSession = false
    @Published var captureFailed = false

    /// The one sheet currently presented over the AR view, if any.
    @Published var activeSheet: ARFlowSheet?

    init(paintings: [PaintingModel]) {
        sessionManager.configure(paintings: paintings)
    }

    /// Adds framed pictures to the gallery mid-session; the wall is re-laid out
    /// so nothing ends up overlapping.
    func addPictures(_ paintings: [PaintingModel]) {
        activeSheet = nil
        sessionManager.addPaintings(paintings)
    }

    func presentAddPicture() {
        guard activeSheet == nil else { return }
        activeSheet = .addPicture
    }

    func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthState = .authorized
            hasStartedARSession = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.cameraAuthState = granted ? .authorized : .denied
                    self?.hasStartedARSession = granted
                }
            }
        default:
            cameraAuthState = .denied
        }
    }

    func rescan() {
        sessionManager.rescan()
    }

    /// Captures the current screen (camera feed + placed painting composited)
    /// and hands it off to the native share sheet, which offers "Save Image"
    /// (Photos) and every other standard share destination. A capture already
    /// in flight is ignored rather than stacking a second presentation.
    func capture() {
        guard activeSheet == nil else { return }
        sessionManager.capturePhoto { [weak self] image in
            guard let self else { return }
            if let image {
                self.activeSheet = .share(ShareItem(image: image))
            } else {
                self.captureFailed = true
            }
        }
    }
}
