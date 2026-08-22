import AVFoundation
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var signInGate: SignInGate

    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    var contentMode: JournaltopiaContentMode = .user
    var openCreatePage: () -> Void = {}
    var openEntriesPage: () -> Void = {}
    var openJournalsPage: () -> Void = {}
    var openStorySoFarPage: () -> Void = {}

    @State private var fullScreenImageName: String?
    @State private var isLoadingHomeStoryboards = false

    private let homeStoryboardLoadLimit = 50

    var body: some View {
        ZStack(alignment: .bottom) {
            WatercolorPaperPageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    heroCard
                        .zIndex(3)
                    homeNavigationCards
                        .zIndex(2)
                    journalCoverSection
                        .zIndex(1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 104 + signInCalloutContentInset)
            }

            BottomNavigationBar(selectedPage: $selectedPage)

            if contentMode.requiresSignIn {
                SampleSignInCallout()
                    .padding(.bottom, JournaltopiaFloatingControlMetrics.signInCalloutBottomInset)
                    .zIndex(3)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { fullScreenImageName != nil },
                set: { isPresented in
                    if !isPresented {
                        fullScreenImageName = nil
                    }
                }
            )
        ) {
            if let fullScreenImageName {
                HomeImagePreviewSheet(imageName: fullScreenImageName) {
                    self.fullScreenImageName = nil
                }
            }
        }
        .task(id: homeStoryboardLoadID) {
            await loadHomeStoryboards()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
        .preferredColorScheme(.light)
    }

    private var isSampleAuthorMode: Bool {
        contentMode.isSampleAuthoring
    }

    private var showsSampleHomeContent: Bool {
        contentMode.showsSampleContent
    }

    /// Extra room under the content for the floating sign-in callout, which nothing else in the
    /// layout reserves space for.
    private var signInCalloutContentInset: CGFloat {
        contentMode.requiresSignIn ? JournaltopiaFloatingControlMetrics.signInCalloutContentInset : 0
    }

    private var homeStoryboardLoadID: String {
        contentMode.loadIdentity(userID: authStore.userID)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Journaltopia")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Text("Your life, told in storyboards.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
            }

            Spacer()

            if contentMode.requiresSignIn {
                signInButton
            } else {
                creditsButton
                    .padding(.top, 2)
            }
        }
    }

    /// Signed out, both trailing icons are answers to questions nobody has asked yet: there is no
    /// balance to show and no account to configure. One word for the one thing worth doing replaces
    /// them, and it opens the same Sign In to Journaltopia sheet every other account-required
    /// action uses.
    private var signInButton: some View {
        Button {
            signInGate.requireAccount(for: .signIn)
        } label: {
            Text("Sign In")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .padding(.horizontal, 8)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in")
        .accessibilityHint("Opens Sign In to Journaltopia")
    }

    /// A balance for subscribers, an invitation for everyone else.
    ///
    /// Showing a free account "0" beside a sparkle reads as a balance they could spend, which is
    /// both wrong and a dead end — credits are not sold separately from Journaltopia+. The pill says
    /// Upgrade instead. Neither variant is shown until the server has answered, so a subscriber is
    /// never briefly invited to subscribe.
    @ViewBuilder
    private var creditsButton: some View {
        NavigationLink {
            GenerationCreditsView()
                .enableInteractivePopGesture()
        } label: {
            if subscriptionStore.state.isSubscribed || !subscriptionStore.state.isResolved {
                CreditBalanceBadge(
                    balance: generationCreditStore.balance,
                    isRefreshing: generationCreditStore.isRefreshing
                )
            } else {
                JournaltopiaPlusPill()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            subscriptionStore.state.isSubscribed ? "Open credits" : "Upgrade to Journaltopia+"
        )
    }

    private var heroCard: some View {
        Button {
            openCreatePage()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("Create\nStory")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .lineSpacing(2)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .homeBannerTitleContrast()

                Text("Write about your day\nand turn it into a storyboard.")
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.92))
                    .homeBannerSubtitleContrast()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, HomeCardLayout.verticalPadding)
            .frame(maxWidth: .infinity, minHeight: HomeCardLayout.primaryHeight, alignment: .leading)
            .background {
                HomeLoopingVideoBackground(resourceName: "homepage_banner")
                    .overlay(HomeBannerLeadingGradient())
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                HomeCardNavigationIndicator(systemName: "plus", style: .accent)
                    .padding(14)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create Story")
        .accessibilityHint("Opens Create Story")
    }

    private var homeNavigationCards: some View {
        VStack(spacing: 14) {
            HomeNavigationCard(
                title: "My Entries",
                subtitle: "Write, edit, and turn your\nthoughts into storyboards.",
                backgroundImageName: "home_entries_card_bg",
                backgroundVideoName: "home_entries_card_bg",
                contentAlignment: .leading
            ) {
                openEntriesPage()
            }

            HomeNavigationCard(
                title: "My Journals",
                subtitle: "Organize your stories\ninto meaningful journals.",
                backgroundImageName: "home_journals_card_bg",
                backgroundVideoName: "home_journals_card_bg",
                contentAlignment: .leading
            ) {
                openJournalsPage()
            }
        }
    }

    private var journalCoverSection: some View {
        HomeStorySoFarCard(
            isEnabled: !generatedStoryboards.isEmpty,
            isLoading: isLoadingHomeStoryboards && generatedStoryboards.isEmpty,
            action: openStorySoFarPage
        )
        .frame(height: HomeCardLayout.primaryHeight)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @MainActor
    private func loadHomeStoryboards() async {
        // Nothing to load against yet: a session still resolving would pick a source and then have
        // to swap it, and a build with no Supabase credentials has neither source to pick.
        guard contentMode.isResolved, contentMode.unavailableMessage == nil else {
            isLoadingHomeStoryboards = contentMode == .loading
            return
        }

        if showsSampleHomeContent {
            await loadSampleHomeStoryboards()
            return
        }

        isLoadingHomeStoryboards = true
        defer { isLoadingHomeStoryboards = false }

        do {
            let service = SupabaseStoryboardService()
            let sampleEntryIDs = (try? await SupabaseSampleStoryService().loadActiveSampleEntryIDs()) ?? []
            let loadedStoryboards = try await service.loadCompletedJournalStoryboardImages(
                limit: homeStoryboardLoadLimit,
                offset: 0
            )
            .filter { storyboard in
                isHomeEligibleStoryboard(storyboard, sampleEntryIDs: sampleEntryIDs)
            }
            .sorted(by: homeStoryboardSort)

            generatedStoryboards = loadedStoryboards
        } catch is CancellationError {
            return
        } catch {
            print("[Journaltopia] Home storyboard cover load failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadSampleHomeStoryboards() async {
        isLoadingHomeStoryboards = true
        defer { isLoadingHomeStoryboards = false }

        do {
            let service = SupabaseSampleStoryService()
            let pack: SampleStoryPack
            if isSampleAuthorMode {
                pack = try await service.loadAuthoringPack()
            } else {
                pack = try await service.loadActivePack()
                // Signed-out browsing shares one in-memory copy of the pack across screens, so
                // Journals and the entry views can read it without any of them writing to disk.
                SampleContentStore.replace(with: pack)
            }
            generatedStoryboards = pack.storyboardsByEntryID.values
                .flatMap { $0 }
                .sorted(by: homeStoryboardSort)
        } catch is CancellationError {
            return
        } catch {
            print("[Journaltopia] Sample home storyboard load failed: \(error.localizedDescription)")
        }
    }

    private func isHomeEligibleStoryboard(
        _ storyboard: GeneratedStoryboard,
        sampleEntryIDs: Set<UUID>
    ) -> Bool {
        guard !storyboard.isSampleContent else {
            return false
        }

        guard storyboard.cloudSyncState != StoryboardCloudSyncState.failed.rawValue else {
            return false
        }

        if let clientEntryID = storyboard.clientEntryID,
           sampleEntryIDs.contains(clientEntryID) {
            return false
        }

        if let storagePath = storyboard.storagePath {
            return !storagePath.hasPrefix("journaltopia-first-run/")
        }

        return false
    }

    private func homeStoryboardSort(_ lhs: GeneratedStoryboard, _ rhs: GeneratedStoryboard) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }

        return lhs.id.uuidString > rhs.id.uuidString
    }

    private var socialFeedSection: some View {
        LazyVStack(spacing: 14) {
            ForEach(homeFeedPosts) { post in
                HomeSocialFeedCard(
                    entry: post.entry,
                    accentColor: Color.homeAccent,
                    username: post.username,
                    dateText: post.dateText,
                    presentation: post.presentation
                ) { imageName in
                    fullScreenImageName = imageName
                } onUsernameTap: {
                    selectedPage = .profile
                }
                .frame(maxWidth: .infinity)
                .id(post.id)
            }
        }
    }

    private var storyboardFeedPosts: [HomeFeedPost] {
        [
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "WED",
                    day: "17",
                    title: "City chapter",
                    body: "A storyboard moment from a bright city walk.",
                    time: "4:38 PM",
                    location: "Brooklyn, NY",
                    imageNames: ["IMG_2839"]
                ),
                username: "mikekogan",
                dateText: "Wed, Jun 17",
                presentation: .storyboardImage
            ),
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "TUE",
                    day: "16",
                    title: "Slow morning",
                    body: "Coffee, window light, and a few quiet panels from the day.",
                    time: "9:12 AM",
                    location: "Brooklyn, NY",
                    imageNames: ["IMG_2840"]
                ),
                username: "journaltopia",
                dateText: "Tue, Jun 16",
                presentation: .storyboardImage
            ),
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "SUN",
                    day: "14",
                    title: "Sunday dinner",
                    body: "A little memory rendered as a storyboard page.",
                    time: "8:04 PM",
                    location: "Home",
                    imageNames: ["IMG_2841"]
                ),
                username: "mikekogan",
                dateText: "Sun, Jun 14",
                presentation: .storyboardImage
            )
        ]
    }

    private var homeFeedPosts: [HomeFeedPost] {
        storyboardFeedPosts
    }
}

