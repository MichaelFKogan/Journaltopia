import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    var embedsInNavigationStack = true
    var contentMode: JournaltopiaContentMode = .user

    @State private var selectedStoryboardIndex: Int?
    @State private var isProfileComicReaderPresented = false
    @State private var profileComicPageIndex = 0
    @State private var profileBookOpenHintProgress: CGFloat = 0
    @State private var profileBookOpenTask: Task<Void, Never>?
    @State private var isOpeningProfileComicReader = false
    @State private var isSelecting = false
    @State private var selectedStoryboardIDs: Set<UUID> = []
    @State private var storyboardsToShare: [GeneratedStoryboard] = []
    @State private var isShowingShareSheet = false
    @State private var isLoadingProfileStoryboards = false
    @State private var isLoadingMoreProfileStoryboards = false
    @State private var hasMoreProfileStoryboards = true
    @State private var nextProfileStoryboardOffset = 0
    /// Server-side account totals; the grid itself is paged and only holds what has been viewed.
    @State private var profileStoryboardCounts: (total: Int, month: Int)?
    @State private var profileStoryboardErrorMessage: String?
    @State private var pendingStoryboardDeletion: PendingStoryboardDeletion?
    @State private var isPreparingStoryboardDeletion = false
    @State private var isDeletingStoryboards = false
    @State private var storyboardDeletionMessage: String?
    @State private var storyboardDeletionMessageVersion = 0
    private let profileStoryboardPageSize = 9

    private let storyboardColumns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]

    var body: some View {
        wrappedProfileContent
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedStoryboardIndex != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedStoryboardIndex = nil
                    }
                }
            )
        ) {
            if let selectedStoryboardIndex {
                StoryboardImageViewer(
                    storyboards: generatedStoryboards,
                    initialIndex: selectedStoryboardIndex,
                    hasMoreStoryboards: hasMoreProfileStoryboards,
                    isLoadingMoreStoryboards: isLoadingMoreProfileStoryboards,
                    onLoadMoreStoryboards: {
                        await loadMoreProfileStoryboards()
                    },
                    allowsSharing: true,
                    deleteAction: StoryboardViewerDeleteAction(
                        // The grid is paginated, so it cannot always tell whether this is the
                        // entry's last storyboard. The result toast reports what actually
                        // happened.
                        message: { _ in
                            "Only this storyboard is deleted. If it is the last one for its entry, that entry moves back to Drafts. This can't be undone."
                        },
                        perform: { storyboard in
                            deleteStoryboards([storyboard])
                        }
                    )
                )
                .presentationBackground(.clear)
            }
        }
        // An alert rather than a confirmationDialog: action sheets drop their cancel button
        // when iOS presents them as a popover, and a destructive action always needs a
        // visible way out.
        .alert(
            pendingStoryboardDeletion?.alertTitle ?? "Delete Storyboards?",
            isPresented: Binding(
                get: { pendingStoryboardDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingStoryboardDeletion = nil
                    }
                }
            ),
            presenting: pendingStoryboardDeletion
        ) { pending in
            Button("Cancel", role: .cancel) {
                pendingStoryboardDeletion = nil
            }

            Button("Delete", role: .destructive) {
                pendingStoryboardDeletion = nil
                deleteStoryboards(pending.storyboards)
            }
        } message: { pending in
            Text(pending.confirmationMessage)
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: storyboardsToShare.map(\.image))
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $isProfileComicReaderPresented) {
            ProfileStoryboardComicReaderView(
                storyboards: generatedStoryboards,
                currentPageIndex: $profileComicPageIndex
            )
            .onDisappear {
                isOpeningProfileComicReader = false
                playProfileBookOpenHint()
            }
        }
        .onChange(of: generatedStoryboards.map(\.id)) { availableIDs in
            sanitizeProfileStoryboards()
            selectedStoryboardIDs.formIntersection(Set(availableIDs))

            if generatedStoryboards.isEmpty {
                endSelection()
                isProfileComicReaderPresented = false
                profileComicPageIndex = 0
            }
        }
        .onAppear {
            sanitizeProfileStoryboards()
            playProfileBookOpenHint()
        }
        .onDisappear {
            profileBookOpenTask?.cancel()
            profileBookOpenTask = nil
        }
        .task(id: profileLoadModeID) {
            await loadProfileStoryboards()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
        // The grid used to refetch on every mount, which is what kept it correct after a generation
        // finished or an entry moved between Drafts and Completed. Now that a mount can be served
        // from the session cache, the change has to say so itself.
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaGeneratedStoryboardsChanged)) { _ in
            ProfileStoryboardSessionCache.markStale(for: profileLoadModeID)

            Task {
                await loadProfileStoryboards()
            }
        }
        // Likewise for a background re-check that turns up a newer sample pack than the cached one
        // these storyboards came from.
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaSampleStoryPackChanged)) { _ in
            guard showsSampleProfileContent, !isSampleAuthorMode else {
                return
            }

            Task {
                await loadSampleProfileStoryboards()
            }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var wrappedProfileContent: some View {
        if embedsInNavigationStack {
            NavigationStack {
                profileContent
                    .toolbar(.hidden, for: .navigationBar)
            }
        } else {
            profileContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(Color.homePageBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Profile")
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(Color.storyInk)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        settingsButton
                    }
                }
        }
    }

    private var profileContent: some View {
        ZStack(alignment: .bottom) {
            WatercolorPaperPageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if embedsInNavigationStack {
                        header
                    }

                    profileSummary
                    storyboardsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isSelecting ? 150 : 96)
            }

            VStack(spacing: 0) {
                if let storyboardDeletionMessage {
                    Text(storyboardDeletionMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.storyInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.homeBorder, lineWidth: 1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if isSelecting {
                    selectionActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                BottomNavigationBar(selectedPage: $selectedPage)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Profile")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer(minLength: 0)

            settingsButton
        }
        .padding(.top, 2)
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
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.88))
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open settings")
    }

    private var profileSummary: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ProfileJournalCoverOpener(
                    coverImage: generatedStoryboards.first?.image,
                    openHintProgress: profileBookOpenHintProgress,
                    isEnabled: !generatedStoryboards.isEmpty && !isOpeningProfileComicReader,
                    onOpen: openProfileComicReader
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Story Seeker")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.storyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text("@story.seeker")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.storyInk.opacity(0.7))

                    Text("Collecting life's moments,\none storyboard at a time.")
                        .font(.system(size: 14, weight: .medium))
                        .lineSpacing(2)
                        .foregroundStyle(Color.storyInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                ProfileStat(value: "\(totalStoryboardCount)", title: "Storyboards")
                ProfileStat(value: "\(thisMonthStoryboardCount)", title: "This Month")
                ProfileStat(value: generationCreditBalanceText, title: "Credits")
                ProfileStat(value: "0", title: "Day Streak")
            }
        }
        .padding(.top, 2)
    }

    private var generationCreditBalanceText: String {
        generationCreditStore.balance.map(String.init) ?? "-"
    }

    private var totalStoryboardCount: Int {
        if !showsSampleProfileContent, let profileStoryboardCounts {
            return profileStoryboardCounts.total
        }

        return generatedStoryboards.count
    }

    private var thisMonthStoryboardCount: Int {
        if !showsSampleProfileContent, let profileStoryboardCounts {
            return profileStoryboardCounts.month
        }

        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: Date()) else {
            return 0
        }

        return generatedStoryboards.map(\.createdAt).filter { month.contains($0) }.count
    }

    private var storyboardsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(showsSampleProfileContent ? "Sample Storyboards" : "Your Storyboards")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text(showsSampleProfileContent ? "A preview collection from the sample stories." : "All the storyboards you've created.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()

                if allowsStoryboardSelection && !generatedStoryboards.isEmpty && !isLoadingProfileStoryboards {
                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            if isSelecting {
                                endSelection()
                            } else {
                                isSelecting = true
                            }
                        }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.homeAccent)
                            .frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isSelecting ? "Ends storyboard selection" : "Selects multiple storyboards")
                }
            }

            if isLoadingProfileStoryboards && generatedStoryboards.isEmpty {
                LazyVGrid(columns: storyboardColumns, spacing: 1) {
                    ForEach(0..<9, id: \.self) { _ in
                        LoadingStoryboardCard()
                    }
                }
            } else if generatedStoryboards.isEmpty, let profileStoryboardErrorMessage {
                ProfileStoryboardErrorState(message: profileStoryboardErrorMessage) {
                    Task {
                        await loadProfileStoryboards(forceReload: true)
                    }
                }
            } else if generatedStoryboards.isEmpty {
                LazyVGrid(columns: storyboardColumns, spacing: 1) {
                    ForEach(0..<9, id: \.self) { _ in
                        StoryboardPlaceholderCard()
                    }
                }
            } else {
                LazyVGrid(columns: storyboardColumns, spacing: 1) {
                    ForEach(Array(generatedStoryboards.enumerated()), id: \.element.id) { index, storyboard in
                        Button {
                            if isSelecting {
                                toggleSelection(for: storyboard)
                            } else {
                                openStoryboard(at: index)
                            }
                        } label: {
                            GeneratedStoryboardThumbnail(
                                storyboard: storyboard,
                                isSelecting: isSelecting,
                                isSelected: selectedStoryboardIDs.contains(storyboard.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            isSelecting
                                ? "\(selectedStoryboardIDs.contains(storyboard.id) ? "Selected" : "Not selected") storyboard"
                                : "Open storyboard"
                        )
                        .accessibilityAddTraits(
                            selectedStoryboardIDs.contains(storyboard.id) ? .isSelected : []
                        )
                    }

                }

                profileStoryboardFooter
            }
        }
    }

    @ViewBuilder
    private var profileStoryboardFooter: some View {
        if hasMoreProfileStoryboards {
            Button {
                Task {
                    await loadMoreProfileStoryboards()
                }
            } label: {
                HStack(spacing: 8) {
                    if isLoadingMoreProfileStoryboards {
                        ProgressView()
                            .tint(Color.homeAccent)
                    } else {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 13, weight: .bold))
                    }

                    Text(isLoadingMoreProfileStoryboards ? "Loading..." : "Load More")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Color.homeAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.homeBorder.opacity(0.9), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoadingMoreProfileStoryboards)
            .accessibilityLabel(isLoadingMoreProfileStoryboards ? "Loading more storyboards" : "Load more storyboards")
        } else if let profileStoryboardErrorMessage, !generatedStoryboards.isEmpty {
            VStack(spacing: 8) {
                Text(profileStoryboardErrorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)

                Button {
                    Task {
                        await loadMoreProfileStoryboards()
                    }
                } label: {
                    Text("Try Again")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.homeAccent)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var selectedStoryboards: [GeneratedStoryboard] {
        generatedStoryboards.filter { selectedStoryboardIDs.contains($0.id) }
    }

    private var isSampleAuthorMode: Bool {
        contentMode.isSampleAuthoring
    }

    private var showsSampleProfileContent: Bool {
        contentMode.showsSampleContent
    }

    /// Selection exists to delete and share, and sample storyboards are neither the visitor's to
    /// delete nor theirs to manage. Offering "Select" over them only ever led to a bar whose delete
    /// button could not be pressed.
    private var allowsStoryboardSelection: Bool {
        !showsSampleProfileContent
    }

    private var profileLoadModeID: String {
        contentMode.loadIdentity(userID: authStore.userID)
    }

    private var areAllStoryboardsSelected: Bool {
        !generatedStoryboards.isEmpty && selectedStoryboardIDs.count == generatedStoryboards.count
    }

    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if areAllStoryboardsSelected {
                        selectedStoryboardIDs.removeAll()
                    } else {
                        selectedStoryboardIDs = Set(generatedStoryboards.map(\.id))
                    }
                }
            } label: {
                Label(
                    areAllStoryboardsSelected ? "Deselect All" : "Select All",
                    systemImage: areAllStoryboardsSelected ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .selectionActionStyle()

            Spacer(minLength: 4)

            Button {
                storyboardsToShare = selectedStoryboards
                isShowingShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .selectionActionStyle()
            .disabled(selectedStoryboardIDs.isEmpty)

            Button {
                requestStoryboardDeletion(selectedStoryboards)
            } label: {
                if isPreparingStoryboardDeletion || isDeletingStoryboards {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Delete", systemImage: "trash")
                }
            }
            .selectionActionStyle(color: .red)
            .disabled(
                selectedDeletableStoryboards.isEmpty
                    || isPreparingStoryboardDeletion
                    || isDeletingStoryboards
            )
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.homeBorder)
                .frame(height: 1)
        }
    }

    private var selectedDeletableStoryboards: [GeneratedStoryboard] {
        selectedStoryboards.filter(\.isDeletable)
    }

    /// The grid mixes storyboards from many entries, so the exact number of entries losing
    /// their last storyboard is resolved before the user is asked to confirm.
    private func requestStoryboardDeletion(_ storyboards: [GeneratedStoryboard]) {
        let deletableStoryboards = storyboards.filter(\.isDeletable)
        guard !deletableStoryboards.isEmpty, !isPreparingStoryboardDeletion, !isDeletingStoryboards else {
            return
        }

        isPreparingStoryboardDeletion = true
        let isSignedIn = authStore.userID != nil

        Task {
            let preview = await StoryboardDeletionService().preview(
                deletableStoryboards,
                isSignedIn: isSignedIn
            )

            await MainActor.run {
                isPreparingStoryboardDeletion = false
                guard !preview.isEmpty else {
                    return
                }

                pendingStoryboardDeletion = PendingStoryboardDeletion(
                    storyboards: deletableStoryboards,
                    preview: preview
                )
            }
        }
    }

    private func deleteStoryboards(_ storyboards: [GeneratedStoryboard]) {
        guard !storyboards.isEmpty, !isDeletingStoryboards else {
            return
        }

        pendingStoryboardDeletion = nil
        isDeletingStoryboards = true
        let isSignedIn = authStore.userID != nil

        Task {
            do {
                let outcome = try await StoryboardDeletionService().delete(
                    storyboards,
                    isSignedIn: isSignedIn
                )
                await MainActor.run {
                    applyStoryboardDeletion(outcome)
                    showStoryboardDeletionMessage(successMessage(for: outcome))
                    isDeletingStoryboards = false
                }
            } catch let error as StoryboardDeletionError {
                await MainActor.run {
                    applyStoryboardDeletion(error.outcome)
                    showStoryboardDeletionMessage(error.localizedDescription)
                    isDeletingStoryboards = false
                }
            } catch {
                await MainActor.run {
                    showStoryboardDeletionMessage("Could not delete. Check your connection and try again.")
                    isDeletingStoryboards = false
                }
            }
        }
    }

    private func applyStoryboardDeletion(_ outcome: StoryboardDeletionOutcome) {
        guard !outcome.isEmpty else {
            return
        }

        // The header stats count the whole account, not the loaded grid, so what was deleted has to
        // come off that tally too — otherwise the count outlives the storyboards it counted.
        let deletedStoryboards = generatedStoryboards
            .filter { outcome.deletedStoryboardIDs.contains($0.id) }
        decrementProfileStoryboardCounts(deletedStoryboards)

        withAnimation(.snappy(duration: 0.24)) {
            generatedStoryboards.removeAll { outcome.deletedStoryboardIDs.contains($0.id) }
            selectedStoryboardIDs.subtract(outcome.deletedStoryboardIDs)
        }

        nextProfileStoryboardOffset = max(nextProfileStoryboardOffset - outcome.deletedStoryboardIDs.count, 0)

        // A deletion also moves entries between Drafts and Completed on the server, so the cached
        // page is no longer what a fresh load would return. Cached with what is on screen now and
        // stamped stale, so returning to Profile draws immediately and then re-checks.
        ProfileStoryboardSessionCache.store(
            storyboards: generatedStoryboards,
            nextOffset: nextProfileStoryboardOffset,
            hasMore: hasMoreProfileStoryboards,
            for: profileLoadModeID
        )
        ProfileStoryboardSessionCache.markStale(for: profileLoadModeID)

        // Keep the open viewer pointed at a real storyboard, or close it once none are left.
        if let openIndex = selectedStoryboardIndex, !generatedStoryboards.indices.contains(openIndex) {
            selectedStoryboardIndex = generatedStoryboards.isEmpty
                ? nil
                : generatedStoryboards.count - 1
        }

        if selectedStoryboardIDs.isEmpty {
            endSelection()
        }
    }

    private func successMessage(for outcome: StoryboardDeletionOutcome) -> String {
        let storyboardCount = outcome.deletedStoryboardIDs.count
        let storyboardText = storyboardCount == 1 ? "Storyboard deleted" : "\(storyboardCount) storyboards deleted"

        switch outcome.entriesReturnedToDrafts.count {
        case 0:
            return "\(storyboardText)."
        case 1:
            return "\(storyboardText). 1 entry moved back to Drafts."
        case let entryCount:
            return "\(storyboardText). \(entryCount) entries moved back to Drafts."
        }
    }

    private func showStoryboardDeletionMessage(_ message: String) {
        storyboardDeletionMessageVersion += 1
        let version = storyboardDeletionMessageVersion

        withAnimation(.snappy(duration: 0.22)) {
            storyboardDeletionMessage = message
        }

        Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            await MainActor.run {
                guard version == storyboardDeletionMessageVersion else {
                    return
                }

                withAnimation(.snappy(duration: 0.22)) {
                    storyboardDeletionMessage = nil
                }
            }
        }
    }

    private func toggleSelection(for storyboard: GeneratedStoryboard) {
        withAnimation(.snappy(duration: 0.18)) {
            if selectedStoryboardIDs.contains(storyboard.id) {
                selectedStoryboardIDs.remove(storyboard.id)
            } else {
                selectedStoryboardIDs.insert(storyboard.id)
            }
        }
    }

    private func openStoryboard(at index: Int) {
        guard generatedStoryboards.indices.contains(index) else {
            return
        }

        selectedStoryboardIndex = index

        let storyboard = generatedStoryboards[index]
        guard let storagePath = storyboard.storagePath else {
            return
        }

        Task {
            do {
                let image = try await SupabaseStoryboardService().downloadStoryboardImage(storagePath: storagePath)
                await MainActor.run {
                    guard let currentIndex = generatedStoryboards.firstIndex(where: { $0.id == storyboard.id }) else {
                        return
                    }

                    generatedStoryboards[currentIndex] = GeneratedStoryboard(
                        id: storyboard.id,
                        clientEntryID: storyboard.clientEntryID,
                        image: image,
                        promptText: storyboard.promptText,
                        artStyle: storyboard.artStyle,
                        generationQuality: storyboard.generationQuality,
                        panelLayout: storyboard.panelLayout,
                        sourcePhotoCount: storyboard.sourcePhotoCount,
                        createdAt: storyboard.createdAt,
                        imageFileName: storyboard.imageFileName,
                        storagePath: storyboard.storagePath,
                        cloudSyncState: storyboard.cloudSyncState,
                        isPrimary: storyboard.isPrimary
                    )
                }
            } catch {
                print("[Journaltopia] Profile storyboard full image load failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func loadProfileStoryboards(forceReload: Bool = false) async {
        if let unavailableMessage = contentMode.unavailableMessage {
            generatedStoryboards = []
            profileStoryboardCounts = nil
            isLoadingProfileStoryboards = false
            profileStoryboardErrorMessage = unavailableMessage
            return
        }

        // Still resolving. Hold the placeholder grid rather than committing to samples and then
        // swapping them out for the account's storyboards a moment later.
        guard contentMode.isResolved else {
            isLoadingProfileStoryboards = true
            return
        }

        if showsSampleProfileContent {
            await loadSampleProfileStoryboards()
            return
        }

        guard authStore.userID != nil else {
            generatedStoryboards = []
            profileStoryboardCounts = nil
            profileStoryboardErrorMessage = nil
            isLoadingProfileStoryboards = false
            return
        }

        // Restored before anything is awaited, so a rebuilt Profile draws the grid — and the header
        // cover, which is the first storyboard — on its first frame instead of a page of spinners
        // over content it already had. A fresh page needs no round trip at all; a stale one still
        // shows while the refresh runs behind it.
        var hasRestoredCachedPage = false
        if !forceReload, let cachedPage = ProfileStoryboardSessionCache.page(for: profileLoadModeID) {
            generatedStoryboards = cachedPage.storyboards
            nextProfileStoryboardOffset = cachedPage.nextOffset
            hasMoreProfileStoryboards = cachedPage.hasMore
            profileStoryboardCounts = ProfileStoryboardSessionCache.counts(for: profileLoadModeID)
            profileStoryboardErrorMessage = nil
            isLoadingProfileStoryboards = false
            hasRestoredCachedPage = true

            if ProfileStoryboardSessionCache.isFresh(cachedPage) {
                playProfileBookOpenHint()
                return
            }
        }

        if !hasRestoredCachedPage {
            hasMoreProfileStoryboards = true
            nextProfileStoryboardOffset = 0
        }

        // Only a load with nothing to show behind it gets the placeholder grid.
        isLoadingProfileStoryboards = generatedStoryboards.isEmpty
        isLoadingMoreProfileStoryboards = false
        profileStoryboardErrorMessage = nil
        defer { isLoadingProfileStoryboards = false }

        do {
            let service = SupabaseStoryboardService()
            let sampleEntryIDs = await activeSampleEntryIDsForProfileFilter()
            // Filtering the metadata before downloading, rather than filtering a downloaded page,
            // is what makes the paging exact: a page is nine *eligible* storyboards, and the total
            // is known without downloading the images behind it.
            let counts = try await service.loadCompletedJournalStoryboardCounts()
            applyProfileStoryboardCounts(counts)
            let pageRows = try await service.loadCompletedJournalStoryboardRowsPage(
                limit: profileStoryboardPageSize + 1,
                offset: 0
            )
            .filter { isProfileEligibleStoryboardRow($0, sampleEntryIDs: sampleEntryIDs) }
            let visiblePageRows = Array(pageRows.prefix(profileStoryboardPageSize))
            let loadedStoryboards = await service.downloadStoryboardPreviews(from: visiblePageRows)
                .sorted(by: profileStoryboardSort)

            generatedStoryboards = loadedStoryboards
            nextProfileStoryboardOffset = visiblePageRows.count
            hasMoreProfileStoryboards = pageRows.count > visiblePageRows.count
            profileStoryboardErrorMessage = nil
            ProfileStoryboardSessionCache.store(
                storyboards: loadedStoryboards,
                nextOffset: nextProfileStoryboardOffset,
                hasMore: hasMoreProfileStoryboards,
                for: profileLoadModeID
            )
            playProfileBookOpenHint()
        } catch {
            print("[Journaltopia] Profile storyboard grid load failed: \(error.localizedDescription)")
            hasMoreProfileStoryboards = false

            // A failed *refresh* is not an empty profile. What is already on screen stays, and the
            // error is only worth saying when there is nothing behind it.
            if generatedStoryboards.isEmpty {
                profileStoryboardErrorMessage = "Could not load your completed AI storyboards from Journaltopia cloud."
            }
        }
    }

    @MainActor
    private func loadMoreProfileStoryboards() async {
        guard !showsSampleProfileContent, authStore.userID != nil else {
            return
        }
        guard hasMoreProfileStoryboards, !isLoadingProfileStoryboards, !isLoadingMoreProfileStoryboards else {
            return
        }

        isLoadingMoreProfileStoryboards = true
        defer { isLoadingMoreProfileStoryboards = false }

        do {
            let service = SupabaseStoryboardService()
            let sampleEntryIDs = await activeSampleEntryIDsForProfileFilter()
            if profileStoryboardCounts == nil {
                applyProfileStoryboardCounts(try await service.loadCompletedJournalStoryboardCounts())
            }
            let pageRows = try await service.loadCompletedJournalStoryboardRowsPage(
                limit: profileStoryboardPageSize + 1,
                offset: nextProfileStoryboardOffset
            )
            .filter { isProfileEligibleStoryboardRow($0, sampleEntryIDs: sampleEntryIDs) }
            let visiblePageRows = Array(pageRows.prefix(profileStoryboardPageSize))
            let existingIDs = Set(generatedStoryboards.map(\.id))
            let newStoryboards = await service.downloadStoryboardPreviews(from: visiblePageRows)
                .filter { !existingIDs.contains($0.id) }
            generatedStoryboards.append(contentsOf: newStoryboards)
            generatedStoryboards.sort(by: profileStoryboardSort)
            nextProfileStoryboardOffset += visiblePageRows.count
            hasMoreProfileStoryboards = pageRows.count > visiblePageRows.count
            profileStoryboardErrorMessage = nil
            // Cached with the pages already scrolled through, so coming back to Profile restores how
            // far down the grid was rather than snapping to the first page.
            ProfileStoryboardSessionCache.store(
                storyboards: generatedStoryboards,
                nextOffset: nextProfileStoryboardOffset,
                hasMore: hasMoreProfileStoryboards,
                for: profileLoadModeID
            )
        } catch {
            profileStoryboardErrorMessage = "Could not load more storyboards."
        }
    }

    private func sanitizeProfileStoryboards() {
        let visibleStoryboards = generatedStoryboards.filter { storyboard in
            if showsSampleProfileContent {
                return isSampleProfileStoryboard(storyboard)
            }

            return isProfileEligibleStoryboard(storyboard, sampleEntryIDs: [])
        }
        let sortedStoryboards = profileSortedStoryboards(visibleStoryboards)
        guard sortedStoryboards.map(\.id) != generatedStoryboards.map(\.id) else {
            return
        }

        generatedStoryboards = sortedStoryboards
        selectedStoryboardIDs.formIntersection(Set(sortedStoryboards.map(\.id)))

        if let selectedStoryboardIndex,
           !sortedStoryboards.indices.contains(selectedStoryboardIndex) {
            self.selectedStoryboardIndex = nil
        }
    }

    private func activeSampleEntryIDsForProfileFilter() async -> Set<UUID> {
        (try? await SupabaseSampleStoryService().loadActiveSampleEntryIDs()) ?? []
    }

    @MainActor
    private func loadSampleProfileStoryboards() async {
        isLoadingMoreProfileStoryboards = false
        hasMoreProfileStoryboards = false
        nextProfileStoryboardOffset = 0
        profileStoryboardCounts = nil
        profileStoryboardErrorMessage = nil

        // The pack another sample screen already loaded, applied before anything is awaited. Same
        // reason as the account path: this screen is rebuilt on every navigation, and the samples
        // were in memory the whole time.
        if !isSampleAuthorMode, let seededPack = SampleContentStore.pack {
            applySampleProfilePack(seededPack)
        }

        isLoadingProfileStoryboards = generatedStoryboards.isEmpty
        defer { isLoadingProfileStoryboards = false }

        do {
            let service = SupabaseSampleStoryService()
            let pack: SampleStoryPack
            if isSampleAuthorMode {
                pack = try await service.loadAuthoringPack()
            } else {
                pack = try await service.loadActivePack()
                SampleContentStore.replace(with: pack)
            }
            applySampleProfilePack(pack)
            playProfileBookOpenHint()
        } catch {
            print("[Journaltopia] Sample profile storyboard load failed: \(error.localizedDescription)")
            if generatedStoryboards.isEmpty {
                profileStoryboardErrorMessage = "Could not load the sample storyboards."
            }
        }
    }

    @MainActor
    private func applySampleProfilePack(_ pack: SampleStoryPack) {
        generatedStoryboards = pack.storyboardsByEntryID.values
            .flatMap { $0 }
            .sorted(by: profileStoryboardSort)
        selectedStoryboardIDs.formIntersection(Set(generatedStoryboards.map(\.id)))
    }

    private func isSampleProfileStoryboard(_ storyboard: GeneratedStoryboard) -> Bool {
        if storyboard.isSampleContent {
            return true
        }

        return storyboard.storagePath?.hasPrefix("journaltopia-first-run/") == true
    }

    private func isProfileEligibleStoryboard(
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

    /// The metadata-only twin of `isProfileEligibleStoryboard`, applied before images are downloaded.
    ///
    /// A downloaded row is always synced and never carries the sample flag, so the two checks that
    /// remain are the ones the row itself answers.
    private func isProfileEligibleStoryboardRow(
        _ row: EntryStoryboard,
        sampleEntryIDs: Set<UUID>
    ) -> Bool {
        guard !sampleEntryIDs.contains(row.clientEntryID) else {
            return false
        }

        return !row.storagePath.hasPrefix("journaltopia-first-run/")
    }

    private func applyProfileStoryboardCounts(_ counts: (total: Int, month: Int)) {
        profileStoryboardCounts = counts
        ProfileStoryboardSessionCache.storeCounts(counts, for: profileLoadModeID)
    }

    private func decrementProfileStoryboardCounts(_ deletedStoryboards: [GeneratedStoryboard]) {
        guard !showsSampleProfileContent, let profileStoryboardCounts else {
            return
        }

        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: Date())
        let deletedThisMonth = deletedStoryboards.filter { storyboard in
            guard let month else {
                return false
            }
            return month.contains(storyboard.createdAt)
        }.count
        applyProfileStoryboardCounts((
            total: max(profileStoryboardCounts.total - deletedStoryboards.count, 0),
            month: max(profileStoryboardCounts.month - deletedThisMonth, 0)
        ))
    }

    private func profileSortedStoryboards(_ storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        storyboards.sorted(by: profileStoryboardSort)
    }

    private func profileStoryboardSort(_ lhs: GeneratedStoryboard, _ rhs: GeneratedStoryboard) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }

        return lhs.id.uuidString > rhs.id.uuidString
    }

    private func endSelection() {
        isSelecting = false
        selectedStoryboardIDs.removeAll()
    }

    private func playProfileBookOpenHint() {
        profileBookOpenTask?.cancel()
        profileBookOpenHintProgress = 0

        guard !reduceMotion, !generatedStoryboards.isEmpty else {
            return
        }

        profileBookOpenTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeOut(duration: 0.42)) {
                profileBookOpenHintProgress = 1
            }

            try? await Task.sleep(nanoseconds: 560_000_000)
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.spring(response: 0.62, dampingFraction: 0.86)) {
                profileBookOpenHintProgress = 0
            }
        }
    }

    private func openProfileComicReader() {
        guard !generatedStoryboards.isEmpty, !isOpeningProfileComicReader else {
            return
        }

        isOpeningProfileComicReader = true
        profileBookOpenTask?.cancel()
        profileBookOpenHintProgress = 0
        profileComicPageIndex = min(profileComicPageIndex, max(0, generatedStoryboards.count - 1))

        guard !reduceMotion else {
            isProfileComicReaderPresented = true
            return
        }

        profileBookOpenTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.14)) {
                profileBookOpenHintProgress = 1
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else {
                return
            }

            profileBookOpenTask = nil
            isProfileComicReaderPresented = true
        }
    }
}

