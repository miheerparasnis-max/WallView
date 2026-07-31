import SwiftUI

/// The app's animated splash: the logo lockup on a light neutral background,
/// shown for a beat on launch and then cross-faded into `HomeView` by
/// `RootView`. Kept as its own view since it's also handy for previewing the
/// artwork in isolation.
struct SplashView: View {
    var body: some View {
        Image("LaunchLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.95, green: 0.95, blue: 0.95))
            .ignoresSafeArea()
    }
}

#Preview {
    SplashView()
}