struct HomeLoopingVideoBackground: UIViewRepresentable {
    let resourceName: String
    var resourceExtension = "mp4"
    /// Home banners stay silent; the intro closing shot is the exception that keeps its soundtrack.
    var isMuted = true
    /// False while the view is still on screen but no longer the one being watched — a TabView
    /// keeps neighbouring pages alive, so this is what stops their sound.
    var isPlaying = true

    func makeUIView(context: Context) -> HomeLoopingVideoPlayerView {
        let view = HomeLoopingVideoPlayerView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.configure(
            resourceName: resourceName,
            resourceExtension: resourceExtension,
            isMuted: isMuted,
            isPlaying: isPlaying
        )
        return view
    }

    func updateUIView(_ uiView: HomeLoopingVideoPlayerView, context: Context) {
        uiView.setMuted(isMuted)
        uiView.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ uiView: HomeLoopingVideoPlayerView, coordinator: ()) {
        uiView.stop()
    }
}

final class HomeLoopingVideoPlayerView: UIView {
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var becomeActiveObserver: NSObjectProtocol?
    private var shouldPlay = true

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stop()
    }

    func configure(
        resourceName: String,
        resourceExtension: String,
        isMuted: Bool = true,
        isPlaying: Bool = true
    ) {
        shouldPlay = isPlaying

        guard queuePlayer == nil else {
            setPlaying(isPlaying)
            return
        }

        guard let url = Self.resourceURL(named: resourceName, extension: resourceExtension) else {
            print("[Journaltopia] Missing bundled video: \(resourceName).\(resourceExtension)")
            return
        }

        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = isMuted
        let templateItem = AVPlayerItem(url: url)
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)
        playerLayer.player = queuePlayer
        self.queuePlayer = queuePlayer

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.playIfNeeded()
        }

        setPlaying(isPlaying)
    }

    func setMuted(_ isMuted: Bool) {
        queuePlayer?.isMuted = isMuted
    }

    func setPlaying(_ isPlaying: Bool) {
        shouldPlay = isPlaying

        if isPlaying {
            playIfNeeded()
        } else {
            queuePlayer?.pause()
        }
    }

    func playIfNeeded() {
        guard shouldPlay, let queuePlayer else {
            return
        }

        if queuePlayer.timeControlStatus != .playing {
            queuePlayer.play()
        }
    }

    func stop() {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }

        queuePlayer?.pause()
        playerLooper?.disableLooping()
        playerLooper = nil
        playerLayer.player = nil
        queuePlayer?.removeAllItems()
        queuePlayer = nil
    }

    /// Device file systems are case-sensitive; the simulator's is not. Try the given
    /// extension, then its lower- and upper-cased forms, so `MOV` still resolves as `mov`.
    private static func resourceURL(named name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext.lowercased())
            ?? Bundle.main.url(forResource: name, withExtension: ext.uppercased())
    }
}