private struct ProfileJournalCoverOpener: View {
    let coverImage: UIImage?
    let openHintProgress: CGFloat
    let isEnabled: Bool
    let onOpen: () -> Void

    private let coverWidth: CGFloat = 92
    private let coverHeight: CGFloat = 128

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                ProfileJournalCoverImage(
                    coverImage: coverImage,
                    openHintProgress: openHintProgress
                )
                .frame(width: coverWidth, height: coverHeight)

                HStack(spacing: 4) {
                    Text("Tap To Open")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(Color.storyInk.opacity(isEnabled ? 0.74 : 0.38))
                .frame(width: 112)
            }
            .frame(width: 112)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Open profile comic")
        .accessibilityHint("Opens the storyboard images on your profile")
    }
}

private struct ProfileJournalCoverImage: View {
    let coverImage: UIImage?
    let openHintProgress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                hintPages
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(x: 3 + (openHintProgress * 5))
                    .scaleEffect(
                        x: 0.992 - (openHintProgress * 0.012),
                        y: 0.99,
                        anchor: .leading
                    )
                    .opacity(openHintProgress > 0 ? 0.86 : 0)

                coverSurface
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .rotation3DEffect(
                        .degrees(-6 * Double(openHintProgress)),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .leading,
                        perspective: 0.66
                    )
                    .offset(x: -1.8 * openHintProgress, y: -1.2 * openHintProgress)
                    .shadow(
                        color: Color.storyInk.opacity(0.13 + (Double(openHintProgress) * 0.12)),
                        radius: 10 + (openHintProgress * 5),
                        y: 5 + (openHintProgress * 3)
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var coverSurface: some View {
        coverFill
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                journalSpine
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
    }

    private var hintPages: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white)
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color.storyInk.opacity(0.13),
                        Color.storyInk.opacity(0.045),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 22)
            }
            .overlay(alignment: .trailing) {
                VStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule()
                            .fill(Color.homeBorder.opacity(0.58))
                            .frame(height: 2)
                    }
                }
                .padding(.horizontal, 14)
                .opacity(0.5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.82), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var coverFill: some View {
        if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .scaledToFill()
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.08), .clear, .black.opacity(0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        } else {
            LinearGradient(
                colors: [
                    Color.homeAccent.opacity(0.55),
                    Color.storyPurple.opacity(0.48),
                    Color.storyInk.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
    }

    private var journalSpine: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.24),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.16),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 8)
            .padding(.leading, 9)
            .blendMode(.screen)
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct ProfileStoryboardComicReaderView: View {
    let storyboards: [GeneratedStoryboard]
    @Binding var currentPageIndex: Int

    @Environment(\.dismiss) private var dismiss

    private let thumbnailHeight: CGFloat = 58

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if storyboards.isEmpty {
                emptyState
            } else {
                TabView(selection: $currentPageIndex) {
                    ForEach(Array(storyboards.enumerated()), id: \.element.id) { index, storyboard in
                        ProfileStoryboardComicPage(storyboard: storyboard)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 0)

                if !storyboards.isEmpty {
                    thumbnailStrip
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            currentPageIndex = clampedPageIndex(currentPageIndex)
        }
        .onChange(of: storyboards.count) { _ in
            currentPageIndex = clampedPageIndex(currentPageIndex)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to profile")

            Spacer()

            Text(storyboards.isEmpty ? "0 / 0" : "\(currentPageIndex + 1) / \(storyboards.count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            Color.clear
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0.28), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(storyboards.enumerated()), id: \.element.id) { index, storyboard in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentPageIndex = index
                            }
                        } label: {
                            ProfileStoryboardComicThumbnail(
                                image: storyboard.image,
                                isSelected: index == currentPageIndex,
                                height: thumbnailHeight
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("Go to storyboard \(index + 1)")
                        .accessibilityAddTraits(index == currentPageIndex ? .isSelected : [])
                    }
                }
                .frame(minHeight: thumbnailHeight + 12)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background {
                Color.black.opacity(0.34)
                    .ignoresSafeArea(edges: .bottom)
            }
            .onAppear {
                proxy.scrollTo(currentPageIndex, anchor: .center)
            }
            .onChange(of: currentPageIndex) { pageIndex in
                withAnimation(.easeInOut(duration: 0.24)) {
                    proxy.scrollTo(pageIndex, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))

            Text("No storyboards yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, storyboards.count - 1))
    }
}

private struct ProfileStoryboardComicPage: View {
    let storyboard: GeneratedStoryboard

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: storyboard.image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color.black)
        }
        .overlay(alignment: .bottomLeading) {
            storyboardMetadata
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
        }
    }

    private var storyboardMetadata: some View {
        HStack(spacing: 8) {
            Text(storyboard.artStyle)
                .font(.system(size: 12, weight: .heavy, design: .rounded))

            if let qualityText = storyboard.generationQuality?.title {
                Text(qualityText)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Color.black.opacity(0.56), in: Capsule())
    }
}

