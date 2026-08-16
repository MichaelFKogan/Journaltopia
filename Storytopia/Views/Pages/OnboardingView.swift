import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var selectedPage = 0

    private let pages = OnboardingPage.allPages
    private var lastPageIndex: Int {
        max(pages.count - 1, 0)
    }

    var body: some View {
        ZStack {
            WatercolorPaperPageBackground()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $selectedPage) {
                    ForEach(pages.indices, id: \.self) { index in
                        OnboardingPageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomControls
            }
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()

            Button("Skip") {
                finish()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.storyInk.opacity(0.72))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .accessibilityLabel("Skip onboarding")
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
    }

    private var bottomControls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.storyPurple : Color.homeBorder)
                        .frame(width: index == selectedPage ? 9 : 7, height: index == selectedPage ? 9 : 7)
                        .animation(.snappy(duration: 0.22), value: selectedPage)
                        .accessibilityHidden(true)
                }
            }

            Group {
                if selectedPage == lastPageIndex {
                    Button {
                        finish()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Get Started")
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.storyPurple.opacity(0.22), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Get Started")
                } else {
                    Color.clear
                        .frame(height: 54)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private func finish() {
        onComplete()
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 30) {
                    Spacer(minLength: 8)

                    image
                        .frame(height: min(proxy.size.height * 0.48, 360))

                    VStack(spacing: 14) {
                        Text(page.title)
                            .font(.system(size: 34, weight: .bold, design: .serif))
                            .foregroundStyle(Color.storyInk)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.82)

                        Text(page.message)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.homeMutedText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 26)

                    Spacer(minLength: 24)
                }
                .frame(minHeight: proxy.size.height)
            }
        }
    }

    private var image: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(page.backdropColor)

            Image(page.imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 24)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.78), lineWidth: 1)
                .padding(.horizontal, 24)
        }
        .shadow(color: Color.storyInk.opacity(0.12), radius: 18, y: 10)
    }
}

private struct OnboardingPage {
    let title: String
    let message: String
    let imageName: String
    let backdropColor: Color

    static let allPages: [OnboardingPage] = [
        OnboardingPage(
            title: "Turn your life into story.",
            message: "Storytopia helps your journals become a living world of scenes, characters, and visual memories.",
            imageName: "storyboard_placeholder_1",
            backdropColor: Color.storyBlush
        ),
        OnboardingPage(
            title: "Write your entry.",
            message: "Start with a moment, a dream, a trip, or one small detail worth remembering.",
            imageName: "art_style_graphic_novel",
            backdropColor: Color.storyCream
        ),
        OnboardingPage(
            title: "Add your characters.",
            message: "Bring in the people, places, and inner-world figures that make the scene feel unmistakably yours.",
            imageName: "art_style_anime",
            backdropColor: Color.storyLavender
        ),
        OnboardingPage(
            title: "Get your storyboard.",
            message: "Generate illustrated panels and browse sample stories first, without needing an account.",
            imageName: "storyboard_placeholder_4",
            backdropColor: Color.homeCardGray
        )
    ]
}

#Preview {
    OnboardingView {}
}
