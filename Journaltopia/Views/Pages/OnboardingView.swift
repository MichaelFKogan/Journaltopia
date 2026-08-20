import SwiftUI
import UIKit

/// The welcome flow: an opening film, four pages on what the app makes of the writing, the tour —
/// its opening page and the steps it walks through — and the sign-in page.
///
/// Every page but the last shares one bottom bar — the dots and the Next button live here rather
/// than inside each page so the dots always know where the flow is. The last page is the sign-in
/// page, which brings its own buttons, so the bar steps aside for it.
///
/// The closing film is not a fourth page. It pushes over the whole flow as a stack, because a film
/// is not a step you can drift back and forth across the way the pages are — see `IntroVideoView`.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var selectedPage = 0
    /// The closing film, pushed over the flow once the visitor is on their way in.
    @State private var isShowingIntro = false

    /// Page one, the story pages, the tour opener, the tour's own steps, then sign-in.
    private var pageCount: Int {
        1 + OnboardingStoryPage.allPages.count + 1 + OnboardingTourStep.allSteps.count + 1
    }
    private var seeHowItWorksIndex: Int { 1 + OnboardingStoryPage.allPages.count }
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
                    bottomInset: bottomBarHeight,
                    isActive: selectedPage == 0
                )
                .tag(0)

                ForEach(OnboardingStoryPage.allPages.indices, id: \.self) { index in
                    OnboardingStoryPageView(
                        page: OnboardingStoryPage.allPages[index],
                        bottomInset: bottomBarHeight
                    )
                    .tag(index + 1)
                }

                OnboardingSeeHowItWorksPage(onContinue: primaryAction)
                    .tag(seeHowItWorksIndex)

                ForEach(OnboardingTourStep.allSteps.indices, id: \.self) { index in
                    OnboardingTourStepView(
                        step: OnboardingTourStep.allSteps[index],
                        number: index + 1,
                        bottomInset: bottomBarHeight
                    )
                    .tag(seeHowItWorksIndex + 1 + index)
                }

                StartYourStoryView(
                    onExploreFirst: showIntro,
                    onAuthenticated: showIntro,
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
                .opacity(isShowingIntro ? 0 : 1)

            if isShowingIntro {
                // Pushed in from the trailing edge and dragged back out the same way: the film reads
                // as somewhere the visitor went, not as a page that replaced this one.
                IntroVideoView(onBack: dismissIntro, onFinished: onComplete)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
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

    /// The tour opener carries its own way forward, down in the torn purple half, so the shared bar
    /// keeps only the dots there.
    private var showsBottomBarButton: Bool {
        selectedPage != seeHowItWorksIndex
    }

    private var bottomBar: some View {
        VStack(spacing: 22) {
            pageIndicator

            if showsBottomBarButton {
                Button(action: primaryAction) {
                    Text(isLastPage ? "Skip For Now" : "Next")
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
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.22), value: showsBottomBarButton)
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

    /// Every way past the sign-in page — its button, exploring first, signing in — leads to the film
    /// rather than straight into the app.
    private func showIntro() {
        guard !isShowingIntro else { return }

        withAnimation(.easeInOut(duration: 0.35)) {
            isShowingIntro = true
        }
    }

    /// One step back down the stack, onto the page the visitor left.
    private func dismissIntro() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isShowingIntro = false
        }
    }

    /// Next through the pages, the film on the last.
    private func primaryAction() {
        guard !isLastPage else {
            showIntro()
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
    /// The page-style TabView keeps this page alive after Next, so the film has to be told to stop.
    let isActive: Bool

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
        HomeLoopingVideoBackground(
            resourceName: "intro-2",
            resourceExtension: "mp4",
            isMuted: false,
            isPlaying: isActive
        )
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

// MARK: - Tour steps

/// One step of the walkthrough the tour opener promises: what the visitor does, and the picture of
/// it. The steps run in order after that opening page.
private struct OnboardingTourStep {
    let title: String
    let message: String
    let imageName: String

    static let allSteps: [OnboardingTourStep] = [
        OnboardingTourStep(
            title: "Write Your Story",
            message: "Capture your thoughts in a\nbeautiful, distraction-free space.",
            imageName: "write_your_story"
        ),
        OnboardingTourStep(
            title: "Choose Your Style",
            message: "Decide how your story\ncomes to life.",
            imageName: "choose_your_style"
        ),
        OnboardingTourStep(
            title: "Bring It to Life",
            message: "Turn your words into\nan illustrated storyboard.",
            imageName: "bring_it_to_life"
        ),
        OnboardingTourStep(
            title: "Build Your Journals",
            message: "Collect your stories into\nchapters of your life.",
            imageName: "build_your_journals"
        )
    ]
}

private struct OnboardingTourStepView: View {
    let step: OnboardingTourStep
    /// Where this step falls in the tour, counted for the visitor rather than from zero.
    let number: Int
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                stepBadge
                    .padding(.bottom, 4)

                Text(step.title)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)

                Text(step.message)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineSpacing(3)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)
            .padding(.horizontal, 28)

            Spacer(minLength: 8)

            Image(step.imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)

            Spacer(minLength: 8)
        }
        .padding(.bottom, bottomInset)
    }

    private var stepBadge: some View {
        Text("\(number)")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.storyPurple, in: Circle())
            .accessibilityLabel("Step \(number) of \(OnboardingTourStep.allSteps.count)")
    }
}

