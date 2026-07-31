import SwiftUI

/// Renders the whole frame catalog for one photo off the main thread.
///
/// The grid previously composited each thumbnail synchronously inside the cell
/// body, so scrolling into fresh cells did Core Graphics work mid-scroll — that
/// is what made the grid feel choppy, not the scroll view's configuration. Here
/// the source photo is downscaled once, every style is composited on a
/// background task, and results are published in batches, so the grid itself
/// only ever reads finished images.
@MainActor
final class FrameThumbnailStore: ObservableObject {
    @Published private(set) var thumbnails: [String: UIImage] = [:]

    private var loadedPhotoID: UUID?
    private var task: Task<Void, Never>?


    func prepare(photo: GalleryPhoto, styles: [FrameStyle]) {
        guard loadedPhotoID != photo.id else { return }
        loadedPhotoID = photo.id

        task?.cancel()
        thumbnails = [:]

        let image = photo.image
        task = Task { [weak self] in
            // Rendered at a longest edge comfortably above the ~150pt cells at
            // 3x so they stay crisp, but small enough to composite quickly.
            let renderSize: CGFloat = 420
            let base = await Task.detached(priority: .userInitiated) {
                FrameCompositor.downscaled(image, maxDimension: renderSize)
            }.value

            var batch: [String: UIImage] = [:]
            for style in styles {
                if Task.isCancelled { return }
                let rendered = await Task.detached(priority: .userInitiated) {
                    FrameCompositor.composite(image: base, style: style)
                }.value
                batch[style.id] = rendered

                // Published in batches so the grid fills in progressively
                // instead of staying empty until the whole catalog is done.
                if batch.count % 8 == 0 {
                    self?.merge(batch)
                }
            }
            if Task.isCancelled { return }
            self?.merge(batch)
        }
    }

    private func merge(_ batch: [String: UIImage]) {
        thumbnails.merge(batch) { _, new in new }
    }
}

/// Screen 3 — assign a frame to each photo in the gallery. The catalog is far
/// too large for a carousel, so it's a single scrolling page: the gallery strip,
/// a live preview of the photo being framed, category filter chips, and a roomy
/// grid of the catalog. One vertical scroll view for the whole page (the strip
/// and chips scroll horizontally, so no two scroll views ever compete for the
/// same axis), with the primary action pinned below it.
struct SelectFrameView: View {
    let photos: [GalleryPhoto]
    /// Overridden by the in-AR add flow, where the wall already exists and the
    /// action is "add to it" rather than "go view it".
    var confirmTitle: String?
    var onViewInRoom: ([PaintingModel]) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbnails = FrameThumbnailStore()

    /// The frame chosen for each photo, keyed by photo id.
    @State private var frames: [UUID: FrameStyle] = [:]
    @State private var editingPhotoID: UUID?
    @State private var category: FrameCategory?

    private var editingPhoto: GalleryPhoto? {
        photos.first { $0.id == editingPhotoID } ?? photos.first
    }

    private var selectedStyle: FrameStyle {
        guard let editingPhoto else { return .unframed }
        return frames[editingPhoto.id] ?? .unframed
    }

    private var visibleStyles: [FrameStyle] {
        FrameStyle.styles(in: category)
    }

    /// Two columns on a phone, more on wider screens. The 150pt minimum is what
    /// gives each frame enough room to actually be judged.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 28) {
                    if photos.count > 1 {
                        photoStrip
                    }
                    preview
                    categoryChips
                    grid
                }
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .safeAreaInset(edge: .bottom) { viewInRoomBar }
        .background(Color(red: 0.95, green: 0.95, blue: 0.95).ignoresSafeArea())
        // Forced light appearance: a black-bordered frame preview against a
        // dark, system-dark-mode background was indistinguishable ("black on
        // black"). This screen's whole job is showing frame color accurately.
        .environment(\.colorScheme, .light)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            if editingPhotoID == nil { editingPhotoID = photos.first?.id }
            if let photo = editingPhoto {
                thumbnails.prepare(photo: photo, styles: FrameStyle.all)
            }
        }
        .onChange(of: editingPhotoID) { _, _ in
            if let photo = editingPhoto {
                thumbnails.prepare(photo: photo, styles: FrameStyle.all)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.bold())
                    .frame(width: 40, height: 40)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)

            Text("Choose a Frame")
                .font(.title2.bold())

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The gallery. Each thumbnail shows the photo in its currently-assigned
    /// frame, so the whole composition stays visible while framing any one.
    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR PHOTOS")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(photos) { photo in
                        Button {
                            editingPhotoID = photo.id
                        } label: {
                            Image(uiImage: photo.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(photo.id == editingPhoto?.id ? Color.accentColor : Color.black.opacity(0.12),
                                                lineWidth: photo.id == editingPhoto?.id ? 3 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 3)
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            if let editingPhoto {
                Image(uiImage: FrameCompositor.thumbnail(
                    image: editingPhoto.image,
                    style: selectedStyle,
                    sourceKey: editingPhoto.id.uuidString,
                    maxDimension: 900
                ))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 240)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
            }

            VStack(spacing: 3) {
                Text(selectedStyle.profileName)
                    .font(.headline)
                if !selectedStyle.finishName.isEmpty {
                    Text(selectedStyle.finishName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.default, value: selectedStyle)
        }
        .padding(.horizontal, 32)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip(title: "All", isSelected: category == nil) { category = nil }
                ForEach(FrameCategory.allCases) { item in
                    chip(title: item.displayName, isSelected: category == item) { category = item }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 3)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentColor : Color.white, in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(visibleStyles) { style in
                Button {
                    if let editingPhoto {
                        frames[editingPhoto.id] = style
                    }
                } label: {
                    FrameSwatch(
                        image: thumbnails.thumbnails[style.id],
                        style: style,
                        isSelected: style == selectedStyle
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var viewInRoomBar: some View {
        Button {
            let paintings = photos.map { photo in
                PaintingModel(id: photo.id, sourceImage: photo.image, frameStyle: frames[photo.id] ?? .unframed)
            }
            onViewInRoom(paintings)
        } label: {
            Text(confirmTitle ?? (photos.count > 1 ? "VIEW GALLERY IN ROOM" : "VIEW IN ROOM"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct FrameSwatch: View {
    /// `nil` while the background render is still catching up.
    let image: UIImage?
    let style: FrameStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 2) {
                Text(style.profileName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text(style.finishName.isEmpty ? "Unframed" : style.finishName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, 4)
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.07), lineWidth: isSelected ? 3 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.12 : 0.05), radius: isSelected ? 8 : 4, y: 2)
    }
}