private struct HomeCardNavigationIndicator: View {
    var isEnabled = true
    var systemName = "chevron.right"
    var style: Style = .standard

    enum Style {
        case standard
        case accent
    }

    private var foregroundOpacity: Double {
        isEnabled ? 0.96 : 0.54
    }

    private var background: some ShapeStyle {
        switch style {
        case .standard:
            return Color.black.opacity(isEnabled ? 0.36 : 0.22)
        case .accent:
            return Color.homeAccent.opacity(isEnabled ? 0.98 : 0.45)
        }
    }

    private var strokeOpacity: Double {
        switch style {
        case .standard:
            return isEnabled ? 0.38 : 0.2
        case .accent:
            return isEnabled ? 0.56 : 0.24
        }
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: style == .accent ? 15 : 12, weight: .black))
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .frame(width: 32, height: 32)
            .background(background, in: Circle())
            .overlay(
                Circle()
                    .stroke(.white.opacity(strokeOpacity), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

private enum HomeCardLayout {
    static let primaryHeight: CGFloat = 160
    static let verticalPadding: CGFloat = 14
}

private extension View {
    /// Dark halo that follows the letterforms so white type stays readable on bright video.
    func homeBannerTitleContrast() -> some View {
        self
            .shadow(color: .black.opacity(0.95), radius: 1.2, x: 0, y: 0)
            .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
    }

    func homeBannerSubtitleContrast() -> some View {
        self
            .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 0)
            .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 1)
    }
}

private struct HomeBannerLeadingGradient: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.55)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .allowsHitTesting(false)
    }
}

private struct HomeNavigationCard: View {
    let title: String
    let subtitle: String
    let backgroundImageName: String
    var backgroundVideoName: String? = nil
    let contentAlignment: HorizontalAlignment
    let action: () -> Void

    private var isTrailingAligned: Bool {
        contentAlignment == .trailing
    }

    private var textAlignment: TextAlignment {
        isTrailingAligned ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        isTrailingAligned ? .trailing : .leading
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: contentAlignment, spacing: 8) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(textAlignment)
                    .homeBannerTitleContrast()

                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.96))
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .homeBannerSubtitleContrast()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, HomeCardLayout.verticalPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: HomeCardLayout.primaryHeight,
                maxHeight: HomeCardLayout.primaryHeight,
                alignment: frameAlignment
            )
            .background {
                cardBackground
                    .overlay(HomeBannerLeadingGradient())
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                HomeCardNavigationIndicator()
                    .padding(14)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(title)")
    }

    @ViewBuilder
    private var cardBackground: some View {
        if let backgroundVideoName {
            HomeLoopingVideoBackground(resourceName: backgroundVideoName)
        } else {
            Image(backgroundImageName)
                .resizable()
                .scaledToFill()
        }
    }
}

private struct HomeStorySoFarCard: View {
    let isEnabled: Bool
    let isLoading: Bool
    let action: () -> Void

    private var subtitle: String {
        if isLoading {
            return "Loading your completed\nstoryboards."
        }

        if isEnabled {
            return "Revisit your completed\nstoryboards in one view."
        }

        return "Completed storyboards\nwill appear here."
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text("The Story So Far...")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .homeBannerTitleContrast()

                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.92)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.96))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .homeBannerSubtitleContrast()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, HomeCardLayout.verticalPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: HomeCardLayout.primaryHeight,
                maxHeight: HomeCardLayout.primaryHeight,
                alignment: .leading
            )
            .background {
                HomeLoopingVideoBackground(resourceName: "home_story_so_far")
                    .overlay(HomeBannerLeadingGradient())
                    .overlay(Color.black.opacity(isEnabled ? 0 : 0.18))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                HomeCardNavigationIndicator(isEnabled: isEnabled)
                    .padding(14)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(height: HomeCardLayout.primaryHeight)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(!isEnabled)
        .accessibilityLabel("The Story So Far")
        .accessibilityHint(isEnabled ? "Opens your storyboards in a vertical view" : "Completed storyboards will appear here")
    }
}

struct HomeStoryboardVerticalViewer: View {
    let storyboards: [GeneratedStoryboard]
    @Binding var currentPageIndex: Int
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var visiblePageIndex: Int

    init(
        storyboards: [GeneratedStoryboard],
        currentPageIndex: Binding<Int>,
        title: String
    ) {
        self.storyboards = storyboards
        _currentPageIndex = currentPageIndex
        self.title = title
        _visiblePageIndex = State(initialValue: currentPageIndex.wrappedValue)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            HomeZoomableVerticalStoryboardView(
                storyboards: storyboards,
                title: title,
                initialPageIndex: clampedPageIndex(currentPageIndex),
                visiblePageIndex: $visiblePageIndex
            )
            .background(Color.black)
            .onChange(of: visiblePageIndex) { nextIndex in
                currentPageIndex = clampedPageIndex(nextIndex)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close vertical story view")
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, totalPageCount - 1))
    }

    private var totalPageCount: Int {
        storyboards.count + 1
    }
}

private struct HomeZoomableVerticalStoryboardView: UIViewRepresentable {
    let storyboards: [GeneratedStoryboard]
    let title: String
    let initialPageIndex: Int
    @Binding var visiblePageIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        context.coordinator.stackView = stackView
        context.coordinator.pageViews = []

        let coverView = makeCoverView()
        stackView.addArrangedSubview(coverView)
        context.coordinator.pageViews.append(coverView)

