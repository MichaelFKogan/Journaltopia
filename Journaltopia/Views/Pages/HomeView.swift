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
    var openRecentEntry: (CreateEntryDraft, UIImage?) -> Void = { _, _ in }
    var openRecentJournal: (PrototypeChapter) -> Void = { _ in }

    @State private var fullScreenImageName: String?
    @State private var isLoadingHomeStoryboards = false
    /// Seeded from the session cache because `ContentView` rebuilds `HomeView` from scratch on every
    /// return to Home. Without it the opening frames have nothing but local draft picks to show,
    /// which are the cards the reader sees swap once the cloud answer lands.
    @State private var recentEntries: [HomeRecentEntry] = HomeRecentEntrySessionCache.mostRecentEntries()
    @State private var loadedHomeSamplePack: SampleStoryPack?
    @State private var recentContentLoadTask: Task<Void, Never>?
    @State private var preparingRecentEntryID: UUID?
    /// Which card the scroll cue last brought to the leading edge. Driven by the button rather than
    /// measured from the scroll offset: a measured index can resolve to the card already on screen,
    /// and then a press asks the scroller to go where it already is and nothing happens.
    @State private var recentScrollCueIndex = 0

    private let homeStoryboardPreviewLimit = 3
    private let homeRecentContentLimit = 5
    /// Enough of the Edited: Newest page to apply the same `createdAt` tie-break Entries uses.
    private let homeRecentCloudEntryLimit = 8

    var body: some View {
        ZStack(alignment: .bottom) {
            WatercolorPaperPageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    homeCardGrid
                        .zIndex(2)
                    recentContentSection
                    myStorySection
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
            // Most Recent used to wait on the cover-image fetch, so the section spent that whole
            // round trip showing last session's cards — or local drafts ranked by on-device
            // `updatedAt` — before the cloud ranking landed. Kick the entry load off first; the
            // covers can arrive on their own.
            refreshRecentContent(loadsCloudEntry: true)
            await loadHomeStoryboards()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
        .onAppear {
            refreshRecentContent(loadsCloudEntry: false)
        }
        .onChange(of: selectedPage) { page in
            guard page == .home else {
                recentContentLoadTask?.cancel()
                return
            }

            refreshRecentContent(loadsCloudEntry: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaGeneratedStoryboardsChanged)) { _ in
            refreshRecentContent(loadsCloudEntry: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaJournalCoverChanged)) { _ in
            refreshRecentContent(loadsCloudEntry: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaSampleStoryPackChanged)) { _ in
            refreshRecentContent(loadsCloudEntry: false)
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

            HStack(spacing: 4) {
                if contentMode.requiresSignIn {
                    signInButton
                } else {
                    creditsButton
                }

                settingsButton
            }
            .padding(.top, 2)
        }
    }

    /// Signed out, there is no balance to show. Sign In replaces the credit badge and still
    /// opens the same Sign In to Journaltopia sheet every other account-required action uses.
    /// Settings stays in the trailing corner so Help, Extra, and account actions remain
    /// reachable without a tab.
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

    private var settingsButton: some View {
        NavigationLink {
            SettingsView(
                selectedPage: $selectedPage,
                generatedStoryboards: $generatedStoryboards,
                contentMode: contentMode
            )
                .enableInteractivePopGesture()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.65))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open settings")
    }

    private var homeCardGrid: some View {
        LazyVGrid(columns: HomeCardLayout.gridColumns, spacing: HomeCardLayout.gridSpacing) {
            heroCard

            HomeNavigationCard(
                title: "Entries",
                subtitle: "Write, edit, and turn your\nthoughts into storyboards.",
                backgroundImageName: "home_entries_card_bg",
                backgroundVideoName: "home_entries_card_bg",
                contentAlignment: .leading
            ) {
                openEntriesPage()
            }

            HomeNavigationCard(
                title: "Journals",
                subtitle: "Organize your stories\ninto meaningful journals.",
                backgroundImageName: "home_journals_card_bg",
                backgroundVideoName: "home_journals_card_bg",
                contentAlignment: .leading
            ) {
                openJournalsPage()
            }
        }
    }

    private var heroCard: some View {
        Button {
            openCreatePage()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("Create")
                    .font(.system(size: HomeCardLayout.titleSize, weight: .bold, design: .serif))
                    .lineSpacing(2)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .homeBannerTitleContrast()

                Text("Write about your day\nand turn it into a storyboard.")
                    .font(.system(size: HomeCardLayout.subtitleSize, weight: .medium))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.92))
                    .homeBannerSubtitleContrast()
            }
            .padding(.horizontal, HomeCardLayout.horizontalPadding)
            .padding(.vertical, HomeCardLayout.verticalPadding)
            .frame(maxWidth: .infinity, minHeight: HomeCardLayout.primaryHeight, alignment: .leading)
            .background {
                HomeLoopingVideoBackground(resourceName: "homepage_banner")
                    .overlay(HomeBannerLeadingGradient())
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                HomeCardNavigationIndicator(systemName: "plus", style: .accent)
                    .padding(HomeCardLayout.indicatorInset)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create")
        .accessibilityHint("Opens Create")
    }

    @ViewBuilder
    private var recentContentSection: some View {
        let recentEntries = homeRecentEntries()
        if !recentEntries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Most Recent")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)
                    .padding(.top, 6)

                ScrollViewReader { scrollProxy in
                    ZStack(alignment: .trailing) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(alignment: .top, spacing: HomeRecentContentLayout.gridSpacing) {
                                ForEach(recentEntries) { recentEntry in
                                    HomeRecentEntryCard(
                                        recent: recentEntry,
                                        isPreparing: preparingRecentEntryID == recentEntry.id
                                    ) {
                                        openRecentEntryCard(recentEntry)
                                    }
                                    .frame(width: HomeRecentContentLayout.cardWidth)
                                    .id(recentEntry.id)
                                }
                            }
                            .padding(.vertical, 1)
                            .padding(.trailing, recentEntries.count > 2 ? HomeRecentContentLayout.trailingScrollCueWidth : 0)
                        }
                        // Only the cue index resets. Asking the proxy to scroll back to the first
                        // card here also drags the page's own vertical scroll — `scrollTo` reaches
                        // the enclosing scroll view too, and a ranking that lands while the reader
                        // is partway down Home yanks them back to the top of the page.
                        .onChange(of: recentEntries.map(\.id)) { _ in
                            recentScrollCueIndex = 0
                        }

                        if recentEntries.count > 2 {
                            HomeRecentScrollCue {
                                let nextIndex = recentScrollCueIndex + 1 < recentEntries.count
                                    ? recentScrollCueIndex + 1
                                    : 0
                                recentScrollCueIndex = nextIndex
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                    scrollProxy.scrollTo(recentEntries[nextIndex].id, anchor: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .homeSectionCardBackground()
            .padding(.top, 8)
        }
    }

    private var myStorySection: some View {
        MyStoryView(
            selectedPage: $selectedPage,
            generatedStoryboards: $generatedStoryboards,
            contentMode: contentMode,
            showsSettingsButton: false,
            showsBottomNavigation: false,
            embedsInNavigationStack: false
        )
        .homeSectionCardBackground()
        .padding(.top, homeRecentEntries().isEmpty ? 8 : 4)
    }

    @MainActor
    private func refreshRecentContent(loadsCloudEntry: Bool) {
        let loadID = homeStoryboardLoadID

        if showsSampleHomeContent {
            recentContentLoadTask?.cancel()
            let pack = isSampleAuthorMode
                ? loadedHomeSamplePack
                : (SampleContentStore.pack ?? loadedHomeSamplePack)
            if let pack {
                recentEntries = mostRecentSampleEntries(from: pack)
                HomeRecentEntrySessionCache.store(recentEntries, for: loadID)
            } else {
                // The seed above is unkeyed, so it can belong to whichever mode was last on screen. A
                // pack that has not loaded yet falls back to this mode's own card, never keeps that one.
                recentEntries = HomeRecentEntrySessionCache.entries(for: loadID)
            }
            return
        }

        // A session still resolving has not picked a data source. Painting local drafts here is what
        // the reader sees as older cards, because those drafts rank by on-device `updatedAt` and then
        // swap once the account's cloud ranking lands.
        guard contentMode.isResolved else {
            recentEntries = HomeRecentEntrySessionCache.entries(for: loadID)
            return
        }

        let cachedEntries = HomeRecentEntrySessionCache.entries(for: loadID)
        if !cachedEntries.isEmpty {
            // The cache holds the last ranking the cloud gave this account, so it opens on the same
            // order the fetch below is about to confirm.
            recentEntries = cachedEntries
        } else if authStore.userID != nil {
            // Signed-in visits must not stand in the local `updatedAt` ranking. Autosaves and sidecar
            // writes bump that timestamp without moving the cloud `updated_at` this section sorts on,
            // so the local pick is often a different order than the one arriving a moment later.
            // Nothing to seed from means staying empty until the fetch answers.
            let localIDs = Set(visibleLocalEntries().map(\.id))
            if recentEntries.contains(where: { !localIDs.contains($0.id) }) {
                recentEntries = []
            }
        } else {
            recentEntries = mostRecentLocalEntries(from: visibleLocalEntries())
        }

        guard loadsCloudEntry, authStore.userID != nil else {
            return
        }

        recentContentLoadTask?.cancel()
        recentContentLoadTask = Task {
            await refreshMostRecentCloudEntry()
        }
    }

    /// Same ranking as Entries when the sort is Edited: Newest — cloud `updated_at`, not the local
    /// draft cache. Local autosaves and sidecar writes bump on-device `updatedAt` without changing
    /// the timestamp the Entries list sorts on, which is how Home could show a different card.
    @MainActor
    private func refreshMostRecentCloudEntry() async {
        let loadID = homeStoryboardLoadID

        do {
            let page = try await SupabaseEntryRepository().getEntrySummariesPage(
                limit: homeRecentCloudEntryLimit,
                offset: 0,
                sort: .updatedAt,
                statusFilter: .all
            )

            guard !Task.isCancelled, homeStoryboardLoadID == loadID, !showsSampleHomeContent else {
                return
            }

            let cloudEntries = Array(page.sorted(by: homeRecentCloudEntrySort).prefix(homeRecentContentLimit))
            guard !cloudEntries.isEmpty else {
                recentEntries = []
                HomeRecentEntrySessionCache.store([], for: loadID)
                return
            }

            // Straight off the Edited: Newest page, in the order Supabase returned it — drafts and
            // completed entries alike, which is the same list Entries shows under All. Nothing local
            // is spliced in: on-device `updatedAt` moves on autosaves and sidecar writes that never
            // touch cloud `updated_at`, so a local pick lands somewhere Entries would never put it,
            // and an entry that has never reached Supabase does not belong on this row at all.
            let merged = cloudEntries.map(homeRecentEntry)
            // Same ranking is not a reason to rebuild the HStack. Replacing cards that are already
            // the right entries is how a fetch that lost the race with a local promotion flashes
            // the previous row for a frame.
            if merged.map(\.id) != recentEntries.map(\.id) {
                recentEntries = merged
            } else {
                recentEntries = zip(recentEntries, merged).map { current, next in
                    HomeRecentEntry(
                        entry: next.entry,
                        storyboardImage: current.storyboardImage ?? next.storyboardImage,
                        storyboardCount: max(current.storyboardCount, next.storyboardCount),
                        isSample: next.isSample,
                        cloudEntryID: next.cloudEntryID ?? current.cloudEntryID
                    )
                }
            }
            HomeRecentEntrySessionCache.store(recentEntries, for: loadID)

            let thumbnailService = SupabaseEntryThumbnailService()
            for cloudEntry in cloudEntries where homeRecentEntryNeedsThumbnail(cloudEntry) {
                if let thumbnailStoragePath = cloudEntry.thumbnailStoragePath,
                   let thumbnail = try? await thumbnailService.downloadThumbnail(storagePath: thumbnailStoragePath) {
                    guard !Task.isCancelled, homeStoryboardLoadID == loadID else {
                        return
                    }

                    updateRecentEntryThumbnail(thumbnail, for: cloudEntry, loadID: loadID)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Journaltopia] Home most-recent entry load failed: \(error.localizedDescription)")
            // The opening paint stayed empty rather than flash a local ranking. If the cloud never
            // answers, local drafts are better than a permanently missing section.
            if recentEntries.isEmpty, homeStoryboardLoadID == loadID, !showsSampleHomeContent {
                recentEntries = mostRecentLocalEntries(from: visibleLocalEntries())
            }
        }
    }

    /// Opens the card's entry, first making sure the editor will be able to find it.
    ///
    /// `CreateEntryView` opens an entry by id and reads it back out of the local stores, and answers
    /// a miss by clearing itself — no writing, no storyboard, and the default notebook paper in
    /// place of whatever the entry was actually written on. Home is the one screen whose card can
    /// name an entry those stores have never held: its ranking comes straight from Supabase, and
    /// sample authoring reads its card out of the pack. Entries has always staged the entry before
    /// handing the editor an id; this is that same step for Home.
    @MainActor
    private func openRecentEntryCard(_ recent: HomeRecentEntry) {
        guard preparingRecentEntryID == nil else {
            return
        }

        // Signed-out browsing is the one mode with nothing to stage: the editor reads that entry
        // straight out of the in-memory pack, and writing it to disk is exactly what used to leak
        // the sample pack into the next account to sign in on the device.
        if showsSampleHomeContent, !isSampleAuthorMode {
            openRecentEntry(recent.entry, recent.storyboardImage)
            return
        }

        if isSampleAuthorMode {
            let storyboardImage = stageSampleEntryForEditing(recent.entry) ?? recent.storyboardImage
            openRecentEntry(recent.entry, storyboardImage)
            return
        }

        // Already on disk: open it now rather than spending a round trip re-fetching what the editor
        // is about to read anyway — including when the local copy holds autosaved edits the cloud
        // has not seen, which a download would overwrite.
        guard !CreateEntryDraftStore.exists(id: recent.id) else {
            openRecentEntry(recent.entry, recent.storyboardImage)
            return
        }

        preparingRecentEntryID = recent.id
        Task {
            let outcome = await materializeCloudRecentEntry(recent)
            preparingRecentEntryID = nil

            switch outcome {
            case .staged(let storyboardImage):
                openRecentEntry(recent.entry, storyboardImage ?? recent.storyboardImage)
            case .entryUnavailable:
                // The cloud answered, and what it said is that this entry is not there any more.
                // Re-rank the card rather than opening an empty editor on top of a deleted entry.
                refreshRecentContent(loadsCloudEntry: true)
            }
        }
    }

    /// Sample authoring edits samples through the on-disk stores the way ordinary entries are
    /// edited, so the pack's copy has to be written down before the editor can open it. Entries does
    /// the same thing in `openSampleEntry`.
    @MainActor
    @discardableResult
    private func stageSampleEntryForEditing(_ entry: CreateEntryDraft) -> UIImage? {
        let didPersist = CreateEntryDraftStore.save(
            id: entry.id,
            title: entry.title,
            text: entry.text,
            richText: entry.richText,
            referencePhotos: entry.photos,
            characters: entry.characters,
            artStyle: entry.artStyle,
            location: entry.location,
            date: entry.date,
            datePrecision: entry.datePrecision,
            savesDraft: entry.savesDraft,
            isPrivate: entry.isPrivate,
            status: JournalEntryStatus(rawValue: entry.status) ?? .draft,
            fontChoiceRawValue: entry.fontChoiceRawValue,
            textColorIndex: entry.textColorIndex,
            textSize: entry.textSize,
            paperStyleRawValue: entry.paperStyleRawValue,
            paperColorIndex: entry.paperColorIndex,
            isBold: entry.isBold,
            isItalic: entry.isItalic,
            isUnderlined: entry.isUnderlined,
            isStrikethrough: entry.isStrikethrough,
            isHighlighted: entry.isHighlighted,
            textAlignmentRawValue: entry.textAlignmentRawValue,
            thumbnail: entry.thumbnail,
            createdAt: entry.createdAt
        ) != nil

        guard didPersist else {
            return nil
        }

        return stageSampleStoryboards(for: entry.id)
    }

    @MainActor
    private func stageSampleStoryboards(for entryID: UUID) -> UIImage? {
        let sampleStoryboards = samplePackStoryboards(for: entryID)
        guard !sampleStoryboards.isEmpty else {
            return nil
        }

        var persistedStoryboards = GeneratedStoryboardStore.load()
        var firstImage: UIImage?

        for (index, sampleStoryboard) in sampleStoryboards.enumerated() {
            if firstImage == nil {
                firstImage = sampleStoryboard.image
            }

            guard
                let storyboard = try? GeneratedStoryboardStore.persistedStoryboard(
                    image: sampleStoryboard.image,
                    clientEntryID: entryID,
                    promptText: sampleStoryboard.promptText,
                    artStyle: sampleStoryboard.artStyle,
                    generationQuality: sampleStoryboard.generationQuality,
                    panelLayout: sampleStoryboard.panelLayout,
                    sourcePhotoCount: sampleStoryboard.sourcePhotoCount,
                    id: sampleStoryboard.id,
                    storagePath: sampleStoryboard.storagePath,
                    cloudSyncState: sampleStoryboard.cloudSyncState,
                    isPrimary: sampleStoryboard.isPrimary || index == 0
                )
            else {
                continue
            }

            persistedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: persistedStoryboards)
        }

        GeneratedStoryboardStore.save(persistedStoryboards)
        return firstImage
    }

    private enum HomeRecentEntryStaging {
        /// The editor will find the entry on disk. Carries the primary storyboard if one came down.
        case staged(UIImage?)
        /// The cloud says the entry no longer exists, so there is nothing to open.
        case entryUnavailable
    }

    /// Downloads the committed cloud copy into the local stores, the way Entries does before it
    /// opens a cloud entry.
    @MainActor
    private func materializeCloudRecentEntry(_ recent: HomeRecentEntry) async -> HomeRecentEntryStaging {
        guard let cloudEntryID = recent.cloudEntryID else {
            return .staged(nil)
        }

        do {
            let fullCloudEntry = try await SupabaseEntryRepository().getEntry(id: cloudEntryID)
            let cloudDraft = CreateEntryDraft.fromCloud(fullCloudEntry, thumbnail: recent.entry.thumbnail)
            let photos = (try? await SupabaseReferencePhotoService().loadReferencePhotos(entryID: cloudEntryID)) ?? []
            let characters = (try? await SupabaseEntryCharacterService().loadCharacters(entryID: cloudEntryID)) ?? []

            saveMaterializedEntry(cloudDraft, photos: photos, characters: characters)
        } catch {
            print("[Journaltopia] Home recent entry download failed: \(error.localizedDescription)")

            // Only the cloud being unreachable earns the fallback. The card was ranked from an entry
            // summary, which already carries the writing, the paper style and the formatting —
            // everything but the reference photos — so writing that down opens the entry the reader
            // tapped rather than a blank page. Any other failure is the cloud answering, and staging
            // a copy of a row it has stopped returning would put a deleted entry back on the device.
            guard (error as? TransientCloudFailure)?.isTransientCloudFailure == true else {
                return .entryUnavailable
            }

            saveMaterializedEntry(recent.entry, photos: recent.entry.photos, characters: recent.entry.characters)
        }

        return .staged(await materializeCloudRecentEntryStoryboards(clientEntryID: recent.id))
    }

    @MainActor
    private func saveMaterializedEntry(
        _ draft: CreateEntryDraft,
        photos: [CreateEntryReferencePhoto],
        characters: [EntryCharacter]
    ) {
        CreateEntryDraftStore.save(
            id: draft.id,
            title: draft.title,
            text: draft.text,
            richText: draft.richText,
            referencePhotos: photos,
            characters: characters,
            artStyle: draft.artStyle,
            location: draft.location,
            date: draft.date,
            datePrecision: draft.datePrecision,
            savesDraft: draft.savesDraft,
            isPrivate: draft.isPrivate,
            status: JournalEntryStatus(rawValue: draft.status) ?? .draft,
            fontChoiceRawValue: draft.fontChoiceRawValue,
            textColorIndex: draft.textColorIndex,
            textSize: draft.textSize,
            paperStyleRawValue: draft.paperStyleRawValue,
            paperColorIndex: draft.paperColorIndex,
            isBold: draft.isBold,
            isItalic: draft.isItalic,
            isUnderlined: draft.isUnderlined,
            isStrikethrough: draft.isStrikethrough,
            isHighlighted: draft.isHighlighted,
            textAlignmentRawValue: draft.textAlignmentRawValue,
            thumbnail: draft.thumbnail,
            createdAt: draft.createdAt,
            cloudSyncState: .synchronized
        )
    }

    /// A device that had never seen the entry has never seen its storyboards either, and the editor
    /// reads those from disk too. Entries fills this store while it lists completed entries; Home
    /// only ever needs the one entry it is opening.
    @MainActor
    private func materializeCloudRecentEntryStoryboards(clientEntryID: UUID) async -> UIImage? {
        guard GeneratedStoryboardStore.count(clientEntryIDs: [clientEntryID]) == 0 else {
            return nil
        }

        let service = SupabaseStoryboardService()
        guard
            let rows = try? await service.loadCompletedStoryboardRows(for: [clientEntryID]),
            !rows.isEmpty
        else {
            return nil
        }

        var persistedStoryboards = GeneratedStoryboardStore.load()
        var primaryImage: UIImage?

        for row in rows {
            guard
                let image = try? await service.downloadStoryboardImage(storagePath: row.storagePath),
                let storyboard = try? GeneratedStoryboardStore.persistedStoryboard(
                    image: image,
                    clientEntryID: row.clientEntryID,
                    promptText: row.prompt ?? "",
                    artStyle: row.artStyle ?? "Anime",
                    panelLayout: row.panelLayout,
                    sourcePhotoCount: 0,
                    id: row.id,
                    storagePath: row.storagePath,
                    cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                    isPrimary: row.isPrimary
                )
            else {
                continue
            }

            if primaryImage == nil || row.isPrimary {
                primaryImage = image
            }

            persistedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: persistedStoryboards)
        }

        GeneratedStoryboardStore.save(persistedStoryboards)
        return primaryImage
    }

    @MainActor
    private func mostRecentSampleEntries(from pack: SampleStoryPack) -> [HomeRecentEntry] {
        // Entries lists `pack.entries` only. Journal copies used to be mixed in here, so Home could
        // pick a nested sample that Edited: Newest on Entries would never show first.
        pack.entries
            .sorted(by: homeRecentEntrySort)
            .prefix(homeRecentContentLimit)
            .map {
                HomeRecentEntry(
                    entry: $0,
                    storyboardImage: primaryStoryboardImage(for: $0.id),
                    storyboardCount: storyboardCount(for: $0.id),
                    isSample: true
                )
            }
    }

    /// Only reached when there is no account to rank against — signed-out browsing, or a cloud page
    /// that never answered. A signed-in Home takes its cards from the cloud alone, which is what
    /// keeps entries that only exist on this device out of the section.
    private func visibleLocalEntries() -> [CreateEntryDraft] {
        CreateEntryDraftStore.loadAll(includeMedia: false)
            .filter { $0.status != JournalEntryStatus.archived.rawValue }
    }

    @MainActor
    private func mostRecentLocalEntries(from entries: [CreateEntryDraft]) -> [HomeRecentEntry] {
        entries
            .sorted(by: homeRecentEntrySort)
            .prefix(homeRecentContentLimit)
            .map { entry in
                HomeRecentEntry(
                    entry: entry,
                    storyboardImage: primaryStoryboardImage(for: entry.id),
                    storyboardCount: storyboardCount(for: entry.id),
                    isSample: false
                )
            }
    }

    @MainActor
    private func homeRecentEntry(from cloudEntry: JournalEntry) -> HomeRecentEntry {
        let localEntry = CreateEntryDraftStore.load(ids: [cloudEntry.clientEntryID], includeMedia: false).first
        // Reuse the thumbnail already on screen for this same entry. Dropping it would blank the card
        // for as long as the download below took to fetch a picture the card was already showing.
        let displayedThumbnail = recentEntries.first { $0.id == cloudEntry.clientEntryID }?.entry.thumbnail
        let entry = CreateEntryDraft.fromCloud(cloudEntry, thumbnail: localEntry?.thumbnail ?? displayedThumbnail)

        return HomeRecentEntry(
            entry: entry,
            storyboardImage: primaryStoryboardImage(for: entry.id),
            storyboardCount: storyboardCount(for: entry.id),
            isSample: false,
            cloudEntryID: cloudEntry.id
        )
    }

    private func homeRecentEntryNeedsThumbnail(_ cloudEntry: JournalEntry) -> Bool {
        recentEntries.first { $0.id == cloudEntry.clientEntryID }?.entry.thumbnail == nil
    }

    @MainActor
    private func updateRecentEntryThumbnail(_ thumbnail: UIImage, for cloudEntry: JournalEntry, loadID: String) {
        guard let index = recentEntries.firstIndex(where: { $0.id == cloudEntry.clientEntryID }) else {
            return
        }

        let recent = recentEntries[index]
        recentEntries[index] = HomeRecentEntry(
            entry: CreateEntryDraft.fromCloud(cloudEntry, thumbnail: thumbnail),
            storyboardImage: recent.storyboardImage,
            storyboardCount: recent.storyboardCount,
            isSample: false,
            cloudEntryID: cloudEntry.id
        )
        HomeRecentEntrySessionCache.store(recentEntries, for: loadID)
    }

    private func homeRecentEntries() -> [HomeRecentEntry] {
        Array(recentEntries.prefix(homeRecentContentLimit))
    }

    private func homeRecentEntrySort(_ lhs: CreateEntryDraft, _ rhs: CreateEntryDraft) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.createdAt > rhs.createdAt
    }

    private func homeRecentCloudEntrySort(_ lhs: JournalEntry, _ rhs: JournalEntry) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.createdAt > rhs.createdAt
    }

    /// Sample authoring never fills `SampleContentStore` — that store exists for signed-out browsing,
    /// and `ContentView` clears it the moment authoring turns on — so the authoring pack Home loaded
    /// for itself is the only place its storyboards live.
    @MainActor
    private func samplePackStoryboards(for entryID: UUID) -> [GeneratedStoryboard] {
        let storeStoryboards = SampleContentStore.storyboards(clientEntryID: entryID)
        guard storeStoryboards.isEmpty else {
            return storeStoryboards
        }

        return loadedHomeSamplePack?.storyboardsByEntryID[entryID] ?? []
    }

    @MainActor
    private func primaryStoryboardImage(for entryID: UUID) -> UIImage? {
        let storyboards: [GeneratedStoryboard]
        if showsSampleHomeContent {
            storyboards = samplePackStoryboards(for: entryID)
        } else {
            storyboards = GeneratedStoryboardStore.load(clientEntryIDs: [entryID])
        }

        return storyboards
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary {
                    return lhs.isPrimary
                }

                return lhs.createdAt > rhs.createdAt
            }
            .first?
            .image
    }

    @MainActor
    private func storyboardCount(for entryID: UUID) -> Int {
        if showsSampleHomeContent {
            return samplePackStoryboards(for: entryID).count
        }

        return GeneratedStoryboardStore.count(clientEntryIDs: [entryID])
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
            let loadedStoryboards = try await service.loadCompletedJournalStoryboardPreviewImages(
                limit: homeStoryboardPreviewLimit,
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
            loadedHomeSamplePack = pack
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
        var seen = Set<String>()
        for candidate in [ext, ext.lowercased(), ext.uppercased(), "mp4", "MP4", "mov", "MOV"] {
            guard seen.insert(candidate).inserted else { continue }
            if let url = Bundle.main.url(forResource: name, withExtension: candidate) {
                return url
            }
        }
        return nil
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
    static let gridSpacing: CGFloat = 12
    static let gridColumns = [
        GridItem(.flexible(), spacing: gridSpacing)
    ]
    static let primaryHeight: CGFloat = 154
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let indicatorInset: CGFloat = 12
    static let titleSize: CGFloat = 26
    static let subtitleSize: CGFloat = 15
}

private enum HomeRecentContentLayout {
    static let gridSpacing: CGFloat = 16
    static let cardWidth: CGFloat = 168
    static let trailingScrollCueWidth: CGFloat = 46
    static let entryAspectRatio = JournalPaperGeometry.aspectRatio
}

private extension View {
    func homeSectionCardBackground() -> some View {
        HomeSectionCardLayout(horizontalInset: 14, verticalInset: 14) {
            self
        }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.homeCardGray.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.82), lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.07), radius: 14, y: 6)
    }
}

