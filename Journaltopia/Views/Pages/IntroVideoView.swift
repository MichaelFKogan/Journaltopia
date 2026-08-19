import AVFoundation
import SwiftUI
import UIKit

/// The film that closes onboarding, and the card it settles into.
///
/// Not a page in the welcome flow's pager: a pager's dots promise steps you can move between freely,
/// and a film that runs for twenty seconds and ends is neither free nor reversible in that sense.
/// This is a stack instead — the film pushes over onboarding, the closing card pushes over the film,
/// and the chevron or a swipe from the left edge walks back down the same way it came. Ordered and
/// reversible, without pretending the steps are equivalent.
///
/// Skip is a step forward in that stack rather than a door out: it lands on the closing card, which
/// is where the way into the app lives.
struct IntroVideoView: View {
    /// One step back out of the stack, to the flow underneath.
    let onBack: () -> Void
    /// All the way in, from the closing card's button.
    let onFinished: () -> Void

    @State private var stage: Stage = .film
    @State private var isSkipVisible = false
    /// Bumped to send the film back to its first frame, which is what stepping back into it means.
    @State private var filmRunID = 0
    @GestureState private var backDragWidth: CGFloat = 0

    private enum Stage {
        case film
        case closingCard
    }

    var body: some View {
        content
            .offset(x: backDragWidth)
            .gesture(backSwipe)
            .statusBarHidden()
    }

    private var content: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            IntroVideoPlayer(
                resourceName: "intro",
                resourceExtension: "MOV",
                isPlaying: stage == .film,
                runID: filmRunID,
                onEnded: { showClosingCard(duration: 0.45) }
            )
            .ignoresSafeArea()