        storyboards.enumerated().forEach { index, storyboard in
            let pageIndex = index + 1
            stackView.addArrangedSubview(
                makeImageBoundary(pageIndex: pageIndex, totalCount: storyboards.count)
            )

            let image = storyboard.image
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let pageView = UIView()
            pageView.backgroundColor = .black
            pageView.translatesAutoresizingMaskIntoConstraints = false
            pageView.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: pageView.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
                pageView.heightAnchor.constraint(
                    equalTo: pageView.widthAnchor,
                    multiplier: image.size.height / max(image.size.width, 1)
                )
            ])

            stackView.addArrangedSubview(pageView)
            context.coordinator.pageViews.append(pageView)
        }

        let bottomSpacer = UIView()
        bottomSpacer.backgroundColor = .black
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacer.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stackView.addArrangedSubview(bottomSpacer)

        DispatchQueue.main.async {
            context.coordinator.scrollToInitialPage(in: scrollView)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
    }

    private func makeCoverView() -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .homeStorySoFarTitleFont
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let subtitleLabel = UILabel()
        subtitleLabel.text = "A continuous view of your completed storyboards."
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.86)
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        let countLabel = UILabel()
        countLabel.text = storyboards.count == 1 ? "1 storyboard" : "\(storyboards.count) storyboards"
        countLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textAlignment = .center
        countLabel.numberOfLines = 1

        [titleLabel, subtitleLabel, countLabel].forEach(stack.addArrangedSubview)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 56),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -44)
        ])

        return container
    }

    private func makeImageBoundary(pageIndex: Int, totalCount: Int) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.035, alpha: 1)
        container.translatesAutoresizingMaskIntoConstraints = false

        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.86)
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        let numberLabel = UILabel()
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.text = "\(pageIndex) / \(totalCount)"
        numberLabel.font = .systemFont(ofSize: 12, weight: .heavy)
        numberLabel.textColor = .white
        numberLabel.textAlignment = .center
        numberLabel.backgroundColor = UIColor(white: 0.035, alpha: 1)
        numberLabel.layer.cornerRadius = 12
        numberLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        numberLabel.layer.borderWidth = 1
        numberLabel.layer.masksToBounds = true
        container.addSubview(numberLabel)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 42),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            numberLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            numberLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            numberLabel.heightAnchor.constraint(equalToConstant: 24)
        ])

        return container
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: HomeZoomableVerticalStoryboardView
        weak var stackView: UIStackView?
        var pageViews: [UIView] = []
        private var didScrollToInitialPage = false

        init(parent: HomeZoomableVerticalStoryboardView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            stackView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisibleIndex(in: scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateVisibleIndex(in: scrollView)
        }

        func scrollToInitialPage(in scrollView: UIScrollView) {
            guard
                !didScrollToInitialPage,
                pageViews.indices.contains(parent.initialPageIndex)
            else {
                return
            }

            scrollView.layoutIfNeeded()
            stackView?.layoutIfNeeded()

            let pageView = pageViews[parent.initialPageIndex]
            let targetY = max(
                0,
                pageView.frame.midY - (scrollView.bounds.height / 2)
            )
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            didScrollToInitialPage = true
            updateVisibleIndex(in: scrollView)
        }

        private func updateVisibleIndex(in scrollView: UIScrollView) {
            guard !pageViews.isEmpty else {
                return
            }

            let viewportCenterY = scrollView.contentOffset.y + (scrollView.bounds.height / 2)
            let zoomScale = scrollView.zoomScale
            let closestIndex = pageViews.indices.min { left, right in
                abs((pageViews[left].frame.midY * zoomScale) - viewportCenterY)
                    < abs((pageViews[right].frame.midY * zoomScale) - viewportCenterY)
            }

            guard
                let closestIndex,
                closestIndex != parent.visiblePageIndex
            else {
                return
            }

            parent.visiblePageIndex = closestIndex
        }
    }
}

private extension UIFont {
    static var homeStorySoFarTitleFont: UIFont {
        let baseDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        let serifDescriptor = baseDescriptor.withDesign(.serif) ?? baseDescriptor
        let boldDescriptor = serifDescriptor.withSymbolicTraits(.traitBold) ?? serifDescriptor
        return UIFont(descriptor: boldDescriptor, size: 34)
    }
}

private enum ChapterPostDemoLayout {
    static let fullPageHeight: CGFloat = 510
    static let cardImageWidth: CGFloat = 242
    static let cardImageHeight: CGFloat = 363
    static let cardsDemoHeight: CGFloat = 412
    static let feedBookHeight: CGFloat = fullPageHeight
    static let feedStackHeight: CGFloat = 388
    static let collectionCarouselHeight: CGFloat = 430
    static let fanShelfHeight: CGFloat = 430
}

private struct HomeFeedPost: Identifiable {
    let id = UUID()
    let entry: PrototypeEntry
    let username: String
    let dateText: String
    let presentation: HomeFeedPresentation
}

private enum HomeFeedPresentation {
    case storyboardImage
    case singleImage
    case pageCurlBook(startIndex: Int)
    case swipeCardStack(startIndex: Int)
    case fanCardStack(startIndex: Int)

    var initialPageIndex: Int {
        switch self {
        case .storyboardImage, .singleImage:
            return 0
        case .pageCurlBook(let startIndex):
            return startIndex
        case .swipeCardStack(let startIndex):
            return startIndex
        case .fanCardStack(let startIndex):
            return startIndex
        }
    }
}

private struct HomeStoryboardFeedImage: View {
    let imageName: String
    let onTap: () -> Void

    private var aspectRatio: CGFloat {
        guard let image = UIImage(named: imageName),
              image.size.height > 0 else {
            return 1
        }

        return image.size.width / image.size.height
    }

    var body: some View {
        Button(action: onTap) {
            Image(imageName)
                .resizable()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.homeCardGray)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open storyboard image full screen")
    }
}

private struct HomeImagePreviewSheet: View {
    let imageName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            HomeZoomableImageView(imageName: imageName)
                .ignoresSafeArea()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close image")
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

private struct HomeZoomableImageView: UIViewRepresentable {
    let imageName: String

    func makeUIView(context _: Context) -> HomeZoomableImageScrollView {
        let scrollView = HomeZoomableImageScrollView()
        scrollView.setImage(UIImage(named: imageName))
        return scrollView
    }

    func updateUIView(_ scrollView: HomeZoomableImageScrollView, context _: Context) {
        scrollView.setImage(UIImage(named: imageName))
    }
}

private final class HomeZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else {
            return
        }

        imageView.image = image
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutImageIfNeeded()
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func configure() {
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
    }

    private func layoutImageIfNeeded() {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else {
            imageView.frame = bounds
            contentSize = bounds.size
            return
        }

        guard zoomScale == minimumZoomScale || imageView.frame == .zero else {
            return
        }

        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fittedSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
    }

