import SwiftUI

/// Shows `SplashView` first, then cross-fades into `HomeView` shortly after
/// launch — the app's own animated splash, layered on top of (and replacing)
/// the brief, static system launch screen.
struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            HomeView()

            if showSplash {
                SplashView()
                    .transition(.opacity)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    showSplash = false
                }
            }
        }
    }
}

#Preview {
    RootView()
}