private struct ProfileStoryboardComicThumbnail: View {
    let image: UIImage
    let isSelected: Bool
    let height: CGFloat

    var body: some View {
        let aspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 0.72
        let thumbnailWidth = max(36, height * aspectRatio)

        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: thumbnailWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isSelected ? Color.white : Color.white.opacity(0.22),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .shadow(color: .black.opacity(isSelected ? 0.42 : 0.2), radius: isSelected ? 8 : 4, y: 2)
            .opacity(isSelected ? 1 : 0.74)
            .scaleEffect(isSelected ? 1.05 : 1)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

struct ProfileStat: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StoryboardPlaceholderCard: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
                .overlay(
                    Rectangle()
                        .stroke(Color.homeBorder, lineWidth: 1)
                )

            VStack(spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "photo")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Color.homeAccent.opacity(0.28))

                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.homeAccent.opacity(0.38))
                        .offset(x: 13, y: -8)
                }

                Text("No storyboards yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.homeMutedText.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.72, contentMode: .fit)
    }
}

struct LoadingStoryboardCard: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
                .overlay(
                    Rectangle()
                        .stroke(Color.homeBorder, lineWidth: 1)
                )

            ProgressView()
                .tint(Color.homeAccent)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.72, contentMode: .fit)
    }
}