            if stage == .closingCard {
                // Layered over the finished film rather than replacing it: the last frame it holds
                // is black, so this reads as a fade up out of the fade out.
                closingShot
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            backButton
                .padding(.leading, 18)
                .padding(.top, 8)
        }
        .overlay(alignment: .topTrailing) {
            skipButton
                .opacity(isSkipVisible && stage == .film ? 1 : 0)
                // Nothing to press while it is invisible, including the beat before it fades in.
                .allowsHitTesting(isSkipVisible && stage == .film)
                .padding(.trailing, 18)
                .padding(.top, 8)
        }
        .overlay(alignment: .top) {
            if stage == .closingCard {
                endCard
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if stage == .closingCard {
                continueButton
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear(perform: revealSkipAfterABeat)
    }

    /// A beat before the corner button fades in, so the opening frames are just the film.
    private func revealSkipAfterABeat() {
        withAnimation(.easeIn(duration: 0.4).delay(0.8)) {
            isSkipVisible = true
        }
    }

    /// Where the film was always going, whether it played out or was skipped past.
    private func showClosingCard(duration: TimeInterval) {
        withAnimation(.easeOut(duration: duration)) {
            stage = .closingCard
        }
    }

    /// The closing card steps back into the film, and the film steps back into onboarding.
    private func stepBack() {
        guard stage == .closingCard else {
            onBack()
            return
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            stage = .film
        }
        isSkipVisible = true
        // Coming back to a screen means arriving at the top of it, not where it left off.
        filmRunID += 1
    }

    /// The system's own way back, since the stack is over onboarding rather than inside a navigation
    /// controller: a drag that starts at the left edge carries the screen with it, and lets go into
    /// either a step back or a slide home.
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($backDragWidth) { value, width, _ in
                guard value.startLocation.x < 44 else { return }
                width = max(0, value.translation.width)
            }
            .onEnded { value in
                guard value.startLocation.x < 44 else { return }

                let carried = max(value.translation.width, value.predictedEndTranslation.width * 0.5)
                if carried > 110 {
                    stepBack()
                }
            }
    }

    private var backButton: some View {
        Button(action: stepBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stage == .closingCard ? "Back to the intro" : "Back to onboarding")
    }

    private var skipButton: some View {
        Button { showClosingCard(duration: 0.3) } label: {
            Text("Skip")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip to the end of the intro")
    }

    /// The second film, looping under the closing card, with a scrim across the top so the name
    /// stays readable however bright the shot gets.
    private var closingShot: some View {
        HomeLoopingVideoBackground(resourceName: "intro-2")
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.65), location: 0),
                        .init(color: .black.opacity(0.35), location: 0.55),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 320)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                // A softer counterpart under the purple button.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
    }

    private var endCard: some View {
        VStack(spacing: 8) {
            Text("Journaltopia")
                .font(.system(size: 40, weight: .bold, design: .serif))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
                .lineLimit(1)

            Text("Your life, told in storyboards.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 2)
        .allowsHitTesting(false)
    }

    private var continueButton: some View {
        Button(action: onFinished) {
            HStack(spacing: 8) {
                Text("Continue To Journaltopia")

                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
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
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}

// MARK: - Player

/// A play-once companion to `HomeLoopingVideoBackground`: same aspect-fill layer, but it reports the
/// end of the film instead of starting it over, and it keeps its sound.
private struct IntroVideoPlayer: UIViewRepresentable {
    let resourceName: String
    let resourceExtension: String
    /// False once the stack has moved on past the film — skipped or played out, its sound should not
    /// carry on under the card.
    let isPlaying: Bool
    /// Any change to this starts the film again from its first frame.
    let runID: Int
    let onEnded: () -> Void

    func makeUIView(context: Context) -> IntroVideoPlayerView {
        let view = IntroVideoPlayerView()
        view.onEnded = onEnded
        view.configure(resourceName: resourceName, resourceExtension: resourceExtension)
        view.setPlaying(isPlaying)
        context.coordinator.runID = runID
        return view
    }

    func updateUIView(_ uiView: IntroVideoPlayerView, context: Context) {
        uiView.onEnded = onEnded

        // A restart is already a play, so the two never both apply in one pass.
        guard context.coordinator.runID == runID else {
            context.coordinator.runID = runID
            uiView.restart()
            return
        }

        uiView.setPlaying(isPlaying)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: IntroVideoPlayerView, coordinator: Coordinator) {
        uiView.stop()
    }

    final class Coordinator {
        var runID = 0
    }
}

private final class IntroVideoPlayerView: UIView {
    var onEnded: (() -> Void)?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    private var hasReportedEnd = false

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stop()
    }

    func configure(resourceName: String, resourceExtension: String) {
        guard player == nil else { return }

        guard let url = Self.resourceURL(named: resourceName, extension: resourceExtension) else {
            print("[Journaltopia] Missing bundled video: \(resourceName).\(resourceExtension)")
            // Nothing to watch: hand the screen its ending straight away so the card still arrives.
            DispatchQueue.main.async { [weak self] in self?.reportEnd() }
            return
        }

        // Ambient keeps the film's music under the ring/silent switch and leaves whatever the visitor
        // was already listening to playing.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        playerLayer.player = player
        self.player = player

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.reportEnd()
        }

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Coming back from the background resumes the film, unless it already finished.
            guard let self, !self.hasReportedEnd else { return }
            self.player?.play()
        }

        player.play()
    }

    func setPlaying(_ isPlaying: Bool) {
        guard let player else { return }

        if isPlaying {
            guard !hasReportedEnd else { return }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Back to the first frame, and playing: what stepping back into the film should feel like.
    func restart() {
        guard let player else { return }

        hasReportedEnd = false
        player.seek(to: .zero)
        player.play()
    }

    func stop() {
        player?.pause()
        playerLayer.player = nil
        player = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
    }

    private func reportEnd() {
        guard !hasReportedEnd else { return }
        hasReportedEnd = true
        onEnded?()
    }

    /// The file is `intro.MOV`; the fallback covers a rename that lower-cases the extension, since
    /// the device's file system is case-sensitive and the simulator's is not.
    private static func resourceURL(named name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext.lowercased())
            ?? Bundle.main.url(forResource: name, withExtension: ext.uppercased())
    }
}

#Preview {
    IntroVideoView(onBack: {}, onFinished: {})
}
