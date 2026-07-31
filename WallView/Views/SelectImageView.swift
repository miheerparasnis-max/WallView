import SwiftUI
import PhotosUI

/// Screen 2 — assemble the gallery. Photos are staged here as thumbnails rather
/// than shooting straight through to the frame picker on the first pick, so the
/// set can be built up from the library and the camera together, reviewed, and
/// trimmed before going any further.
///
/// Uses Apple's native `PHPickerViewController` for the library rather than a
/// hand-rolled grid: it renders the system's own (correct, non-overlapping)
/// photo grid, needs no explicit Photos permission prompt (it runs
/// out-of-process and only grants the app the specific items the user picks),
/// and is far more reliable than reimplementing thumbnail loading ourselves.
///
/// Layout note: exactly one vertical scroll view owns the page, with the
/// primary action pinned beneath it via `safeAreaInset`. Nothing vertically
/// scrollable is nested inside anything else vertically scrollable, which is
/// what keeps the scrolling smooth as the staged grid grows.
struct SelectImageView: View {
    var onSelect: ([GalleryPhoto]) -> Void

    @State private var staged: [GalleryPhoto] = []
    @State private var showLibraryPicker = false
    @State private var showCamera = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                intro
                sourceButtons
                if !staged.isEmpty {
                    stagedGallery
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Your Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !staged.isEmpty { continueBar }
        }
        .sheet(isPresented: $showLibraryPicker) {
            PhotoPickerView { images in
                showLibraryPicker = false
                stage(images)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                if let image { stage([image]) }
            }
            .ignoresSafeArea()
        }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text(staged.isEmpty ? "Add your paintings" : "\(staged.count) photo\(staged.count == 1 ? "" : "s") added")
                    .font(.title2.bold())
                Text(staged.isEmpty
                     ? "Pick as many as you like — they'll be laid out as a gallery on your wall."
                     : "Add more, or continue to choose frames.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
        }
        .padding(.top, 8)
    }

    private var sourceButtons: some View {
        VStack(spacing: 14) {
            Button {
                showLibraryPicker = true
            } label: {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
    }

    private var stagedGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("IN YOUR GALLERY")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(staged) { photo in
                    Image(uiImage: photo.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 104)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                remove(photo)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.55))
                                    .padding(5)
                            }
                            .buttonStyle(.plain)
                        }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var continueBar: some View {
        Button {
            onSelect(staged)
        } label: {
            Text("CONTINUE")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func stage(_ images: [UIImage]) {
        staged.append(contentsOf: images.map { GalleryPhoto(image: $0) })
    }

    private func remove(_ photo: GalleryPhoto) {
        staged.removeAll { $0.id == photo.id }
    }
}

/// Wraps `PHPickerViewController` — the system's own photo grid UI. The
/// picker itself hands back `PHPickerResult`s; loading them as `UIImage`s
/// happens on the item providers' own queues, then we hop back to main. Shared
/// with the AR flow's "add photo" button.
struct PhotoPickerView: UIViewControllerRepresentable {
    var onPick: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        // 0 means no limit — the gallery takes as many photos as the user wants.
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([UIImage]) -> Void

        init(onPick: @escaping ([UIImage]) -> Void) {
            self.onPick = onPick
        }

        /// Each result loads on its own queue and finishes in an arbitrary
        /// order, so results are collected into a fixed-size, index-keyed slot
        /// array. That preserves the order the user picked them in — which is
        /// the order the gallery is laid out in — and a dispatch group fires
        /// the callback once, after every load has settled.
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Deliberately does NOT call `picker.dismiss` — presentation is
            // owned by the SwiftUI binding that presented this picker, and
            // dismissing behind that binding's back leaves it stuck set, so the
            // picker could never be presented a second time. The callback below
            // always fires (including for a cancel, with an empty array), and
            // clearing the binding is what dismisses it.
            let providers = results.map(\.itemProvider)
            guard !providers.isEmpty else {
                onPick([])
                return
            }

            var slots = [UIImage?](repeating: nil, count: providers.count)
            let lock = NSLock()
            let group = DispatchGroup()

            for (index, provider) in providers.enumerated() {
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        lock.lock()
                        slots[index] = image
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) { [onPick] in
                onPick(slots.compactMap { $0 })
            }
        }
    }
}

/// Thin UIKit bridge for `UIImagePickerController` in camera mode — SwiftUI
/// has no native camera-capture view, and `PHPickerViewController` only picks
/// existing photos.
struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        let dismiss: () -> Void

        init(onCapture: @escaping (UIImage?) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            dismiss()
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
            onCapture(nil)
        }
    }
}