struct ProfileStoryboardErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.homeAccent.opacity(0.7))

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try Again", action: retry)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 16)
        .background(Color.white)
        .overlay(
            Rectangle()
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }
}

struct GeneratedStoryboardThumbnail: View {
    let storyboard: GeneratedStoryboard
    var isSelecting = false
    var isSelected = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Image(uiImage: storyboard.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if isSelecting {
                    Color.black
                        .opacity(isSelected ? 0.18 : 0.04)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.homeAccent : .white)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.white : Color.black.opacity(0.28))
                                .padding(2)
                        )
                        .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.72, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .overlay {
            if isSelected {
                Rectangle()
                    .stroke(Color.homeAccent, lineWidth: 3)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {
    }
}

private struct PendingStoryboardDeletion: Identifiable {
    let id = UUID()
    let storyboards: [GeneratedStoryboard]
    let preview: StoryboardDeletionPreview

    var alertTitle: String {
        preview.storyboardCount == 1 ? "Delete Storyboard?" : "Delete \(preview.storyboardCount) Storyboards?"
    }

    var confirmationMessage: String {
        let isSingleStoryboard = preview.storyboardCount == 1
        let creditNote = isSingleStoryboard
            ? "This can't be undone."
            : "This can't be undone."

        switch preview.entriesReturningToDrafts {
        case 0:
            let keptText = isSingleStoryboard
                ? "Only this one is deleted. Its entry keeps its other storyboards and stays completed."
                : "Every affected entry keeps at least one other storyboard and stays completed."
            return "\(keptText) \(creditNote)"
        case 1:
            let entryText = isSingleStoryboard
                ? "This is the last storyboard for its entry, so that entry moves back to Drafts."
                : "1 entry loses its last storyboard and moves back to Drafts."
            return "\(entryText) \(creditNote)"
        case let entryCount:
            return "\(entryCount) entries lose their last storyboard and move back to Drafts. \(creditNote)"
        }
    }
}

private extension View {
    func selectionActionStyle(color: Color = .storyInk) -> some View {
        self
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(Color.white, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.homeBorder, lineWidth: 1)
            }
    }
}