private struct HomeSectionCardLayout: Layout {
    let horizontalInset: CGFloat
    let verticalInset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else {
            return .zero
        }

        let contentProposal = ProposedViewSize(
            width: proposal.width.map { max(0, $0 - horizontalInset * 2) },
            height: proposal.height.map { max(0, $0 - verticalInset * 2) }
        )
        let contentSize = content.sizeThatFits(contentProposal)

        return CGSize(
            width: proposal.width ?? contentSize.width + horizontalInset * 2,
            height: contentSize.height + verticalInset * 2
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else {
            return
        }

        let contentSize = CGSize(
            width: max(0, bounds.width - horizontalInset * 2),
            height: max(0, bounds.height - verticalInset * 2)
        )

        content.place(
            at: CGPoint(x: bounds.minX + horizontalInset, y: bounds.minY + verticalInset),
            anchor: .topLeading,
            proposal: ProposedViewSize(contentSize)
        )
    }
}

private struct HomeRecentEntry: Identifiable {
    let entry: CreateEntryDraft
    let storyboardImage: UIImage?
    let storyboardCount: Int
    let isSample: Bool
    /// The Supabase row this card was ranked from, when the card came from the cloud rather than
    /// from disk. Opening the entry needs it: the editor reads the entry back out of the local
    /// stores, so an entry that has never been on this device has to be downloaded first.
    var cloudEntryID: UUID?

