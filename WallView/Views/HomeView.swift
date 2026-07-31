import SwiftUI

/// Screen 1 — a single "TEST PICTURE" button. Owns the navigation stack for
/// the whole flow.
struct HomeView: View {
    @State private var path: [Route] = []

    private enum Route: Hashable {
        case selectImage
        case selectFrame(PhotosPayload)
        case arFlow(GalleryPayload)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .selectImage:
                        SelectImageView { photos in
                            path.append(.selectFrame(PhotosPayload(photos: photos)))
                        }
                    case .selectFrame(let payload):
                        SelectFrameView(photos: payload.photos) { paintings in
                            path.append(.arFlow(GalleryPayload(paintings: paintings)))
                        }
                    case .arFlow(let payload):
                        ARFlowView(paintings: payload.paintings)
                    }
                }
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text("WallView")
                    .font(.largeTitle.bold())
                Text("See your art on your wall before you hang it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                path.append(.selectImage)
            } label: {
                HomeActionCard(title: "TEST PICTURE", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 48)

            Spacer()
        }
    }
}

private struct HomeActionCard: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding()
        .foregroundStyle(.white)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// `UIImage`/`PaintingModel` aren't `Hashable`, so these thin wrappers (keyed
/// by a fresh `UUID`) give `NavigationStack`'s path something `Hashable` to
/// store without needing image content equality.
private struct PhotosPayload: Hashable {
    let id = UUID()
    let photos: [GalleryPhoto]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct GalleryPayload: Hashable {
    let id = UUID()
    let paintings: [PaintingModel]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    HomeView()
}