/// Deletion behavior for the full-screen viewer. The host supplies the confirmation copy,
/// because only it knows whether this is the entry's last storyboard, while the viewer keeps
/// the confirmation on screen so deleting never kicks the reader out of the sheet.
struct StoryboardViewerDeleteAction {
    let message: (GeneratedStoryboard) -> String
    let perform: (GeneratedStoryboard) -> Void

    init(
        message: @escaping (GeneratedStoryboard) -> String,
        perform: @escaping (GeneratedStoryboard) -> Void
    ) {
        self.message = message
        self.perform = perform
    }
}

struct StoryboardImageViewer: View {
    let storyboards: [GeneratedStoryboard]
    let initialIndex: Int
    let onSelectPrimary: ((GeneratedStoryboard) -> Void)?
    let hasMoreStoryboards: Bool
    let isLoadingMoreStoryboards: Bool
    let onLoadMoreStoryboards: (() async -> Void)?
    let allowsSharing: Bool
    let deleteAction: StoryboardViewerDeleteAction?

    @Environment(\.dismiss) private var dismiss
    @State private var visibleIndex: Int
    @State private var primaryStoryboardID: UUID?
    @State private var storyboardPendingDeletion: GeneratedStoryboard?
    @State private var storyboardToShare: GeneratedStoryboard?

    init(
        storyboards: [GeneratedStoryboard],
        initialIndex: Int,
        onSelectPrimary: ((GeneratedStoryboard) -> Void)? = nil,
        hasMoreStoryboards: Bool = false,
        isLoadingMoreStoryboards: Bool = false,
        onLoadMoreStoryboards: (() async -> Void)? = nil,
        allowsSharing: Bool = false,
        deleteAction: StoryboardViewerDeleteAction? = nil
    ) {
        self.storyboards = storyboards
        self.initialIndex = initialIndex
        self.onSelectPrimary = onSelectPrimary
        self.hasMoreStoryboards = hasMoreStoryboards
        self.isLoadingMoreStoryboards = isLoadingMoreStoryboards
        self.onLoadMoreStoryboards = onLoadMoreStoryboards
        self.allowsSharing = allowsSharing
        self.deleteAction = deleteAction
        _visibleIndex = State(initialValue: initialIndex)
        _primaryStoryboardID = State(initialValue: storyboards.first(where: \.isPrimary)?.id)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.storyInk
                .ignoresSafeArea()

            ZoomableVerticalStoryboardView(
                storyboards: storyboards,
                images: storyboards.map(\.image),
                initialIndex: initialIndex,
                visibleIndex: $visibleIndex,
                primaryStoryboardID: primaryStoryboardID,
                onSelectPrimary: primarySelectionHandler,
                onDeleteStoryboard: storyboardDeletionHandler,
                onShareStoryboard: storyboardShareHandler,
                hasMoreStoryboards: hasMoreStoryboards,
                isLoadingMoreStoryboards: isLoadingMoreStoryboards,
                onLoadMoreStoryboards: onLoadMoreStoryboards
            )
            .background(Color.black)

            HStack {
                Text("\(visibleIndex + 1) of \(storyboards.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(.black.opacity(0.62), in: Capsule())

                Spacer()

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
                .accessibilityLabel("Close storyboard viewer")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .sheet(item: $storyboardToShare) { storyboard in
            ActivityView(activityItems: [storyboard.image])
                .presentationDetents([.medium, .large])
        }
        .alert(
            "Delete Storyboard?",
            isPresented: Binding(
                get: { storyboardPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        storyboardPendingDeletion = nil
                    }
                }
            ),
            presenting: storyboardPendingDeletion
        ) { storyboard in
            Button("Cancel", role: .cancel) {
                storyboardPendingDeletion = nil
            }

            Button("Delete", role: .destructive) {
                storyboardPendingDeletion = nil
                deleteAction?.perform(storyboard)
            }
        } message: { storyboard in
            Text(deleteAction?.message(storyboard) ?? "")
        }
    }

    private var shouldShowPrimaryPicker: Bool {
        onSelectPrimary != nil && storyboards.count > 1
    }

    private var primarySelectionHandler: ((GeneratedStoryboard) -> Void)? {
        guard shouldShowPrimaryPicker else {
            return nil
        }

        return { storyboard in
            primaryStoryboardID = storyboard.id
            onSelectPrimary?(storyboard)
        }
    }

    private var storyboardDeletionHandler: ((GeneratedStoryboard) -> Void)? {
        guard deleteAction != nil else {
            return nil
        }

        return { storyboard in
            storyboardPendingDeletion = storyboard
        }
    }

    private var storyboardShareHandler: ((GeneratedStoryboard) -> Void)? {
        guard allowsSharing else {
            return nil
        }

        return { storyboard in
            storyboardToShare = storyboard
        }
    }
}

private struct StoryboardPrimarySelectionRow: View {
    let storyboards: [GeneratedStoryboard]
    let primaryStoryboardID: UUID?
    let onSelectStoryboard: (Int) -> Void
    let onDeleteStoryboard: ((GeneratedStoryboard) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text("Current Storyboards for this Entry")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Text("\(storyboards.count)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.storyPurple.opacity(0.72), in: Circle())

                Spacer(minLength: 0)
            }

            Text("The Primary image is the one that will be shown in your journal for this entry. Tap Set as Primary on another storyboard to change which image appears there.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(storyboards.enumerated()), id: \.element.id) { index, storyboard in
                        Button {
                            onSelectStoryboard(index)
                        } label: {
                            StoryboardPrimarySelectionThumbnail(
                                image: storyboard.image,
                                isPrimary: storyboard.id == primaryStoryboardID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(storyboard.id == primaryStoryboardID ? "Primary storyboard, go to storyboard \(index + 1)" : "Go to storyboard \(index + 1)")
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

}

private struct StoryboardPrimarySelectionThumbnail: View {
    let image: UIImage
    let isPrimary: Bool

    var body: some View {
        let aspectRatio = max(image.size.width, 1) / max(image.size.height, 1)
        let thumbnailHeight: CGFloat = 132

        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: min(max(thumbnailHeight * aspectRatio, 100), 214), height: thumbnailHeight)
            .clipped()
            .background(Color.storyInk.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isPrimary ? Color.storyPurple : Color.storyBorder.opacity(0.58), lineWidth: isPrimary ? 2 : 1)
            )
            .overlay(alignment: .bottomLeading) {
                if isPrimary {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .black))

                        Text("Primary")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.storyPurple, in: UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 7,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 6,
                        style: .continuous
                    ))
                }
            }
    }
}

