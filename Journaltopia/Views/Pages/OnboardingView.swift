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
            OnboardingBackgroundView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $selectedPage) {
                    ForEach(pages.indices, id: \.self) { index in
                        OnboardingPageView(
                            page: pages[index],
                            isLastPage: index == lastPageIndex,
                            onComplete: finish
                        )
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomControls
            }

            VStack {
                topBar
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack {
            Spacer()

            Button("Skip") {
                finish()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.storyPurple)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .accessibilityLabel("Skip onboarding")
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
    }

    private var bottomControls: some View {
        HStack(spacing: 18) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == selectedPage ? Color.storyPurple : Color.homeBorder)
                    .frame(width: 9, height: 9)
                    .animation(.snappy(duration: 0.22), value: selectedPage)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 24)
        .padding(.bottom, 34)
    }

    private func finish() {
        onComplete()
    }
}

private struct OnboardingBackgroundView: View {
    var body: some View {
        GeometryReader { proxy in
            Image("onboarding-background")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let isLastPage: Bool
    let onComplete: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 52)

                VStack(spacing: 12) {
                    page.titleText
                        .font(.system(size: titleSize(for: proxy.size), weight: .bold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)

                    Text(page.message)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 34)

                Spacer(minLength: 12)

                image(maxHeight: imageHeight(for: proxy.size))

                if isLastPage {
                    VStack(spacing: 14) {
                        Button {
                            onComplete()
                        } label: {
                            Text("Start Journaling")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start Journaling")

                        Text("You can always sign in later.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.homeMutedText)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                }

                Spacer(minLength: isLastPage ? 14 : 24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func image(maxHeight: CGFloat) -> some View {
        Image(page.imageName)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: maxHeight)
            .padding(.horizontal, page.horizontalImagePadding)
    }

    private func titleSize(for size: CGSize) -> CGFloat {
        size.height < 720 ? 30 : 34
    }

    private func imageHeight(for size: CGSize) -> CGFloat {
        let reservedHeight: CGFloat = isLastPage ? 340 : 206
        return max(320, size.height - reservedHeight)
    }
}

private struct OnboardingPage {
    let titleText: Text
    let message: String
    let imageName: String
    let horizontalImagePadding: CGFloat

    static let allPages: [OnboardingPage] = [
        OnboardingPage(
            titleText: Text("Your life,\ntold in ").foregroundColor(.storyInk)
                + Text("storyboards.").foregroundColor(.storyPurple),
            message: "Write about your day, a memory,\nor something you're dreaming about.",
            imageName: "1",
            horizontalImagePadding: 0
        ),
        OnboardingPage(
            titleText: Text("Turn your words\ninto a ").foregroundColor(.storyInk)
                + Text("story.").foregroundColor(.storyPurple),
            message: "Journaltopia transforms your writing\ninto illustrated storyboards.",
            imageName: "2",
            horizontalImagePadding: 8
        ),
        OnboardingPage(
            titleText: Text("Make every\nstory ").foregroundColor(.storyInk)
                + Text("yours.").foregroundColor(.storyPurple),
            message: "Add characters, reference photos,\nart styles, and details to shape\nhow your story looks.",
            imageName: "3",
            horizontalImagePadding: 8
        ),
        OnboardingPage(
            titleText: Text("Build the story\nof ").foregroundColor(.storyInk)
                + Text("your life.").foregroundColor(.storyPurple),
            message: "Organize your moments into journals\nand watch your visual story\ngrow over time.",
            imageName: "4",
            horizontalImagePadding: 0
        )
    ]
}

#Preview {
    OnboardingView {}
}