    private func centerImage() {
        let horizontalInset = max((bounds.width - contentSize.width) / 2, 0)
        let verticalInset = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }
}

private struct ChapterScrollPageDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int

    var body: some View {
        VStack(spacing: 10) {
            ChapterPageSwipeView(imageNames: imageNames, currentIndex: $selectedPageIndex)
                .frame(height: ChapterPostDemoLayout.fullPageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
                )

            HStack {
                Text("UIPageViewController scroll")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }
}

private enum ChapterCollectionCarouselStyle {
    case groupPagingCentered
    case continuousLeading

    var label: String {
        switch self {
        case .groupPagingCentered:
            return "UICollectionView centered group paging"
        case .continuousLeading:
            return "UICollectionView leading snap shelf"
        }
    }
}

private struct ChapterCollectionCarouselDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int
    let style: ChapterCollectionCarouselStyle

    var body: some View {
        VStack(spacing: 10) {
            ChapterCollectionCarouselView(
                imageNames: imageNames,
                currentIndex: $selectedPageIndex,
                style: style
            )
            .frame(height: ChapterPostDemoLayout.collectionCarouselHeight)
            .background(Color.homeCardGray)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
            )

            HStack {
                Text(style.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }
}

private struct ChapterFanShelfDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int
    @State private var fanDragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let cardWidth = min(geometry.size.width * 0.64, (geometry.size.height - 44) / 1.48)
                let cardHeight = cardWidth * 1.48

                ZStack {
                    Color.homeCardGray

                    ForEach(visibleIndices, id: \.self) { index in
                        let distance = index - selectedPageIndex

                        ChapterFanShelfCard(
                            imageName: imageNames[index]
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(fanScale(for: distance, cardWidth: cardWidth))
                        .rotationEffect(.degrees(fanRotation(for: distance, cardWidth: cardWidth)))
                        .offset(
                            x: fanXOffset(for: distance, cardWidth: cardWidth),
                            y: fanYOffset(for: distance, cardWidth: cardWidth)
                        )
                        .shadow(color: Color.storyInk.opacity(distance == 0 ? 0.18 : 0.08), radius: distance == 0 ? 16 : 8, y: 8)
                        .zIndex(fanZIndex(for: distance, cardWidth: cardWidth))
                    }
                }
                .contentShape(Rectangle())
                .gesture(fanDragGesture)
                .animation(fanSpring, value: selectedPageIndex)
            }
            .frame(height: ChapterPostDemoLayout.fanShelfHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
            )

            HStack {
                Text("Custom stacked shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }

    private var visibleIndices: [Int] {
        imageNames.indices.filter { index in
            index >= selectedPageIndex - 6 && index <= selectedPageIndex + 6
        }
    }

    private var fanDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                fanDragOffset = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 80
                let projectedTranslation = value.predictedEndTranslation.width
                let shouldAdvance = value.translation.width < -threshold || projectedTranslation < -threshold * 1.25
                let shouldReverse = value.translation.width > threshold || projectedTranslation > threshold * 1.25

                withAnimation(fanSpring) {
                    if shouldAdvance {
                        selectedPageIndex = min(selectedPageIndex + 1, imageNames.count - 1)
                    } else if shouldReverse {
                        selectedPageIndex = max(selectedPageIndex - 1, 0)
                    }

                    fanDragOffset = 0
                }
            }
    }

    private var fanSpring: Animation {
        .interactiveSpring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    }

    private func fanXOffset(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let position = fanPosition(for: distance, cardWidth: cardWidth)
        let absPosition = abs(position)

        guard absPosition > 0.001 else {
            return 0
        }

        let direction: CGFloat = position < 0 ? -1 : 1
        let stackOffset = cardWidth * 0.58

        if absPosition <= 1 {
            return position * stackOffset
        }

        return direction * (stackOffset + (absPosition - 1) * 10)
    }

    private func fanYOffset(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let position = fanPosition(for: distance, cardWidth: cardWidth)

        return min(abs(position) * 5, 24)
    }

    private func fanScale(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let absPosition = abs(fanPosition(for: distance, cardWidth: cardWidth))
        let sideProgress = min(absPosition, 1)
        let depthProgress = max(absPosition - 1, 0)

        return max(0.74, 1 - sideProgress * 0.14 - depthProgress * 0.018)
    }

    private func fanRotation(for distance: Int, cardWidth: CGFloat) -> Double {
        let position = fanPosition(for: distance, cardWidth: cardWidth)
        return Double(max(min(position, 3), -3)) * 1.15
    }

    private func fanZIndex(for distance: Int, cardWidth: CGFloat) -> Double {
        let position = abs(fanPosition(for: distance, cardWidth: cardWidth))
        return 100 - Double(position)
    }

    private func fanPosition(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let dragStep = cardWidth * 0.64
        let clampedDrag = min(max(fanDragOffset, -dragStep), dragStep)
        return CGFloat(distance) + clampedDrag / dragStep
    }

}

private struct ChapterFanShelfCard: View {
    let imageName: String
    private let cornerRadius: CGFloat = 7

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.92), lineWidth: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.55), lineWidth: 1)
            )
    }
}

private struct ChapterCardsDemo: View {
    let imageNames: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(Array(imageNames.enumerated()), id: \.offset) { index, imageName in
                    VStack(alignment: .leading, spacing: 8) {
                        ChapterPageImage(imageName: imageName, cornerRadius: 7)
                            .frame(
                                width: ChapterPostDemoLayout.cardImageWidth,
                                height: ChapterPostDemoLayout.cardImageHeight
                            )

                        HStack {
                            Text("Page \(index + 1)")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Color.storyInk)

                            Spacer()

                            Text("\(index + 1)/\(imageNames.count)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.homeMutedText)
                        }
                    }
                    .padding(9)
                    .frame(width: 260)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.homeBorder.opacity(0.86), lineWidth: 1)
                    )
                    .shadow(color: Color.storyInk.opacity(0.08), radius: 8, y: 4)
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, 34)
        }
        .frame(height: ChapterPostDemoLayout.cardsDemoHeight)
    }
}