private struct StoryboardViewerLoadMoreFooter: View {
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            HStack(spacing: 9) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 13, weight: .bold))
                }

                Text(isLoading ? "Loading..." : "Load More")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 40)
        .accessibilityLabel(isLoading ? "Loading more storyboards" : "Load more storyboards")
    }
}

private struct ZoomableVerticalStoryboardView: UIViewRepresentable {
    let storyboards: [GeneratedStoryboard]
    let images: [UIImage]
    let initialIndex: Int
    @Binding var visibleIndex: Int
    let primaryStoryboardID: UUID?
    let onSelectPrimary: ((GeneratedStoryboard) -> Void)?
    let onDeleteStoryboard: ((GeneratedStoryboard) -> Void)?
    let onShareStoryboard: ((GeneratedStoryboard) -> Void)?
    let hasMoreStoryboards: Bool
    let isLoadingMoreStoryboards: Bool
    let onLoadMoreStoryboards: (() async -> Void)?
    private let topOverlayClearance: CGFloat = 64

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private var hasStoryboardPicker: Bool {
        onSelectPrimary != nil && storyboards.count > 1
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
        populateStackView(stackView, in: scrollView, context: context)

        DispatchQueue.main.async {
            context.coordinator.scrollToInitialImage(in: scrollView)
        }

        return scrollView
    }

    private func populateStackView(_ stackView: UIStackView, in scrollView: UIScrollView, context: Context) {
        let topSpacer = UIView()
        topSpacer.backgroundColor = .black
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        topSpacer.heightAnchor.constraint(equalToConstant: topOverlayClearance).isActive = true
        stackView.addArrangedSubview(topSpacer)

        if let storyboardPicker = makeStoryboardPicker(in: scrollView, context: context) {
            stackView.addArrangedSubview(storyboardPicker)
        }
        context.coordinator.imageViews = images.enumerated().map { index, image in
            if index > 0 {
                stackView.addArrangedSubview(
                    makeImageBoundary(nextIndex: index, totalCount: images.count)
                )
            }

            let imageContainer = makeStoryboardImageContainer(
                image: image,
                storyboard: storyboards.indices.contains(index) ? storyboards[index] : nil,
                context: context
            )
            stackView.addArrangedSubview(imageContainer)
            if storyboards.indices.contains(index) {
                stackView.addArrangedSubview(makeMetadataView(for: storyboards[index]))
            }
            return imageContainer
        }
        context.coordinator.renderedPrimaryStoryboardID = primaryStoryboardID
        context.coordinator.renderedStoryboardIDs = storyboards.map(\.id)
        context.coordinator.renderedHasMoreStoryboards = hasMoreStoryboards
        context.coordinator.renderedIsLoadingMoreStoryboards = isLoadingMoreStoryboards

        if let loadMoreFooter = makeLoadMoreFooter(context: context) {
            stackView.addArrangedSubview(loadMoreFooter)
        }
    }

