import SwiftUI
import UIKit

/// The three-page welcome flow.
///
/// Pages one and two introduce the app and share one bottom bar — the dots and the Next button live
/// here rather than inside each page so the dots always know where the flow is. The last page is the
/// sign-in page, which brings its own buttons, so the bar steps aside for it.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var selectedPage = 0

    private let pageCount = 3
    private var startYourStoryIndex: Int { pageCount - 1 }
    /// What the pages leave clear at the bottom for the shared bar.
    private let bottomBarHeight: CGFloat = 108

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.onboardingPaper
                .ignoresSafeArea()

            TabView(selection: $selectedPage) {
                OnboardingWelcomePage(
                    topInset: topSafeAreaInset,
                    bottomInset: bottomBarHeight
                )
                .tag(0)

                OnboardingWriteYourStoryPage(bottomInset: bottomBarHeight)
                    .tag(1)

                StartYourStoryView(
                    onExploreFirst: onComplete,
                    onAuthenticated: onComplete,
                    // The shared bar below carries this page's way into the app, so the page itself
                    // stops drawing one and just leaves room for it.
                    showsContinueBrowsingButton: false,
                    bottomContentInset: bottomBarHeight
                )
                .tag(startYourStoryIndex)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Two halves of one fix for the safe area strips. This half gives the TabView the whole
            // screen to draw in; without it there is nothing outside the safe area to draw into. The
            // other half is in the pages, which have to climb into that space themselves — a
            // page-style TabView hands every page the safe area back no matter what its container
            // says. Page one cancels the top inset by hand; the sign-in page's sheet already asks to
            // ignore the bottom one, and now has somewhere to go.
            .ignoresSafeArea()

            bottomBar
        }
        .preferredColorScheme(.light)
    }

    /// The status bar inset, read from the window: page one needs the measurement to cancel it out,
    /// and a GeometryReader inside the TabView reports it as already applied rather than as a number.
    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 47
    }

    private var isLastPage: Bool {
        selectedPage == startYourStoryIndex
    }

    private var bottomBar: some View {
        VStack(spacing: 22) {
            pageIndicator

            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Text(isLastPage ? "Continue To Journaltopia" : "Next")

                    if isLastPage {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .font(.system(size: 18, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        Color.storyPurple,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .shadow(color: Color.storyPurple.opacity(0.26), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == selectedPage ? Color.storyPurple : Color.storyInk.opacity(0.16))
                    .frame(width: index == selectedPage ? 22 : 8, height: 8)
            }
        }
        .frame(height: 8)
        .animation(.snappy(duration: 0.24), value: selectedPage)
        .accessibilityHidden(true)
    }

    /// Next on the first two pages, the way into Journaltopia on the last.
    private func primaryAction() {
        guard !isLastPage else {
            onComplete()
            return
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            selectedPage += 1
        }
    }
}

// MARK: - Page one

private struct OnboardingWelcomePage: View {
    let topInset: CGFloat
    let bottomInset: CGFloat

    /// How far the video's bottom edge dissolves into the paper.
    private let blendHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            // No fixed height: the copy takes what it needs at the bottom and the video keeps the
            // rest, so the paper only ever covers the words.
            hero

            copy
        }
        // The page arrives already inset below the status bar; this cancels that out so the video
        // starts at the physical top of the screen.
        .padding(.top, -topInset)
        .padding(.bottom, bottomInset)
    }

    private var hero: some View {
        HomeLoopingVideoBackground(resourceName: "onboarding-1")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .bottom) {
                // Two passes over the same edge: the material blurs the art out, the tint carries it
                // the rest of the way to the paper colour so there is no seam to find.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.55), location: 0.5),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(height: blendHeight * 0.8)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .onboardingPaper.opacity(0), location: 0),
                        .init(color: .onboardingPaper.opacity(0.32), location: 0.45),
                        .init(color: .onboardingPaper.opacity(0.86), location: 0.82),
                        .init(color: .onboardingPaper, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: blendHeight)
                .allowsHitTesting(false)
            }
    }

    private var copy: some View {
        VStack(spacing: 0) {
            Text("Journaltopia")
                .font(.system(size: 40, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Text("Your life, told in storyboards.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .padding(.top, 6)

            Text("Turn your thoughts into\nbeautiful storyboards and\nrelive your story, one page\nat a time.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.78))
                .lineSpacing(5)
                .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .padding(.horizontal, 30)
        .background(Color.onboardingPaper)
    }
}

// MARK: - Page two

private struct OnboardingWriteYourStoryPage: View {
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("Write Your Story")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)

                Text("Capture your thoughts in a\nbeautiful, distraction-free space.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineSpacing(3)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)
            .padding(.horizontal, 28)

            Spacer(minLength: 8)

            Image("write_your_story")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)

            Spacer(minLength: 8)
        }
        .padding(.bottom, bottomInset)
    }
}

extension Color {
    /// The warm paper the onboarding pages sit on.
    static let onboardingPaper = Color(red: 0.953, green: 0.945, blue: 0.933)
}

#Preview {
    OnboardingView {}
        .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
}