    var id: UUID {
        entry.id
    }
}

/// The most-recent entry cards Home last resolved, kept for the life of the process.
///
/// `ContentView` builds `HomeView` fresh on every return to Home, so `recentEntries` starts empty and
/// the only thing available for the opening frames is the local draft cache — which ranks by on-device
/// `updatedAt` and can name different entries than the cloud `updated_at` ranking the cards settle on
/// a moment later. That mismatch is what the reader sees as cards flashing one way and then swapping.
/// Seeding from here means a return to Home starts on the answer it ended on.
///
/// Keyed by the same load identity Home keys its loads on, so one account never reads another's card
/// and sample mode never reads the account's; sign-out purges the whole thing through
/// ``HomeLocalCachePurge``.
private enum HomeRecentEntrySessionCache {
    private static var entriesByLoadID: [String: [HomeRecentEntry]] = [:]
    private static var mostRecentLoadID: String?

    static func entries(for loadID: String) -> [HomeRecentEntry] {
        entriesByLoadID[loadID] ?? []
    }

    /// The last cards stored, whichever load they belonged to.
    ///
    /// Unkeyed because the load identity needs the signed-in user, and `@State` initial values are
    /// evaluated before the environment exists. Being occasionally wrong is safe: `onAppear` refreshes
    /// against the real identity, so a mismatch costs a frame and never persists.
    static func mostRecentEntries() -> [HomeRecentEntry] {
        guard let mostRecentLoadID else {
            return []
        }

        return entries(for: mostRecentLoadID)
    }