    private func makeStoryboardImageContainer(
        image: UIImage,
        storyboard: GeneratedStoryboard?,
        context: Context
    ) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(
            equalTo: container.widthAnchor,
            multiplier: image.size.height / max(image.size.width, 1)
        ).isActive = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Anchored to the artwork's top-right corner, opposite the Primary badge, so it is
        // unmistakably the control for this one image.
        if let storyboard, storyboard.isDeletable, onDeleteStoryboard != nil {
            let deleteButton = deleteStoryboardButton()
            deleteButton.addAction(UIAction { _ in
                context.coordinator.requestDelete(storyboard)
            }, for: .touchUpInside)
            container.addSubview(deleteButton)

            NSLayoutConstraint.activate([
                deleteButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -16),
                deleteButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 16)
            ])
        }

        if let storyboard, onShareStoryboard != nil {
            let shareButton = shareStoryboardButton()
            shareButton.addAction(UIAction { _ in
                context.coordinator.requestShare(storyboard)
            }, for: .touchUpInside)
            container.addSubview(shareButton)

            NSLayoutConstraint.activate([
                shareButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 16),
                shareButton.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 16)
            ])
        }

        guard
            let storyboard,
            onSelectPrimary != nil,
            storyboards.count > 1
        else {
            return container
        }

        if storyboard.id == primaryStoryboardID {
            let border = UIView()
            border.isUserInteractionEnabled = false
            border.layer.borderColor = UIColor(Color.storyPurple).cgColor
            border.layer.borderWidth = 4
            border.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(border)

            let badge = primaryBadge()
            container.addSubview(badge)

            // Track the aspect-fit rect of the image rather than the image view's
            // frame, so the border hugs the artwork instead of any letterboxing.
            let fillsWidth = border.widthAnchor.constraint(equalTo: imageView.widthAnchor)
            fillsWidth.priority = .defaultHigh
            let fillsHeight = border.heightAnchor.constraint(equalTo: imageView.heightAnchor)
            fillsHeight.priority = .defaultHigh

            NSLayoutConstraint.activate([
                border.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                border.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
                border.heightAnchor.constraint(
                    equalTo: border.widthAnchor,
                    multiplier: image.size.height / max(image.size.width, 1)
                ),
                border.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor),
                border.heightAnchor.constraint(lessThanOrEqualTo: imageView.heightAnchor),
                fillsWidth,
                fillsHeight,
                badge.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 16),
                badge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 16)
            ])
        } else {
            let button = setPrimaryButton()
            button.addAction(UIAction { _ in
                context.coordinator.selectPrimary(storyboard)
            }, for: .touchUpInside)
            container.addSubview(button)

            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -16),
                button.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -16)
            ])
        }

        return container
    }

    private func deleteStoryboardButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "trash",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        )
        configuration.baseForegroundColor = UIColor(Color.storyboardDeleteTint)
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.62)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Delete this storyboard"
        return button
    }

    private func shareStoryboardButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "square.and.arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        )
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.62)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Share this storyboard"
        return button
    }

    private func primaryBadge() -> UIView {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "star.fill")
        configuration.imagePadding = 5
        configuration.title = "Primary"
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor(Color.storyPurple)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 13)

        let badge = UIButton(configuration: configuration)
        badge.isUserInteractionEnabled = false
        badge.titleLabel?.font = .systemFont(ofSize: 13, weight: .heavy)
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }

    private func setPrimaryButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "star")
        configuration.imagePadding = 6
        configuration.title = "Set as Primary"
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor(Color.storyPurple).withAlphaComponent(0.92)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 15)

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .heavy)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.26
        button.layer.shadowRadius = 10
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Set storyboard as primary"
        return button
    }

    private func makeMetadataView(for storyboard: GeneratedStoryboard) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let artStyleLabel = metadataLabel(text: "Art Style: \(storyboard.artStyle)", alignment: .left)

        stack.addArrangedSubview(artStyleLabel)
        if let qualityText = storyboard.generationQuality?.title {
            let qualityLabel = metadataLabel(text: "Quality: \(qualityText)", alignment: .right)
            stack.addArrangedSubview(qualityLabel)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])

        return container
    }

    private func metadataLabel(text: String, alignment: NSTextAlignment) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = UIColor(white: 0.68, alpha: 1)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = alignment
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.82
        return label
    }

    private func makeStoryboardPicker(in scrollView: UIScrollView, context: Context) -> UIView? {
        guard let onSelectPrimary, storyboards.count > 1 else {
            return nil
        }

        let picker = StoryboardPrimarySelectionRow(
            storyboards: storyboards,
            primaryStoryboardID: primaryStoryboardID,
            onSelectStoryboard: { index in
                context.coordinator.scrollToStoryboard(at: index, in: scrollView, animated: true)
            },
            onDeleteStoryboard: onDeleteStoryboard
        )
        let hostingController = UIHostingController(rootView: picker)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.storyboardPickerHostingController = hostingController

        return hostingController.view
    }

    private func makeLoadMoreFooter(context: Context) -> UIView? {
        guard hasMoreStoryboards, let onLoadMoreStoryboards else {
            return nil
        }

        let footer = StoryboardViewerLoadMoreFooter(
            isLoading: isLoadingMoreStoryboards,
            action: onLoadMoreStoryboards
        )
        let hostingController = UIHostingController(rootView: footer)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.loadMoreFooterHostingController = hostingController
        return hostingController.view
    }

    private func makeImageBoundary(nextIndex _: Int, totalCount _: Int) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.035, alpha: 1)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 6).isActive = true

        return container
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        let needsRebuild = context.coordinator.renderedPrimaryStoryboardID != primaryStoryboardID
            || context.coordinator.renderedStoryboardIDs != storyboards.map(\.id)
            || context.coordinator.renderedHasMoreStoryboards != hasMoreStoryboards

        if needsRebuild, let stackView = context.coordinator.stackView {
            // Clamp, because a deleted storyboard can leave the preserved index past the end.
            let preservedVisibleIndex = min(visibleIndex, max(storyboards.count - 1, 0))
            for arrangedSubview in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }
            context.coordinator.storyboardPickerHostingController = nil
            context.coordinator.loadMoreFooterHostingController = nil
            populateStackView(stackView, in: scrollView, context: context)
            scrollView.layoutIfNeeded()
            stackView.layoutIfNeeded()
            context.coordinator.scrollToStoryboard(at: preservedVisibleIndex, in: scrollView, animated: false)
        } else {
            if onSelectPrimary != nil {
                context.coordinator.storyboardPickerHostingController?.rootView = StoryboardPrimarySelectionRow(
                    storyboards: storyboards,
                    primaryStoryboardID: primaryStoryboardID,
                    onSelectStoryboard: { index in
                        context.coordinator.scrollToStoryboard(at: index, in: scrollView, animated: true)
                    },
                    onDeleteStoryboard: onDeleteStoryboard
                )
            }

            if hasMoreStoryboards, let onLoadMoreStoryboards {
                context.coordinator.loadMoreFooterHostingController?.rootView = StoryboardViewerLoadMoreFooter(
                    isLoading: isLoadingMoreStoryboards,
                    action: onLoadMoreStoryboards
                )
                context.coordinator.renderedIsLoadingMoreStoryboards = isLoadingMoreStoryboards
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableVerticalStoryboardView
        weak var stackView: UIStackView?
        var storyboardPickerHostingController: UIHostingController<StoryboardPrimarySelectionRow>?
        var loadMoreFooterHostingController: UIHostingController<StoryboardViewerLoadMoreFooter>?
        var imageViews: [UIView] = []
        var renderedPrimaryStoryboardID: UUID?
        var renderedStoryboardIDs: [UUID] = []
        var renderedHasMoreStoryboards = false
        var renderedIsLoadingMoreStoryboards = false
        private var didScrollToInitialImage = false

        init(parent: ZoomableVerticalStoryboardView) {
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

        func scrollToInitialImage(in scrollView: UIScrollView) {
            guard
                !didScrollToInitialImage,
                imageViews.indices.contains(parent.initialIndex)
            else {
                return
            }

            scrollView.layoutIfNeeded()
            stackView?.layoutIfNeeded()

            if parent.hasStoryboardPicker && parent.initialIndex == 0 {
                scrollView.setContentOffset(.zero, animated: false)
                didScrollToInitialImage = true
                updateVisibleIndex(in: scrollView)
                return
            }

            let imageView = imageViews[parent.initialIndex]
            let targetY = max(
                0,
                imageView.frame.midY - (scrollView.bounds.height / 2)
            )
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            didScrollToInitialImage = true
            updateVisibleIndex(in: scrollView)
        }

        func scrollToStoryboard(at index: Int, in scrollView: UIScrollView, animated: Bool) {
            guard imageViews.indices.contains(index) else {
                return
            }

            let imageView = imageViews[index]
            scrollView.layoutIfNeeded()
            stackView?.layoutIfNeeded()
            let targetY = max(
                0,
                imageView.frame.minY - parent.topOverlayClearance
            )
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
            parent.visibleIndex = index
        }

        func selectPrimary(_ storyboard: GeneratedStoryboard) {
            parent.onSelectPrimary?(storyboard)
        }

        func requestDelete(_ storyboard: GeneratedStoryboard) {
            parent.onDeleteStoryboard?(storyboard)
        }

        func requestShare(_ storyboard: GeneratedStoryboard) {
            parent.onShareStoryboard?(storyboard)
        }

        private func updateVisibleIndex(in scrollView: UIScrollView) {
            guard !imageViews.isEmpty else {
                return
            }

            let viewportCenterY = scrollView.contentOffset.y + (scrollView.bounds.height / 2)
            let zoomScale = scrollView.zoomScale
            let closestIndex = imageViews.indices.min { left, right in
                abs((imageViews[left].frame.midY * zoomScale) - viewportCenterY)
                    < abs((imageViews[right].frame.midY * zoomScale) - viewportCenterY)
            }

            guard
                let closestIndex,
                closestIndex != parent.visibleIndex
            else {
                return
            }

            parent.visibleIndex = closestIndex
        }
    }
}

private struct LegacyStoryboardImageViewer: View {
    let storyboard: GeneratedStoryboard

    @Environment(\.dismiss) private var dismiss
    @State private var imageScale: CGFloat = 1
    @State private var lastImageScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @State private var lastImageOffset: CGSize = .zero

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 5
    private let horizontalPadding: CGFloat = 0
    private let verticalPadding: CGFloat = 52

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            GeometryReader { proxy in
                let viewportSize = proxy.size
                let imageSize = fittedImageSize(in: viewportSize)

                Image(uiImage: storyboard.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(imageScale * dismissalScale)
                    .offset(imageOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .contentShape(Rectangle())
                    .gesture(imageGesture(imageSize: imageSize, viewportSize: viewportSize))
                    .onTapGesture(count: 2) {
                        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                            if imageScale > minimumScale {
                                resetZoom()
                            } else {
                                imageScale = 2.35
                                lastImageScale = imageScale
                            }

                            imageOffset = boundedOffset(
                                imageOffset,
                                imageSize: imageSize,
                                viewportSize: viewportSize
                            )
                            lastImageOffset = imageOffset
                        }
                    }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(closeButtonOpacity)
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        .background(Color.clear)
    }

    private func imageGesture(imageSize: CGSize, viewportSize: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    imageScale = rubberBandScale(lastImageScale * value)
                    imageOffset = boundedOffset(
                        imageOffset,
                        imageSize: imageSize,
                        viewportSize: viewportSize,
                        allowsResistance: true
                    )
                }
                .onEnded { _ in
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.84)) {
                        imageScale = clampedScale(imageScale)
                        imageOffset = boundedOffset(
                            imageOffset,
                            imageSize: imageSize,
                            viewportSize: viewportSize
                        )

                        if imageScale <= minimumScale {
                            imageOffset = .zero
                        }

                        lastImageScale = imageScale
                        lastImageOffset = imageOffset
                    }
                },
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if imageScale <= minimumScale {
                        imageOffset = CGSize(
                            width: value.translation.width * 0.16,
                            height: max(value.translation.height, 0)
                        )
                        return
                    }

                    let proposedOffset = CGSize(
                        width: lastImageOffset.width + value.translation.width,
                        height: lastImageOffset.height + value.translation.height
                    )

                    imageOffset = boundedOffset(
                        proposedOffset,
                        imageSize: imageSize,
                        viewportSize: viewportSize,
                        allowsResistance: true
                    )
                }
                .onEnded { value in
                    if imageScale <= minimumScale {
                        closeOrResetAfterSwipe(value)
                        return
                    }

                    let projectedOffset = CGSize(
                        width: imageOffset.width + (value.predictedEndTranslation.width - value.translation.width) * 0.28,
                        height: imageOffset.height + (value.predictedEndTranslation.height - value.translation.height) * 0.28
                    )

                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.86)) {
                        imageOffset = boundedOffset(
                            projectedOffset,
                            imageSize: imageSize,
                            viewportSize: viewportSize
                        )
                        lastImageOffset = imageOffset
                    }
                }
        )
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    private func rubberBandScale(_ scale: CGFloat) -> CGFloat {
        if scale < minimumScale {
            return minimumScale - ((minimumScale - scale) * 0.42)
        }

        if scale > maximumScale {
            return maximumScale + ((scale - maximumScale) * 0.18)
        }

        return scale
    }

    private func fittedImageSize(in viewportSize: CGSize) -> CGSize {
        let availableSize = CGSize(
            width: max(viewportSize.width - (horizontalPadding * 2), 1),
            height: max(viewportSize.height - (verticalPadding * 2), 1)
        )
        let sourceSize = storyboard.image.size
        let sourceAspectRatio = sourceSize.width / max(sourceSize.height, 1)
        let availableAspectRatio = availableSize.width / max(availableSize.height, 1)

        if sourceAspectRatio > availableAspectRatio {
            let height = availableSize.width / sourceAspectRatio
            return CGSize(width: availableSize.width, height: height)
        } else {
            let width = availableSize.height * sourceAspectRatio
            return CGSize(width: width, height: availableSize.height)
        }
    }

    private func boundedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize,
        allowsResistance: Bool = false
    ) -> CGSize {
        let bounds = offsetBounds(imageSize: imageSize, viewportSize: viewportSize)

        return CGSize(
            width: boundedValue(offset.width, limit: bounds.width, allowsResistance: allowsResistance),
            height: boundedValue(offset.height, limit: bounds.height, allowsResistance: allowsResistance)
        )
    }

    private func offsetBounds(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        let visibleSize = CGSize(
            width: max(viewportSize.width - (horizontalPadding * 2), 1),
            height: max(viewportSize.height - (verticalPadding * 2), 1)
        )

        return CGSize(
            width: max(((imageSize.width * imageScale) - visibleSize.width) / 2, 0),
            height: max(((imageSize.height * imageScale) - visibleSize.height) / 2, 0)
        )
    }

    private func boundedValue(_ value: CGFloat, limit: CGFloat, allowsResistance: Bool) -> CGFloat {
        guard limit > 0 else {
            return allowsResistance ? value * 0.18 : 0
        }

        guard abs(value) > limit else {
            return value
        }

        let overshoot = abs(value) - limit
        let resistedOvershoot = allowsResistance ? rubberBandDistance(overshoot) : 0
        return (limit + resistedOvershoot) * (value < 0 ? -1 : 1)
    }

    private func rubberBandDistance(_ distance: CGFloat) -> CGFloat {
        (1 - (1 / ((distance * 0.008) + 1))) * 120
    }

    private var backgroundOpacity: Double {
        guard imageScale <= minimumScale else {
            return 1
        }

        return 1 - (Double(dismissProgress) * 0.92)
    }

    private var dismissProgress: CGFloat {
        min(max(imageOffset.height / 260, 0), 1)
    }

    private var dismissalScale: CGFloat {
        guard imageScale <= minimumScale else {
            return 1
        }

        return 1 - (dismissProgress * 0.12)
    }

    private var closeButtonOpacity: Double {
        guard imageScale <= minimumScale else {
            return 1
        }

        return max(1 - Double(dismissProgress * 1.7), 0)
    }

    private func closeOrResetAfterSwipe(_ value: DragGesture.Value) {
        let isDownwardSwipe = value.translation.height > 120
        let isMostlyVertical = value.translation.height > abs(value.translation.width)

        if isDownwardSwipe && isMostlyVertical {
            dismiss()
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            imageOffset = .zero
            lastImageOffset = .zero
        }
    }

    private func resetOffsetIfNeeded() {
        guard imageScale <= minimumScale else {
            return
        }

        imageOffset = .zero
        lastImageOffset = .zero
    }

    private func resetZoom() {
        imageScale = minimumScale
        lastImageScale = minimumScale
        imageOffset = .zero
        lastImageOffset = .zero
    }
}

