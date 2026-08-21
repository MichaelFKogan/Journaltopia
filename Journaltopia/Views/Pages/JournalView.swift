import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private func playJournalFloatingButtonHaptic() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.82)
}

/// Turns the sample pack's journals into the same `PrototypeChapter`/`PrototypeEntry` shapes every
/// journal surface already renders.
///
/// It lives at file scope rather than inside `JournalView` because Journals is not the only screen
/// that shows sample journals — the daily Daybook does too — and two screens deriving "which sample
/// journal is this and what is in it" separately is exactly how they drift apart.
@MainActor
enum SampleJournalDisplay {
    static func chapter(from journal: SampleJournal) -> PrototypeChapter {
        PrototypeChapter(
            id: journal.id,
            title: journal.title,
            subtitle: journal.subtitle ?? "Sample journal",
            color: journal.colorHex.flatMap(Color.init(hex:)) ?? Color.storyPurple,
            symbol: journal.symbol ?? "book.closed.fill",
            coverImageName: journal.coverImageName,
            remoteCover: journal.remoteCover,
            kind: journal.kind == "storyboard" ? .storyboard : .journal,
            isFavorite: journal.isFavorite,
            createdAt: journal.createdAt,
            updatedAt: journal.updatedAt,
            entries: entries(from: journal.entries)
        )
    }

    static func entries(from drafts: [CreateEntryDraft]) -> [PrototypeEntry] {
        // A `for` loop rather than `map`: the closure `map` takes is not actor-isolated, and both
        // this conversion and `PrototypeEntry.init` are.
        var converted: [PrototypeEntry] = []
        converted.reserveCapacity(drafts.count)
        for draft in drafts {
            converted.append(entry(from: draft))
        }

        return converted
    }

    static func entry(from entry: CreateEntryDraft) -> PrototypeEntry {
        PrototypeEntry(
            id: entry.id,
            weekday: entry.date.formatted(.dateTime.weekday(.abbreviated)).uppercased(),
            day: entry.date.formatted(.dateTime.day()),
            title: entry.title.isEmpty ? "Untitled Sample" : entry.title,
            body: entry.text,
            richText: entry.richText,
            time: entry.date.formatted(.dateTime.hour().minute()),
            location: entry.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : entry.location,
            imageNames: [],
            createdAt: entry.createdAt
        )
    }
}

private func sampleStoryboardsByMergingLocalFallbacks(
    remoteStoryboardsByEntryID: [UUID: [GeneratedStoryboard]],
    entries: [CreateEntryDraft],
    repairsMissingRemote: Bool
) -> [UUID: [GeneratedStoryboard]] {
    let entryIDs = Set(entries.map(\.id))
    guard !entryIDs.isEmpty else {
        return remoteStoryboardsByEntryID
    }

    var merged = remoteStoryboardsByEntryID
    let remoteStoryboardIDs = Set(remoteStoryboardsByEntryID.values.flatMap { $0.map(\.id) })
    let localStoryboards = GeneratedStoryboardStore.load().filter { storyboard in
        guard let clientEntryID = storyboard.clientEntryID else {
            return false
        }

        return entryIDs.contains(clientEntryID) && !remoteStoryboardIDs.contains(storyboard.id)
    }

    for storyboard in localStoryboards {
        guard let clientEntryID = storyboard.clientEntryID else {
            continue
        }

        merged[clientEntryID, default: []].append(storyboard)
        if repairsMissingRemote {
            Task {
                _ = try? await SupabaseSampleStoryService().persistSampleStoryboard(storyboard)
            }
        }
    }

    return merged.mapValues { storyboards in
        storyboards.sorted { left, right in
            if left.isPrimary != right.isPrimary {
                return left.isPrimary
            }

            return left.createdAt < right.createdAt
        }
    }
}

private func duplicateStoryboardsForEntry(
    sourceClientEntryID: UUID,
    duplicateClientEntryID: UUID,
    isSignedIn: Bool
) async -> [GeneratedStoryboard] {
    var sourceStoryboards = GeneratedStoryboardStore.load(clientEntryIDs: [sourceClientEntryID])
        .filter { !$0.isSampleContent }

    if isSignedIn {
        do {
            let cloudStoryboards = try await SupabaseStoryboardService().loadStoryboardImages(for: [sourceClientEntryID])
            sourceStoryboards = mergedStoryboardsByID(sourceStoryboards + cloudStoryboards)
        } catch {
            print("[Journaltopia] Could not load cloud storyboards for duplicate: \(error.localizedDescription)")
        }
    }

    guard !sourceStoryboards.isEmpty else {
        return []
    }

    let primarySourceID = sourceStoryboards.first(where: \.isPrimary)?.id ?? sourceStoryboards.first?.id
    let orderedSources = sourceStoryboards.sorted { lhs, rhs in
        if lhs.id == primarySourceID {
            return false
        }
        if rhs.id == primarySourceID {
            return true
        }
        return lhs.createdAt < rhs.createdAt
    }

    let storyboardService = SupabaseStoryboardService()
    var persistedStoryboards = GeneratedStoryboardStore.load()
    var duplicatedStoryboards: [GeneratedStoryboard] = []

    for source in orderedSources {
        let duplicateStoryboardID = UUID()
        let isPrimary = source.id == primarySourceID

        do {
            var duplicate = try GeneratedStoryboardStore.persistedStoryboard(
                image: source.image,
                clientEntryID: duplicateClientEntryID,
                promptText: source.promptText,
                artStyle: source.artStyle,
                generationQuality: source.generationQuality,
                panelLayout: source.panelLayout,
                sourcePhotoCount: source.sourcePhotoCount,
                createdAt: Date(),
                id: duplicateStoryboardID,
                storagePath: nil,
                cloudSyncState: isSignedIn ? StoryboardCloudSyncState.pending.rawValue : source.cloudSyncState,
                isPrimary: isPrimary
            )

            if isSignedIn {
                let row = try await storyboardService.persistStoryboard(duplicate)
                duplicate = try GeneratedStoryboardStore.persistedStoryboard(
                    image: source.image,
                    clientEntryID: duplicateClientEntryID,
                    promptText: source.promptText,
                    artStyle: source.artStyle,
                    generationQuality: source.generationQuality,
                    panelLayout: source.panelLayout,
                    sourcePhotoCount: source.sourcePhotoCount,
                    createdAt: row.createdAt,
                    id: duplicateStoryboardID,
                    storagePath: row.storagePath,
                    cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                    isPrimary: row.isPrimary
                )
            }

            persistedStoryboards = GeneratedStoryboardStore.merging(duplicate, into: persistedStoryboards)
            duplicatedStoryboards.append(duplicate)
        } catch {
            print("[Journaltopia] Could not duplicate storyboard \(source.id): \(error.localizedDescription)")
        }
    }

    if !duplicatedStoryboards.isEmpty {
        GeneratedStoryboardStore.save(persistedStoryboards)
    }

    return duplicatedStoryboards
}

private func mergedStoryboardsByID(_ storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
    var mergedByID: [UUID: GeneratedStoryboard] = [:]
    var orderedIDs: [UUID] = []

    for storyboard in storyboards {
        if mergedByID[storyboard.id] == nil {
            orderedIDs.append(storyboard.id)
        }
        mergedByID[storyboard.id] = storyboard
    }

    return orderedIDs.compactMap { mergedByID[$0] }
}

struct JournalView: View {
    @Binding var selectedPage: StoryPage
    @Binding var isDraftSaved: Bool
    @Binding var activeDraftID: UUID?
    @Binding var journalCreatePresentation: CreateEntryPresentation?
    @Binding var completedEntryOpenedStoryboardImage: UIImage?
    @Binding var isOpeningEntryFromEntries: Bool
    @Binding var isOpeningCompletedEntryFromEntries: Bool
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    @Binding var storyboardGenerationStatus: StoryboardGenerationGlobalStatus?
    var contentMode: JournaltopiaContentMode = .user
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsPrototypeData = false
    @State private var chapters: [PrototypeChapter]
    @State private var editMode: EditMode = .inactive
    @State private var journalBeingRenamed: PrototypeChapter?
    @State private var renamedJournalTitle = ""
    @State private var journalsPendingDeletion: [PrototypeChapter] = []
    @State private var journalBeingCustomized: PrototypeChapter?
    @State private var isShowingJournalBackgroundPicker = false
    @State private var journalPageBackground = JournalPageBackgroundStore.load()
    @State private var pendingCoverSync: PendingJournalCoverSync?
    @State private var isCoverSyncInProgress = false
    @State private var journalEntryText = ""
    @State private var journalDraftStoryTitle = ""
    @State private var journalDraftStoryboardPhotos: [CreateEntryReferencePhoto?] = Array(repeating: nil, count: 5)
    @State private var isCreateJournalAlertPresented = false
    @State private var newJournalTitle = ""
    @State private var openingJournal: JournalOpeningContext?
    @State private var isJournalOpening = false
    @State private var journalNavigationPath: [JournalRoute] = []
    @State private var sampleJournalLoadTask: Task<Void, Never>?
    /// Whether the sample pack is still on its way. Without it an empty `chapters` reads as "this
    /// library has no journals", which is how "No journals yet" ended up on screen for the whole
    /// length of the load.
    @State private var isLoadingSampleJournals = false
    @State private var sampleJournalEntryIDs: Set<UUID> = []
    /// Whether the IDs in `sampleJournalEntryIDs` were written to `CreateEntryDraftStore`, which only
    /// sample authoring does. The cleanup has to know which of the two places to clear, and it runs
    /// *after* the mode has already changed — so it cannot ask the new mode where the old one put
    /// them.
    @State private var seededSampleDraftsToDisk = false
    @State private var sampleJournalsByID: [UUID: SampleJournal] = [:]
    @State private var areJournalPagesExpanded = false
    @State private var isJournalDetailVisible = false
    @State private var draggingJournalID: UUID?
    @Namespace private var journalOpenNamespace
    @AppStorage("JournaltopiaSelectedJournalLayout") private var selectedJournalLayoutRawValue = JournalDisplayLayout.grid3x3.rawValue

    private var selectedJournalLayout: JournalDisplayLayout {
        get {
            JournalDisplayLayout(rawValue: selectedJournalLayoutRawValue) ?? .grid3x3
        }
        nonmutating set {
            selectedJournalLayoutRawValue = newValue.rawValue
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14),
            count: selectedJournalLayout.gridColumnCount
        )
    }

    init(
        selectedPage: Binding<StoryPage>,
        isDraftSaved: Binding<Bool>,
        activeDraftID: Binding<UUID?>,
        journalCreatePresentation: Binding<CreateEntryPresentation?> = .constant(nil),
        completedEntryOpenedStoryboardImage: Binding<UIImage?> = .constant(nil),
        isOpeningEntryFromEntries: Binding<Bool> = .constant(false),
        isOpeningCompletedEntryFromEntries: Binding<Bool> = .constant(false),
        generatedStoryboards: Binding<[GeneratedStoryboard]> = .constant([]),
        storyboardGenerationStatus: Binding<StoryboardGenerationGlobalStatus?> = .constant(nil),
        contentMode: JournaltopiaContentMode = .user
    ) {
        _selectedPage = selectedPage
        _isDraftSaved = isDraftSaved
        _activeDraftID = activeDraftID
        _journalCreatePresentation = journalCreatePresentation
        _completedEntryOpenedStoryboardImage = completedEntryOpenedStoryboardImage
        _isOpeningEntryFromEntries = isOpeningEntryFromEntries
        _isOpeningCompletedEntryFromEntries = isOpeningCompletedEntryFromEntries
        _generatedStoryboards = generatedStoryboards
        _storyboardGenerationStatus = storyboardGenerationStatus
        self.contentMode = contentMode
        _chapters = State(initialValue: DailyJournalData.allChapters())
    }

    var body: some View {
        NavigationStack(path: $journalNavigationPath) {
            ZStack(alignment: .bottom) {
                journalPageBackgroundView

                journalMainContent

                BottomNavigationBar(selectedPage: $selectedPage)

                floatingAddButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 84)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(2)

                if contentMode.requiresSignIn {
                    SampleSignInCallout()
                        .padding(.bottom, JournaltopiaFloatingControlMetrics.signInCalloutBottomInset)
                        .zIndex(3)
                }

                bottomPrototypeNotice

            }
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.editMode, $editMode)
            .overlay {
                journalOpeningOverlay
            }
            .navigationDestination(for: JournalRoute.self) { route in
                switch route {
                case let .journalDetail(detailRoute):
                    dailyJournalDetail(for: detailRoute.chapter, dayOffset: detailRoute.dayOffset)
                case .createEntry:
                    journalCreateEntryPage
                case .profile:
                    ProfileView(
                        selectedPage: $selectedPage,
                        generatedStoryboards: $generatedStoryboards,
                        embedsInNavigationStack: false,
                        contentMode: contentMode
                    )
                case .credits:
                    GenerationCreditsView()
                }
            }
        }
        .onAppear {
            reloadJournalsForCurrentMode()
        }
        .onChange(of: selectedPage) { newPage in
            if newPage != .create {
                reloadJournalsForCurrentMode()
            }
        }
        .onChange(of: journalNavigationPath) { newPath in
            if !newPath.contains(.createEntry) {
                resetJournalCreateEntryState()
            }
        }
        // One trigger for every way the answer can change — signing in or out, the sample-author
        // toggle, a session finishing its check. They used to be three handlers that disagreed about
        // what a nil user ID meant.
        .onChange(of: contentMode) { _ in
            journalPageBackground = JournalPageBackgroundStore.load()
            resetJournalSessionState()
            reloadJournalsForCurrentMode(retriesCoverSync: true)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else {
                return
            }

            reloadJournalsForCurrentMode(retriesCoverSync: true)
        }
        // These journals came from the cache, so a background re-check that turns up a newer pack
        // has to be picked up rather than waiting for the next launch.
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaSampleStoryPackChanged)) { _ in
            guard usesSampleJournalContent, !isSampleAuthorMode else {
                return
            }

            loadSampleJournals()
        }
        .preferredColorScheme(.light)
        .alert("Rename Journal", isPresented: isRenameAlertPresented) {
            TextField("Journal name", text: $renamedJournalTitle)

            Button("Cancel", role: .cancel) {
                journalBeingRenamed = nil
                renamedJournalTitle = ""
            }

            Button("Save") {
                renameSelectedJournal()
            }
        }
        .alert("Create Journal", isPresented: $isCreateJournalAlertPresented) {
            TextField("Journal name", text: $newJournalTitle)

            Button("Cancel", role: .cancel) {
                newJournalTitle = ""
            }

            Button("Create") {
                createJournal()
            }
        }
        .alert(deleteJournalAlertTitle, isPresented: isDeleteJournalAlertPresented) {
            Button("Cancel", role: .cancel) {
                journalsPendingDeletion = []
            }

            Button("Delete", role: .destructive) {
                deletePendingJournals()
            }
        } message: {
            Text(deleteJournalAlertMessage)
        }
        .sheet(item: $journalBeingCustomized) { chapter in
            JournalCustomizationSheet(
                chapter: refreshedChapter(chapter),
                initialStoryboardCovers: storyboardCoverCandidates(for: refreshedChapter(chapter)),
                onSave: applyJournalCustomization
            )
        }
        .sheet(isPresented: $isShowingJournalBackgroundPicker) {
            JournalPageBackgroundSheet(
                initialBackground: journalPageBackground,
                onSave: applyJournalPageBackground
            )
        }
    }

    private var journalPageBackgroundView: some View {
        GeometryReader { proxy in
            ZStack {
                Color.homePageBackground

                if showsJournalImageBackground, let remoteCoverURL = journalPageBackground.remoteCover?.imageNSURL {
                    RemoteCoverImage(url: remoteCoverURL, placeholderColor: Color.homeCardGray)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else if showsJournalImageBackground {
                    Image(JournalPageBackground.defaultImageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("Journals")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(usesLightJournalHeader ? Color.white : Color.storyInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .shadow(color: usesLightJournalHeader ? Color.black.opacity(0.28) : Color.clear, radius: 4, y: 2)

                Spacer()

                if selectedJournalLayout == .list && canEditJournals {
                    EditButton()
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(usesLightJournalHeader ? Color.white : Color.homeAccent)
                        .shadow(color: usesLightJournalHeader ? Color.black.opacity(0.24) : Color.clear, radius: 3, y: 1)
                }

                journalLayoutSwitcher
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var journalReorderHint: some View {
        // Signed-out browsing cannot reorder someone else's sample pack, so the hint would be
        // promising a gesture that does nothing.
        if !chapters.isEmpty && canEditJournals {
            ReorderHintText(usesLightForeground: usesLightJournalHeader)
        }
    }

    private var hasJournalPageBackground: Bool {
        journalPageBackground.remoteCover != nil
    }

    private var showsJournalImageBackground: Bool {
        selectedJournalLayout != .list
    }

    private var usesLightJournalHeader: Bool {
        showsJournalImageBackground && hasJournalPageBackground
    }

    private var isSampleAuthorMode: Bool {
        contentMode.isSampleAuthoring
    }

    private var usesSampleJournalContent: Bool {
        contentMode.showsSampleContent
    }

    /// Whether journals on this screen belong to whoever is looking at them. Signed-out browsing is
    /// reading someone else's demo pack, so nothing here is theirs to rearrange.
    private var canEditJournals: Bool {
        contentMode.canPersistUserContent || contentMode.isSampleAuthoring
    }

    private var journalSelectButton: some View {
        Button {
            guard !usesSampleJournalContent else {
                return
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                editMode = editMode == .active ? .inactive : .active
            }
        } label: {
            Text(editMode == .active ? "Done" : "Edit")
        }
        .buttonStyle(.plain)
        .disabled(usesSampleJournalContent)
        .accessibilityLabel(editMode == .active ? "Done selecting journals" : "Edit journals")
    }

    private var journalBackgroundButton: some View {
        Button {
            // The chosen background is stored per account, so signed out it would be written into
            // the anonymous scope and lost at the next sign-in.
            guard signInGate.requireAccount(for: .customizeJournalCover, retry: { isShowingJournalBackgroundPicker = true }) else {
                return
            }

            isShowingJournalBackgroundPicker = true
        } label: {
            Image(systemName: hasJournalPageBackground ? "photo.fill.on.rectangle.fill" : "photo.on.rectangle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(hasJournalPageBackground ? Color.storyInk : Color.homeMutedText)
                .frame(width: 34, height: 34)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.homeBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasJournalPageBackground ? "Change journals background" : "Set journals background")
    }

    private var journalLayoutSwitcher: some View {
        HStack(spacing: 4) {
            journalLayoutButton(.grid2x2)
            journalLayoutButton(.grid3x3)
            journalLayoutButton(.list)
        }
        .padding(4)
        .frame(height: 32)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private func journalLayoutButton(_ layout: JournalDisplayLayout) -> some View {
        let isSelected = selectedJournalLayout == layout

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedJournalLayout = layout
            }
        } label: {
            Image(systemName: layout.systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.homeMutedText)
                .frame(width: 32, height: 24)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.storyInk)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var journalCreateButton: some View {
        Button {
            handleCreateButtonTapped()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create a new journal")
    }

    private var floatingAddButton: some View {
        Button {
            playJournalFloatingButtonHaptic()
            handleCreateButtonTapped()
        } label: {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color.white)
                .frame(width: 60, height: 60)
                .background(Color.storyPurple, in: Circle())
                .shadow(color: Color.storyInk.opacity(0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
    }

    @ViewBuilder
    private var journalMainContent: some View {
        if selectedJournalLayout == .list {
            journalListContent
        } else {
            journalScrollableContent
        }
    }

    private var journalScrollableContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                journalPageChrome

                journalPageContent
            }
            .padding(.bottom, (showsPrototypeData ? 140 : 118) + signInCalloutContentInset)
        }
        .background(Color.clear)
    }

    private var journalListContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            journalPageChrome

            List {
                Section {
                    if chapters.isEmpty && isLoadingSampleJournals {
                        ForEach(0..<5, id: \.self) { _ in
                            EntryListLoadingRow()
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                                .listRowBackground(Color.homePageBackground)
                                .listRowSeparatorTint(Color.storyInk.opacity(0.10))
                        }
                    } else if chapters.isEmpty {
                        noSearchResults
                            .listRowBackground(Color.homePageBackground)
                    } else {
                        journalRows
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: (showsPrototypeData ? 140 : 118) + signInCalloutContentInset)
            }
        }
    }

    /// Extra room under the content for the floating sign-in callout, which nothing else in the
    /// layout reserves space for.
    private var signInCalloutContentInset: CGFloat {
        contentMode.requiresSignIn ? JournaltopiaFloatingControlMetrics.signInCalloutContentInset : 0
    }

    private var journalPageChrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 16)

            journalReorderHint
                .padding(.horizontal, 16)

            if isCoverSyncInProgress || pendingCoverSync != nil {
                JournalCoverSyncNotice(
                    isInProgress: isCoverSyncInProgress,
                    message: pendingCoverSync?.message,
                    onRetry: retryPendingCoverSync
                )
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var journalPageContent: some View {
        journalGridContent
    }

    private var journalGridContent: some View {
        Group {
            if chapters.isEmpty && isLoadingSampleJournals {
                journalGridLoadingPlaceholders
            } else if chapters.isEmpty {
                emptyState
            } else {
                journalGrid
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, selectedJournalLayout == .grid2x2 ? 8 : 4)
    }

    private var journalGridLoadingPlaceholders: some View {
        LazyVGrid(columns: columns, spacing: selectedJournalLayout == .grid2x2 ? 18 : 14) {
            ForEach(0..<6, id: \.self) { index in
                JournalCoverLoadingCard(
                    seed: index,
                    usesWideGridStyle: selectedJournalLayout == .grid2x2
                )
            }
        }
    }

    private var journalGrid: some View {
        LazyVGrid(columns: columns, spacing: selectedJournalLayout == .grid2x2 ? 18 : 14) {
            ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                JournalCoverCard(
                    chapter: chapter,
                    coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter) : nil,
                    remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
                    fallbackImageName: fallbackCoverImageName(for: chapter, at: index),
                    isEditing: editMode == .active,
                    hidesBorder: true,
                    usesWideGridStyle: selectedJournalLayout == .grid2x2,
                    isSample: contentMode.requiresSignIn,
                    onCustomize: { beginCustomizing(chapter) },
                    onRename: { beginRenaming(chapter) },
                    onDelete: { requestDeleteJournals([chapter]) }
                )
                .matchedGeometryEffect(
                    id: journalCoverAnimationID(for: chapter),
                    in: journalOpenNamespace,
                    isSource: openingJournal?.id != chapter.id
                )
                .opacity(openingJournal?.id == chapter.id ? 0 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    openJournal(chapter, dayOffset: index)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    openJournal(chapter, dayOffset: index)
                }
                .modifier(JournalDragModifier(
                    chapter: chapter,
                    isEnabled: canEditJournals,
                    draggingJournalID: $draggingJournalID
                ))
                .onDrop(
                    of: [UTType.text],
                    delegate: JournalGridDropDelegate(
                        chapter: chapter,
                        chapters: $chapters,
                        draggingJournalID: $draggingJournalID,
                        isEnabled: canEditJournals,
                        onReorder: persistManualJournalOrder
                    )
                )
                .allowsHitTesting(openingJournal == nil && journalNavigationPath.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var journalOpeningOverlay: some View {
        if openingJournal != nil {
            GeometryReader { proxy in
                ZStack {
                    Color.homePageBackground
                        .opacity(isJournalOpening ? 1 : 0)
                        .ignoresSafeArea()

                    if let openingJournal {
                        let bookWidth = areJournalPagesExpanded ? proxy.size.width + 2 : min(proxy.size.width - 72, 290)
                        let bookHeight = areJournalPagesExpanded
                            ? proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom + 2
                            : bookWidth / JournalOpeningBook.compactAspectRatio

                        JournalOpeningBook(
                            chapter: openingJournal.chapter,
                            coverImage: openingJournal.coverImage,
                            remoteCoverURL: openingJournal.remoteCoverURL,
                            fallbackImageName: openingJournal.fallbackImageName,
                            isOpen: isJournalOpening,
                            pagesExpanded: areJournalPagesExpanded
                        )
                        .frame(
                            width: bookWidth,
                            height: bookHeight
                        )
                        .matchedGeometryEffect(
                            id: journalCoverAnimationID(for: openingJournal.chapter),
                            in: journalOpenNamespace,
                            isSource: false
                        )
                        .position(
                            x: proxy.size.width / 2 - journalPageCenterCorrection(for: bookWidth),
                            y: proxy.size.height / 2
                        )
                        .scaleEffect(isJournalOpening ? 1 : 0.96)
                        .shadow(color: Color.storyInk.opacity(areJournalPagesExpanded ? 0 : 0.24), radius: 18, y: 10)
                    }
                }
                .allowsHitTesting(true)
            }
            .transition(.opacity)
            .zIndex(10)
        }
    }

    private var journalRows: some View {
        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
            journalListRow(for: chapter, at: index)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 12))
            .listRowBackground(Color.homePageBackground)
            .listRowSeparatorTint(Color.storyInk.opacity(0.10))
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if canEditJournals {
                    Button {
                        beginRenaming(chapter)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color.homeAccent)
                }
            }
        }
        .onDelete(perform: deleteChapters)
        .onMove(perform: moveChapters)
        .deleteDisabled(!canEditJournals)
        .moveDisabled(!canEditJournals)
    }

    @ViewBuilder
    private func journalListRow(for chapter: PrototypeChapter, at index: Int) -> some View {
        let row = JournalChapterListRow(
            chapter: chapter,
            coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter) : nil,
            remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
            fallbackImageName: journalFallbackCoverImageName(for: chapter, at: index),
            isEditing: false,
            isSample: contentMode.requiresSignIn
        )

        NavigationLink {
            dailyJournalDetail(for: chapter, dayOffset: index)
        } label: {
            row
        }
    }

    @ViewBuilder
    private var bottomPrototypeNotice: some View {
        if false {
            prototypeNotice
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 82)
        }
    }

    private var prototypeNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.homeAccent)

            Text("Previewing sample journal entries")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)

            Spacer()

            Button("Show empty") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsPrototypeData = false
                }
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.homeAccent)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var isRenameAlertPresented: Binding<Bool> {
        Binding(
            get: { journalBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    journalBeingRenamed = nil
                    renamedJournalTitle = ""
                }
            }
        )
    }

    private func beginRenaming(_ chapter: PrototypeChapter) {
        guard signInGate.requireAccount(for: .editJournal) else {
            return
        }

        journalBeingRenamed = chapter
        renamedJournalTitle = chapter.title
    }

    private func beginCustomizing(_ chapter: PrototypeChapter) {
        guard signInGate.requireAccount(for: .customizeJournalCover) else {
            return
        }

        journalBeingCustomized = refreshedChapter(chapter)
    }

    private func refreshedChapter(_ chapter: PrototypeChapter) -> PrototypeChapter {
        chapters.first { $0.id == chapter.id } ?? chapter
    }

    private func storyboardCoverCandidates(for chapter: PrototypeChapter) -> [JournalStoryboardCoverCandidate] {
        let entryIDs = Set(chapter.entries.map(\.id))
        guard !entryIDs.isEmpty else {
            return []
        }

        var seen = Set<UUID>()
        return GeneratedStoryboardStore.load()
            .filter { storyboard in
                guard
                    let clientEntryID = storyboard.clientEntryID,
                    entryIDs.contains(clientEntryID)
                else {
                    return false
                }

                return storyboard.isPrimary && seen.insert(storyboard.id).inserted
            }
            .sorted { $0.createdAt > $1.createdAt }
            .map(JournalStoryboardCoverCandidate.init(storyboard:))
    }

    private func applyJournalCustomization(_ customization: JournalCustomization) {
        guard let index = chapters.firstIndex(where: { $0.id == customization.chapterID }) else {
            journalBeingCustomized = nil
            return
        }

        if let storedCoverImage = customization.storedCoverImage {
            JournalCoverStore.save(storedCoverImage, for: chapters[index])
        } else if customization.clearsStoredCover {
            JournalCoverStore.delete(for: chapters[index])
        }

        let updatedChapter = PrototypeChapter(
            id: chapters[index].id,
            title: chapters[index].title,
            subtitle: chapters[index].subtitle,
            color: customization.color,
            symbol: chapters[index].symbol,
            coverImageName: customization.coverImageName,
            remoteCover: customization.remoteCover,
            kind: chapters[index].kind,
            isFavorite: chapters[index].isFavorite,
            createdAt: chapters[index].createdAt,
            updatedAt: Date(),
            entries: chapters[index].entries
        )

        chapters[index] = updatedChapter
        if isSampleAuthorMode {
            updateSampleJournal(
                updatedChapter,
                storedCoverImage: customization.storedCoverImage,
                clearsStoredCover: customization.clearsStoredCover
            )
            journalBeingCustomized = nil
            return
        }

        UserChapterStore.updateAppearance(
            id: updatedChapter.id,
            color: updatedChapter.color,
            coverImageName: updatedChapter.coverImageName,
            remoteCover: updatedChapter.remoteCover
        )
        syncJournalCoverToCloud(PendingJournalCoverSync(
            chapter: updatedChapter,
            uploadsStoredCover: customization.storedCoverImage != nil,
            clearsStoredCover: customization.clearsStoredCover
        ))
    }

    private func applyJournalPageBackground(_ customization: JournalPageBackgroundCustomization) {
        journalPageBackground = JournalPageBackground(remoteCover: customization.remoteCover)
        JournalPageBackgroundStore.save(journalPageBackground)
    }

    private func retryPendingCoverSync() {
        guard let pendingCoverSync else {
            return
        }

        syncJournalCoverToCloud(pendingCoverSync)
    }

    private func restorePendingCoverSyncIfNeeded() {
        guard pendingCoverSync == nil else {
            return
        }

        pendingCoverSync = PendingJournalCoverSyncStore.pendingSyncs(for: chapters).first
    }

    private func syncJournalCoverToCloud(_ pendingSync: PendingJournalCoverSync) {
        pendingCoverSync = nil
        isCoverSyncInProgress = true
        PendingJournalCoverSyncStore.save(pendingSync)

        Task {
            do {
                try await UserChapterStore.syncCoverCustomizationToCloud(
                    pendingSync.chapter,
                    storedCoverImage: pendingSync.storedCoverImage,
                    requiresStoredCoverUpload: pendingSync.uploadsStoredCover,
                    clearsStoredCover: pendingSync.clearsStoredCover
                )

                await MainActor.run {
                    PendingJournalCoverSyncStore.delete(id: pendingSync.id)
                    pendingCoverSync = nil
                    isCoverSyncInProgress = false
                }
            } catch {
                await MainActor.run {
                    pendingCoverSync = pendingSync
                    isCoverSyncInProgress = false
                }
            }
        }
    }

    private func renameSelectedJournal() {
        guard
            let selectedJournal = journalBeingRenamed,
            let index = chapters.firstIndex(where: { $0.id == selectedJournal.id })
        else {
            return
        }

        let trimmedTitle = renamedJournalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        let oldTitle = chapters[index].title
        chapters[index] = chapters[index].copy(title: trimmedTitle)
        if isSampleAuthorMode {
            updateSampleJournal(chapters[index])
            journalBeingRenamed = nil
            renamedJournalTitle = ""
            return
        }

        UserChapterStore.rename(title: oldTitle, to: trimmedTitle)
        UserChapterStore.syncToCloud(chapters[index])
        StoryEntryStore.renameChapter(from: oldTitle, to: trimmedTitle)
        JournalCoverStore.rename(from: oldTitle, to: trimmedTitle)
        journalBeingRenamed = nil
        renamedJournalTitle = ""
    }

    private func handleCreateButtonTapped() {
        // The alert is the write. Turning it away here rather than inside `createJournal()` is what
        // keeps a signed-out visitor from typing a name into a dialog that was never going to keep
        // it — and, before the gate existed, from having it written into `UserChapterStore` under
        // the anonymous scope for the next account to inherit.
        guard signInGate.requireAccount(for: .createJournal, retry: { isCreateJournalAlertPresented = true }) else {
            return
        }

        isCreateJournalAlertPresented = true
    }

    private func createJournal() {
        let trimmedTitle = newJournalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        if isSampleAuthorMode {
            let title = trimmedTitle
            newJournalTitle = ""
            Task {
                do {
                    try await SupabaseSampleStoryService().createSampleJournal(title: title)
                    await MainActor.run {
                        loadSampleJournals()
                    }
                } catch {
                    await MainActor.run {
                        newJournalTitle = title
                    }
                }
            }
            return
        }

        let journal = PrototypeChapter(
            title: trimmedTitle,
            subtitle: "Personal journal",
            color: Color.storyPurple,
            symbol: "book.closed.fill",
            coverImageName: nil,
            kind: .journal,
            isFavorite: false,
            entries: []
        )

        UserChapterStore.add(journal)
        chapters = DailyJournalData.allChapters()
        showsPrototypeData = false
        newJournalTitle = ""
    }

    private func deleteChapters(at offsets: IndexSet) {
        requestDeleteJournals(offsets.compactMap { chapters.indices.contains($0) ? chapters[$0] : nil })
    }

    private var isDeleteJournalAlertPresented: Binding<Bool> {
        Binding(
            get: { !journalsPendingDeletion.isEmpty },
            set: { isPresented in
                if !isPresented {
                    journalsPendingDeletion = []
                }
            }
        )
    }

    private var deleteJournalAlertTitle: String {
        journalsPendingDeletion.count == 1 ? "Delete Journal?" : "Delete Journals?"
    }

    private var deleteJournalAlertMessage: String {
        if let journal = journalsPendingDeletion.first, journalsPendingDeletion.count == 1 {
            return "Are you sure you want to delete \"\(journal.title)\"? This can't be undone. Entries won't be deleted — they'll stay in your library, and any that aren't in another journal will appear under Not in Journal."
        }

        return "Are you sure you want to delete these journals? This can't be undone. Entries won't be deleted — they'll stay in your library, and any that aren't in another journal will appear under Not in Journal."
    }

    private func requestDeleteJournals(_ journals: [PrototypeChapter]) {
        guard signInGate.requireAccount(for: .deleteJournal) else {
            return
        }

        journalsPendingDeletion = journals
    }

    private func deletePendingJournals() {
        let journalsToDelete = journalsPendingDeletion
        journalsPendingDeletion = []
        journalsToDelete.forEach(deleteJournal)
    }

    private func deleteJournal(_ journal: PrototypeChapter) {
        if isSampleAuthorMode {
            chapters.removeAll { $0.id == journal.id }
            sampleJournalsByID[journal.id] = nil
            Task {
                try? await SupabaseSampleStoryService().deleteSampleJournal(id: journal.id)
            }
            return
        }

        let isUserJournal = UserChapterStore.contains(title: journal.title)
        UserChapterStore.delete(title: journal.title)
        UserChapterStore.deleteFromCloud(journal)
        JournalCoverStore.delete(for: journal)
        if !isUserJournal {
            DeletedSampleChapterStore.add(title: journal.title)
        }
        StoryEntryStore.deleteAll(for: journal.title)

        chapters.removeAll { $0.id == journal.id }
        persistManualJournalOrder()
    }

    private func moveChapters(from source: IndexSet, to destination: Int) {
        guard canEditJournals else {
            return
        }

        chapters.move(fromOffsets: source, toOffset: destination)
        persistManualJournalOrder()
    }

    private func persistManualJournalOrder() {
        // Last line of defence for the journal order: every affordance that reaches here is already
        // disabled without an account, and none of them may write `UserChapterStore` anyway.
        guard canEditJournals else {
            return
        }

        if isSampleAuthorMode {
            let orderedIDs = chapters.map(\.id)
            Task {
                try? await SupabaseSampleStoryService().updateSampleJournalOrder(orderedIDs)
            }
            return
        }

        let userChapters = chapters.filter { UserChapterStore.contains(title: $0.title) }
        UserChapterStore.replace(with: userChapters)
        UserChapterStore.syncOrderToCloud(userChapters)
    }

    private func openJournal(_ chapter: PrototypeChapter, dayOffset: Int) {
        guard openingJournal == nil, journalNavigationPath.isEmpty else {
            return
        }

        let context = JournalOpeningContext(
            chapter: chapter,
            dayOffset: dayOffset,
            coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter) : nil,
            remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
            fallbackImageName: fallbackCoverImageName(for: chapter, at: dayOffset)
        )

        openingJournal = context
        isJournalOpening = false
        areJournalPagesExpanded = false
        isJournalDetailVisible = false

        withAnimation(.spring(response: 1.16, dampingFraction: 0.88)) {
            isJournalOpening = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.02) {
            guard openingJournal?.id == context.id else {
                return
            }

            withAnimation(.easeInOut(duration: 0.46)) {
                areJournalPagesExpanded = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                guard openingJournal?.id == context.id else {
                    return
                }

                var transaction = Transaction()
                transaction.disablesAnimations = true

                withTransaction(transaction) {
                    journalNavigationPath = [.journalDetail(JournalDetailRoute(chapter: chapter, dayOffset: dayOffset))]
                    openingJournal = nil
                    isJournalOpening = false
                    areJournalPagesExpanded = false
                    isJournalDetailVisible = false
                }
            }
        }
    }

    private func dismissOpenedJournal() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            journalNavigationPath = []
            openingJournal = nil
            isJournalOpening = false
            areJournalPagesExpanded = false
            isJournalDetailVisible = false
        }
    }

    private func journalPageCenterCorrection(for bookWidth: CGFloat) -> CGFloat {
        guard isJournalOpening, !areJournalPagesExpanded else {
            return 0
        }

        let openPageOffset: CGFloat = 42
        let openPageScale: CGFloat = 0.94
        return openPageOffset + (bookWidth * openPageScale / 2) - (bookWidth / 2)
    }

    private func journalCoverAnimationID(for chapter: PrototypeChapter) -> String {
        "journal-cover-\(chapter.id.uuidString)"
    }

    private func dailyJournalDetail(for chapter: PrototypeChapter, dayOffset: Int) -> some View {
        DailyJournalData.detailView(
            for: chapter,
            dayOffset: dayOffset,
            storyboardGenerationStatus: $storyboardGenerationStatus,
            onCreateEntryRequested: openFreshEntryFromJournalDetail,
            onChapterUpdated: updateChapterFromDetail,
            onOpenExistingEntry: openExistingEntryFromJournalDetail,
            contentMode: contentMode
        ) { entry in
            guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapter.id }) else {
                return
            }

            if let existingIndex = chapters[chapterIndex].entries.firstIndex(where: { $0.id == entry.id }) {
                chapters[chapterIndex].entries[existingIndex] = entry
            } else {
                chapters[chapterIndex].entries.insert(entry, at: 0)
            }
        }
    }

    private func openExistingEntryFromJournalDetail(
        _ entry: CreateEntryDraft,
        isCompleted: Bool,
        storyboardImage: UIImage?,
        presentation: CreateEntryPresentation
    ) {
        isOpeningEntryFromEntries = true
        isOpeningCompletedEntryFromEntries = isCompleted
        completedEntryOpenedStoryboardImage = storyboardImage
        generatedStoryboards = loadedStoryboardsForEntryOpening()
        activeDraftID = entry.id
        journalCreatePresentation = presentation
        pushJournalCreateEntryRoute()
    }

    private func openFreshEntryFromJournalDetail(_ presentation: CreateEntryPresentation) {
        activeDraftID = nil
        journalCreatePresentation = presentation
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
        completedEntryOpenedStoryboardImage = nil
        generatedStoryboards = loadedStoryboardsForEntryOpening()
        journalEntryText = ""
        journalDraftStoryTitle = ""
        journalDraftStoryboardPhotos = Array(repeating: nil, count: 5)
        pushJournalCreateEntryRoute()
    }

    /// Signed-out browsing must not read the on-disk storyboard store at all. It resolves to the
    /// `anonymous` scope, which is where a previous account's cache would land if a sign-out purge
    /// had ever failed partway — and the samples are in memory anyway.
    private func loadedStoryboardsForEntryOpening() -> [GeneratedStoryboard] {
        usesSampleJournalContent && !isSampleAuthorMode
            ? SampleContentStore.allStoryboards
            : GeneratedStoryboardStore.load()
    }

    private var journalCreateEntryPage: some View {
        CreateEntryView(
            presentation: journalCreatePresentation ?? .compose,
            entryText: $journalEntryText,
            storyTitle: $journalDraftStoryTitle,
            storyboardPhotos: $journalDraftStoryboardPhotos,
            isDraftSaved: $isDraftSaved,
            activeDraftID: $activeDraftID,
            selectedPage: $selectedPage,
            generatedStoryboards: $generatedStoryboards,
            completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
            isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
            storyboardGenerationStatus: $storyboardGenerationStatus,
            contentMode: contentMode,
            existingEntryStartsReadOnly: isOpeningEntryFromEntries,
            dismissCreate: {
                popJournalCreateEntryRoute()
            },
            onJournalEntryCreated: { journalTitle, entry in
                updateJournalEntry(entry, in: journalTitle)
            }
        )
    }

    private func pushJournalCreateEntryRoute() {
        journalNavigationPath.removeAll { route in
            if case .createEntry = route {
                return true
            }

            return false
        }
        journalNavigationPath.append(.createEntry)
    }

    private func popJournalCreateEntryRoute() {
        if journalNavigationPath.last == .createEntry {
            journalNavigationPath.removeLast()
        } else {
            journalNavigationPath.removeAll { route in
                if case .createEntry = route {
                    return true
                }

                return false
            }
        }

        resetJournalCreateEntryState()
        if isSampleAuthorMode {
            loadSampleJournals()
        }
    }

    private func resetJournalCreateEntryState() {
        journalCreatePresentation = nil
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
        completedEntryOpenedStoryboardImage = nil
    }

    private func resetJournalSessionState() {
        sampleJournalLoadTask?.cancel()
        sampleJournalLoadTask = nil
        isLoadingSampleJournals = false
        removeSampleJournalDrafts()
        sampleJournalsByID = [:]
        chapters = []
        showsPrototypeData = false
        editMode = .inactive
        journalBeingRenamed = nil
        renamedJournalTitle = ""
        journalsPendingDeletion = []
        journalBeingCustomized = nil
        pendingCoverSync = nil
        isCoverSyncInProgress = false
        isCreateJournalAlertPresented = false
        newJournalTitle = ""
        journalNavigationPath = []
        openingJournal = nil
        isJournalOpening = false
        areJournalPagesExpanded = false
        isJournalDetailVisible = false
        resetJournalCreateEntryState()
    }

    private func updateJournalEntry(_ entry: PrototypeEntry, in journalTitle: String) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.title == journalTitle }) else {
            return
        }

        if let entryIndex = chapters[chapterIndex].entries.firstIndex(where: { $0.id == entry.id }) {
            chapters[chapterIndex].entries[entryIndex] = entry
        } else {
            chapters[chapterIndex].entries.insert(entry, at: 0)
        }
    }

    private func updateChapterFromDetail(_ updatedChapter: PrototypeChapter) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == updatedChapter.id }) else {
            return
        }

        chapters[chapterIndex] = updatedChapter
    }

    private func fallbackCoverImageName(for chapter: PrototypeChapter, at index: Int) -> String? {
        journalFallbackCoverImageName(for: chapter, at: index)
    }

    /// The one place that decides which library this screen is showing.
    ///
    /// `.loading` deliberately does nothing: the previous mode's journals stay on screen until the
    /// session check settles, rather than the screen blanking and then filling twice.
    private func reloadJournalsForCurrentMode(retriesCoverSync: Bool = false) {
        guard contentMode.isResolved else {
            return
        }

        if usesSampleJournalContent {
            loadSampleJournals()
            return
        }

        chapters = DailyJournalData.allChapters()
        loadCloudJournalsIfNeeded()
        restorePendingCoverSyncIfNeeded()

        if retriesCoverSync {
            retryPendingCoverSync()
        }
    }

    private func loadSampleJournals() {
        // Applied before anything is awaited, for the same reason Entries does it: this screen is
        // rebuilt on every navigation, and without it a return to Journals renders "No journals yet"
        // over a pack that is already in memory.
        if !isSampleAuthorMode, let seededPack = SampleContentStore.pack {
            applySampleJournalPack(seededPack)
        }

        isLoadingSampleJournals = chapters.isEmpty

        sampleJournalLoadTask?.cancel()
        sampleJournalLoadTask = Task {
            let service = SupabaseSampleStoryService()
            let pack = isSampleAuthorMode
                ? try? await service.loadAuthoringPack()
                : try? await service.loadActivePack()

            guard let pack else {
                // A cancelled load is a superseded one, not a failed one. Clearing here would wipe
                // the journals its replacement is in the middle of putting on screen.
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    isLoadingSampleJournals = false
                    chapters = []
                    showsPrototypeData = true
                    editMode = .inactive
                }
                return
            }

            // Still ahead of the apply: the grid reads its covers straight from `JournalCoverStore`
            // during a body pass rather than observing it, so a pack applied first would draw with
            // whatever covers happened to be on disk and not redraw when the real ones landed. On a
            // warm cache this loop is disk reads, and the seed above means the screen is not blank
            // while it runs.
            await reconcileSampleJournalCovers(
                pack.journals,
                service: service,
                preservesLocalCoversWithoutRemotePath: isSampleAuthorMode
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                isLoadingSampleJournals = false
                applySampleJournalPack(pack)
            }
        }
    }

    /// Signed-out browsing and sample authoring want the same journals on screen but must not share
    /// a storage path.
    ///
    /// Authoring is a signed-in admin making real edits, so it keeps the round trip through the
    /// on-disk stores it has always used — the entry editor writes drafts and storyboards there, and
    /// `sampleStoryboardsByMergingLocalFallbacks` reads them back to show artwork that has been
    /// generated but not yet uploaded.
    ///
    /// Browsing writes nothing. It hands the pack to ``SampleContentStore`` and the journal screens
    /// read it from memory. That difference is the whole fix: the on-disk stores resolve to the
    /// `anonymous` scope when signed out, and the anonymous scope is merged into whichever account
    /// signs in next, so seeding the demo pack there was seeding it into a stranger's library.
    @MainActor
    private func applySampleJournalPack(_ pack: SampleStoryPack) {
        if isSampleAuthorMode {
            seededSampleDraftsToDisk = true
            seedSampleDraftsForJournals(pack.entries)
            let storyboardsByEntryID = sampleStoryboardsByMergingLocalFallbacks(
                remoteStoryboardsByEntryID: pack.storyboardsByEntryID,
                entries: pack.entries,
                repairsMissingRemote: true
            )
            persistSampleStoryboardsForJournals(storyboardsByEntryID)
        } else {
            seededSampleDraftsToDisk = false
            SampleContentStore.replace(with: pack)
            sampleJournalEntryIDs = Set(SampleContentStore.orderedEntryIDs)
            generatedStoryboards = SampleContentStore.allStoryboards
        }

        sampleJournalsByID = Dictionary(uniqueKeysWithValues: pack.journals.map { ($0.id, $0) })
        chapters = pack.journals.map(SampleJournalDisplay.chapter(from:))
        showsPrototypeData = true
        editMode = .inactive
    }

    private func reconcileSampleJournalCovers(
        _ journals: [SampleJournal],
        service: SupabaseSampleStoryService,
        preservesLocalCoversWithoutRemotePath: Bool
    ) async {
        for journal in journals {
            guard
                journal.remoteCover == nil,
                journal.coverImageName?.trimmedOrNil == nil,
                let storagePath = journal.coverStoragePath?.trimmedOrNil
            else {
                if !preservesLocalCoversWithoutRemotePath || journal.remoteCover != nil || journal.coverImageName?.trimmedOrNil != nil {
                    await MainActor.run {
                        JournalCoverStore.delete(journalID: journal.id, legacyTitle: journal.title)
                    }
                }
                continue
            }

            do {
                let image = try await service.downloadSampleJournalCover(storagePath: storagePath)
                await MainActor.run {
                    JournalCoverStore.save(image, journalID: journal.id, legacyTitle: journal.title)
                }
            } catch {
                print("[Journaltopia] Sample journal cover load failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateSampleJournal(
        _ chapter: PrototypeChapter,
        storedCoverImage: UIImage? = nil,
        clearsStoredCover: Bool = false
    ) {
        guard let existingJournal = sampleJournalsByID[chapter.id] else {
            return
        }

        let preservesStoredCover = storedCoverImage == nil
            && !clearsStoredCover
            && chapter.remoteCover == nil
            && chapter.coverImageName?.trimmedOrNil == nil
        let coverStoragePath = preservesStoredCover ? existingJournal.coverStoragePath : nil
        let updatedJournal = SampleJournal(
            id: existingJournal.id,
            packID: existingJournal.packID,
            title: chapter.title,
            subtitle: chapter.subtitle,
            colorHex: JournalColorOption.hexString(for: chapter.color),
            symbol: chapter.symbol,
            coverImageName: chapter.coverImageName,
            coverStoragePath: coverStoragePath,
            remoteCover: chapter.remoteCover,
            kind: chapter.kind == .storyboard ? "storyboard" : "journal",
            isFavorite: chapter.isFavorite,
            displayOrder: existingJournal.displayOrder,
            entries: existingJournal.entries,
            createdAt: existingJournal.createdAt,
            updatedAt: Date()
        )

        sampleJournalsByID[chapter.id] = updatedJournal
        Task {
            let service = SupabaseSampleStoryService()
            var storedCoverPath = updatedJournal.coverStoragePath
            if let storedCoverImage {
                do {
                    storedCoverPath = try await service.uploadSampleJournalCover(storedCoverImage, journalID: chapter.id)
                } catch {
                    print("[Journaltopia] Sample journal cover upload failed: \(error.localizedDescription)")
                    return
                }
            }

            let persistedJournal = SampleJournal(
                id: updatedJournal.id,
                packID: updatedJournal.packID,
                title: updatedJournal.title,
                subtitle: updatedJournal.subtitle,
                colorHex: updatedJournal.colorHex,
                symbol: updatedJournal.symbol,
                coverImageName: updatedJournal.coverImageName,
                coverStoragePath: storedCoverPath,
                remoteCover: updatedJournal.remoteCover,
                kind: updatedJournal.kind,
                isFavorite: updatedJournal.isFavorite,
                displayOrder: updatedJournal.displayOrder,
                entries: updatedJournal.entries,
                createdAt: updatedJournal.createdAt,
                updatedAt: Date()
            )
            do {
                try await service.updateSampleJournal(persistedJournal)
                await MainActor.run {
                    sampleJournalsByID[chapter.id] = persistedJournal
                }
            } catch {
                print("[Journaltopia] Sample journal update failed: \(error.localizedDescription)")
            }
        }
    }

    private func seedSampleDraftsForJournals(_ entries: [CreateEntryDraft]) {
        sampleJournalEntryIDs = Set(entries.map(\.id))

        for entry in entries {
            _ = CreateEntryDraftStore.save(
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
            )
        }
    }

    private func removeSampleJournalDrafts() {
        // Only authoring ever put them on disk. Browsing's copies are in memory and go with the
        // store, so deleting by ID here would be reaching into whatever scope is now active.
        if seededSampleDraftsToDisk {
            for entryID in sampleJournalEntryIDs {
                CreateEntryDraftStore.delete(id: entryID)
            }
        } else {
            SampleContentStore.clear()
        }

        seededSampleDraftsToDisk = false
        sampleJournalEntryIDs = []
    }

    private func persistSampleStoryboardsForJournals(_ storyboardsByEntryID: [UUID: [GeneratedStoryboard]]) {
        let sampleEntryIDs = Set(storyboardsByEntryID.keys)
        var persistedStoryboards = GeneratedStoryboardStore.load().filter { storyboard in
            guard let clientEntryID = storyboard.clientEntryID else {
                return true
            }

            return !sampleEntryIDs.contains(clientEntryID)
        }

        for (_, storyboards) in storyboardsByEntryID {
            for (index, sampleStoryboard) in storyboards.enumerated() {
                guard
                    let clientEntryID = sampleStoryboard.clientEntryID,
                    let storyboard = try? GeneratedStoryboardStore.persistedStoryboard(
                        image: sampleStoryboard.image,
                        clientEntryID: clientEntryID,
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
        }

        GeneratedStoryboardStore.save(persistedStoryboards)
        generatedStoryboards = persistedStoryboards
    }

    private func loadCloudJournalsIfNeeded() {
        guard !isSampleAuthorMode else {
            return
        }

        guard authStore.userID != nil else {
            return
        }

        Task {
            do {
                let journalRepository = SupabaseJournalRepository()
                let entryRepository = SupabaseEntryRepository()

                // These three are independent reads, so let them overlap rather than stacking
                // three round trips end to end.
                async let cloudJournalsTask = journalRepository.getJournals()
                async let cloudEntryIDsTask = entryRepository.getEntryClientIDs()
                async let membershipsTask = journalRepository.getJournalEntryMemberships()

                let cloudJournals = try await cloudJournalsTask
                let cloudEntryIDs = try await cloudEntryIDsTask
                let memberships = try await membershipsTask

                let cloudChapters = cloudJournals
                    .filter { !LegacySystemJournalIDs.all.contains($0.id) }
                    .map(PrototypeChapter.init(cloudJournal:))
                await Self.reconcileCloudJournalCovers(
                    cloudJournals,
                    repository: journalRepository
                )
                let membershipRepairs = await MainActor.run {
                    StoryEntryStore.missingCloudMembershipRepairs(
                        journals: cloudChapters,
                        cloudEntryIDs: cloudEntryIDs,
                        existingMemberships: memberships
                    )
                }
                try await journalRepository.upsertJournalEntryMemberships(membershipRepairs)
                let repairedMemberships = membershipRepairs.isEmpty
                    ? memberships
                    : try await journalRepository.getJournalEntryMemberships()

                // Only entries that belong to a journal the page is about to render can produce a
                // stored record, so only those are worth fetching bodies for.
                let renderedJournalIDs = Set(cloudChapters.map(\.id))
                let memberEntryIDs = Set(
                    repairedMemberships
                        .filter { renderedJournalIDs.contains($0.journalID) }
                        .map(\.clientEntryID)
                )
                let memberEntries = try await entryRepository.getEntryDigests(clientEntryIDs: memberEntryIDs)

                await MainActor.run {
                    let mergedCloudChapters = Self.cloudChapters(
                        cloudChapters,
                        preservingOrderOf: chapters
                    )
                    UserChapterStore.replace(with: mergedCloudChapters)
                    StoryEntryStore.replaceCloudMemberships(
                        repairedMemberships,
                        journals: mergedCloudChapters,
                        entries: memberEntries
                    )
                    chapters = DailyJournalData.allChapters()
                }
            } catch {
                print("[Journaltopia] Cloud journals load failed: \(error.localizedDescription)")
            }
        }
    }

    private static func cloudChapters(
        _ cloudChapters: [PrototypeChapter],
        preservingOrderOf _: [PrototypeChapter]
    ) -> [PrototypeChapter] {
        cloudChapters
    }

    private static func reconcileCloudJournalCovers(
        _ cloudJournals: [StoryJournal],
        repository: SupabaseJournalRepository
    ) async {
        for cloudJournal in cloudJournals where !LegacySystemJournalIDs.all.contains(cloudJournal.id) {
            guard
                cloudJournal.remoteCover == nil,
                cloudJournal.coverImageName?.trimmedOrNil == nil,
                let coverStoragePath = cloudJournal.coverStoragePath?.trimmedOrNil
            else {
                JournalCoverStore.delete(journalID: cloudJournal.id, legacyTitle: cloudJournal.title)
                JournalCoverStore.clearCloudStoragePath(for: cloudJournal.id)
                continue
            }

            guard JournalCoverStore.needsCloudCoverDownload(
                journalID: cloudJournal.id,
                cloudStoragePath: coverStoragePath,
                cloudUpdatedAt: cloudJournal.updatedAt
            ) else {
                print("[Journaltopia] Journal cover is current locally for \(cloudJournal.id).")
                continue
            }

            do {
                print("[Journaltopia] Downloading journal cover \(cloudJournal.id) from \(coverStoragePath).")
                let coverImage = try await repository.downloadCover(storagePath: coverStoragePath)
                JournalCoverStore.save(
                    coverImage,
                    journalID: cloudJournal.id,
                    legacyTitle: cloudJournal.title,
                    cloudStoragePath: coverStoragePath,
                    cloudUpdatedAt: cloudJournal.updatedAt
                )
                print("[Journaltopia] Journal cover hydrated for \(cloudJournal.id) from \(coverStoragePath).")
            } catch {
                print("[Journaltopia] Cloud journal cover download failed: \(error.localizedDescription)")
            }
        }
    }

    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.homeAccent.opacity(0.6))

            Text("No journals yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text("Your journals will appear here.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 58)

            Image("no_entries_journal")
                .resizable()
                .scaledToFit()
                .frame(width: 165)
                .padding(.bottom, 3)

            VStack(spacing: 8) {
                Text("No journals yet")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text("Create a journal to start collecting entries and storyboards.")
                    .font(.system(size: 13, weight: .semibold))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.homeMutedText)
            }

            Button {
                isCreateJournalAlertPresented = true
            } label: {
                Label("Create Journal", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 39)
                    .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum JournalDisplayLayout: String {
    case grid2x2
    case grid3x3 = "grid"
    case list

    var gridColumnCount: Int {
        switch self {
        case .grid2x2:
            return 2
        case .grid3x3, .list:
            return 3
        }
    }

    var systemImage: String {
        switch self {
        case .grid2x2:
            return "square.grid.2x2"
        case .grid3x3:
            return "square.grid.3x3"
        case .list:
            return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid2x2:
            return "Show journals as 2 by 2 grid"
        case .grid3x3:
            return "Show journals as 3 by 3 grid"
        case .list:
            return "Show journals as list"
        }
    }
}

private func journalFallbackCoverImageName(for chapter: PrototypeChapter, at _: Int) -> String? {
    chapter.coverImageName
}

private enum JournalRoute: Hashable {
    case journalDetail(JournalDetailRoute)
    case createEntry
    case profile
    case credits
}

private struct JournalDetailRoute: Hashable, Identifiable {
    let chapter: PrototypeChapter
    let dayOffset: Int

    var id: UUID {
        chapter.id
    }

    static func == (lhs: JournalDetailRoute, rhs: JournalDetailRoute) -> Bool {
        lhs.id == rhs.id && lhs.dayOffset == rhs.dayOffset
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(dayOffset)
    }
}

private struct JournalGridDropDelegate: DropDelegate {
    let chapter: PrototypeChapter
    @Binding var chapters: [PrototypeChapter]
    @Binding var draggingJournalID: UUID?
    let isEnabled: Bool
    let onReorder: () -> Void

    func dropEntered(info _: DropInfo) {
        guard
            isEnabled,
            let draggingJournalID,
            draggingJournalID != chapter.id,
            let fromIndex = chapters.firstIndex(where: { $0.id == draggingJournalID }),
            let toIndex = chapters.firstIndex(where: { $0.id == chapter.id })
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            let movedChapter = chapters.remove(at: fromIndex)
            chapters.insert(movedChapter, at: toIndex)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        isEnabled ? DropProposal(operation: .move) : nil
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggingJournalID = nil
        if isEnabled {
            onReorder()
        }
        return isEnabled
    }
}

private struct JournalDragModifier: ViewModifier {
    let chapter: PrototypeChapter
    let isEnabled: Bool
    @Binding var draggingJournalID: UUID?

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else {
            content
                .onDrag {
                    draggingJournalID = chapter.id
                    return NSItemProvider(object: chapter.id.uuidString as NSString)
                }
        }
    }
}

private struct JournalOpeningContext: Identifiable {
    let chapter: PrototypeChapter
    let dayOffset: Int
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?

    var id: UUID {
        chapter.id
    }
}

private extension StoryJournal {
    var remoteCover: JournalRemoteCover? {
        guard
            coverSource == JournalCoverSource.unsplash.rawValue,
            let coverImageURL,
            !coverImageURL.isEmpty
        else {
            return nil
        }

        return JournalRemoteCover(
            source: .unsplash,
            imageURL: coverImageURL,
            thumbnailURL: coverThumbURL,
            attributionName: coverAttributionName,
            attributionURL: coverAttributionURL,
            downloadLocation: coverDownloadLocation
        )
    }
}

private struct JournalOpeningBook: View {
    static let compactAspectRatio: CGFloat = 0.72

    let chapter: PrototypeChapter
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    let isOpen: Bool
    let pagesExpanded: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                pages
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(x: pagesExpanded ? 0 : (isOpen ? 42 : 12))
                    .scaleEffect(x: pagesExpanded ? 1 : (isOpen ? 0.94 : 0.98), y: pagesExpanded ? 1 : (isOpen ? 0.96 : 0.99), anchor: .leading)
                    .opacity(isOpen ? 1 : 0.76)

                cover
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .overlay(alignment: .leading) {
                        spine
                    }
                    .mask(
                        RoundedRectangle(cornerRadius: pagesExpanded ? 0 : 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: pagesExpanded ? 0 : 14, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    )
                    .rotation3DEffect(
                        .degrees(pagesExpanded ? -92 : (isOpen ? -68 : 0)),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .leading,
                        perspective: 0.62
                    )
                    .offset(x: pagesExpanded ? -120 : (isOpen ? -34 : 0))
                    .opacity(pagesExpanded ? 0 : 1)
                    .shadow(color: Color.storyInk.opacity(isOpen ? 0.28 : 0.14), radius: isOpen ? 16 : 9, y: 8)
            }
        }
        .animation(.spring(response: 1.16, dampingFraction: 0.88), value: isOpen)
        .animation(.easeInOut(duration: 0.46), value: pagesExpanded)
        .accessibilityHidden(true)
    }

    private var pages: some View {
        RoundedRectangle(cornerRadius: pagesExpanded ? 0 : 14, style: .continuous)
            .fill(Color.white)
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color.storyInk.opacity(pagesExpanded ? 0.03 : 0.16),
                        Color.storyInk.opacity(pagesExpanded ? 0.015 : 0.05),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: pagesExpanded ? 18 : 54)
            }
            .overlay(alignment: .trailing) {
                VStack(spacing: 10) {
                    ForEach(0..<8, id: \.self) { _ in
                        Capsule()
                            .fill(Color.homeBorder.opacity(0.62))
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 24)
                .opacity(pagesExpanded ? 0 : 0.72)
            }
            .overlay(
                RoundedRectangle(cornerRadius: pagesExpanded ? 0 : 14, style: .continuous)
                    .stroke(Color.homeBorder.opacity(pagesExpanded ? 0 : 1), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var cover: some View {
        GeometryReader { proxy in
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else if let remoteCoverURL {
                    RemoteCoverImage(url: remoteCoverURL, placeholderColor: chapter.color)
                } else if let fallbackImageName {
                    Image(fallbackImageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    chapter.color
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var spine: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.18),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
                .frame(width: 12.5)
                .padding(.leading, 24.25)
                .blendMode(.screen)
        }
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct JournalDragHandle: View {
    var visibleSize = JournalEditControlMetrics.visibleSize

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.homeMutedText.opacity(0.88))
            .frame(width: visibleSize, height: visibleSize)
            .background(JournalEditControlMetrics.background, in: Circle())
            .shadow(
                color: JournalEditControlMetrics.shadowColor,
                radius: JournalEditControlMetrics.shadowRadius,
                y: JournalEditControlMetrics.shadowYOffset
            )
            .frame(width: JournalEditControlMetrics.touchSize, height: JournalEditControlMetrics.touchSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct JournalDeleteButton: View {
    let title: String
    var visibleSize = JournalEditControlMetrics.visibleSize
    var showsBackground = true
    var backgroundColor = JournalEditControlMetrics.background
    var backgroundShape = JournalDeleteButtonBackgroundShape.circle
    var visualAlignment: Alignment = .center
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            deleteIcon
                .frame(
                    width: JournalEditControlMetrics.touchSize,
                    height: JournalEditControlMetrics.touchSize,
                    alignment: visualAlignment
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete \(title)")
    }

    @ViewBuilder
    private var deleteIcon: some View {
        if showsBackground {
            baseIcon
                .background {
                    switch backgroundShape {
                    case .circle:
                        Circle()
                            .fill(backgroundColor)
                    case .roundedRectangle:
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(backgroundColor)
                    }
                }
                .shadow(
                    color: JournalEditControlMetrics.shadowColor,
                    radius: JournalEditControlMetrics.shadowRadius,
                    y: JournalEditControlMetrics.shadowYOffset
                )
        } else {
            baseIcon
        }
    }

    private var baseIcon: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.red)
            .frame(width: visibleSize, height: visibleSize)
    }
}

private enum JournalDeleteButtonBackgroundShape {
    case circle
    case roundedRectangle
}

private enum JournalEditControlMetrics {
    static let visibleSize: CGFloat = 36
    static let compactVisibleSize: CGFloat = 32
    static let touchSize: CGFloat = 44
    static let background = Color.white.opacity(0.94)
    static let shadowColor = Color.black.opacity(0.14)
    static let shadowRadius: CGFloat = 4
    static let shadowYOffset: CGFloat = 2
}

private struct ReorderHintText: View {
    var usesLightForeground = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .bold))

            Text("Hold and drag to re-order")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .foregroundStyle(foregroundColor)
        .shadow(color: usesLightForeground ? Color.black.opacity(0.22) : Color.clear, radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }

    private var foregroundColor: Color {
        usesLightForeground ? Color.white : Color.homeMutedText
    }
}

private struct JournalCoverCard: View {
    let chapter: PrototypeChapter
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    let isEditing: Bool
    let hidesBorder: Bool
    let usesWideGridStyle: Bool
    var isSample = false
    let onCustomize: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(JournalOpeningBook.compactAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    cover
                }
                .clipShape(Rectangle())
                .overlay(alignment: .leading) {
                    journalSpine
                }
                .overlay(alignment: .bottomLeading) {
                    journalTitleScrim
                }

            if isSample && !isEditing {
                EntrySampleBadge()
                    .padding(.top, 8)
                    .padding(.leading, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            if isEditing {
                if usesWideGridStyle {
                    JournalDragHandle(visibleSize: editControlVisibleSize)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                JournalDeleteButton(title: chapter.title, visibleSize: editControlVisibleSize, action: onDelete)
                    .padding(.top, 8)
                    .padding(.leading, 8)
                    .padding(.trailing, usesWideGridStyle ? 8 : 2)
                    .padding(.bottom, 8)
            } else if !isSample {
                Menu {
                    Button(action: onCustomize) {
                        Label("Change Cover", systemImage: "photo.on.rectangle")
                    }

                    Button(action: onRename) {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.storyInk)
                        .frame(width: 31, height: 24)
                        .background(Color.white.opacity(0.94), in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Journal options for \(chapter.title)")
            }
        }
        .background(
            usesWideGridStyle ? Color.clear : Color.white,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if !hidesBorder {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            }
        }
        .shadow(
            color: Color.storyInk.opacity(usesWideGridStyle ? 0.28 : 0.13),
            radius: usesWideGridStyle ? 20 : 10,
            y: usesWideGridStyle ? 12 : 5
        )
    }

    private var editControlVisibleSize: CGFloat {
        usesWideGridStyle ? JournalEditControlMetrics.visibleSize : JournalEditControlMetrics.compactVisibleSize
    }

    private var journalTitleScrim: some View {
        titleBackdrop
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Text("\(chapter.entries.count) \(chapter.entries.count == 1 ? "entry" : "entries")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.leading, 28)
            .padding(.trailing, 11)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var titleBackdrop: some View {
        if hasImageCover {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.50),
                    Color.black.opacity(0.74)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.clear
        }
    }

    private var hasImageCover: Bool {
        coverImage != nil || remoteCoverURL != nil || fallbackImageName != nil
    }

    @ViewBuilder
    private var cover: some View {
        GeometryReader { proxy in
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else if let remoteCoverURL {
                    RemoteCoverImage(url: remoteCoverURL, placeholderColor: chapter.color)
                } else if let fallbackImageName {
                    Image(fallbackImageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    chapter.color
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var journalSpine: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.16),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
                .frame(width: 12.5)
                .padding(.leading, 14.25)
                .blendMode(.screen)
        }
        .frame(width: 22)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct JournalCustomization {
    let chapterID: UUID
    let color: Color
    let coverImageName: String?
    let remoteCover: JournalRemoteCover?
    let storedCoverImage: UIImage?
    let clearsStoredCover: Bool
}

private struct JournalPageBackground: Codable, Equatable {
    let remoteCover: JournalRemoteCover?

    static let defaultImageName = WatercolorPaperPageBackground.assetName
    static let empty = JournalPageBackground(remoteCover: nil)
}

private struct JournalPageBackgroundCustomization {
    let remoteCover: JournalRemoteCover?
}

private enum JournalPageBackgroundStore {
    private static let storageKey = "JournaltopiaJournalPageBackground"

    static func load() -> JournalPageBackground {
        migrateLegacyValueIfNeeded()

        guard
            let data = UserDefaults.standard.data(forKey: scopedStorageKey),
            let background = try? JSONDecoder().decode(JournalPageBackground.self, from: data)
        else {
            return .empty
        }

        return background
    }

    static func save(_ background: JournalPageBackground) {
        guard let data = try? JSONEncoder().encode(background) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
    }

    private static var scopedStorageKey: String {
        JournaltopiaLocalAccountScope.scopedUserDefaultsKey(storageKey)
    }

    private static func migrateLegacyValueIfNeeded() {
        let targetKey = scopedStorageKey
        guard UserDefaults.standard.data(forKey: targetKey) == nil,
              let legacyData = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        UserDefaults.standard.set(legacyData, forKey: targetKey)
    }
}

private struct JournalPageBackgroundSheet: View {
    let initialBackground: JournalPageBackground
    let onSave: (JournalPageBackgroundCustomization) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRemoteCover: JournalRemoteCover?
    @State private var unsplashQuery = ""
    @State private var unsplashPhotos: [UnsplashCoverPhoto] = []
    @State private var unsplashResultsCache: [String: [UnsplashCoverPhoto]] = [:]
    @State private var isSearchingUnsplash = false
    @State private var unsplashErrorMessage: String?
    @FocusState private var isUnsplashSearchFocused: Bool
    private let unsplashService = UnsplashCoverService()

    init(
        initialBackground: JournalPageBackground,
        onSave: @escaping (JournalPageBackgroundCustomization) -> Void
    ) {
        self.initialBackground = initialBackground
        self.onSave = onSave
        _selectedRemoteCover = State(initialValue: initialBackground.remoteCover)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        preview
                        stockPhotoSection
                    }
                    .padding(18)
                    .padding(.bottom, isUnsplashSearchFocused ? 180 : 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .background {
                    Color.homePageBackground
                        .onTapGesture {
                            isUnsplashSearchFocused = false
                        }
                }
                .onChange(of: isUnsplashSearchFocused) { isFocused in
                    guard isFocused else {
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("journal-background-search-field", anchor: .center)
                        }
                    }
                }
            }
            .background(Color.homePageBackground)
            .navigationTitle("Journals Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCurrentSelection()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button {
                        isUnsplashSearchFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .fontWeight(.bold)
                    .accessibilityLabel("Dismiss keyboard")
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            ZStack(alignment: .topLeading) {
                GeometryReader { proxy in
                    ZStack {
                        if let remoteCoverURL = selectedRemoteCover?.thumbnailNSURL ?? selectedRemoteCover?.imageNSURL {
                            RemoteCoverImage(url: remoteCoverURL, placeholderColor: Color.homeCardGray)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        } else {
                            Image(JournalPageBackground.defaultImageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        }

                        LinearGradient(
                            colors: [
                                Color.black.opacity(selectedRemoteCover == nil ? 0 : 0.08),
                                Color.black.opacity(selectedRemoteCover == nil ? 0 : 0.16)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 178)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Journals")
                            .font(.system(size: 19, weight: .bold, design: .serif))
                            .foregroundStyle(selectedRemoteCover == nil ? Color.storyInk : Color.white)
                            .shadow(color: selectedRemoteCover == nil ? Color.clear : Color.black.opacity(0.22), radius: 3, y: 1)

                        Spacer()

                        previewControlIcon("square.grid.2x2.fill")
                        previewControlIcon("square.grid.3x3.fill")
                    }

                    HStack(spacing: 12) {
                        previewJournalCard(color: Color.storyPurple)
                        previewJournalCard(color: Color.storyInk)
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )

            HStack {
                if
                    let attributionName = selectedRemoteCover?.attributionName,
                    let attributionURL = selectedRemoteCover?.attributionURL,
                    let url = URL(string: attributionURL)
                {
                    Link("Photo by \(attributionName) on Unsplash", destination: url)
                        .foregroundStyle(Color.homeAccent)
                } else {
                    Text("Watercolor Paper")
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()

                Button("Remove") {
                    selectedRemoteCover = nil
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyRose)
                .disabled(selectedRemoteCover == nil)
            }
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private func previewControlIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.storyInk)
            .frame(width: 30, height: 26)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func previewJournalCard(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(color)
            .frame(width: 74, height: 104)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 54, height: 7)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                        .frame(width: 34, height: 5)
                }
                .padding(10)
            }
            .shadow(color: Color.storyInk.opacity(0.16), radius: 8, y: 4)
    }

    private var stockPhotoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stock Photos")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            HStack(spacing: 8) {
                TextField("Search background photos", text: $unsplashQuery)
                    .focused($isUnsplashSearchFocused)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit {
                        searchUnsplash()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.homeBorder, lineWidth: 1)
                    )

                Button {
                    searchUnsplash()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 40)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSearchingUnsplash)
                .accessibilityLabel("Search stock photos")
            }
            .frame(height: 40)
            .id("journal-background-search-field")

            if isSearchingUnsplash {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let unsplashErrorMessage {
                Text(unsplashErrorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.storyRose)
                    .fixedSize(horizontal: false, vertical: true)
            } else if unsplashPhotos.isEmpty {
                Text("Search stock photos when you're ready to browse background photos.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(unsplashPhotos) { photo in
                        Button {
                            selectUnsplashPhoto(photo)
                        } label: {
                            let isSelected = selectedRemoteCover?.imageURL == photo.imageURL

                            CoverPhotoTile(isSelected: isSelected) {
                                Group {
                                    if let thumbnailURL = URL(string: photo.thumbnailURL) {
                                        RemoteCoverImage(url: thumbnailURL, placeholderColor: Color.homeCardGray)
                                    } else {
                                        Color.homeCardGray
                                    }
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text(photo.attributionName)
                                    .font(.system(size: 9, weight: .bold))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.black.opacity(0.38))
                            }
                            .overlay(alignment: .topTrailing) {
                                if isSelected {
                                    selectedBackgroundBadge
                                        .padding(6)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use Unsplash photo by \(photo.attributionName)")
                    }
                }
                .padding(.top, 2)
            }

            Color.clear
                .frame(height: 160)
        }
    }

    private var selectedBackgroundBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.homeAccent, in: Circle())
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
            .shadow(color: Color.storyInk.opacity(0.22), radius: 4, y: 2)
    }

    private func saveCurrentSelection() {
        let remoteCover = selectedRemoteCover
        onSave(JournalPageBackgroundCustomization(remoteCover: remoteCover))
        if let downloadLocation = remoteCover?.downloadLocation {
            Task {
                try? await unsplashService.trackDownload(downloadLocation: downloadLocation)
            }
        }
    }

    private func searchUnsplash() {
        let query = unsplashQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearchingUnsplash else {
            return
        }
        isUnsplashSearchFocused = false
        let cacheKey = normalizedUnsplashQuery(query)

        if let cachedPhotos = unsplashResultsCache[cacheKey] {
            unsplashPhotos = cachedPhotos
            unsplashErrorMessage = nil
            return
        }

        isSearchingUnsplash = true
        unsplashErrorMessage = nil

        Task {
            do {
                let photos = try await unsplashService.search(query: query)
                await MainActor.run {
                    unsplashPhotos = photos
                    unsplashResultsCache[cacheKey] = photos
                    isSearchingUnsplash = false
                }
            } catch {
                await MainActor.run {
                    unsplashErrorMessage = error.localizedDescription
                    isSearchingUnsplash = false
                }
            }
        }
    }

    private func normalizedUnsplashQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func selectUnsplashPhoto(_ photo: UnsplashCoverPhoto) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedRemoteCover = JournalRemoteCover(
                source: .unsplash,
                imageURL: photo.imageURL,
                thumbnailURL: photo.thumbnailURL,
                attributionName: photo.attributionName,
                attributionURL: photo.attributionURL,
                downloadLocation: photo.downloadLocation
            )
        }
    }
}

private struct PendingJournalCoverSync: Identifiable {
    let chapter: PrototypeChapter
    let uploadsStoredCover: Bool
    let clearsStoredCover: Bool

    var id: UUID {
        chapter.id
    }

    var storedCoverImage: UIImage? {
        guard uploadsStoredCover else {
            return nil
        }

        return JournalCoverStore.image(for: chapter)
    }

    var message: String {
        "Cover saved on this device. Cloud sync failed."
    }
}

private enum PendingJournalCoverSyncStore {
    private struct Record: Codable {
        let chapterID: UUID
        let uploadsStoredCover: Bool
        let clearsStoredCover: Bool
        let updatedAt: Date
    }

    private static let storageKey = "JournaltopiaPendingJournalCoverSyncs"

    static func save(_ pendingSync: PendingJournalCoverSync) {
        var updatedRecords = records.filter { $0.chapterID != pendingSync.id }
        updatedRecords.append(Record(
            chapterID: pendingSync.id,
            uploadsStoredCover: pendingSync.uploadsStoredCover,
            clearsStoredCover: pendingSync.clearsStoredCover,
            updatedAt: Date()
        ))
        persist(updatedRecords)
    }

    static func delete(id: UUID) {
        persist(records.filter { $0.chapterID != id })
    }

    static func pendingSync(for chapter: PrototypeChapter) -> PendingJournalCoverSync? {
        guard let record = records.first(where: { $0.chapterID == chapter.id }) else {
            return nil
        }

        return PendingJournalCoverSync(
            chapter: chapter,
            uploadsStoredCover: record.uploadsStoredCover,
            clearsStoredCover: record.clearsStoredCover
        )
    }

    static func pendingSyncs(for chapters: [PrototypeChapter]) -> [PendingJournalCoverSync] {
        let chaptersByID = Dictionary(uniqueKeysWithValues: chapters.map { ($0.id, $0) })

        return records
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { record in
                guard let chapter = chaptersByID[record.chapterID] else {
                    return nil
                }

                return PendingJournalCoverSync(
                    chapter: chapter,
                    uploadsStoredCover: record.uploadsStoredCover,
                    clearsStoredCover: record.clearsStoredCover
                )
            }
    }

    private static var records: [Record] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decodedRecords = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }

        return decodedRecords
    }

    private static func persist(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private struct JournalCoverSyncNotice: View {
    let isInProgress: Bool
    let message: String?
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if isInProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.homeAccent)
            } else {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
            }

            Text(isInProgress ? "Saving cover..." : (message ?? "Cover saved on this device. Cloud sync failed."))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if !isInProgress {
                Button("Retry", action: onRetry)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }
}

private struct JournalStoryboardCoverCandidate: Identifiable {
    let id: UUID
    let clientEntryID: UUID?
    let image: UIImage
    let createdAt: Date

    init(storyboard: GeneratedStoryboard) {
        id = storyboard.id
        clientEntryID = storyboard.clientEntryID
        image = storyboard.image
        createdAt = storyboard.createdAt
    }
}

/// Single source of truth for which cover is selected in the journal cover picker.
/// Color / image / storyboard / Unsplash are mutually exclusive — never independently "selected".
private enum JournalCustomizationCoverSource: Equatable {
    case color
    case storyboard(id: UUID?)
    case image(name: String)
    case unsplash(JournalRemoteCover)

    static func resolving(
        remoteCover: JournalRemoteCover?,
        coverImageName: String?,
        storedCoverImage: UIImage?,
        storyboardCandidates: [JournalStoryboardCoverCandidate]
    ) -> Self {
        if let remoteCover {
            return .unsplash(remoteCover)
        }
        if let coverImageName, !coverImageName.isEmpty {
            return .image(name: coverImageName)
        }
        if let storedCoverImage {
            let matchedID = Self.matchingStoryboardID(for: storedCoverImage, in: storyboardCandidates)
            return .storyboard(id: matchedID)
        }
        return .color
    }

    private static func matchingStoryboardID(
        for image: UIImage,
        in candidates: [JournalStoryboardCoverCandidate]
    ) -> UUID? {
        let matches = candidates.filter { candidate in
            abs(candidate.image.size.width - image.size.width) < 0.5
                && abs(candidate.image.size.height - image.size.height) < 0.5
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0].id
    }
}

private struct JournalCustomizationSheet: View {
    let chapter: PrototypeChapter
    let initialStoryboardCovers: [JournalStoryboardCoverCandidate]
    let onSave: (JournalCustomization) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedColorHex: String
    @State private var coverSource: JournalCustomizationCoverSource
    @State private var selectedStoredCoverImage: UIImage?
    @State private var storyboardCoverCandidates: [JournalStoryboardCoverCandidate]
    @State private var isLoadingStoryboardCovers = false
    @State private var unsplashQuery: String
    @State private var unsplashPhotos: [UnsplashCoverPhoto] = []
    @State private var unsplashResultsCache: [String: [UnsplashCoverPhoto]] = [:]
    @State private var unsplashPageCache: [String: Int] = [:]
    @State private var unsplashHasMoreCache: [String: Bool] = [:]
    @State private var currentUnsplashCacheKey: String?
    @State private var currentUnsplashPage = 0
    @State private var canLoadMoreUnsplashPhotos = false
    @State private var isSearchingUnsplash = false
    @State private var isLoadingMoreUnsplash = false
    @State private var unsplashErrorMessage: String?
    @FocusState private var isUnsplashSearchFocused: Bool
    private let unsplashService = UnsplashCoverService()
    private let unsplashPageSize = 18

    init(
        chapter: PrototypeChapter,
        initialStoryboardCovers: [JournalStoryboardCoverCandidate] = [],
        onSave: @escaping (JournalCustomization) -> Void
    ) {
        self.chapter = chapter
        self.initialStoryboardCovers = initialStoryboardCovers
        self.onSave = onSave
        let initialColorHex = JournalColorOption.hexString(for: chapter.color)
        let initialStoredCoverImage = JournalCoverStore.image(for: chapter)
        let initialCoverSource = JournalCustomizationCoverSource.resolving(
            remoteCover: chapter.remoteCover,
            coverImageName: chapter.coverImageName,
            storedCoverImage: initialStoredCoverImage,
            storyboardCandidates: initialStoryboardCovers
        )
        _selectedColorHex = State(initialValue: initialColorHex)
        _coverSource = State(initialValue: initialCoverSource)
        _selectedStoredCoverImage = State(
            initialValue: {
                if case .storyboard = initialCoverSource {
                    return initialStoredCoverImage
                }
                return nil
            }()
        )
        _storyboardCoverCandidates = State(initialValue: initialStoryboardCovers)
        _unsplashQuery = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        preview
                        colorSection
                        coverSection
                    }
                    .padding(18)
                    .padding(.bottom, isUnsplashSearchFocused ? 180 : 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .background {
                    Color.homePageBackground
                        .onTapGesture {
                            isUnsplashSearchFocused = false
                        }
                }
                .onChange(of: isUnsplashSearchFocused) { isFocused in
                    guard isFocused else {
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("unsplash-search-field", anchor: .center)
                        }
                    }
                }
            }
            .background(Color.homePageBackground)
            .navigationTitle("Journal Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCurrentSelection()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button {
                        isUnsplashSearchFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .fontWeight(.bold)
                    .accessibilityLabel("Dismiss keyboard")
                }
            }
        }
        .task {
            await loadCloudStoryboardCoverCandidatesIfNeeded()
        }
    }

    private var selectedColor: Color {
        Color(hex: selectedColorHex) ?? chapter.color
    }

    private var selectedCoverImageName: String? {
        if case .image(let name) = coverSource {
            return name
        }
        return nil
    }

    private var selectedRemoteCover: JournalRemoteCover? {
        if case .unsplash(let remoteCover) = coverSource {
            return remoteCover
        }
        return nil
    }

    private var selectedStoryboardCoverID: UUID? {
        if case .storyboard(let id) = coverSource {
            return id
        }
        return nil
    }

    private var isColorCoverSelected: Bool {
        if case .color = coverSource {
            return true
        }
        return false
    }

    private var coverImageCandidates: [String] {
        var seen = Set<String>()
        return chapter.entries
            .flatMap(\.imageNames)
            .filter { imageName in
                UIImage(named: imageName) != nil && seen.insert(imageName).inserted
            }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            JournalCoverPreview(
                title: chapter.title,
                entryCount: chapter.entries.count,
                color: selectedColor,
                coverImage: selectedRemoteCover == nil ? selectedStoredCoverImage : nil,
                remoteCoverURL: selectedRemoteCover?.thumbnailNSURL ?? selectedRemoteCover?.imageNSURL,
                fallbackImageName: selectedCoverImageName,
                attributionName: selectedRemoteCover?.attributionName
            )
            .frame(maxWidth: 210)

            Group {
                if
                    let attributionName = selectedRemoteCover?.attributionName,
                    let attributionURL = selectedRemoteCover?.attributionURL,
                    let url = URL(string: attributionURL)
                {
                    Link("Photo by \(attributionName) on Unsplash", destination: url)
                        .foregroundStyle(Color.homeAccent)
                } else {
                    Text(" ")
                        .foregroundStyle(Color.clear)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(JournalColorOption.all) { option in
                    Button {
                        selectColor(option)
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 42, height: 42)
                            .overlay {
                                if isColorCoverSelected, selectedColorHex == option.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .heavy))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                            }
                            .shadow(color: option.color.opacity(0.24), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name)
                }
            }
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cover Photo")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            if storyboardCoverCandidates.isEmpty && coverImageCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Storyboard image choices will appear here.", systemImage: "photo.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)

                    Text("Completed storyboard images from entries in this journal can be used as covers.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.homeMutedText.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.homeBorder, lineWidth: 1)
                )
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(storyboardCoverCandidates) { candidate in
                        Button {
                            selectStoryboardCover(candidate)
                        } label: {
                            let isSelected = selectedStoryboardCoverID == candidate.id

                            CoverPhotoTile(isSelected: isSelected) {
                                Image(uiImage: candidate.image)
                                    .resizable()
                                    .scaledToFill()
                            }
                                .overlay(alignment: .topTrailing) {
                                    if isSelected {
                                        selectedCoverBadge
                                            .padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use storyboard image as cover")
                    }

                    ForEach(coverImageCandidates, id: \.self) { imageName in
                        Button {
                            selectStoryboardCoverImage(named: imageName)
                        } label: {
                            let isSelected = selectedCoverImageName == imageName

                            CoverPhotoTile(isSelected: isSelected) {
                                Image(imageName)
                                    .resizable()
                                    .scaledToFill()
                            }
                                .overlay(alignment: .topTrailing) {
                                    if isSelected {
                                        selectedCoverBadge
                                            .padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use image as cover")
                    }
                }
            }

            if isLoadingStoryboardCovers {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading storyboard covers...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }
            }

            unsplashSection
        }
    }

    private var unsplashSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stock Photos")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            HStack(spacing: 8) {
                TextField("Search cover photos", text: $unsplashQuery)
                    .focused($isUnsplashSearchFocused)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit {
                        searchUnsplash()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.homeBorder, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                Button {
                    searchUnsplash()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 40)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSearchingUnsplash || isLoadingMoreUnsplash)
                .accessibilityLabel("Search stock photos")
            }
            .frame(height: 40)
            .id("unsplash-search-field")
            .zIndex(2)

            if isSearchingUnsplash {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let unsplashErrorMessage {
                Text(unsplashErrorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.storyRose)
                    .fixedSize(horizontal: false, vertical: true)
            } else if unsplashPhotos.isEmpty {
                Text("Search stock photos when you're ready to browse cover photos.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(unsplashPhotos) { photo in
                        Button {
                            selectUnsplashPhoto(photo)
                        } label: {
                            let isSelected = selectedRemoteCover?.imageURL == photo.imageURL

                            CoverPhotoTile(isSelected: isSelected) {
                                Group {
                                    if let thumbnailURL = URL(string: photo.thumbnailURL) {
                                        RemoteCoverImage(url: thumbnailURL, placeholderColor: Color.homeCardGray)
                                    } else {
                                        Color.homeCardGray
                                    }
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text(photo.attributionName)
                                    .font(.system(size: 9, weight: .bold))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.black.opacity(0.38))
                            }
                            .overlay(alignment: .topTrailing) {
                                if isSelected {
                                    selectedCoverBadge
                                        .padding(6)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use Unsplash photo by \(photo.attributionName)")
                    }
                }
                .padding(.top, 2)
                .zIndex(1)

                if canLoadMoreUnsplashPhotos, currentUnsplashCacheKey == normalizedUnsplashQuery(unsplashQuery) {
                    Button {
                        loadMoreUnsplashPhotos()
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingMoreUnsplash {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(isLoadingMoreUnsplash ? "Loading..." : "Load More")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(isLoadingMoreUnsplash ? Color.homeMutedText : Color.homeAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.homeBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingMoreUnsplash || isSearchingUnsplash)
                    .accessibilityLabel("Load more stock photos")
                    .padding(.top, 2)
                }
            }

            Color.clear
                .frame(height: 160)
        }
    }

    private var selectedCoverBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.homeAccent, in: Circle())
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
            .shadow(color: Color.storyInk.opacity(0.22), radius: 4, y: 2)
    }

    private func saveCurrentSelection() {
        let coverImageName: String?
        let remoteCover: JournalRemoteCover?
        let storedCoverImage: UIImage?
        let clearsStoredCover: Bool

        switch coverSource {
        case .color:
            coverImageName = nil
            remoteCover = nil
            storedCoverImage = nil
            clearsStoredCover = true
        case .storyboard:
            coverImageName = nil
            remoteCover = nil
            storedCoverImage = selectedStoredCoverImage
            clearsStoredCover = false
        case .image(let name):
            coverImageName = name
            remoteCover = nil
            storedCoverImage = nil
            clearsStoredCover = true
        case .unsplash(let cover):
            coverImageName = nil
            remoteCover = cover
            storedCoverImage = nil
            clearsStoredCover = true
        }

        onSave(
            JournalCustomization(
                chapterID: chapter.id,
                color: selectedColor,
                coverImageName: coverImageName,
                remoteCover: remoteCover,
                storedCoverImage: storedCoverImage,
                clearsStoredCover: clearsStoredCover
            )
        )
        if let downloadLocation = remoteCover?.downloadLocation {
            Task {
                try? await unsplashService.trackDownload(downloadLocation: downloadLocation)
            }
        }
    }

    private func searchUnsplash() {
        let query = unsplashQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearchingUnsplash, !isLoadingMoreUnsplash else {
            return
        }
        isUnsplashSearchFocused = false
        let cacheKey = normalizedUnsplashQuery(query)

        if let cachedPhotos = unsplashResultsCache[cacheKey] {
            unsplashPhotos = cachedPhotos
            currentUnsplashCacheKey = cacheKey
            currentUnsplashPage = unsplashPageCache[cacheKey] ?? cachedPageCount(for: cachedPhotos)
            canLoadMoreUnsplashPhotos = unsplashHasMoreCache[cacheKey] ?? (cachedPhotos.count >= unsplashPageSize)
            unsplashErrorMessage = nil
            return
        }

        currentUnsplashCacheKey = cacheKey
        currentUnsplashPage = 0
        canLoadMoreUnsplashPhotos = false
        isSearchingUnsplash = true
        unsplashErrorMessage = nil

        Task {
            do {
                let photos = try await unsplashService.search(query: query, page: 1, perPage: unsplashPageSize)
                await MainActor.run {
                    unsplashPhotos = photos
                    unsplashResultsCache[cacheKey] = photos
                    unsplashPageCache[cacheKey] = 1
                    unsplashHasMoreCache[cacheKey] = photos.count == unsplashPageSize
                    currentUnsplashCacheKey = cacheKey
                    currentUnsplashPage = 1
                    canLoadMoreUnsplashPhotos = photos.count == unsplashPageSize
                    isSearchingUnsplash = false
                }
            } catch {
                await MainActor.run {
                    unsplashErrorMessage = error.localizedDescription
                    isSearchingUnsplash = false
                }
            }
        }
    }

    private func loadMoreUnsplashPhotos() {
        let query = unsplashQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = normalizedUnsplashQuery(query)
        guard !query.isEmpty,
              !isSearchingUnsplash,
              !isLoadingMoreUnsplash,
              canLoadMoreUnsplashPhotos,
              currentUnsplashCacheKey == cacheKey else {
            return
        }

        let nextPage = currentUnsplashPage + 1
        isLoadingMoreUnsplash = true
        unsplashErrorMessage = nil

        Task {
            do {
                let photos = try await unsplashService.search(query: query, page: nextPage, perPage: unsplashPageSize)
                await MainActor.run {
                    let existingIDs = Set(unsplashPhotos.map(\.id))
                    let newPhotos = photos.filter { !existingIDs.contains($0.id) }
                    unsplashPhotos.append(contentsOf: newPhotos)
                    unsplashResultsCache[cacheKey] = unsplashPhotos
                    unsplashPageCache[cacheKey] = nextPage
                    unsplashHasMoreCache[cacheKey] = photos.count == unsplashPageSize
                    currentUnsplashPage = nextPage
                    canLoadMoreUnsplashPhotos = photos.count == unsplashPageSize
                    isLoadingMoreUnsplash = false
                }
            } catch {
                await MainActor.run {
                    unsplashErrorMessage = error.localizedDescription
                    isLoadingMoreUnsplash = false
                }
            }
        }
    }

    private func cachedPageCount(for photos: [UnsplashCoverPhoto]) -> Int {
        max(Int(ceil(Double(photos.count) / Double(unsplashPageSize))), 1)
    }

    private func normalizedUnsplashQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func selectColor(_ option: JournalColorOption) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedColorHex = option.hex
            coverSource = .color
            selectedStoredCoverImage = nil
        }
    }

    private func selectStoryboardCoverImage(named imageName: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            coverSource = .image(name: imageName)
            selectedStoredCoverImage = nil
        }
    }

    private func selectStoryboardCover(_ candidate: JournalStoryboardCoverCandidate) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            coverSource = .storyboard(id: candidate.id)
            selectedStoredCoverImage = candidate.image
        }
    }

    private func selectUnsplashPhoto(_ photo: UnsplashCoverPhoto) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedStoredCoverImage = nil
            coverSource = .unsplash(
                JournalRemoteCover(
                    source: .unsplash,
                    imageURL: photo.imageURL,
                    thumbnailURL: photo.thumbnailURL,
                    attributionName: photo.attributionName,
                    attributionURL: photo.attributionURL,
                    downloadLocation: photo.downloadLocation
                )
            )
        }
    }

    @MainActor
    private func loadCloudStoryboardCoverCandidatesIfNeeded() async {
        let entryIDs = Set(chapter.entries.map(\.id))
        guard !entryIDs.isEmpty else {
            return
        }

        guard !isLoadingStoryboardCovers else {
            return
        }

        isLoadingStoryboardCovers = true
        defer { isLoadingStoryboardCovers = false }

        do {
            let rows = try await SupabaseStoryboardService().loadPrimaryCompletedStoryboards()
            let existingIDs = Set(storyboardCoverCandidates.map(\.id))
            let matchingRows = rows
                .filter { entryIDs.contains($0.clientEntryID) && !existingIDs.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }

            guard !matchingRows.isEmpty else {
                resolveStoryboardCoverSelectionIfNeeded(in: storyboardCoverCandidates)
                return
            }

            var loadedCandidates = storyboardCoverCandidates
            var persistedStoryboards = GeneratedStoryboardStore.load()

            for row in matchingRows {
                do {
                    let image = try await SupabaseStoryboardService().downloadStoryboardImage(storagePath: row.storagePath)
                    let storyboard = try GeneratedStoryboardStore.persistedStoryboard(
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
                    persistedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: persistedStoryboards)
                    loadedCandidates.append(JournalStoryboardCoverCandidate(storyboard: storyboard))
                } catch {
                    continue
                }
            }

            GeneratedStoryboardStore.save(persistedStoryboards)
            storyboardCoverCandidates = loadedCandidates.sorted { $0.createdAt > $1.createdAt }
            resolveStoryboardCoverSelectionIfNeeded(in: storyboardCoverCandidates)
        } catch {
            return
        }
    }

    private func resolveStoryboardCoverSelectionIfNeeded(in candidates: [JournalStoryboardCoverCandidate]) {
        guard case .storyboard(let selectedID) = coverSource, selectedID == nil else {
            return
        }
        guard let selectedStoredCoverImage else {
            return
        }
        let resolved = JournalCustomizationCoverSource.resolving(
            remoteCover: nil,
            coverImageName: nil,
            storedCoverImage: selectedStoredCoverImage,
            storyboardCandidates: candidates
        )
        if case .storyboard(let id) = resolved, id != nil {
            coverSource = resolved
        }
    }
}

private struct CoverPhotoTile<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            content()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .aspectRatio(JournalOpeningBook.compactAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.homeCardGray)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected ? Color.homeAccent : Color.white.opacity(0.9),
                    lineWidth: 2
                )
        }
    }
}

private struct JournalCoverPreview: View {
    let title: String
    let entryCount: Int
    let color: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    let attributionName: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else if let remoteCoverURL {
                    RemoteCoverImage(url: remoteCoverURL, placeholderColor: color)
                } else if let fallbackImageName {
                    Image(fallbackImageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    color
                }
            }
            .aspectRatio(JournalOpeningBook.compactAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()

            journalSpine

            titleScrim
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.09), radius: 8, y: 4)
    }

    private var titleScrim: some View {
        titleBackdrop
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text("\(entryCount) \(entryCount == 1 ? "entry" : "entries")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))

                    if let attributionName {
                        Text("Photo by \(attributionName) on Unsplash")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.86))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: attributionName == nil ? 58 : 72)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var titleBackdrop: some View {
        if hasImageCover {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.50),
                    Color.black.opacity(0.74)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var hasImageCover: Bool {
        coverImage != nil || remoteCoverURL != nil || fallbackImageName != nil
    }

    private var journalSpine: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.16),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.26),
                    Color.white.opacity(0.16),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 12.5)
            .padding(.leading, 14.25)
            .blendMode(.screen)
        }
        .frame(width: 22)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

private struct RemoteCoverImage: View {
    let url: URL
    let placeholderColor: Color
    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let loadedImage, loadedURL == url {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if let cachedImage = JournalRemoteCoverImageCache.image(for: url) {
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFill()
                    .onAppear {
                        loadedImage = cachedImage
                        loadedURL = url
                    }
            } else {
                placeholderColor
                    .task(id: url) {
                        await loadImage()
                    }
            }
        }
    }

    private func loadImage() async {
        if let cachedImage = JournalRemoteCoverImageCache.image(for: url) {
            loadedImage = cachedImage
            loadedURL = url
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let image = UIImage(data: data)
            else {
                return
            }

            JournalRemoteCoverImageCache.save(image, for: url)
            loadedImage = image
            loadedURL = url
        } catch {
            return
        }
    }
}

private enum JournalRemoteCoverImageCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func save(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}

private struct JournalColorOption: Identifiable {
    let name: String
    let hex: String

    var id: String {
        hex
    }

    var color: Color {
        Color(hex: hex) ?? Color.storyPurple
    }

    static let all: [JournalColorOption] = [
        JournalColorOption(name: "Indigo", hex: "#3D2678"),
        JournalColorOption(name: "Berry", hex: "#7D2148"),
        JournalColorOption(name: "Terracotta", hex: "#A24A35"),
        JournalColorOption(name: "Gold", hex: "#B87522"),
        JournalColorOption(name: "Moss", hex: "#245C48"),
        JournalColorOption(name: "Teal", hex: "#16636C"),
        JournalColorOption(name: "Ocean", hex: "#214D83"),
        JournalColorOption(name: "Violet", hex: "#683BA0"),
        JournalColorOption(name: "Charcoal", hex: "#2E3142"),
        JournalColorOption(name: "Rose", hex: "#B45467")
    ]

    static func hexString(for color: Color) -> String {
        UIColor(color).journaltopiaHexString ?? "#3D2678"
    }
}

private enum JournalCoverStore {
    private struct CloudCoverRecord: Codable, Equatable {
        let storagePath: String
        let updatedAt: Date
    }

    private static let folderName = "JournalCovers"
    private static let cloudStoragePathKey = "JournaltopiaJournalCoverCloudStoragePaths"

    static func image(for chapter: PrototypeChapter) -> UIImage? {
        image(journalID: chapter.id, legacyTitle: chapter.title)
    }

    static func image(journalID: UUID, legacyTitle: String? = nil) -> UIImage? {
        if let image = image(forKey: storageKey(for: journalID)) {
            return image
        }

        guard let legacyTitle else {
            return nil
        }

        return image(forKey: legacyTitle)
    }

    static func image(for title: String) -> UIImage? {
        image(forKey: title)
    }

    static func save(
        _ image: UIImage,
        for chapter: PrototypeChapter,
        cloudStoragePath: String? = nil,
        cloudUpdatedAt: Date? = nil
    ) {
        save(
            image,
            journalID: chapter.id,
            legacyTitle: chapter.title,
            cloudStoragePath: cloudStoragePath,
            cloudUpdatedAt: cloudUpdatedAt
        )
    }

    static func save(_ image: UIImage, for title: String) {
        save(image, forKey: title)
    }

    static func save(
        _ image: UIImage,
        journalID: UUID,
        legacyTitle _: String? = nil,
        cloudStoragePath: String? = nil,
        cloudUpdatedAt: Date? = nil
    ) {
        guard save(image, forKey: storageKey(for: journalID)) else {
            return
        }

        if let cloudStoragePath, let cloudUpdatedAt {
            setCloudCoverRecord(
                CloudCoverRecord(storagePath: cloudStoragePath, updatedAt: cloudUpdatedAt),
                for: journalID
            )
        }
        postCoverChanged(journalID: journalID)
    }

    @discardableResult
    private static func save(_ image: UIImage, forKey key: String) -> Bool {
        guard let data = image.journaltopiaPreparedJPEGData(compressionQuality: 0.86) ?? image.jpegData(compressionQuality: 0.86) else {
            return false
        }

        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: fileURL(for: key), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func rename(from oldTitle: String, to newTitle: String) {
        let oldURL = fileURL(for: oldTitle)
        let newURL = fileURL(for: newTitle)
        guard FileManager.default.fileExists(atPath: oldURL.path) else {
            return
        }

        try? FileManager.default.removeItem(at: newURL)
        try? FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    static func delete(title: String) {
        delete(key: title)
    }

    static func delete(for chapter: PrototypeChapter) {
        delete(journalID: chapter.id, legacyTitle: chapter.title)
    }

    static func delete(journalID: UUID, legacyTitle: String? = nil) {
        let removedIDCover = delete(key: storageKey(for: journalID))
        let hadCloudStoragePath = cloudCoverRecords[journalID.uuidString] != nil
        var removedLegacyCover = false
        if let legacyTitle {
            removedLegacyCover = delete(key: legacyTitle)
        }
        clearCloudStoragePath(for: journalID)
        if removedIDCover || removedLegacyCover || hadCloudStoragePath {
            postCoverChanged(journalID: journalID)
        }
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    static func needsCloudCoverDownload(
        journalID: UUID,
        cloudStoragePath: String,
        cloudUpdatedAt: Date
    ) -> Bool {
        cloudCoverRecords[journalID.uuidString] != CloudCoverRecord(
            storagePath: cloudStoragePath,
            updatedAt: cloudUpdatedAt
        )
            || !FileManager.default.fileExists(atPath: fileURL(for: storageKey(for: journalID)).path)
    }

    static func clearCloudStoragePath(for journalID: UUID) {
        var records = cloudCoverRecords
        records.removeValue(forKey: journalID.uuidString)
        persistCloudCoverRecords(records)
    }

    static func recordCloudStoragePath(_ storagePath: String, updatedAt: Date, for journalID: UUID) {
        setCloudCoverRecord(
            CloudCoverRecord(storagePath: storagePath, updatedAt: updatedAt),
            for: journalID
        )
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func image(forKey key: String) -> UIImage? {
        guard
            let data = try? Data(contentsOf: fileURL(for: key)),
            let image = UIImage(data: data)
        else {
            return nil
        }

        return image
    }

    private static func fileURL(for key: String) -> URL {
        directoryURL.appendingPathComponent(fileName(for: key))
    }

    private static func fileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = key.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return "\(sanitized.isEmpty ? "journal" : sanitized).jpg"
    }

    private static func storageKey(for journalID: UUID) -> String {
        "journal-\(journalID.uuidString.lowercased())"
    }

    private static var cloudCoverRecords: [String: CloudCoverRecord] {
        guard let data = UserDefaults.standard.data(forKey: cloudStoragePathKey) else {
            return [:]
        }

        if let records = try? JSONDecoder().decode([String: CloudCoverRecord].self, from: data) {
            return records
        }

        if let legacyPaths = try? JSONDecoder().decode([String: String].self, from: data) {
            return legacyPaths.mapValues {
                CloudCoverRecord(storagePath: $0, updatedAt: .distantPast)
            }
        }

        return [:]
    }

    private static func setCloudCoverRecord(_ record: CloudCoverRecord, for journalID: UUID) {
        var records = cloudCoverRecords
        records[journalID.uuidString] = record
        persistCloudCoverRecords(records)
    }

    private static func persistCloudCoverRecords(_ records: [String: CloudCoverRecord]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: cloudStoragePathKey)
    }

    private static func postCoverChanged(journalID: UUID) {
        NotificationCenter.default.post(
            name: .journaltopiaJournalCoverChanged,
            object: nil,
            userInfo: ["journalID": journalID]
        )
    }
}

struct ClassicJournalView: View {
    @Binding var selectedPage: StoryPage
    @Binding var isDraftSaved: Bool
    @Binding var activeDraftID: UUID?
    var embedsInNavigationStack = true
    var showsBottomNavigation = true

    @State private var showsPrototypeData = false
    @State private var chapters: [PrototypeChapter]
    @State private var editMode: EditMode = .inactive
    @State private var journalBeingRenamed: PrototypeChapter?
    @State private var renamedJournalTitle = ""
    @State private var journalsPendingDeletion: [PrototypeChapter] = []
    @State private var isCreateJournalAlertPresented = false
    @State private var newJournalTitle = ""

    init(
        selectedPage: Binding<StoryPage>,
        isDraftSaved: Binding<Bool>,
        activeDraftID: Binding<UUID?>,
        embedsInNavigationStack: Bool = true,
        showsBottomNavigation: Bool = true
    ) {
        _selectedPage = selectedPage
        _isDraftSaved = isDraftSaved
        _activeDraftID = activeDraftID
        self.embedsInNavigationStack = embedsInNavigationStack
        self.showsBottomNavigation = showsBottomNavigation
        _chapters = State(initialValue: DailyJournalData.allChapters())
    }

    var body: some View {
        Group {
            if embedsInNavigationStack {
                NavigationStack {
                    classicJournalContent
                }
            } else {
                classicJournalContent
            }
        }
        .onAppear {
            chapters = DailyJournalData.allChapters()
        }
        .onChange(of: selectedPage) { newPage in
            if newPage != .create {
                chapters = DailyJournalData.allChapters()
            }
        }
        .preferredColorScheme(.light)
        .alert("Rename Journal", isPresented: isRenameAlertPresented) {
            TextField("Journal name", text: $renamedJournalTitle)

            Button("Cancel", role: .cancel) {
                journalBeingRenamed = nil
                renamedJournalTitle = ""
            }

            Button("Save") {
                renameSelectedJournal()
            }
        }
        .alert("Create Journal", isPresented: $isCreateJournalAlertPresented) {
            TextField("Journal name", text: $newJournalTitle)

            Button("Cancel", role: .cancel) {
                newJournalTitle = ""
            }

            Button("Create") {
                createJournal()
            }
        }
        .alert(deleteJournalAlertTitle, isPresented: isDeleteJournalAlertPresented) {
            Button("Cancel", role: .cancel) {
                journalsPendingDeletion = []
            }

            Button("Delete", role: .destructive) {
                deletePendingJournals()
            }
        } message: {
            Text(deleteJournalAlertMessage)
        }
    }

    private var classicJournalContent: some View {
        ZStack(alignment: .bottom) {
            journalBackground

            VStack(alignment: .leading, spacing: 10) {
                header
                    .padding(.horizontal, 16)

                chapterList
            }

            if showsBottomNavigation {
                BottomNavigationBar(selectedPage: $selectedPage)
            }

            bottomPrototypeNotice
        }
        .navigationTitle(embedsInNavigationStack ? "" : "All Journals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(embedsInNavigationStack ? .hidden : .visible, for: .navigationBar)
        .environment(\.editMode, $editMode)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Journals")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            EditButton()
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.homeAccent)

            journalCreateButton
        }
        .padding(.top, 12)
    }

    private var journalCreateButton: some View {
        Button {
            handleCreateButtonTapped()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create a new journal")
    }

    @ViewBuilder
    private var bottomPrototypeNotice: some View {
        if false {
            prototypeNotice
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 82)
        }
    }

    private var prototypeNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.homeAccent)

            Text("Previewing sample journal entries")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)

            Spacer()

            Button("Show empty") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsPrototypeData = false
                }
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.homeAccent)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var chapterList: some View {
        List {
            Section {
                if chapters.isEmpty {
                    noSearchResults
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                } else {
                    journalRows
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.homePageBackground)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: showsBottomNavigation ? 150 : 60)
        }
    }

    private var journalRows: some View {
        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
            NavigationLink {
                dailyJournalDetail(for: chapter, dayOffset: index)
            } label: {
                JournalChapterListRow(
                    chapter: chapter,
                    coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter) : nil,
                    remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
                    fallbackImageName: journalFallbackCoverImageName(for: chapter, at: index)
                )
            }
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: JournalChapterListMetrics.horizontalInset,
                bottom: 0,
                trailing: JournalChapterListMetrics.trailingInset
            ))
            .listRowBackground(Color.homePageBackground)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    beginRenaming(chapter)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(Color.homeAccent)
            }
        }
        .onDelete(perform: deleteChapters)
        .onMove(perform: moveChapters)
    }

    private var isRenameAlertPresented: Binding<Bool> {
        Binding(
            get: { journalBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    journalBeingRenamed = nil
                    renamedJournalTitle = ""
                }
            }
        )
    }

    private func beginRenaming(_ chapter: PrototypeChapter) {
        journalBeingRenamed = chapter
        renamedJournalTitle = chapter.title
    }

    private func renameSelectedJournal() {
        guard
            let selectedJournal = journalBeingRenamed,
            let index = chapters.firstIndex(where: { $0.id == selectedJournal.id })
        else {
            return
        }

        let trimmedTitle = renamedJournalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        let oldTitle = chapters[index].title
        chapters[index] = chapters[index].copy(title: trimmedTitle)
        UserChapterStore.rename(title: oldTitle, to: trimmedTitle)
        UserChapterStore.syncToCloud(chapters[index])
        StoryEntryStore.renameChapter(from: oldTitle, to: trimmedTitle)
        JournalCoverStore.rename(from: oldTitle, to: trimmedTitle)
        journalBeingRenamed = nil
        renamedJournalTitle = ""
    }

    private func handleCreateButtonTapped() {
        isCreateJournalAlertPresented = true
    }

    private func createJournal() {
        let trimmedTitle = newJournalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        let journal = PrototypeChapter(
            title: trimmedTitle,
            subtitle: "Personal journal",
            color: Color.storyPurple,
            symbol: "book.closed.fill",
            coverImageName: nil,
            kind: .journal,
            isFavorite: false,
            entries: []
        )

        UserChapterStore.add(journal)
        chapters = DailyJournalData.allChapters()
        showsPrototypeData = false
        newJournalTitle = ""
    }

    private func deleteChapters(at offsets: IndexSet) {
        requestDeleteJournals(offsets.map { chapters[$0] })
    }

    private var isDeleteJournalAlertPresented: Binding<Bool> {
        Binding(
            get: { !journalsPendingDeletion.isEmpty },
            set: { isPresented in
                if !isPresented {
                    journalsPendingDeletion = []
                }
            }
        )
    }

    private var deleteJournalAlertTitle: String {
        journalsPendingDeletion.count == 1 ? "Delete Journal?" : "Delete Journals?"
    }

    private var deleteJournalAlertMessage: String {
        if let journal = journalsPendingDeletion.first, journalsPendingDeletion.count == 1 {
            return "Are you sure you want to delete \"\(journal.title)\"? This can't be undone. Entries won't be deleted — they'll stay in your library, and any that aren't in another journal will appear under Not in Journal."
        }

        return "Are you sure you want to delete these journals? This can't be undone. Entries won't be deleted — they'll stay in your library, and any that aren't in another journal will appear under Not in Journal."
    }

    private func requestDeleteJournals(_ journals: [PrototypeChapter]) {
        journalsPendingDeletion = journals
    }

    private func deletePendingJournals() {
        let journalsToDelete = journalsPendingDeletion
        journalsPendingDeletion = []
        journalsToDelete.forEach(deleteJournal)
    }

    private func deleteJournal(_ journal: PrototypeChapter) {
        let isUserJournal = UserChapterStore.contains(title: journal.title)
        UserChapterStore.delete(title: journal.title)
        UserChapterStore.deleteFromCloud(journal)
        JournalCoverStore.delete(for: journal)
        if !isUserJournal {
            DeletedSampleChapterStore.add(title: journal.title)
        }
        StoryEntryStore.deleteAll(for: journal.title)

        chapters.removeAll { $0.id == journal.id }
        let userChapters = chapters.filter { UserChapterStore.contains(title: $0.title) }
        UserChapterStore.replace(with: userChapters)
        UserChapterStore.syncOrderToCloud(userChapters)
    }

    private func moveChapters(from source: IndexSet, to destination: Int) {
        chapters.move(fromOffsets: source, toOffset: destination)
        UserChapterStore.replace(with: chapters.filter { UserChapterStore.contains(title: $0.title) })
        UserChapterStore.syncOrderToCloud(chapters)
    }

    private func journalDate(dayOffset: Int) -> Date {
        DailyJournalData.journalDate(dayOffset: dayOffset)
    }

    private func dailyJournalDetail(for chapter: PrototypeChapter, dayOffset: Int) -> some View {
        DailyJournalData.detailView(
            for: chapter,
            dayOffset: dayOffset,
            onChapterUpdated: updateChapterFromDetail
        ) { entry in
            guard let chapterIndex = chapters.firstIndex(where: { $0.id == chapter.id }) else {
                return
            }

            if let existingIndex = chapters[chapterIndex].entries.firstIndex(where: { $0.id == entry.id }) {
                chapters[chapterIndex].entries[existingIndex] = entry
            } else {
                chapters[chapterIndex].entries.insert(entry, at: 0)
            }
        }
    }

    private func updateChapterFromDetail(_ updatedChapter: PrototypeChapter) {
        guard let chapterIndex = chapters.firstIndex(where: { $0.id == updatedChapter.id }) else {
            return
        }

        chapters[chapterIndex] = updatedChapter
    }

    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.homeAccent.opacity(0.6))

            Text("No journals yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text("Your journals will appear here.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 58)

            Image("no_entries_journal")
                .resizable()
                .scaledToFit()
                .frame(width: 165)
                .padding(.bottom, 3)

            VStack(spacing: 8) {
                Text("No journals yet")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text("Create a journal to start collecting entries and storyboards.")
                    .font(.system(size: 13, weight: .semibold))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.homeMutedText)
            }

            Button {
                isCreateJournalAlertPresented = true
            } label: {
                Label("Create Journal", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 39)
                    .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var journalBackground: some View {
        Color.homePageBackground
            .ignoresSafeArea()
    }
}

private struct JournalStoryboardComicReaderView: View {
    @EnvironmentObject private var signInGate: SignInGate

    let storyboards: [GeneratedStoryboard]
    @Binding var currentPageIndex: Int
    let journalTitle: String
    let journalColor: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackCoverImageName: String?
    let pageCountText: String
    let storyboardCountText: String
    let chapter: PrototypeChapter
    let storyboardCoverCandidates: [JournalStoryboardCoverCandidate]
    let onCoverCustomized: (JournalCustomization) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("journalStoryboardComicReaderGestureHintSeen") private var readerGestureHintSeen = false

    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var isShowingGestureHint = false
    @State private var isShowingCoverCustomization = false
    @State private var isShowingVerticalView = false
    @State private var isPageTurnActive = false
    @State private var programmaticTurnOffset = 0
    @State private var programmaticTurnProgress: CGFloat = 0
    @State private var programmaticTurnTask: Task<Void, Never>?
    @GestureState private var isMagnifying = false

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 5
    private let thumbnailHeight: CGFloat = 56
    private let panEdgePaddingRatio: CGFloat = 0.28
    private let readerTopToolbarClearance: CGFloat = 58
    private let zoomSteps: [CGFloat] = [1.75, 2.5, 3.5, 5]

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            readerPageContent
                .zIndex(isPageTurnActive ? 3 : 0)

            VStack(spacing: 0) {
                readerTopBar

                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    readerBottomBar
                    readerThumbnailStrip
                }
                    .background {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
            .zIndex(1)

            if isShowingGestureHint {
                gestureHintOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(4)
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .enableInteractivePopGesture()
        .statusBarHidden()
        .onAppear {
            currentPageIndex = clampedPageIndex(currentPageIndex)
            presentGestureHintIfNeeded()
        }
        .onChange(of: currentPageIndex) { _ in
            resetZoom(animated: false)
        }
        .onChange(of: storyboards.count) { _ in
            currentPageIndex = clampedPageIndex(currentPageIndex)
        }
        .onDisappear {
            programmaticTurnTask?.cancel()
            programmaticTurnTask = nil
            resetZoom(animated: false)
        }
        .sheet(isPresented: $isShowingCoverCustomization) {
            JournalCustomizationSheet(
                chapter: chapter,
                initialStoryboardCovers: storyboardCoverCandidates,
                onSave: { customization in
                    onCoverCustomized(customization)
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingVerticalView) {
            JournalStoryboardVerticalComicViewer(
                storyboards: storyboards,
                currentPageIndex: $currentPageIndex,
                journalTitle: journalTitle,
                journalColor: journalColor,
                coverImage: coverImage,
                remoteCoverURL: remoteCoverURL,
                fallbackCoverImageName: fallbackCoverImageName,
                pageCountText: pageCountText,
                storyboardCountText: storyboardCountText,
                readerPageAspectRatio: readerPageAspectRatio
            )
        }
    }

    private var readerTopBar: some View {
        HStack(spacing: 12) {
            Button {
                resetZoom(animated: false)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to journal")

            Spacer()

            Text("\(currentPageIndex + 1) / \(totalPageCount)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            Button {
                isShowingVerticalView = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open vertical comic view")
            .accessibilityHint("Shows the journal comic as a vertical scroll")

            Menu {
                Button {
                    isShowingVerticalView = true
                } label: {
                    Label("Vertical View", systemImage: "list.bullet.rectangle")
                }

                Button {
                    guard signInGate.requireAccount(for: .customizeJournalCover, retry: { isShowingCoverCustomization = true }) else {
                        return
                    }

                    isShowingCoverCustomization = true
                } label: {
                    Label("Change Cover", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("Reader options")
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

    private var readerPageContent: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let pageSize = fittedPageSize(in: viewport)

            readerBookSurface(pageSize: pageSize) {
                Group {
                    if showsPageTurnView {
                        JournalStoryboardPageTurnView(
                            images: storyboardImages,
                            journalTitle: journalTitle,
                            journalColor: journalColor,
                            coverImage: coverImage,
                            remoteCoverURL: remoteCoverURL,
                            fallbackCoverImageName: fallbackCoverImageName,
                            pageCountText: pageCountText,
                            storyboardCountText: storyboardCountText,
                            currentPageIndex: $currentPageIndex,
                            programmaticTurnOffset: programmaticTurnOffset,
                            programmaticTurnProgress: programmaticTurnProgress,
                            isPageTurnActive: $isPageTurnActive
                        )
                        .frame(width: pageSize.width, height: pageSize.height)
                        .scaleEffect(isMagnifying ? zoomScale : 1)
                        .simultaneousGesture(fitZoomMagnificationGesture(pageSize: pageSize, viewport: viewport))
                    } else {
                        pageView(at: currentPageIndex)
                            .frame(width: pageSize.width, height: pageSize.height)
                            .scaleEffect(zoomScale)
                            .offset(panOffset)
                            .contentShape(Rectangle())
                            .gesture(zoomedGestures(pageSize: pageSize, viewport: viewport))
                            .onTapGesture(count: 2) {
                                resetZoom(animated: true)
                            }
                    }
                }
            }
            .padding(.top, readerTopToolbarClearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func pageView(at pageIndex: Int) -> some View {
        if pageIndex == 0 {
            JournalStoryboardReaderCoverPage(
                title: journalTitle,
                color: journalColor,
                coverImage: coverImage,
                remoteCoverURL: remoteCoverURL,
                fallbackImageName: fallbackCoverImageName,
                pageCountText: pageCountText,
                storyboardCountText: storyboardCountText
            )
        } else if let image = image(for: pageIndex) {
            storyboardPage(image)
        }
    }

    private func storyboardPage(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.black.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 20)
                }
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.12), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                    .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func readerBookSurface<Content: View>(
        pageSize: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: pageSize.width, height: pageSize.height)
            .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 8)
    }

    private var readerBottomBar: some View {
        HStack(spacing: 14) {
            readerControlButton(
                isEnabled: !isAtFitZoom,
                accessibilityLabel: "Fit page",
                usesSquareShape: true
            ) {
                fitPageIcon(isEnabled: !isAtFitZoom)
            } action: {
                resetZoom(animated: true)
            }

            Spacer(minLength: 0)

            readerControlButton(
                isEnabled: currentPageIndex > 0 && !isTurningProgrammatically,
                accessibilityLabel: "Previous page"
            ) {
                Image(systemName: "chevron.left")
            } action: {
                turnPage(by: -1)
            }

            readerControlButton(
                isEnabled: currentPageIndex < totalPageCount - 1 && !isTurningProgrammatically,
                accessibilityLabel: "Next page"
            ) {
                Image(systemName: "chevron.right")
            } action: {
                turnPage(by: 1)
            }

            Spacer(minLength: 0)

            readerControlButton(
                isEnabled: canZoomInFurther,
                accessibilityLabel: "Zoom in",
                usesSquareShape: true
            ) {
                Image(systemName: "plus.magnifyingglass")
            } action: {
                zoomInOneStep()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func fitPageIcon(isEnabled: Bool) -> some View {
        let tint = isEnabled ? Color.white : Color.white.opacity(0.28)

        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint, lineWidth: 2)
                .frame(width: 17, height: 17)

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(tint)
        }
    }

    private func readerControlButton<Label: View>(
        isEnabled: Bool,
        accessibilityLabel: String,
        usesSquareShape: Bool = false,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.28))
                .frame(width: 44, height: 40)
                .background {
                    if usesSquareShape {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(isEnabled ? 0.14 : 0.06))
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(isEnabled ? 0.14 : 0.06))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var readerThumbnailStrip: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentPageIndex = 0
                            }
                        } label: {
                            readerCoverThumbnail()
                        }
                        .buttonStyle(.plain)
                        .id(0)
                        .accessibilityLabel("Go to journal cover")
                        .accessibilityAddTraits(currentPageIndex == 0 ? .isSelected : [])

                        ForEach(Array(storyboards.enumerated()), id: \.element.id) { index, storyboard in
                            let pageIndex = index + 1

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentPageIndex = pageIndex
                                }
                            } label: {
                                readerThumbnail(for: storyboard.image, at: pageIndex)
                            }
                            .buttonStyle(.plain)
                            .id(pageIndex)
                            .accessibilityLabel("Go to storyboard \(index + 1)")
                            .accessibilityAddTraits(pageIndex == currentPageIndex ? .isSelected : [])
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: .center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
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
        .frame(height: thumbnailHeight + 12)
        .padding(.bottom, 10)
    }

    private func readerCoverThumbnail() -> some View {
        let isSelected = currentPageIndex == 0

        return JournalStoryboardReaderCoverPage(
            title: journalTitle,
            color: journalColor,
            coverImage: coverImage,
            remoteCoverURL: remoteCoverURL,
            fallbackImageName: fallbackCoverImageName,
            pageCountText: pageCountText,
            storyboardCountText: storyboardCountText,
            showsDecorativeCopy: false
        )
        .frame(width: thumbnailHeight * readerPageAspectRatio, height: thumbnailHeight)
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
        .animation(.easeInOut(duration: 0.18), value: currentPageIndex)
    }

    private func readerThumbnail(for image: UIImage, at index: Int) -> some View {
        let isSelected = index == currentPageIndex
        let aspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 0.57
        let thumbnailWidth = max(28, thumbnailHeight * aspectRatio)

        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: thumbnailWidth, height: thumbnailHeight)
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
            .animation(.easeInOut(duration: 0.18), value: currentPageIndex)
    }

    private var gestureHintOverlay: some View {
        Text("Pinch to zoom. Swipe pages at 1x.")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.72), in: Capsule())
            .padding(.horizontal, 28)
    }

    private var storyboardImages: [UIImage] {
        storyboards.map(\.image)
    }

    private var totalPageCount: Int {
        storyboards.count + 1
    }

    private var readerPageAspectRatio: CGFloat {
        guard let firstStoryboard = storyboards.first,
              firstStoryboard.image.size.height > 0 else {
            return 0.57
        }

        return firstStoryboard.image.size.width / firstStoryboard.image.size.height
    }

    private var isAtFitZoom: Bool {
        zoomScale <= minimumScale + 0.02
    }

    private var showsPageTurnView: Bool {
        if programmaticTurnOffset != 0 {
            return true
        }

        if isMagnifying {
            return lastZoomScale <= minimumScale + 0.02
        }

        return isAtFitZoom
    }

    private var isTurningProgrammatically: Bool {
        isPageTurnActive || programmaticTurnOffset != 0
    }

    private var canZoomInFurther: Bool {
        zoomSteps.contains { $0 > zoomScale + 0.05 }
    }

    private func image(for pageIndex: Int) -> UIImage? {
        let index = clampedPageIndex(pageIndex) - 1
        guard storyboards.indices.contains(index) else {
            return nil
        }

        return storyboards[index].image
    }

    private func imageAspectRatio(for pageIndex: Int) -> CGFloat {
        if clampedPageIndex(pageIndex) == 0 {
            return readerPageAspectRatio
        }

        guard let image = image(for: pageIndex), image.size.height > 0 else {
            return 0.57
        }

        return image.size.width / image.size.height
    }

    private func zoomInOneStep() {
        guard let nextScale = zoomSteps.first(where: { $0 > zoomScale + 0.05 }) else {
            return
        }

        applyZoom(to: nextScale, animated: true)
    }

    private func applyZoom(to scale: CGFloat, animated: Bool) {
        let updates = {
            zoomScale = clampedScale(scale)
            lastZoomScale = zoomScale
            panOffset = .zero
            lastPanOffset = .zero
        }

        if animated {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func fitZoomMagnificationGesture(pageSize: CGSize, viewport: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($isMagnifying) { _, state, _ in
                state = true
            }
            .onChanged { value in
                zoomScale = rubberBandScale(lastZoomScale * value)
            }
            .onEnded { _ in
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.84)) {
                    zoomScale = clampedScale(zoomScale)

                    if isAtFitZoom {
                        panOffset = .zero
                        lastPanOffset = .zero
                    } else {
                        panOffset = boundedOffset(
                            panOffset,
                            pageSize: pageSize,
                            viewport: viewport
                        )
                        lastPanOffset = panOffset
                    }

                    lastZoomScale = zoomScale
                }
            }
    }

    private func zoomedGestures(pageSize: CGSize, viewport: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    zoomScale = rubberBandScale(lastZoomScale * value)
                    panOffset = boundedOffset(
                        panOffset,
                        pageSize: pageSize,
                        viewport: viewport,
                        allowsResistance: true
                    )
                }
                .onEnded { _ in
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.84)) {
                        zoomScale = clampedScale(zoomScale)

                        if isAtFitZoom {
                            panOffset = .zero
                        } else {
                            panOffset = boundedOffset(
                                panOffset,
                                pageSize: pageSize,
                                viewport: viewport
                            )
                        }

                        lastZoomScale = zoomScale
                        lastPanOffset = panOffset
                    }
                },
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let proposedOffset = CGSize(
                        width: lastPanOffset.width + value.translation.width,
                        height: lastPanOffset.height + value.translation.height
                    )

                    panOffset = boundedOffset(
                        proposedOffset,
                        pageSize: pageSize,
                        viewport: viewport,
                        allowsResistance: true
                    )
                }
                .onEnded { value in
                    let projectedOffset = CGSize(
                        width: panOffset.width + (value.predictedEndTranslation.width - value.translation.width) * 0.28,
                        height: panOffset.height + (value.predictedEndTranslation.height - value.translation.height) * 0.28
                    )

                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.86)) {
                        panOffset = boundedOffset(
                            projectedOffset,
                            pageSize: pageSize,
                            viewport: viewport
                        )
                        lastPanOffset = panOffset
                    }
                }
        )
    }

    private func turnPage(by offset: Int) {
        guard !isTurningProgrammatically else {
            return
        }

        let nextPageIndex = clampedPageIndex(currentPageIndex + offset)
        guard nextPageIndex != currentPageIndex else {
            return
        }

        if !isAtFitZoom {
            resetZoom(animated: false)
        }

        programmaticTurnOffset = offset
        programmaticTurnProgress = 0.02

        programmaticTurnTask?.cancel()
        programmaticTurnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, programmaticTurnOffset == offset else {
                return
            }

            let frameCount = 24
            for frame in 1...frameCount {
                guard !Task.isCancelled, programmaticTurnOffset == offset else {
                    return
                }

                let linearProgress = CGFloat(frame) / CGFloat(frameCount)
                let remainingProgress = 1 - linearProgress
                let easedProgress = 1 - (remainingProgress * remainingProgress)
                programmaticTurnProgress = min(1, max(0.02, easedProgress))
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            var transaction = Transaction()
            transaction.animation = nil

            withTransaction(transaction) {
                currentPageIndex = nextPageIndex
                programmaticTurnOffset = 0
                programmaticTurnProgress = 0
                programmaticTurnTask = nil
            }
        }
    }

    private func goToPage(_ pageIndex: Int) {
        let nextIndex = clampedPageIndex(pageIndex)
        guard nextIndex != currentPageIndex else {
            return
        }

        resetZoom(animated: false)
        currentPageIndex = nextIndex
    }

    private func resetZoom(animated: Bool) {
        let updates = {
            zoomScale = minimumScale
            lastZoomScale = minimumScale
            panOffset = .zero
            lastPanOffset = .zero
        }

        if animated {
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func presentGestureHintIfNeeded() {
        guard !readerGestureHintSeen else {
            return
        }

        readerGestureHintSeen = true

        withAnimation(.easeOut(duration: 0.2)) {
            isShowingGestureHint = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            withAnimation(.easeOut(duration: 0.24)) {
                isShowingGestureHint = false
            }
        }
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, totalPageCount - 1))
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

    private func fittedPageSize(in viewport: CGSize) -> CGSize {
        let aspectRatio = imageAspectRatio(for: currentPageIndex)
        let width = max(viewport.width, 1)
        let height = width / aspectRatio
        return CGSize(width: width, height: height)
    }

    private func boundedOffset(
        _ offset: CGSize,
        pageSize: CGSize,
        viewport: CGSize,
        allowsResistance: Bool = false
    ) -> CGSize {
        let bounds = offsetBounds(pageSize: pageSize, viewport: viewport)

        return CGSize(
            width: boundedValue(offset.width, limit: bounds.width, allowsResistance: allowsResistance),
            height: boundedValue(offset.height, limit: bounds.height, allowsResistance: allowsResistance)
        )
    }

    private func offsetBounds(pageSize: CGSize, viewport: CGSize) -> CGSize {
        let visibleSize = CGSize(
            width: max(viewport.width, 1),
            height: max(viewport.height, 1)
        )
        let edgePadding = min(visibleSize.width, visibleSize.height) * panEdgePaddingRatio

        return CGSize(
            width: max(((pageSize.width * zoomScale) - visibleSize.width) / 2, 0) + edgePadding,
            height: max(((pageSize.height * zoomScale) - visibleSize.height) / 2, 0) + edgePadding
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
}

private struct JournalStoryboardVerticalComicViewer: View {
    let storyboards: [GeneratedStoryboard]
    @Binding var currentPageIndex: Int
    let journalTitle: String
    let journalColor: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackCoverImageName: String?
    let pageCountText: String
    let storyboardCountText: String
    let readerPageAspectRatio: CGFloat

    @Environment(\.dismiss) private var dismiss
    @State private var visiblePageIndex: Int

    init(
        storyboards: [GeneratedStoryboard],
        currentPageIndex: Binding<Int>,
        journalTitle: String,
        journalColor: Color,
        coverImage: UIImage?,
        remoteCoverURL: URL?,
        fallbackCoverImageName: String?,
        pageCountText: String,
        storyboardCountText: String,
        readerPageAspectRatio: CGFloat
    ) {
        self.storyboards = storyboards
        _currentPageIndex = currentPageIndex
        self.journalTitle = journalTitle
        self.journalColor = journalColor
        self.coverImage = coverImage
        self.remoteCoverURL = remoteCoverURL
        self.fallbackCoverImageName = fallbackCoverImageName
        self.pageCountText = pageCountText
        self.storyboardCountText = storyboardCountText
        self.readerPageAspectRatio = readerPageAspectRatio
        _visiblePageIndex = State(initialValue: currentPageIndex.wrappedValue)
    }

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .top) {
                Color.black
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            Color.black
                                .frame(height: 64)

                            verticalCoverPage
                                .id(0)
                                .background(pagePositionReader(index: 0))

                            ForEach(Array(storyboards.enumerated()), id: \.element.id) { index, storyboard in
                                let pageIndex = index + 1

                                pageBoundary(pageIndex: pageIndex)

                                Image(uiImage: storyboard.image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.black)
                                    .id(pageIndex)
                                    .background(pagePositionReader(index: pageIndex))
                            }

                            Color.black
                                .frame(height: 44)
                        }
                    }
                    .coordinateSpace(name: "journalVerticalComicScroll")
                    .background(Color.black)
                    .onAppear {
                        visiblePageIndex = clampedPageIndex(currentPageIndex)
                        DispatchQueue.main.async {
                            proxy.scrollTo(visiblePageIndex, anchor: .center)
                        }
                    }
                    .onPreferenceChange(JournalVerticalComicPagePositionPreferenceKey.self) { positions in
                        updateVisiblePageIndex(from: positions, viewportHeight: viewport.size.height)
                    }
                }

                verticalTopBar
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    private var verticalTopBar: some View {
        HStack {
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
            .accessibilityLabel("Close vertical comic view")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var verticalCoverPage: some View {
        JournalStoryboardReaderCoverPage(
            title: journalTitle,
            color: journalColor,
            coverImage: coverImage,
            remoteCoverURL: remoteCoverURL,
            fallbackImageName: fallbackCoverImageName,
            pageCountText: pageCountText,
            storyboardCountText: storyboardCountText
        )
        .aspectRatio(readerPageAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private func pageBoundary(pageIndex: Int) -> some View {
        ZStack {
            Color(white: 0.035)

            Rectangle()
                .fill(Color.white.opacity(0.86))
                .frame(height: 1)
                .padding(.horizontal, 28)

            Text("\(pageIndex) / \(storyboards.count)")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Color(white: 0.035), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                )
        }
        .frame(height: 42)
    }

    private func pagePositionReader(index: Int) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: JournalVerticalComicPagePositionPreferenceKey.self,
                value: [index: proxy.frame(in: .named("journalVerticalComicScroll")).midY]
            )
        }
    }

    private func updateVisiblePageIndex(from positions: [Int: CGFloat], viewportHeight: CGFloat) {
        guard let closest = positions.min(by: { left, right in
            abs(left.value - (viewportHeight / 2)) < abs(right.value - (viewportHeight / 2))
        })?.key else {
            return
        }

        let nextIndex = clampedPageIndex(closest)
        guard nextIndex != visiblePageIndex else {
            return
        }

        visiblePageIndex = nextIndex
        currentPageIndex = nextIndex
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, totalPageCount - 1))
    }

    private var totalPageCount: Int {
        storyboards.count + 1
    }
}

private struct JournalVerticalComicPagePositionPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct JournalStoryboardTurningPage: View {
    let images: [UIImage]
    let journalTitle: String
    let journalColor: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackCoverImageName: String?
    let pageCountText: String
    let storyboardCountText: String
    let pageIndex: Int
    let progress: CGFloat
    let style: DaybookPageFoldStyle

    private let perspective: CGFloat = 0.34

    var body: some View {
        ZStack {
            if showsFrontFace {
                pageView(at: pageIndex)
                    .rotation3DEffect(
                        .degrees(frontRotation),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: rotationAnchor,
                        perspective: perspective
                    )
            }

            if showsBackFace {
                DaybookPagePaperBack()
                    .rotation3DEffect(
                        .degrees(backRotation),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: rotationAnchor,
                        perspective: perspective
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pageView(at pageIndex: Int) -> some View {
        if pageIndex == 0 {
            JournalStoryboardReaderCoverPage(
                title: journalTitle,
                color: journalColor,
                coverImage: coverImage,
                remoteCoverURL: remoteCoverURL,
                fallbackImageName: fallbackCoverImageName,
                pageCountText: pageCountText,
                storyboardCountText: storyboardCountText
            )
        } else if let image = image(at: pageIndex) {
            JournalStoryboardComicPage(image: image)
        }
    }

    private func image(at pageIndex: Int) -> UIImage? {
        let index = min(max(0, pageIndex - 1), max(0, images.count - 1))
        guard images.indices.contains(index) else {
            return nil
        }

        return images[index]
    }

    private var rotationAnchor: UnitPoint {
        switch style {
        case .foldLeft, .unfoldFromLeft:
            return .leading
        case .foldRight:
            return .trailing
        }
    }

    private var showsFrontFace: Bool {
        switch style {
        case .foldLeft, .foldRight:
            return progress < 0.5
        case .unfoldFromLeft:
            return progress >= 0.5
        }
    }

    private var showsBackFace: Bool {
        switch style {
        case .foldLeft, .foldRight:
            return progress >= 0.5
        case .unfoldFromLeft:
            return progress < 0.5
        }
    }

    private var frontRotation: Double {
        switch style {
        case .foldLeft:
            return Double(-min(progress, 0.5) / 0.5 * 90)
        case .unfoldFromLeft:
            return Double(-90 + max(progress - 0.5, 0) / 0.5 * 90)
        case .foldRight:
            return Double(min(progress, 0.5) / 0.5 * 90)
        }
    }

    private var backRotation: Double {
        switch style {
        case .foldLeft:
            return Double(-90 - max(progress - 0.5, 0) / 0.5 * 90)
        case .unfoldFromLeft:
            return Double(-180 + min(progress, 0.5) / 0.5 * 90)
        case .foldRight:
            return Double(90 + max(progress - 0.5, 0) / 0.5 * 90)
        }
    }
}

private struct JournalStoryboardPageTurnView: View {
    let images: [UIImage]
    let journalTitle: String
    let journalColor: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackCoverImageName: String?
    let pageCountText: String
    let storyboardCountText: String
    @Binding var currentPageIndex: Int
    let programmaticTurnOffset: Int
    let programmaticTurnProgress: CGFloat
    @Binding var isPageTurnActive: Bool
    @State private var dragTranslation: CGFloat = 0
    @State private var pendingTurnOffset = 0
    @State private var pendingTurnProgress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let turnWidth = max(1, proxy.size.width)
            let pageTurn = pageTurnState(width: turnWidth)

            turnPageContent(pageTurn: pageTurn)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            dragTranslation = value.translation.width
                        }
                        .onEnded { value in
                            finishPageTurn(value, width: turnWidth)
                        },
                    including: pendingTurnOffset == 0 ? .all : .subviews
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Journal comic page \(currentPageIndex + 1) of \(totalPageCount)")
                .onChange(of: pageTurn.isTurningForward || pageTurn.isTurningBackward || pendingTurnOffset != 0 || programmaticTurnOffset != 0) { turning in
                    isPageTurnActive = turning
                }
                .onAppear {
                    isPageTurnActive = pageTurn.isTurningForward || pageTurn.isTurningBackward
                }
        }
    }

    @ViewBuilder
    private func turnPageContent(
        pageTurn: (progress: CGFloat, isTurningForward: Bool, isTurningBackward: Bool)
    ) -> some View {
        ZStack {
            if let animation = activeTurnAnimation(for: pageTurn) {
                switch animation {
                case .forward(let revealed, let folding):
                    pageView(at: revealed)

                    JournalStoryboardTurningPage(
                        images: images,
                        journalTitle: journalTitle,
                        journalColor: journalColor,
                        coverImage: coverImage,
                        remoteCoverURL: remoteCoverURL,
                        fallbackCoverImageName: fallbackCoverImageName,
                        pageCountText: pageCountText,
                        storyboardCountText: storyboardCountText,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .foldLeft
                    )
                    .zIndex(1)

                case .unfoldPrevious(let revealed, let folding):
                    pageView(at: revealed)

                    JournalStoryboardTurningPage(
                        images: images,
                        journalTitle: journalTitle,
                        journalColor: journalColor,
                        coverImage: coverImage,
                        remoteCoverURL: remoteCoverURL,
                        fallbackCoverImageName: fallbackCoverImageName,
                        pageCountText: pageCountText,
                        storyboardCountText: storyboardCountText,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .unfoldFromLeft
                    )
                    .zIndex(1)

                case .foldCurrentRight(let revealed, let folding):
                    pageView(at: revealed)

                    JournalStoryboardTurningPage(
                        images: images,
                        journalTitle: journalTitle,
                        journalColor: journalColor,
                        coverImage: coverImage,
                        remoteCoverURL: remoteCoverURL,
                        fallbackCoverImageName: fallbackCoverImageName,
                        pageCountText: pageCountText,
                        storyboardCountText: storyboardCountText,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .foldRight
                    )
                    .zIndex(1)
                }
            } else {
                pageView(at: currentPageIndex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pageView(at pageIndex: Int) -> some View {
        if pageIndex == 0 {
            JournalStoryboardReaderCoverPage(
                title: journalTitle,
                color: journalColor,
                coverImage: coverImage,
                remoteCoverURL: remoteCoverURL,
                fallbackImageName: fallbackCoverImageName,
                pageCountText: pageCountText,
                storyboardCountText: storyboardCountText
            )
            .id(pageIndex)
        } else if let image = image(at: pageIndex) {
            JournalStoryboardComicPage(image: image)
                .id(pageIndex)
        }
    }

    private func pageTurnState(width: CGFloat) -> (progress: CGFloat, isTurningForward: Bool, isTurningBackward: Bool) {
        if programmaticTurnOffset != 0 {
            return (
                min(1, max(0.02, programmaticTurnProgress)),
                programmaticTurnOffset > 0,
                programmaticTurnOffset < 0
            )
        }

        if pendingTurnOffset != 0 {
            return (
                min(1, max(0.02, pendingTurnProgress)),
                pendingTurnOffset > 0,
                pendingTurnOffset < 0
            )
        }

        let progress = min(1, abs(dragTranslation) / (width * 0.62))
        return (
            max(0.02, progress),
            dragTranslation < -4,
            dragTranslation > 4
        )
    }

    private func activeTurnAnimation(
        for pageTurn: (progress: CGFloat, isTurningForward: Bool, isTurningBackward: Bool)
    ) -> DaybookPageTurnAnimation? {
        if pageTurn.isTurningForward {
            guard currentPageIndex < totalPageCount - 1 else { return nil }
            return .forward(revealed: currentPageIndex + 1, folding: currentPageIndex)
        }

        if pageTurn.isTurningBackward {
            guard currentPageIndex > 0 else { return nil }
            return .unfoldPrevious(revealed: currentPageIndex, folding: currentPageIndex - 1)
        }

        return nil
    }

    private func finishPageTurn(_ value: DragGesture.Value, width: CGFloat) {
        guard pendingTurnOffset == 0 else {
            return
        }

        let predicted = value.predictedEndTranslation.width
        let threshold = max(64, width * 0.22)
        let releaseProgress = min(1, abs(value.translation.width) / (width * 0.62))

        if predicted < -threshold, currentPageIndex < totalPageCount - 1 {
            completeDragTurn(offset: 1, from: releaseProgress)
        } else if predicted > threshold, currentPageIndex > 0 {
            completeDragTurn(offset: -1, from: releaseProgress)
        } else {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88)) {
                dragTranslation = 0
            }
        }
    }

    private func completeDragTurn(offset: Int, from releaseProgress: CGFloat) {
        pendingTurnOffset = offset
        pendingTurnProgress = max(0.02, releaseProgress)
        dragTranslation = 0

        let remaining = max(0, 1 - releaseProgress)
        let duration = max(0.12, 0.28 * remaining)

        withAnimation(.easeInOut(duration: duration)) {
            pendingTurnProgress = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard pendingTurnOffset == offset else {
                return
            }

            var transaction = Transaction()
            transaction.animation = nil

            withTransaction(transaction) {
                currentPageIndex = clampedPageIndex(currentPageIndex + offset)
                pendingTurnOffset = 0
                pendingTurnProgress = 0
            }
        }
    }

    private func image(at pageIndex: Int) -> UIImage? {
        let index = clampedPageIndex(pageIndex) - 1
        guard images.indices.contains(index) else {
            return nil
        }

        return images[index]
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, totalPageCount - 1))
    }

    private var totalPageCount: Int {
        images.count + 1
    }
}

private struct JournalStoryboardComicPage: View {
    let image: UIImage

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.black.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 20)
                }
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.12), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                    .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct JournalStoryboardReaderCoverPage: View {
    let title: String
    let color: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    let pageCountText: String
    let storyboardCountText: String
    var showsDecorativeCopy = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                coverFill
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.5),
                        Color.black.opacity(0.2),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(22, proxy.size.width * 0.13))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(false)

                titleScrim(in: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1)
                    .padding(.leading, max(14, proxy.size.width * 0.075))
                    .blendMode(.screen)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private func titleScrim(in size: CGSize) -> some View {
        let bottomPadding = max(18, size.height * 0.082)
        let horizontalPadding = max(10, size.width * 0.055)
        let scrimHeight = showsDecorativeCopy
            ? max(118, size.height * 0.34)
            : max(72, size.height * 0.28)

        return titleBackdrop
            .overlay(alignment: .bottom) {
                VStack(spacing: max(8, size.height * 0.022)) {
                    Text(title.uppercased())
                        .font(.system(size: max(16, min(40, size.width * 0.116)), weight: .heavy, design: .serif))
                        .foregroundStyle(Color.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.62)
                        .multilineTextAlignment(.center)
                        .shadow(color: Color.black.opacity(0.42), radius: 10, y: 3)
                        .padding(.horizontal, max(18, size.width * 0.11))

                    if showsDecorativeCopy {
                        HStack(spacing: 10) {
                            coverStat(systemName: "book.pages", text: pageCountText)
                            coverStat(systemName: "photo.on.rectangle", text: storyboardCountText)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: scrimHeight)
            .allowsHitTesting(false)
    }

    private var titleBackdrop: some View {
        LinearGradient(
            colors: [
                Color.clear,
                Color.black.opacity(hasImageCover ? 0.50 : 0.18),
                Color.black.opacity(hasImageCover ? 0.74 : 0.28)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var hasImageCover: Bool {
        coverImage != nil || remoteCoverURL != nil || fallbackImageName != nil
    }

    @ViewBuilder
    private var coverFill: some View {
        if let coverImage {
            Image(uiImage: coverImage)
                .resizable()
                .scaledToFill()
        } else if let remoteCoverURL {
            RemoteCoverImage(url: remoteCoverURL, placeholderColor: color)
        } else if let fallbackImageName {
            Image(fallbackImageName)
                .resizable()
                .scaledToFill()
        } else {
            color
        }
    }

    private func coverStat(systemName: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))

            Text(text)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color.black.opacity(0.24), in: Capsule())
    }
}

enum DailyJournalData {
    static func allChapters() -> [PrototypeChapter] {
        UserChapterStore.load().map(chapterWithStoredEntries)
    }

    static func journalDate(dayOffset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
    }

    static func dateTitledChapter(from chapter: PrototypeChapter, dayOffset: Int) -> PrototypeChapter {
        let date = journalDate(dayOffset: dayOffset)
        return PrototypeChapter(
            id: chapter.id,
            title: Calendar.current.isDateInToday(date)
                ? "Today"
                : date.formatted(.dateTime.weekday(.wide)),
            subtitle: date.formatted(date: .complete, time: .omitted),
            color: chapter.color,
            symbol: "calendar",
            coverImageName: chapter.coverImageName,
            remoteCover: chapter.remoteCover,
            kind: .journal,
            isFavorite: chapter.isFavorite,
            createdAt: chapter.createdAt,
            updatedAt: chapter.updatedAt,
            entries: chapter.entries
        )
    }

    static func detailView(
        for chapter: PrototypeChapter,
        dayOffset: Int,
        storyboardGenerationStatus: Binding<StoryboardGenerationGlobalStatus?> = .constant(nil),
        onNewEntryPresentationChange: @escaping (Bool) -> Void = { _ in },
        onCreateEntryRequested: ((CreateEntryPresentation) -> Void)? = nil,
        onChapterUpdated: @escaping (PrototypeChapter) -> Void = { _ in },
        onOpenExistingEntry: ((CreateEntryDraft, Bool, UIImage?, CreateEntryPresentation) -> Void)? = nil,
        contentMode: JournaltopiaContentMode = .user,
        onAddEntry: @escaping (PrototypeEntry) -> Void
    ) -> some View {
        let datedChapter = dateTitledChapter(from: chapter, dayOffset: dayOffset)

        return PrototypeChapterDetailView(
            chapter: datedChapter.copy(title: chapter.title),
            entryDate: journalDate(dayOffset: dayOffset),
            presentation: .dailyJournal,
            storyboardGenerationStatus: storyboardGenerationStatus,
            onNewEntryPresentationChange: onNewEntryPresentationChange,
            onCreateEntryRequested: onCreateEntryRequested,
            onChapterUpdated: onChapterUpdated,
            onOpenExistingEntry: onOpenExistingEntry,
            contentMode: contentMode,
            onCreateStory: onAddEntry
        )
    }

    private static func chapterWithStoredEntries(_ chapter: PrototypeChapter) -> PrototypeChapter {
        var chapter = chapter
        let visibleSampleEntries = chapter.entries.filter {
            !DeletedSampleEntryStore.contains($0, in: chapter.title)
        }
        chapter.entries = StoryEntryStore.load(for: chapter.title) + visibleSampleEntries
        return chapter
    }

}

private enum LegacySystemJournalIDs {
    static let all: Set<UUID> = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    ]
}

private enum DaybookPageTurnAnimation {
    case forward(revealed: Int, folding: Int)
    case unfoldPrevious(revealed: Int, folding: Int)
    case foldCurrentRight(revealed: Int, folding: Int)
}

private enum DaybookPageFoldStyle {
    case foldLeft
    case unfoldFromLeft
    case foldRight
}

private struct DaybookPagePaperBack: View {
    var body: some View {
        Color(red: 0.96, green: 0.94, blue: 0.88)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private let regularSetImageNames: [String] = [
    "IMG_9080",
    "IMG_9144",
    "IMG_2390",
    "IMG_2382 2",
    "IMG_9131",
    "IMG_9113",
    "IMG_9127",
    "IMG_9126",
    "IMG_9114",
    "IMG_9102",
    "IMG_2385 2",
    "IMG_9140",
    "IMG_2214"
]

private func journalSampleImages(startIndex: Int, count: Int) -> [String] {
    guard !regularSetImageNames.isEmpty else {
        return []
    }

    return (0..<count).map { offset in
        regularSetImageNames[(startIndex + offset) % regularSetImageNames.count]
    }
}

private enum EntryDisplayItem: Identifiable {
    case local(CreateEntryDraft, cloudEntry: JournalEntry?)
    case cloud(JournalEntry)

    var id: UUID {
        switch self {
        case .local(let entry, _):
            return entry.id
        case .cloud(let entry):
            return entry.clientEntryID
        }
    }

    var localDraftID: UUID? {
        if case .local(let entry, _) = self {
            return entry.id
        }

        return nil
    }

    var isLocal: Bool {
        localDraftID != nil
    }

    var status: String {
        switch self {
        case .local(let entry, let cloudEntry):
            if cloudEntry?.status == JournalEntryStatus.archived.rawValue {
                return JournalEntryStatus.archived.rawValue
            }
            if entry.status == JournalEntryStatus.completed.rawValue {
                return JournalEntryStatus.completed.rawValue
            }
            return cloudEntry?.status ?? entry.status
        case .cloud(let entry):
            return entry.status
        }
    }

    var cloudEntry: JournalEntry? {
        switch self {
        case .local(_, let cloudEntry):
            return cloudEntry
        case .cloud(let entry):
            return entry
        }
    }

    var createdAt: Date {
        switch self {
        case .local(let entry, let cloudEntry):
            return cloudEntry?.createdAt ?? entry.createdAt
        case .cloud(let entry):
            return entry.createdAt
        }
    }

    var updatedAt: Date {
        switch self {
        case .local(let entry, let cloudEntry):
            return cloudEntry?.updatedAt ?? entry.updatedAt
        case .cloud(let entry):
            return entry.updatedAt
        }
    }

    var entry: CreateEntryDraft {
        switch self {
        case .local(let entry, let cloudEntry):
            if let cloudEntry {
                return CreateEntryDraft.fromCloud(cloudEntry, thumbnail: entry.thumbnail)
            }

            return entry
        case .cloud(let entry):
            return CreateEntryDraft.fromCloud(entry)
        }
    }
}

private struct JournalDetailThumbnailSignature: Equatable {
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let fontChoiceRawValue: String?
    let textColorIndex: Int?
    let textSize: Double?
    let paperStyleRawValue: String?
    let paperColorIndex: Int?
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let textAlignmentRawValue: String
    let updatedAt: Date

    init(entry: CreateEntryDraft) {
        title = entry.title
        text = entry.text
        richText = entry.richText
        fontChoiceRawValue = entry.fontChoiceRawValue
        textColorIndex = entry.textColorIndex
        textSize = entry.textSize
        paperStyleRawValue = entry.paperStyleRawValue
        paperColorIndex = entry.paperColorIndex
        isBold = entry.isBold
        isItalic = entry.isItalic
        isUnderlined = entry.isUnderlined
        isStrikethrough = entry.isStrikethrough
        isHighlighted = entry.isHighlighted
        textAlignmentRawValue = entry.textAlignmentRawValue
        updatedAt = entry.updatedAt
    }
}

private struct JournalDetailRenderedThumbnail {
    let signature: JournalDetailThumbnailSignature
    let thumbnail: UIImage?
}

private struct EntryDropDelegate: DropDelegate {
    let item: EntryDisplayItem
    let items: [EntryDisplayItem]
    @Binding var draggingEntryID: UUID?
    let isEnabled: Bool
    let onReorder: (UUID, UUID) -> Void

    func dropEntered(info _: DropInfo) {
        guard
            isEnabled,
            let draggingEntryID,
            draggingEntryID != item.id,
            items.contains(where: { $0.id == draggingEntryID })
        else {
            return
        }

        onReorder(draggingEntryID, item.id)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        isEnabled ? DropProposal(operation: .move) : nil
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggingEntryID = nil
        return isEnabled
    }
}

private struct EntryOpeningPreview: Identifiable {
    let entry: CreateEntryDraft
    let sortOption: EntrySortOption
    let isCompleted: Bool
    let storyboardImage: UIImage?

    var id: UUID {
        entry.id
    }

    var title: String {
        entryDisplayTitle(entry)
    }

    var dateText: String {
        entryPreviewDateText(entry, sortOption: sortOption)
    }
}

private extension CreateEntryDraft {
    func prototypeEntry() -> PrototypeEntry {
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d"

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        let displayDate = datePrecision == .noDate ? createdAt : date
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)

        return PrototypeEntry(
            id: id,
            weekday: weekdayFormatter.string(from: displayDate).uppercased(),
            day: dayFormatter.string(from: displayDate),
            title: entryDisplayTitle(self),
            body: text,
            richText: richText,
            time: timeFormatter.string(from: displayDate),
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            imageNames: [],
            createdAt: createdAt
        )
    }

    static func fromCloud(_ entry: JournalEntry, thumbnail: UIImage? = nil) -> CreateEntryDraft {
        CreateEntryDraft(
            id: entry.clientEntryID,
            title: entry.title ?? "",
            text: entry.content ?? "",
            richText: entry.richText ?? entry.content.map { NotebookRichTextDocument(text: $0) },
            photos: [],
            artStyle: entry.artStyle ?? "Anime",
            location: entry.location ?? "",
            date: entry.entryDate ?? entry.createdAt,
            datePrecision: entry.datePrecision.flatMap(EntryDatePrecision.init(rawValue:)) ?? .exact,
            savesDraft: entry.savesDraft ?? true,
            isPrivate: entry.isPrivate ?? true,
            status: entry.status,
            fontChoiceRawValue: entry.fontChoiceRawValue,
            textColorIndex: entry.textColorIndex,
            textSize: entry.textSize,
            paperStyleRawValue: entry.paperStyleRawValue,
            paperColorIndex: entry.paperColorIndex,
            isBold: entry.isBold ?? false,
            isItalic: entry.isItalic ?? false,
            isUnderlined: entry.isUnderlined ?? false,
            isStrikethrough: entry.isStrikethrough ?? false,
            isHighlighted: entry.isHighlighted ?? false,
            textAlignmentRawValue: entry.textAlignmentRawValue ?? "leading",
            thumbnail: thumbnail,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            displayOrder: entry.displayOrder
        )
    }

    func replacingThumbnail(_ thumbnail: UIImage?) -> CreateEntryDraft {
        CreateEntryDraft(
            id: id,
            title: title,
            text: text,
            richText: richText,
            photos: photos,
            artStyle: artStyle,
            location: location,
            date: date,
            datePrecision: datePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivate,
            status: status,
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: textAlignmentRawValue,
            thumbnail: thumbnail,
            createdAt: createdAt,
            updatedAt: updatedAt,
            displayOrder: displayOrder
        )
    }

    func replacingTitle(_ title: String, thumbnail: UIImage?) -> CreateEntryDraft {
        CreateEntryDraft(
            id: id,
            title: title,
            text: text,
            richText: richText,
            photos: photos,
            characters: characters,
            artStyle: artStyle,
            location: location,
            date: date,
            datePrecision: datePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivate,
            status: status,
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: textAlignmentRawValue,
            thumbnail: thumbnail,
            createdAt: createdAt,
            updatedAt: Date(),
            displayOrder: displayOrder
        )
    }

    func duplicateSavePayload(id duplicateID: UUID) -> EntryDraftSavePayload {
        EntryDraftSavePayload(
            id: duplicateID,
            createdAt: Date(),
            title: duplicateTitle,
            text: text,
            richText: richText,
            photos: photos,
            characters: characters,
            artStyle: artStyle,
            location: location,
            date: date,
            datePrecision: datePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivate,
            fontChoiceRawValue: fontChoiceRawValue ?? "sans",
            textColorIndex: textColorIndex ?? 0,
            textSize: textSize ?? 1,
            paperStyleRawValue: paperStyleRawValue ?? "default",
            paperColorIndex: paperColorIndex ?? 0,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: textAlignmentRawValue
        )
    }

    private var duplicateTitle: String {
        let baseTitle = entryDisplayTitle(self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseTitle.isEmpty else {
            return "Untitled Entry Copy"
        }

        return "\(baseTitle) Copy"
    }
}

private enum EntriesCloudFetchCache {
    private static let freshnessInterval: TimeInterval = 300
    private static var entrySummariesByKey: [EntryQueryKey: CachedEntrySummaries] = [:]
    private static var storyboardLoadDateByUserID: [UUID: Date] = [:]

    static func entrySummaries(for key: EntryQueryKey) -> CachedEntrySummaries? {
        guard
            let cached = cachedEntrySummaries(for: key),
            Date().timeIntervalSince(cached.loadedAt) < freshnessInterval
        else {
            return nil
        }

        return cached
    }

    static func staleEntrySummaries(for key: EntryQueryKey) -> CachedEntrySummaries? {
        cachedEntrySummaries(for: key)
    }

    static func hasFreshEntrySummaries(for key: EntryQueryKey) -> Bool {
        entrySummaries(for: key) != nil
    }

    static func storeEntrySummaries(
        _ entries: [JournalEntry],
        counts: JournalEntrySummaryCounts?,
        hasMore: Bool,
        nextOffset: Int,
        for key: EntryQueryKey
    ) {
        let cached = CachedEntrySummaries(
            entries: entries,
            counts: counts,
            hasMore: hasMore,
            nextOffset: nextOffset,
            loadedAt: Date()
        )
        entrySummariesByKey[key] = cached
        storeEntrySummariesOnDisk(cached, for: key)
    }

    static func shouldLoadStoryboards(for userID: UUID) -> Bool {
        guard let loadedAt = storyboardLoadDateByUserID[userID] else {
            return true
        }

        return Date().timeIntervalSince(loadedAt) >= freshnessInterval
    }

    static func markStoryboardsLoaded(for userID: UUID) {
        storyboardLoadDateByUserID[userID] = Date()
    }

    static func invalidate(for userID: UUID?) {
        guard let userID else {
            entrySummariesByKey.removeAll()
            storyboardLoadDateByUserID.removeAll()
            return
        }

        entrySummariesByKey = entrySummariesByKey.filter { $0.key.userID != userID }
        storyboardLoadDateByUserID.removeValue(forKey: userID)
        removeDiskEntrySummaries(for: userID)
    }

    struct EntryQueryKey: Hashable {
        let userID: UUID
        let sort: EntrySummarySort
        let statusFilter: EntrySummaryStatusFilter
    }

    struct CachedEntrySummaries {
        let entries: [JournalEntry]
        let counts: JournalEntrySummaryCounts?
        let hasMore: Bool
        let nextOffset: Int
        let loadedAt: Date
    }

    private static func cachedEntrySummaries(for key: EntryQueryKey) -> CachedEntrySummaries? {
        if let cached = entrySummariesByKey[key] {
            return cached
        }

        guard let cached = diskEntrySummaries(for: key) else {
            return nil
        }

        entrySummariesByKey[key] = cached
        return cached
    }

    private static func diskEntrySummaries(for key: EntryQueryKey) -> CachedEntrySummaries? {
        guard let diskCache = loadDiskCache()[key.diskKey] else {
            return nil
        }

        return CachedEntrySummaries(
            entries: diskCache.entries,
            counts: diskCache.counts,
            hasMore: diskCache.hasMore,
            nextOffset: diskCache.nextOffset,
            loadedAt: diskCache.loadedAt
        )
    }

    private static func storeEntrySummariesOnDisk(_ cached: CachedEntrySummaries, for key: EntryQueryKey) {
        var diskCache = loadDiskCache()
        diskCache[key.diskKey] = DiskCachedEntrySummaries(
            entries: cached.entries,
            counts: cached.counts,
            hasMore: cached.hasMore,
            nextOffset: cached.nextOffset,
            loadedAt: cached.loadedAt
        )
        saveDiskCache(diskCache)
    }

    private static func removeDiskEntrySummaries(for userID: UUID) {
        var diskCache = loadDiskCache()
        diskCache = diskCache.filter { !$0.key.hasPrefix(userID.uuidString.lowercased() + "|") }
        saveDiskCache(diskCache)
    }

    private static func loadDiskCache() -> [String: DiskCachedEntrySummaries] {
        guard
            let data = try? Data(contentsOf: diskCacheURL),
            let cache = try? JSONDecoder().decode([String: DiskCachedEntrySummaries].self, from: data)
        else {
            return [:]
        }

        return cache
    }

    private static func saveDiskCache(_ cache: [String: DiskCachedEntrySummaries]) {
        guard let data = try? JSONEncoder().encode(cache) else {
            return
        }

        let directoryURL = diskCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        try? data.write(to: diskCacheURL, options: [.atomic])
    }

    private static var diskCacheURL: URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Journaltopia", isDirectory: true)
            .appendingPathComponent("EntriesCloudFetchCache.json")
    }

    private struct DiskCachedEntrySummaries: Codable {
        let entries: [JournalEntry]
        let counts: JournalEntrySummaryCounts?
        let hasMore: Bool
        let nextOffset: Int
        let loadedAt: Date
    }
}

private enum DeletedAuthoringSampleEntryStore {
    private static let storageKey = "JournaltopiaDeletedAuthoringSampleEntries"

    static func load() -> Set<UUID> {
        guard let rawValues = UserDefaults.standard.stringArray(forKey: storageKey) else {
            return []
        }

        return Set(rawValues.compactMap(UUID.init(uuidString:)))
    }

    static func contains(_ id: UUID) -> Bool {
        load().contains(id)
    }

    static func add(_ id: UUID) {
        var ids = load()
        ids.insert(id)
        save(ids)
    }

    static func remove(_ id: UUID) {
        var ids = load()
        ids.remove(id)
        save(ids)
    }

    private static func save(_ ids: Set<UUID>) {
        UserDefaults.standard.set(
            ids.map(\.uuidString).sorted(),
            forKey: storageKey
        )
    }
}

private extension EntriesCloudFetchCache.EntryQueryKey {
    var diskKey: String {
        [
            userID.uuidString.lowercased(),
            sort.cacheIdentifier,
            statusFilter.cacheIdentifier
        ].joined(separator: "|")
    }
}

private extension EntrySummarySort {
    var cacheIdentifier: String {
        switch self {
        case .entryDate:
            return "entryDate"
        case .entryDateAscending:
            return "entryDateAscending"
        case .createdAt:
            return "createdAt"
        case .createdAtAscending:
            return "createdAtAscending"
        case .updatedAt:
            return "updatedAt"
        case .updatedAtAscending:
            return "updatedAtAscending"
        case .manual:
            return "manual"
        }
    }
}

private extension EntrySummaryStatusFilter {
    var cacheIdentifier: String {
        switch self {
        case .all:
            return "all"
        case .drafts:
            return "drafts"
        case .completed:
            return "completed"
        case .addToJournal:
            return "addToJournal"
        }
    }
}

private enum EntriesSessionMemoryCache {
    private static var snapshotsByQueryKey: [EntriesCloudFetchCache.EntryQueryKey: Snapshot] = [:]
    private static var mostRecentQueryKey: EntriesCloudFetchCache.EntryQueryKey?

    static func snapshot(for queryKey: EntriesCloudFetchCache.EntryQueryKey) -> Snapshot? {
        snapshotsByQueryKey[queryKey]
    }

    /// The last snapshot stored, whichever query it belonged to.
    ///
    /// `EntriesView` seeds its `@State` from this when it is built, which is the only way to have
    /// content in the *first* rendered frame: the keyed restore happens in `onAppear`, and SwiftUI
    /// has already drawn the view once by then — with empty arrays, which render as "No Entries".
    /// That one frame is the flash on returning to the tab.
    ///
    /// Unkeyed because the query key needs the signed-in user, and `@State` initial values are
    /// evaluated before the environment exists. Being occasionally wrong is safe: `onAppear` compares
    /// the real key and reloads when it differs, so a mismatch costs a frame and never persists. It
    /// cannot leak across accounts either — signing out purges this cache outright.
    static func mostRecentSnapshot() -> Snapshot? {
        guard let mostRecentQueryKey else {
            return nil
        }

        return snapshotsByQueryKey[mostRecentQueryKey]
    }

    static func store(_ snapshot: Snapshot, for queryKey: EntriesCloudFetchCache.EntryQueryKey) {
        snapshotsByQueryKey[queryKey] = snapshot
        mostRecentQueryKey = queryKey
    }

    static func invalidate(userID: UUID?) {
        guard let userID else {
            snapshotsByQueryKey.removeAll()
            mostRecentQueryKey = nil
            return
        }

        snapshotsByQueryKey = snapshotsByQueryKey.filter { $0.key.userID != userID }
        if mostRecentQueryKey?.userID == userID {
            mostRecentQueryKey = nil
        }
    }

    struct Snapshot {
        let entries: [CreateEntryDraft]
        let sampleEntries: [CreateEntryDraft]
        let sampleStoryboardsByEntryID: [UUID: [GeneratedStoryboard]]
        let completedStoryboards: [GeneratedStoryboard]
        let storyboardCountsByClientEntryID: [UUID: Int]
        let cloudEntries: [JournalEntry]
        let cloudEntryCounts: JournalEntrySummaryCounts?
        let cloudEntryThumbnails: [UUID: UIImage]
        let cloudEntryThumbnailVersions: [UUID: String]
        let cloudStoryboardClientIDs: Set<UUID>
        let failedCloudStoryboardClientIDs: Set<UUID>
        let hasMoreCloudEntries: Bool
        let nextCloudEntryOffset: Int
        let cloudEntriesErrorMessage: String?
    }
}

/// `LocalUserDataPurge`'s hook into this file.
///
/// `EntriesCloudFetchCache`, `EntriesSessionMemoryCache` and `JournalRemoteCoverImageCache` are
/// file-private and live as long as the process does. Deleting their disk backing on sign-out is not
/// enough on its own: the copies already in memory hold the previous account's entries, thumbnails
/// and covers, and would keep being served to the next account until the app was killed. Nothing but
/// the sign-out purge should call this.
enum JournalLocalCachePurge {
    static func purgeInMemoryCaches() {
        EntriesCloudFetchCache.invalidate(for: nil)
        EntriesSessionMemoryCache.invalidate(userID: nil)
        JournalRemoteCoverImageCache.removeAll()
    }
}

private enum EntriesCloudThumbnailDiskCache {
    static func image(for entry: JournalEntry) -> UIImage? {
        guard entry.thumbnailStoragePath != nil else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL(for: entry)) else {
            return nil
        }

        return UIImage(data: data)
    }

    static func store(_ image: UIImage, for entry: JournalEntry) {
        guard entry.thumbnailStoragePath != nil else {
            return
        }

        guard let data = image.journaltopiaPreparedJPEGData(compressionQuality: 0.86) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(for: entry), options: [.atomic])
        } catch {
            print("[Journaltopia] Entry thumbnail cache write failed: \(error.localizedDescription)")
        }
    }

    private static var cacheDirectory: URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Journaltopia", isDirectory: true)
            .appendingPathComponent("CloudEntryThumbnails", isDirectory: true)
    }

    private static func fileURL(for entry: JournalEntry) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(for: entry))
    }

    private static func cacheKey(for entry: JournalEntry) -> String {
        let updatedMilliseconds = Int((entry.thumbnailUpdatedAt ?? entry.updatedAt).timeIntervalSince1970 * 1000)
        return [
            entry.userID.uuidString.lowercased(),
            entry.clientEntryID.uuidString.lowercased(),
            entry.thumbnailStoragePath ?? "missing",
            "\(updatedMilliseconds)"
        ]
        .joined(separator: "_")
        .map { character in
            character.isLetter || character.isNumber || character == "." ? character : "_"
        }
        .reduce(into: "") { $0.append($1) } + ".jpg"
    }
}

struct EntriesView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @Binding var selectedPage: StoryPage
    @Binding var isDraftSaved: Bool
    @Binding var activeDraftID: UUID?
    @Binding var completedEntryOpenedStoryboardImage: UIImage?
    @Binding var isOpeningEntryFromEntries: Bool
    @Binding var isOpeningCompletedEntryFromEntries: Bool
    var contentMode: JournaltopiaContentMode = .user
    @EnvironmentObject private var signInGate: SignInGate

    private var isSampleAuthorMode: Bool {
        contentMode.isSampleAuthoring
    }

    private let thumbnailRendererVersion = 14
    private let thumbnailRendererVersionKey = "JournaltopiaEntryThumbnailRendererVersion"

    // Seeded from the last session snapshot rather than starting empty. These are `@State`
    // initialisers, so they run when SwiftUI builds the view — before the first frame is drawn, and
    // before `onAppear` gets a chance to restore anything. Starting empty is what made a return to
    // this tab paint "No Entries" for a frame and then swap in content that had been in memory the
    // whole time. `onAppear` still does the real, key-checked restore immediately afterwards.
    @State private var showsPrototypeData = true
    @State private var entries: [CreateEntryDraft] = EntriesSessionMemoryCache.mostRecentSnapshot()?.entries ?? []
    @State private var sampleEntries: [CreateEntryDraft] = EntriesSessionMemoryCache.mostRecentSnapshot()?.sampleEntries ?? []
    @State private var sampleStoryboardsByEntryID: [UUID: [GeneratedStoryboard]] =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.sampleStoryboardsByEntryID ?? [:]
    @State private var completedStoryboards: [GeneratedStoryboard] =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.completedStoryboards ?? []
    @State private var storyboardCountsByClientEntryID: [UUID: Int] =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.storyboardCountsByClientEntryID ?? [:]
    @State private var cloudStoryboardClientIDs: Set<UUID> =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.cloudStoryboardClientIDs ?? []
    @State private var failedCloudStoryboardClientIDs: Set<UUID> =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.failedCloudStoryboardClientIDs ?? []
    @State private var editMode: EditMode = .inactive
    @State private var entryBeingRenamed: CreateEntryDraft?
    @State private var renamedEntryTitle = ""
    @State private var temporaryOpenedSampleEntryID: UUID?
    @State private var entriesPendingDeletion: [EntryDisplayItem] = []
    @State private var entryDeleteErrorMessage: String?
    @State private var entryDuplicateErrorMessage: String?
    @State private var isDuplicatingSelectedEntries = false
    @State private var draggingEntryID: UUID?
    @State private var manualEntryOrderOverrides: [UUID: Int] = [:]
    @State private var manualEntryOrderSaveTask: Task<Void, Never>?
    @State private var entryRenameErrorMessage: String?
    @State private var entryIDsBeingDeleted: Set<UUID> = []
    @State private var entryIDsBeingRenamed: Set<UUID> = []
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var isShowingAddSelectedEntriesToJournalSheet = false
    @State private var selectedEntriesJournalTitle: String?
    @State private var selectedEntriesJournalTitles: Set<String> = []
    @State private var cloudEntries: [JournalEntry] = EntriesSessionMemoryCache.mostRecentSnapshot()?.cloudEntries ?? []
    @State private var cloudEntryCounts: JournalEntrySummaryCounts? = EntriesSessionMemoryCache.mostRecentSnapshot()?.cloudEntryCounts
    @State private var unjournaledEntryIDs: Set<UUID> = []
    @State private var cloudEntryThumbnails: [UUID: UIImage] =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.cloudEntryThumbnails ?? [:]
    @State private var cloudEntryThumbnailVersions: [UUID: String] =
        EntriesSessionMemoryCache.mostRecentSnapshot()?.cloudEntryThumbnailVersions ?? [:]
    @State private var isLoadingCloudEntries = false
    /// Tracked separately from ``isLoadingCloudEntries`` because the two are genuinely different
    /// loads, and conflating them is what put "No Entries" on screen while the sample pack was in
    /// flight: the signed-out path leaves the cloud flag false, so an empty list read as *empty*
    /// rather than as *not loaded yet*.
    @State private var isLoadingSampleContent = false
    @State private var isLoadingMoreCloudEntries = false
    @State private var hasMoreCloudEntries = EntriesSessionMemoryCache.mostRecentSnapshot()?.hasMoreCloudEntries ?? true
    @State private var nextCloudEntryOffset = EntriesSessionMemoryCache.mostRecentSnapshot()?.nextCloudEntryOffset ?? 0
    /// Whether a load has been attempted for the current mode yet.
    ///
    /// A first visit has no snapshot to seed from, so without this an empty list on the first frame
    /// still reads as "No Entries" before anything has even been asked for.
    @State private var hasAttemptedEntriesLoad = false
    @State private var cloudEntriesErrorMessage: String?
    @State private var openingEntryPreview: EntryOpeningPreview?
    @State private var isFinishingEntryOpening = false
    @State private var hasLoadedEntriesForSession = false
    @State private var loadedEntryQueryKey: EntriesCloudFetchCache.EntryQueryKey?
    @State private var entryThumbnailBackfillTask: Task<Void, Never>?
    @State private var cloudEntryThumbnailBackfillTask: Task<Void, Never>?
    @State private var completedStoryboardLoadTask: Task<Void, Never>?
    @State private var sampleContentLoadTask: Task<Void, Never>?
    @State private var cloudThumbnailIDsBeingLoaded: Set<UUID> = []
    @State private var selectedEntryTabRawValue = EntriesTab.all.rawValue
    private let cloudEntriesPageSize = 30
    @AppStorage("JournaltopiaSelectedEntryLayout") private var selectedEntryLayoutRawValue = JournalEntryLayout.grid.rawValue
    @AppStorage("JournaltopiaSelectedEntrySort") private var selectedEntrySortRawValue = EntrySortOption.cloudCreated.rawValue
    @AppStorage("JournaltopiaEntriesSampleBannerDismissed") private var isSampleBannerDismissed = false
    @AppStorage("JournaltopiaEntriesSamplesCompleted") private var hasCompletedEntriesSamples = false

    private var selectedEntryLayout: JournalEntryLayout {
        get {
            JournalEntryLayout(rawValue: selectedEntryLayoutRawValue) ?? .grid
        }
        nonmutating set {
            selectedEntryLayoutRawValue = newValue.rawValue
        }
    }

    private var selectedEntryTab: EntriesTab {
        get {
            EntriesTab(rawValue: selectedEntryTabRawValue) ?? .all
        }
        nonmutating set {
            selectedEntryTabRawValue = newValue.rawValue
        }
    }

    private var selectedEntrySort: EntrySortOption {
        get {
            EntrySortOption(rawValue: selectedEntrySortRawValue)?.availableEntriesSelection ?? .cloudCreated
        }
        nonmutating set {
            selectedEntrySortRawValue = newValue.rawValue
        }
    }

    private func dismissAnyKeyboard() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .endEditing(true)
    }

    var body: some View {
        entriesScreenWithAlerts
    }

    private var entriesScreenWithAlerts: some View {
        entriesScreenWithPresentation
            .alert("Rename Entry", isPresented: isRenameEntryAlertPresented) {
                renameEntryAlertActions
            } message: {
                renameEntryAlertMessage
            }
            .alert(deleteEntryAlertTitle, isPresented: isDeleteEntryAlertPresented) {
                deleteEntryAlertActions
            } message: {
                Text(deleteEntryAlertMessage)
            }
            .alert("Could Not Duplicate", isPresented: isDuplicateEntryAlertPresented) {
                Button("OK") {
                    entryDuplicateErrorMessage = nil
                }
            } message: {
                Text(entryDuplicateErrorMessage ?? "Could not duplicate one or more entries.")
            }
    }

    private var entriesScreenWithPresentation: some View {
        entriesScreenWithLifecycle
            .sheet(isPresented: $isShowingAddSelectedEntriesToJournalSheet) {
                NavigationStack {
                    addSelectedEntriesToJournalDestination
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }

    private var entriesScreenWithLifecycle: some View {
        entriesScreen
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.editMode, $editMode)
            .onAppear {
                loadEntriesForCurrentPageIfNeeded()
            }
            .onChange(of: selectedPage) { newPage in
                handleSelectedPageChange(newPage)
            }
            .onChange(of: activeDraftID) { newDraftID in
                handleActiveDraftIDChange(newDraftID)
            }
            .onChange(of: authStore.userID) { _ in
                handleUserIDChange()
            }
            .onChange(of: contentMode) { _ in
                handleSampleAuthorModeChange()
            }
            .onChange(of: selectedEntryTabRawValue) { _ in
                guard selectedPage == .entries else {
                    return
                }
                refreshEntries()
            }
            .onChange(of: selectedEntrySortRawValue) { _ in
                refreshEntries()
            }
            .onReceive(NotificationCenter.default.publisher(for: .journaltopiaGeneratedStoryboardsChanged)) { _ in
                handleGeneratedStoryboardsChanged()
            }
            // The samples on screen came from the cache, so a background re-check that finds a newer
            // pack has to hand it over rather than waiting for the next launch. Reloading rather
            // than reading `SampleContentStore` directly, because that still holds the pack this
            // screen was showing — the newer one is in the service's cache.
            .onReceive(NotificationCenter.default.publisher(for: .journaltopiaSampleStoryPackChanged)) { _ in
                guard contentMode.showsSampleContent else {
                    return
                }

                loadRemoteSampleContentIfNeeded()
            }
            .onDisappear {
                dismissAnyKeyboard()
                storeCurrentEntriesSessionSnapshot()
                cancelThumbnailBackfills()
            }
            .preferredColorScheme(.light)
    }

    private var entriesScreen: some View {
        ZStack(alignment: .bottom) {
            entriesPageBackgroundView

            entriesMainContent
                .refreshable {
                    refreshEntriesFromCloud()
                }

            BottomNavigationBar(selectedPage: $selectedPage)

            if editMode != .active {
                entriesFloatingEditButton
                    .padding(.trailing, 20)
                    .padding(.bottom, entriesFloatingEditButtonBottomPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(2)
            }

            if contentMode.requiresSignIn {
                SampleSignInCallout()
                    .padding(.bottom, JournaltopiaFloatingControlMetrics.signInCalloutBottomInset)
                    .zIndex(3)
            }

            selectedEntriesToolbar

            if let openingEntryPreview {
                EntryOpeningOverlay(
                    preview: openingEntryPreview,
                    isFinishing: isFinishingEntryOpening
                )
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
                    .zIndex(4)
            }
        }
    }

    @ViewBuilder
    private var entriesPageBackgroundView: some View {
        if selectedEntryLayout == .list {
            Color.homePageBackground
                .ignoresSafeArea()
        } else {
            WatercolorPaperPageBackground()
        }
    }

    @ViewBuilder
    private var entriesMainContent: some View {
        if selectedEntryLayout == .list {
            entriesListContent
        } else {
            entriesScrollableContent
        }
    }

    private var entriesScrollableContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    entriesPageChrome

                    entriesPageContent
                }
                .padding(.bottom, 104 + signInCalloutContentInset)
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .background(Color.clear)
        }
    }

    private var entriesListContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            entriesPageChrome

            List {
                Section {
                    if showsCloudLoadingPlaceholder {
                        entryLoadingRows
                    } else if filteredEntryItems.isEmpty {
                        emptyEntriesState
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.homePageBackground)
                    } else {
                        entryRows
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 104 + signInCalloutContentInset)
            }
        }
    }

    private var entriesPageChrome: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 16)

            tabSwitcher
                .padding(.horizontal, 16)

            layoutSwitcherRow
                .padding(.horizontal, 16)

            entriesReorderHint
                .padding(.horizontal, 16)

            cloudEntriesNotice

            entriesSampleBanner
        }
    }

    private var entriesFloatingEditButton: some View {
        Button {
            playJournalFloatingButtonHaptic()
            openCreateEntryFromEntries()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .offset(x: 0, y: -2)
                .background(Color.storyPurple, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write")
    }

    private var entriesFloatingEditButtonBottomPadding: CGFloat {
        JournaltopiaFloatingControlMetrics.bottomInset
    }

    /// Extra room under the content for the floating sign-in callout, which nothing else in the
    /// layout reserves space for.
    private var signInCalloutContentInset: CGFloat {
        contentMode.requiresSignIn ? JournaltopiaFloatingControlMetrics.signInCalloutContentInset : 0
    }

    private var addSelectedEntriesToJournalDestination: some View {
        AddEntryToJournalPage(
            selectedJournalTitle: $selectedEntriesJournalTitle,
            selectedJournalTitles: $selectedEntriesJournalTitles,
            contentMode: contentMode,
            onSelect: { journalTitle in
                addSelectedEntriesToJournals(Set<String>([journalTitle]))
            },
            onSaveSelection: addSelectedEntriesToJournals
        )
    }

    @ViewBuilder
    private var renameEntryAlertActions: some View {
        TextField("Entry name", text: $renamedEntryTitle)

        Button("Cancel", role: .cancel) {
            entryBeingRenamed = nil
            renamedEntryTitle = ""
        }

        Button(entryRenameErrorMessage == nil ? "Save" : "Retry") {
            Task {
                await renameSelectedEntry()
            }
        }
        .disabled(entryBeingRenamed.map { entryIDsBeingRenamed.contains($0.id) } ?? false)
    }

    @ViewBuilder
    private var renameEntryAlertMessage: some View {
        if let entryRenameErrorMessage {
            Text(entryRenameErrorMessage)
        }
    }

    @ViewBuilder
    private var deleteEntryAlertActions: some View {
        Button("Cancel", role: .cancel) {
            entriesPendingDeletion = []
            entryDeleteErrorMessage = nil
        }

        Button(entryDeleteErrorMessage == nil ? "Delete" : "Retry", role: .destructive) {
            let entriesToDelete = entriesPendingDeletion
            Task {
                await deletePendingEntries(entriesToDelete)
            }
        }
    }

    private func openCreateEntryFromEntries() {
        if !isSampleAuthorMode {
            removeTemporaryOpenedSampleEntryIfNeeded()
        }
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
        completedEntryOpenedStoryboardImage = nil
        activeDraftID = nil
        selectedPage = .create
    }

    private func handleSelectedPageChange(_ newPage: StoryPage) {
        if newPage != .entries {
            dismissAnyKeyboard()
            openingEntryPreview = nil
            isFinishingEntryOpening = false
            if !(newPage == .create && isOpeningEntryFromEntries) {
                selectedEntryTab = .all
            }
        }

        if newPage == .entries {
            if isSampleAuthorMode {
                removeTemporaryOpenedSampleEntryIfNeeded()
                refreshEntries(forceCloudReload: true)
                return
            }

            removeTemporaryOpenedSampleEntryIfNeeded()

            if let activeDraftID {
                handleReturnToEntriesFromEditedDraft(activeDraftID)
            } else {
                loadEntriesForCurrentPageIfNeeded()
            }
        }
    }

    private func handleReturnToEntriesFromEditedDraft(_ draftID: UUID) {
        if isSampleAuthorMode {
            removeTemporaryOpenedSampleEntryIfNeeded()
            refreshEntries(forceCloudReload: true)
            return
        }

        if let draft = CreateEntryDraftStore.load(id: draftID) {
            guard !currentSampleEntryIDs.contains(draft.id) else {
                removeTemporaryOpenedSampleEntryIfNeeded()
                loadEntriesForCurrentPageIfNeeded()
                return
            }

            hasCompletedEntriesSamples = true
            sampleEntries = []
            if let existingIndex = entries.firstIndex(where: { $0.id == draft.id }) {
                entries[existingIndex] = draft
            } else {
                entries.append(draft)
            }

            if let thumbnail = draft.thumbnail {
                cloudEntryThumbnails[draft.id] = thumbnail
                cloudEntryThumbnailVersions[draft.id] = "local|\(Int(draft.updatedAt.timeIntervalSince1970 * 1000))"
            }
            isDraftSaved = true
            storeCurrentEntriesSessionSnapshot()
        }

        guard let userID = authStore.userID else {
            return
        }

        let queryKey = currentEntryQueryKey(userID: userID)
        hasLoadedEntriesForSession = true
        loadedEntryQueryKey = queryKey

        Task {
            await loadCloudEntriesIfNeeded(forceReload: true, queryKey: queryKey)
            await loadCloudStoryboardsIfNeeded(forceReload: true, userID: userID)
        }
    }

    private func handleActiveDraftIDChange(_ newDraftID: UUID?) {
        if newDraftID == nil && selectedPage == .entries {
            loadEntriesForCurrentPageIfNeeded()
        } else if newDraftID == nil && selectedPage != .create {
            refreshEntries(forceCloudReload: true)
        }
    }

    private func handleUserIDChange() {
        EntriesSessionMemoryCache.invalidate(userID: nil)
        resetEntriesSessionState()
        refreshEntries(forceCloudReload: true)
    }

    private func handleSampleAuthorModeChange() {
        EntriesSessionMemoryCache.invalidate(userID: nil)
        resetEntriesSessionState()
        selectedEntryIDs = []
        editMode = .inactive
        refreshEntries(forceCloudReload: true)
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text("Entries")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            if canEditEntries {
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if editMode == .active {
                            editMode = .inactive
                            selectedEntryIDs = []
                        } else {
                            editMode = .active
                        }
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .disabled(filteredEntryItems.isEmpty)
            }
        }
        .padding(.top, 12)
    }

    /// Sample browsing has nothing of the visitor's to select, rename or delete — Edit belongs to
    /// signed-in accounts (and sample authors editing the pack).
    private var canEditEntries: Bool {
        contentMode.canPersistUserContent || contentMode.isSampleAuthoring
    }

    private var tabSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(EntriesTab.primaryFilters) { tab in
                    entryFilterPill(for: tab)
                }
            }

            HStack(spacing: 6) {
                ForEach(EntriesTab.secondaryFilters) { tab in
                    entryFilterPill(for: tab)
                }
            }
        }
        .padding(.top, 2)
    }

    private func entryFilterPill(for tab: EntriesTab) -> some View {
        let isSelected = selectedEntryTab == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedEntryTab = tab
            }
        } label: {
            Text(filterTitle(for: tab))
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.storyInk.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(isSelected ? Color.homeAccent : Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(isSelected ? Color.homeAccent : Color.homeBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var layoutSwitcherRow: some View {
        HStack(spacing: 10) {
            entrySortMenu

            Spacer()

            entryLayoutSwitcher
        }
    }

    private var entrySortMenu: some View {
        Menu {
            ForEach(EntrySortOption.menuOptions) { option in
                Button {
                    selectedEntrySort = selectedEntrySort.selection(afterChoosing: option)
                } label: {
                    Label(option.menuTitle, systemImage: selectedEntrySort.menuSystemImage(for: option))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedEntrySort.displaySystemImage)
                    .font(.system(size: 12, weight: .bold))

                Text(selectedEntrySort.shortTitle)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.homeMutedText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort entries by \(selectedEntrySort.title)")
    }

    @ViewBuilder
    private var entriesReorderHint: some View {
        if selectedEntrySort == .manual
            && !showsSampleEntries
            && !filteredEntryItems.isEmpty
            && (selectedEntryLayout != .list || editMode == .active) {
            ReorderHintText()
        }
    }

    private var entryLayoutSwitcher: some View {
        HStack(spacing: 4) {
            entryLayoutButton(.grid)
            entryLayoutButton(.grid3x3)
            entryLayoutButton(.list)
        }
        .padding(4)
        .frame(height: 34)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private func entryLayoutButton(_ layout: JournalEntryLayout) -> some View {
        let isSelected = selectedEntryLayout == layout

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedEntryLayout = layout
            }
        } label: {
            Image(systemName: layout.systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.homeMutedText)
                .frame(width: 34, height: 26)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.storyInk)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func filterTitle(for tab: EntriesTab) -> String {
        "\(tab.title) (\(entryCount(for: tab)))"
    }

    private func entryCount(for tab: EntriesTab) -> Int {
        if showsSampleEntries {
            switch tab {
            case .all:
                return sampleEntries.count
            case .drafts:
                return draftEntries.count
            case .completed:
                return completedEntries.count
            case .addToJournal:
                return sampleEntries.count
            }
        }

        switch tab {
        case .all:
            return authStore.userID == nil ? mergedEntryItems.count : cloudEntryCounts?.all ?? mergedEntryItems.count
        case .drafts:
            return authStore.userID == nil ? draftEntryItems.count : cloudEntryCounts?.drafts ?? draftEntryItems.count
        case .completed:
            return authStore.userID == nil ? completedEntryItems.count : cloudEntryCounts?.completed ?? completedEntryItems.count
        case .addToJournal:
            return authStore.userID == nil ? unjournaledEntryItems.count : unjournaledEntryIDs.count
        }
    }

    @ViewBuilder
    private var selectedEntriesToolbar: some View {
        if editMode == .active && !selectedEntryIDs.isEmpty {
            HStack(spacing: 12) {
                Text("\(selectedEntryIDs.count) selected")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                selectedEntriesOverflowMenu

                if !showsSampleEntries {
                    Button {
                        openAddSelectedEntriesToJournalPage()
                    } label: {
                        Label("Add to Journal", systemImage: "book.closed.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add selected entries to a journal")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.12), radius: 12, y: 6)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 82)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
        }
    }

    private var selectedEntriesOverflowMenu: some View {
        Menu {
            Button {
                duplicateSelectedEntries()
            } label: {
                Label(duplicateSelectedEntriesMenuTitle, systemImage: "doc.on.doc")
            }
            .disabled(isDuplicatingSelectedEntries)

            Button(role: .destructive) {
                requestDeleteSelectedEntries()
            } label: {
                Label(deleteSelectedEntriesMenuTitle, systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Color.storyInk.opacity(0.76))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.homeBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions for selected entries")
    }

    @ViewBuilder
    private var entriesSampleBanner: some View {
        if showsSampleEntries && !isSampleBannerDismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
                    .padding(.top, 1)

                Text("Explore a few sample stories to see how Journaltopia works. Your own entries will appear here once you begin writing.")
                    .font(.system(size: 12, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(Color.homeMutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 6)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSampleBannerDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.homeMutedText)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss sample stories message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var cloudEntriesNotice: some View {
        if let cloudEntriesErrorMessage {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.homeAccent)

                Text(cloudEntriesErrorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                Button("Retry") {
                    Task {
                        await loadCloudEntriesIfNeeded(forceReload: true)
                    }
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.homeAccent)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var entriesPageContent: some View {
        if selectedEntryTab == .completed {
            completedEntryGrid
        } else {
            entryGrid
        }
    }

    @ViewBuilder
    private var entryRows: some View {
        if showsSampleEntries {
            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                let category = categoryForSampleEntry(entry)

                let isCompletedSample = entry.status == JournalEntryStatus.completed.rawValue
                Group {
                    if editMode == .active {
                        EntryListRow(
                            entry: entry,
                            sortOption: selectedEntrySort,
                            pageLabel: entryManualOrderLabel(for: index),
                            category: category,
                            completedStoryboardImage: isCompletedSample
                                ? sampleStoryboardImage(for: entry)
                                : nil,
                            completedStoryboardCount: isCompletedSample ? sampleStoryboardCount(for: entry.id) : 0,
                            rowHeight: 52,
                            coverWidth: 34,
                            coverHeight: 44,
                            isSelecting: true,
                            isSelected: selectedEntryIDs.contains(entry.id),
                            isSample: true,
                            showsReorderHandle: false,
                            onSelect: {
                                toggleEntrySelection(entry.id)
                            }
                        )
                    } else {
                        Button {
                            openSampleEntry(entry)
                        } label: {
                            sampleEntryListRow(entry, category: category, index: index, isCompletedSample: isCompletedSample)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                .listRowBackground(Color.homePageBackground)
                .listRowSeparatorTint(Color.storyInk.opacity(0.10))
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        beginRenaming(entry)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color.homeAccent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        requestDeleteEntry(.local(entry, cloudEntry: nil))
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } else {
            ForEach(Array(filteredEntryItems.enumerated()), id: \.element.id) { index, item in
                let displayEntry = entryForDisplay(item)
                let isCompleted = isCompletedEntryItem(item)
                let completedFallbackIndex = completedStoryboardFallbackIndex(for: item)

                Group {
                    if editMode == .active {
                        entryListRow(
                            item: item,
                            displayEntry: displayEntry,
                            index: index,
                            isCompleted: isCompleted,
                            completedFallbackIndex: completedFallbackIndex
                        )
                    } else {
                        Button {
                            openEntryItem(
                                item,
                                asCompleted: isCompleted,
                                storyboardImage: isCompleted ? storyboardUIImage(for: item, fallbackIndex: completedFallbackIndex) : nil
                            )
                        } label: {
                            entryListRow(
                                item: item,
                                displayEntry: displayEntry,
                                index: index,
                                isCompleted: isCompleted,
                                completedFallbackIndex: completedFallbackIndex
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(openingEntryPreview != nil)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                .listRowBackground(Color.homePageBackground)
                .listRowSeparatorTint(Color.storyInk.opacity(0.10))
                .onAppear {
                    loadMoreCloudEntriesIfNeeded(currentIndex: index, totalCount: filteredEntryItems.count)
                }
                .task(id: cloudThumbnailLoadID(for: item)) {
                    await loadCloudThumbnailIfNeeded(for: item)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        beginRenaming(displayEntry)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color.homeAccent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        requestDeleteEntry(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteEntries)
            .onMove(perform: moveEntries)
            .moveDisabled(selectedEntrySort != .manual || showsSampleEntries)

            if isLoadingMoreCloudEntries {
                EntryListLoadingRow()
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                    .listRowBackground(Color.homePageBackground)
                    .listRowSeparatorTint(Color.storyInk.opacity(0.10))
            }
        }
    }

    private func sampleEntryListRow(
        _ entry: CreateEntryDraft,
        category: EntriesTab?,
        index: Int,
        isCompletedSample: Bool
    ) -> some View {
        EntryListRow(
            entry: entry,
            sortOption: selectedEntrySort,
            pageLabel: entryManualOrderLabel(for: index),
            category: category,
            completedStoryboardImage: isCompletedSample
                ? sampleStoryboardImage(for: entry)
                : nil,
            completedStoryboardCount: isCompletedSample ? sampleStoryboardCount(for: entry.id) : 0,
            rowHeight: 52,
            coverWidth: 34,
            coverHeight: 44,
            isSelecting: false,
            isSelected: selectedEntryIDs.contains(entry.id),
            isSample: true,
            showsReorderHandle: false
        )
    }

    private func entryListRow(
        item: EntryDisplayItem,
        displayEntry: CreateEntryDraft,
        index: Int,
        isCompleted: Bool,
        completedFallbackIndex: Int
    ) -> some View {
        EntryListRow(
            entry: displayEntry,
            sortOption: selectedEntrySort,
            pageLabel: entryManualOrderLabel(for: index),
            category: categoryForEntryItem(item),
            completedStoryboardImage: isCompleted ? storyboardImage(for: item, fallbackIndex: completedFallbackIndex) : nil,
            completedStoryboardCount: isCompleted ? storyboardCount(for: item) : 0,
            showsCompletedStoryboardCount: false,
            rowHeight: 52,
            coverWidth: 34,
            coverHeight: 44,
            isSelecting: editMode == .active,
            isSelected: selectedEntryIDs.contains(item.id),
            showsReorderHandle: false,
            onSelect: {
                toggleEntrySelection(item.id)
            }
        )
        .opacity(openingEntryPreview?.id == item.id ? 0.58 : 1)
    }

    @ViewBuilder
    private var entryLoadingRows: some View {
        ForEach(0..<4, id: \.self) { _ in
            EntryListLoadingRow()
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                .listRowBackground(Color.homePageBackground)
                .listRowSeparatorTint(Color.storyInk.opacity(0.10))
        }
    }

    private var entryGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsCloudLoadingPlaceholder {
                entryGridLoadingPlaceholders
            } else if filteredEntryItems.isEmpty {
                emptyEntriesState
                    .padding(.horizontal, 16)
            } else {
                entryGridContent
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    private var entryGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 14),
            count: selectedEntryLayout.gridColumnCount
        )
    }

    private var entryGridContent: some View {
        LazyVGrid(columns: entryGridColumns, spacing: 14) {
            if showsSampleEntries {
                ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                    sampleEntryGridCard(for: entry, index: index)
                }
            } else {
                ForEach(Array(filteredEntryItems.enumerated()), id: \.element.id) { index, item in
                    let displayEntry = entryForDisplay(item)

                    entryGridCard(for: item, displayEntry: displayEntry, index: index)
                        .onAppear {
                            loadMoreCloudEntriesIfNeeded(currentIndex: index, totalCount: filteredEntryItems.count)
                        }
                        .task(id: cloudThumbnailLoadID(for: item)) {
                            await loadCloudThumbnailIfNeeded(for: item)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: EntryDropDelegate(
                                item: item,
                                items: filteredEntryItems,
                                draggingEntryID: $draggingEntryID,
                                isEnabled: selectedEntrySort == .manual,
                                onReorder: moveEntryItem
                            )
                        )
                }
            }

            if isLoadingMoreCloudEntries {
                EntryGridLoadingCard(seed: filteredEntryItems.count)
            }
        }
    }

    private var completedEntryGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsCloudLoadingPlaceholder {
                entryGridLoadingPlaceholders
            } else if showsSampleEntries {
                entryGridContent
                    .padding(.horizontal, 16)
            } else if completedEntryItems.isEmpty {
                emptyEntriesState
                    .padding(.horizontal, 16)
            } else {
                completedEntryGridContent
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    private var completedEntryGridContent: some View {
        LazyVGrid(columns: entryGridColumns, spacing: 14) {
            ForEach(Array(completedEntryItems.enumerated()), id: \.element.id) { index, item in
                let displayEntry = entryForDisplay(item)

                CompletedEntryGridCard(
                    entry: displayEntry,
                    title: entryDisplayTitle(displayEntry),
                    sortOption: selectedEntrySort,
                    pageLabel: entryManualOrderLabel(for: index),
                    storyboardImage: storyboardImage(for: item, fallbackIndex: index),
                    storyboardCount: storyboardCount(for: item),
                    isOpening: openingEntryPreview?.id == item.id,
                    isSelecting: editMode == .active && !showsSampleEntries,
                    isSelected: selectedEntryIDs.contains(item.id),
                    selectionBadgeStyle: .prominentGrid,
                    showsReorderHandle: showsManualReorderControls,
                    reorderEntryID: item.id,
                    draggingEntryID: $draggingEntryID,
                    onOpen: {
                        if editMode == .active {
                            toggleEntrySelection(item.id)
                        } else {
                            openEntryItem(item, asCompleted: true, storyboardImage: storyboardUIImage(for: item, fallbackIndex: index))
                        }
                    },
                    onDelete: {
                        requestDeleteEntry(item)
                    },
                    onSelect: {
                        toggleEntrySelection(item.id)
                    }
                )
                .onAppear {
                    loadMoreCloudEntriesIfNeeded(currentIndex: index, totalCount: completedEntryItems.count)
                }
                .task(id: cloudThumbnailLoadID(for: item)) {
                    await loadCloudThumbnailIfNeeded(for: item)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: EntryDropDelegate(
                        item: item,
                        items: completedEntryItems,
                        draggingEntryID: $draggingEntryID,
                        isEnabled: selectedEntrySort == .manual,
                        onReorder: moveEntryItem
                    )
                )
            }

            if isLoadingMoreCloudEntries {
                EntryGridLoadingCard(seed: completedEntryItems.count)
            }
        }
    }

    @ViewBuilder
    private func sampleEntryGridCard(for entry: CreateEntryDraft, index: Int) -> some View {
        if entry.status == JournalEntryStatus.completed.rawValue {
            CompletedEntryGridCard(
                entry: entry,
                title: entryDisplayTitle(entry),
                sortOption: selectedEntrySort,
                pageLabel: entryManualOrderLabel(for: index),
                storyboardImage: sampleStoryboardImage(for: entry),
                storyboardCount: sampleStoryboardCount(for: entry.id),
                category: categoryForSampleEntry(entry),
                isOpening: false,
                isSelecting: editMode == .active,
                isSelected: selectedEntryIDs.contains(entry.id),
                isSample: true,
                selectionBadgeStyle: .prominentGrid,
                onOpen: {
                    if editMode == .active {
                        toggleEntrySelection(entry.id)
                    } else {
                        openSampleEntry(entry)
                    }
                },
                onDelete: {
                    requestDeleteEntry(.local(entry, cloudEntry: nil))
                },
                onRename: {
                    beginRenaming(entry)
                },
                onSelect: {
                    toggleEntrySelection(entry.id)
                }
            )
        } else {
            EntryGridPreviewCard(
                entry: entry,
                sortOption: selectedEntrySort,
                pageLabel: entryManualOrderLabel(for: index),
                isEditing: editMode == .active,
                showsActions: true,
                title: entryDisplayTitle(entry),
                category: categoryForSampleEntry(entry),
                isOpening: false,
                isSelecting: editMode == .active,
                isSelected: selectedEntryIDs.contains(entry.id),
                isSample: true,
                selectionBadgeStyle: .prominentGrid,
                onOpen: {
                    if editMode == .active {
                        toggleEntrySelection(entry.id)
                    } else {
                        openSampleEntry(entry)
                    }
                },
                onDelete: {
                    requestDeleteEntry(.local(entry, cloudEntry: nil))
                },
                onRename: {
                    beginRenaming(entry)
                },
                onSelect: {
                    toggleEntrySelection(entry.id)
                }
            )
        }
    }

    @ViewBuilder
    private func entryGridCard(for item: EntryDisplayItem, displayEntry: CreateEntryDraft, index: Int) -> some View {
        if isCompletedEntryItem(item) {
            let fallbackIndex = completedStoryboardFallbackIndex(for: item)

            CompletedEntryGridCard(
                entry: displayEntry,
                title: entryDisplayTitle(displayEntry),
                sortOption: selectedEntrySort,
                pageLabel: entryManualOrderLabel(for: index),
                storyboardImage: storyboardImage(for: item, fallbackIndex: fallbackIndex),
                storyboardCount: storyboardCount(for: item),
                category: categoryForEntryItem(item),
                isOpening: openingEntryPreview?.id == item.id,
                isSelecting: editMode == .active && !showsSampleEntries,
                isSelected: selectedEntryIDs.contains(item.id),
                selectionBadgeStyle: .prominentGrid,
                showsReorderHandle: showsManualReorderControls,
                reorderEntryID: item.id,
                draggingEntryID: $draggingEntryID,
                onOpen: {
                    if editMode == .active {
                        toggleEntrySelection(item.id)
                    } else {
                        openEntryItem(
                            item,
                            asCompleted: true,
                            storyboardImage: storyboardUIImage(for: item, fallbackIndex: fallbackIndex)
                        )
                    }
                },
                onDelete: {
                    requestDeleteEntry(item)
                },
                onSelect: {
                    toggleEntrySelection(item.id)
                }
            )
        } else {
            EntryGridPreviewCard(
                entry: displayEntry,
                sortOption: selectedEntrySort,
                pageLabel: entryManualOrderLabel(for: index),
                isEditing: false,
                showsActions: !showsSampleEntries,
                title: entryDisplayTitle(displayEntry),
                category: categoryForEntryItem(item),
                isOpening: openingEntryPreview?.id == item.id,
                isSelecting: editMode == .active && !showsSampleEntries,
                isSelected: selectedEntryIDs.contains(item.id),
                selectionBadgeStyle: .prominentGrid,
                showsReorderHandle: showsManualReorderControls,
                reorderEntryID: item.id,
                draggingEntryID: $draggingEntryID,
                onOpen: {
                    if showsSampleEntries {
                        openSampleEntry(displayEntry)
                    } else if editMode == .active {
                        toggleEntrySelection(item.id)
                    } else {
                        openEntryItem(item, asCompleted: false)
                    }
                },
                onDelete: {
                    if !showsSampleEntries {
                        requestDeleteEntry(item)
                    }
                },
                onRename: {
                    if !showsSampleEntries {
                        beginRenaming(displayEntry)
                    }
                },
                onSelect: {
                    toggleEntrySelection(item.id)
                }
            )
        }
    }

    private func entryManualOrderLabel(for index: Int) -> String? {
        selectedEntrySort == .manual ? "\(index + 1)" : nil
    }

    private var showsManualReorderControls: Bool {
        editMode == .active && selectedEntrySort == .manual && !showsSampleEntries
    }

    private var entryGridLoadingPlaceholders: some View {
        LazyVGrid(columns: entryGridColumns, spacing: 14) {
            ForEach(0..<6, id: \.self) { index in
                EntryGridLoadingCard(seed: index)
            }
        }
        .padding(.horizontal, 16)
    }

    private var completedEntries: [CreateEntryDraft] {
        let sourceEntries = showsSampleEntries ? sampleEntries : entries
        if showsSampleEntries {
            return sourceEntries.filter { $0.status == JournalEntryStatus.completed.rawValue }
        }

        guard !sourceEntries.isEmpty else {
            return []
        }

        return Array(sourceEntries.prefix(completedEntryCount(for: sourceEntries.count)))
    }

    private var draftEntries: [CreateEntryDraft] {
        let sourceEntries = showsSampleEntries ? sampleEntries : entries
        if showsSampleEntries {
            return sourceEntries.filter { $0.status != JournalEntryStatus.completed.rawValue }
        }

        let completedIDs = Set(completedEntries.map(\.id))
        return sourceEntries.filter { !completedIDs.contains($0.id) }
    }

    private func completedEntryCount(for entryCount: Int) -> Int {
        min(max(entryCount / 3, 1), 4)
    }

    private func sampleStoryboardImage(for entry: CreateEntryDraft) -> CompletedStoryboardImage {
        if let storyboard = sampleStoryboards(for: entry).first {
            return .uiImage(storyboard.image)
        }

        return .failed
    }

    private func sampleStoryboardCount(for entryID: UUID) -> Int {
        sampleStoryboardsByEntryID[entryID]?.count ?? 0
    }

    private func sampleStoryboards(for entry: CreateEntryDraft) -> [GeneratedStoryboard] {
        if let storyboards = sampleStoryboardsByEntryID[entry.id], !storyboards.isEmpty {
            return storyboards
        }

        return []
    }

    private func openSampleEntry(_ entry: CreateEntryDraft) {
        removeStaleSampleRecordsIfNeeded()

        // Signed-out browsing reads the pack from memory, so there is nothing to stage on disk. The
        // staging below exists only for sample authoring, whose editor round-trips through the local
        // draft store — and it was the reason a sample entry left open at quit ended up in the next
        // account's library.
        if contentMode.showsSampleContent, !contentMode.isSampleAuthoring {
            temporaryOpenedSampleEntryID = nil
            openEntryItem(
                .local(entry, cloudEntry: nil),
                asCompleted: entry.status == JournalEntryStatus.completed.rawValue,
                storyboardImage: sampleStoryboards(for: entry).first?.image
            )
            return
        }

        let persistedSampleID = CreateEntryDraftStore.save(
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
        )

        guard persistedSampleID != nil else {
            return
        }

        temporaryOpenedSampleEntryID = entry.id
        let storyboardImage = persistTemporarySampleStoryboards(for: entry)
        openEntryItem(
            .local(entry, cloudEntry: nil),
            asCompleted: entry.status == JournalEntryStatus.completed.rawValue,
            storyboardImage: storyboardImage
        )
    }

    @discardableResult
    private func persistTemporarySampleStoryboards(for entry: CreateEntryDraft) -> UIImage? {
        let sampleStoryboards = sampleStoryboards(for: entry)
        guard !sampleStoryboards.isEmpty else {
            return nil
        }

        let sampleIDs = currentSampleEntryIDs
        var persistedStoryboards = GeneratedStoryboardStore.load().filter { storyboard in
            storyboard.clientEntryID != entry.id && !isCurrentSampleEntryID(storyboard.clientEntryID, in: sampleIDs)
        }
        var firstImage: UIImage?

        for (index, sampleStoryboard) in sampleStoryboards.enumerated() {
            if firstImage == nil {
                firstImage = sampleStoryboard.image
            }

            guard
                let storyboard = try? GeneratedStoryboardStore.persistedStoryboard(
                    image: sampleStoryboard.image,
                    clientEntryID: entry.id,
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

    private func removeTemporaryOpenedSampleEntryIfNeeded() {
        guard !isSampleAuthorMode else {
            temporaryOpenedSampleEntryID = nil
            return
        }

        guard let temporaryOpenedSampleEntryID else {
            return
        }

        let sampleIDs = currentSampleEntryIDs
        CreateEntryDraftStore.delete(id: temporaryOpenedSampleEntryID)
        let sampleStoryboards = GeneratedStoryboardStore.load().filter { storyboard in
            storyboard.clientEntryID == temporaryOpenedSampleEntryID
                || isCurrentSampleEntryID(storyboard.clientEntryID, in: sampleIDs)
        }
        if !sampleStoryboards.isEmpty {
            GeneratedStoryboardStore.delete(sampleStoryboards)
            GeneratedStoryboardStore.save(
                GeneratedStoryboardStore.load().filter { storyboard in
                    storyboard.clientEntryID != temporaryOpenedSampleEntryID
                        && !isCurrentSampleEntryID(storyboard.clientEntryID, in: sampleIDs)
                }
            )
        }
        self.temporaryOpenedSampleEntryID = nil
        if activeDraftID == temporaryOpenedSampleEntryID {
            activeDraftID = nil
        }
        completedEntryOpenedStoryboardImage = nil
    }

    private func removeStaleSampleRecordsIfNeeded() {
        guard !isSampleAuthorMode else {
            return
        }

        guard contentMode.canPersistUserContent else {
            return
        }

        let sampleIDs = currentSampleEntryIDs
        for sampleID in sampleIDs where sampleID != temporaryOpenedSampleEntryID {
            CreateEntryDraftStore.delete(id: sampleID)
        }

        let staleSampleStoryboards = GeneratedStoryboardStore.load().filter { storyboard in
            isCurrentSampleEntryID(storyboard.clientEntryID, in: sampleIDs)
                && storyboard.clientEntryID != temporaryOpenedSampleEntryID
        }
        guard !staleSampleStoryboards.isEmpty else {
            return
        }

        GeneratedStoryboardStore.delete(staleSampleStoryboards)
        GeneratedStoryboardStore.save(
            GeneratedStoryboardStore.load().filter { storyboard in
                !isCurrentSampleEntryID(storyboard.clientEntryID, in: sampleIDs)
                    || storyboard.clientEntryID == temporaryOpenedSampleEntryID
            }
        )
    }

    private var currentSampleEntryIDs: Set<UUID> {
        Set(sampleEntries.map(\.id))
    }

    private func isCurrentSampleEntryID(_ entryID: UUID?, in sampleIDs: Set<UUID>) -> Bool {
        guard let entryID else {
            return false
        }

        return sampleIDs.contains(entryID)
    }

    private func generatedStoryboard(for item: EntryDisplayItem) -> GeneratedStoryboard? {
        completedStoryboards.first { $0.clientEntryID == item.id && $0.isPrimary }
            ?? completedStoryboards.first { $0.clientEntryID == item.id }
    }

    private func storyboardCount(for item: EntryDisplayItem) -> Int {
        max(
            storyboardCountsByClientEntryID[item.id] ?? 0,
            completedStoryboards.filter { $0.clientEntryID == item.id }.count
        )
    }

    private func storyboardImage(for item: EntryDisplayItem, fallbackIndex index: Int) -> CompletedStoryboardImage {
        if let storyboard = generatedStoryboard(for: item) {
            return .uiImage(storyboard.image)
        }

        if cloudStoryboardClientIDs.contains(item.id) {
            return .loading
        }

        if failedCloudStoryboardClientIDs.contains(item.id) {
            return .failed
        }

        if completedStoryboards.indices.contains(index),
           completedStoryboards[index].clientEntryID == nil {
            return .uiImage(completedStoryboards[index].image)
        }

        return .failed
    }

    private func storyboardUIImage(for item: EntryDisplayItem, fallbackIndex index: Int) -> UIImage? {
        if let storyboard = generatedStoryboard(for: item) {
            return storyboard.image
        }

        if cloudStoryboardClientIDs.contains(item.id) || failedCloudStoryboardClientIDs.contains(item.id) {
            return nil
        }

        if completedStoryboards.indices.contains(index),
           completedStoryboards[index].clientEntryID == nil {
            return completedStoryboards[index].image
        }

        return nil
    }

    private var emptyEntriesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(Color.homeAccent.opacity(0.65))

            Text("No entries")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text("Entries you save will appear here.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var filteredEntries: [CreateEntryDraft] {
        let sourceEntries: [CreateEntryDraft]
        switch selectedEntryTab {
        case .all:
            sourceEntries = showsSampleEntries ? sampleEntries : entries
        case .drafts:
            sourceEntries = draftEntries
        case .completed:
            sourceEntries = completedEntries
        case .addToJournal:
            sourceEntries = sampleEntries
        }

        guard showsSampleEntries else {
            return sourceEntries
        }

        return sourceEntries
            .map { EntryDisplayItem.local($0, cloudEntry: nil) }
            .sorted(by: sortEntryItems)
            .map(\.entry)
    }

    private var filteredEntryItems: [EntryDisplayItem] {
        if showsSampleEntries {
            return filteredEntries.map { .local($0, cloudEntry: nil) }
        }

        switch selectedEntryTab {
        case .all:
            return mergedEntryItems
        case .drafts:
            return draftEntryItems
        case .completed:
            return completedEntryItems
        case .addToJournal:
            return unjournaledEntryItems
        }
    }

    private var mergedEntryItems: [EntryDisplayItem] {
        if authStore.userID != nil {
            return cloudBackedEntryItems
        }

        let cloudByClientID = Dictionary(grouping: cloudEntries, by: \.clientEntryID)
            .compactMapValues(\.first)
        let localItems = entries.map { entry in
            EntryDisplayItem.local(entry, cloudEntry: cloudByClientID[entry.id])
        }
        let localIDs = Set(entries.map(\.id))
        let cloudOnlyItems = cloudEntries
            .filter { !localIDs.contains($0.clientEntryID) }
            .map(EntryDisplayItem.cloud)

        return (localItems + cloudOnlyItems)
            .filter { $0.status != JournalEntryStatus.archived.rawValue }
            .sorted(by: sortEntryItems)
    }

    private var cloudBackedEntryItems: [EntryDisplayItem] {
        let localByID = Dictionary(grouping: entries, by: \.id)
            .compactMapValues(\.first)

        return cloudEntries
            .map { cloudEntry in
                if let localEntry = localByID[cloudEntry.clientEntryID] {
                    return EntryDisplayItem.local(localEntry, cloudEntry: cloudEntry)
                }

                return EntryDisplayItem.cloud(cloudEntry)
            }
            .filter { $0.status != JournalEntryStatus.archived.rawValue }
            .sorted(by: sortEntryItems)
    }

    private func sortEntryItems(_ lhs: EntryDisplayItem, _ rhs: EntryDisplayItem) -> Bool {
        if selectedEntrySort == .manual {
            switch (manualEntryOrderOverrides[lhs.id], manualEntryOrderOverrides[rhs.id]) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            switch (lhs.entry.displayOrder, rhs.entry.displayOrder) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.createdAt > rhs.createdAt
            }
        }

        let lhsDate = sortDate(for: lhs)
        let rhsDate = sortDate(for: rhs)

        if lhsDate != rhsDate {
            return selectedEntrySort.sortsAscending ? lhsDate < rhsDate : lhsDate > rhsDate
        }

        return selectedEntrySort.sortsAscending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
    }

    private func sortDate(for item: EntryDisplayItem) -> Date {
        switch selectedEntrySort {
        case .manual:
            return item.createdAt
        case .entryDate, .entryDateOldest:
            let entry = item.entry
            return entry.datePrecision == .noDate ? item.createdAt : entry.date
        case .cloudCreated, .cloudCreatedOldest:
            return item.createdAt
        case .updated, .updatedOldest:
            return item.updatedAt
        }
    }

    private var draftEntryItems: [EntryDisplayItem] {
        mergedEntryItems.filter { $0.status != JournalEntryStatus.completed.rawValue }
    }

    private var completedEntryItems: [EntryDisplayItem] {
        mergedEntryItems.filter { $0.status == JournalEntryStatus.completed.rawValue }
    }

    private var unjournaledEntryItems: [EntryDisplayItem] {
        if authStore.userID != nil {
            return mergedEntryItems.filter { unjournaledEntryIDs.contains($0.id) }
        }

        return mergedEntryItems.filter { item in
            journalTitles(for: item).isEmpty
        }
    }

    private func isCompletedEntryItem(_ item: EntryDisplayItem) -> Bool {
        item.status == JournalEntryStatus.completed.rawValue
    }

    private var selectedEntryItems: [EntryDisplayItem] {
        filteredEntryItems.filter { selectedEntryIDs.contains($0.id) }
    }

    private func toggleEntrySelection(_ entryID: UUID) {
        if selectedEntryIDs.contains(entryID) {
            selectedEntryIDs.remove(entryID)
        } else {
            selectedEntryIDs.insert(entryID)
        }
    }

    private func openAddSelectedEntriesToJournalPage() {
        let journalTitles = selectedJournalTitlesForAddSheet()
        selectedEntriesJournalTitles = journalTitles
        selectedEntriesJournalTitle = journalTitles.sorted().first

        Task {
            await refreshCloudJournalsBeforeShowingSelectedEntrySheet()
            isShowingAddSelectedEntriesToJournalSheet = true
        }
    }

    private func addSelectedEntriesToJournals(_ journalTitles: Set<String>) {
        guard !journalTitles.isEmpty else {
            return
        }

        selectedEntryItems.forEach { item in
            let entry = entryForDisplay(item).prototypeEntry()
            journalTitles.sorted().forEach { journalTitle in
                StoryEntryStore.upsert(entry, to: journalTitle)
                EntryJournalLinkStore.save(journalTitle: journalTitle, journalEntryID: entry.id, for: item.id)
            }
        }

        Task {
            await syncSelectedEntryJournalsToCloud(journalTitles)
        }

        selectedEntriesJournalTitles = journalTitles
        selectedEntriesJournalTitle = journalTitles.sorted().first
        selectedEntryIDs.forEach { unjournaledEntryIDs.remove($0) }
        selectedEntryIDs = []
        editMode = .inactive
        refreshEntries(forceCloudReload: true)
    }

    private func requestDeleteSelectedEntries() {
        requestDeleteEntries(selectedEntryItems)
    }

    private var duplicateSelectedEntriesMenuTitle: String {
        selectedEntryIDs.count == 1 ? "Duplicate Entry" : "Duplicate \(selectedEntryIDs.count) Entries"
    }

    private func duplicateSelectedEntries() {
        let itemsToDuplicate = selectedEntryItems
        guard !itemsToDuplicate.isEmpty, !isDuplicatingSelectedEntries else {
            return
        }

        guard signInGate.requireAccount(for: .createEntry) else {
            return
        }

        isDuplicatingSelectedEntries = true
        entryDuplicateErrorMessage = nil

        Task {
            var duplicatedEntries: [CreateEntryDraft] = []

            for item in itemsToDuplicate {
                do {
                    let sourceEntry = fullLocalEntry(for: item)
                    let duplicateID = UUID()
                    let status = JournalEntryStatus(rawValue: item.status) ?? .draft
                    let payload = sourceEntry.duplicateSavePayload(id: duplicateID)
                    let result = try await EntrySaveService().saveEntryPreservingStatus(
                        payload: payload,
                        isSignedIn: authStore.userID != nil,
                        status: status
                    )

                    if authStore.userID != nil, result.cloudEntry == nil {
                        CreateEntryDraftStore.delete(id: result.localDraftID)
                        throw JournalEntryRepositoryError.operationFailed
                    }

                    if let duplicate = CreateEntryDraftStore.load(id: result.localDraftID) {
                        duplicatedEntries.append(duplicate)
                    }

                    if let cloudEntry = result.cloudEntry {
                        cloudEntries.removeAll { $0.clientEntryID == cloudEntry.clientEntryID }
                        cloudEntries.insert(cloudEntry, at: 0)
                    }

                    let duplicatedStoryboards = await duplicateStoryboardsForEntry(
                        sourceClientEntryID: item.id,
                        duplicateClientEntryID: result.localDraftID,
                        isSignedIn: authStore.userID != nil
                    )
                    if !duplicatedStoryboards.isEmpty {
                        completedStoryboards = duplicatedStoryboards + completedStoryboards
                        storyboardCountsByClientEntryID[result.localDraftID] = duplicatedStoryboards.count
                    } else if storyboardCount(for: item) > 0 {
                        entryDuplicateErrorMessage = "Duplicated the entry, but could not duplicate one or more storyboards."
                    }
                } catch {
                    entryDuplicateErrorMessage = "Could not duplicate one or more entries."
                }
            }

            if !duplicatedEntries.isEmpty {
                entries.append(contentsOf: duplicatedEntries)
                isDraftSaved = true
            }

            if authStore.userID != nil {
                EntriesCloudFetchCache.invalidate(for: authStore.userID)
                EntriesSessionMemoryCache.invalidate(userID: authStore.userID)
            }

            selectedEntryIDs.subtract(itemsToDuplicate.map(\.id))
            if selectedEntryIDs.isEmpty {
                editMode = .inactive
            }
            isDuplicatingSelectedEntries = false
            refreshEntries(forceCloudReload: authStore.userID != nil)
        }
    }

    private func fullLocalEntry(for item: EntryDisplayItem) -> CreateEntryDraft {
        CreateEntryDraftStore.load(id: item.id) ?? entryForDisplay(item)
    }

    private func syncSelectedEntryJournalsToCloud(_ journalTitles: Set<String>) async {
        guard authStore.userID != nil else {
            return
        }

        for journalTitle in journalTitles {
            await UserChapterStore.syncJournalAndEntriesToCloud(title: journalTitle)
        }
    }

    private func selectedJournalTitlesForAddSheet() -> Set<String> {
        let titleSets = selectedEntryItems.map { item in
            journalTitles(for: item)
        }

        guard let firstTitleSet = titleSets.first else {
            return []
        }

        return titleSets.dropFirst().reduce(firstTitleSet) { sharedTitles, titles in
            sharedTitles.intersection(titles)
        }
    }

    private func journalTitles(for item: EntryDisplayItem) -> Set<String> {
        let entry = entryForDisplay(item).prototypeEntry()
        return StoryEntryStore.journalTitles(containing: entry)
            .union(EntryJournalLinkStore.loadJournalTitles(for: item.id))
    }

    private func loadUnjournaledEntryIDs() async throws -> Set<UUID> {
        let repository = SupabaseEntryRepository()
        async let activeEntryIDsTask = repository.getActiveEntryClientIDs()
        async let membershipsTask = SupabaseJournalRepository().getJournalEntryMemberships()
        let activeEntryIDs = try await activeEntryIDsTask
        let memberships = try await membershipsTask
        let journaledEntryIDs = Set(memberships.map(\.clientEntryID))
        return activeEntryIDs.subtracting(journaledEntryIDs)
    }

    private func refreshUnjournaledEntryIDs() async {
        guard authStore.userID != nil else {
            unjournaledEntryIDs = []
            return
        }

        do {
            unjournaledEntryIDs = try await loadUnjournaledEntryIDs()
        } catch {
            print("[Journaltopia] Could not refresh unjournaled entry IDs.")
        }
    }

    private func refreshCloudJournalsBeforeShowingSelectedEntrySheet() async {
        guard authStore.userID != nil else {
            return
        }

        do {
            let cloudJournals = try await SupabaseJournalRepository().getJournals()
            let chapters = cloudJournals.map(PrototypeChapter.init(cloudJournal:))
            UserChapterStore.replace(with: chapters)
        } catch {
            print("[Journaltopia] Could not refresh journals before adding selected entries.")
        }
    }

    private func categoryForEntryItem(_ item: EntryDisplayItem) -> EntriesTab? {
        guard selectedEntryTab == .all else {
            return nil
        }

        return isCompletedEntryItem(item) ? .completed : .drafts
    }

    private func categoryForSampleEntry(_ entry: CreateEntryDraft) -> EntriesTab? {
        guard selectedEntryTab == .all else {
            return nil
        }

        let completedIDs = Set(completedEntries.map(\.id))
        return completedIDs.contains(entry.id) ? .completed : .drafts
    }

    private func completedStoryboardFallbackIndex(for item: EntryDisplayItem) -> Int {
        completedEntryItems.firstIndex { $0.id == item.id } ?? 0
    }

    private var showsSampleEntries: Bool {
        if isSampleAuthorMode {
            return showsPrototypeData && !sampleEntries.isEmpty && !isLoadingCloudEntries
        }

        return !shouldSuppressSamplesForSignedInUser
            && entries.isEmpty
            && cloudEntries.isEmpty
            && !isLoadingCloudEntries
            && cloudEntriesErrorMessage == nil
            && showsPrototypeData
            && !sampleEntries.isEmpty
    }

    /// Signed-in accounts never borrow the sample pack, empty or not.
    ///
    /// This used to hold only once ``hasCompletedEntriesSamples`` was set, so a brand-new account
    /// opened on Entries full of someone else's demo stories until its owner saved a first entry.
    /// Journals and Profile already gated on ``JournaltopiaContentMode/showsSampleContent`` — signed
    /// out only — so Entries was the one screen that disagreed. A new account starts empty here too.
    private var shouldSuppressSamplesForSignedInUser: Bool {
        authStore.userID != nil && !isSampleAuthorMode
    }

    private var showsCloudLoadingPlaceholder: Bool {
        (isLoadingCloudEntries || isLoadingSampleContent || !hasAttemptedEntriesLoad)
            && !showsSampleEntries
            && filteredEntryItems.isEmpty
            && cloudEntriesErrorMessage == nil
    }

    private func entryForDisplay(_ item: EntryDisplayItem) -> CreateEntryDraft {
        let entry = item.entry
        guard entry.thumbnail == nil, let thumbnail = cloudEntryThumbnails[item.id] else {
            return entry
        }

        return entry.replacingThumbnail(thumbnail)
    }

    private func deleteEntries(at offsets: IndexSet) {
        requestDeleteEntries(offsets.map { filteredEntryItems[$0] })
    }

    private func deleteEntry(_ item: EntryDisplayItem) async throws {
        guard !entryIDsBeingDeleted.contains(item.id) else {
            return
        }

        if isSampleAuthorMode {
            try await deleteSampleEntry(item)
            return
        }

        if authStore.userID != nil, cloudEntriesErrorMessage != nil, item.cloudEntry == nil {
            throw JournalEntryRepositoryError.operationFailed
        }

        entryIDsBeingDeleted.insert(item.id)
        defer { entryIDsBeingDeleted.remove(item.id) }

        try await EntrySaveService().deleteEntry(
            localDraftID: item.id,
            cloudEntry: item.cloudEntry,
            isSignedIn: authStore.userID != nil
        )
        StoryEntryStore.delete(entryID: item.id)
        EntryJournalLinkStore.remove(for: item.id)
        entries.removeAll { $0.id == item.id }
        cloudEntries.removeAll { $0.clientEntryID == item.id }

        if activeDraftID == item.id {
            activeDraftID = nil
        }
        isDraftSaved = !entries.isEmpty
    }

    private func deleteSampleEntry(_ item: EntryDisplayItem) async throws {
        entryIDsBeingDeleted.insert(item.id)
        defer { entryIDsBeingDeleted.remove(item.id) }

        try await SupabaseSampleStoryService().deleteSampleEntry(id: item.id)
        DeletedAuthoringSampleEntryStore.add(item.id)
        sampleEntries.removeAll { $0.id == item.id }
        sampleStoryboardsByEntryID[item.id] = nil
        let localSampleStoryboards = GeneratedStoryboardStore.load().filter { $0.clientEntryID == item.id }
        if !localSampleStoryboards.isEmpty {
            GeneratedStoryboardStore.delete(localSampleStoryboards)
            GeneratedStoryboardStore.save(
                GeneratedStoryboardStore.load().filter { $0.clientEntryID != item.id }
            )
        }
        CreateEntryDraftStore.delete(id: item.id)

        if activeDraftID == item.id {
            activeDraftID = nil
        }
        isDraftSaved = false
    }

    private var isDeleteEntryAlertPresented: Binding<Bool> {
        Binding(
            get: { !entriesPendingDeletion.isEmpty },
            set: { isPresented in
                if !isPresented {
                    entriesPendingDeletion = []
                }
            }
        )
    }

    private var deleteEntryAlertTitle: String {
        entriesPendingDeletion.count == 1 ? "Delete Entry?" : "Delete Entries?"
    }

    private var deleteEntryAlertMessage: String {
        if let entryDeleteErrorMessage {
            return entryDeleteErrorMessage
        }

        if let entry = entriesPendingDeletion.first, entriesPendingDeletion.count == 1 {
            return "Are you sure you want to delete \"\(entryDisplayTitle(entry.entry))\"? This can't be undone."
        }

        return "Are you sure you want to delete \(entriesPendingDeletion.count) entries? This can't be undone."
    }

    private var deleteSelectedEntriesMenuTitle: String {
        selectedEntryIDs.count == 1 ? "Delete Entry" : "Delete \(selectedEntryIDs.count) Entries"
    }

    private var isDuplicateEntryAlertPresented: Binding<Bool> {
        Binding(
            get: { entryDuplicateErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    entryDuplicateErrorMessage = nil
                }
            }
        )
    }

    private func requestDeleteEntry(_ entry: EntryDisplayItem) {
        requestDeleteEntries([entry])
    }

    private func requestDeleteEntries(_ entries: [EntryDisplayItem]) {
        guard signInGate.requireAccount(for: .deleteEntry) else {
            return
        }

        entriesPendingDeletion = entries
        entryDeleteErrorMessage = nil
    }

    private func deletePendingEntries(_ entriesToDelete: [EntryDisplayItem]) async {
        var failedEntries: [EntryDisplayItem] = []

        for entry in entriesToDelete {
            do {
                try await deleteEntry(entry)
            } catch {
                failedEntries.append(entry)
            }
        }

        if failedEntries.isEmpty {
            entriesPendingDeletion = []
            entryDeleteErrorMessage = nil
            selectedEntryIDs.subtract(entriesToDelete.map(\.id))
            if selectedEntryIDs.isEmpty {
                editMode = .inactive
            }
            refreshEntries(forceCloudReload: true)
        } else {
            entriesPendingDeletion = failedEntries
            entryDeleteErrorMessage = isSampleAuthorMode
                ? "Could not delete from the sample author pack. Check your connection and try again."
                : "Could not delete from Journaltopia cloud. Check your connection and try again."
        }
    }

    private var isRenameEntryAlertPresented: Binding<Bool> {
        Binding(
            get: { entryBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    entryBeingRenamed = nil
                    renamedEntryTitle = ""
                    entryRenameErrorMessage = nil
                }
            }
        )
    }

    private func beginRenaming(_ entry: CreateEntryDraft) {
        guard signInGate.requireAccount(for: .editEntry) else {
            return
        }

        entryBeingRenamed = entry
        renamedEntryTitle = entryDisplayTitle(entry)
        entryRenameErrorMessage = nil
    }

    private func renameSelectedEntry() async {
        guard let entry = entryBeingRenamed else {
            return
        }

        guard !entryIDsBeingRenamed.contains(entry.id) else {
            return
        }

        let trimmedTitle = renamedEntryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        let entryThumbnail = DraftThumbnailRenderer.render(
            title: trimmedTitle,
            text: entry.text,
            richText: entry.richText,
            photos: [],
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
            textAlignmentRawValue: entry.textAlignmentRawValue
        )

        if isSampleAuthorMode {
            entryIDsBeingRenamed.insert(entry.id)
            defer { entryIDsBeingRenamed.remove(entry.id) }

            do {
                try await SupabaseSampleStoryService().renameSampleEntry(id: entry.id, title: trimmedTitle)
                if let index = sampleEntries.firstIndex(where: { $0.id == entry.id }) {
                    sampleEntries[index] = sampleEntries[index].replacingTitle(trimmedTitle, thumbnail: entryThumbnail)
                }
                entryBeingRenamed = nil
                renamedEntryTitle = ""
                entryRenameErrorMessage = nil
                refreshEntries(forceCloudReload: true)
            } catch {
                entryRenameErrorMessage = "Could not sync the sample title to Journaltopia cloud."
            }
            return
        }

        let renamedID = CreateEntryDraftStore.save(
            id: entry.id,
            title: trimmedTitle,
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
            thumbnail: entryThumbnail,
            createdAt: entry.createdAt
        )

        if renamedID != nil {
            refreshEntries(forceCloudReload: true)
        }

        if authStore.userID != nil {
            entryIDsBeingRenamed.insert(entry.id)
            defer { entryIDsBeingRenamed.remove(entry.id) }

            do {
                let matchingCloudEntry = cloudEntries.firstIndex(where: { $0.clientEntryID == entry.id })
                    .map { cloudEntries[$0] }
                let status: JournalEntryStatus
                if entry.status == JournalEntryStatus.completed.rawValue {
                    status = .completed
                } else if let rawStatus = matchingCloudEntry?.status,
                   let cloudStatus = JournalEntryStatus(rawValue: rawStatus) {
                    status = cloudStatus
                } else {
                    status = .draft
                }
                _ = try await EntrySaveService().renameEntry(
                    entry: entry.replacingThumbnail(entryThumbnail),
                    title: trimmedTitle,
                    status: status,
                    isSignedIn: true
                )
                await loadCloudEntriesIfNeeded(forceReload: true)
            } catch {
                entryRenameErrorMessage = "Saved locally. Could not sync the title to Journaltopia cloud."
                return
            }
        }

        entryBeingRenamed = nil
        renamedEntryTitle = ""
        entryRenameErrorMessage = nil
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        guard selectedEntrySort == .manual else {
            return
        }

        var visibleItems = filteredEntryItems
        visibleItems.move(fromOffsets: source, toOffset: destination)
        persistManualEntryOrder(visibleItems.map(\.id))
    }

    private func moveEntryItem(_ draggedID: UUID, before targetID: UUID) {
        guard selectedEntrySort == .manual else {
            return
        }

        var visibleItems = filteredEntryItems
        guard
            let fromIndex = visibleItems.firstIndex(where: { $0.id == draggedID }),
            let toIndex = visibleItems.firstIndex(where: { $0.id == targetID }),
            fromIndex != toIndex
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            let item = visibleItems.remove(at: fromIndex)
            visibleItems.insert(item, at: toIndex)
            persistManualEntryOrder(visibleItems.map(\.id))
        }
    }

    private func persistManualEntryOrder(_ orderedIDs: [UUID]) {
        guard !orderedIDs.isEmpty else {
            return
        }

        // Signed out there is no order to keep: the list is the shared sample pack, and the local
        // draft store it used to write into resolves to the anonymous scope.
        guard contentMode.canPersistUserContent || contentMode.isSampleAuthoring else {
            return
        }

        applyManualEntryOrder(orderedIDs)

        if isSampleAuthorMode {
            persistManualSampleEntryOrder()
        } else {
            persistManualCloudEntryOrder()
        }
    }

    private func persistManualSampleEntryOrder() {
        let orderedSampleEntryIDs = sampleEntries
            .map { EntryDisplayItem.local($0, cloudEntry: nil) }
            .sorted(by: sortEntryItems)
            .map(\.id)
        guard !orderedSampleEntryIDs.isEmpty else {
            return
        }

        manualEntryOrderSaveTask?.cancel()
        manualEntryOrderSaveTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }

            do {
                try await SupabaseSampleStoryService().updateSampleEntryOrder(orderedSampleEntryIDs)
                await MainActor.run {
                    cloudEntriesErrorMessage = nil
                }
            } catch {
                await MainActor.run {
                    cloudEntriesErrorMessage = "Could not save sample entry order."
                }
            }
        }
    }

    private func persistManualCloudEntryOrder() {
        guard authStore.userID != nil else {
            return
        }

        let orderedClientEntryIDs = cloudEntries.map(\.clientEntryID)
        guard !orderedClientEntryIDs.isEmpty else {
            return
        }

        manualEntryOrderSaveTask?.cancel()
        manualEntryOrderSaveTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }

            do {
                try await SupabaseEntryRepository().updateEntryDisplayOrder(orderedClientEntryIDs)
                await MainActor.run {
                    if let userID = authStore.userID {
                        EntriesCloudFetchCache.invalidate(for: userID)
                    }
                    cloudEntriesErrorMessage = nil
                }
            } catch {
                await MainActor.run {
                    cloudEntriesErrorMessage = "Could not save manual entry order."
                }
            }
        }
    }

    private func applyManualEntryOrder(_ orderedIDs: [UUID]) {
        let orderByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        manualEntryOrderOverrides.merge(orderByID) { _, newValue in newValue }

        entries.sort { lhs, rhs in
            switch (orderByID[lhs.id], orderByID[rhs.id]) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return sortLocalEntriesByManualOrder(lhs, rhs)
            }
        }

        cloudEntries.sort { lhs, rhs in
            switch (orderByID[lhs.clientEntryID], orderByID[rhs.clientEntryID]) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return sortCloudEntriesByManualOrder(lhs, rhs)
            }
        }

        sampleEntries.sort { lhs, rhs in
            switch (orderByID[lhs.id], orderByID[rhs.id]) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return (lhs.displayOrder ?? Int.max) < (rhs.displayOrder ?? Int.max)
            }
        }
    }

    private func sortLocalEntriesByManualOrder(_ lhs: CreateEntryDraft, _ rhs: CreateEntryDraft) -> Bool {
        switch (lhs.displayOrder, rhs.displayOrder) {
        case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
            return lhsOrder < rhsOrder
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func sortCloudEntriesByManualOrder(_ lhs: JournalEntry, _ rhs: JournalEntry) -> Bool {
        switch (lhs.displayOrder, rhs.displayOrder) {
        case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
            return lhsOrder < rhsOrder
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func loadEntriesForCurrentPageIfNeeded() {
        if isSampleAuthorMode {
            refreshEntries()
            return
        }

        removeStaleSampleRecordsIfNeeded()

        guard let userID = authStore.userID else {
            refreshEntries()
            return
        }

        let queryKey = currentEntryQueryKey(userID: userID)
        if !hasLoadedEntriesForSession {
            restoreEntriesSessionSnapshotIfAvailable(for: queryKey)
        }

        guard hasLoadedEntriesForSession, loadedEntryQueryKey == queryKey else {
            refreshEntries()
            return
        }

        hasAttemptedEntriesLoad = true

        scheduleEntryThumbnailBackfill()
        scheduleCloudEntryThumbnailBackfill()
        if selectedEntryTab != .addToJournal, EntriesCloudFetchCache.hasFreshEntrySummaries(for: queryKey) {
            Task {
                await refreshUnjournaledEntryIDs()
                await loadCloudStoryboardsIfNeeded(userID: userID)
            }
            return
        }

        Task {
            await loadCloudEntriesIfNeeded()
            await loadCloudStoryboardsIfNeeded(userID: userID)
        }
    }

    private func restoreEntriesSessionSnapshotIfAvailable(
        for queryKey: EntriesCloudFetchCache.EntryQueryKey
    ) {
        guard let snapshot = EntriesSessionMemoryCache.snapshot(for: queryKey) else {
            return
        }

        entries = snapshot.entries
        sampleEntries = snapshot.sampleEntries
        sampleStoryboardsByEntryID = snapshot.sampleStoryboardsByEntryID
        completedStoryboards = snapshot.completedStoryboards
        storyboardCountsByClientEntryID = snapshot.storyboardCountsByClientEntryID
        cloudEntries = snapshot.cloudEntries
        cloudEntryCounts = snapshot.cloudEntryCounts
        cloudEntryThumbnails = snapshot.cloudEntryThumbnails
        cloudEntryThumbnailVersions = snapshot.cloudEntryThumbnailVersions
        cloudStoryboardClientIDs = snapshot.cloudStoryboardClientIDs
        failedCloudStoryboardClientIDs = snapshot.failedCloudStoryboardClientIDs
        hasMoreCloudEntries = snapshot.hasMoreCloudEntries
        nextCloudEntryOffset = snapshot.nextCloudEntryOffset
        cloudEntriesErrorMessage = snapshot.cloudEntriesErrorMessage
        isLoadingCloudEntries = false
        isLoadingMoreCloudEntries = false
        isDraftSaved = draftEntryItems.isEmpty == false
        hasLoadedEntriesForSession = true
        loadedEntryQueryKey = queryKey
        restoreCachedCloudEntryThumbnails()
        scheduleCloudEntryThumbnailBackfill()
    }

    private func storeCurrentEntriesSessionSnapshot() {
        guard hasLoadedEntriesForSession, let loadedEntryQueryKey else {
            return
        }

        EntriesSessionMemoryCache.store(
            EntriesSessionMemoryCache.Snapshot(
                entries: entries,
                sampleEntries: sampleEntries,
                sampleStoryboardsByEntryID: sampleStoryboardsByEntryID,
                completedStoryboards: completedStoryboards,
                storyboardCountsByClientEntryID: storyboardCountsByClientEntryID,
                cloudEntries: cloudEntries,
                cloudEntryCounts: cloudEntryCounts,
                cloudEntryThumbnails: cloudEntryThumbnails,
                cloudEntryThumbnailVersions: cloudEntryThumbnailVersions,
                cloudStoryboardClientIDs: cloudStoryboardClientIDs,
                failedCloudStoryboardClientIDs: failedCloudStoryboardClientIDs,
                hasMoreCloudEntries: hasMoreCloudEntries,
                nextCloudEntryOffset: nextCloudEntryOffset,
                cloudEntriesErrorMessage: cloudEntriesErrorMessage
            ),
            for: loadedEntryQueryKey
        )
    }

    private func resetEntriesSessionState() {
        cancelThumbnailBackfills()
        isLoadingSampleContent = false
        hasLoadedEntriesForSession = false
        loadedEntryQueryKey = nil
        storyboardCountsByClientEntryID = [:]
        unjournaledEntryIDs = []
        cloudThumbnailIDsBeingLoaded = []
        cloudEntryThumbnailVersions = [:]
    }

    private func refreshEntriesFromCloud() {
        if isSampleAuthorMode {
            refreshEntries(forceCloudReload: true)
            return
        }

        guard let userID = authStore.userID else {
            refreshEntries(forceCloudReload: true)
            return
        }

        EntriesSessionMemoryCache.invalidate(userID: userID)
        EntriesCloudFetchCache.invalidate(for: userID)
        selectedEntryIDs = []
        editMode = .inactive
        refreshEntries(forceCloudReload: true)
    }

    private func handleGeneratedStoryboardsChanged() {
        if isSampleAuthorMode {
            refreshEntries(forceCloudReload: true)
            return
        }

        guard let userID = authStore.userID else {
            refreshEntries(forceCloudReload: true)
            return
        }

        EntriesSessionMemoryCache.invalidate(userID: userID)
        EntriesCloudFetchCache.invalidate(for: userID)
        refreshEntries(forceCloudReload: true)
    }

    private func cancelThumbnailBackfills() {
        entryThumbnailBackfillTask?.cancel()
        entryThumbnailBackfillTask = nil
        cloudEntryThumbnailBackfillTask?.cancel()
        cloudEntryThumbnailBackfillTask = nil
        completedStoryboardLoadTask?.cancel()
        completedStoryboardLoadTask = nil
        sampleContentLoadTask?.cancel()
        sampleContentLoadTask = nil
    }

    private func loadRemoteSampleContentIfNeeded() {
        if isSampleAuthorMode {
            sampleContentLoadTask?.cancel()
            sampleContentLoadTask = Task {
                guard let pack = try? await SupabaseSampleStoryService().loadAuthoringPack() else {
                    sampleEntries = []
                    sampleStoryboardsByEntryID = [:]
                    isLoadingCloudEntries = false
                    return
                }

                guard !Task.isCancelled else {
                    return
                }

                let visibleEntries = visibleAuthoringSampleEntries(from: pack.entries)
                sampleEntries = visibleEntries
                sampleStoryboardsByEntryID = sampleStoryboardsByMergingLocalFallbacks(
                    remoteStoryboardsByEntryID: pack.storyboardsByEntryID,
                    entries: visibleEntries,
                    repairsMissingRemote: true
                )
                isLoadingCloudEntries = false
                storeCurrentEntriesSessionSnapshot()
            }
            return
        }

        guard
            !shouldSuppressSamplesForSignedInUser,
            showsPrototypeData,
            entries.isEmpty,
            cloudEntries.isEmpty
        else {
            isLoadingSampleContent = false
            return
        }

        // The pack another sample screen already loaded, applied before anything is awaited. This
        // screen is destroyed and rebuilt on every navigation, so without this a return to Entries
        // renders an empty list first and fills it a moment later — even though the content was in
        // memory the whole time.
        let seededPack = contentMode.showsSampleContent ? SampleContentStore.pack : nil
        if let seededPack {
            applySamplePack(seededPack)
        }

        isLoadingSampleContent = seededPack == nil

        sampleContentLoadTask?.cancel()
        sampleContentLoadTask = Task {
            // Only the task that is still current may lower the flag. A superseded one reaching here
            // after its replacement raised it would drop the placeholder back to "No Entries" while
            // the replacement is still loading.
            defer {
                if !Task.isCancelled {
                    isLoadingSampleContent = false
                }
            }

            guard let pack = try? await SupabaseSampleStoryService().loadActivePack() else {
                return
            }

            guard
                !Task.isCancelled,
                !shouldSuppressSamplesForSignedInUser,
                entries.isEmpty,
                cloudEntries.isEmpty
            else {
                return
            }

            applySamplePack(pack)
            storeCurrentEntriesSessionSnapshot()
        }
    }

    private func applySamplePack(_ pack: SampleStoryPack) {
        sampleEntries = pack.entries
        sampleStoryboardsByEntryID = pack.storyboardsByEntryID
        if contentMode.showsSampleContent {
            // Same pack the Journals tab browses. Sharing one in-memory copy is what keeps a
            // sample entry openable from either screen without either of them writing to disk.
            SampleContentStore.replace(with: pack)
        }
    }

    private func visibleAuthoringSampleEntries(from entries: [CreateEntryDraft]) -> [CreateEntryDraft] {
        let deletedEntryIDs = DeletedAuthoringSampleEntryStore.load()
        guard !deletedEntryIDs.isEmpty else {
            return entries
        }

        return entries.filter { !deletedEntryIDs.contains($0.id) }
    }

    private func refreshEntries(forceCloudReload: Bool = false) {
        // A session still being checked is not a signed-out one. Falling through would clear the
        // list and load samples over content that is about to come back — and it is not an attempt
        // either, so the placeholder stays up rather than dropping to an empty state.
        guard contentMode.isResolved else {
            return
        }

        hasAttemptedEntriesLoad = true

        if isSampleAuthorMode {
            resetEntriesSessionState()
            entries = []
            sampleEntries = []
            sampleStoryboardsByEntryID = [:]
            completedStoryboards = []
            storyboardCountsByClientEntryID = [:]
            cloudEntries = []
            cloudEntryCounts = nil
            unjournaledEntryIDs = []
            cloudEntryThumbnails = [:]
            cloudEntryThumbnailVersions = [:]
            cloudEntriesErrorMessage = nil
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            isLoadingCloudEntries = true
            isLoadingMoreCloudEntries = false
            hasMoreCloudEntries = false
            nextCloudEntryOffset = 0
            isDraftSaved = false
            loadRemoteSampleContentIfNeeded()
            return
        }

        guard let userID = authStore.userID else {
            resetEntriesSessionState()
            entries = []
            sampleEntries = []
            sampleStoryboardsByEntryID = [:]
            completedStoryboards = []
            storyboardCountsByClientEntryID = [:]
            cloudEntries = []
            cloudEntryCounts = nil
            unjournaledEntryIDs = []
            cloudEntryThumbnails = [:]
            cloudEntryThumbnailVersions = [:]
            cloudEntriesErrorMessage = nil
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            isLoadingCloudEntries = false
            isLoadingMoreCloudEntries = false
            hasMoreCloudEntries = false
            nextCloudEntryOffset = 0
            isDraftSaved = false
            loadRemoteSampleContentIfNeeded()
            return
        }

        let queryKey = currentEntryQueryKey(userID: userID)
        hasLoadedEntriesForSession = true
        loadedEntryQueryKey = queryKey

        entries = CreateEntryDraftStore.loadAll()
        completedStoryboards = GeneratedStoryboardStore.load().filter { !$0.isSampleContent }
        scheduleCompletedStoryboardLoad()
        loadRemoteSampleContentIfNeeded()
        scheduleEntryThumbnailBackfill()
        scheduleCloudEntryThumbnailBackfill()
        isDraftSaved = false
        storeCurrentEntriesSessionSnapshot()

        // A forced reload deliberately keeps the thumbnails it already has. Dropping them here is
        // what put a screen of blank cards up on every sign-in: the images went, and the refetch
        // came back with the same entries, so the grid reused its cells and nothing asked for them
        // again. `restoreCachedCloudEntryThumbnails` drops the ones that are genuinely stale by
        // comparing versions, which is the narrower thing this was reaching for.

        let didHydrateCachedEntries = forceCloudReload ? false : hydrateCachedCloudEntries(for: queryKey)
        isLoadingCloudEntries = !didHydrateCachedEntries && filteredEntryItems.isEmpty
        storeCurrentEntriesSessionSnapshot()

        Task {
            await loadCloudEntriesIfNeeded(forceReload: forceCloudReload, queryKey: queryKey)
            await loadCloudStoryboardsIfNeeded(forceReload: forceCloudReload, userID: userID)
        }
    }

    private func hydrateCachedCloudEntries(for queryKey: EntriesCloudFetchCache.EntryQueryKey) -> Bool {
        guard let cachedEntries = EntriesCloudFetchCache.staleEntrySummaries(for: queryKey) else {
            return false
        }

        if cloudEntries != cachedEntries.entries {
            cloudEntries = cachedEntries.entries
        }
        updateEntriesSamplesCompletion()
        if let cachedCounts = cachedEntries.counts, cloudEntryCounts != cachedCounts {
            cloudEntryCounts = cachedCounts
        }
        hasMoreCloudEntries = cachedEntries.hasMore
        nextCloudEntryOffset = cachedEntries.nextOffset
        restoreCachedCloudEntryThumbnails()
        scheduleCloudEntryThumbnailBackfill()
        isDraftSaved = draftEntryItems.isEmpty == false
        cloudEntriesErrorMessage = nil
        isLoadingCloudEntries = false
        storeCurrentEntriesSessionSnapshot()
        return true
    }

    private func loadCloudEntriesIfNeeded(
        forceReload: Bool = false,
        queryKey providedQueryKey: EntriesCloudFetchCache.EntryQueryKey? = nil
    ) async {
        guard let userID = authStore.userID else {
            cloudEntries = []
            cloudEntriesErrorMessage = nil
            unjournaledEntryIDs = []
            isLoadingCloudEntries = false
            isLoadingMoreCloudEntries = false
            hasMoreCloudEntries = false
            nextCloudEntryOffset = 0
            return
        }

        let queryKey = providedQueryKey ?? currentEntryQueryKey(userID: userID)
        guard queryKey == currentEntryQueryKey(userID: userID) else {
            return
        }

        if selectedEntryTab != .addToJournal,
           !forceReload,
           let cachedEntries = EntriesCloudFetchCache.entrySummaries(for: queryKey) {
            if cloudEntries != cachedEntries.entries {
                cloudEntries = cachedEntries.entries
            }
            updateEntriesSamplesCompletion()
            if let cachedCounts = cachedEntries.counts {
                if cloudEntryCounts != cachedCounts {
                    cloudEntryCounts = cachedCounts
                }
            }
            hasMoreCloudEntries = cachedEntries.hasMore
            nextCloudEntryOffset = cachedEntries.nextOffset
            hasLoadedEntriesForSession = true
            loadedEntryQueryKey = queryKey
            restoreCachedCloudEntryThumbnails()
            scheduleCloudEntryThumbnailBackfill()
            isDraftSaved = draftEntryItems.isEmpty == false
            cloudEntriesErrorMessage = nil
            isLoadingCloudEntries = false
            storeCurrentEntriesSessionSnapshot()
            return
        }

        isLoadingCloudEntries = true
        isLoadingMoreCloudEntries = false
        hasMoreCloudEntries = true
        nextCloudEntryOffset = 0
        defer { isLoadingCloudEntries = false }

        do {
            let repository = SupabaseEntryRepository()
            if selectedEntryTab == .addToJournal {
                async let countsTask = repository.getEntrySummaryCounts()
                let currentUnjournaledEntryIDs = try await loadUnjournaledEntryIDs()
                let page = try await repository.getEntrySummaries(clientEntryIDs: currentUnjournaledEntryIDs)
                let counts = try? await countsTask

                guard queryKey == currentEntryQueryKey(userID: userID) else {
                    return
                }
                unjournaledEntryIDs = currentUnjournaledEntryIDs
                cloudEntries = page
                updateEntriesSamplesCompletion()
                if let counts, cloudEntryCounts != counts {
                    cloudEntryCounts = counts
                }
                hasMoreCloudEntries = false
                nextCloudEntryOffset = page.count
                hasLoadedEntriesForSession = true
                loadedEntryQueryKey = queryKey
                restoreCachedCloudEntryThumbnails()
                scheduleCloudEntryThumbnailBackfill()
                EntriesCloudFetchCache.storeEntrySummaries(
                    cloudEntries,
                    counts: cloudEntryCounts,
                    hasMore: hasMoreCloudEntries,
                    nextOffset: nextCloudEntryOffset,
                    for: queryKey
                )
                isDraftSaved = draftEntryItems.isEmpty == false
                cloudEntriesErrorMessage = nil
                storeCurrentEntriesSessionSnapshot()
                return
            }

            await refreshUnjournaledEntryIDs()
            async let pageTask = repository.getEntrySummariesPage(
                limit: cloudEntriesPageSize,
                offset: 0,
                sort: selectedEntrySort.summarySort,
                statusFilter: selectedEntryTab.summaryStatusFilter
            )
            async let countsTask = repository.getEntrySummaryCounts()

            let page = try await pageTask
            let counts = try? await countsTask

            guard queryKey == currentEntryQueryKey(userID: userID) else {
                return
            }
            if cloudEntries != page {
                cloudEntries = page
            }
            updateEntriesSamplesCompletion()
            if let counts, cloudEntryCounts != counts {
                cloudEntryCounts = counts
            }
            hasMoreCloudEntries = page.count == cloudEntriesPageSize
            nextCloudEntryOffset = page.count
            hasLoadedEntriesForSession = true
            loadedEntryQueryKey = queryKey
            restoreCachedCloudEntryThumbnails()
            scheduleCloudEntryThumbnailBackfill()
            EntriesCloudFetchCache.storeEntrySummaries(
                cloudEntries,
                counts: cloudEntryCounts,
                hasMore: hasMoreCloudEntries,
                nextOffset: nextCloudEntryOffset,
                for: queryKey
            )
            isDraftSaved = draftEntryItems.isEmpty == false
            cloudEntriesErrorMessage = nil
            storeCurrentEntriesSessionSnapshot()
        } catch {
            cloudEntriesErrorMessage = "Could not load cloud entries."
            storeCurrentEntriesSessionSnapshot()
        }
    }

    private func loadMoreCloudEntriesIfNeeded(currentIndex: Int, totalCount: Int) {
        guard authStore.userID != nil, totalCount > 0 else {
            return
        }
        guard currentIndex >= totalCount - 6 else {
            return
        }
        guard hasMoreCloudEntries, !isLoadingCloudEntries, !isLoadingMoreCloudEntries else {
            return
        }

        Task {
            await loadMoreCloudEntries()
        }
    }

    private func loadMoreCloudEntries() async {
        guard let userID = authStore.userID else {
            return
        }
        guard hasMoreCloudEntries, !isLoadingCloudEntries, !isLoadingMoreCloudEntries else {
            return
        }

        isLoadingMoreCloudEntries = true
        defer { isLoadingMoreCloudEntries = false }

        do {
            let page = try await SupabaseEntryRepository().getEntrySummariesPage(
                limit: cloudEntriesPageSize,
                offset: nextCloudEntryOffset,
                sort: selectedEntrySort.summarySort,
                statusFilter: selectedEntryTab.summaryStatusFilter
            )
            let existingIDs = Set(cloudEntries.map(\.clientEntryID))
            let newEntries = page.filter { !existingIDs.contains($0.clientEntryID) }
            cloudEntries.append(contentsOf: newEntries)
            updateEntriesSamplesCompletion()
            restoreCachedCloudEntryThumbnails()
            hasMoreCloudEntries = page.count == cloudEntriesPageSize
            nextCloudEntryOffset += page.count
            EntriesCloudFetchCache.storeEntrySummaries(
                cloudEntries,
                counts: cloudEntryCounts,
                hasMore: hasMoreCloudEntries,
                nextOffset: nextCloudEntryOffset,
                for: currentEntryQueryKey(userID: userID)
            )
            if selectedEntryTab != .drafts {
                await loadCloudStoryboardsIfNeeded(forceReload: true, userID: userID)
            }
            cloudEntriesErrorMessage = nil
            storeCurrentEntriesSessionSnapshot()
        } catch {
            cloudEntriesErrorMessage = "Could not load more cloud entries."
            storeCurrentEntriesSessionSnapshot()
        }
    }

    private func currentEntryQueryKey(userID: UUID) -> EntriesCloudFetchCache.EntryQueryKey {
        EntriesCloudFetchCache.EntryQueryKey(
            userID: userID,
            sort: selectedEntrySort.summarySort,
            statusFilter: selectedEntryTab.summaryStatusFilter
        )
    }

    private func loadCloudStoryboardsIfNeeded(forceReload: Bool = false, userID: UUID? = nil) async {
        guard let userID = userID ?? authStore.userID else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            storeCurrentEntriesSessionSnapshot()
            return
        }

        guard forceReload || selectedEntryTab == .addToJournal || EntriesCloudFetchCache.shouldLoadStoryboards(for: userID) else {
            return
        }

        guard !completedEntryItems.isEmpty else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            storeCurrentEntriesSessionSnapshot()
            return
        }

        do {
            let completedEntryIDs = Set(completedEntryItems.map(\.id))
            let storyboardRows = try await SupabaseStoryboardService().loadCompletedStoryboardRows(for: completedEntryIDs)
            let storyboardCounts = Dictionary(grouping: storyboardRows, by: \.clientEntryID)
                .mapValues(\.count)
            storyboardCountsByClientEntryID.merge(storyboardCounts) { _, newValue in newValue }
            completedEntryIDs
                .subtracting(storyboardCounts.keys)
                .forEach { storyboardCountsByClientEntryID[$0] = 0 }
            let localStoryboardIDs = Set(completedStoryboards.map(\.id))
            var rowsToDownload = storyboardRows.filter {
                !localStoryboardIDs.contains($0.id)
            }
            var mergedStoryboards = completedStoryboards

            rowsToDownload.removeAll { row in
                guard let cachedStoryboard = cachedCloudStoryboard(for: row) else {
                    return false
                }

                mergedStoryboards = GeneratedStoryboardStore.merging(cachedStoryboard, into: mergedStoryboards)
                return true
            }

            if mergedStoryboards.map(\.id) != completedStoryboards.map(\.id) {
                completedStoryboards = mergedStoryboards
                GeneratedStoryboardStore.save(mergedStoryboards)
            }

            cloudStoryboardClientIDs = Set(rowsToDownload.map(\.clientEntryID))
            failedCloudStoryboardClientIDs = []
            if selectedEntryTab != .addToJournal {
                EntriesCloudFetchCache.markStoryboardsLoaded(for: userID)
            }

            guard !rowsToDownload.isEmpty else {
                storeCurrentEntriesSessionSnapshot()
                return
            }

            for row in rowsToDownload {
                do {
                    let image = try await SupabaseStoryboardService().downloadStoryboardImage(storagePath: row.storagePath)
                    let cachedStoryboard = try GeneratedStoryboardStore.persistedStoryboard(
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
                    mergedStoryboards = GeneratedStoryboardStore.merging(cachedStoryboard, into: mergedStoryboards)
                    cloudStoryboardClientIDs.remove(row.clientEntryID)
                } catch {
                    cloudStoryboardClientIDs.remove(row.clientEntryID)
                    failedCloudStoryboardClientIDs.insert(row.clientEntryID)
                }
            }

            completedStoryboards = mergedStoryboards
            GeneratedStoryboardStore.save(mergedStoryboards)
            storeCurrentEntriesSessionSnapshot()
        } catch {
            failedCloudStoryboardClientIDs = cloudStoryboardClientIDs
            cloudStoryboardClientIDs = []
            storeCurrentEntriesSessionSnapshot()
        }
    }

    private func cachedCloudStoryboard(for row: EntryStoryboard) -> GeneratedStoryboard? {
        guard
            let cachedData = SupabaseStorageImageCache.data(
                bucketName: "generated-storyboards",
                storagePath: row.storagePath
            ),
            let image = UIImage(data: cachedData)
        else {
            return nil
        }

        return try? GeneratedStoryboardStore.persistedStoryboard(
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
    }

    private func openEntryItem(_ item: EntryDisplayItem, asCompleted: Bool, storyboardImage: UIImage? = nil) {
        guard openingEntryPreview == nil else {
            return
        }

        let openingStartedAt = Date()
        let minimumOpeningDuration: TimeInterval = 1.15
        let finishingZoomDuration: TimeInterval = 0.42
        let displayEntry = entryForDisplay(item)
        isFinishingEntryOpening = false
        withAnimation(.spring(response: 0.56, dampingFraction: 0.82)) {
            openingEntryPreview = EntryOpeningPreview(
                entry: displayEntry,
                sortOption: selectedEntrySort,
                isCompleted: asCompleted,
                storyboardImage: storyboardImage
            )
        }

        Task {
            let localID = await materializeCloudEntryIfNeeded(item)
            guard let localID else {
                withAnimation(.easeOut(duration: 0.18)) {
                    openingEntryPreview = nil
                    isFinishingEntryOpening = false
                }
                return
            }

            let elapsedOpeningTime = Date().timeIntervalSince(openingStartedAt)
            let remainingOpeningTime = minimumOpeningDuration - elapsedOpeningTime
            if remainingOpeningTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingOpeningTime * 1_000_000_000))
            }

            withAnimation(.spring(response: 0.44, dampingFraction: 0.8)) {
                isFinishingEntryOpening = true
            }
            try? await Task.sleep(nanoseconds: UInt64(finishingZoomDuration * 1_000_000_000))

            isOpeningEntryFromEntries = true
            isOpeningCompletedEntryFromEntries = asCompleted
            completedEntryOpenedStoryboardImage = storyboardImage
            activeDraftID = localID
            selectedPage = .create
        }
    }

    private func materializeCloudEntryIfNeeded(_ item: EntryDisplayItem) async -> UUID? {
        if item.cloudEntry == nil, let localDraftID = item.localDraftID {
            return localDraftID
        }

        // Opening an entry normally refreshes the local cache from the cloud. When the local copy
        // holds autosaved edits the user has not committed yet, that download is older than what is
        // on disk, so the entry is opened from disk instead — and the download is skipped entirely.
        if CreateEntryCloudMaterialization.decision(for: item.id) == .preserveLocalEdits {
            return item.id
        }

        var entry = entryForDisplay(item)
        let photos: [CreateEntryReferencePhoto]
        let characters: [EntryCharacter]
        if let cloudEntry = item.cloudEntry {
            do {
                let fullCloudEntry = try await SupabaseEntryRepository().getEntry(id: cloudEntry.id)
                entry = CreateEntryDraft.fromCloud(fullCloudEntry, thumbnail: entry.thumbnail)
                photos = try await SupabaseReferencePhotoService().loadReferencePhotos(entryID: fullCloudEntry.id)
            } catch {
                cloudEntriesErrorMessage = "Could not download this entry's reference photos."
                return nil
            }

            do {
                characters = try await SupabaseEntryCharacterService().loadCharacters(entryID: cloudEntry.id)
            } catch {
                print("[Journaltopia] Entry character download skipped: \(error.localizedDescription)")
                characters = []
            }
        } else {
            photos = []
            characters = entry.characters
        }

        if entry.thumbnail == nil {
            entry = entry.replacingThumbnail(renderThumbnail(for: entry, photos: []))
        }

        return CreateEntryDraftStore.save(
            id: entry.id,
            title: entry.title,
            text: entry.text,
            richText: entry.richText,
            referencePhotos: photos,
            characters: characters,
            artStyle: entry.artStyle,
            location: entry.location,
            date: entry.date,
            datePrecision: entry.datePrecision,
            savesDraft: entry.savesDraft,
            isPrivate: entry.isPrivate,
            status: JournalEntryStatus(rawValue: item.status) ?? .draft,
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
            createdAt: entry.createdAt,
            cloudSyncState: .synchronized
        )
    }

    private func restoreCachedCloudEntryThumbnails() {
        var updatedThumbnails = cloudEntryThumbnails
        var updatedVersions = cloudEntryThumbnailVersions
        var didUpdate = false
        let visibleCloudEntryIDs = Set(cloudEntries.map(\.clientEntryID))
        let localThumbnailsByID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.thumbnail.map { (entry.id, $0) }
        })

        for cloudEntry in cloudEntries {
            let clientEntryID = cloudEntry.clientEntryID

            if let localThumbnail = localThumbnailsByID[clientEntryID] {
                let localVersion = cloudThumbnailVersion(for: cloudEntry) ?? "local|\(Int(cloudEntry.updatedAt.timeIntervalSince1970 * 1000))"
                if updatedThumbnails[clientEntryID] == nil || updatedVersions[clientEntryID] != localVersion {
                    didUpdate = true
                }
                updatedThumbnails[clientEntryID] = localThumbnail
                updatedVersions[clientEntryID] = localVersion
                continue
            }

            guard let currentVersion = cloudThumbnailVersion(for: cloudEntry) else {
                let localVersion = localCloudThumbnailVersion(for: cloudEntry)
                if updatedVersions[clientEntryID] == localVersion, updatedThumbnails[clientEntryID] != nil {
                    continue
                }

                didUpdate = updatedThumbnails.removeValue(forKey: clientEntryID) != nil || didUpdate
                updatedVersions.removeValue(forKey: clientEntryID)
                continue
            }

            if updatedVersions[clientEntryID] != currentVersion {
                updatedThumbnails.removeValue(forKey: clientEntryID)
                updatedVersions[clientEntryID] = currentVersion
                didUpdate = true
            }

            guard updatedThumbnails[clientEntryID] == nil else {
                continue
            }

            guard let cachedImage = EntriesCloudThumbnailDiskCache.image(for: cloudEntry) else {
                continue
            }

            updatedThumbnails[clientEntryID] = cachedImage
            didUpdate = true
        }

        let trimmedThumbnails = updatedThumbnails.filter { clientEntryID, _ in
            visibleCloudEntryIDs.contains(clientEntryID)
        }
        let trimmedVersions = updatedVersions.filter { clientEntryID, _ in
            visibleCloudEntryIDs.contains(clientEntryID)
        }

        if didUpdate || trimmedThumbnails.count != cloudEntryThumbnails.count || trimmedVersions.count != cloudEntryThumbnailVersions.count {
            cloudEntryThumbnails = trimmedThumbnails
            cloudEntryThumbnailVersions = trimmedVersions
            storeCurrentEntriesSessionSnapshot()
        }
    }

    /// Identity for a card's thumbnail load, driving the `.task(id:)` each card attaches.
    ///
    /// This used to hang off `onAppear`, which fires once when a cell is *created* and never again
    /// while it stays on screen. Anything that dropped a loaded thumbnail afterwards — a forced
    /// reload on sign-in, a version bump — left the card blank with nothing left to ask for it, and
    /// the only cure was destroying the cell: scrolling it out of the lazy grid, or leaving the tab
    /// and coming back. Keying on whether an image is actually in hand makes losing one a reason to
    /// fetch it again, in place, without the cell going anywhere.
    private func cloudThumbnailLoadID(for item: EntryDisplayItem) -> String {
        let version = item.cloudEntry.flatMap { cloudThumbnailVersion(for: $0) } ?? "none"
        let state = cloudEntryThumbnails[item.id] == nil ? "missing" : "loaded"
        return "\(item.id.uuidString)|\(version)|\(state)"
    }

    @MainActor
    private func loadCloudThumbnailIfNeeded(for item: EntryDisplayItem) async {
        guard
            let cloudEntry = item.cloudEntry,
            cloudEntryThumbnails[item.id] == nil,
            !cloudThumbnailIDsBeingLoaded.contains(item.id)
        else {
            return
        }

        cloudThumbnailIDsBeingLoaded.insert(item.id)
        defer {
            cloudThumbnailIDsBeingLoaded.remove(item.id)
        }

        guard let thumbnailStoragePath = cloudEntry.thumbnailStoragePath else {
            await renderLocalCloudThumbnail(for: cloudEntry)
            return
        }

        // The disk cache is keyed by the same version this load is keyed on, so a hit here is the
        // right image, not a stale one. Worth asking before the network: a refresh that clears the
        // in-memory copies leaves this cache intact, and reading it back is instant.
        if let cachedThumbnail = EntriesCloudThumbnailDiskCache.image(for: cloudEntry) {
            applyCloudThumbnail(cachedThumbnail, for: cloudEntry, storesToDiskCache: false)
            return
        }

        do {
            let thumbnail = try await SupabaseEntryThumbnailService().downloadThumbnail(
                storagePath: thumbnailStoragePath,
                bypassCache: true
            )
            guard !Task.isCancelled else {
                return
            }

            applyCloudThumbnail(thumbnail, for: cloudEntry, storesToDiskCache: true)
        } catch {
            // A cancelled download is a card that scrolled away, not a thumbnail that failed to
            // arrive. Falling through to the local render would write a text-only page over an entry
            // whose real thumbnail is sitting in storage, and the load key would then read as
            // satisfied — so the good image would never be asked for again.
            guard !Task.isCancelled else {
                return
            }

            await renderLocalCloudThumbnail(for: cloudEntry)
        }
    }

    @MainActor
    private func applyCloudThumbnail(
        _ thumbnail: UIImage,
        for cloudEntry: JournalEntry,
        storesToDiskCache: Bool
    ) {
        cloudEntryThumbnails[cloudEntry.clientEntryID] = thumbnail
        cloudEntryThumbnailVersions[cloudEntry.clientEntryID] = cloudThumbnailVersion(for: cloudEntry)

        if storesToDiskCache {
            EntriesCloudThumbnailDiskCache.store(thumbnail, for: cloudEntry)
        }

        storeCurrentEntriesSessionSnapshot()
    }

    private func cloudThumbnailVersion(for entry: JournalEntry) -> String? {
        guard let storagePath = entry.thumbnailStoragePath else {
            return nil
        }

        let updatedAt = entry.thumbnailUpdatedAt ?? entry.updatedAt
        return "\(storagePath)|\(Int(updatedAt.timeIntervalSince1970 * 1000))"
    }

    @MainActor
    private func backfillMissingCloudEntryThumbnailsIfNeeded() async {
        var backfilledCount = 0
        var hasMoreMissingThumbnails = false

        for (index, cloudEntry) in cloudEntries.enumerated() {
            guard !Task.isCancelled else {
                return
            }
            guard backfilledCount < 4 else {
                hasMoreMissingThumbnails = true
                break
            }

            let clientEntryID = cloudEntry.clientEntryID
            guard cloudEntry.thumbnailStoragePath == nil, cloudEntryThumbnails[clientEntryID] == nil else {
                continue
            }

            backfilledCount += 1
            await renderLocalCloudThumbnail(for: cloudEntry)

            if index.isMultiple(of: 2) {
                await Task.yield()
            }
        }

        if hasMoreMissingThumbnails {
            scheduleCloudEntryThumbnailBackfill(delayNanoseconds: 1_500_000_000)
        }
    }

    @MainActor
    private func renderLocalCloudThumbnail(for cloudEntry: JournalEntry) async {
        guard cloudEntryThumbnails[cloudEntry.clientEntryID] == nil else {
            return
        }

        let entry = CreateEntryDraft.fromCloud(cloudEntry)
        guard let thumbnail = renderThumbnail(for: entry, photos: []) else {
            return
        }

        cloudEntryThumbnails[cloudEntry.clientEntryID] = thumbnail
        cloudEntryThumbnailVersions[cloudEntry.clientEntryID] = localCloudThumbnailVersion(for: cloudEntry)
        storeCurrentEntriesSessionSnapshot()
    }

    private func localCloudThumbnailVersion(for entry: JournalEntry) -> String {
        "local-render|\(entry.clientEntryID.uuidString.lowercased())|\(Int(entry.updatedAt.timeIntervalSince1970 * 1000))"
    }

    @MainActor
    private func backfillEntryThumbnailsIfNeeded() async {
        var didCreateThumbnail = false
        let storedRendererVersion = UserDefaults.standard.integer(forKey: thumbnailRendererVersionKey)
        let shouldRefreshExistingThumbnails = storedRendererVersion < thumbnailRendererVersion

        for (index, entry) in entries.enumerated() where shouldRefreshExistingThumbnails || entry.thumbnail == nil {
            guard !Task.isCancelled else {
                return
            }

            guard
                let thumbnail = DraftThumbnailRenderer.render(
                    title: entry.title,
                    text: entry.text,
                    richText: entry.richText,
                    photos: [],
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
                    textAlignmentRawValue: entry.textAlignmentRawValue
                )
            else {
                continue
            }

            CreateEntryDraftStore.saveThumbnail(thumbnail, for: entry.id)
            didCreateThumbnail = true

            if index.isMultiple(of: 2) {
                await Task.yield()
            }
        }

        if shouldRefreshExistingThumbnails {
            UserDefaults.standard.set(thumbnailRendererVersion, forKey: thumbnailRendererVersionKey)
        }

        if didCreateThumbnail {
            entries = CreateEntryDraftStore.loadAll()
        }
    }

    private func scheduleEntryThumbnailBackfill() {
        entryThumbnailBackfillTask?.cancel()
        entryThumbnailBackfillTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else {
                return
            }
            await backfillEntryThumbnailsIfNeeded()
        }
    }

    private func scheduleCloudEntryThumbnailBackfill(delayNanoseconds: UInt64 = 650_000_000) {
        cloudEntryThumbnailBackfillTask?.cancel()
        cloudEntryThumbnailBackfillTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await backfillMissingCloudEntryThumbnailsIfNeeded()
        }
    }

    private func scheduleCompletedStoryboardLoad() {
        completedStoryboardLoadTask?.cancel()
        completedStoryboardLoadTask = Task {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else {
                return
            }
            let storyboards = await Task.detached(priority: .utility) {
                GeneratedStoryboardStore.load().filter { !$0.isSampleContent }
            }.value

            guard !Task.isCancelled else {
                return
            }

            completedStoryboards = storyboards.reduce(into: completedStoryboards) { merged, storyboard in
                merged = GeneratedStoryboardStore.merging(storyboard, into: merged)
            }
            storeCurrentEntriesSessionSnapshot()
        }
    }

    private func renderThumbnail(for entry: CreateEntryDraft, photos: [UIImage]) -> UIImage? {
        DraftThumbnailRenderer.render(
            title: entry.title,
            text: entry.text,
            richText: entry.richText,
            photos: photos,
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
            textAlignmentRawValue: entry.textAlignmentRawValue
        )
    }

    private func updateEntriesSamplesCompletion() {
        guard authStore.userID != nil, !isSampleAuthorMode else {
            return
        }

        if !entries.isEmpty || !cloudEntries.isEmpty {
            hasCompletedEntriesSamples = true
            sampleEntries = []
        }
    }
}

private struct EntryListRow: View {
    let entry: CreateEntryDraft
    let sortOption: EntrySortOption
    var pageLabel: String? = nil
    var category: EntriesTab?
    var completedStoryboardImage: CompletedStoryboardImage?
    var completedStoryboardCount = 0
    var showsCompletedStoryboardCount = true
    var rowHeight = JournalChapterListMetrics.rowHeight
    var coverWidth = JournalChapterListMetrics.coverWidth
    var coverHeight = JournalChapterListMetrics.coverHeight
    var isSelecting = false
    var isSelected = false
    var isSample = false
    var showsReorderHandle = false
    var reorderEntryID: UUID?
    @Binding var draggingEntryID: UUID?
    var onSelect: (() -> Void)?

    init(
        entry: CreateEntryDraft,
        sortOption: EntrySortOption,
        pageLabel: String? = nil,
        category: EntriesTab? = nil,
        completedStoryboardImage: CompletedStoryboardImage? = nil,
        completedStoryboardCount: Int = 0,
        showsCompletedStoryboardCount: Bool = true,
        rowHeight: CGFloat = JournalChapterListMetrics.rowHeight,
        coverWidth: CGFloat = JournalChapterListMetrics.coverWidth,
        coverHeight: CGFloat = JournalChapterListMetrics.coverHeight,
        isSelecting: Bool = false,
        isSelected: Bool = false,
        isSample: Bool = false,
        showsReorderHandle: Bool = false,
        reorderEntryID: UUID? = nil,
        draggingEntryID: Binding<UUID?> = .constant(nil),
        onSelect: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.sortOption = sortOption
        self.pageLabel = pageLabel
        self.category = category
        self.completedStoryboardImage = completedStoryboardImage
        self.completedStoryboardCount = completedStoryboardCount
        self.showsCompletedStoryboardCount = showsCompletedStoryboardCount
        self.rowHeight = rowHeight
        self.coverWidth = coverWidth
        self.coverHeight = coverHeight
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.isSample = isSample
        self.showsReorderHandle = showsReorderHandle
        self.reorderEntryID = reorderEntryID
        _draggingEntryID = draggingEntryID
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 10) {
            if isSelecting {
                if let onSelect {
                    Button {
                        onSelect()
                    } label: {
                        listSelectionBadge
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Deselect \(entryDisplayTitle(entry))" : "Select \(entryDisplayTitle(entry))")
                } else {
                    listSelectionBadge
                }
            }

            entryIcon
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text(entryDisplayTitle(entry))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

            Spacer(minLength: 8)

            if let category {
                EntryCategoryPill(category: category)
                    .layoutPriority(1)
            }

            if isSample {
                EntrySampleBadge()
                    .layoutPriority(1)
            }

            VStack(alignment: .trailing, spacing: 2) {
                if let pageLabel {
                    Text(pageLabel)
                        .font(.system(size: 12, weight: .bold))
                } else {
                    Text(entryDateDisplay.label)
                        .font(.system(size: 10, weight: .bold))

                    Text(entryDateDisplay.dateText)
                        .font(.system(size: 12, weight: .regular))
                }
            }
            .foregroundStyle(Color.homeMutedText)
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)

            if showsReorderHandle, let reorderEntryID {
                EntryReorderHandle(entryID: reorderEntryID, draggingEntryID: $draggingEntryID)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("\(entryDisplayTitle(entry)), \(pageLabel ?? entryDateDisplay.inlineText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var listSelectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isSelected ? Color.storyPurple : Color.homeBorder)
            .frame(width: 28, height: 34)
    }

    private var entryIcon: some View {
        Group {
            if let completedStoryboardImage {
                storyboardThumbnail(completedStoryboardImage)
                    .overlay(alignment: .bottomTrailing) {
                        storyboardCountBadge
                            .offset(x: 5, y: 5)
                    }
            } else if let thumbnail = entry.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.storyInk.opacity(0.72))
            }
        }
        .frame(
            width: coverWidth,
            height: coverHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.storyInk.opacity(showsImageThumbnail ? 0.14 : 0), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func storyboardThumbnail(_ image: CompletedStoryboardImage) -> some View {
        switch image {
        case .asset(let imageName):
            Image(imageName)
                .resizable()
                .scaledToFill()
        case .uiImage(let uiImage):
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        case .loading:
            ZStack {
                Color.white
                ProgressView()
                    .controlSize(.small)
            }
        case .failed:
            ZStack {
                Color.white
                Image(systemName: "icloud.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }
        }
    }

    private var showsImageThumbnail: Bool {
        entry.thumbnail != nil || completedStoryboardImage != nil
    }

    @ViewBuilder
    private var storyboardCountBadge: some View {
        if showsCompletedStoryboardCount, completedStoryboardCount > 1 {
            Text("\(completedStoryboardCount)")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.storyPurple, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                )
                .shadow(color: Color.storyInk.opacity(0.18), radius: 4, y: 2)
        }
    }

    private var entryDateDisplay: EntryPreviewDateDisplay {
        entryPreviewDateDisplay(entry, sortOption: sortOption)
    }
}

private struct EntryCategoryPill: View {
    let category: EntriesTab

    var body: some View {
        Text(category.pillTitle)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(category.pillForegroundColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(category.pillBackgroundColor, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(category.pillBorderColor, lineWidth: 1)
            )
            .accessibilityLabel(category.title)
    }
}

private struct EntrySampleBadge: View {
    var body: some View {
        Text("Sample")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.storyPurple, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.20), radius: 3, y: 1)
            .accessibilityLabel("Sample")
    }
}

/// Where the floating controls sit above the tab bar, and how much room the scroll content has to
/// leave underneath so its last row is not left permanently hidden behind them.
private enum JournaltopiaFloatingControlMetrics {
    static let bottomInset: CGFloat = 84
    static let floatingButtonDiameter: CGFloat = 60
    static let signInCalloutHeight: CGFloat = 44

    /// The callout shares a row with the floating button but is the shorter of the two, so matching
    /// their bottom edges leaves them looking misaligned. Lifting it by half the height difference
    /// puts the two centre lines together instead.
    static let signInCalloutBottomInset: CGFloat =
        bottomInset + (floatingButtonDiameter - signInCalloutHeight) / 2

    /// What the scroll content adds underneath so its last row clears the callout. The floating
    /// button reaches further down the screen than this but sits against the trailing edge, where
    /// it covers a corner rather than a whole row.
    static let signInCalloutContentInset: CGFloat = 32
}

/// The one call to action on the signed-out browse screens, floating at the bottom centre above the
/// tab bar.
///
/// The sample badges say *what* this content is; this says what to do about it. It routes through
/// ``SignInGate`` rather than presenting `SignInView` itself so the sign-in page is still the single
/// one mounted at the app root, and so a visitor who signs in from here lands back where they were.
///
/// The label is kept short on purpose. Centred, it shares a row with a floating button pinned 20pt
/// from the trailing edge, so the pill has about 205pt to live in before the two touch on a 375pt
/// phone — a longer sentence collides there while still looking fine on a Pro.
private struct SampleSignInCallout: View {
    @EnvironmentObject private var signInGate: SignInGate

    var body: some View {
        Button {
            signInGate.requireAccount(for: .signIn)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))

                Text("Sign in to start")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(height: JournaltopiaFloatingControlMetrics.signInCalloutHeight)
            .background(Color.storyPurple, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            // It floats over the content rather than sitting in the layout, so it carries its own
            // separation from whatever scrolls underneath it.
            .shadow(color: Color.black.opacity(0.28), radius: 14, y: 6)
            .shadow(color: Color.storyPurple.opacity(0.34), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in to start")
        .accessibilityHint("Opens the sign in page")
    }
}

private enum EntrySelectionBadgeStyle {
    case standard
    case prominentGrid
}

private struct EntrySelectionBadge: View {
    let isSelected: Bool
    var style: EntrySelectionBadgeStyle = .standard

    var body: some View {
        switch style {
        case .standard:
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 23, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.white : Color.homeBorder, isSelected ? Color.storyPurple : Color.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.9), in: Circle())
                .shadow(color: Color.storyInk.opacity(0.14), radius: 5, y: 2)
        case .prominentGrid:
            ZStack {
                Circle()
                    .fill(isSelected ? Color.storyPurple : Color.white)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.clear : Color.homeBorder, lineWidth: 2.5)
                    )

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 26, height: 26)
            .shadow(color: Color.white.opacity(0.95), radius: 5, y: 0)
            .shadow(color: Color.storyInk.opacity(0.2), radius: 4, y: 2)
        }
    }
}

private struct EntryReorderHandle: View {
    let entryID: UUID
    @Binding var draggingEntryID: UUID?

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(Color.storyInk.opacity(0.58))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.08), radius: 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onDrag {
                draggingEntryID = entryID
                return NSItemProvider(object: entryID.uuidString as NSString)
            }
            .accessibilityLabel("Reorder entry")
    }
}

private func entryDisplayTitle(_ entry: CreateEntryDraft) -> String {
    let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? "Untitled Entry" : trimmedTitle
}

private struct EntryPreviewDateDisplay {
    let label: String
    let dateText: String

    var inlineText: String {
        "\(label): \(dateText)"
    }
}

private func entryPreviewDateDisplay(_ entry: CreateEntryDraft, sortOption: EntrySortOption) -> EntryPreviewDateDisplay {
    let label = sortOption.previewDateLabel
    let date: Date

    switch sortOption {
    case .manual:
        date = entry.createdAt
    case .entryDate, .entryDateOldest:
        date = entry.datePrecision == .noDate ? entry.createdAt : entry.date
    case .cloudCreated, .cloudCreatedOldest:
        date = entry.createdAt
    case .updated, .updatedOldest:
        date = entry.updatedAt
    }

    return EntryPreviewDateDisplay(
        label: label,
        dateText: date.formatted(date: .abbreviated, time: .omitted)
    )
}

private func entryPreviewDateText(_ entry: CreateEntryDraft, sortOption: EntrySortOption) -> String {
    entryPreviewDateDisplay(entry, sortOption: sortOption).inlineText
}

private struct EntryLoadingBar: View {
    let width: CGFloat?
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShimmering = false

    init(width: CGFloat? = nil, height: CGFloat) {
        self.width = width
        self.height = height
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)

        shape
            .fill(Color(red: 0.82, green: 0.83, blue: 0.88))
            .frame(width: width, height: height)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let shimmerWidth = max(proxy.size.width * 0.48, 22)

                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.58),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: shimmerWidth)
                        .offset(x: isShimmering ? proxy.size.width + shimmerWidth : -shimmerWidth)
                    }
                    .clipShape(shape)
                }
            }
            .onAppear {
                guard !reduceMotion else {
                    return
                }

                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    isShimmering = true
                }
            }
            .onChange(of: reduceMotion) { shouldReduceMotion in
                if shouldReduceMotion {
                    isShimmering = false
                } else {
                    withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                        isShimmering = true
                    }
                }
            }
    }
}

private struct EntryGridLoadingCard: View {
    let seed: Int

    @State private var isPulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.homeBorder.opacity(0.76), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 12) {
                    EntryLoadingBar(width: CGFloat(74 + (seed % 2) * 22), height: 14)
                        .padding(.top, 38)

                    EntryLoadingBar(width: CGFloat(118 - (seed % 3) * 14), height: 14)

                    EntryLoadingBar(width: CGFloat(86 + (seed % 3) * 12), height: 10)
                        .padding(.top, 10)

                    EntryLoadingBar(width: CGFloat(126 - (seed % 2) * 18), height: 10)

                    EntryLoadingBar(width: CGFloat(96 + (seed % 2) * 16), height: 10)

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)

                StoryPhotoTape(width: 48, height: 14, rotation: -2)
                    .opacity(0.62)
                    .offset(y: -7)
            }
            .aspectRatio(260.0 / 340.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .shadow(color: Color.storyInk.opacity(0.05), radius: 8, y: 4)
            .opacity(isPulsing ? 0.54 : 0.9)
            .animation(
                .easeInOut(duration: 0.88)
                    .repeatForever(autoreverses: true)
                    .delay(Double(seed) * 0.06),
                value: isPulsing
            )

            EntryLoadingBar(width: 78, height: 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(isPulsing ? 0.42 : 0.78)
        }
        .onAppear {
            isPulsing = true
        }
        .accessibilityHidden(true)
    }
}

/// The journals-grid counterpart to ``EntryGridLoadingCard``, so a sample pack still loading reads as
/// "on its way" rather than as an empty library.
private struct JournalCoverLoadingCard: View {
    let seed: Int
    let usesWideGridStyle: Bool

    @State private var isPulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
                .overlay(
                    VStack(alignment: .leading, spacing: 10) {
                        EntryLoadingBar(width: CGFloat(58 + (seed % 3) * 14), height: 11)
                        EntryLoadingBar(width: CGFloat(42 + (seed % 2) * 18), height: 9)

                        Spacer()
                    }
                    .padding(.horizontal, usesWideGridStyle ? 16 : 11)
                    .padding(.top, usesWideGridStyle ? 22 : 16),
                    alignment: .topLeading
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.homeBorder.opacity(0.76), lineWidth: 1)
                )
                .aspectRatio(usesWideGridStyle ? 168.0 / 208.0 : 104.0 / 136.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .shadow(color: Color.storyInk.opacity(0.05), radius: 8, y: 4)

            EntryLoadingBar(width: usesWideGridStyle ? 86 : 62, height: 9)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .opacity(isPulsing ? 0.54 : 0.9)
        .animation(
            .easeInOut(duration: 0.88)
                .repeatForever(autoreverses: true)
                .delay(Double(seed) * 0.06),
            value: isPulsing
        )
        .onAppear {
            isPulsing = true
        }
        .accessibilityHidden(true)
    }
}

private struct EntryListLoadingRow: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white)
                .overlay(
                    VStack(alignment: .leading, spacing: 7) {
                        EntryLoadingBar(width: 42, height: 8)
                        EntryLoadingBar(width: 56, height: 8)
                        EntryLoadingBar(width: 34, height: 8)
                    }
                    .padding(8),
                    alignment: .topLeading
                )
                .frame(
                    width: JournalChapterListMetrics.coverWidth,
                    height: JournalChapterListMetrics.coverHeight
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.homeBorder.opacity(0.76), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 9) {
                EntryLoadingBar(width: 132, height: 13)
                EntryLoadingBar(width: 86, height: 10)
            }

            Spacer(minLength: 8)

            EntryLoadingBar(width: 58, height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: JournalChapterListMetrics.rowHeight, alignment: .leading)
        .opacity(isPulsing ? 0.52 : 0.88)
        .animation(.easeInOut(duration: 0.88).repeatForever(autoreverses: true), value: isPulsing)
        .onAppear {
            isPulsing = true
        }
        .accessibilityHidden(true)
    }
}

private struct EntryPreviewDateBlock: View {
    let entry: CreateEntryDraft
    let sortOption: EntrySortOption
    var pageLabel: String? = nil

    var body: some View {
        Text(pageLabel ?? entryPreviewDateText(entry, sortOption: sortOption))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.homeMutedText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct EntryGridPreviewCard: View {
    let entry: CreateEntryDraft
    let sortOption: EntrySortOption
    var pageLabel: String? = nil
    let isEditing: Bool
    let showsActions: Bool
    let title: String
    var category: EntriesTab?
    var isOpening = false
    var isSelecting = false
    var isSelected = false
    var isSample = false
    var selectionBadgeStyle: EntrySelectionBadgeStyle = .standard
    var showsReorderHandle = false
    var reorderEntryID: UUID?
    @Binding var draggingEntryID: UUID?
    let onOpen: () -> Void
    let onDelete: () -> Void
    var deleteActionTitle: String = "Delete"
    var onRename: (() -> Void)?
    var onSelect: (() -> Void)?

    init(
        entry: CreateEntryDraft,
        sortOption: EntrySortOption,
        pageLabel: String? = nil,
        isEditing: Bool,
        showsActions: Bool,
        title: String,
        category: EntriesTab? = nil,
        isOpening: Bool = false,
        isSelecting: Bool = false,
        isSelected: Bool = false,
        isSample: Bool = false,
        selectionBadgeStyle: EntrySelectionBadgeStyle = .standard,
        showsReorderHandle: Bool = false,
        reorderEntryID: UUID? = nil,
        draggingEntryID: Binding<UUID?> = .constant(nil),
        onOpen: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        deleteActionTitle: String = "Delete",
        onRename: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.sortOption = sortOption
        self.pageLabel = pageLabel
        self.isEditing = isEditing
        self.showsActions = showsActions
        self.title = title
        self.category = category
        self.isOpening = isOpening
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.isSample = isSample
        self.selectionBadgeStyle = selectionBadgeStyle
        self.showsReorderHandle = showsReorderHandle
        self.reorderEntryID = reorderEntryID
        _draggingEntryID = draggingEntryID
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.deleteActionTitle = deleteActionTitle
        self.onRename = onRename
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                previewImage
                    .aspectRatio(260.0 / 340.0, contentMode: .fit)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: Color.storyInk.opacity(0.09), radius: 9, y: 5)
                    .overlay(alignment: .top) {
                        StoryPhotoTape(width: 48, height: 14, rotation: -2)
                            .offset(y: -7)
                    }

                if isSelecting {
                    Group {
                        if let onSelect {
                            Button {
                                onSelect()
                            } label: {
                                EntrySelectionBadge(isSelected: isSelected, style: selectionBadgeStyle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isSelected ? "Deselect \(title)" : "Select \(title)")
                        } else {
                            EntrySelectionBadge(isSelected: isSelected, style: selectionBadgeStyle)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if showsReorderHandle, let reorderEntryID {
                    EntryReorderHandle(entryID: reorderEntryID, draggingEntryID: $draggingEntryID)
                        .padding(.top, isSelecting && showsActions ? 42 : 8)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if isSelecting && showsActions {
                    JournalDeleteButton(
                        title: title,
                        visibleSize: 29,
                        backgroundColor: Color.red.opacity(0.1),
                        backgroundShape: .roundedRectangle,
                        visualAlignment: .topTrailing,
                        action: onDelete
                    )
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if let category {
                    EntryCategoryPill(category: category)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                if isSample && !isSelecting {
                    EntrySampleBadge()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            EntryPreviewDateBlock(entry: entry, sortOption: sortOption, pageLabel: pageLabel)
        }
        .contentShape(Rectangle())
        .scaleEffect(isOpening ? 0.96 : 1)
        .opacity(isOpening ? 0.62 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isOpening)
        .onTapGesture {
            if isSelecting, onSelect != nil {
                return
            } else {
                onOpen()
            }
        }
        .contextMenu {
            if showsActions {
                if let onRename {
                    Button {
                        onRename()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(deleteActionTitle, systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(pageLabel ?? entryPreviewDateText(entry, sortOption: sortOption))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var previewImage: some View {
        if let thumbnail = entry.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
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
}

private enum CompletedStoryboardImage {
    case asset(String)
    case uiImage(UIImage)
    case loading
    case failed
}

private struct CompletedEntryGridCard: View {
    let entry: CreateEntryDraft
    let title: String
    let sortOption: EntrySortOption
    let pageLabel: String?
    let storyboardImage: CompletedStoryboardImage
    let storyboardCount: Int
    let category: EntriesTab?
    let isOpening: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let isSample: Bool
    let selectionBadgeStyle: EntrySelectionBadgeStyle
    let showsReorderHandle: Bool
    let reorderEntryID: UUID?
    @Binding var draggingEntryID: UUID?
    let onOpen: () -> Void
    let onDelete: (() -> Void)?
    let deleteActionTitle: String
    let onRename: (() -> Void)?
    let onSelect: (() -> Void)?
    let accessibilityLabel: String

    init(
        entry: CreateEntryDraft,
        title: String,
        sortOption: EntrySortOption,
        pageLabel: String? = nil,
        storyboardImage: CompletedStoryboardImage,
        storyboardCount: Int = 0,
        category: EntriesTab? = nil,
        isOpening: Bool = false,
        isSelecting: Bool = false,
        isSelected: Bool = false,
        isSample: Bool = false,
        selectionBadgeStyle: EntrySelectionBadgeStyle = .standard,
        showsReorderHandle: Bool = false,
        reorderEntryID: UUID? = nil,
        draggingEntryID: Binding<UUID?> = .constant(nil),
        onOpen: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        deleteActionTitle: String = "Delete",
        onRename: (() -> Void)? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.title = title
        self.sortOption = sortOption
        self.pageLabel = pageLabel
        self.storyboardImage = storyboardImage
        self.storyboardCount = storyboardCount
        self.category = category
        self.isOpening = isOpening
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.isSample = isSample
        self.selectionBadgeStyle = selectionBadgeStyle
        self.showsReorderHandle = showsReorderHandle
        self.reorderEntryID = reorderEntryID
        _draggingEntryID = draggingEntryID
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.deleteActionTitle = deleteActionTitle
        self.onRename = onRename
        self.onSelect = onSelect
        accessibilityLabel = "Completed \(title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    entryPreviewImage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .top) {
                            StoryPhotoTape(width: 48, height: 14, rotation: -2)
                                .offset(y: -7)
                        }
                        .zIndex(0)

                    storyboardOverlay(in: proxy.size)
                        .zIndex(1)

                    if let category {
                        EntryCategoryPill(category: category)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .zIndex(2)
                    }

                    if isSample && !isSelecting {
                        EntrySampleBadge()
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .zIndex(2)
                    }

                    if isSelecting {
                        Group {
                            if let onSelect {
                                Button {
                                    onSelect()
                                } label: {
                                    EntrySelectionBadge(isSelected: isSelected, style: selectionBadgeStyle)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isSelected ? "Deselect \(title)" : "Select \(title)")
                            } else {
                                EntrySelectionBadge(isSelected: isSelected, style: selectionBadgeStyle)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .zIndex(3)
                    }

                    if showsReorderHandle, let reorderEntryID {
                        EntryReorderHandle(entryID: reorderEntryID, draggingEntryID: $draggingEntryID)
                            .padding(.top, isSelecting && onDelete != nil ? 42 : 8)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .zIndex(3)
                    }

                    if isSelecting, let onDelete {
                        JournalDeleteButton(
                            title: title,
                            visibleSize: 29,
                            backgroundColor: Color.red.opacity(0.1),
                            backgroundShape: .roundedRectangle,
                            visualAlignment: .topTrailing,
                            action: onDelete
                        )
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .zIndex(4)
                    }
                }
            }
                .aspectRatio(260.0 / 340.0, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: .infinity)
                .shadow(color: Color.storyInk.opacity(0.09), radius: 9, y: 5)

            EntryPreviewDateBlock(entry: entry, sortOption: sortOption, pageLabel: pageLabel)
        }
        .contentShape(Rectangle())
        .scaleEffect(isOpening ? 0.96 : 1)
        .opacity(isOpening ? 0.62 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isOpening)
        .onTapGesture {
            if isSelecting, onSelect != nil {
                return
            } else {
                onOpen()
            }
        }
        .contextMenu {
            if let onRename {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(deleteActionTitle, systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityLabel), \(pageLabel ?? entryPreviewDateText(entry, sortOption: sortOption))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var entryPreviewImage: some View {
        if let thumbnail = entry.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
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
            storyboardPreviewImage
                .frame(width: overlayWidth, height: overlayHeight)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.82), lineWidth: 1)
                )
                .shadow(color: Color.storyInk.opacity(0.08), radius: 3, y: 1)
                .zIndex(1)

            paperclipSymbol
                .offset(x: 1, y: -13)
                .zIndex(2)

            if storyboardCount > 1 {
                Text("\(storyboardCount)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.storyPurple, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
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

    private var paperclipSymbol: some View {
        Image(systemName: "paperclip")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(Color(red: 0.74, green: 0.76, blue: 0.82))
            .rotationEffect(.degrees(-34))
            .shadow(color: Color.white.opacity(0.75), radius: 1, y: 1)
            .shadow(color: Color.storyInk.opacity(0.12), radius: 1, y: 1)
    }

    @ViewBuilder
    private var storyboardPreviewImage: some View {
        switch storyboardImage {
        case .asset(let imageName):
            Image(imageName)
                .resizable()
                .scaledToFit()
        case .uiImage(let uiImage):
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        case .loading:
            ZStack {
                Color.white
                ProgressView()
                    .controlSize(.small)
            }
        case .failed:
            ZStack {
                Color.white
                Image(systemName: "icloud.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }
        }
    }
}

private struct EntryOpeningOverlay: View {
    let preview: EntryOpeningPreview
    let isFinishing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Color.homePageBackground.opacity(hasAppeared ? 0.92 : 0)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                openingPreviewCard
                    .frame(maxWidth: 284)
                    .rotationEffect(openingRotation)
                    .scaleEffect(openingScale)
                    .opacity(hasAppeared ? 1 : 0)
                    .shadow(color: Color.storyInk.opacity(0.16), radius: 18, y: 10)

                VStack(spacing: 4) {
                    Text("Opening entry...")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text(preview.isCompleted ? "Preparing your story and art" : "Preparing your draft")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                }
                .opacity(isFinishing ? 0 : (hasAppeared ? 1 : 0))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 82)
        }
        .onAppear {
            withAnimation(.spring(response: 0.78, dampingFraction: 0.78)) {
                hasAppeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening \(preview.title)")
    }

    private var openingScale: CGFloat {
        guard !reduceMotion else {
            return 1
        }

        if isFinishing {
            return 1.38
        }

        return hasAppeared ? 1.08 : 0.76
    }

    private var openingRotation: Angle {
        guard !reduceMotion else {
            return .degrees(0)
        }

        return .degrees(isFinishing ? 0 : (hasAppeared ? -1.4 : 5))
    }

    private var openingPreviewCard: some View {
        ZStack(alignment: .top) {
            previewImage
                .aspectRatio(260.0 / 340.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .top) {
                    StoryPhotoTape(width: 48, height: 14, rotation: -2)
                        .offset(y: -7)
                }

            if preview.isCompleted, let storyboardImage = preview.storyboardImage {
                GeometryReader { proxy in
                    completedStoryboardOverlay(storyboardImage, in: proxy.size)
                }
                .aspectRatio(260.0 / 340.0, contentMode: .fit)
            }
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        if let thumbnail = preview.entry.thumbnail {
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

    private func completedStoryboardOverlay(_ storyboardImage: UIImage, in size: CGSize) -> some View {
        let overlayHeight = size.height * 0.47
        let overlayWidth = overlayHeight * 0.72

        return ZStack(alignment: .topTrailing) {
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

            Image(systemName: "paperclip")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color(red: 0.74, green: 0.76, blue: 0.82))
                .rotationEffect(.degrees(-34))
                .shadow(color: Color.white.opacity(0.75), radius: 1, y: 1)
                .shadow(color: Color.storyInk.opacity(0.12), radius: 1, y: 1)
                .offset(x: 1, y: -13)
        }
        .frame(width: overlayWidth, height: overlayHeight)
        .rotationEffect(.degrees(2))
        .shadow(color: Color.storyInk.opacity(0.16), radius: 6, y: 4)
        .position(x: size.width * 0.76, y: size.height * 0.73)
    }
}

private enum EntriesTab: String, CaseIterable, Identifiable {
    case all
    case drafts
    case completed
    case addToJournal

    static let primaryFilters: [EntriesTab] = [.all, .drafts, .completed]
    static let secondaryFilters: [EntriesTab] = [.addToJournal]

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .drafts:
            return "Drafts"
        case .completed:
            return "Completed"
        case .addToJournal:
            return "Not in Journal"
        }
    }

    var pillTitle: String {
        switch self {
        case .all:
            return title
        case .drafts:
            return "Draft"
        case .completed:
            return "Completed"
        case .addToJournal:
            return "Not in Journal"
        }
    }

    var summaryStatusFilter: EntrySummaryStatusFilter {
        switch self {
        case .all:
            return .all
        case .drafts:
            return .drafts
        case .completed:
            return .completed
        case .addToJournal:
            return .addToJournal
        }
    }

    var pillForegroundColor: Color {
        switch self {
        case .all:
            return Color.storyInk
        case .drafts:
            return Color.homeAccent
        case .completed:
            return Color.white
        case .addToJournal:
            return Color.storyInk
        }
    }

    var pillBackgroundColor: Color {
        switch self {
        case .all:
            return Color.white
        case .drafts:
            return Color.homeAccent.opacity(0.11)
        case .completed:
            return Color.storyInk.opacity(0.88)
        case .addToJournal:
            return Color.homeAccent.opacity(0.11)
        }
    }

    var pillBorderColor: Color {
        switch self {
        case .all:
            return Color.homeBorder
        case .drafts:
            return Color.homeAccent.opacity(0.26)
        case .completed:
            return Color.storyInk.opacity(0.12)
        case .addToJournal:
            return Color.homeAccent.opacity(0.26)
        }
    }
}

private enum EntrySortOption: String, CaseIterable, Identifiable {
    case manual
    case entryDate
    case entryDateOldest
    case cloudCreated
    case cloudCreatedOldest
    case updated
    case updatedOldest

    static let menuOptions: [EntrySortOption] = [.manual, .cloudCreated, .updated]

    var id: String {
        rawValue
    }

    var menuTitle: String {
        switch self {
        case .manual:
            return "Custom Order"
        case .entryDate, .entryDateOldest:
            return "Story Date"
        case .cloudCreated, .cloudCreatedOldest:
            return "Created"
        case .updated, .updatedOldest:
            return "Edited"
        }
    }

    var title: String {
        switch self {
        case .manual:
            return "Custom Order"
        case .entryDate:
            return "Story Date: Newest"
        case .entryDateOldest:
            return "Story Date: Oldest"
        case .cloudCreated:
            return "Created: Newest"
        case .cloudCreatedOldest:
            return "Created: Oldest"
        case .updated:
            return "Edited: Newest"
        case .updatedOldest:
            return "Edited: Oldest"
        }
    }

    var shortTitle: String {
        switch self {
        case .manual:
            return "Custom Order"
        case .entryDate:
            return "Story: Newest"
        case .entryDateOldest:
            return "Story: Oldest"
        case .cloudCreated:
            return "Created: Newest"
        case .cloudCreatedOldest:
            return "Created: Oldest"
        case .updated:
            return "Edited: Newest"
        case .updatedOldest:
            return "Edited: Oldest"
        }
    }

    var displaySystemImage: String {
        switch self {
        case .manual:
            return systemImage
        case .entryDate, .cloudCreated, .updated:
            return "arrow.down"
        case .entryDateOldest, .cloudCreatedOldest, .updatedOldest:
            return "arrow.up"
        }
    }

    var systemImage: String {
        switch self {
        case .manual:
            return "line.3.horizontal"
        case .entryDate:
            return "calendar"
        case .entryDateOldest:
            return "calendar"
        case .cloudCreated:
            return "plus.circle"
        case .cloudCreatedOldest:
            return "plus.circle"
        case .updated:
            return "clock.arrow.circlepath"
        case .updatedOldest:
            return "clock"
        }
    }

    var previewDateLabel: String {
        switch self {
        case .manual, .cloudCreated, .cloudCreatedOldest:
            return "Created"
        case .entryDate, .entryDateOldest:
            return "Story Date"
        case .updated, .updatedOldest:
            return "Edited"
        }
    }

    var sortsAscending: Bool {
        switch self {
        case .entryDateOldest, .cloudCreatedOldest, .updatedOldest:
            return true
        case .manual, .entryDate, .cloudCreated, .updated:
            return false
        }
    }

    private var menuSelection: EntrySortOption {
        switch self {
        case .manual:
            return .manual
        case .entryDate, .entryDateOldest:
            return .entryDate
        case .cloudCreated, .cloudCreatedOldest:
            return .cloudCreated
        case .updated, .updatedOldest:
            return .updated
        }
    }

    private var toggledDirection: EntrySortOption {
        switch self {
        case .manual:
            return .manual
        case .entryDate:
            return .entryDateOldest
        case .entryDateOldest:
            return .entryDate
        case .cloudCreated:
            return .cloudCreatedOldest
        case .cloudCreatedOldest:
            return .cloudCreated
        case .updated:
            return .updatedOldest
        case .updatedOldest:
            return .updated
        }
    }

    var availableEntriesSelection: EntrySortOption {
        switch self {
        case .entryDate, .entryDateOldest:
            return .cloudCreated
        case .manual, .cloudCreated, .cloudCreatedOldest, .updated, .updatedOldest:
            return self
        }
    }

    func selection(afterChoosing option: EntrySortOption) -> EntrySortOption {
        guard option != .manual else {
            return .manual
        }

        return menuSelection == option ? toggledDirection : option
    }

    func menuSystemImage(for option: EntrySortOption) -> String {
        guard menuSelection == option else {
            return option.systemImage
        }

        return option == .manual ? "checkmark" : displaySystemImage
    }

    var summarySort: EntrySummarySort {
        switch self {
        case .manual:
            return .manual
        case .entryDate:
            return .entryDate
        case .entryDateOldest:
            return .entryDateAscending
        case .cloudCreated:
            return .createdAt
        case .cloudCreatedOldest:
            return .createdAtAscending
        case .updated:
            return .updatedAt
        case .updatedOldest:
            return .updatedAtAscending
        }
    }
}

private enum JournalEntryLayout: String {
    case grid
    case grid3x3
    case list

    var gridColumnCount: Int {
        switch self {
        case .grid:
            return 2
        case .grid3x3, .list:
            return 3
        }
    }

    var systemImage: String {
        switch self {
        case .grid:
            return "square.grid.2x2"
        case .grid3x3:
            return "square.grid.3x3"
        case .list:
            return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid:
            return "Show entries as 2 by 2 grid"
        case .grid3x3:
            return "Show entries as 3 by 3 grid"
        case .list:
            return "Show entries as list"
        }
    }
}

private enum JournalChapterListMetrics {
    static let rowHeight: CGFloat = 58
    static let horizontalInset: CGFloat = 16
    static let trailingInset: CGFloat = 12
    static let coverWidth: CGFloat = 36
    static let coverHeight: CGFloat = 48
}

private struct JournalChapterListRow: View {
    let chapter: PrototypeChapter
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    var isEditing = false
    var isSample = false
    var onDelete: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                JournalDragHandle()
            }

            JournalListCover(
                color: chapter.color,
                coverImage: coverImage,
                remoteCoverURL: remoteCoverURL,
                fallbackImageName: fallbackImageName,
                width: JournalChapterListMetrics.coverWidth,
                height: JournalChapterListMetrics.coverHeight
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text(chapter.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.storyInk)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if isSample {
                EntrySampleBadge()
                    .layoutPriority(1)
            }

            Text("\(chapter.entries.count) \(chapter.entries.count == 1 ? "entry" : "entries")")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)

            if isEditing {
                JournalDeleteButton(title: chapter.title, action: onDelete)
            }
        }
        .frame(height: JournalChapterListMetrics.rowHeight)
        .accessibilityLabel(chapter.title)
    }
}

private struct JournalListCover: View {
    let color: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 5,
                topTrailingRadius: 5,
                style: .continuous
            )
            .fill(color)

            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.black.opacity(0.12))
                    .clipped()
            } else if let remoteCoverURL {
                RemoteCoverImage(url: remoteCoverURL, placeholderColor: color)
                .overlay(Color.black.opacity(0.12))
                .clipped()
            } else if let fallbackImageName {
                Image(fallbackImageName)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.black.opacity(0.12))
                    .clipped()
            }

            HStack {
                Rectangle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 6)

                Spacer()

                Rectangle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 2)
            }

            HStack {
                Rectangle()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: 1)
                    .padding(.leading, 4)

                Spacer()
            }
        }
        .frame(width: width, height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 5,
                topTrailingRadius: 5,
                style: .continuous
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 3,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 5,
                topTrailingRadius: 5,
                style: .continuous
            )
            .stroke(Color.black.opacity(0.16), lineWidth: 0.8)
        )
        .shadow(color: color.opacity(0.20), radius: 4, y: 2)
    }
}

private struct NotebookCover: View {
    let color: Color
    let symbol: String?
    var coverImage: UIImage?
    var remoteCoverURL: URL?
    let imageName: String?
    var width: CGFloat = 48
    var height: CGFloat = 58

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)

            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.black.opacity(0.12))
                    .clipped()
            } else if let remoteCoverURL {
                RemoteCoverImage(url: remoteCoverURL, placeholderColor: color)
                .overlay(Color.black.opacity(0.12))
                .clipped()
            } else if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .overlay(Color.black.opacity(0.12))
                    .clipped()
            }

            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }

            HStack {
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 4)

                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 1)
                
                Spacer()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: color.opacity(0.25), radius: 5, y: 3)
    }
}

private struct JournalDetailBannerBackground: View {
    let color: Color
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?

    var body: some View {
        ZStack {
            bannerFill

            Color.black.opacity(0.46)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var bannerFill: some View {
        if let coverImage {
            fillImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
            }
        } else if let remoteCoverURL {
            fillImage {
                RemoteCoverImage(url: remoteCoverURL, placeholderColor: color)
            }
        } else if let fallbackImageName {
            fillImage {
                Image(fallbackImageName)
                    .resizable()
                    .scaledToFill()
            }
        } else {
            color
        }
    }

    private func fillImage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear
            .overlay {
                content()
            }
            .clipped()
    }
}

private struct JournalDetailCoverImage: View {
    let chapter: PrototypeChapter
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    var openHintProgress: CGFloat = 0
    var navigationOpenProgress: CGFloat = 0

    var body: some View {
        Color.clear
            .aspectRatio(JournalOpeningBook.compactAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let fullOpenProgress = min(max(navigationOpenProgress, 0), 1)
                    let hintProgress = fullOpenProgress > 0 ? 0 : openHintProgress

                    ZStack(alignment: .leading) {
                        hintPages
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: fullOpenProgress > 0 ? 0 : 9 + (hintProgress * 11))
                            .scaleEffect(
                                x: fullOpenProgress > 0 ? 1 : 0.98 - (hintProgress * 0.02),
                                y: fullOpenProgress > 0 ? 1 : 0.99,
                                anchor: .leading
                            )
                            .opacity(fullOpenProgress > 0 ? 1 : 0)

                        coverSurface
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .rotation3DEffect(
                                .degrees(fullOpenProgress > 0 ? -176 * Double(fullOpenProgress) : -8 * Double(hintProgress)),
                                axis: (x: 0, y: 1, z: 0),
                                anchor: .leading,
                                perspective: fullOpenProgress > 0 ? 0.18 : 0.66
                            )
                            .offset(
                                x: fullOpenProgress > 0 ? 0 : -3 * hintProgress,
                                y: fullOpenProgress > 0 ? 0 : -2 * hintProgress
                            )
                            .shadow(
                                color: Color.storyInk.opacity(0.13 + (Double(max(fullOpenProgress, hintProgress)) * 0.12)),
                                radius: 10 + (max(fullOpenProgress, hintProgress) * 5),
                                y: 5 + (max(fullOpenProgress, hintProgress) * 3)
                            )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
    }

    private var coverSurface: some View {
        cover
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                journalSpine
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
    }

    private var hintPages: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                .frame(width: 34)
            }
            .overlay(alignment: .trailing) {
                VStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { _ in
                        Capsule()
                            .fill(Color.homeBorder.opacity(0.58))
                            .frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 22)
                .opacity(0.52)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.82), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var cover: some View {
        GeometryReader { proxy in
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else if let remoteCoverURL {
                    RemoteCoverImage(url: remoteCoverURL, placeholderColor: chapter.color)
                } else if let fallbackImageName {
                    Image(fallbackImageName)
                        .resizable()
                        .scaledToFill()
                } else {
                    chapter.color
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var journalSpine: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.28),
                    Color.black.opacity(0.16),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 12.5)
            .padding(.leading, 14.25)
            .blendMode(.screen)
        }
        .frame(width: 22)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct PrototypeChapterDetailView: View {
    enum Presentation {
        case story
        case dailyJournal
    }

    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var chapter: PrototypeChapter
    @Binding var storyboardGenerationStatus: StoryboardGenerationGlobalStatus?
    let onCreateStory: (PrototypeEntry) -> Void
    let onNewEntryPresentationChange: (Bool) -> Void
    let onCreateEntryRequested: ((CreateEntryPresentation) -> Void)?
    let onChapterUpdated: (PrototypeChapter) -> Void
    let onOpenExistingEntry: ((CreateEntryDraft, Bool, UIImage?, CreateEntryPresentation) -> Void)?
    let contentMode: JournaltopiaContentMode
    let entryDate: Date

    private var isSampleAuthorMode: Bool {
        contentMode.isSampleAuthoring
    }

    /// A sample journal belongs to the pack, not to the visitor, so it offers no "write the first
    /// entry" button. Creating an entry is still one tap away on the Create tab, where the gate
    /// explains itself.
    private var allowsEntryCreation: Bool {
        contentMode.canPersistUserContent || contentMode.isSampleAuthoring
    }
    let presentation: Presentation

    @State private var selectedSection = "Media"
    @State private var isShowingNewStory = false
    @State private var selectedMediaIndex: Int?
    @State private var draftEntryText = ""
    @State private var draftStoryTitle = ""
    @State private var draftStoryboardPhotos: [CreateEntryReferencePhoto?] = Array(repeating: nil, count: 5)
    @State private var isDraftSaved = false
    @State private var activeDraftID: UUID?
    @State private var generatedStoryboards: [GeneratedStoryboard] = []
    @State private var completedEntryOpenedStoryboardImage: UIImage?
    @State private var isOpeningCompletedEntryFromEntries = false
    @State private var isOpeningExistingEntryFromJournal = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var journalDetailSelectionBarAction: JournalDetailSelectionBarAction?
    @State private var draggingEntryID: UUID?
    @State private var isShowingCoverCustomization = false
    @State private var pendingCoverSync: PendingJournalCoverSync?
    @State private var isCoverSyncInProgress = false
    @State private var isComicReaderPresented = false
    @State private var comicPageIndex = 0
    @State private var bookOpenHintProgress: CGFloat = 0
    @State private var bookNavigationOpenProgress: CGFloat = 0
    @State private var isOpeningJournalComicReader = false
    @State private var skipsBookOpenHintOnNextAppear = false
    @State private var bookOpenHintTask: Task<Void, Never>?
    @State private var mediaStoryboards: [GeneratedStoryboard] = []
    @State private var isLoadingMediaStoryboards = false
    @State private var mediaStoryboardErrorMessage: String?
    @State private var hasLoadedMediaStoryboards = false
    @State private var lastMediaLoadEntryIDs: Set<UUID> = []
    @State private var draggingMediaStoryboardID: UUID?
    @State private var hasVisibleJournalEntries: Bool
    @State private var detailMembershipSnapshot: JournalDetailMembershipSnapshot
    @State private var displayedMediaStoryboardCount: Int
    @State private var cachedHeroCoverImage: UIImage?
    @State private var cachedHeroCoverStorageKey: String?
    @State private var journalDetailSheetScrollOffsetY: CGFloat = 0
    @State private var pendingJournalDetailSheetScrollOffsetY: CGFloat?

    private var sections: [String] {
        ["Pages", "Media"]
    }

    private static func initialSection(for _: PrototypeChapter, presentation: Presentation) -> String {
        presentation == .dailyJournal ? "Pages" : "Media"
    }

    private var mediaImageNames: [String] {
        chapter.entries.flatMap(\.imageNames)
    }

    private var mediaClientEntryIDs: Set<UUID> {
        detailMembershipSnapshot.mediaClientEntryIDs
    }

    private func storyboardCoverCandidates(for chapter: PrototypeChapter) -> [JournalStoryboardCoverCandidate] {
        let entryIDs = Set(chapter.entries.map(\.id)).union(mediaClientEntryIDs)
        guard !entryIDs.isEmpty else {
            return []
        }

        var seen = Set<UUID>()
        return GeneratedStoryboardStore.load(clientEntryIDs: entryIDs)
            .filter { storyboard in
                guard
                    let clientEntryID = storyboard.clientEntryID,
                    entryIDs.contains(clientEntryID)
                else {
                    return false
                }

                return storyboard.isPrimary && seen.insert(storyboard.id).inserted
            }
            .sorted { $0.createdAt > $1.createdAt }
            .map(JournalStoryboardCoverCandidate.init(storyboard:))
    }

    private func applyJournalCustomization(_ customization: JournalCustomization) {
        if let storedCoverImage = customization.storedCoverImage {
            JournalCoverStore.save(storedCoverImage, for: chapter)
        } else if customization.clearsStoredCover {
            JournalCoverStore.delete(for: chapter)
        }

        let updatedChapter = PrototypeChapter(
            id: chapter.id,
            title: chapter.title,
            subtitle: chapter.subtitle,
            color: customization.color,
            symbol: chapter.symbol,
            coverImageName: customization.coverImageName,
            remoteCover: customization.remoteCover,
            kind: chapter.kind,
            isFavorite: chapter.isFavorite,
            createdAt: chapter.createdAt,
            updatedAt: Date(),
            entries: chapter.entries
        )

        chapter = updatedChapter
        onChapterUpdated(updatedChapter)
        refreshCachedHeroCoverImage(
            storedCoverImage: customization.storedCoverImage,
            force: customization.storedCoverImage != nil || customization.clearsStoredCover
        )
        if isSampleAuthorMode {
            syncSampleJournalCoverCustomization(
                updatedChapter,
                storedCoverImage: customization.storedCoverImage,
                clearsStoredCover: customization.clearsStoredCover
            )
            return
        }

        UserChapterStore.updateAppearance(
            id: updatedChapter.id,
            color: updatedChapter.color,
            coverImageName: updatedChapter.coverImageName,
            remoteCover: updatedChapter.remoteCover
        )
        syncJournalCoverToCloud(PendingJournalCoverSync(
            chapter: updatedChapter,
            uploadsStoredCover: customization.storedCoverImage != nil,
            clearsStoredCover: customization.clearsStoredCover
        ))
    }

    private func syncSampleJournalCoverCustomization(
        _ updatedChapter: PrototypeChapter,
        storedCoverImage: UIImage?,
        clearsStoredCover: Bool
    ) {
        Task {
            let service = SupabaseSampleStoryService()
            do {
                let pack = try await service.loadAuthoringPack()
                guard let existingJournal = pack.journals.first(where: { $0.id == updatedChapter.id }) else {
                    return
                }

                let preservesStoredCover = storedCoverImage == nil
                    && !clearsStoredCover
                    && updatedChapter.remoteCover == nil
                    && updatedChapter.coverImageName?.trimmedOrNil == nil
                var coverStoragePath = preservesStoredCover ? existingJournal.coverStoragePath : nil
                if let storedCoverImage {
                    coverStoragePath = try await service.uploadSampleJournalCover(
                        storedCoverImage,
                        journalID: updatedChapter.id
                    )
                }

                let sampleJournal = SampleJournal(
                    id: existingJournal.id,
                    packID: existingJournal.packID,
                    title: updatedChapter.title,
                    subtitle: updatedChapter.subtitle,
                    colorHex: JournalColorOption.hexString(for: updatedChapter.color),
                    symbol: updatedChapter.symbol,
                    coverImageName: updatedChapter.coverImageName,
                    coverStoragePath: coverStoragePath,
                    remoteCover: updatedChapter.remoteCover,
                    kind: updatedChapter.kind == .storyboard ? "storyboard" : "journal",
                    isFavorite: updatedChapter.isFavorite,
                    displayOrder: existingJournal.displayOrder,
                    entries: existingJournal.entries,
                    createdAt: existingJournal.createdAt,
                    updatedAt: Date()
                )
                try await service.updateSampleJournal(sampleJournal)
            } catch {
                print("[Journaltopia] Sample journal detail cover sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func retryPendingCoverSync() {
        guard let pendingCoverSync else {
            return
        }

        syncJournalCoverToCloud(pendingCoverSync)
    }

    private func restorePendingCoverSyncIfNeeded() {
        guard pendingCoverSync == nil else {
            return
        }

        pendingCoverSync = PendingJournalCoverSyncStore.pendingSync(for: chapter)
    }

    private func syncJournalCoverToCloud(_ pendingSync: PendingJournalCoverSync) {
        pendingCoverSync = nil
        isCoverSyncInProgress = true
        PendingJournalCoverSyncStore.save(pendingSync)

        Task {
            do {
                try await UserChapterStore.syncCoverCustomizationToCloud(
                    pendingSync.chapter,
                    storedCoverImage: pendingSync.storedCoverImage,
                    requiresStoredCoverUpload: pendingSync.uploadsStoredCover,
                    clearsStoredCover: pendingSync.clearsStoredCover
                )

                await MainActor.run {
                    PendingJournalCoverSyncStore.delete(id: pendingSync.id)
                    pendingCoverSync = nil
                    isCoverSyncInProgress = false
                }
            } catch {
                await MainActor.run {
                    pendingCoverSync = pendingSync
                    isCoverSyncInProgress = false
                }
            }
        }
    }

    init(
        chapter: PrototypeChapter,
        entryDate: Date = Date(),
        presentation: Presentation = .story,
        storyboardGenerationStatus: Binding<StoryboardGenerationGlobalStatus?> = .constant(nil),
        onNewEntryPresentationChange: @escaping (Bool) -> Void = { _ in },
        onCreateEntryRequested: ((CreateEntryPresentation) -> Void)? = nil,
        onChapterUpdated: @escaping (PrototypeChapter) -> Void = { _ in },
        onOpenExistingEntry: ((CreateEntryDraft, Bool, UIImage?, CreateEntryPresentation) -> Void)? = nil,
        contentMode: JournaltopiaContentMode = .user,
        onCreateStory: @escaping (PrototypeEntry) -> Void
    ) {
        let initialMembershipSnapshot = JournalDetailMembershipSnapshot.make(for: chapter)

        _chapter = State(initialValue: chapter)
        _storyboardGenerationStatus = storyboardGenerationStatus
        _selectedSection = State(initialValue: Self.initialSection(for: chapter, presentation: presentation))
        _hasVisibleJournalEntries = State(initialValue: Self.hasLocalEntries(for: chapter))
        _detailMembershipSnapshot = State(initialValue: initialMembershipSnapshot)
        _displayedMediaStoryboardCount = State(
            initialValue: GeneratedStoryboardStore.count(clientEntryIDs: initialMembershipSnapshot.mediaClientEntryIDs)
        )
        self.entryDate = entryDate
        self.presentation = presentation
        self.onNewEntryPresentationChange = onNewEntryPresentationChange
        self.onCreateEntryRequested = onCreateEntryRequested
        self.onChapterUpdated = onChapterUpdated
        self.onOpenExistingEntry = onOpenExistingEntry
        self.contentMode = contentMode
        self.onCreateStory = onCreateStory
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                Color.homePageBackground
                    .ignoresSafeArea()

                journalDetailLowerBannerBackground(proxy: proxy)

                journalHeroHeader(toolbarBottomOffset: proxy.safeAreaInsets.top + 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)

                journalDetailSheetScroll(proxy: proxy)
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.light)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.black.opacity(0.34), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .tint(.white)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard signInGate.requireAccount(for: .customizeJournalCover, retry: { isShowingCoverCustomization = true }) else {
                        return
                    }

                    isShowingCoverCustomization = true
                } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Change Cover")
                                .font(.system(size: 13, weight: .semibold))
                        }

                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .fixedSize()
                }
                .accessibilityLabel("Change journal cover")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationDestination(isPresented: $isShowingNewStory) {
            CreateEntryView(
                presentation: newEntryPresentation,
                entryText: $draftEntryText,
                storyTitle: $draftStoryTitle,
                storyboardPhotos: $draftStoryboardPhotos,
                isDraftSaved: $isDraftSaved,
                activeDraftID: $activeDraftID,
                selectedPage: Binding(
                    get: { .journal },
                    set: { _ in }
                ),
                generatedStoryboards: $generatedStoryboards,
                completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
                isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
                storyboardGenerationStatus: $storyboardGenerationStatus,
                existingEntryStartsReadOnly: isOpeningExistingEntryFromJournal,
                dismissCreate: {
                    isShowingNewStory = false
                    isOpeningExistingEntryFromJournal = false
                },
                onJournalEntryCreated: { _, entry in
                    if let existingIndex = chapter.entries.firstIndex(where: { $0.id == entry.id }) {
                        chapter.entries[existingIndex] = entry
                    } else {
                        chapter.entries.insert(entry, at: 0)
                    }
                    hasVisibleJournalEntries = true
                    selectedSection = "Pages"
                    onCreateStory(entry)
                }
            )
        }
        .sheet(isPresented: $isShowingCoverCustomization) {
            JournalCustomizationSheet(
                chapter: chapter,
                initialStoryboardCovers: storyboardCoverCandidates(for: chapter),
                onSave: applyJournalCustomization
            )
        }
        .onChange(of: isShowingNewStory) { isShowing in
            onNewEntryPresentationChange(isShowing)
            if !isShowing, selectedSection == "Media" {
                Task {
                    await loadMediaStoryboards(force: true)
                }
            }
        }
        .onChange(of: chapter.entries.map(\.id)) { _ in
            refreshDetailMembershipSnapshot()
            resortMediaStoryboardsToEntryOrder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaGeneratedStoryboardPrimaryChanged)) { _ in
            refreshMediaStoryboardsFromLocalStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaGeneratedStoryboardsChanged)) { _ in
            refreshMediaStoryboardsFromLocalStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaJournalCoverChanged)) { notification in
            guard
                let journalID = notification.userInfo?["journalID"] as? UUID,
                journalID == chapter.id
            else {
                return
            }

            refreshCachedHeroCoverImage(force: true)
        }
        .onChange(of: selectedSection) { newSection in
            if newSection != "Pages" {
                editMode = .inactive
                selectedEntryIDs = []
                journalDetailSelectionBarAction = nil
                draggingEntryID = nil
            }
            if newSection != "Media" {
                draggingMediaStoryboardID = nil
            }

            if newSection == "Media" {
                refreshDetailMembershipSnapshot()
                resortMediaStoryboardsToEntryOrder()
                Task {
                    await loadMediaStoryboardsIfNeeded()
                }
            }
        }
        .onChange(of: authStore.userID) { userID in
            guard userID != nil else {
                return
            }

            restorePendingCoverSyncIfNeeded()
            retryPendingCoverSync()
            refreshDetailMembershipSnapshot()
            hasLoadedMediaStoryboards = false
            lastMediaLoadEntryIDs = []
            if selectedSection == "Media" {
                Task {
                    await loadMediaStoryboardsIfNeeded(force: true)
                }
            }
        }
        .onChange(of: isComicReaderPresented) { isPresented in
            if !isPresented {
                bookNavigationOpenProgress = 0
                isOpeningJournalComicReader = false
            }
        }
        .navigationDestination(isPresented: $isComicReaderPresented) {
            JournalStoryboardComicReaderView(
                storyboards: comicReaderStoryboards,
                currentPageIndex: $comicPageIndex,
                journalTitle: chapter.title,
                journalColor: chapter.color,
                coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter) : nil,
                remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
                fallbackCoverImageName: chapter.coverImageName,
                pageCountText: pageCountText,
                storyboardCountText: comicReaderStoryboardCountText,
                chapter: chapter,
                storyboardCoverCandidates: storyboardCoverCandidates(for: chapter),
                onCoverCustomized: applyJournalCustomization
            )
        }
        .onAppear {
            restorePendingCoverSyncIfNeeded()
            refreshDetailMembershipSnapshot()
            refreshCachedHeroCoverImage()

            guard !skipsBookOpenHintOnNextAppear else {
                skipsBookOpenHintOnNextAppear = false
                return
            }

            // Defer the book-open hint so it does not compete with first-content loading.
            bookOpenHintTask?.cancel()
            bookOpenHintTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else {
                    return
                }
                playBookOpenHint()
            }
        }
        .onDisappear {
            bookOpenHintTask?.cancel()
            bookOpenHintTask = nil
            bookOpenHintProgress = 0
            bookNavigationOpenProgress = 0
            isOpeningJournalComicReader = false
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedMediaIndex != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedMediaIndex = nil
                    }
                }
            )
        ) {
            if let selectedMediaIndex,
               mediaStoryboardItems.indices.contains(selectedMediaIndex) {
                let selectedStoryboard = mediaStoryboardItems[selectedMediaIndex].storyboard
                let viewerStoryboards = mediaViewerStoryboards(for: selectedStoryboard)
                StoryboardImageViewer(
                    storyboards: viewerStoryboards,
                    initialIndex: viewerStoryboards.firstIndex(where: { $0.id == selectedStoryboard.id }) ?? 0
                )
            }
        }
        // Selection bar and write button stay as outer overlays so the
        // full-bleed detail sheet cannot cover them or drag them.
        .overlay(alignment: .bottom) {
            journalDetailSelectedEntriesToolbar
                .animation(.easeInOut(duration: 0.18), value: selectedEntryIDs.isEmpty)
                .animation(.easeInOut(duration: 0.18), value: editMode)
        }
        .overlay(alignment: .bottomTrailing) {
            journalDetailFloatingWriteButton
                .padding(.trailing, 20)
                .padding(.bottom, 0)
                .opacity(showsJournalDetailWriteButton ? 1 : 0)
                .allowsHitTesting(showsJournalDetailWriteButton)
                .accessibilityHidden(!showsJournalDetailWriteButton)
        }
    }

    private var showsJournalDetailWriteButton: Bool {
        hasVisibleJournalEntries || !chapter.entries.isEmpty || !detailMembershipSnapshot.memberIDs.isEmpty
    }

    private var journalDetailFloatingWriteButton: some View {
        Button {
            playJournalFloatingButtonHaptic()
            openFreshEntryFromJournalDetail()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .offset(x: 0, y: -2)
                .background(Color.black, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write")
    }

    @ViewBuilder
    private var journalDetailSelectedEntriesToolbar: some View {
        if editMode == .active && !selectedEntryIDs.isEmpty {
            HStack(spacing: 12) {
                Text("\(selectedEntryIDs.count) selected")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                journalDetailSelectedEntriesOverflowMenu

                Button {
                    journalDetailSelectionBarAction = .addToJournal
                } label: {
                    Label("Add to Journal", systemImage: "book.closed.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add selected entries to a journal")
            }
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.08), radius: 10, y: 5)
            .padding(.horizontal, 16)
            .padding(.bottom, 72)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
        }
    }

    private var journalDetailSelectedEntriesOverflowMenu: some View {
        Menu {
            Button {
                journalDetailSelectionBarAction = .duplicateSelected
            } label: {
                Label(
                    selectedEntryIDs.count == 1 ? "Duplicate Entry" : "Duplicate \(selectedEntryIDs.count) Entries",
                    systemImage: "doc.on.doc"
                )
            }

            Button(role: .destructive) {
                journalDetailSelectionBarAction = .deleteSelected
            } label: {
                Label(
                    selectedEntryIDs.count == 1 ? "Delete Entry" : "Delete \(selectedEntryIDs.count) Entries",
                    systemImage: "trash"
                )
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Color.storyInk.opacity(0.76))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.homeBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions for selected entries")
    }

    private func journalDetailLowerBannerBackground(proxy: GeometryProxy) -> some View {
        let metrics = journalHeroMetrics(toolbarBottomOffset: proxy.safeAreaInsets.top + 44)

        return VStack(spacing: 0) {
            journalDetailBannerBackdrop
                .frame(maxWidth: .infinity)
                .frame(height: metrics.backdropHeight)

            journalDetailBannerBackdrop
                .frame(maxWidth: .infinity)
                .frame(height: metrics.backdropHeight)
                .scaleEffect(x: 1, y: -1, anchor: .center)

            journalDetailBannerBackdrop
                .frame(maxWidth: .infinity)
                .frame(height: max(0, proxy.size.height - (metrics.backdropHeight * 2) + proxy.safeAreaInsets.bottom))
                .scaleEffect(x: 1, y: -1, anchor: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: [.top, .bottom])
        .allowsHitTesting(false)
    }

    private var journalDetailBannerBackdrop: some View {
        ZStack {
            JournalDetailBannerBackground(
                color: chapter.color,
                coverImage: cachedHeroCoverImage,
                remoteCoverURL: chapter.remoteCover?.imageNSURL ?? chapter.remoteCover?.thumbnailNSURL,
                fallbackImageName: chapter.coverImageName
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.62),
                    Color.black.opacity(0.42),
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func journalDetailSheetScroll(proxy: GeometryProxy) -> some View {
        let sheetTopOffset = journalDetailSheetTopOffset(
            height: proxy.size.height,
            safeAreaTop: proxy.safeAreaInsets.top
        )
        let bottomPadding = 112 + proxy.safeAreaInsets.bottom + min(sheetTopOffset * 0.45, 260)

        return ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                journalDetailSheetScrollOffsetMarker

                journalHeroSpacerTapTargets(height: sheetTopOffset, proxy: proxy)

                journalDetailSheetTopChrome
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.homePageBackground, ignoresSafeAreaEdges: [])
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 32,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 32,
                            style: .continuous
                        )
                    )
                    .shadow(color: Color.storyInk.opacity(0.12), radius: 22, y: -8)

                if selectedSection == "Pages" {
                    JournalDetailEntryBrowser(
                        chapter: chapter,
                        editMode: $editMode,
                        selectedEntryIDs: $selectedEntryIDs,
                        selectionBarAction: $journalDetailSelectionBarAction,
                        contentMode: contentMode,
                        allowsCreation: allowsEntryCreation,
                        scrollViewportHeight: proxy.size.height,
                        onCreateEntry: {
                            openFreshEntryFromJournalDetail()
                        },
                        onOpenEntry: { entry, isCompleted, storyboardImage in
                            if let onOpenExistingEntry {
                                onOpenExistingEntry(
                                    entry,
                                    isCompleted,
                                    storyboardImage,
                                    .editDraftInJournal(title: chapter.title)
                                )
                            } else {
                                activeDraftID = entry.id
                                isOpeningCompletedEntryFromEntries = isCompleted
                                isOpeningExistingEntryFromJournal = true
                                completedEntryOpenedStoryboardImage = storyboardImage
                                generatedStoryboards = GeneratedStoryboardStore.load(clientEntryIDs: [entry.id])
                                isShowingNewStory = true
                            }
                        },
                        onEntriesChanged: { entries in
                            let hadKnownEntries = !detailMembershipSnapshot.memberIDs.isEmpty
                            let previousIDs = chapter.entries.map(\.id)
                            let nextIDs = entries.map(\.id)
                            if !entries.isEmpty || !hadKnownEntries {
                                guard previousIDs != nextIDs || chapter.entries.count != entries.count else {
                                    if !entries.isEmpty {
                                        hasVisibleJournalEntries = true
                                    }
                                    return
                                }
                                chapter.entries = entries
                                onChapterUpdated(chapter)
                            }
                            if !entries.isEmpty {
                                hasVisibleJournalEntries = true
                            }
                        },
                        hasVisibleJournalEntries: $hasVisibleJournalEntries
                    )
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.homePageBackground)
                } else {
                    mediaLazyContent
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Color.homePageBackground)
                }

                Color.clear
                    .frame(height: bottomPadding)
                    .frame(maxWidth: .infinity)
                    .background(Color.homePageBackground)
            }
        }
        .coordinateSpace(name: JournalDetailScrollCoordinate.spaceName)
        .onPreferenceChange(JournalDetailSheetScrollOffsetKey.self) { offsetY in
            journalDetailSheetScrollOffsetY = offsetY
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
        }
        .ignoresSafeArea(edges: .top)
    }

    private var journalDetailSheetScrollOffsetMarker: some View {
        Color.clear
            .frame(height: 0)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: JournalDetailSheetScrollOffsetKey.self,
                        value: max(0, -geo.frame(in: .named(JournalDetailScrollCoordinate.spaceName)).minY)
                    )
                }
            }
            .background(
                JournalDetailSheetScrollOffsetRestorer(
                    requestedOffsetY: $pendingJournalDetailSheetScrollOffsetY
                )
            )
    }

    private var journalDetailSheetTopChrome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(Color.homeMutedText.opacity(0.22))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)

            if isCoverSyncInProgress || pendingCoverSync != nil {
                JournalCoverSyncNotice(
                    isInProgress: isCoverSyncInProgress,
                    message: pendingCoverSync?.message,
                    onRetry: retryPendingCoverSync
                )
            }

            sectionPicker
        }
    }

    private var mediaLazyContent: some View {
        Group {
            if isLoadingMediaStoryboards && mediaStoryboards.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(0..<4, id: \.self) { index in
                        LoadingStoryboardCard()
                            .aspectRatio(1, contentMode: .fit)
                            .accessibilityLabel("Loading storyboard \(index + 1)")
                    }
                }
            } else if mediaStoryboards.isEmpty {
                VStack(spacing: 10) {
                    Text("No storyboards yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)

                    if let mediaStoryboardErrorMessage {
                        Text(mediaStoryboardErrorMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.homeMutedText.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                let items = mediaStoryboardItems
                LazyVStack(spacing: 8) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 2).enumerated()), id: \.offset) { _, start in
                        let end = min(start + 2, items.count)
                        let rowItems = Array(items[start..<end])
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(Array(rowItems.enumerated()), id: \.element.id) { rowOffset, item in
                                let index = start + rowOffset
                                let storyboard = item.storyboard
                                let pageLabel = mediaPageLabel(for: storyboard, fallbackIndex: index)

                                Button {
                                    selectedMediaIndex = index
                                } label: {
                                    VStack(spacing: 8) {
                                        mediaStoryboardThumbnail(item)

                                        Text(pageLabel)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.homeMutedText)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.82)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .modifier(MediaStoryboardDragModifier(
                                    storyboardID: storyboard.id,
                                    draggingStoryboardID: $draggingMediaStoryboardID
                                ))
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: MediaStoryboardDropDelegate(
                                        storyboard: storyboard,
                                        storyboards: mediaStoryboards,
                                        draggingStoryboardID: $draggingMediaStoryboardID,
                                        onReorder: moveMediaStoryboard
                                    )
                                )
                                .accessibilityLabel(mediaStoryboardAccessibilityLabel(item: item, pageLabel: pageLabel, index: index))
                            }

                            if rowItems.count == 1 {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func journalHeroSpacerTapTargets(height: CGFloat, proxy: GeometryProxy) -> some View {
        let metrics = journalHeroMetrics(toolbarBottomOffset: proxy.safeAreaInsets.top + 44)

        return ZStack(alignment: .top) {
            Color.clear
                .frame(height: height)

            VStack(alignment: .center, spacing: 14) {
                Color.clear
                    .frame(height: metrics.coverTopOffset)

                Button {
                    openJournalComicReader()
                } label: {
                    Color.clear
                        .frame(width: metrics.coverWidth, height: metrics.coverHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isOpeningJournalComicReader)
                .accessibilityLabel("Open journal comic")
                .accessibilityHint("Opens the storyboard images in the comic reader")

                Button {
                    openJournalComicReader()
                } label: {
                    Color.clear
                        .frame(width: 160, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isOpeningJournalComicReader)
                .accessibilityLabel("Tap to open journal comic")
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func journalDetailSheetTopOffset(height: CGFloat, safeAreaTop: CGFloat) -> CGFloat {
        let preferredOffset = height * 0.64
        let minimumOffset = safeAreaTop + 420
        let maximumOffset = height - 210
        return min(max(preferredOffset, minimumOffset), maximumOffset)
    }

    private func playBookOpenHint() {
        bookOpenHintTask?.cancel()
        bookOpenHintProgress = 0

        guard !reduceMotion else {
            return
        }

        bookOpenHintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeOut(duration: 0.42)) {
                bookOpenHintProgress = 1
            }

            try? await Task.sleep(nanoseconds: 560_000_000)
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.spring(response: 0.62, dampingFraction: 0.86)) {
                bookOpenHintProgress = 0
            }
        }
    }

    private var newEntryPresentation: CreateEntryPresentation {
        if activeDraftID != nil {
            return .editDraft
        }

        return .composeInJournal(
            title: chapter.title,
            initialDate: entryDate,
            locksEntryDate: presentation == .dailyJournal
        )
    }

    private func openJournalComicReader() {
        guard !isOpeningJournalComicReader else {
            return
        }

        isOpeningJournalComicReader = true
        bookOpenHintTask?.cancel()
        bookOpenHintProgress = 0
        bookNavigationOpenProgress = 0
        comicPageIndex = 0
        refreshMediaStoryboardsFromLocalStore()
        resortMediaStoryboardsToEntryOrder()

        Task {
            await loadMediaStoryboardsIfNeeded()
        }

        guard !reduceMotion else {
            bookOpenHintTask = nil
            skipsBookOpenHintOnNextAppear = true
            isComicReaderPresented = true
            return
        }

        bookOpenHintTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.14)) {
                bookOpenHintProgress = 1
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else {
                return
            }

            bookOpenHintTask = nil
            skipsBookOpenHintOnNextAppear = true
            isComicReaderPresented = true
        }
    }

    private func journalHeroHeader(toolbarBottomOffset: CGFloat) -> some View {
        heroBanner(toolbarBottomOffset: toolbarBottomOffset)
    }

    private func heroBanner(toolbarBottomOffset: CGFloat) -> some View {
        let metrics = journalHeroMetrics(toolbarBottomOffset: toolbarBottomOffset)

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                GeometryReader { bannerProxy in
                    VStack(spacing: 8) {
                        Text(chapter.title.uppercased())
                            .font(.system(size: 24, weight: .heavy, design: .serif))
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.76)
                            .multilineTextAlignment(.center)
                            .shadow(color: Color.black.opacity(0.42), radius: 10, y: 2)

                        HStack(spacing: 16) {
                            bannerStat(
                                systemName: "book.pages",
                                text: pageCountText,
                                foregroundColor: Color.white.opacity(0.92)
                            )
                            bannerStat(
                                systemName: "photo.on.rectangle",
                                text: mediaCountText,
                                foregroundColor: Color.white.opacity(0.92)
                            )
                        }
                        .shadow(color: Color.black.opacity(0.36), radius: 7, y: 2)
                    }
                    .padding(.horizontal, 24)
                    .frame(width: bannerProxy.size.width)
                    .position(x: bannerProxy.size.width / 2, y: metrics.bannerTitleCenterY)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: metrics.bannerHeight, alignment: .top)
            .clipped()

            VStack(alignment: .center, spacing: 14) {
                Button {
                    openJournalComicReader()
                } label: {
                    JournalDetailCoverImage(
                        chapter: chapter,
                        coverImage: cachedHeroCoverImage,
                        remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
                        fallbackImageName: chapter.coverImageName,
                        openHintProgress: bookOpenHintProgress,
                        navigationOpenProgress: bookNavigationOpenProgress
                    )
                    .frame(
                        width: metrics.coverWidth,
                        height: metrics.coverHeight
                    )
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isOpeningJournalComicReader)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Open journal comic")
                .accessibilityHint("Opens the storyboard images in the comic reader")

                Button {
                    openJournalComicReader()
                } label: {
                    HStack(spacing: 5) {
                        Text("Tap To Open")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.38), radius: 7, y: 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isOpeningJournalComicReader)
                .accessibilityLabel("Tap to open journal comic")
            }
            .padding(.horizontal, 16)
            .padding(.top, 0)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
            .offset(y: -metrics.coverOverlap)
            .padding(.bottom, -metrics.coverOverlap)
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func journalHeroMetrics(toolbarBottomOffset: CGFloat) -> JournalHeroMetrics {
        let bannerHeight: CGFloat = 246
        let coverTopOffset = min(bannerHeight - 58, toolbarBottomOffset + 32)
        let coverWidth = min(UIScreen.main.bounds.width * 0.49, 188)
        let coverHeight = coverWidth / JournalOpeningBook.compactAspectRatio
        let coverOverlap = max(0, bannerHeight - coverTopOffset)
        let coverStackHeight = coverHeight + 14 + 24 + 64

        return JournalHeroMetrics(
            bannerHeight: bannerHeight,
            coverTopOffset: coverTopOffset,
            bannerTitleCenterY: max(78, coverTopOffset - 44),
            coverOverlap: coverOverlap,
            coverWidth: coverWidth,
            coverHeight: coverHeight,
            backdropHeight: bannerHeight + coverStackHeight - coverOverlap
        )
    }

    private func openFreshEntryFromJournalDetail() {
        activeDraftID = nil
        isOpeningCompletedEntryFromEntries = false
        isOpeningExistingEntryFromJournal = false
        completedEntryOpenedStoryboardImage = nil
        generatedStoryboards = []

        if let onCreateEntryRequested {
            onCreateEntryRequested(newEntryPresentation)
        } else {
            isShowingNewStory = true
        }
    }

    private func bannerStat(systemName: String, text: String, foregroundColor: Color = Color.homeMutedText) -> some View {
        Label(text, systemImage: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
    }

    private var mediaComicStrip: some View {
        Group {
            if !mediaImageNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(mediaImageNames.enumerated()), id: \.offset) { index, imageName in
                            Button {
                                selectedMediaIndex = index
                            } label: {
                                comicStripPanel(imageName: imageName, index: index)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open photo \(index + 1) of \(mediaImageNames.count)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private func comicStripPanel(imageName: String, index: Int) -> some View {
        let size = comicStripPanelSize(for: imageName)

        return Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.storyInk)
                    .frame(width: 24, height: 20)
                    .background(Color.white.opacity(0.9))
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 6,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 5,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white, lineWidth: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.storyInk.opacity(0.16), lineWidth: 1)
            )
            .rotationEffect(.degrees(comicStripRotation(for: index)))
            .shadow(color: Color.storyInk.opacity(0.12), radius: 7, y: 4)
            .padding(.vertical, 4)
    }

    private func comicStripPanelSize(for imageName: String) -> CGSize {
        let height: CGFloat = 248

        guard let image = UIImage(named: imageName), image.size.height > 0 else {
            return CGSize(width: 184, height: height)
        }

        let width = height * (image.size.width / image.size.height)
        return CGSize(width: min(max(width, 152), 308), height: height)
    }

    private func comicStripRotation(for index: Int) -> Double {
        switch index % 5 {
        case 0:
            return -1.5
        case 1:
            return 1.2
        case 2:
            return -0.6
        case 3:
            return 1.6
        default:
            return 0.4
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(sections, id: \.self) { section in
                Button {
                    pendingJournalDetailSheetScrollOffsetY = journalDetailSheetScrollOffsetY
                    selectedSection = section
                } label: {
                    VStack(spacing: 8) {
                        Text(section)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selectedSection == section ? Color.homeAccent : Color.homeMutedText.opacity(0.78))

                        Capsule()
                            .fill(selectedSection == section ? Color.homeAccent : Color.clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func editableEntryRow(_ entry: PrototypeEntry, at index: Int) -> some View {
        HStack(spacing: editMode == .active ? 10 : 0) {
            if editMode == .active {
                Button {
                    deleteEntry(entry)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .frame(width: 30, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(entry.title)")
            }

            NavigationLink {
                PrototypeEntryDetailView(
                    entry: entry,
                    chapter: chapter,
                    title: presentation == .dailyJournal ? "Journal Entry" : "Story"
                )
            } label: {
                PrototypeEntryRow(
                    entry: detailDisplayEntry(for: entry, entryIndex: index),
                    accentColor: Color.homeAccent,
                    thumbnailSize: detailEntryThumbnailSize
                )
            }
            .buttonStyle(.plain)
            .disabled(editMode == .active)

            if editMode == .active {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.homeMutedText.opacity(0.72))
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggingEntryID = entry.id
                        return NSItemProvider(object: entry.id.uuidString as NSString)
                    }
                    .accessibilityLabel("Reorder \(entry.title)")
            }
        }
        .padding(.leading, editMode == .active ? 8 : 0)
        .padding(.trailing, editMode == .active ? 8 : 0)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .onDrop(
            of: [UTType.text],
            delegate: PrototypeEntryReorderDropDelegate(
                targetEntry: entry,
                entries: $chapter.entries,
                draggingEntryID: $draggingEntryID,
                onReorder: persistEntryOrder
            )
        )
    }

    private var detailEntryThumbnailSize: CGFloat {
        presentation == .dailyJournal ? 50 : 58
    }

    private func detailDisplayEntry(for entry: PrototypeEntry, entryIndex: Int) -> PrototypeEntry {
        guard presentation == .dailyJournal, !entry.imageNames.isEmpty else {
            return entry
        }

        return entry.copy(
            imageNames: regularPhotoNames(
                startIndex: entryIndex * 2,
                count: entry.imageNames.count
            )
        )
    }

    private func regularPhotoNames(startIndex: Int, count: Int) -> [String] {
        (0..<count).map { offset in
            regularSetImageNames[(startIndex + offset) % regularSetImageNames.count]
        }
    }

    private func deleteEntry(_ entry: PrototypeEntry) {
        guard signInGate.requireAccount(for: .deleteEntry) else {
            return
        }

        chapter.entries.removeAll { $0.id == entry.id }
        StoryEntryStore.delete(entry, from: chapter.title)
        DeletedSampleEntryStore.add(entry, in: chapter.title)
        persistEntryOrder()
    }

    private func persistEntryOrder() {
        StoryEntryStore.saveStoredOrder(from: chapter.entries, for: chapter.title)
    }

    private func refreshDetailMembershipSnapshot() {
        let snapshot = JournalDetailMembershipSnapshot.make(for: chapter)
        detailMembershipSnapshot = snapshot
        updateDisplayedMediaStoryboardCount(snapshot: snapshot)
    }

    private func refreshCachedHeroCoverImage(storedCoverImage: UIImage? = nil, force: Bool = false) {
        let storageKey = chapter.coverStorageKey
        if chapter.remoteCover != nil {
            cachedHeroCoverImage = nil
            cachedHeroCoverStorageKey = nil
            return
        }

        if let storedCoverImage {
            cachedHeroCoverStorageKey = storageKey
            cachedHeroCoverImage = storedCoverImage
            return
        }

        if !force, cachedHeroCoverStorageKey == storageKey, cachedHeroCoverImage != nil {
            return
        }

        cachedHeroCoverStorageKey = storageKey
        cachedHeroCoverImage = JournalCoverStore.image(for: chapter)
    }

    private func updateDisplayedMediaStoryboardCount(snapshot: JournalDetailMembershipSnapshot? = nil) {
        if !mediaStoryboards.isEmpty {
            displayedMediaStoryboardCount = mediaStoryboardItems.count
            return
        }

        displayedMediaStoryboardCount = GeneratedStoryboardStore.count(
            clientEntryIDs: (snapshot ?? detailMembershipSnapshot).mediaClientEntryIDs
        )
    }

    private var pageCountText: String {
        let pageCount = max(displayedMediaStoryboardCount, chapter.entries.count)
        return "\(pageCount) \(pageCount == 1 ? "page" : "pages")"
    }

    private var mediaCountText: String {
        let count = displayedMediaStoryboardCount
        return "\(count) \(count == 1 ? "storyboard" : "storyboards")"
    }

    private var comicReaderStoryboardCountText: String {
        let count = comicReaderStoryboards.count
        return "\(count) \(count == 1 ? "storyboard" : "storyboards")"
    }

    private var comicReaderStoryboards: [GeneratedStoryboard] {
        primaryStoryboardsByEntry(
            from: GeneratedStoryboardStore.load(clientEntryIDs: mediaClientEntryIDs)
        )
    }

    private var mediaStoryboardItems: [JournalMediaStoryboardItem] {
        primaryStoryboardItemsByEntry(from: mediaStoryboards)
    }

    private func mediaStoryboardThumbnail(_ item: JournalMediaStoryboardItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: item.storyboard.image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                )

            if item.storyboardCount > 1 {
                Text("\(item.storyboardCount)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.storyPurple, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
                    .shadow(color: Color.storyInk.opacity(0.18), radius: 5, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 7, y: 7)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func mediaStoryboardAccessibilityLabel(
        item: JournalMediaStoryboardItem,
        pageLabel: String,
        index: Int
    ) -> String {
        if item.storyboardCount > 1 {
            return "Open \(pageLabel), storyboard stack \(index + 1) of \(mediaStoryboardItems.count), \(item.storyboardCount) images"
        }

        return "Open \(pageLabel), storyboard \(index + 1) of \(mediaStoryboardItems.count)"
    }

    /// The viewer scrolls every tile in the Media grid — the primary storyboard
    /// for each entry — so entries with multiple storyboards contribute one image.
    private func mediaViewerStoryboards(for storyboard: GeneratedStoryboard) -> [GeneratedStoryboard] {
        let gridStoryboards = mediaStoryboardItems.map(\.storyboard)
        let viewerStoryboards = gridStoryboards.contains(where: { $0.id == storyboard.id })
            ? gridStoryboards
            : [storyboard]

        // Grid tiles hold downsampled images; swap in the full-size ones for viewing.
        let clientEntryIDs = Set(viewerStoryboards.compactMap(\.clientEntryID))
        guard !clientEntryIDs.isEmpty else {
            return viewerStoryboards
        }

        let storedByID = Dictionary(
            GeneratedStoryboardStore.load(clientEntryIDs: clientEntryIDs).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return viewerStoryboards.map { storedByID[$0.id] ?? $0 }
    }

    private func cardSizedMediaStoryboards(_ storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        storyboards.map { storyboard in
            GeneratedStoryboard(
                id: storyboard.id,
                clientEntryID: storyboard.clientEntryID,
                image: storyboard.image.journaltopiaDownsampled(maxDimension: 640),
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
    }

    private func refreshMediaStoryboardsFromLocalStore() {
        let clientEntryIDs = mediaClientEntryIDs
        guard !clientEntryIDs.isEmpty else {
            mediaStoryboards = []
            displayedMediaStoryboardCount = 0
            return
        }

        let localStoryboards = storyboardsForMedia(
            clientEntryIDs: clientEntryIDs,
            in: GeneratedStoryboardStore.load(clientEntryIDs: clientEntryIDs)
        )

        mediaStoryboards = mergedMediaStoryboards(cardSizedMediaStoryboards(localStoryboards + mediaStoryboards))
        updateDisplayedMediaStoryboardCount()
    }

    @MainActor
    private func loadMediaStoryboardsIfNeeded(force: Bool = false) async {
        let clientEntryIDs = mediaClientEntryIDs
        guard force || !hasLoadedMediaStoryboards || clientEntryIDs != lastMediaLoadEntryIDs else {
            return
        }

        await loadMediaStoryboards(clientEntryIDs: clientEntryIDs)
    }

    @MainActor
    private func loadMediaStoryboards(force: Bool = false) async {
        await loadMediaStoryboardsIfNeeded(force: force)
    }

    @MainActor
    private func loadMediaStoryboards(clientEntryIDs: Set<UUID>) async {
        // Signed-out browsing has no on-disk storyboards of its own, and the ones that would be
        // there belong to the `anonymous` scope rather than to the pack.
        let sourceStoryboards = contentMode.showsSampleContent && !contentMode.isSampleAuthoring
            ? SampleContentStore.storyboards(clientEntryIDs: clientEntryIDs)
            : GeneratedStoryboardStore.load(clientEntryIDs: clientEntryIDs)
        let localStoryboards = storyboardsForMedia(
            clientEntryIDs: clientEntryIDs,
            in: sourceStoryboards
        )
        mediaStoryboards = cardSizedMediaStoryboards(localStoryboards)
        updateDisplayedMediaStoryboardCount()
        mediaStoryboardErrorMessage = nil
        lastMediaLoadEntryIDs = clientEntryIDs
        hasLoadedMediaStoryboards = true

        guard authStore.userID != nil else {
            isLoadingMediaStoryboards = false
            return
        }

        isLoadingMediaStoryboards = true
        defer { isLoadingMediaStoryboards = false }

        do {
            let cloudClientEntryIDs = try await mediaClientEntryIDsFromCloudEntries()
            let allClientEntryIDs = clientEntryIDs.union(cloudClientEntryIDs)
            // Media tab needs every storyboard for an entry (viewer + counts); query is membership-scoped.
            let cloudStoryboards = try await SupabaseStoryboardService().loadStoryboardImages(for: allClientEntryIDs)
            let cachedCloudStoryboards = GeneratedStoryboardStore.cachedStoryboards(cloudStoryboards)
            var persistedStoryboards = GeneratedStoryboardStore.load()
            for storyboard in cachedCloudStoryboards {
                persistedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: persistedStoryboards)
            }
            GeneratedStoryboardStore.save(persistedStoryboards)

            let refreshedLocalStoryboards = storyboardsForMedia(
                clientEntryIDs: allClientEntryIDs,
                in: persistedStoryboards
            )
            mediaStoryboards = mergedMediaStoryboards(cardSizedMediaStoryboards(refreshedLocalStoryboards))
            updateDisplayedMediaStoryboardCount()
            lastMediaLoadEntryIDs = allClientEntryIDs
        } catch {
            mediaStoryboardErrorMessage = "Could not load cloud storyboards."
        }
    }

    private func mediaClientEntryIDsFromCloudEntries() async throws -> Set<UUID> {
        let memberships = try await SupabaseJournalRepository().getJournalEntryMemberships()
        return Set(
            memberships
                .filter { $0.journalID == chapter.id }
                .map { $0.clientEntryID }
        )
    }

    private static func hasLocalEntries(for chapter: PrototypeChapter) -> Bool {
        !chapter.entries.isEmpty
            || !StoryEntryStore.clientEntryIDs(for: chapter.title).isEmpty
            || !EntryJournalLinkStore.draftIDs(linkedTo: chapter.title).isEmpty
    }

    private func storyboardsForMedia(
        clientEntryIDs: Set<UUID>,
        in storyboards: [GeneratedStoryboard]
    ) -> [GeneratedStoryboard] {
        mergedMediaStoryboards(
            storyboards.filter { storyboard in
                guard let clientEntryID = storyboard.clientEntryID else {
                    return false
                }

                return clientEntryIDs.contains(clientEntryID)
            }
        )
    }

    private func primaryStoryboardsByEntry(from storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        primaryStoryboardItemsByEntry(from: storyboards).map(\.storyboard)
    }

    private func primaryStoryboardItemsByEntry(from storyboards: [GeneratedStoryboard]) -> [JournalMediaStoryboardItem] {
        var countsByEntryID: [UUID: Int] = [:]
        var selectedByEntryID: [UUID: GeneratedStoryboard] = [:]
        var entryOrder: [UUID] = []
        var storyboardsWithoutEntryID: [JournalMediaStoryboardItem] = []

        for storyboard in storyboards {
            guard let clientEntryID = storyboard.clientEntryID else {
                storyboardsWithoutEntryID.append(JournalMediaStoryboardItem(storyboard: storyboard, storyboardCount: 1))
                continue
            }

            countsByEntryID[clientEntryID, default: 0] += 1
            if selectedByEntryID[clientEntryID] == nil {
                entryOrder.append(clientEntryID)
                selectedByEntryID[clientEntryID] = storyboard
            } else if storyboard.isPrimary {
                selectedByEntryID[clientEntryID] = storyboard
            }
        }

        let selectedStoryboards = entryOrder.compactMap { entryID -> JournalMediaStoryboardItem? in
            guard let storyboard = selectedByEntryID[entryID] else {
                return nil
            }

            return JournalMediaStoryboardItem(
                storyboard: storyboard,
                storyboardCount: countsByEntryID[entryID, default: 1]
            )
        }
        return selectedStoryboards + storyboardsWithoutEntryID
    }

    /// Matches Pages-tab order (Page 1 / Page 2 / …) via journal membership order.
    private func mediaEntryOrderPositions() -> [UUID: Int] {
        var positions = detailMembershipSnapshot.memberPositions
        for (offset, entry) in chapter.entries.enumerated() where positions[entry.id] == nil {
            positions[entry.id] = offset
        }
        for storyboard in mediaStoryboards {
            guard let clientEntryID = storyboard.clientEntryID, positions[clientEntryID] == nil else {
                continue
            }

            positions[clientEntryID] = positions.count
        }
        return positions
    }

    private func mediaPageLabel(for storyboard: GeneratedStoryboard, fallbackIndex: Int) -> String {
        let positions = mediaEntryOrderPositions()
        if let entryID = storyboard.clientEntryID, let position = positions[entryID] {
            return "Page \(position + 1)"
        }

        return "Page \(fallbackIndex + 1)"
    }

    private func moveMediaStoryboard(draggingStoryboardID: UUID, targetStoryboardID: UUID) {
        guard draggingStoryboardID != targetStoryboardID else {
            return
        }

        var reorderedStoryboards = mediaStoryboards
        guard
            let fromIndex = reorderedStoryboards.firstIndex(where: { $0.id == draggingStoryboardID }),
            let toIndex = reorderedStoryboards.firstIndex(where: { $0.id == targetStoryboardID }),
            let sourceEntryID = reorderedStoryboards[fromIndex].clientEntryID,
            let targetEntryID = reorderedStoryboards[toIndex].clientEntryID
        else {
            return
        }

        let movedStoryboard = reorderedStoryboards.remove(at: fromIndex)
        reorderedStoryboards.insert(movedStoryboard, at: toIndex)

        withAnimation(.easeInOut(duration: 0.18)) {
            mediaStoryboards = reorderedStoryboards
        }

        guard sourceEntryID != targetEntryID else {
            return
        }

        let orderedEntryIDs = reorderedMediaEntryIDs(
            moving: sourceEntryID,
            to: targetEntryID,
            placesAfterTarget: fromIndex < toIndex
        )
        applyMediaEntryOrder(orderedEntryIDs)
    }

    private func reorderedMediaEntryIDs(
        moving sourceEntryID: UUID,
        to targetEntryID: UUID,
        placesAfterTarget: Bool
    ) -> [UUID] {
        var seenEntryIDs = Set<UUID>()
        var orderedEntryIDs = detailMembershipSnapshot.memberIDsInOrder.filter {
            seenEntryIDs.insert($0).inserted
        }

        for entry in chapter.entries where seenEntryIDs.insert(entry.id).inserted {
            orderedEntryIDs.append(entry.id)
        }

        for storyboard in mediaStoryboards {
            guard let clientEntryID = storyboard.clientEntryID, seenEntryIDs.insert(clientEntryID).inserted else {
                continue
            }

            orderedEntryIDs.append(clientEntryID)
        }

        guard
            let fromIndex = orderedEntryIDs.firstIndex(of: sourceEntryID),
            let toIndex = orderedEntryIDs.firstIndex(of: targetEntryID)
        else {
            return orderedEntryIDs
        }

        let movedEntryID = orderedEntryIDs.remove(at: fromIndex)
        let targetIndexAfterRemoval = orderedEntryIDs.firstIndex(of: targetEntryID) ?? toIndex
        let insertionIndex = placesAfterTarget ? targetIndexAfterRemoval + 1 : targetIndexAfterRemoval
        orderedEntryIDs.insert(movedEntryID, at: min(insertionIndex, orderedEntryIDs.count))
        return orderedEntryIDs
    }

    private func applyMediaEntryOrder(_ orderedEntryIDs: [UUID]) {
        guard !orderedEntryIDs.isEmpty else {
            return
        }

        StoryEntryStore.saveStoredOrder(
            clientEntryIDs: orderedEntryIDs,
            for: chapter.title,
            syncsToCloud: false
        )

        let positions = Dictionary(uniqueKeysWithValues: orderedEntryIDs.enumerated().map { ($0.element, $0.offset) })
        let previousEntryIDs = chapter.entries.map(\.id)
        chapter.entries.sort {
            let lhsPosition = positions[$0.id] ?? Int.max
            let rhsPosition = positions[$1.id] ?? Int.max
            if lhsPosition != rhsPosition {
                return lhsPosition < rhsPosition
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        if chapter.entries.map(\.id) != previousEntryIDs {
            onChapterUpdated(chapter)
        }
        refreshDetailMembershipSnapshot()

        Task {
            guard authStore.userID != nil else {
                return
            }

            do {
                try await SupabaseJournalRepository().replaceJournalEntries(
                    journalID: chapter.id,
                    clientEntryIDs: orderedEntryIDs
                )
            } catch {
                await MainActor.run {
                    mediaStoryboardErrorMessage = "Could not save media order to Journaltopia cloud."
                }
            }
        }
    }

    private func resortMediaStoryboardsToEntryOrder() {
        guard !mediaStoryboards.isEmpty else {
            return
        }

        mediaStoryboards = mergedMediaStoryboards(mediaStoryboards)
        updateDisplayedMediaStoryboardCount()
    }

    private func mergedMediaStoryboards(_ storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        let positions = mediaEntryOrderPositions()
        var seen = Set<UUID>()
        return storyboards
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let lhsPosition = lhs.clientEntryID.flatMap { positions[$0] }
                let rhsPosition = rhs.clientEntryID.flatMap { positions[$0] }

                switch (lhsPosition, rhsPosition) {
                case let (lhsPosition?, rhsPosition?) where lhsPosition != rhsPosition:
                    return lhsPosition < rhsPosition
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    // Same page (or both unordered): older storyboard first within a page.
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
    }
}

private struct JournalHeroMetrics {
    let bannerHeight: CGFloat
    let coverTopOffset: CGFloat
    let bannerTitleCenterY: CGFloat
    let coverOverlap: CGFloat
    let coverWidth: CGFloat
    let coverHeight: CGFloat
    let backdropHeight: CGFloat
}

private struct JournalDetailMembershipSnapshot {
    static let empty = JournalDetailMembershipSnapshot(
        memberIDsInOrder: [],
        memberIDs: [],
        memberPositions: [:],
        linkedJournalTitlesByEntryID: [:],
        mediaClientEntryIDs: []
    )

    let memberIDsInOrder: [UUID]
    let memberIDs: Set<UUID>
    let memberPositions: [UUID: Int]
    let linkedJournalTitlesByEntryID: [UUID: Set<String>]
    let mediaClientEntryIDs: Set<UUID>

    static func make(for chapter: PrototypeChapter) -> JournalDetailMembershipSnapshot {
        let memberIDsInOrder = StoryEntryStore.clientEntryIDs(for: chapter.title)
        let linkedDraftIDs = EntryJournalLinkStore.draftIDs(linkedTo: chapter.title)
        let knownChapterEntryIDs = Set(chapter.entries.map(\.id))
        let allMemberIDs = Set(memberIDsInOrder).union(linkedDraftIDs).union(knownChapterEntryIDs)

        var positions: [UUID: Int] = [:]
        for (offset, id) in memberIDsInOrder.enumerated() where positions[id] == nil {
            positions[id] = offset
        }

        return JournalDetailMembershipSnapshot(
            memberIDsInOrder: memberIDsInOrder,
            memberIDs: allMemberIDs,
            memberPositions: positions,
            linkedJournalTitlesByEntryID: EntryJournalLinkStore.loadJournalTitles(for: Array(allMemberIDs)),
            mediaClientEntryIDs: allMemberIDs
        )
    }
}

private enum JournalDetailScrollCoordinate {
    static let spaceName = "journalDetailScroll"
}

private struct JournalDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct JournalDetailSheetScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct JournalDetailSheetScrollOffsetRestorer: UIViewRepresentable {
    @Binding var requestedOffsetY: CGFloat?

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let requestedOffsetY else {
            return
        }

        context.coordinator.restore(
            requestedOffsetY,
            from: view,
            requestedOffsetY: $requestedOffsetY
        )
    }

    final class Coordinator {
        private var restoreID = UUID()

        func restore(_ offsetY: CGFloat, from view: UIView, requestedOffsetY: Binding<CGFloat?>) {
            let restoreID = UUID()
            self.restoreID = restoreID
            applyRestore(
                restoreID: restoreID,
                offsetY: offsetY,
                from: view,
                requestedOffsetY: requestedOffsetY,
                attempt: 0
            )
        }

        private func applyRestore(
            restoreID: UUID,
            offsetY: CGFloat,
            from view: UIView,
            requestedOffsetY: Binding<CGFloat?>,
            attempt: Int
        ) {
            guard restoreID == self.restoreID else {
                return
            }

            guard let scrollView = view.journalDetailEnclosingScrollView else {
                scheduleNextRestore(
                    restoreID: restoreID,
                    offsetY: offsetY,
                    from: view,
                    requestedOffsetY: requestedOffsetY,
                    attempt: attempt
                )
                return
            }

            let minimumOffsetY = -scrollView.adjustedContentInset.top
            let maximumOffsetY = max(
                minimumOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let restoredOffsetY = min(max(offsetY, minimumOffsetY), maximumOffsetY)

            if abs(scrollView.contentOffset.y - restoredOffsetY) > 0.5 {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: restoredOffsetY),
                    animated: false
                )
            }

            scheduleNextRestore(
                restoreID: restoreID,
                offsetY: offsetY,
                from: view,
                requestedOffsetY: requestedOffsetY,
                attempt: attempt
            )
        }

        private func scheduleNextRestore(
            restoreID: UUID,
            offsetY: CGFloat,
            from view: UIView,
            requestedOffsetY: Binding<CGFloat?>,
            attempt: Int
        ) {
            guard attempt < 8 else {
                if restoreID == self.restoreID {
                    requestedOffsetY.wrappedValue = nil
                }
                return
            }

            let delay = min(0.02 * Double(attempt + 1), 0.08)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                guard let self, let view else {
                    return
                }

                self.applyRestore(
                    restoreID: restoreID,
                    offsetY: offsetY,
                    from: view,
                    requestedOffsetY: requestedOffsetY,
                    attempt: attempt + 1
                )
            }
        }
    }
}

private extension UIView {
    var journalDetailEnclosingScrollView: UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            candidate = view.superview
        }

        return nil
    }
}

private enum JournalDetailSelectionBarAction {
    case addToJournal
    case duplicateSelected
    case deleteSelected
}

private struct JournalDetailEntryBrowser: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var signInGate: SignInGate

    let chapter: PrototypeChapter
    @Binding var editMode: EditMode
    @Binding var selectedEntryIDs: Set<UUID>
    @Binding var selectionBarAction: JournalDetailSelectionBarAction?
    let contentMode: JournaltopiaContentMode
    let allowsCreation: Bool

    private var isSampleAuthorMode: Bool {
        contentMode.isSampleAuthoring
    }

    /// Signed-out browsing reads the pack from memory. Sample authoring and signed-in users keep
    /// reading the on-disk stores, which is where their entries actually live.
    private var readsSampleContentFromMemory: Bool {
        contentMode.showsSampleContent && !contentMode.isSampleAuthoring
    }
    let scrollViewportHeight: CGFloat
    let onCreateEntry: () -> Void
    let onOpenEntry: (CreateEntryDraft, Bool, UIImage?) -> Void
    let onEntriesChanged: ([PrototypeEntry]) -> Void
    @Binding var hasVisibleJournalEntries: Bool

    @State private var localEntries: [CreateEntryDraft] = []
    @State private var cloudEntries: [JournalEntry] = []
    @State private var completedStoryboards: [GeneratedStoryboard] = []
    @State private var storyboardCountsByClientEntryID: [UUID: Int] = [:]
    @State private var cloudStoryboardClientIDs: Set<UUID> = []
    @State private var failedCloudStoryboardClientIDs: Set<UUID> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var entriesPendingDeletion: [EntryDisplayItem] = []
    @State private var duplicateErrorMessage: String?
    @State private var isDuplicatingSelectedEntries = false
    @State private var isShowingAddSelectedEntriesToJournalSheet = false
    @State private var selectedEntriesJournalTitle: String?
    @State private var selectedEntriesJournalTitles: Set<String> = []
    @State private var draggingEntryID: UUID?
    @State private var manualEntryOrderOverrides: [UUID: Int] = [:]
    @State private var membershipSnapshot = JournalDetailMembershipSnapshot.empty
    @State private var visibleItems: [EntryDisplayItem] = []
    @State private var visibleItemSignature: [UUID] = []
    @State private var lastNotifiedEntrySignature: [UUID] = []
    @State private var suppressedChapterEntryRefreshSignature: [UUID]?
    @State private var renderedThumbnails: [UUID: JournalDetailRenderedThumbnail] = [:]
    @State private var thumbnailRenderTask: Task<Void, Never>?
    @State private var entryContentMinY: CGFloat = 0
    @State private var openingEntryID: UUID?
    @AppStorage("JournaltopiaSelectedJournalDetailEntryLayout") private var selectedLayoutRawValue = JournalEntryLayout.grid.rawValue

    private var selectedLayout: JournalEntryLayout {
        get { JournalEntryLayout(rawValue: selectedLayoutRawValue) ?? .grid }
        nonmutating set { selectedLayoutRawValue = newValue.rawValue }
    }

    private var entryGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14),
            count: selectedLayout.gridColumnCount
        )
    }

    private func makeDisplayItems(
        localEntries: [CreateEntryDraft],
        cloudEntries: [JournalEntry],
        membershipSnapshot: JournalDetailMembershipSnapshot
    ) -> [EntryDisplayItem] {
        let cloudByClientID = Dictionary(grouping: cloudEntries, by: \.clientEntryID).compactMapValues(\.first)
        let localItems = localEntries
            .map { EntryDisplayItem.local($0, cloudEntry: cloudByClientID[$0.id]) }
            .filter { matchesChapterFilter($0, membershipSnapshot: membershipSnapshot) }
        let localIDs = Set(localEntries.map(\.id))
        let cloudOnlyItems = cloudEntries
            .filter { !localIDs.contains($0.clientEntryID) }
            .map(EntryDisplayItem.cloud)
            .filter { matchesChapterFilter($0, membershipSnapshot: membershipSnapshot) }

        return (localItems + cloudOnlyItems)
            .filter { $0.status != JournalEntryStatus.archived.rawValue }
            .sorted { lhs, rhs in
                sortEntryItems(lhs, rhs, membershipSnapshot: membershipSnapshot)
            }
    }

    private var isEntryReorderingEnabled: Bool {
        true
    }

    var body: some View {
        let items = visibleItems

        VStack(alignment: .leading, spacing: 14) {
            controlsRow

            if let errorMessage {
                cloudErrorNotice(errorMessage)
            }

            if isLoading && items.isEmpty {
                loadingGrid
            } else if items.isEmpty {
                emptyState
            } else if selectedLayout == .list {
                entryList(items)
            } else {
                entryGrid(items)
            }
        }
        .onAppear(perform: refreshEntries)
        .onAppear(perform: notifyVisibleEntriesAvailability)
        .onChange(of: authStore.userID) { _ in
            refreshEntries()
        }
        .onChange(of: visibleItemSignature) { _ in
            notifyVisibleEntriesAvailability()
        }
        .onChange(of: chapter.entries.map(\.id)) { _ in
            let chapterSignature = chapter.entries.map(\.id)
            if suppressedChapterEntryRefreshSignature == chapterSignature {
                suppressedChapterEntryRefreshSignature = nil
                return
            }

            refreshEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .journaltopiaGeneratedStoryboardsChanged)) { _ in
            refreshEntries()
        }
        .onDisappear {
            thumbnailRenderTask?.cancel()
            thumbnailRenderTask = nil
        }
        .onChange(of: editMode) { mode in
            if mode != .active {
                selectedEntryIDs = []
            }
        }
        .onChange(of: selectionBarAction) { action in
            guard let action else {
                return
            }

            selectionBarAction = nil
            switch action {
            case .addToJournal:
                openAddSelectedEntriesToJournalPage()
            case .duplicateSelected:
                duplicateSelectedEntries()
            case .deleteSelected:
                requestDeleteSelectedEntries()
            }
        }
        .sheet(isPresented: $isShowingAddSelectedEntriesToJournalSheet) {
            NavigationStack {
                AddEntryToJournalPage(
                    selectedJournalTitle: $selectedEntriesJournalTitle,
                    selectedJournalTitles: $selectedEntriesJournalTitles,
                    contentMode: contentMode,
                    onSelect: { journalTitle in
                        addSelectedEntriesToJournals(Set([journalTitle]))
                    },
                    onSaveSelection: addSelectedEntriesToJournals
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert(deleteEntryAlertTitle, isPresented: isDeleteEntryAlertPresented) {
            Button("Cancel", role: .cancel) {
                entriesPendingDeletion = []
            }

            Button("Remove from this Journal", role: .destructive) {
                let itemsToDelete = entriesPendingDeletion
                Task {
                    await deletePendingEntriesFromCurrentJournal(itemsToDelete)
                }
            }

            if hasEntriesPendingDeletionOutsideCurrentJournal {
                Button("Delete in All", role: .destructive) {
                    let itemsToDelete = entriesPendingDeletion
                    Task {
                        await deletePendingEntriesEverywhere(itemsToDelete)
                    }
                }
            }
        } message: {
            Text(deleteEntryAlertMessage)
        }
        .alert("Could Not Duplicate", isPresented: isDuplicateEntryAlertPresented) {
            Button("OK") {
                duplicateErrorMessage = nil
            }
        } message: {
            Text(duplicateErrorMessage ?? "Could not duplicate one or more entries.")
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            if !visibleItems.isEmpty {
                ReorderHintText()
            }

            Spacer()

            editSelectionButton
            layoutSwitcher
        }
    }

    @ViewBuilder
    private var editSelectionButton: some View {
        if allowsCreation {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if editMode == .active {
                        editMode = .inactive
                        selectedEntryIDs = []
                    } else {
                        editMode = .active
                    }
                }
            } label: {
                Text(editMode == .active ? "Done" : "Edit")
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.homeAccent)
            .buttonStyle(.plain)
            .accessibilityLabel(editMode == .active ? "Done editing entries" : "Edit entries")
        }
    }

    private var layoutSwitcher: some View {
        HStack(spacing: 4) {
            layoutButton(.grid)
            layoutButton(.grid3x3)
            layoutButton(.list)
        }
        .padding(4)
        .frame(height: 34)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private func layoutButton(_ layout: JournalEntryLayout) -> some View {
        let isSelected = selectedLayout == layout
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedLayout = layout
            }
        } label: {
            Image(systemName: layout.systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.homeMutedText)
                .frame(width: 34, height: 26)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.storyInk)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func entryGrid(_ items: [EntryDisplayItem]) -> some View {
        let columns = max(1, selectedLayout.gridColumnCount)
        let spacing: CGFloat = 14
        let availableWidth = entryGridAvailableWidth
        let rowHeight = entryGridRowHeight(availableWidth: availableWidth, columns: columns)
        let rowCount = Int(ceil(Double(items.count) / Double(columns)))
        let totalHeight = entryGridContentHeight(itemCount: items.count, availableWidth: availableWidth)
        let window = visibleRowWindow(
            rowCount: rowCount,
            rowStride: rowHeight + spacing
        )

        return VStack(spacing: 0) {
            if window.lowerBound > 0 {
                Color.clear
                    .frame(height: CGFloat(window.lowerBound) * (rowHeight + spacing))
            }

            ForEach(Array(window), id: \.self) { rowIndex in
                let start = rowIndex * columns
                let end = min(start + columns, items.count)
                let rowItems = Array(items[start..<end])

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(rowItems.enumerated()), id: \.element.id) { rowOffset, item in
                        let index = start + rowOffset
                        entryGridCell(item: item, index: index, items: items)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }

                    if rowItems.count < columns {
                        ForEach(0..<(columns - rowItems.count), id: \.self) { _ in
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: rowHeight, alignment: .top)
                .padding(.bottom, rowIndex < rowCount - 1 ? spacing : 0)
            }

            Color.clear
                .frame(height: max(0, totalHeight - CGFloat(window.lowerBound) * (rowHeight + spacing) - CGFloat(window.count) * rowHeight - CGFloat(max(0, window.count - 1)) * spacing))
        }
        .frame(height: totalHeight, alignment: .top)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: JournalDetailScrollOffsetKey.self,
                    value: geo.frame(in: .named(JournalDetailScrollCoordinate.spaceName)).minY
                )
            }
        }
        .onPreferenceChange(JournalDetailScrollOffsetKey.self) { entryContentMinY = $0 }
    }

    @ViewBuilder
    private func entryGridCell(item: EntryDisplayItem, index: Int, items: [EntryDisplayItem]) -> some View {
        let displayEntry = entryForDisplay(item)
        if isCompleted(item) {
            CompletedEntryGridCard(
                entry: displayEntry,
                title: entryDisplayTitle(displayEntry),
                sortOption: .manual,
                pageLabel: pageLabel(for: index),
                storyboardImage: storyboardImage(for: item, fallbackIndex: index),
                storyboardCount: storyboardCount(for: item),
                category: nil,
                isSelecting: editMode == .active,
                isSelected: selectedEntryIDs.contains(item.id),
                selectionBadgeStyle: .prominentGrid,
                onOpen: {
                    handleItemTap(item, displayEntry: displayEntry, fallbackIndex: index)
                },
                onDelete: {
                    requestDeleteEntry(item)
                },
                deleteActionTitle: journalDetailDeleteActionTitle,
                onSelect: {
                    toggleEntrySelection(item.id)
                }
            )
            .modifier(JournalDetailEntryDragModifier(
                entryID: item.id,
                isEnabled: isEntryReorderingEnabled,
                draggingEntryID: $draggingEntryID
            ))
            .onDrop(
                of: [UTType.text],
                delegate: EntryDropDelegate(
                    item: item,
                    items: items,
                    draggingEntryID: $draggingEntryID,
                    isEnabled: isEntryReorderingEnabled,
                    onReorder: moveEntryItem
                )
            )
        } else {
            EntryGridPreviewCard(
                entry: displayEntry,
                sortOption: .manual,
                pageLabel: pageLabel(for: index),
                isEditing: false,
                // Matches the Entries page: the long-press action is available without
                // first entering selection mode.
                showsActions: true,
                title: entryDisplayTitle(displayEntry),
                category: nil,
                isOpening: false,
                isSelecting: editMode == .active,
                isSelected: selectedEntryIDs.contains(item.id),
                selectionBadgeStyle: .prominentGrid,
                onOpen: {
                    handleItemTap(item, displayEntry: displayEntry, fallbackIndex: index)
                },
                onDelete: {
                    requestDeleteEntry(item)
                },
                deleteActionTitle: journalDetailDeleteActionTitle,
                onRename: nil,
                onSelect: {
                    toggleEntrySelection(item.id)
                }
            )
            .modifier(JournalDetailEntryDragModifier(
                entryID: item.id,
                isEnabled: isEntryReorderingEnabled,
                draggingEntryID: $draggingEntryID
            ))
            .onDrop(
                of: [UTType.text],
                delegate: EntryDropDelegate(
                    item: item,
                    items: items,
                    draggingEntryID: $draggingEntryID,
                    isEnabled: isEntryReorderingEnabled,
                    onReorder: moveEntryItem
                )
            )
        }
    }

    /// On a journal page the destructive action is ambiguous — the confirmation alert is what
    /// offers "Remove from this Journal" versus "Delete in All", so the row action stays neutral.
    private var journalDetailDeleteActionTitle: String {
        "Remove from Journal"
    }

    private var entryGridAvailableWidth: CGFloat {
        max(1, UIScreen.main.bounds.width - 32)
    }

    private func entryGridRowHeight(availableWidth: CGFloat, columns: Int) -> CGFloat {
        let spacing: CGFloat = 14
        let cellWidth = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let imageHeight = cellWidth * (340.0 / 260.0)
        return imageHeight + 8 + 34
    }

    private func entryGridContentHeight(itemCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard itemCount > 0 else {
            return 0
        }

        let columns = max(1, selectedLayout.gridColumnCount)
        let spacing: CGFloat = 14
        let rowCount = Int(ceil(Double(itemCount) / Double(columns)))
        let rowHeight = entryGridRowHeight(availableWidth: availableWidth, columns: columns)
        return CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * spacing
    }

    private func visibleRowWindow(rowCount: Int, rowStride: CGFloat) -> Range<Int> {
        guard rowCount > 0, rowStride > 0 else {
            return 0..<0
        }

        let viewport = max(scrollViewportHeight, 1)
        // Content moves up as the user scrolls; minY decreases.
        let scrolled = max(0, -entryContentMinY)
        let bufferRows = 2
        let first = max(0, Int(floor(scrolled / rowStride)) - bufferRows)
        let visibleRows = Int(ceil(viewport / rowStride)) + (bufferRows * 2)
        let last = min(rowCount, first + max(visibleRows, 1))
        return first..<max(first, last)
    }

    private func entryList(_ items: [EntryDisplayItem]) -> some View {
        let rowHeight: CGFloat = 52
        let listHeight = CGFloat(items.count) * rowHeight
        let window = visibleRowWindow(rowCount: items.count, rowStride: rowHeight)

        return VStack(spacing: 0) {
            if window.lowerBound > 0 {
                Color.clear
                    .frame(height: CGFloat(window.lowerBound) * rowHeight)
            }

            ForEach(Array(window), id: \.self) { index in
                let item = items[index]
                let displayEntry = entryForDisplay(item)
                Button {
                    handleItemTap(item, displayEntry: displayEntry, fallbackIndex: index)
                } label: {
                    EntryListRow(
                        entry: displayEntry,
                        sortOption: .manual,
                        pageLabel: pageLabel(for: index),
                        category: isCompleted(item) ? .completed : .drafts,
                        completedStoryboardImage: isCompleted(item) ? storyboardImage(for: item, fallbackIndex: index) : nil,
                        completedStoryboardCount: isCompleted(item) ? storyboardCount(for: item) : 0,
                        showsCompletedStoryboardCount: false,
                        rowHeight: rowHeight,
                        coverWidth: 34,
                        coverHeight: 44
                    )
                    .overlay(alignment: .leading) {
                        if editMode == .active {
                            EntrySelectionBadge(isSelected: selectedEntryIDs.contains(item.id))
                                .padding(.leading, 8)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(height: rowHeight)
                .contextMenu {
                    Button(role: .destructive) {
                        requestDeleteEntry(item)
                    } label: {
                        Label(journalDetailDeleteActionTitle, systemImage: "trash")
                    }
                }
                .modifier(JournalDetailEntryDragModifier(
                    entryID: item.id,
                    isEnabled: isEntryReorderingEnabled,
                    draggingEntryID: $draggingEntryID
                ))
                .onDrop(
                    of: [UTType.text],
                    delegate: EntryDropDelegate(
                        item: item,
                        items: items,
                        draggingEntryID: $draggingEntryID,
                        isEnabled: isEntryReorderingEnabled,
                        onReorder: moveEntryItem
                    )
                )
            }

            Color.clear
                .frame(height: max(0, listHeight - CGFloat(window.lowerBound) * rowHeight - CGFloat(window.count) * rowHeight))
        }
        .frame(height: listHeight, alignment: .top)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: JournalDetailScrollOffsetKey.self,
                    value: geo.frame(in: .named(JournalDetailScrollCoordinate.spaceName)).minY
                )
            }
        }
        .onPreferenceChange(JournalDetailScrollOffsetKey.self) { entryContentMinY = $0 }
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: entryGridColumns, spacing: 14) {
            ForEach(0..<(selectedLayout.gridColumnCount * selectedLayout.gridColumnCount), id: \.self) { index in
                EntryGridLoadingCard(seed: index)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 32))
                .foregroundStyle(Color.homeAccent.opacity(0.72))

            Text("No entries")
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            if allowsCreation {
                Button {
                    onCreateEntry()
                } label: {
                    Label("Write the First Entry", systemImage: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    private func cloudErrorNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.homeAccent)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
            Spacer()
            Button("Retry", action: refreshEntries)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.homeAccent)
        }
    }

    private func refreshEntries() {
        let membershipSnapshot = JournalDetailMembershipSnapshot.make(for: chapter)
        self.membershipSnapshot = membershipSnapshot

        let memberIDs = Array(membershipSnapshot.memberIDs)
        let loadedLocalEntries = readsSampleContentFromMemory
            ? SampleContentStore.entries(ids: memberIDs)
            : CreateEntryDraftStore.load(ids: memberIDs, includeMedia: false)
        localEntries = loadedLocalEntries
        let localStoryboards = readsSampleContentFromMemory
            ? SampleContentStore.storyboards(clientEntryIDs: membershipSnapshot.memberIDs)
            : GeneratedStoryboardStore.load(clientEntryIDs: membershipSnapshot.memberIDs)
        completedStoryboards = localStoryboards.map { storyboard in
            GeneratedStoryboard(
                id: storyboard.id,
                clientEntryID: storyboard.clientEntryID,
                image: storyboard.image.journaltopiaDownsampled(maxDimension: 640),
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
        var localCounts: [UUID: Int] = [:]
        for storyboard in localStoryboards {
            if let clientEntryID = storyboard.clientEntryID {
                localCounts[clientEntryID, default: 0] += 1
            }
        }
        storyboardCountsByClientEntryID = localCounts

        let localItems = makeDisplayItems(
            localEntries: loadedLocalEntries,
            cloudEntries: cloudEntries,
            membershipSnapshot: membershipSnapshot
        )
        publishVisibleItems(localItems, notifiesParent: authStore.userID == nil)

        guard let userID = authStore.userID else {
            cloudEntries = []
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            errorMessage = nil
            isLoading = false
            return
        }

        guard !membershipSnapshot.memberIDs.isEmpty else {
            cloudEntries = []
            errorMessage = nil
            isLoading = false
            return
        }

        let queryKey = EntriesCloudFetchCache.EntryQueryKey(
            userID: userID,
            sort: .createdAt,
            statusFilter: .all
        )

        // Prefer an existing global cache when present, then filter to this journal.
        let exactCachedEntries = EntriesCloudFetchCache.entrySummaries(for: queryKey)
        let staleCachedEntries = exactCachedEntries == nil ? completeStaleEntrySummaries(for: queryKey) : nil

        if let cachedEntries = exactCachedEntries ?? staleCachedEntries {
            let scopedEntries = cachedEntries.entries.filter { membershipSnapshot.memberIDs.contains($0.clientEntryID) }
            cloudEntries = scopedEntries
            errorMessage = nil
            isLoading = false
            let cachedItems = makeDisplayItems(
                localEntries: loadedLocalEntries,
                cloudEntries: scopedEntries,
                membershipSnapshot: membershipSnapshot
            )
            publishVisibleItems(cachedItems, notifiesParent: exactCachedEntries != nil)
            loadMissingCompletedStoryboards()

            if exactCachedEntries != nil {
                return
            }
        } else if localItems.isEmpty {
            isLoading = true
        }

        let scopedMemberIDs = membershipSnapshot.memberIDs
        Task {
            do {
                let entries = try await SupabaseEntryRepository().getEntrySummaries(clientEntryIDs: scopedMemberIDs)
                await MainActor.run {
                    guard self.membershipSnapshot.memberIDs == membershipSnapshot.memberIDs,
                          self.membershipSnapshot.memberPositions == membershipSnapshot.memberPositions
                    else {
                        return
                    }

                    cloudEntries = entries
                    errorMessage = nil
                    isLoading = false
                    let currentItems = makeDisplayItems(
                        localEntries: localEntries,
                        cloudEntries: entries,
                        membershipSnapshot: membershipSnapshot
                    )
                    publishVisibleItems(currentItems, notifiesParent: true)
                    loadMissingCompletedStoryboards()
                }
            } catch {
                await MainActor.run {
                    if cloudEntries.isEmpty {
                        errorMessage = "Could not load cloud entries."
                    }
                    isLoading = false
                }
            }
        }
    }

    private func completeStaleEntrySummaries(
        for queryKey: EntriesCloudFetchCache.EntryQueryKey
    ) -> EntriesCloudFetchCache.CachedEntrySummaries? {
        guard
            let cached = EntriesCloudFetchCache.staleEntrySummaries(for: queryKey),
            !cached.hasMore
        else {
            return nil
        }

        return cached
    }

    private func loadMissingCompletedStoryboards() {
        guard authStore.userID != nil else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            return
        }

        let currentItems = visibleItems
        let completedClientEntryIDs = Set(currentItems.filter { isCompleted($0) }.map(\.id))

        guard !completedClientEntryIDs.isEmpty else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            return
        }

        let locallyCachedStoryboards = GeneratedStoryboardStore.load(clientEntryIDs: completedClientEntryIDs)
        let cachedClientEntryIDs = Set((completedStoryboards + locallyCachedStoryboards).compactMap(\.clientEntryID))
        let missingClientEntryIDs = completedClientEntryIDs.subtracting(cachedClientEntryIDs)
        if !missingClientEntryIDs.isEmpty {
            cloudStoryboardClientIDs.formUnion(missingClientEntryIDs)
            failedCloudStoryboardClientIDs.subtract(missingClientEntryIDs)
        }

        Task {
            let storyboardService = SupabaseStoryboardService()

            do {
                let rows = try await storyboardService.loadCompletedStoryboardRows(for: completedClientEntryIDs)
                var countsByClientEntryID: [UUID: Int] = [:]
                for row in rows {
                    countsByClientEntryID[row.clientEntryID, default: 0] += 1
                }

                let cachedStoryboardIDs = Set(locallyCachedStoryboards.map(\.id))
                let clientEntryIDsNeedingImages = Set(
                    rows.compactMap { row in
                        cachedStoryboardIDs.contains(row.id) ? nil : row.clientEntryID
                    }
                )
                let rowsToDownload = rows.filter { clientEntryIDsNeedingImages.contains($0.clientEntryID) }
                if !clientEntryIDsNeedingImages.isEmpty {
                    await MainActor.run {
                        cloudStoryboardClientIDs.formUnion(clientEntryIDsNeedingImages)
                        failedCloudStoryboardClientIDs.subtract(clientEntryIDsNeedingImages)
                    }
                }

                let downloadedStoryboards = await storyboardService.downloadStoryboards(from: rowsToDownload)
                let cachedCloudStoryboards = GeneratedStoryboardStore.cachedStoryboards(downloadedStoryboards)
                var persistedStoryboards = GeneratedStoryboardStore.load()
                for storyboard in cachedCloudStoryboards {
                    persistedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: persistedStoryboards)
                }
                if !cachedCloudStoryboards.isEmpty {
                    GeneratedStoryboardStore.save(persistedStoryboards)
                }

                await MainActor.run {
                    let currentCompletedClientEntryIDs = Set(visibleItems.filter { isCompleted($0) }.map(\.id))
                    guard currentCompletedClientEntryIDs == completedClientEntryIDs else {
                        return
                    }

                    var mergedStoryboards = completedStoryboards
                    for storyboard in locallyCachedStoryboards + cachedCloudStoryboards {
                        let cardStoryboard = GeneratedStoryboard(
                            id: storyboard.id,
                            clientEntryID: storyboard.clientEntryID,
                            image: storyboard.image.journaltopiaDownsampled(maxDimension: 640),
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
                        mergedStoryboards = GeneratedStoryboardStore.merging(cardStoryboard, into: mergedStoryboards)
                        if let clientEntryID = storyboard.clientEntryID {
                            cloudStoryboardClientIDs.remove(clientEntryID)
                        }
                    }

                    completedStoryboards = mergedStoryboards
                    for (clientEntryID, count) in countsByClientEntryID {
                        storyboardCountsByClientEntryID[clientEntryID] = max(
                            storyboardCountsByClientEntryID[clientEntryID, default: 0],
                            count
                        )
                    }

                    let downloadedClientEntryIDs = Set(cachedCloudStoryboards.compactMap(\.clientEntryID))
                    let clientEntryIDsWithCloudRows = Set(countsByClientEntryID.keys)
                    let failedClientEntryIDs = clientEntryIDsNeedingImages
                        .subtracting(downloadedClientEntryIDs)
                        .union(missingClientEntryIDs.subtracting(clientEntryIDsWithCloudRows))
                    cloudStoryboardClientIDs.subtract(failedClientEntryIDs)
                    failedCloudStoryboardClientIDs.formUnion(failedClientEntryIDs)
                    notifyEntriesChangedIfNeeded(for: visibleItems)
                    notifyVisibleEntriesAvailability(items: visibleItems)
                }
            } catch {
                await MainActor.run {
                    cloudStoryboardClientIDs.subtract(completedClientEntryIDs)
                    failedCloudStoryboardClientIDs.formUnion(completedClientEntryIDs)
                }
            }
        }
    }

    private func publishVisibleItems(_ items: [EntryDisplayItem], notifiesParent: Bool) {
        let signature = items.map(\.id)
        visibleItems = items
        visibleItemSignature = signature
        notifyVisibleEntriesAvailability(items: items)
        queueMissingThumbnailRender(for: items)

        if notifiesParent {
            notifyEntriesChangedIfNeeded(for: items)
        }
    }

    private func notifyEntriesChangedIfNeeded(for items: [EntryDisplayItem]) {
        let signature = items.map(\.id)
        guard signature != lastNotifiedEntrySignature else {
            return
        }

        lastNotifiedEntrySignature = signature
        suppressedChapterEntryRefreshSignature = signature
        onEntriesChanged(items.map { entryForDisplay($0).prototypeEntry() })
    }

    private func matchesChapterFilter(
        _ entry: CreateEntryDraft,
        membershipSnapshot: JournalDetailMembershipSnapshot
    ) -> Bool {
        membershipSnapshot.memberIDs.contains(entry.id)
            || membershipSnapshot.linkedJournalTitlesByEntryID[entry.id, default: []].contains(chapter.title)
    }

    private func matchesChapterFilter(
        _ entry: JournalEntry,
        membershipSnapshot: JournalDetailMembershipSnapshot
    ) -> Bool {
        membershipSnapshot.memberIDs.contains(entry.clientEntryID)
    }

    private func matchesChapterFilter(
        _ item: EntryDisplayItem,
        membershipSnapshot: JournalDetailMembershipSnapshot
    ) -> Bool {
        matchesChapterFilter(item.entry, membershipSnapshot: membershipSnapshot)
    }

    private func sortEntryItems(
        _ lhs: EntryDisplayItem,
        _ rhs: EntryDisplayItem,
        membershipSnapshot: JournalDetailMembershipSnapshot
    ) -> Bool {
        let lhsPosition = manualEntryOrderOverrides[lhs.id] ?? membershipSnapshot.memberPositions[lhs.id]
        let rhsPosition = manualEntryOrderOverrides[rhs.id] ?? membershipSnapshot.memberPositions[rhs.id]

        switch (lhsPosition, rhsPosition) {
        case let (lhsPosition?, rhsPosition?) where lhsPosition != rhsPosition:
            return lhsPosition < rhsPosition
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        default:
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func pageLabel(for index: Int) -> String {
        "Page \(index + 1)"
    }

    private func entryForDisplay(_ item: EntryDisplayItem) -> CreateEntryDraft {
        let entry = item.entry
        guard entry.thumbnail == nil else {
            return entry
        }

        guard let cachedThumbnail = renderedThumbnails[entry.id],
              cachedThumbnail.signature == JournalDetailThumbnailSignature(entry: entry)
        else {
            return entry
        }

        return entry.replacingThumbnail(cachedThumbnail.thumbnail)
    }

    private func renderThumbnail(for entry: CreateEntryDraft) -> UIImage? {
        DraftThumbnailRenderer.render(
            title: entry.title,
            text: entry.text,
            richText: entry.richText,
            photos: [],
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
            textAlignmentRawValue: entry.textAlignmentRawValue
        )
    }

    private func queueMissingThumbnailRender(for items: [EntryDisplayItem]) {
        let entriesNeedingThumbnails = items
            .map(\.entry)
            .filter { entry in
                guard entry.thumbnail == nil else {
                    return false
                }

                let signature = JournalDetailThumbnailSignature(entry: entry)
                return renderedThumbnails[entry.id]?.signature != signature
            }

        let currentIDs = Set(items.map(\.id))
        renderedThumbnails = renderedThumbnails.filter { currentIDs.contains($0.key) }
        thumbnailRenderTask?.cancel()

        guard !entriesNeedingThumbnails.isEmpty else {
            thumbnailRenderTask = nil
            return
        }

        thumbnailRenderTask = Task { @MainActor in
            for entry in entriesNeedingThumbnails {
                guard !Task.isCancelled else {
                    return
                }

                let signature = JournalDetailThumbnailSignature(entry: entry)
                if renderedThumbnails[entry.id]?.signature == signature {
                    continue
                }

                let thumbnail = renderThumbnail(for: entry)
                renderedThumbnails[entry.id] = JournalDetailRenderedThumbnail(
                    signature: signature,
                    thumbnail: thumbnail
                )

                if let thumbnail {
                    CreateEntryDraftStore.saveThumbnail(thumbnail, for: entry.id)
                }

                await Task.yield()
            }
        }
    }

    private func isCompleted(_ item: EntryDisplayItem) -> Bool {
        item.status == JournalEntryStatus.completed.rawValue
    }

    private var selectedItems: [EntryDisplayItem] {
        visibleItems.filter { selectedEntryIDs.contains($0.id) }
    }

    private var isDeleteEntryAlertPresented: Binding<Bool> {
        Binding(
            get: { !entriesPendingDeletion.isEmpty },
            set: { isPresented in
                if !isPresented {
                    entriesPendingDeletion = []
                }
            }
        )
    }

    private var deleteEntryAlertTitle: String {
        "Are u sure?"
    }

    private var hasEntriesPendingDeletionOutsideCurrentJournal: Bool {
        entriesPendingDeletion.contains { !otherJournalTitles(for: $0).isEmpty }
    }

    private var deleteEntryAlertMessage: String {
        if let entry = entriesPendingDeletion.first, entriesPendingDeletion.count == 1 {
            if otherJournalTitles(for: entry).isEmpty {
                return "\"\(entryDisplayTitle(entry.entry))\" is only in \(chapter.title). Removing it here will delete it permanently."
            }

            return "Remove \"\(entryDisplayTitle(entry.entry))\" from \(chapter.title), or delete it from every journal?"
        }

        if hasEntriesPendingDeletionOutsideCurrentJournal {
            return "Remove these entries from \(chapter.title), or delete them from every journal? Entries with no other journals will be deleted permanently."
        }

        return "These entries are only in \(chapter.title). Removing them here will delete them permanently."
    }

    private func handleItemTap(_ item: EntryDisplayItem, displayEntry: CreateEntryDraft, fallbackIndex: Int) {
        if editMode == .active {
            toggleEntrySelection(item.id)
        } else {
            guard openingEntryID == nil else {
                return
            }

            openingEntryID = item.id
            Task {
                await openItem(item, displayEntry: displayEntry, fallbackIndex: fallbackIndex)
            }
        }
    }

    private func toggleEntrySelection(_ entryID: UUID) {
        if selectedEntryIDs.contains(entryID) {
            selectedEntryIDs.remove(entryID)
        } else {
            selectedEntryIDs.insert(entryID)
        }
    }

    private func moveEntryItem(draggingEntryID: UUID, targetEntryID: UUID) {
        guard
            isEntryReorderingEnabled,
            draggingEntryID != targetEntryID
        else {
            return
        }

        var reorderedItems = visibleItems
        guard
            let fromIndex = reorderedItems.firstIndex(where: { $0.id == draggingEntryID }),
            let toIndex = reorderedItems.firstIndex(where: { $0.id == targetEntryID })
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            let movedItem = reorderedItems.remove(at: fromIndex)
            reorderedItems.insert(movedItem, at: toIndex)
        }

        let reorderedEntries = reorderedItems.map { entryForDisplay($0).prototypeEntry() }
        manualEntryOrderOverrides = Dictionary(
            uniqueKeysWithValues: reorderedItems.enumerated().map { offset, item in
                (item.id, offset)
            }
        )
        StoryEntryStore.saveStoredOrder(from: reorderedEntries, for: chapter.title)
        publishVisibleItems(reorderedItems, notifiesParent: true)
        Task {
            await UserChapterStore.syncJournalAndEntriesToCloud(title: chapter.title)
        }
    }

    private func notifyVisibleEntriesAvailability() {
        notifyVisibleEntriesAvailability(items: visibleItems)
    }

    private func notifyVisibleEntriesAvailability(items: [EntryDisplayItem]) {
        if !items.isEmpty {
            hasVisibleJournalEntries = true
            return
        }

        // Avoid flashing the button away while cloud entries are still loading.
        if !isLoading {
            hasVisibleJournalEntries = false
        }
    }

    private func openAddSelectedEntriesToJournalPage() {
        let journalTitles = selectedJournalTitlesForAddSheet()
        selectedEntriesJournalTitles = journalTitles
        selectedEntriesJournalTitle = journalTitles.sorted().first

        Task {
            await refreshCloudJournalsBeforeShowingSelectedEntrySheet()
            isShowingAddSelectedEntriesToJournalSheet = true
        }
    }

    private func addSelectedEntriesToJournals(_ journalTitles: Set<String>) {
        guard !journalTitles.isEmpty else {
            return
        }

        guard signInGate.requireAccount(for: .editEntry) else {
            return
        }

        selectedItems.forEach { item in
            let entry = entryForDisplay(item).prototypeEntry()
            journalTitles.sorted().forEach { journalTitle in
                StoryEntryStore.upsert(entry, to: journalTitle)
                EntryJournalLinkStore.save(journalTitle: journalTitle, journalEntryID: entry.id, for: item.id)
            }
        }

        Task {
            await syncSelectedEntryJournalsToCloud(journalTitles)
        }

        selectedEntriesJournalTitles = journalTitles
        selectedEntriesJournalTitle = journalTitles.sorted().first
        selectedEntryIDs = []
        editMode = .inactive
        refreshEntries()
    }

    private func requestDeleteSelectedEntries() {
        guard signInGate.requireAccount(for: .deleteEntry) else {
            return
        }

        entriesPendingDeletion = selectedItems
    }

    private func duplicateSelectedEntries() {
        let itemsToDuplicate = selectedItems
        guard !itemsToDuplicate.isEmpty, !isDuplicatingSelectedEntries else {
            return
        }

        guard signInGate.requireAccount(for: .createEntry) else {
            return
        }

        isDuplicatingSelectedEntries = true
        duplicateErrorMessage = nil

        Task {
            var duplicatedItems: [EntryDisplayItem] = []
            var duplicatedEntries: [CreateEntryDraft] = []

            for item in itemsToDuplicate {
                do {
                    let sourceEntry = fullLocalEntry(for: item)
                    let duplicateID = UUID()
                    let status = JournalEntryStatus(rawValue: item.status) ?? .draft
                    let result = try await EntrySaveService().saveEntryPreservingStatus(
                        payload: sourceEntry.duplicateSavePayload(id: duplicateID),
                        isSignedIn: authStore.userID != nil,
                        status: status
                    )

                    if authStore.userID != nil, result.cloudEntry == nil {
                        CreateEntryDraftStore.delete(id: result.localDraftID)
                        throw JournalEntryRepositoryError.operationFailed
                    }

                    guard let duplicateEntry = CreateEntryDraftStore.load(id: result.localDraftID) else {
                        throw JournalEntryRepositoryError.operationFailed
                    }

                    let prototypeEntry = duplicateEntry.prototypeEntry()
                    StoryEntryStore.upsert(prototypeEntry, to: chapter.title)
                    EntryJournalLinkStore.save(
                        journalTitle: chapter.title,
                        journalEntryID: prototypeEntry.id,
                        for: duplicateEntry.id
                    )

                    let duplicateItem: EntryDisplayItem
                    if let cloudEntry = result.cloudEntry {
                        cloudEntries.removeAll { $0.clientEntryID == cloudEntry.clientEntryID }
                        cloudEntries.insert(cloudEntry, at: 0)
                        duplicateItem = .local(duplicateEntry, cloudEntry: cloudEntry)
                    } else {
                        duplicateItem = .local(duplicateEntry, cloudEntry: nil)
                    }

                    let duplicatedStoryboards = await duplicateStoryboardsForEntry(
                        sourceClientEntryID: item.id,
                        duplicateClientEntryID: result.localDraftID,
                        isSignedIn: authStore.userID != nil
                    )
                    if !duplicatedStoryboards.isEmpty {
                        completedStoryboards = duplicatedStoryboards + completedStoryboards
                        storyboardCountsByClientEntryID[result.localDraftID] = duplicatedStoryboards.count
                    } else if storyboardCount(for: item) > 0 {
                        duplicateErrorMessage = "Duplicated the entry, but could not duplicate one or more storyboards."
                    }

                    duplicatedEntries.append(duplicateEntry)
                    duplicatedItems.append(duplicateItem)
                } catch {
                    duplicateErrorMessage = "Could not duplicate one or more entries."
                }
            }

            if !duplicatedEntries.isEmpty {
                localEntries.append(contentsOf: duplicatedEntries)
                let nextItems = duplicatedItems + visibleItems
                publishVisibleItems(nextItems, notifiesParent: true)
            }

            if authStore.userID != nil {
                EntriesCloudFetchCache.invalidate(for: authStore.userID)
                EntriesSessionMemoryCache.invalidate(userID: authStore.userID)
                await UserChapterStore.syncJournalAndEntriesToCloud(title: chapter.title)
            }

            selectedEntryIDs.subtract(itemsToDuplicate.map(\.id))
            if selectedEntryIDs.isEmpty {
                editMode = .inactive
            }
            isDuplicatingSelectedEntries = false
            refreshEntries()
        }
    }

    private func requestDeleteEntry(_ item: EntryDisplayItem) {
        entriesPendingDeletion = [item]
    }

    private func deletePendingEntriesFromCurrentJournal(_ itemsToDelete: [EntryDisplayItem]) async {
        guard !itemsToDelete.isEmpty else {
            return
        }

        let scopedItems = itemsToDelete.filter { !otherJournalTitles(for: $0).isEmpty }
        let permanentItems = itemsToDelete.filter { otherJournalTitles(for: $0).isEmpty }

        guard await deleteItemsEverywhereInCloud(permanentItems) else {
            return
        }

        if authStore.userID != nil && !scopedItems.isEmpty {
            do {
                try await SupabaseJournalRepository().deleteJournalEntryMemberships(
                    journalID: chapter.id,
                    clientEntryIDs: scopedItems.map(\.id)
                )
            } catch {
                entriesPendingDeletion = itemsToDelete
                errorMessage = "Could not delete from Journaltopia cloud. Check your connection and try again."
                return
            }
        }

        scopedItems.forEach { item in
            let entry = entryForDisplay(item).prototypeEntry()
            StoryEntryStore.delete(entry, from: chapter.title)
            EntryJournalLinkStore.remove(journalTitle: chapter.title, for: item.id)
        }

        permanentlyDeleteLocalItems(permanentItems)

        completePendingDelete(itemsToDelete)
        await UserChapterStore.syncJournalAndEntriesToCloud(title: chapter.title)
    }

    private func deletePendingEntriesEverywhere(_ itemsToDelete: [EntryDisplayItem]) async {
        guard !itemsToDelete.isEmpty else {
            return
        }

        guard await deleteItemsEverywhereInCloud(itemsToDelete) else {
            return
        }

        permanentlyDeleteLocalItems(itemsToDelete)
        completePendingDelete(itemsToDelete)
    }

    private func deleteItemsEverywhereInCloud(_ items: [EntryDisplayItem]) async -> Bool {
        guard authStore.userID != nil else {
            return true
        }

        for item in items {
            do {
                try await EntrySaveService().deleteEntry(
                    localDraftID: item.id,
                    cloudEntry: item.cloudEntry,
                    isSignedIn: true
                )
            } catch {
                entriesPendingDeletion = items
                errorMessage = "Could not delete from Journaltopia cloud. Check your connection and try again."
                return false
            }
        }

        return true
    }

    private func permanentlyDeleteLocalItems(_ items: [EntryDisplayItem]) {
        items.forEach { item in
            StoryEntryStore.delete(entryID: item.id)
            EntryJournalLinkStore.remove(for: item.id)
            localEntries.removeAll { $0.id == item.id }
            cloudEntries.removeAll { $0.clientEntryID == item.id }
        }
    }

    private func completePendingDelete(_ itemsToDelete: [EntryDisplayItem]) {
        entriesPendingDeletion = []
        errorMessage = nil
        selectedEntryIDs.subtract(itemsToDelete.map(\.id))
        editMode = .inactive
        refreshEntries()
    }

    private func otherJournalTitles(for item: EntryDisplayItem) -> Set<String> {
        let entry = entryForDisplay(item).prototypeEntry()
        return StoryEntryStore.journalTitles(containing: entry)
            .union(membershipSnapshot.linkedJournalTitlesByEntryID[item.id, default: []])
            .subtracting([chapter.title])
    }

    private func selectedJournalTitlesForAddSheet() -> Set<String> {
        let titleSets = selectedItems.map { item in
            otherJournalTitles(for: item).union([chapter.title])
        }

        guard let firstTitleSet = titleSets.first else {
            return []
        }

        return titleSets.dropFirst().reduce(firstTitleSet) { sharedTitles, titles in
            sharedTitles.intersection(titles)
        }
    }

    private var isDuplicateEntryAlertPresented: Binding<Bool> {
        Binding(
            get: { duplicateErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    duplicateErrorMessage = nil
                }
            }
        )
    }

    private func fullLocalEntry(for item: EntryDisplayItem) -> CreateEntryDraft {
        CreateEntryDraftStore.load(id: item.id) ?? entryForDisplay(item)
    }

    @MainActor
    private func deleteDraftEntry(_ item: EntryDisplayItem) async {
        do {
            try await EntrySaveService().deleteEntry(
                localDraftID: item.id,
                cloudEntry: item.cloudEntry,
                isSignedIn: authStore.userID != nil
            )
            StoryEntryStore.delete(entryID: item.id)
            EntryJournalLinkStore.remove(for: item.id)
            localEntries.removeAll { $0.id == item.id }
            cloudEntries.removeAll { $0.clientEntryID == item.id }
        } catch {
            errorMessage = "Could not delete one or more entries."
        }
    }

    private func syncSelectedEntryJournalsToCloud(_ journalTitles: Set<String>) async {
        guard authStore.userID != nil else {
            return
        }

        for journalTitle in journalTitles {
            await UserChapterStore.syncJournalAndEntriesToCloud(title: journalTitle)
        }
    }

    private func refreshCloudJournalsBeforeShowingSelectedEntrySheet() async {
        guard authStore.userID != nil else {
            return
        }

        do {
            let cloudJournals = try await SupabaseJournalRepository().getJournals()
            let chapters = cloudJournals.map(PrototypeChapter.init(cloudJournal:))
            UserChapterStore.replace(with: chapters)
        } catch {
            print("[Journaltopia] Could not refresh journals before adding selected entries.")
        }
    }

    private func storyboardImage(for item: EntryDisplayItem, fallbackIndex: Int) -> CompletedStoryboardImage {
        if let image = storyboardUIImage(for: item, fallbackIndex: fallbackIndex) {
            return .uiImage(image)
        }

        if cloudStoryboardClientIDs.contains(item.id) {
            return .loading
        }

        if failedCloudStoryboardClientIDs.contains(item.id) {
            return .failed
        }

        return .failed
    }

    private func storyboardCount(for item: EntryDisplayItem) -> Int {
        if let counted = storyboardCountsByClientEntryID[item.id], counted > 0 {
            return counted
        }

        return completedStoryboards.filter { $0.clientEntryID == item.id }.count
    }

    private func storyboardUIImage(for item: EntryDisplayItem, fallbackIndex: Int) -> UIImage? {
        if let storyboard = completedStoryboards.first(where: { $0.clientEntryID == item.id && $0.isPrimary })
            ?? completedStoryboards.first(where: { $0.clientEntryID == item.id }) {
            return storyboard.image
        }

        if completedStoryboards.indices.contains(fallbackIndex),
           completedStoryboards[fallbackIndex].clientEntryID == nil {
            return completedStoryboards[fallbackIndex].image
        }

        return nil
    }

    private func openItem(_ item: EntryDisplayItem, displayEntry: CreateEntryDraft, fallbackIndex: Int) async {
        defer {
            openingEntryID = nil
        }

        let isCompleted = isCompleted(item)
        let storyboardImage: UIImage? = {
            guard isCompleted else {
                return nil
            }

            if let fullImage = GeneratedStoryboardStore.load(clientEntryIDs: [item.id])
                .first(where: { $0.isPrimary })?.image
                ?? GeneratedStoryboardStore.load(clientEntryIDs: [item.id]).first?.image {
                return fullImage
            }

            return storyboardUIImage(for: item, fallbackIndex: fallbackIndex)
        }()
        let hydratedDisplayEntry = CreateEntryDraftStore.load(id: displayEntry.id) ?? displayEntry
        guard let entryToOpen = await materializedEntry(for: item, displayEntry: hydratedDisplayEntry) else {
            return
        }
        onOpenEntry(entryToOpen, isCompleted, storyboardImage)
    }

    private func materializedEntry(for item: EntryDisplayItem, displayEntry: CreateEntryDraft) async -> CreateEntryDraft? {
        guard let cloudEntry = item.cloudEntry else {
            return displayEntry
        }

        // Same protection as the Entries list: an entry opened from inside a journal must not have
        // locally autosaved edits replaced by the older snapshot the server still holds.
        if CreateEntryCloudMaterialization.decision(for: item.id) == .preserveLocalEdits {
            return CreateEntryDraftStore.load(id: item.id) ?? displayEntry
        }

        do {
            let fullCloudEntry = try await SupabaseEntryRepository().getEntry(id: cloudEntry.id)
            let cloudDraft = CreateEntryDraft.fromCloud(fullCloudEntry, thumbnail: displayEntry.thumbnail)
            let photos = try await SupabaseReferencePhotoService().loadReferencePhotos(entryID: fullCloudEntry.id)
            let characters: [EntryCharacter]

            do {
                characters = try await SupabaseEntryCharacterService().loadCharacters(entryID: fullCloudEntry.id)
            } catch {
                print("[Journaltopia] Journal detail entry character download skipped: \(error.localizedDescription)")
                characters = []
            }
            let resolvedPhotos = photos.isEmpty && !displayEntry.photos.isEmpty ? displayEntry.photos : photos
            let resolvedCharacters = characters.isEmpty && !displayEntry.characters.isEmpty ? displayEntry.characters : characters

            _ = CreateEntryDraftStore.save(
                id: cloudDraft.id,
                title: cloudDraft.title,
                text: cloudDraft.text,
                richText: cloudDraft.richText,
                referencePhotos: resolvedPhotos,
                characters: resolvedCharacters,
                artStyle: cloudDraft.artStyle,
                location: cloudDraft.location,
                date: cloudDraft.date,
                datePrecision: cloudDraft.datePrecision,
                savesDraft: cloudDraft.savesDraft,
                isPrivate: cloudDraft.isPrivate,
                status: JournalEntryStatus(rawValue: item.status) ?? .draft,
                fontChoiceRawValue: cloudDraft.fontChoiceRawValue,
                textColorIndex: cloudDraft.textColorIndex,
                textSize: cloudDraft.textSize,
                paperStyleRawValue: cloudDraft.paperStyleRawValue,
                paperColorIndex: cloudDraft.paperColorIndex,
                isBold: cloudDraft.isBold,
                isItalic: cloudDraft.isItalic,
                isUnderlined: cloudDraft.isUnderlined,
                isStrikethrough: cloudDraft.isStrikethrough,
                isHighlighted: cloudDraft.isHighlighted,
                textAlignmentRawValue: cloudDraft.textAlignmentRawValue,
                thumbnail: cloudDraft.thumbnail,
                createdAt: cloudDraft.createdAt,
                cloudSyncState: .synchronized
            )

            return CreateEntryDraftStore.load(id: cloudDraft.id) ?? cloudDraft
        } catch {
            errorMessage = "Could not download this entry's reference photos."
            return nil
        }
    }
}

private struct JournalMediaStoryboardItem: Identifiable {
    let storyboard: GeneratedStoryboard
    let storyboardCount: Int

    var id: UUID {
        storyboard.id
    }
}

private struct PrototypeEntryReorderDropDelegate: DropDelegate {
    let targetEntry: PrototypeEntry
    @Binding var entries: [PrototypeEntry]
    @Binding var draggingEntryID: UUID?
    let onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        guard
            let draggingEntryID,
            draggingEntryID != targetEntry.id,
            let fromIndex = entries.firstIndex(where: { $0.id == draggingEntryID }),
            let toIndex = entries.firstIndex(where: { $0.id == targetEntry.id })
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            entries.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        onReorder()
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingEntryID = nil
        onReorder()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct JournalDetailEntryDragModifier: ViewModifier {
    let entryID: UUID
    let isEnabled: Bool
    @Binding var draggingEntryID: UUID?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrag {
                    draggingEntryID = entryID
                    return NSItemProvider(object: entryID.uuidString as NSString)
                }
        } else {
            content
        }
    }
}

private struct MediaStoryboardDragModifier: ViewModifier {
    let storyboardID: UUID
    @Binding var draggingStoryboardID: UUID?

    func body(content: Content) -> some View {
        content
            .onDrag {
                draggingStoryboardID = storyboardID
                return NSItemProvider(object: storyboardID.uuidString as NSString)
            }
    }
}

private struct MediaStoryboardDropDelegate: DropDelegate {
    let storyboard: GeneratedStoryboard
    let storyboards: [GeneratedStoryboard]
    @Binding var draggingStoryboardID: UUID?
    let onReorder: (UUID, UUID) -> Void

    func dropEntered(info _: DropInfo) {
        guard
            let draggingStoryboardID,
            draggingStoryboardID != storyboard.id,
            storyboards.contains(where: { $0.id == draggingStoryboardID })
        else {
            return
        }

        onReorder(draggingStoryboardID, storyboard.id)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggingStoryboardID = nil
        return true
    }
}

private struct PrototypeEntryDetailView: View {
    let entry: PrototypeEntry
    let chapter: PrototypeChapter
    let title: String

    @State private var isFavorite = false
    @State private var selectedImageName: String?

    var body: some View {
        ZStack {
            storyDetailBackground

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        if !entry.imageNames.isEmpty {
                            photoStory
                        }

                        entryIntroduction
                        journalPage
                        entryDetails
                        referencePhotosSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 36)
                }
                .background(Color.clear)
            }
        }
        .background(storyDetailBackground)
        .preferredColorScheme(.light)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .tint(Color.homeAccent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                entryOptionsMenu
            }
        }
        .sheet(
            isPresented: Binding(
                get: { selectedImageName != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedImageName = nil
                    }
                }
            )
        ) {
            if let selectedImageName {
                PhotoViewer(imageName: selectedImageName, accentColor: Color.homeAccent)
            }
        }
    }

    private var storyDetailBackground: some View {
        Color.homePageBackground
            .ignoresSafeArea()
    }

    private var entryOptionsMenu: some View {
        Menu {
            Button {
                isFavorite.toggle()
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }

            Button {
            } label: {
                Label("Edit Story", systemImage: "pencil")
            }

            Button {
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .fontWeight(.bold)
                .foregroundStyle(Color.storyInk)
        }
        .accessibilityLabel("Story options")
    }

    private var entryIntroduction: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(entry.createdAt.formatted(.dateTime.month(.wide).day().year()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.56))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                VStack(spacing: 1) {
                    Text(entry.weekday)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.homeAccent)

                    Text(entry.day)
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                }
                .frame(width: 48, height: 54)
                .background(Color.homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.homeAccent)

                    Text(entry.time)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) {
                        isFavorite.toggle()
                    }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isFavorite ? Color.storyRose : Color.storyInk.opacity(0.58))
                        .frame(width: 38, height: 38)
                        .background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }

            Text(entry.title)
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .fixedSize(horizontal: false, vertical: true)

            if let location = entry.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.storyInk.opacity(0.64))
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    private var photoStory: some View {
        Group {
            if let firstImageName = entry.imageNames.first {
                Button {
                    selectedImageName = firstImageName
                } label: {
                    Image(firstImageName)
                        .resizable()
                        .aspectRatio(momentImageAspectRatio(for: firstImageName), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.46), in: Circle())
                                .padding(10)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func momentImageAspectRatio(for imageName: String) -> CGFloat {
        guard let image = UIImage(named: imageName), image.size.height > 0 else {
            return 1
        }

        return image.size.width / image.size.height
    }

    private var journalPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Story", systemImage: "text.quote")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.homeAccent)

                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyGold)
            }

            Text(entryDisplayBody)
                .lineSpacing(7)
                .foregroundStyle(Color.storyInk.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(Color.homeBorder)
                .frame(height: 1)

            Text(entry.reflection)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .italic()
                .lineSpacing(5)
                .foregroundStyle(Color.storyInk.opacity(0.67))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background {
            ZStack {
                Color.white

                VStack(spacing: 27) {
                    ForEach(0..<12, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.homeAccent.opacity(0.06))
                            .frame(height: 1)
                    }
                }
                .padding(.top, 28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    private var entryDisplayBody: AttributedString {
        let richText = entry.richText?.normalized(for: entry.body) ?? NotebookRichTextDocument(text: entry.body)
        return AttributedString(richText.attributedString(textStyle: .default))
    }

    private var entryDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Story details")
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            HStack(spacing: 10) {
                DetailPill(systemName: "clock", text: entry.time, color: Color.homeAccent)

                if let location = entry.location {
                    DetailPill(systemName: "location", text: location, color: Color.homeAccent)
                }
            }
        }
    }

    private var referencePhotosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(Color.storyInk.opacity(0.86))
                    .rotationEffect(.degrees(-18))
                    .frame(width: 24, height: 24)

                Text("Reference photos")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 7) {
                    ForEach(Array(visibleReferencePhotoNames.enumerated()), id: \.element) { index, imageName in
                        Button {
                            selectedImageName = imageName
                        } label: {
                            referencePhotoThumbnail(imageName: imageName)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open reference photo \(index + 1) of \(visibleReferencePhotoNames.count)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func referencePhotoThumbnail(imageName: String) -> some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            }
    }

    private var visibleReferencePhotoNames: [String] {
        let count = min(max(entry.imageNames.count, 1), 5)
        return Array(referencePhotoNames.prefix(count))
    }

    private var referencePhotoNames: [String] {
        [
            "IMG_2214",
            "IMG_2382 2",
            "IMG_2385 2",
            "IMG_2390",
            "IMG_9080",
            "IMG_9102",
            "IMG_9113",
            "IMG_9114",
            "IMG_9126",
            "IMG_9127",
            "IMG_9131",
            "IMG_9140",
            "IMG_9144"
        ]
    }
}

private struct DetailPill: View {
    let systemName: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.storyInk.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(color.opacity(0.1), in: Capsule())
    }
}

private struct PhotoViewer: View {
    let imageName: String
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.storyInk
                    .ignoresSafeArea()

                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 8)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(accentColor.opacity(0.9), in: Circle())
                    }
                }
            }
            .toolbarBackground(Color.storyInk, for: .navigationBar)
        }
    }
}

private struct PrototypeEntryRow: View {
    let entry: PrototypeEntry
    let accentColor: Color
    var showsDate = true
    var thumbnailSize: CGFloat = 58
    var leadingCoverImageName: String?
    var inlineLeadingCoverImageName: String?
    var trailingCoverImageName: String?
    var showsReferencePhotos = true
    var isCompact = false
    var showsBodyPreview = true
    @State private var rowHeight: CGFloat = 0
    @State private var rowContentHeight: CGFloat = 0

    private var leadingCoverWidth: CGFloat {
        guard let leadingCoverImageName, rowHeight > 0 else {
            return 0
        }

        return rowHeight * coverAspectRatio(for: leadingCoverImageName)
    }

    var body: some View {
        rowContent
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PrototypeEntryRowHeightPreferenceKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(PrototypeEntryRowHeightPreferenceKey.self) { height in
                rowHeight = height
            }
            .overlay(alignment: .leading) {
                if let leadingCoverImageName {
                    entryCoverPanel(imageName: leadingCoverImageName)
                }
            }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsDate {
                VStack(spacing: 2) {
                    Text(entry.weekday)
                        .font(.system(size: isCompact ? 8 : 9, weight: .bold))
                        .foregroundStyle(Color.storyGray)

                    Text(entry.day)
                        .font(.system(size: isCompact ? 17 : 20, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                }
                .frame(width: isCompact ? 30 : 38)
                .padding(.top, 2)
            }

            if let inlineLeadingCoverImageName {
                inlineCoverPanel(imageName: inlineLeadingCoverImageName)
            }

            VStack(alignment: .leading, spacing: isCompact ? 3 : 5) {
                Text(entry.title)
                    .font(.system(size: isCompact ? 12 : 16, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(isCompact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)

                if showsBodyPreview {
                    Text(entry.body)
                        .font(.system(size: isCompact ? 13 : 13, weight: .medium))
                        .lineSpacing(isCompact ? 1 : 2)
                        .foregroundStyle(Color.storyInk.opacity(0.74))
                        .lineLimit(isCompact ? 1 : 2)
                }

                HStack(spacing: 4) {
                    Text(entry.time)
                    if let location = entry.location {
                        Text("•")
                        Text(location)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: isCompact ? 11 : 11, weight: .semibold))
                .foregroundStyle(accentColor)

                if showsReferencePhotos, !entry.imageNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 7) {
                            ForEach(Array(entry.imageNames.enumerated()), id: \.offset) { index, imageName in
                                Image(imageName)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: thumbnailSize, height: thumbnailSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                                    }
                                    .accessibilityLabel("Story image \(index + 1) of \(entry.imageNames.count)")
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PrototypeEntryRowContentHeightPreferenceKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(PrototypeEntryRowContentHeightPreferenceKey.self) { height in
                rowContentHeight = height
            }

            Spacer(minLength: 0)

            if let trailingCoverImageName {
                inlineCoverPanel(imageName: trailingCoverImageName)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: isCompact ? 10 : 11, weight: .bold))
                .foregroundStyle(Color.storyGray.opacity(0.4))
        }
        .padding(.leading, leadingCoverImageName == nil ? compactCardInset : leadingCoverWidth + 12)
        .padding(.trailing, compactCardInset)
        .padding(.vertical, isCompact ? compactCardInset : 14)
    }

    private var compactCardInset: CGFloat {
        isCompact ? 14 : 12
    }

    private func entryCoverPanel(imageName: String) -> some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: leadingCoverWidth, height: rowHeight)
            .background(Color.homeCardGray)
            .accessibilityHidden(true)
    }

    private func inlineCoverPanel(imageName: String) -> some View {
        let height = isCompact ? thumbnailSize : max(rowContentHeight, 72)
        let width = height * coverAspectRatio(for: imageName)
        let frameWidth = isCompact ? thumbnailSize : width
        let cornerRadius: CGFloat = 8

        return Image(imageName)
            .resizable()
            .aspectRatio(contentMode: isCompact ? .fill : .fit)
            .scaleEffect(isCompact ? 1.28 : 1)
            .frame(width: frameWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private func coverAspectRatio(for imageName: String) -> CGFloat {
        guard
            let image = UIImage(named: imageName),
            image.size.height > 0
        else {
            return 0.74
        }

        return image.size.width / image.size.height
    }
}

private struct PrototypeEntryRowHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PrototypeEntryRowContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PrototypeChapter: Identifiable {
    enum Kind {
        case journal
        case storyboard
    }

    let id: UUID
    let title: String
    let subtitle: String
    let color: Color
    let symbol: String
    let coverImageName: String?
    let remoteCover: JournalRemoteCover?
    let kind: Kind
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    var entries: [PrototypeEntry]

    var coverStorageKey: String {
        "journal-\(id.uuidString.lowercased())"
    }

    var imageCount: Int {
        entries.reduce(0) { $0 + $1.imageNames.count }
    }

    var entryCountText: String {
        "\(entries.count) \(entries.count == 1 ? "story" : "stories")"
    }

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        color: Color,
        symbol: String,
        coverImageName: String?,
        remoteCover: JournalRemoteCover? = nil,
        kind: Kind,
        isFavorite: Bool,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        entries: [PrototypeEntry]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.symbol = symbol
        self.coverImageName = coverImageName
        self.remoteCover = remoteCover
        self.kind = kind
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = entries
    }

    init(cloudJournal: StoryJournal) {
        self.init(
            id: cloudJournal.id,
            title: cloudJournal.title,
            subtitle: cloudJournal.subtitle ?? "Personal journal",
            color: cloudJournal.colorHex.flatMap(Color.init(hex:)) ?? Color.storyPurple,
            symbol: cloudJournal.symbol ?? "book.closed.fill",
            coverImageName: cloudJournal.coverImageName,
            remoteCover: cloudJournal.remoteCover,
            kind: cloudJournal.kind == "storyboard" ? .storyboard : .journal,
            isFavorite: cloudJournal.isFavorite,
            createdAt: cloudJournal.createdAt,
            updatedAt: cloudJournal.updatedAt,
            entries: []
        )
    }

    func copy(title: String) -> PrototypeChapter {
        PrototypeChapter(
            id: id,
            title: title,
            subtitle: subtitle,
            color: color,
            symbol: symbol,
            coverImageName: coverImageName,
            remoteCover: remoteCover,
            kind: kind,
            isFavorite: isFavorite,
            createdAt: createdAt,
            updatedAt: Date(),
            entries: entries
        )
    }

    static let samples: [PrototypeChapter] = [
        PrototypeChapter(
            title: "Everyday Stories",
            subtitle: "Small moments worth remembering",
            color: Color(red: 0.20, green: 0.12, blue: 0.42),
            symbol: "sparkles",
            coverImageName: nil,
            kind: .journal,
            isFavorite: true,
            entries: [
                PrototypeEntry(
                    weekday: "TUE",
                    day: "16",
                    title: "A slow morning in Williamsburg",
                    body: "Coffee, a window seat, and nowhere I needed to be for an hour.",
                    time: "9:12 AM",
                    location: "Brooklyn, NY",
                    imageNames: journalSampleImages(startIndex: 0, count: 2)
                ),
                PrototypeEntry(
                    weekday: "SUN",
                    day: "14",
                    title: "Sunday dinner",
                    body: "We stayed at the table long after dessert and retold the same family stories.",
                    time: "8:04 PM",
                    location: "Home",
                    imageNames: journalSampleImages(startIndex: 2, count: 2)
                ),
                PrototypeEntry(
                    weekday: "FRI",
                    day: "05",
                    title: "The first warm night",
                    body: "Everyone seemed to have the same idea: walk slowly and stay outside.",
                    time: "10:18 PM",
                    location: nil,
                    imageNames: journalSampleImages(startIndex: 4, count: 1)
                )
            ]
        ),
        PrototypeChapter(
            title: "Summer Adventures",
            subtitle: "Trips, detours, and sunlit days",
            color: Color(red: 0.05, green: 0.09, blue: 0.20),
            symbol: "sun.max.fill",
            coverImageName: nil,
            kind: .storyboard,
            isFavorite: false,
            entries: [
                PrototypeEntry(
                    weekday: "SAT",
                    day: "06",
                    title: "The road to the coast",
                    body: "A playlist, an overpacked car, and four stops we never planned to make.",
                    time: "6:42 PM",
                    location: "Montauk, NY",
                    imageNames: journalSampleImages(startIndex: 5, count: 2)
                ),
                PrototypeEntry(
                    weekday: "MON",
                    day: "01",
                    title: "Boardwalk at sunset",
                    body: "The sky turned peach just as the lights came on.",
                    time: "7:31 PM",
                    location: "Asbury Park, NJ",
                    imageNames: journalSampleImages(startIndex: 7, count: 2)
                )
            ]
        ),
        PrototypeChapter(
            title: "Dream Log",
            subtitle: "Scenes from the edge of sleep",
            color: Color(red: 0.31, green: 0.14, blue: 0.56),
            symbol: "moon.stars.fill",
            coverImageName: nil,
            kind: .journal,
            isFavorite: true,
            entries: [
                PrototypeEntry(
                    weekday: "WED",
                    day: "27",
                    title: "The library under the ocean",
                    body: "Every book was sealed in glass, but I could still hear the pages turning.",
                    time: "6:18 AM",
                    location: nil,
                    imageNames: journalSampleImages(startIndex: 9, count: 2)
                )
            ]
        ),
        PrototypeChapter(
            title: "People & Places",
            subtitle: "Portraits of a changing city",
            color: Color(red: 0.08, green: 0.18, blue: 0.36),
            symbol: "building.2.fill",
            coverImageName: nil,
            kind: .storyboard,
            isFavorite: false,
            entries: [
                PrototypeEntry(
                    weekday: "THU",
                    day: "21",
                    title: "Notes from the train",
                    body: "A collection of overheard sentences and passing neighborhoods.",
                    time: "5:26 PM",
                    location: "New York, NY",
                    imageNames: journalSampleImages(startIndex: 11, count: 2)
                ),
                PrototypeEntry(
                    weekday: "TUE",
                    day: "12",
                    title: "The corner flower stand",
                    body: "He remembered everyone's favorite color.",
                    time: "11:03 AM",
                    location: "Chelsea",
                    imageNames: journalSampleImages(startIndex: 0, count: 3)
                )
            ]
        )
    ]
}

enum UserChapterStore {
    private struct Record: Codable, Equatable {
        let id: UUID?
        let title: String
        let subtitle: String
        let symbol: String
        let kind: String
        let colorHex: String?
        let coverImageName: String?
        let remoteCover: JournalRemoteCover?
        let createdAt: Date?
        let updatedAt: Date?
    }

    private static let storageKey = "JournaltopiaUserChapters"
    private static var orderSyncTask: Task<Void, Never>?

    static func load() -> [PrototypeChapter] {
        return records.map { record in
            PrototypeChapter(
                id: record.id ?? stableID(for: record.title, occurrence: 0),
                title: record.title,
                subtitle: record.subtitle,
                color: color(for: record),
                symbol: record.symbol,
                coverImageName: record.coverImageName,
                remoteCover: record.remoteCover,
                kind: record.kind == "storyboard" ? .storyboard : .journal,
                isFavorite: false,
                createdAt: record.createdAt ?? Date(),
                updatedAt: record.updatedAt ?? record.createdAt ?? Date(),
                entries: []
            )
        }
    }

    static func add(_ chapter: PrototypeChapter) {
        let existingRecords: [Record]
        if
            let data = UserDefaults.standard.data(forKey: scopedStorageKey),
            let decodedRecords = try? JSONDecoder().decode([Record].self, from: data)
        {
            existingRecords = decodedRecords
        } else {
            existingRecords = []
        }

        guard !existingRecords.contains(where: { $0.title == chapter.title }) else {
            return
        }

        let newRecord = Record(
            id: chapter.id,
            title: chapter.title,
            subtitle: chapter.subtitle,
            symbol: chapter.symbol,
            kind: chapter.kind == .storyboard ? "storyboard" : "journal",
            colorHex: colorHex(for: chapter),
            coverImageName: chapter.coverImageName,
            remoteCover: chapter.remoteCover,
            createdAt: chapter.createdAt,
            updatedAt: Date()
        )

        guard let data = try? JSONEncoder().encode([newRecord] + existingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
        syncCreatedJournalToCloud(chapter, orderedChapters: load())
    }

    static func contains(title: String) -> Bool {
        records.contains { $0.title == title }
    }

    static func rename(title oldTitle: String, to newTitle: String) {
        let updatedRecords = records.map { record in
            guard record.title == oldTitle else {
                return record
            }

            return Record(
                id: record.id ?? stableID(for: oldTitle, occurrence: 0),
                title: newTitle,
                subtitle: record.subtitle,
                symbol: record.symbol,
                kind: record.kind,
                colorHex: record.colorHex,
                coverImageName: record.coverImageName,
                remoteCover: record.remoteCover,
                createdAt: record.createdAt,
                updatedAt: Date()
            )
        }

        guard let data = try? JSONEncoder().encode(updatedRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
    }

    static func replace(with chapters: [PrototypeChapter]) {
        let updatedRecords = chapters.map { chapter in
            return Record(
                id: chapter.id,
                title: chapter.title,
                subtitle: chapter.subtitle,
                symbol: chapter.symbol,
                kind: chapter.kind == .storyboard ? "storyboard" : "journal",
                colorHex: colorHex(for: chapter),
                coverImageName: chapter.coverImageName,
                remoteCover: chapter.remoteCover,
                createdAt: chapter.createdAt,
                updatedAt: chapter.updatedAt
            )
        }

        guard let data = try? JSONEncoder().encode(updatedRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
    }

    static func delete(title: String) {
        let remainingRecords = records.filter { $0.title != title }
        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
    }

    static func touch(title: String) {
        let now = Date()
        let updatedRecords = records.map { record in
            guard record.title == title else {
                return record
            }

            return Record(
                id: record.id,
                title: record.title,
                subtitle: record.subtitle,
                symbol: record.symbol,
                kind: record.kind,
                colorHex: record.colorHex,
                coverImageName: record.coverImageName,
                remoteCover: record.remoteCover,
                createdAt: record.createdAt,
                updatedAt: now
            )
        }

        guard let data = try? JSONEncoder().encode(updatedRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
    }

    static func id(for title: String) -> UUID? {
        records.first { $0.title == title }?.id
    }

    static func updateAppearance(
        id: UUID,
        color: Color,
        coverImageName: String?,
        remoteCover: JournalRemoteCover?
    ) {
        let updatedRecords = records.map { record in
            guard (record.id ?? stableID(for: record.title, occurrence: 0)) == id else {
                return record
            }

            return Record(
                id: record.id ?? id,
                title: record.title,
                subtitle: record.subtitle,
                symbol: record.symbol,
                kind: record.kind,
                colorHex: colorHex(for: color),
                coverImageName: coverImageName,
                remoteCover: remoteCover,
                createdAt: record.createdAt,
                updatedAt: Date()
            )
        }

        guard let data = try? JSONEncoder().encode(updatedRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: scopedStorageKey)
    }

    static func syncToCloud(_ chapter: PrototypeChapter, preservesDisplayOrder: Bool = true) {
        guard contains(title: chapter.title) else {
            return
        }

        Task {
            try? await SupabaseJournalRepository().upsertJournal(
                id: chapter.id,
                title: chapter.title,
                subtitle: chapter.subtitle,
                colorHex: colorHex(for: chapter),
                symbol: chapter.symbol,
                coverImageName: chapter.coverImageName,
                remoteCover: chapter.remoteCover,
                kind: chapter.kind == .storyboard ? "storyboard" : "journal",
                isFavorite: chapter.isFavorite,
                displayOrder: preservesDisplayOrder ? nil : displayOrder(for: chapter.title)
            )
            syncEntriesToCloud(chapter.entries, journalID: chapter.id)
        }
    }

    private static func syncCreatedJournalToCloud(_ chapter: PrototypeChapter, orderedChapters: [PrototypeChapter]) {
        guard contains(title: chapter.title) else {
            return
        }

        let orderedJournalIDs = orderedChapters
            .filter { contains(title: $0.title) }
            .map(\.id)

        Task {
            do {
                let repository = SupabaseJournalRepository()
                try await repository.upsertJournal(
                    id: chapter.id,
                    title: chapter.title,
                    subtitle: chapter.subtitle,
                    colorHex: colorHex(for: chapter),
                    symbol: chapter.symbol,
                    coverImageName: chapter.coverImageName,
                    remoteCover: chapter.remoteCover,
                    kind: chapter.kind == .storyboard ? "storyboard" : "journal",
                    isFavorite: chapter.isFavorite,
                    displayOrder: displayOrder(for: chapter.title)
                )
                syncEntriesToCloud(chapter.entries, journalID: chapter.id)
                try await repository.updateJournalDisplayOrder(orderedJournalIDs)
            } catch {
                print("[Journaltopia] Could not sync created journal order to cloud: \(error.localizedDescription)")
            }
        }
    }

    static func syncCoverCustomizationToCloud(
        _ chapter: PrototypeChapter,
        storedCoverImage: UIImage?,
        requiresStoredCoverUpload: Bool = false,
        clearsStoredCover: Bool
    ) async throws {
        let repository = SupabaseJournalRepository()
        try await repository.upsertJournal(
            id: chapter.id,
            title: chapter.title,
            subtitle: chapter.subtitle,
            colorHex: colorHex(for: chapter),
            symbol: chapter.symbol,
            coverImageName: chapter.coverImageName,
            remoteCover: chapter.remoteCover,
            kind: chapter.kind == .storyboard ? "storyboard" : "journal",
            isFavorite: chapter.isFavorite,
            displayOrder: nil
        )

        if let storedCoverImage {
            print("[Journaltopia] Journal cover upload started for \(chapter.id).")
            let uploadedJournal = try await repository.uploadCover(storedCoverImage, journalID: chapter.id)
            if let coverStoragePath = uploadedJournal.coverStoragePath?.trimmedOrNil {
                JournalCoverStore.recordCloudStoragePath(
                    coverStoragePath,
                    updatedAt: uploadedJournal.updatedAt,
                    for: chapter.id
                )
                print("[Journaltopia] Journal cover upload stored path \(coverStoragePath) for \(chapter.id).")
            } else {
                print("[Journaltopia] Journal cover upload returned no storage path for \(chapter.id).")
            }
        } else if requiresStoredCoverUpload {
            throw StoryJournalRepositoryError.invalidCover
        } else if clearsStoredCover {
            try await repository.clearCover(journalID: chapter.id)
            JournalCoverStore.clearCloudStoragePath(for: chapter.id)
            print("[Journaltopia] Journal cover cleared in cloud for \(chapter.id).")
        } else {
            JournalCoverStore.clearCloudStoragePath(for: chapter.id)
        }
    }

    static func syncAllToCloud(_ chapters: [PrototypeChapter]) {
        chapters
            .filter { contains(title: $0.title) }
            .forEach { syncToCloud($0) }
    }

    static func syncOrderToCloud(_ chapters: [PrototypeChapter]) {
        let orderedJournalIDs = chapters
            .filter { contains(title: $0.title) }
            .map(\.id)

        orderSyncTask?.cancel()
        orderSyncTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else {
                    return
                }
                try await SupabaseJournalRepository().updateJournalDisplayOrder(orderedJournalIDs)
            } catch is CancellationError {
                return
            } catch {
                print("[Journaltopia] Could not sync journal order to cloud: \(error.localizedDescription)")
            }
        }
    }

    static func deleteFromCloud(_ chapter: PrototypeChapter) {
        Task {
            try? await SupabaseJournalRepository().deleteJournal(id: chapter.id)
        }
    }

    static func uploadCoverToCloud(_ image: UIImage, journalID: UUID) {
        Task {
            try? await SupabaseJournalRepository().uploadCover(image, journalID: journalID)
        }
    }

    static func clearCoverInCloud(journalID: UUID) {
        Task {
            try? await SupabaseJournalRepository().clearCover(journalID: journalID)
        }
    }

    static func syncEntriesToCloud(_ entries: [PrototypeEntry], journalID: UUID) {
        Task {
            try? await SupabaseJournalRepository().replaceJournalEntries(
                journalID: journalID,
                clientEntryIDs: entries.map(\.id)
            )
        }
    }

    static func syncJournalAndEntriesToCloud(title: String) async {
        guard let chapter = load().first(where: { $0.title == title }) else {
            return
        }

        do {
            try await SupabaseJournalRepository().upsertJournal(
                id: chapter.id,
                title: chapter.title,
                subtitle: chapter.subtitle,
                colorHex: colorHex(for: chapter),
                symbol: chapter.symbol,
                coverImageName: chapter.coverImageName,
                remoteCover: chapter.remoteCover,
                kind: chapter.kind == .storyboard ? "storyboard" : "journal",
                isFavorite: chapter.isFavorite,
                displayOrder: nil
            )

            try await SupabaseJournalRepository().replaceJournalEntries(
                journalID: chapter.id,
                clientEntryIDs: StoryEntryStore.clientEntryIDs(for: chapter.title)
            )
        } catch {
            print("[Journaltopia] Could not sync journal entries to cloud for \(title).")
        }
    }

    private static var records: [Record] {
        loadMigratedRecords()
    }

    private static func record(for chapter: PrototypeChapter) -> Record? {
        records.first {
            if let id = $0.id, id == chapter.id {
                return true
            }

            return $0.title == chapter.title
        }
    }

    private static func loadMigratedRecords() -> [Record] {
        guard
            let data = UserDefaults.standard.data(forKey: scopedStorageKey),
            let decodedRecords = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }

        let migratedRecords = migrateRecords(decodedRecords)
        if migratedRecords != decodedRecords,
           let data = try? JSONEncoder().encode(migratedRecords) {
            UserDefaults.standard.set(data, forKey: scopedStorageKey)
        }

        return migratedRecords
    }

    private static var scopedStorageKey: String {
        migrateLegacyRecordsIfNeeded()
        return JournaltopiaLocalAccountScope.scopedUserDefaultsKey(storageKey)
    }

    private static func migrateLegacyRecordsIfNeeded() {
        guard !JournaltopiaLocalAccountScope.isAnonymous else {
            return
        }

        let targetKey = JournaltopiaLocalAccountScope.scopedUserDefaultsKey(storageKey)
        guard UserDefaults.standard.data(forKey: targetKey) == nil,
              let legacyData = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        UserDefaults.standard.set(legacyData, forKey: targetKey)
    }

    private static func migrateRecords(_ records: [Record]) -> [Record] {
        var seenTitles = Set<String>()
        var seenIDs = Set<UUID>()

        return records.enumerated().compactMap { index, record in
            guard seenTitles.insert(record.title).inserted else {
                return nil
            }

            var recordID = record.id ?? stableID(for: record.title, occurrence: index)
            while !seenIDs.insert(recordID).inserted {
                recordID = stableID(for: record.title, occurrence: index + seenIDs.count + 1)
            }

            return Record(
                id: recordID,
                title: record.title,
                subtitle: record.subtitle,
                symbol: record.symbol,
                kind: record.kind,
                colorHex: record.colorHex,
                coverImageName: record.coverImageName,
                remoteCover: record.remoteCover,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt ?? record.createdAt ?? Date()
            )
        }
    }

    private static func color(for record: Record) -> Color {
        if let colorHex = record.colorHex {
            return Color(hex: colorHex) ?? color(for: record.symbol)
        }

        return color(for: record.symbol)
    }

    private static func color(for symbol: String) -> Color {
        switch symbol {
        case "sun.max.fill":
            return Color(red: 0.05, green: 0.09, blue: 0.20)
        case "moon.stars.fill":
            return Color(red: 0.31, green: 0.14, blue: 0.56)
        case "building.2.fill":
            return Color(red: 0.08, green: 0.18, blue: 0.36)
        case "heart.fill":
            return Color(red: 0.36, green: 0.05, blue: 0.18)
        case "leaf.fill":
            return Color(red: 0.06, green: 0.22, blue: 0.17)
        default:
            return Color(red: 0.20, green: 0.12, blue: 0.42)
        }
    }

    private static func colorHex(for chapter: PrototypeChapter) -> String {
        colorHex(for: chapter.color)
    }

    fileprivate static func colorHex(for color: Color) -> String {
        UIColor(color).journaltopiaHexString ?? "#3D2678"
    }

    private static func displayOrder(for title: String) -> Int {
        records.firstIndex { $0.title == title } ?? 0
    }

    private static func stableID(for title: String, occurrence: Int) -> UUID {
        let namespace = "JournaltopiaJournal:\(title):\(occurrence)"
        let uuidBytes = Array(namespace.utf8).reduce(into: [UInt8](repeating: 0, count: 16)) { bytes, byte in
            let index = Int(byte) % bytes.count
            bytes[index] = bytes[index] &+ byte
        }
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

private enum DeletedSampleChapterStore {
    private static let storageKey = "JournaltopiaDeletedSampleChapters"

    static func contains(title: String) -> Bool {
        titles.contains(title)
    }

    static func add(title: String) {
        var updatedTitles = titles
        updatedTitles.insert(title)
        UserDefaults.standard.set(Array(updatedTitles), forKey: storageKey)
    }

    private static var titles: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }
}

private enum DeletedSampleEntryStore {
    private static let storageKey = "JournaltopiaDeletedSampleEntries"

    static func contains(_ entry: PrototypeEntry, in chapterTitle: String) -> Bool {
        keys.contains(key(for: entry, in: chapterTitle))
    }

    static func add(_ entry: PrototypeEntry, in chapterTitle: String) {
        var updatedKeys = keys
        updatedKeys.insert(key(for: entry, in: chapterTitle))
        UserDefaults.standard.set(Array(updatedKeys), forKey: storageKey)
    }

    private static func key(for entry: PrototypeEntry, in chapterTitle: String) -> String {
        [
            chapterTitle,
            entry.weekday,
            entry.day,
            entry.title,
            entry.body,
            entry.time,
            entry.location ?? ""
        ].joined(separator: "\u{1F}")
    }

    private static var keys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum StoryEntryStore {
    private struct Record: Codable {
        let id: UUID?
        let chapterTitle: String
        let weekday: String
        let day: String
        let title: String
        let body: String
        let richText: NotebookRichTextDocument?
        let time: String
        let location: String?

        func matches(_ entry: PrototypeEntry) -> Bool {
            if id == entry.id {
                return true
            }

            return id == nil
                && matchesContent(of: entry)
        }

        func matchesContent(of entry: PrototypeEntry) -> Bool {
            weekday == entry.weekday
                && day == entry.day
                && title == entry.title
                && body == entry.body
                && time == entry.time
                && location == entry.location
        }

        init(
            id: UUID?,
            chapterTitle: String,
            weekday: String,
            day: String,
            title: String,
            body: String,
            richText: NotebookRichTextDocument?,
            time: String,
            location: String?
        ) {
            self.id = id
            self.chapterTitle = chapterTitle
            self.weekday = weekday
            self.day = day
            self.title = title
            self.body = body
            self.richText = richText
            self.time = time
            self.location = location
        }

        init(cloudEntry entry: JournalEntryDigest, chapterTitle: String) {
            let displayDate = entry.entryDate ?? entry.createdAt
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.dateFormat = "EEE"

            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "d"

            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short

            self.init(
                id: entry.clientEntryID,
                chapterTitle: chapterTitle,
                weekday: weekdayFormatter.string(from: displayDate).uppercased(),
                day: dayFormatter.string(from: displayDate),
                title: entry.title?.trimmedOrNil ?? "Untitled Entry",
                body: entry.content ?? "",
                richText: entry.richText ?? entry.content.map { NotebookRichTextDocument(text: $0) },
                time: timeFormatter.string(from: displayDate),
                location: entry.location?.trimmedOrNil
            )
        }
    }

    private static let storageKey = "JournaltopiaChapterStories"

    static func load(for chapterTitle: String) -> [PrototypeEntry] {
        records
            .filter { $0.chapterTitle == chapterTitle }
            .map { record in
                PrototypeEntry(
                    id: record.id ?? UUID(),
                    weekday: record.weekday,
                    day: record.day,
                    title: record.title,
                    body: record.body,
                    richText: record.richText,
                    time: record.time,
                    location: record.location,
                    imageNames: []
                )
            }
    }

    static func journalTitles(containing entry: PrototypeEntry) -> Set<String> {
        Set(records.filter { $0.id == entry.id || $0.matchesContent(of: entry) }.map(\.chapterTitle))
    }

    static func clientEntryIDs(for chapterTitle: String) -> [UUID] {
        records
            .filter { $0.chapterTitle == chapterTitle }
            .compactMap(\.id)
    }

    static func clientEntryIDPositions(for chapterTitle: String) -> [UUID: Int] {
        var positions: [UUID: Int] = [:]
        for (offset, id) in clientEntryIDs(for: chapterTitle).enumerated() where positions[id] == nil {
            positions[id] = offset
        }
        return positions
    }

    /// `entries` only has to cover the memberships being written; anything missing from it simply
    /// keeps no record, which is the same outcome the old full-table fetch produced for an entry it
    /// could not match.
    static func replaceCloudMemberships(
        _ memberships: [JournalEntryMembership],
        journals: [PrototypeChapter],
        entries: [JournalEntryDigest]
    ) {
        let cloudJournalTitlesByID = Dictionary(uniqueKeysWithValues: journals.map { ($0.id, $0.title) })
        let cloudJournalTitles = Set(cloudJournalTitlesByID.values)
        let entriesByClientID = Dictionary(grouping: entries, by: \.clientEntryID)
            .compactMapValues(\.first)
        let cloudRecords = memberships
            .sorted {
                if $0.journalID != $1.journalID {
                    return (cloudJournalTitlesByID[$0.journalID] ?? "") < (cloudJournalTitlesByID[$1.journalID] ?? "")
                }

                if $0.position != $1.position {
                    return $0.position < $1.position
                }

                return $0.createdAt < $1.createdAt
            }
            .compactMap { membership -> Record? in
                guard
                    let chapterTitle = cloudJournalTitlesByID[membership.journalID],
                    let entry = entriesByClientID[membership.clientEntryID]
                else {
                    return nil
                }

                return Record(cloudEntry: entry, chapterTitle: chapterTitle)
            }

        let localRecords = records.filter { !cloudJournalTitles.contains($0.chapterTitle) }
        guard let data = try? JSONEncoder().encode(cloudRecords + localRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func missingCloudMembershipRepairs(
        journals: [PrototypeChapter],
        cloudEntryIDs: Set<UUID>,
        existingMemberships: [JournalEntryMembership]
    ) -> [JournalEntryMembershipRepair] {
        let journalIDsByTitle = Dictionary(uniqueKeysWithValues: journals.map { ($0.title, $0.id) })
        let existingKeys = Set(existingMemberships.map { MembershipKey(journalID: $0.journalID, clientEntryID: $0.clientEntryID) })

        var seenKeys = existingKeys
        var positionsByJournalID = Dictionary(
            grouping: existingMemberships,
            by: \.journalID
        ).mapValues { memberships in
            (memberships.map(\.position).max() ?? -1) + 1
        }

        return records.compactMap { record in
            guard
                let clientEntryID = record.id,
                cloudEntryIDs.contains(clientEntryID),
                let journalID = journalIDsByTitle[record.chapterTitle]
            else {
                return nil
            }

            let key = MembershipKey(journalID: journalID, clientEntryID: clientEntryID)
            guard seenKeys.insert(key).inserted else {
                return nil
            }

            let position = positionsByJournalID[journalID] ?? 0
            positionsByJournalID[journalID] = position + 1
            return JournalEntryMembershipRepair(
                journalID: journalID,
                clientEntryID: clientEntryID,
                position: position
            )
        }
    }

    static func add(_ entry: PrototypeEntry, to chapterTitle: String) {
        let newRecord = Record(
            id: entry.id,
            chapterTitle: chapterTitle,
            weekday: entry.weekday,
            day: entry.day,
            title: entry.title,
            body: entry.body,
            richText: entry.richText,
            time: entry.time,
            location: entry.location
        )

        guard let data = try? JSONEncoder().encode([newRecord] + records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func upsert(_ entry: PrototypeEntry, to chapterTitle: String, syncsToCloud: Bool = true) {
        let newRecord = Record(
            id: entry.id,
            chapterTitle: chapterTitle,
            weekday: entry.weekday,
            day: entry.day,
            title: entry.title,
            body: entry.body,
            richText: entry.richText,
            time: entry.time,
            location: entry.location
        )
        var didUpdate = false
        let updatedRecords = records.map { record in
            guard record.chapterTitle == chapterTitle, record.id == entry.id else {
                return record
            }

            didUpdate = true
            return newRecord
        }
        let recordsToSave = didUpdate ? updatedRecords : [newRecord] + updatedRecords

        guard let data = try? JSONEncoder().encode(recordsToSave) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        if syncsToCloud {
            syncToCloud(chapterTitle: chapterTitle)
        }
    }

    static func delete(_ entry: PrototypeEntry, from chapterTitle: String) {
        var didDelete = false
        let remainingRecords = records.filter { record in
            guard record.chapterTitle == chapterTitle else {
                return true
            }

            if record.id == entry.id {
                didDelete = true
                return false
            }

            if record.id == nil, !didDelete, record.matches(entry) {
                didDelete = true
                return false
            }

            return true
        }

        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func delete(entryID: UUID, from chapterTitle: String) {
        var didDelete = false
        let remainingRecords = records.filter { record in
            guard record.chapterTitle == chapterTitle else {
                return true
            }

            if record.id == entryID, !didDelete {
                didDelete = true
                return false
            }

            return true
        }

        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func delete(entryID: UUID) {
        let deletedChapterTitles = Set(records.filter { $0.id == entryID }.map(\.chapterTitle))
        let remainingRecords = records.filter { $0.id != entryID }

        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        deletedChapterTitles.forEach { syncToCloud(chapterTitle: $0) }
    }

    static func delete(entryIDs: Set<UUID>, matching entry: PrototypeEntry, from chapterTitle: String) {
        var didDelete = false
        let remainingRecords = records.filter { record in
            guard record.chapterTitle == chapterTitle else {
                return true
            }

            if !didDelete, let id = record.id, entryIDs.contains(id) {
                didDelete = true
                return false
            }

            if !didDelete, record.matchesContent(of: entry) {
                didDelete = true
                return false
            }

            return true
        }

        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func deleteFirstMatchingContent(_ entry: PrototypeEntry, from chapterTitle: String) {
        var didDelete = false
        let remainingRecords = records.filter { record in
            guard record.chapterTitle == chapterTitle else {
                return true
            }

            if !didDelete, record.matchesContent(of: entry) {
                didDelete = true
                return false
            }

            return true
        }

        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func saveStoredOrder(from entries: [PrototypeEntry], for chapterTitle: String) {
        let allRecords = records
        let chapterRecords = allRecords.filter { $0.chapterTitle == chapterTitle }
        guard !chapterRecords.isEmpty else {
            return
        }

        var remainingChapterRecords = chapterRecords
        let reorderedChapterRecords = entries.compactMap { entry -> Record? in
            guard let recordIndex = remainingChapterRecords.firstIndex(where: { $0.matches(entry) }) else {
                return nil
            }

            return remainingChapterRecords.remove(at: recordIndex)
        } + remainingChapterRecords

        let otherRecords = allRecords.filter { $0.chapterTitle != chapterTitle }
        guard let data = try? JSONEncoder().encode(reorderedChapterRecords + otherRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func saveStoredOrder(
        clientEntryIDs: [UUID],
        for chapterTitle: String,
        syncsToCloud: Bool = true
    ) {
        let allRecords = records
        let chapterRecords = allRecords.filter { $0.chapterTitle == chapterTitle }
        guard !chapterRecords.isEmpty else {
            return
        }

        var remainingChapterRecords = chapterRecords
        let reorderedChapterRecords = clientEntryIDs.compactMap { clientEntryID -> Record? in
            guard let recordIndex = remainingChapterRecords.firstIndex(where: { $0.id == clientEntryID }) else {
                return nil
            }

            return remainingChapterRecords.remove(at: recordIndex)
        } + remainingChapterRecords

        let otherRecords = allRecords.filter { $0.chapterTitle != chapterTitle }
        guard let data = try? JSONEncoder().encode(reorderedChapterRecords + otherRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        if syncsToCloud {
            syncToCloud(chapterTitle: chapterTitle)
        }
    }

    static func deleteAll(for chapterTitle: String) {
        let remainingRecords = records.filter { $0.chapterTitle != chapterTitle }
        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: chapterTitle)
    }

    static func renameChapter(from oldTitle: String, to newTitle: String) {
        let updatedRecords = records.map { record in
            guard record.chapterTitle == oldTitle else {
                return record
            }

            return Record(
                id: record.id,
                chapterTitle: newTitle,
                weekday: record.weekday,
                day: record.day,
                title: record.title,
                body: record.body,
                richText: record.richText,
                time: record.time,
                location: record.location
            )
        }

        guard let data = try? JSONEncoder().encode(updatedRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapterTitle: oldTitle)
        syncToCloud(chapterTitle: newTitle)
    }

    private static var records: [Record] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let records = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }

        return records
    }

    private static func syncToCloud(chapterTitle: String) {
        guard let journalID = UserChapterStore.id(for: chapterTitle) else {
            return
        }

        UserChapterStore.touch(title: chapterTitle)

        let clientEntryIDs = records
            .filter { $0.chapterTitle == chapterTitle }
            .compactMap(\.id)

        UserChapterStore.syncEntriesToCloud(
            clientEntryIDs.map {
                PrototypeEntry(
                    id: $0,
                    weekday: "",
                    day: "",
                    title: "",
                    body: "",
                    time: "",
                    location: nil,
                    imageNames: []
                )
            },
            journalID: journalID
        )
    }

    private struct MembershipKey: Hashable {
        let journalID: UUID
        let clientEntryID: UUID
    }
}

struct PrototypeEntry: Identifiable {
    let id: UUID
    let weekday: String
    let day: String
    let title: String
    let body: String
    let richText: NotebookRichTextDocument?
    let time: String
    let location: String?
    let imageNames: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        weekday: String,
        day: String,
        title: String,
        body: String,
        richText: NotebookRichTextDocument? = nil,
        time: String,
        location: String?,
        imageNames: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.weekday = weekday
        self.day = day
        self.title = title
        self.body = body
        self.richText = richText?.normalized(for: body)
        self.time = time
        self.location = location
        self.imageNames = imageNames
        self.createdAt = createdAt
    }

    func copy(imageNames: [String]) -> PrototypeEntry {
        PrototypeEntry(
            id: id,
            weekday: weekday,
            day: day,
            title: title,
            body: body,
            richText: richText,
            time: time,
            location: location,
            imageNames: imageNames,
            createdAt: createdAt
        )
    }

    var reflection: String {
        switch title {
        case "A slow morning in Williamsburg":
            return "I want to remember how spacious the day felt before it filled up."
        case "Sunday dinner":
            return "Some traditions survive because nobody is ready for the conversation to end."
        case "The first warm night":
            return "The whole neighborhood felt like it had been waiting at the same window."
        case "The road to the coast":
            return "The detours became the parts of the trip we quoted on the way home."
        case "Boardwalk at sunset":
            return "For a few minutes, the sky and the old neon signs seemed to agree on a color."
        case "The library under the ocean":
            return "I woke up wondering who kept reading after I left."
        case "Notes from the train":
            return "A city tells on itself in the half-sentences people leave behind."
        case "The corner flower stand":
            return "Being remembered in a small way can change the shape of an ordinary morning."
        default:
            return "A small moment, kept here before it could slip away."
        }
    }
}

private extension PrototypeEntry {
    init(cloudEntry entry: JournalEntry) {
        let displayDate = entry.entryDate ?? entry.createdAt
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d"

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        self.init(
            id: entry.clientEntryID,
            weekday: weekdayFormatter.string(from: displayDate).uppercased(),
            day: dayFormatter.string(from: displayDate),
            title: entry.title?.trimmedOrNil ?? "Untitled Entry",
            body: entry.content ?? "",
            richText: entry.richText ?? entry.content.map { NotebookRichTextDocument(text: $0) },
            time: timeFormatter.string(from: displayDate),
            location: entry.location?.trimmedOrNil,
            imageNames: []
        )
    }
}