private struct ChapterBookDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.homeCardGray

                ChapterPageCurlView(imageNames: imageNames, currentIndex: $selectedPageIndex)
                    .frame(height: ChapterPostDemoLayout.fullPageHeight)
            }
            .frame(height: ChapterPostDemoLayout.fullPageHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
            )

            HStack {
                Text("Drag the page edge to curl")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }
}

private struct ChapterPageCounter: View {
    let currentIndex: Int
    let totalCount: Int

    var body: some View {
        Text("\(currentIndex + 1)/\(totalCount)")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.storyInk.opacity(0.72), in: Capsule())
            .accessibilityLabel("Page \(currentIndex + 1) of \(totalCount)")
    }
}

private struct ChapterPageImage: View {
    let imageName: String
    let cornerRadius: CGFloat

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color.homeCardGray)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.7), lineWidth: 1)
            )
    }
}

private struct ChapterPageSwipeView: UIViewControllerRepresentable {
    let imageNames: [String]
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear

        if let initialViewController = context.coordinator.viewController(for: currentIndex) {
            pageViewController.setViewControllers(
                [initialViewController],
                direction: .forward,
                animated: false
            )
        }

        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self

        guard context.coordinator.displayedIndex != currentIndex,
              let targetViewController = context.coordinator.viewController(for: currentIndex) else {
            return
        }

        let direction: UIPageViewController.NavigationDirection = currentIndex > context.coordinator.displayedIndex ? .forward : .reverse
        pageViewController.setViewControllers(
            [targetViewController],
            direction: direction,
            animated: true
        )
        context.coordinator.displayedIndex = currentIndex
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ChapterPageSwipeView
        var displayedIndex: Int

        init(_ parent: ChapterPageSwipeView) {
            self.parent = parent
            self.displayedIndex = parent.currentIndex
        }

        func viewController(for index: Int) -> UIViewController? {
            guard parent.imageNames.indices.contains(index) else {
                return nil
            }

            let pageView = ChapterPageImage(imageName: parent.imageNames[index], cornerRadius: 0)
                .ignoresSafeArea()
            let hostingController = UIHostingController(rootView: pageView)
            hostingController.view.backgroundColor = .clear
            hostingController.view.tag = index
            return hostingController
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let visibleViewController = pageViewController.viewControllers?.first else {
                return
            }

            displayedIndex = visibleViewController.view.tag
            parent.currentIndex = displayedIndex
        }
    }
}

private struct ChapterCollectionCarouselView: UIViewRepresentable {
    let imageNames: [String]
    @Binding var currentIndex: Int
    let style: ChapterCollectionCarouselStyle

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.reuseIdentifier)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.reloadData()

        let indexPath = IndexPath(item: currentIndex, section: 0)
        if imageNames.indices.contains(currentIndex) {
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupWidth: CGFloat = style == .groupPagingCentered ? 0.76 : 0.84
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(groupWidth),
            heightDimension: .fractionalHeight(0.92)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = style == .groupPagingCentered ? 14 : 10
        section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        section.orthogonalScrollingBehavior = style == .groupPagingCentered ? .groupPagingCentered : .continuousGroupLeadingBoundary
        section.visibleItemsInvalidationHandler = { visibleItems, offset, environment in
            let centerX = offset.x + environment.container.contentSize.width / 2

            for item in visibleItems {
                let distance = abs(item.frame.midX - centerX)
                let normalizedDistance = min(distance / environment.container.contentSize.width, 1)
                let scale = 1 - normalizedDistance * 0.12
                item.transform = CGAffineTransform(scaleX: scale, y: scale)
                item.alpha = 1 - normalizedDistance * 0.18
            }
        }

        return UICollectionViewCompositionalLayout(section: section)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        static let reuseIdentifier = "ChapterCollectionCarouselCell"

        var parent: ChapterCollectionCarouselView

        init(_ parent: ChapterCollectionCarouselView) {
            self.parent = parent
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.imageNames.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseIdentifier, for: indexPath)
            let imageName = parent.imageNames[indexPath.item]
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.isOpaque = false
            cell.contentConfiguration = UIHostingConfiguration {
                ChapterCarouselCard(imageName: imageName, pageNumber: indexPath.item + 1, totalCount: parent.imageNames.count)
            }
            .margins(.all, 0)
            return cell
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateCurrentIndex(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                updateCurrentIndex(in: scrollView)
            }
        }

        private func updateCurrentIndex(in scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView,
                  let centeredIndexPath = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX + collectionView.contentOffset.x, y: collectionView.bounds.midY)) else {
                return
            }

            parent.currentIndex = centeredIndexPath.item
        }
    }
}

private struct ChapterCarouselCard: View {
    let imageName: String
    let pageNumber: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ChapterPageImage(imageName: imageName, cornerRadius: 7)

            HStack {
                Text("Page \(pageNumber)")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Text("\(pageNumber)/\(totalCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.homeMutedText)
            }
        }
        .padding(9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.86), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.1), radius: 12, y: 6)
    }
}

private struct ChapterPageCurlView: UIViewControllerRepresentable {
    let imageNames: [String]
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear
        pageViewController.view.clipsToBounds = false
        pageViewController.view.subviews.forEach { $0.clipsToBounds = false }
        pageViewController.isDoubleSided = false

        if let initialViewController = context.coordinator.viewController(for: currentIndex) {
            pageViewController.setViewControllers(
                [initialViewController],
                direction: .forward,
                animated: false
            )
        }

        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        pageViewController.view.clipsToBounds = false
        pageViewController.view.subviews.forEach { $0.clipsToBounds = false }

        guard context.coordinator.displayedIndex != currentIndex,
              let targetViewController = context.coordinator.viewController(for: currentIndex) else {
            return
        }

        let direction: UIPageViewController.NavigationDirection = currentIndex > context.coordinator.displayedIndex ? .forward : .reverse
        pageViewController.setViewControllers(
            [targetViewController],
            direction: direction,
            animated: true
        )
        context.coordinator.displayedIndex = currentIndex
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ChapterPageCurlView
        var displayedIndex: Int

        init(_ parent: ChapterPageCurlView) {
            self.parent = parent
            self.displayedIndex = parent.currentIndex
        }