/// The first page of the profile grid, kept for the length of the session.
///
/// `ProfileView` is destroyed and rebuilt on every navigation, so its `.task` re-ran and refetched
/// the whole page each time — and because the load cleared the array before going to the network,
/// every visit spent a round trip showing placeholder tiles over content it already had. The header
/// cover is `generatedStoryboards.first`, so it blanked along with the grid.
///
/// Keyed by the same load identity the `.task` is, so signing in, signing out and the sample-author
/// toggle each get their own entry rather than seeing one another's storyboards.
private enum ProfileStoryboardSessionCache {
    private static let freshnessInterval: TimeInterval = 300
    private static var pagesByLoadID: [String: Page] = [:]
    /// Server-side counts for the whole account, kept alongside the cached page so a rebuilt
    /// Profile draws its header stats without fetching every metadata row.
    private static var countsByLoadID: [String: (total: Int, month: Int)] = [:]

    /// Registered once, for the process, rather than on the view.
    ///
    /// The case that matters is a storyboard finishing while the user is somewhere else — Create, or
    /// another app entirely. `ProfileView` is not mounted to hear about it, so an observer on the
    /// view would leave the next visit served a "fresh" cached page that predates the storyboard
    /// just generated. Invalidating where the cache lives is what keeps that from happening.
    private static let storyboardChangeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: .journaltopiaGeneratedStoryboardsChanged,
        object: nil,
        queue: .main
    ) { _ in
        markAllStale()
    }

    /// `storyboardChangeObserver` is a lazy `static let`, so it does not exist until something asks
    /// for it. Every entry point into the cache does.
    private static func startObservingIfNeeded() {
        _ = storyboardChangeObserver
    }

    struct Page {
        let storyboards: [GeneratedStoryboard]
        let nextOffset: Int
        let hasMore: Bool
        let loadedAt: Date
    }

    static func page(for loadID: String) -> Page? {
        startObservingIfNeeded()
        return pagesByLoadID[loadID]
    }

    static func isFresh(_ page: Page) -> Bool {
        Date().timeIntervalSince(page.loadedAt) < freshnessInterval
    }

    static func store(
        storyboards: [GeneratedStoryboard],
        nextOffset: Int,
        hasMore: Bool,
        for loadID: String
    ) {
        startObservingIfNeeded()
        pagesByLoadID[loadID] = Page(
            storyboards: storyboards,
            nextOffset: nextOffset,
            hasMore: hasMore,
            loadedAt: Date()
        )
    }

    static func counts(for loadID: String) -> (total: Int, month: Int)? {
        startObservingIfNeeded()
        return countsByLoadID[loadID]
    }

    static func storeCounts(_ counts: (total: Int, month: Int), for loadID: String) {
        startObservingIfNeeded()
        countsByLoadID[loadID] = counts
    }

    private static func markAllStale() {
        for (loadID, _) in pagesByLoadID {
            markStale(for: loadID)
        }
    }

    /// Drops the freshness stamp but keeps the storyboards, so the next load refetches while still
    /// having something to draw.
    static func markStale(for loadID: String) {
        guard let page = pagesByLoadID[loadID] else {
            return
        }

        pagesByLoadID[loadID] = Page(
            storyboards: page.storyboards,
            nextOffset: page.nextOffset,
            hasMore: page.hasMore,
            loadedAt: .distantPast
        )
    }

    static func removeAll() {
        pagesByLoadID.removeAll()
        countsByLoadID.removeAll()
    }
}

/// `LocalUserDataPurge`'s hook into this file, matching `JournalLocalCachePurge`. The cache holds one
/// account's storyboard images in memory for the life of the process, so deleting the account's files
/// on sign-out is not on its own enough to stop them being shown to whoever signs in next.
enum ProfileLocalCachePurge {
    static func purgeInMemoryCaches() {
        ProfileStoryboardSessionCache.removeAll()
    }
}