// MARK: - See how it works

/// The opening page of the tour: the four steps laid out on the paper half, and, below the torn
/// edge, the invitation into the walkthrough.
///
/// The purple half runs all the way off the bottom of the screen, under the shared bar's dots, so
/// this page reserves only the dots' room rather than the whole bar's — the bar drops its own
/// button here and this page's "Show Me How" takes its place inside the purple.
private struct OnboardingSeeHowItWorksPage: View {
    let onContinue: () -> Void

    /// What the purple half keeps clear at the bottom for the shared bar's dots.
    private let dotsInset: CGFloat = 46
    /// The torn sheet's own proportions, so it hangs at its drawn height however wide the screen is.
    private let tornSheetAspect: CGFloat = 1056.0 / 1490.0

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 20)
                .padding(.horizontal, 24)

            // Takes whatever the header and the purple half leave, and fits inside it: on a short
            // screen the picture gives way rather than pushing the torn edge off the bottom.
            Image("5")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            invitation
        }
        // The two pictures are drawn on a slightly warmer paper than the flow's own; the page takes
        // theirs so no edge shows around the picture or above the tear.
        .background(Color.onboardingTourPaper.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("See How It Works")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .overlay(alignment: .topLeading) {
                    OnboardingSparkle(size: 18).offset(x: -30, y: -4)
                }
                .overlay(alignment: .topLeading) {
                    OnboardingSparkle(size: 12).offset(x: -46, y: 16)
                }
                .overlay(alignment: .trailing) {
                    OnboardingSparkle(size: 17).offset(x: 32, y: 4)
                }

            Text("Ready to turn your words into\nbeautiful storyboards?")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .lineSpacing(3)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The torn purple half, with the walkthrough's way in.
    private var invitation: some View {
        VStack(spacing: 12) {
            // The spaces are the glyphs' elbow room: Caveat's tails lean past the advance width and
            // SwiftUI clips a Text to its measured box.
            Text(" Let\u{2019}s get started! ")
                .font(.custom("Caveat-Regular", size: 36).weight(.bold))
                .foregroundStyle(Color.storyPurple)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .overlay(alignment: .leading) {
                    OnboardingSparkle(size: 14).offset(x: -26, y: -6)
                }
                .overlay(alignment: .trailing) {
                    OnboardingSparkle(size: 14).offset(x: 26, y: -8)
                }

            Text("We\u{2019}ll show you how to write,\ncreate, and keep your stories.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.7))
                .lineSpacing(3)

            Button(action: onContinue) {
                HStack(spacing: 14) {
                    Text("Show Me How")
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .semibold))
                }
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
            .padding(.top, 8)
            .padding(.horizontal, 24)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        // Enough to clear the ragged edge the picture tears across the top of this half.
        .padding(.top, 42)
        .padding(.bottom, dotsInset)
        .background(alignment: .top) {
            // The colour runs off the bottom of the screen rather than stopping at the home
            // indicator, so the dots sit on purple like the rest of this half.
            tornPaper
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The torn sheet, hung from the top of the purple half at its own proportions, with its colour
    /// carrying on below it however far the screen runs.
    private var tornPaper: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            VStack(spacing: 0) {
                Image("5-bottom")
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: width * tornSheetAspect)
                    .clipped()

                Color.onboardingTornPurple
            }
            .frame(width: width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
    }
}

/// The little four-pointed stars scattered around the tour's headings.
private struct OnboardingSparkle: View {
    let size: CGFloat

    var body: some View {
        SparkleShape()
            .stroke(Color.storyPurple, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// A diamond pulled hollow at the sides — the four arms meet in curves rather than corners.
    private struct SparkleShape: Shape {
        func path(in rect: CGRect) -> Path {
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.move(to: CGPoint(x: centre.x, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: centre.y), control: centre)
            path.addQuadCurve(to: CGPoint(x: centre.x, y: rect.maxY), control: centre)
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: centre.y), control: centre)
            path.addQuadCurve(to: CGPoint(x: centre.x, y: rect.minY), control: centre)
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Story pages

/// One of the four pages between the writing page and sign-in: a two-tone title, a line or two
/// underneath, and the picture that carries the page.
private struct OnboardingStoryPage {
    /// Ink for the sentence, purple for the words it lands on.
    let titleText: Text
    let message: String
    let imageName: String
    let horizontalImagePadding: CGFloat

    static let allPages: [OnboardingStoryPage] = [
        OnboardingStoryPage(
            titleText: Text("Your life,\ntold in ").foregroundColor(.storyInk)
                + Text("storyboards.").foregroundColor(.storyPurple),
            message: "Write about your day, a memory,\nor something you're dreaming about.",
            imageName: "1",
            horizontalImagePadding: 0
        ),
        OnboardingStoryPage(
            titleText: Text("Turn your words\ninto a ").foregroundColor(.storyInk)
                + Text("story.").foregroundColor(.storyPurple),
            message: "Journaltopia transforms your writing\ninto illustrated storyboards.",
            imageName: "2",
            horizontalImagePadding: 8
        ),
        OnboardingStoryPage(
            titleText: Text("Make every\nstory ").foregroundColor(.storyInk)
                + Text("yours.").foregroundColor(.storyPurple),
            message: "Add characters, reference photos,\nart styles, and details to shape\nhow your story looks.",
            imageName: "3",
            horizontalImagePadding: 8
        ),
        OnboardingStoryPage(
            titleText: Text("Build the story\nof ").foregroundColor(.storyInk)
                + Text("your life.").foregroundColor(.storyPurple),
            message: "Organize your moments into journals\nand watch your visual story\ngrow over time.",
            imageName: "4",
            horizontalImagePadding: 0
        )
    ]
}

private struct OnboardingStoryPageView: View {
    let page: OnboardingStoryPage
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                page.titleText
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)

                Text(page.message)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineSpacing(3)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 20)
            .padding(.horizontal, 28)

            Spacer(minLength: 8)

            Image(page.imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, page.horizontalImagePadding + 20)

            Spacer(minLength: 8)
        }
        .padding(.bottom, bottomInset)
    }
}

extension Color {
    /// The warm paper the onboarding pages sit on.
    static let onboardingPaper = Color(red: 0.953, green: 0.945, blue: 0.933)
    /// The lilac of the torn sheet on the tour's opening page, so the colour can carry on below the
    /// picture's own edge.
    static let onboardingTornPurple = Color(red: 0.890, green: 0.847, blue: 0.952)
    /// The paper the tour's pictures are drawn on — a shade warmer than the rest of the flow's.
    static let onboardingTourPaper = Color(red: 0.972, green: 0.949, blue: 0.933)
}

#Preview {
    OnboardingView {}
        .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
}