    /// Stores an empty array as a real answer — "this account has no entries" is worth seeding too,
    /// and lets deleted last entries stop coming back on the next visit.
    static func store(_ entries: [HomeRecentEntry], for loadID: String) {
        entriesByLoadID[loadID] = entries
        mostRecentLoadID = loadID
    }

    static func removeAll() {
        entriesByLoadID.removeAll()
        mostRecentLoadID = nil
    }
}

/// `LocalUserDataPurge`'s hook into this file, matching `JournalLocalCachePurge`.
///
/// ``HomeRecentEntrySessionCache`` is file-private and lives as long as the process does, holding the
/// previous account's entry text and thumbnail in memory. Nothing but the sign-out purge should call
/// this.
enum HomeLocalCachePurge {
    static func purgeInMemoryCaches() {
        HomeRecentEntrySessionCache.removeAll()
    }
}

private func homeRecentEntryTitle(_ entry: CreateEntryDraft) -> String {
    let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
        return trimmedTitle
    }

    let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedText.isEmpty ? "Untitled Entry" : trimmedText
}

private struct HomeRecentScrollCue: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LinearGradient(
                colors: [
                    Color.homeCardGray.opacity(0),
                    Color.homeCardGray.opacity(0.86)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: HomeRecentContentLayout.trailingScrollCueWidth)
            .overlay(alignment: .trailing) {
                HomeCardNavigationIndicator()
                    .padding(.trailing, 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show more recent entries")
        .accessibilityHint("Scrolls to the rest of the most recent entries")
    }
}

private struct HomeRecentEntryCard: View {
    let recent: HomeRecentEntry
    /// The entry is being downloaded into the local stores before the editor opens it.
    var isPreparing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        entryPreview
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .top) {
                                StoryPhotoTape(width: 48, height: 14, rotation: -2)
                                    .offset(y: -7)
                            }

                        if recent.storyboardImage != nil {
                            storyboardOverlay(in: proxy.size)
                        }

                        if isPreparing {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.18))
                                .overlay {
                                    ProgressView()
                                        .tint(.white)
                                }
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                }
                .aspectRatio(HomeRecentContentLayout.entryAspectRatio, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: .infinity)
                .shadow(color: Color.storyInk.opacity(0.09), radius: 9, y: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(homeRecentEntryTitle(recent.entry))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(recent.entry.updatedAt.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Most recent entry, \(homeRecentEntryTitle(recent.entry))")
        .accessibilityHint("Opens the entry")
    }

    @ViewBuilder
    private var entryPreview: some View {
        if let thumbnail = recent.entry.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(red: 0.985, green: 0.978, blue: 0.955)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.storyInk.opacity(0.08), lineWidth: 1)
                    .padding(12)

                Image(systemName: "doc.text")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.storyInk.opacity(0.34))
            }
        }
    }

    private func storyboardOverlay(in size: CGSize) -> some View {
        let overlayHeight = size.height * 0.47
        let overlayWidth = overlayHeight * 0.72

        return ZStack(alignment: .topTrailing) {
            if let storyboardImage = recent.storyboardImage {
                Image(uiImage: storyboardImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: overlayWidth, height: overlayHeight)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 1)
                    )
                    .shadow(color: Color.storyInk.opacity(0.08), radius: 3, y: 1)
                    .zIndex(1)
            }

            Image(systemName: "paperclip")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color(red: 0.74, green: 0.76, blue: 0.82))
                .rotationEffect(.degrees(-34))
                .shadow(color: Color.white.opacity(0.75), radius: 1, y: 1)
                .shadow(color: Color.storyInk.opacity(0.12), radius: 1, y: 1)
                .offset(x: 1, y: -13)
                .zIndex(2)

            if recent.storyboardCount > 1 {
                Text("\(recent.storyboardCount)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.storyPurple, in: Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: Color.storyInk.opacity(0.18), radius: 5, y: 2)
                    .offset(x: 12, y: overlayHeight - 16)
                    .zIndex(3)
            }
        }
        .frame(width: overlayWidth, height: overlayHeight)
        .rotationEffect(.degrees(2))
        .shadow(color: Color.storyInk.opacity(0.16), radius: 6, y: 4)
        .position(x: size.width * 0.76, y: size.height * 0.73)
    }
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
                    .font(.system(size: HomeCardLayout.titleSize, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(textAlignment)
                    .homeBannerTitleContrast()

                Text(subtitle)
                    .font(.system(size: HomeCardLayout.subtitleSize, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(.white.opacity(0.96))
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .homeBannerSubtitleContrast()
            }
            .padding(.horizontal, HomeCardLayout.horizontalPadding)
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
                    .padding(HomeCardLayout.indicatorInset)
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