        func viewController(for index: Int) -> UIViewController? {
            guard parent.imageNames.indices.contains(index) else {
                return nil
            }

            let pageView = ChapterPageImage(imageName: parent.imageNames[index], cornerRadius: 0)
                .ignoresSafeArea()
            let hostingController = UIHostingController(rootView: pageView)
            hostingController.view.backgroundColor = .clear
            hostingController.view.clipsToBounds = false
            hostingController.view.tag = index
            return hostingController
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let visibleViewController = pageViewController.viewControllers?.first else {
                return
            }

            displayedIndex = visibleViewController.view.tag
            parent.currentIndex = displayedIndex
        }
    }
}

private struct HomeSocialFeedCard: View {
    let entry: PrototypeEntry
    let accentColor: Color
    let username: String
    let dateText: String
    let presentation: HomeFeedPresentation
    let onImageTap: (String) -> Void
    let onUsernameTap: () -> Void
    @State private var currentSingleImageIndex: Int
    @State private var currentBookPageIndex: Int
    @State private var currentStackPageIndex: Int
    @GestureState private var stackDragOffset: CGFloat = 0

    private var activeSingleImageName: String? {
        guard entry.imageNames.indices.contains(currentSingleImageIndex) else {
            return entry.imageNames.first
        }

        return entry.imageNames[currentSingleImageIndex]
    }

    init(
        entry: PrototypeEntry,
        accentColor: Color,
        username: String,
        dateText: String,
        presentation: HomeFeedPresentation = .storyboardImage,
        onImageTap: @escaping (String) -> Void,
        onUsernameTap: @escaping () -> Void
    ) {
        self.entry = entry
        self.accentColor = accentColor
        self.username = username
        self.dateText = dateText
        self.presentation = presentation
        self.onImageTap = onImageTap
        self.onUsernameTap = onUsernameTap
        let maximumPageIndex = max(entry.imageNames.count - 1, 0)
        let initialPageIndex = min(max(presentation.initialPageIndex, 0), maximumPageIndex)
        _currentSingleImageIndex = State(initialValue: initialPageIndex)
        _currentBookPageIndex = State(initialValue: initialPageIndex)
        _currentStackPageIndex = State(initialValue: initialPageIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            feedHeader
                .zIndex(0)
            feedImage
                .zIndex(imageLayerZIndex)
            feedCaption
                .zIndex(captionLayerZIndex)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.08), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var feedHeader: some View {
        HStack(spacing: 10) {
            Button(action: onUsernameTap) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [accentColor.opacity(0.9), Color.storyRose.opacity(0.86), Color.storyGold.opacity(0.84)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Circle()
                            .fill(Color.white)
                            .frame(width: 32, height: 32)

                        Circle()
                            .fill(Color.homeCardGray)
                            .frame(width: 28, height: 28)

                        Image(systemName: "person.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.homeMutedText)
                    }
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(username)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Color.storyInk)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text(dateText)
                            Text("•")
                            Text(entry.time)
                            if let location = entry.location {
                                Text("•")
                                Text(location)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                        .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(username)'s profile")

            Spacer(minLength: 8)

            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk.opacity(0.58))
                .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var feedImage: some View {
        switch presentation {
        case .storyboardImage:
            feedStoryboardImage
        case .pageCurlBook:
            feedBookImage
        case .swipeCardStack:
            feedSwipeCardStackImage
        case .fanCardStack:
            feedFanCardStackImage
        case .singleImage:
            feedSingleImage
        }
    }

    @ViewBuilder
    private var feedStoryboardImage: some View {
        if let imageName = entry.imageNames.first {
            HomeStoryboardFeedImage(imageName: imageName) {
                onImageTap(imageName)
            }
        } else {
            Color.homeCardGray
                .frame(height: 260)
        }
    }

    @ViewBuilder
    private var feedSingleImage: some View {
        if let activeSingleImageName {
            Image(activeSingleImageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 345, alignment: .top)
                .clipped()
                .id(activeSingleImageName)
                .overlay(alignment: .topTrailing) {
                    if entry.imageNames.count > 1 {
                        Text("\(currentSingleImageIndex + 1)/\(entry.imageNames.count)")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Color.black.opacity(0.48), in: Capsule())
                            .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .gesture(singleImageSwipeGesture)
                .animation(.easeInOut(duration: 0.18), value: currentSingleImageIndex)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(accentColor.opacity(0.56))

                Text(entry.body)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 282)
            .padding(22)
            .background(Color.homeCardGray)
        }
    }

    private var feedBookImage: some View {
        ZStack {
            Color.homeCardGray

            ChapterPageCurlView(imageNames: entry.imageNames, currentIndex: $currentBookPageIndex)
                .frame(maxWidth: .infinity)
                .frame(height: ChapterPostDemoLayout.feedBookHeight)
                .zIndex(0)

            Label("Chapter", systemImage: "book.closed.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.storyInk.opacity(0.62), in: Capsule())
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(1)

            ChapterPageCounter(
                    currentIndex: currentBookPageIndex,
                    totalCount: entry.imageNames.count
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(1)
        }
        .frame(height: ChapterPostDemoLayout.feedBookHeight)
    }

    private var feedSwipeCardStackImage: some View {
        GeometryReader { geometry in
            let cardWidth = min(geometry.size.width * 0.66, 238)
            let cardHeight = geometry.size.height - 46

            ZStack {
                Color.homeCardGray

                ForEach(entry.imageNames.indices.reversed(), id: \.self) { index in
                    let distance = index - currentStackPageIndex

                    if abs(distance) <= 2 {
                        HomeSwipeThroughCard(
                            imageName: entry.imageNames[index],
                            title: stackCardTitle(for: index),
                            subtitle: stackCardSubtitle(for: index),
                            likes: stackCardLikes(for: index),
                            accentColor: accentColor
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(stackCardScale(for: distance))
                        .rotationEffect(.degrees(stackCardRotation(for: distance)))
                        .offset(x: stackCardOffset(for: distance), y: abs(distance) == 0 ? 0 : 6)
                        .shadow(color: Color.storyInk.opacity(abs(distance) == 0 ? 0.18 : 0.08), radius: abs(distance) == 0 ? 16 : 8, y: 8)
                        .zIndex(stackCardZIndex(for: distance))
                    }
                }

                ChapterPageCounter(
                    currentIndex: currentStackPageIndex,
                    totalCount: entry.imageNames.count
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .contentShape(Rectangle())
            .gesture(stackSwipeGesture)
        }
        .frame(height: ChapterPostDemoLayout.feedStackHeight)
    }

    private var feedFanCardStackImage: some View {
        GeometryReader { geometry in
            let cardWidth = min(geometry.size.width * 0.62, (geometry.size.height - 38) / 1.48)
            let cardHeight = cardWidth * 1.48

            ZStack {
                Color.homeCardGray

                ForEach(fanFeedVisibleIndices, id: \.self) { index in
                    let distance = index - currentStackPageIndex
                    let position = fanFeedPosition(for: distance, cardWidth: cardWidth)

                    ChapterFanShelfCard(imageName: entry.imageNames[index])
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(fanFeedScale(for: position))
                        .rotationEffect(.degrees(fanFeedRotation(for: position)))
                        .offset(
                            x: fanFeedXOffset(for: position, cardWidth: cardWidth),
                            y: fanFeedYOffset(for: position)
                        )
                        .shadow(
                            color: Color.storyInk.opacity(abs(position) < 0.5 ? 0.18 : 0.08),
                            radius: abs(position) < 0.5 ? 16 : 8,
                            y: 8
                        )
                        .zIndex(fanFeedZIndex(for: position))
                }

                ChapterPageCounter(
                    currentIndex: currentStackPageIndex,
                    totalCount: entry.imageNames.count
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(120)
            }
            .contentShape(Rectangle())
            .gesture(stackSwipeGesture)
        }
        .frame(height: ChapterPostDemoLayout.feedStackHeight)
    }

    private var feedCaption: some View {
        VStack(alignment: .leading, spacing: 7) {
            (
                Text(entry.title)
                    .fontWeight(.heavy)
                + Text(" \(entry.body)")
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.storyInk.opacity(0.86))
            .lineSpacing(2)
            .lineLimit(3)

            if entry.imageNames.count > 1 {
                HStack(spacing: 5) {
                    ForEach(entry.imageNames.indices, id: \.self) { index in
                        Circle()
                            .fill(index == activeImageIndex ? accentColor : Color.homeBorder)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 13)
    }

    private var activeImageIndex: Int {
        switch presentation {
        case .storyboardImage, .singleImage:
            return currentSingleImageIndex
        case .pageCurlBook:
            return currentBookPageIndex
        case .swipeCardStack, .fanCardStack:
            return currentStackPageIndex
        }
    }

    private var imageLayerZIndex: Double {
        switch presentation {
        case .storyboardImage, .singleImage:
            return 0
        case .pageCurlBook, .swipeCardStack, .fanCardStack:
            return 3
        }
    }

    private var captionLayerZIndex: Double {
        0
    }

    private var singleImageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard entry.imageNames.count > 1 else {
                    return
                }

                let threshold: CGFloat = 44
                if value.translation.width < -threshold {
                    currentSingleImageIndex = min(currentSingleImageIndex + 1, entry.imageNames.count - 1)
                } else if value.translation.width > threshold {
                    currentSingleImageIndex = max(currentSingleImageIndex - 1, 0)
                }
            }
    }

    private var stackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($stackDragOffset) { value, state, _ in
                state = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 44
                if value.translation.width < -threshold {
                    currentStackPageIndex = min(currentStackPageIndex + 1, entry.imageNames.count - 1)
                } else if value.translation.width > threshold {
                    currentStackPageIndex = max(currentStackPageIndex - 1, 0)
                }
            }
    }

    private func stackCardOffset(for distance: Int) -> CGFloat {
        CGFloat(distance) * 44 + stackDragOffset
    }

    private func stackCardScale(for distance: Int) -> CGFloat {
        max(0.86, 1 - CGFloat(abs(distance)) * 0.07)
    }

    private func stackCardRotation(for distance: Int) -> Double {
        Double(distance) * 2.5
    }

    private func stackCardZIndex(for distance: Int) -> Double {
        Double(10 - abs(distance))
    }

    private var fanFeedVisibleIndices: [Int] {
        entry.imageNames.indices.filter { index in
            index >= currentStackPageIndex - 5 && index <= currentStackPageIndex + 5
        }
    }

    private func fanFeedPosition(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let dragStep = cardWidth * 0.74
        let clampedDrag = min(max(stackDragOffset, -dragStep), dragStep)
        return CGFloat(distance) + clampedDrag / dragStep
    }

    private func fanFeedXOffset(for position: CGFloat, cardWidth: CGFloat) -> CGFloat {
        let absPosition = abs(position)

        guard absPosition > 0.001 else {
            return 0
        }

        let direction: CGFloat = position < 0 ? -1 : 1
        let firstStackOffset = cardWidth * 0.17

        if absPosition <= 1 {
            return position * firstStackOffset
        }

        return direction * (firstStackOffset + (absPosition - 1) * 12)
    }

    private func fanFeedYOffset(for position: CGFloat) -> CGFloat {
        min(abs(position) * 4, 20)
    }

    private func fanFeedScale(for position: CGFloat) -> CGFloat {
        let absPosition = abs(position)
        let depthProgress = max(absPosition - 1, 0)

        return max(0.84, 1 - min(absPosition, 1) * 0.04 - depthProgress * 0.012)
    }

    private func fanFeedRotation(for position: CGFloat) -> Double {
        Double(max(min(position, 3), -3)) * 0.85
    }

    private func fanFeedZIndex(for position: CGFloat) -> Double {
        100 - Double(abs(position))
    }

    private func stackCardTitle(for index: Int) -> String {
        switch index {
        case 0:
            return "corner light"
        case 1:
            return "coffee run"
        case 2:
            return "new page"
        case 3:
            return "after rain"
        default:
            return "city note"
        }
    }

    private func stackCardSubtitle(for index: Int) -> String {
        index == currentStackPageIndex ? "Just added" : "\(index + 1) days ago"
    }

    private func stackCardLikes(for index: Int) -> Int {
        [7, 4, 12, 3, 9][index % 5]
    }
}

private struct HomeSwipeThroughCard: View {
    let imageName: String
    let title: String
    let subtitle: String
    let likes: Int
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(height: 174)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Color.storyInk)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 4)

            Text(subtitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.homeMutedText)

            HStack(spacing: 18) {
                Label("\(likes)", systemImage: "heart")
                Image(systemName: "bubble.right")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.storyInk)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.55), lineWidth: 1)
        )
    }
}
