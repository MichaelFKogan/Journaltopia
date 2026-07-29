import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct JournalView: View {
    @Binding var selectedPage: StoryPage
    @Binding var isDraftSaved: Bool
    @Binding var activeDraftID: UUID?
    @Binding var completedEntryOpenedStoryboardImage: UIImage?
    @Binding var isOpeningEntryFromEntries: Bool
    @Binding var isOpeningCompletedEntryFromEntries: Bool
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    @EnvironmentObject private var authStore: SupabaseAuthStore

    @State private var showsPrototypeData = false
    @State private var chapters: [PrototypeChapter]
    @State private var editMode: EditMode = .inactive
    @State private var journalBeingRenamed: PrototypeChapter?
    @State private var renamedJournalTitle = ""
    @State private var journalsPendingDeletion: [PrototypeChapter] = []
    @State private var journalBeingCustomized: PrototypeChapter?
    @State private var isCreateJournalAlertPresented = false
    @State private var isCreateOptionsSheetPresented = false
    @State private var newJournalTitle = ""
    @State private var openingJournal: JournalOpeningContext?
    @State private var isJournalOpening = false
    @State private var journalNavigationPath: [JournalRoute] = []
    @State private var areJournalPagesExpanded = false
    @State private var isJournalDetailVisible = false
    @State private var draggingJournalID: UUID?
    @Namespace private var journalOpenNamespace
    @AppStorage("StorytopiaSelectedJournalLayout") private var selectedJournalLayoutRawValue = JournalDisplayLayout.grid3x3.rawValue
    @AppStorage("StorytopiaSelectedJournalSort") private var selectedJournalSortRawValue = JournalSortOption.manual.rawValue

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

    private var selectedJournalSort: JournalSortOption {
        get {
            JournalSortOption(rawValue: selectedJournalSortRawValue) ?? .manual
        }
        nonmutating set {
            selectedJournalSortRawValue = newValue.rawValue
        }
    }

    private var sortedChapters: [PrototypeChapter] {
        let systemChapters = PrototypeChapter.SystemJournal.orderedCases.compactMap { systemJournal in
            chapters.first { $0.systemJournal == systemJournal }
        }
        let userChapters = chapters.filter { !$0.isSystemJournal }

        if selectedJournalSort == .manual {
            return systemChapters + userChapters
        }

        return systemChapters + userChapters.sorted { lhs, rhs in
            switch selectedJournalSort {
            case .created:
                if lhs.createdAt == rhs.createdAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.createdAt > rhs.createdAt
            case .createdOldest:
                if lhs.createdAt == rhs.createdAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.createdAt < rhs.createdAt
            case .updated:
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            case .updatedOldest:
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt < rhs.updatedAt
            case .manual:
                return false
            }
        }
    }

    init(
        selectedPage: Binding<StoryPage>,
        isDraftSaved: Binding<Bool>,
        activeDraftID: Binding<UUID?>,
        completedEntryOpenedStoryboardImage: Binding<UIImage?> = .constant(nil),
        isOpeningEntryFromEntries: Binding<Bool> = .constant(false),
        isOpeningCompletedEntryFromEntries: Binding<Bool> = .constant(false),
        generatedStoryboards: Binding<[GeneratedStoryboard]> = .constant([])
    ) {
        _selectedPage = selectedPage
        _isDraftSaved = isDraftSaved
        _activeDraftID = activeDraftID
        _completedEntryOpenedStoryboardImage = completedEntryOpenedStoryboardImage
        _isOpeningEntryFromEntries = isOpeningEntryFromEntries
        _isOpeningCompletedEntryFromEntries = isOpeningCompletedEntryFromEntries
        _generatedStoryboards = generatedStoryboards
        _chapters = State(initialValue: DailyJournalData.allChapters())
    }

    var body: some View {
        NavigationStack(path: $journalNavigationPath) {
            ZStack(alignment: .bottom) {
                Color.homePageBackground
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 10) {
                    header
                        .padding(.horizontal, 16)

                    if selectedJournalLayout == .list {
                        chapterList
                    } else {
                        journalGridScroll
                    }
                }

                BottomNavigationBar(selectedPage: $selectedPage)

                floatingAddButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .zIndex(2)

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
                case .profile:
                    ProfileView(
                        selectedPage: $selectedPage,
                        generatedStoryboards: $generatedStoryboards,
                        embedsInNavigationStack: false
                    )
                }
            }
        }
        .onAppear {
            chapters = DailyJournalData.allChapters()
            loadCloudJournalsIfNeeded()
        }
        .onChange(of: selectedPage) { newPage in
            if newPage != .create {
                chapters = DailyJournalData.allChapters()
                loadCloudJournalsIfNeeded()
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
        .sheet(item: $journalBeingCustomized) { chapter in
            JournalCustomizationSheet(
                chapter: refreshedChapter(chapter),
                initialStoryboardCovers: storyboardCoverCandidates(for: refreshedChapter(chapter)),
                onSave: applyJournalCustomization
            )
        }
        .sheet(isPresented: $isCreateOptionsSheetPresented) {
            JournalCreateOptionsSheet(
                onNewEntry: openNewEntryFromCreateOptions,
                onNewJournal: openNewJournalFromCreateOptions
            )
            .presentationDetents([.height(304)])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.white)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                Text("My Journals")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                EditButton()
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.homeAccent)

                journalProfileButton
            }

            HStack(alignment: .center) {
                journalSortMenu

                Spacer()

                journalLayoutSwitcher
            }
        }
        .padding(.top, 12)
    }

    private var journalSortMenu: some View {
        Menu {
            ForEach(JournalSortOption.menuOptions) { option in
                Button {
                    selectedJournalSort = selectedJournalSort.selection(afterChoosing: option)
                } label: {
                    Label(option.menuTitle, systemImage: selectedJournalSort.menuSystemImage(for: option))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedJournalSort.displaySystemImage)
                    .font(.system(size: 13, weight: .bold))

                Text(selectedJournalSort.shortTitle)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.storyInk)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort journals by \(selectedJournalSort.title)")
    }

    private var journalLayoutSwitcher: some View {
        HStack(spacing: 4) {
            journalLayoutButton(.grid2x2)
            journalLayoutButton(.grid3x3)
            journalLayoutButton(.list)
        }
        .padding(4)
        .frame(height: 34)
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

    private var journalProfileButton: some View {
        Button {
            journalNavigationPath.append(.profile)
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 27, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.storyInk)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }

    private var floatingAddButton: some View {
        Button {
            isCreateOptionsSheetPresented = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 64)
                .background(Color.homeAccent, in: Circle())
                .shadow(color: Color.storyInk.opacity(0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
    }

    private var journalGridScroll: some View {
        ScrollView(showsIndicators: false) {
            journalGrid
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, showsPrototypeData ? 140 : 118)
        }
        .background(Color.homePageBackground)
    }

    private var journalGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            if sortedChapters.isEmpty {
                emptyState
                    .gridCellColumns(selectedJournalLayout.gridColumnCount)
            } else {
                ForEach(Array(sortedChapters.enumerated()), id: \.element.id) { index, chapter in
                    JournalCoverCard(
                        chapter: chapter,
                        coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter.coverStorageKey) : nil,
                        remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
                        fallbackImageName: fallbackCoverImageName(for: chapter, at: index),
                        isEditing: editMode == .active,
                        allowsEditingActions: !chapter.isSystemJournal,
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
                    .moveDisabled(chapter.isSystemJournal)
                    .modifier(JournalDragModifier(
                        chapter: chapter,
                        draggingJournalID: $draggingJournalID
                    ))
                    .onDrop(
                        of: [UTType.text],
                        delegate: JournalGridDropDelegate(
                            chapter: chapter,
                            chapters: $chapters,
                            draggingJournalID: $draggingJournalID,
                            isEnabled: selectedJournalSort == .manual && !chapter.isSystemJournal,
                            onReorder: persistManualJournalOrder
                        )
                    )
                    .allowsHitTesting(openingJournal == nil && journalNavigationPath.isEmpty)
                }
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

    private var chapterList: some View {
        List {
            Section {
                if sortedChapters.isEmpty {
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
            Color.clear.frame(height: 150)
        }
    }

    private var journalRows: some View {
        ForEach(Array(sortedChapters.enumerated()), id: \.element.id) { index, chapter in
            NavigationLink {
                dailyJournalDetail(for: chapter, dayOffset: index)
            } label: {
                JournalChapterListRow(
                    chapter: chapter,
                    coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter.coverStorageKey) : nil,
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
            .moveDisabled(chapter.isSystemJournal)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !chapter.isSystemJournal {
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
        guard !chapter.isSystemJournal else {
            return
        }
        journalBeingRenamed = chapter
        renamedJournalTitle = chapter.title
    }

    private func beginCustomizing(_ chapter: PrototypeChapter) {
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
            JournalCoverStore.save(storedCoverImage, for: chapters[index].coverStorageKey)
        } else if customization.clearsStoredCover {
            JournalCoverStore.delete(key: chapters[index].coverStorageKey)
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
            systemJournal: chapters[index].systemJournal,
            entries: chapters[index].entries
        )

        chapters[index] = updatedChapter
        if let systemJournal = updatedChapter.systemJournal {
            SystemJournalAppearanceStore.update(
                systemJournal,
                color: updatedChapter.color,
                coverImageName: updatedChapter.coverImageName,
                remoteCover: updatedChapter.remoteCover
            )
            SystemJournalAppearanceStore.syncToCloud(
                updatedChapter,
                storedCoverImage: customization.storedCoverImage
            )
        } else {
            UserChapterStore.updateAppearance(
                id: updatedChapter.id,
                color: updatedChapter.color,
                coverImageName: updatedChapter.coverImageName,
                remoteCover: updatedChapter.remoteCover
            )
            UserChapterStore.syncToCloud(updatedChapter)
            if let storedCoverImage = customization.storedCoverImage {
                UserChapterStore.uploadCoverToCloud(storedCoverImage, journalID: updatedChapter.id)
            } else if customization.clearsStoredCover {
                UserChapterStore.clearCoverInCloud(journalID: updatedChapter.id)
            }
        }
        journalBeingCustomized = nil
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

    private func openNewEntryFromCreateOptions() {
        isCreateOptionsSheetPresented = false
        selectedPage = .create
    }

    private func openNewJournalFromCreateOptions() {
        isCreateOptionsSheetPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            handleCreateButtonTapped()
        }
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
        let visibleChapters = sortedChapters
        requestDeleteJournals(offsets.compactMap { visibleChapters.indices.contains($0) ? visibleChapters[$0] : nil })
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
            return "Are you sure you want to delete \"\(journal.title)\"? This journal and its entries can't be recovered."
        }

        return "Are you sure you want to delete these journals? These journals and their entries can't be recovered."
    }

    private func requestDeleteJournals(_ journals: [PrototypeChapter]) {
        journalsPendingDeletion = journals.filter { !$0.isSystemJournal }
    }

    private func deletePendingJournals() {
        let journalsToDelete = journalsPendingDeletion
        journalsPendingDeletion = []
        journalsToDelete.forEach(deleteJournal)
    }

    private func deleteJournal(_ journal: PrototypeChapter) {
        guard !journal.isSystemJournal else {
            return
        }
        let isUserJournal = UserChapterStore.contains(title: journal.title)
        UserChapterStore.delete(title: journal.title)
        UserChapterStore.deleteFromCloud(journal)
        JournalCoverStore.delete(key: journal.coverStorageKey)
        if !isUserJournal {
            DeletedSampleChapterStore.add(title: journal.title)
        }
        StoryEntryStore.deleteAll(for: journal.title)

        chapters.removeAll { $0.id == journal.id }
    }

    private func moveChapters(from source: IndexSet, to destination: Int) {
        guard selectedJournalSort == .manual else {
            return
        }

        let systemCount = chapters.filter(\.isSystemJournal).count
        guard source.allSatisfy({ $0 >= systemCount }), destination >= systemCount else {
            return
        }

        chapters.move(fromOffsets: source, toOffset: destination)
        persistManualJournalOrder()
    }

    private func persistManualJournalOrder() {
        let userChapters = chapters.filter { !$0.isSystemJournal && UserChapterStore.contains(title: $0.title) }
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
            coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter.coverStorageKey) : nil,
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

            withAnimation(.spring(response: 1.04, dampingFraction: 0.91)) {
                areJournalPagesExpanded = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
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
            onChapterUpdated: updateChapterFromDetail,
            onOpenExistingEntry: openExistingEntryFromJournalDetail
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
        storyboardImage: UIImage?
    ) {
        isOpeningEntryFromEntries = true
        isOpeningCompletedEntryFromEntries = isCompleted
        completedEntryOpenedStoryboardImage = storyboardImage
        activeDraftID = entry.id
        selectedPage = .create
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

    private func loadCloudJournalsIfNeeded() {
        guard authStore.userID != nil else {
            return
        }

        Task {
            do {
                let journalRepository = SupabaseJournalRepository()
                let cloudJournals = try await journalRepository.getJournals()
                let cloudEntries = try await SupabaseEntryRepository().getEntries()
                let memberships = try await journalRepository.getJournalEntryMemberships()
                await Self.cacheCloudSystemJournalAppearances(cloudJournals)
                SystemJournalAppearanceStore.syncLocalAppearancesToCloudIfNeeded(existingCloudJournals: cloudJournals)
                let cloudChapters = cloudJournals
                    .filter { PrototypeChapter.SystemJournal.journal(for: $0.id) == nil }
                    .map(PrototypeChapter.init(cloudJournal:))

                await MainActor.run {
                    let mergedCloudChapters = Self.cloudChapters(
                        cloudChapters,
                        preservingOrderOf: chapters
                    )
                    UserChapterStore.replace(with: mergedCloudChapters)
                    StoryEntryStore.replaceCloudMemberships(
                        memberships,
                        journals: mergedCloudChapters,
                        entries: cloudEntries
                    )
                    chapters = DailyJournalData.allChapters(cloudEntries: cloudEntries)
                }
            } catch {
                print("[Storytopia] Cloud journals load failed: \(error.localizedDescription)")
            }
        }
    }

    private static func cloudChapters(
        _ cloudChapters: [PrototypeChapter],
        preservingOrderOf _: [PrototypeChapter]
    ) -> [PrototypeChapter] {
        cloudChapters
    }

    private static func cacheCloudSystemJournalAppearances(_ cloudJournals: [StoryJournal]) async {
        let journalRepository = SupabaseJournalRepository()

        for cloudJournal in cloudJournals {
            guard let systemJournal = PrototypeChapter.SystemJournal.journal(for: cloudJournal.id) else {
                continue
            }

            let remoteCover = cloudJournal.remoteCover
            SystemJournalAppearanceStore.update(
                systemJournal,
                color: cloudJournal.colorHex.flatMap(Color.init(hex:)) ?? systemJournal.color,
                coverImageName: cloudJournal.coverImageName,
                remoteCover: remoteCover
            )

            if remoteCover != nil {
                JournalCoverStore.delete(key: systemJournal.coverStorageKey)
            } else if let storagePath = cloudJournal.coverStoragePath,
                      let image = try? await journalRepository.downloadCover(storagePath: storagePath) {
                JournalCoverStore.save(image, for: systemJournal.coverStorageKey)
            } else {
                JournalCoverStore.delete(key: systemJournal.coverStorageKey)
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
    case profile
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

private enum JournalSortOption: String, CaseIterable, Identifiable {
    case manual
    case updated
    case updatedOldest
    case created
    case createdOldest

    static let menuOptions: [JournalSortOption] = [.manual, .updated, .created]

    var id: String {
        rawValue
    }

    var menuTitle: String {
        switch self {
        case .manual:
            return "Custom Order"
        case .updated, .updatedOldest:
            return "Edited"
        case .created, .createdOldest:
            return "Created"
        }
    }

    var title: String {
        switch self {
        case .manual:
            return "Custom Order"
        case .updated:
            return "Edited: Newest"
        case .updatedOldest:
            return "Edited: Oldest"
        case .created:
            return "Created: Newest"
        case .createdOldest:
            return "Created: Oldest"
        }
    }

    var shortTitle: String {
        switch self {
        case .manual:
            return "Custom Order"
        case .updated:
            return "Edited: Newest"
        case .updatedOldest:
            return "Edited: Oldest"
        case .created:
            return "Created: Newest"
        case .createdOldest:
            return "Created: Oldest"
        }
    }

    var displaySystemImage: String {
        switch self {
        case .manual:
            return systemImage
        case .updated, .created:
            return "arrow.down"
        case .updatedOldest, .createdOldest:
            return "arrow.up"
        }
    }

    var systemImage: String {
        switch self {
        case .manual:
            return "line.3.horizontal"
        case .updated:
            return "clock.arrow.circlepath"
        case .updatedOldest:
            return "clock"
        case .created:
            return "plus.circle"
        case .createdOldest:
            return "plus.circle"
        }
    }

    private var menuSelection: JournalSortOption {
        switch self {
        case .manual:
            return .manual
        case .updated, .updatedOldest:
            return .updated
        case .created, .createdOldest:
            return .created
        }
    }

    private var toggledDirection: JournalSortOption {
        switch self {
        case .manual:
            return .manual
        case .updated:
            return .updatedOldest
        case .updatedOldest:
            return .updated
        case .created:
            return .createdOldest
        case .createdOldest:
            return .created
        }
    }

    func selection(afterChoosing option: JournalSortOption) -> JournalSortOption {
        guard option != .manual else {
            return .manual
        }

        return menuSelection == option ? toggledDirection : option
    }

    func menuSystemImage(for option: JournalSortOption) -> String {
        guard menuSelection == option else {
            return option.systemImage
        }

        return option == .manual ? "checkmark" : displaySystemImage
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
        onReorder()
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        isEnabled ? DropProposal(operation: .move) : nil
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggingJournalID = nil
        return isEnabled
    }
}

private struct JournalDragModifier: ViewModifier {
    let chapter: PrototypeChapter
    @Binding var draggingJournalID: UUID?

    func body(content: Content) -> some View {
        if chapter.isSystemJournal {
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
        .animation(.spring(response: 1.04, dampingFraction: 0.91), value: pagesExpanded)
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

private struct JournalCoverCard: View {
    let chapter: PrototypeChapter
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?
    let isEditing: Bool
    var allowsEditingActions = true
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
                .overlay(alignment: .topLeading) {
                    if chapter.isSystemJournal {
                        SystemJournalBadge(style: .cover)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    journalTitleScrim
                }

            if isEditing && allowsEditingActions {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.red)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Delete \(chapter.title)")
            } else {
                Menu {
                    Button(action: onCustomize) {
                        Label("Change Cover", systemImage: "photo.on.rectangle")
                    }

                    if allowsEditingActions {
                        Button(action: onRename) {
                            Label("Rename", systemImage: "pencil")
                        }

                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    } else {
                        Button {} label: {
                            Label("Built-in: can't move or delete", systemImage: "shield.fill")
                        }
                        .disabled(true)
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
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.13), radius: 10, y: 5)
        .accessibilityHint(chapter.isSystemJournal ? "Built-in journals can't be moved or deleted." : "")
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

private struct JournalCustomizationSheet: View {
    let chapter: PrototypeChapter
    let initialStoryboardCovers: [JournalStoryboardCoverCandidate]
    let onSave: (JournalCustomization) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedColorHex: String
    @State private var selectedCoverImageName: String?
    @State private var selectedRemoteCover: JournalRemoteCover?
    @State private var selectedStoredCoverImage: UIImage?
    @State private var selectedStoryboardCoverID: UUID?
    @State private var storyboardCoverCandidates: [JournalStoryboardCoverCandidate]
    @State private var isLoadingStoryboardCovers = false
    @State private var clearsStoredCover = false
    @State private var unsplashQuery: String
    @State private var unsplashPhotos: [UnsplashCoverPhoto] = []
    @State private var unsplashResultsCache: [String: [UnsplashCoverPhoto]] = [:]
    @State private var isSearchingUnsplash = false
    @State private var unsplashErrorMessage: String?
    @FocusState private var isUnsplashSearchFocused: Bool
    private let unsplashService = UnsplashCoverService()

    init(
        chapter: PrototypeChapter,
        initialStoryboardCovers: [JournalStoryboardCoverCandidate] = [],
        onSave: @escaping (JournalCustomization) -> Void
    ) {
        self.chapter = chapter
        self.initialStoryboardCovers = initialStoryboardCovers
        self.onSave = onSave
        _selectedColorHex = State(initialValue: JournalColorOption.hexString(for: chapter.color))
        _selectedCoverImageName = State(initialValue: chapter.coverImageName)
        _selectedRemoteCover = State(initialValue: chapter.remoteCover)
        _selectedStoredCoverImage = State(initialValue: JournalCoverStore.image(for: chapter.coverStorageKey))
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
                    Button("Done") {
                        let remoteCover = selectedRemoteCover
                        onSave(
                            JournalCustomization(
                                chapterID: chapter.id,
                                color: selectedColor,
                                coverImageName: selectedCoverImageName,
                                remoteCover: remoteCover,
                                storedCoverImage: selectedStoredCoverImage,
                                clearsStoredCover: clearsStoredCover
                            )
                        )
                        if let downloadLocation = remoteCover?.downloadLocation {
                            Task {
                                try? await unsplashService.trackDownload(downloadLocation: downloadLocation)
                            }
                        }
                        dismiss()
                    }
                    .fontWeight(.bold)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button("Done") {
                        isUnsplashSearchFocused = false
                    }
                    .fontWeight(.bold)
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
                        selectedColorHex = option.hex
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 42, height: 42)
                            .overlay {
                                if selectedColorHex == option.hex {
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
            HStack {
                Text("Cover Photo")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Button("Use Color") {
                    selectedCoverImageName = nil
                    selectedRemoteCover = nil
                    selectedStoredCoverImage = nil
                    selectedStoryboardCoverID = nil
                    clearsStoredCover = true
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.homeAccent)
            }

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
                                && selectedRemoteCover == nil
                                && selectedCoverImageName == nil

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
                                && selectedRemoteCover == nil
                                && selectedStoryboardCoverID == nil

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
                .disabled(isSearchingUnsplash)
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
            }
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

    private func selectStoryboardCoverImage(named imageName: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedCoverImageName = imageName
            selectedRemoteCover = nil
            selectedStoredCoverImage = nil
            selectedStoryboardCoverID = nil
            clearsStoredCover = true
        }
    }

    private func selectStoryboardCover(_ candidate: JournalStoryboardCoverCandidate) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedCoverImageName = nil
            selectedRemoteCover = nil
            selectedStoredCoverImage = candidate.image
            selectedStoryboardCoverID = candidate.id
            clearsStoredCover = false
        }
    }

    private func selectUnsplashPhoto(_ photo: UnsplashCoverPhoto) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            selectedCoverImageName = nil
            selectedStoredCoverImage = nil
            selectedStoryboardCoverID = nil
            clearsStoredCover = true
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
        } catch {
            return
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

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(coverImage != nil || remoteCoverURL != nil || fallbackImageName != nil ? 0.72 : 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            journalSpine

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
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.09), radius: 8, y: 4)
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
        UIColor(color).storytopiaHexString ?? "#3D2678"
    }
}

private enum JournalCoverStore {
    private static let folderName = "JournalCovers"

    static func image(for title: String) -> UIImage? {
        guard
            let data = try? Data(contentsOf: fileURL(for: title)),
            let image = UIImage(data: data)
        else {
            return nil
        }

        return image
    }

    static func save(_ image: UIImage, for title: String) {
        guard let data = image.storytopiaPreparedJPEGData(compressionQuality: 0.86) ?? image.jpegData(compressionQuality: 0.86) else {
            return
        }

        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL(for: title), options: [.atomic])
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

    static func delete(key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func fileURL(for title: String) -> URL {
        directoryURL.appendingPathComponent(fileName(for: title))
    }

    private static func fileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return "\(sanitized.isEmpty ? "journal" : sanitized).jpg"
    }
}

private struct JournalCreateOptionsSheet: View {
    let onNewEntry: () -> Void
    let onNewJournal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tileColumns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 0)
        ]

        VStack(spacing: 0) {
            Text("What would you like to create?")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .padding(.top, 46)
                .padding(.bottom, 18)

            LazyVGrid(columns: tileColumns, spacing: 0) {
                JournalCreateOptionTile(
                    title: "New Entry",
                    subtitle: "Write and add to a journal.",
                    systemName: "square.and.pencil",
                    action: onNewEntry
                )

                JournalCreateOptionTile(
                    title: "New Journal",
                    subtitle: "Organize your stories.",
                    systemName: "books.vertical",
                    action: onNewJournal
                )
            }

            Divider()
                .padding(.top, 18)

            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.storyInk)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .background(Color.white)
    }
}

private struct JournalCreateOptionTile: View {
    let title: String
    let subtitle: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 11) {
                Image(systemName: systemName)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 50, height: 50)
                    .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.homeAccent.opacity(0.22), radius: 7, y: 4)

                VStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.storyInk)
                        .multilineTextAlignment(.center)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.storyInk.opacity(0.64))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.homePageBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.storyInk.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
                    coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter.title) : nil,
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
            return "Are you sure you want to delete \"\(journal.title)\"? This journal and its entries can't be recovered."
        }

        return "Are you sure you want to delete these journals? These journals and their entries can't be recovered."
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
        JournalCoverStore.delete(title: journal.title)
        if !isUserJournal {
            DeletedSampleChapterStore.add(title: journal.title)
        }
        StoryEntryStore.deleteAll(for: journal.title)

        chapters.removeAll { $0.id == journal.id }
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

struct DaybookView: View {
    @Binding var selectedPage: StoryPage
    var embedsInNavigationStack = true
    var showsBottomNavigation = true

    @State private var chapters = DailyJournalData.allChapters()
    @State private var selectedTab: DaybookTab = .entries
    @State private var comicPageIndex = 0
    @State private var isComicReaderPresented = false
    @State private var isShowingNewEntry = false
    @State private var selectedGalleryImageIndex: Int?
    @State private var previewHorizontalPosition: Double = 0.5
    @State private var previewZoom: Double = 1.0

    private var comicBook: DaybookComicBook {
        DaybookComicBook(chapters: chapters)
    }

    var body: some View {
        Group {
            if embedsInNavigationStack {
                NavigationStack {
                    daybookContent
                }
            } else {
                daybookContent
            }
        }
        .navigationTitle(embedsInNavigationStack ? "" : "Daily")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(embedsInNavigationStack ? .hidden : .visible, for: .navigationBar)
        .onAppear {
            chapters = DailyJournalData.allChapters()
            comicPageIndex = clampedComicPageIndex(comicPageIndex)
            clampPreviewZoom()
        }
        .onChange(of: selectedTab) { newTab in
            clampPreviewZoom()
            if newTab == .comic {
                previewHorizontalPosition = 0.5
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsComicPreviewControls)
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedGalleryImageIndex != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedGalleryImageIndex = nil
                    }
                }
            )
        ) {
            if let selectedGalleryImageIndex {
                VerticalComicViewer(
                    imageNames: comicBook.storyPages.map(\.imageName),
                    initialIndex: selectedGalleryImageIndex,
                    accentColor: Color.homeAccent
                )
            }
        }
    }

    private var daybookContent: some View {
        ZStack(alignment: .bottom) {
            Color.white
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    pageHeader
                    DaybookComicSummaryStrip(comicBook: comicBook) {
                        isComicReaderPresented = true
                    }
                    tabSwitcher

                    selectedTabContent
                }
                .padding(.top, 12)
                .padding(.bottom, scrollBottomPadding)
            }
            .modifier(DaybookScrollClipDisabledModifier())

            if showsBottomNavigation {
                VStack(spacing: 0) {
                    if showsComicPreviewControls {
                        DaybookComicPreviewControlSliders(
                            horizontalPosition: $previewHorizontalPosition,
                            zoom: $previewZoom,
                            zoomRange: comicPreviewZoomRange,
                            zoomCenterValue: comicPreviewZoomCenter
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    BottomNavigationBar(selectedPage: $selectedPage)
                }
            }
        }
        .navigationDestination(isPresented: $isShowingNewEntry) {
            NewStorySheet(
                chapterTitle: todayJournalTitle,
                accentColor: Color.homeAccent,
                initialDate: DailyJournalData.journalDate(dayOffset: 0),
                collectionLabel: "Daily Journal",
                locksEntryDate: true
            ) { entry in
                addEntryToToday(entry)
                selectedTab = .entries
            }
        }
        .navigationDestination(isPresented: $isComicReaderPresented) {
            DaybookComicReaderView(
                comicBook: comicBook,
                currentPageIndex: $comicPageIndex
            )
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("June 2026")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            Button {
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.storyInk)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose month")

            Button {
                isShowingNewEntry = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.storyInk, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create a new journal entry")
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(DaybookTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selectedTab == tab ? Color.homeAccent : Color.homeMutedText.opacity(0.78))

                        Capsule()
                            .fill(selectedTab == tab ? Color.homeAccent : Color.clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.top, 2)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .entries:
            AllJournalEntriesSection(chapters: $chapters)
        case .comic:
            DaybookComicTab(
                comicBook: comicBook,
                currentPageIndex: $comicPageIndex,
                previewHorizontalPosition: $previewHorizontalPosition,
                previewZoom: $previewZoom,
                onOpenReader: { isComicReaderPresented = true },
                onOpenGalleryImage: { imageIndex in
                    selectedGalleryImageIndex = imageIndex
                }
            )
            .padding(.horizontal, 16)
        }
    }

    private var showsComicPreviewControls: Bool {
        selectedTab == .comic && !comicBook.storyPages.isEmpty
    }

    private var scrollBottomPadding: CGFloat {
        if !showsBottomNavigation {
            return 24
        }

        return showsComicPreviewControls ? 188 : 92
    }

    private var comicPreviewZoomRange: ClosedRange<Double> {
        DaybookComicPreviewMetrics.sliderZoomRange
    }

    private var comicPreviewZoomCenter: Double {
        DaybookComicPreviewMetrics.sliderZoomCenter
    }

    private func clampPreviewZoom() {
        previewZoom = min(max(previewZoom, comicPreviewZoomRange.lowerBound), comicPreviewZoomRange.upperBound)
    }

    private func clampedComicPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, comicBook.totalPageCount - 1))
    }

    private var todayJournalTitle: String {
        guard let chapter = chapters.first else {
            return "Today"
        }

        return DailyJournalData.dateTitledChapter(from: chapter, dayOffset: 0).title
    }

    private func addEntryToToday(_ entry: PrototypeEntry) {
        guard let chapter = chapters.first else {
            return
        }

        chapters[0].entries.insert(entry, at: 0)
        StoryEntryStore.add(entry, to: chapter.title)
    }
}

private struct DaybookComicReaderView: View {
    let comicBook: DaybookComicBook
    @Binding var currentPageIndex: Int

    @Environment(\.dismiss) private var dismiss
    @AppStorage("daybookComicReaderGestureHintSeen") private var readerGestureHintSeen = false

    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var isShowingGestureHint = false
    @State private var isReaderBookOpen = false
    @State private var isPageTurnActive = false
    @GestureState private var isMagnifying = false

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 5
    private let thumbnailHeight: CGFloat = 56
    private let panEdgePaddingRatio: CGFloat = 0.28
    private let readerSpineWidth: CGFloat = 18
    private let readerTopToolbarClearance: CGFloat = 58
    private let zoomSteps: [CGFloat] = [1.75, 2.5, 3.5, 5]

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            readerPageContent

            VStack(spacing: 0) {
                readerTopBar
                    .background {
                        LinearGradient(
                            colors: [.black.opacity(0.72), .black.opacity(0.28), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .top)
                    }

                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    readerBottomBar
                    readerPageThumbnailStrip
                }
                .background {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea(edges: .bottom)
                }
            }

            if isShowingGestureHint {
                gestureHintOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
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

            isReaderBookOpen = false
            withAnimation(.spring(response: 0.54, dampingFraction: 0.82).delay(0.06)) {
                isReaderBookOpen = true
            }
        }
        .onChange(of: currentPageIndex) { _ in
            resetZoom(animated: false)
        }
        .onDisappear {
            resetZoom(animated: false)
            isReaderBookOpen = false
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
            .accessibilityLabel("Back to daily journal")

            Spacer()

            Text("\(currentPageIndex + 1) / \(comicBook.totalPageCount)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            Menu {
                Button("Fit Page") {
                    resetZoom(animated: true)
                }
                .disabled(isAtFitZoom)
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
    }

    private var readerPageThumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<comicBook.totalPageCount, id: \.self) { pageIndex in
                        Button {
                            goToPage(pageIndex)
                        } label: {
                            readerThumbnail(for: pageIndex)
                        }
                        .buttonStyle(.plain)
                        .id(pageIndex)
                        .accessibilityLabel("Go to page \(pageIndex + 1)")
                        .accessibilityAddTraits(pageIndex == currentPageIndex ? .isSelected : [])
                    }
                }
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
        .frame(height: thumbnailHeight + 12)
        .padding(.bottom, 10)
    }

    private func readerThumbnail(for pageIndex: Int) -> some View {
        let isSelected = pageIndex == currentPageIndex
        let aspectRatio = comicBook.imageAspectRatio(for: pageIndex)
        let thumbnailWidth = max(28, thumbnailHeight * aspectRatio)

        return Image(comicBook.imageName(for: pageIndex))
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

    private var readerPageContent: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let pageSize = fittedPageSize(in: viewport)

            readerBookSurface(pageSize: pageSize) {
                Group {
                    if showsPageTurnView {
                        DaybookPageCurlReaderView(
                            comicBook: comicBook,
                            currentPageIndex: $currentPageIndex,
                            isPageTurnActive: $isPageTurnActive
                        )
                        .frame(width: pageSize.width, height: pageSize.height)
                        .scaleEffect(isMagnifying ? zoomScale : 1)
                        .simultaneousGesture(fitZoomMagnificationGesture(pageSize: pageSize, viewport: viewport))
                    } else {
                        DaybookComicPageContent(
                            comicBook: comicBook,
                            pageIndex: currentPageIndex
                        )
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

    private func readerBookSurface<Content: View>(
        pageSize: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let bookWidth = pageSize.width + readerSpineWidth

        return ZStack(alignment: .leading) {
            DaybookReaderPageStack()
                .frame(width: bookWidth, height: pageSize.height)
                .offset(x: 7, y: 7)

            DaybookReaderSpine()
                .frame(width: readerSpineWidth, height: pageSize.height)
                .allowsHitTesting(false)

            content()
                .shadow(color: .black.opacity(0.38), radius: 20, x: 0, y: 10)
                .overlay(alignment: .trailing) {
                    DaybookReaderSwipeCue()
                        .frame(width: 54)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    DaybookReaderPageBlock()
                        .frame(height: 5)
                        .allowsHitTesting(false)
                }
                .offset(x: readerSpineWidth)
        }
        .frame(width: bookWidth, height: pageSize.height)
        .rotation3DEffect(
            .degrees(isReaderBookOpen ? 0 : -18),
            axis: (x: 0, y: 1, z: 0),
            anchor: .leading,
            perspective: 0.72
        )
        .scaleEffect(isReaderBookOpen ? 1 : 0.96, anchor: .leading)
        .opacity(isReaderBookOpen ? 1 : 0.88)
        .animation(.spring(response: 0.54, dampingFraction: 0.82), value: isReaderBookOpen)
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
                if isAtFitZoom {
                    turnPage(by: -1)
                } else {
                    goToPage(currentPageIndex - 1)
                }
            }

            readerControlButton(
                isEnabled: currentPageIndex < comicBook.totalPageCount - 1 && !isTurningProgrammatically,
                accessibilityLabel: "Next page"
            ) {
                Image(systemName: "chevron.right")
            } action: {
                if isAtFitZoom {
                    turnPage(by: 1)
                } else {
                    goToPage(currentPageIndex + 1)
                }
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

    private var isAtFitZoom: Bool {
        zoomScale <= minimumScale + 0.02
    }

    private var showsPageTurnView: Bool {
        if isMagnifying {
            return lastZoomScale <= minimumScale + 0.02
        }

        return isAtFitZoom
    }

    private var isTurningProgrammatically: Bool {
        isPageTurnActive
    }

    private var canZoomInFurther: Bool {
        zoomSteps.contains { $0 > zoomScale + 0.05 }
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
        guard isAtFitZoom, !isTurningProgrammatically else {
            return
        }

        let nextPageIndex = clampedPageIndex(currentPageIndex + offset)
        guard nextPageIndex != currentPageIndex else {
            return
        }

        currentPageIndex = nextPageIndex
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
        min(max(0, pageIndex), max(0, comicBook.totalPageCount - 1))
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
        let aspectRatio = comicBook.imageAspectRatio(for: currentPageIndex)
        let width = max(viewport.width - readerSpineWidth, 1)
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

private struct JournalStoryboardComicReaderView: View {
    let storyboards: [GeneratedStoryboard]
    @Binding var currentPageIndex: Int

    @Environment(\.dismiss) private var dismiss
    @AppStorage("journalStoryboardComicReaderGestureHintSeen") private var readerGestureHintSeen = false

    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var isShowingGestureHint = false
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

            if storyboards.isEmpty {
                emptyState
            } else {
                readerPageContent
                    .zIndex(isPageTurnActive ? 3 : 0)
            }

            VStack(spacing: 0) {
                readerTopBar

                Spacer(minLength: 0)

                if !storyboards.isEmpty {
                    VStack(spacing: 0) {
                        readerBottomBar
                        readerThumbnailStrip
                    }
                        .background {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea(edges: .bottom)
                        }
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

            Text(storyboards.isEmpty ? "0 / 0" : "\(currentPageIndex + 1) / \(storyboards.count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            Menu {
                Button("Fit Page") {
                    resetZoom(animated: true)
                }
                .disabled(isAtFitZoom)
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
                            currentPageIndex: $currentPageIndex,
                            programmaticTurnOffset: programmaticTurnOffset,
                            programmaticTurnProgress: programmaticTurnProgress,
                            isPageTurnActive: $isPageTurnActive
                        )
                        .frame(width: pageSize.width, height: pageSize.height)
                        .scaleEffect(isMagnifying ? zoomScale : 1)
                        .simultaneousGesture(fitZoomMagnificationGesture(pageSize: pageSize, viewport: viewport))
                    } else if let image = image(for: currentPageIndex) {
                        storyboardPage(image)
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
                isEnabled: currentPageIndex < storyboards.count - 1 && !isTurningProgrammatically,
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
                        ForEach(Array(storyboards.enumerated()), id: \.element.id) { index, storyboard in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentPageIndex = index
                                }
                            } label: {
                                readerThumbnail(for: storyboard.image, at: index)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .accessibilityLabel("Go to storyboard \(index + 1)")
                            .accessibilityAddTraits(index == currentPageIndex ? .isSelected : [])
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

    private var emptyState: some View {
        Text("No storyboard images yet")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.78))
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
        let index = clampedPageIndex(pageIndex)
        guard storyboards.indices.contains(index) else {
            return nil
        }

        return storyboards[index].image
    }

    private func imageAspectRatio(for pageIndex: Int) -> CGFloat {
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
        guard !readerGestureHintSeen, !storyboards.isEmpty else {
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
        min(max(0, pageIndex), max(0, storyboards.count - 1))
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

private struct JournalStoryboardTurningPage: View {
    let images: [UIImage]
    let pageIndex: Int
    let progress: CGFloat
    let style: DaybookPageFoldStyle

    private let perspective: CGFloat = 0.34

    var body: some View {
        ZStack {
            if showsFrontFace, let image = image(at: pageIndex) {
                JournalStoryboardComicPage(image: image)
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

    private func image(at pageIndex: Int) -> UIImage? {
        let index = min(max(0, pageIndex), max(0, images.count - 1))
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
                .accessibilityLabel("Journal comic page \(currentPageIndex + 1) of \(images.count)")
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
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .foldLeft
                    )
                    .zIndex(1)

                case .unfoldPrevious(let revealed, let folding):
                    pageView(at: revealed)

                    JournalStoryboardTurningPage(
                        images: images,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .unfoldFromLeft
                    )
                    .zIndex(1)

                case .foldCurrentRight(let revealed, let folding):
                    pageView(at: revealed)

                    JournalStoryboardTurningPage(
                        images: images,
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
        if let image = image(at: pageIndex) {
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
            guard currentPageIndex < images.count - 1 else { return nil }
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

        if predicted < -threshold, currentPageIndex < images.count - 1 {
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
        let index = clampedPageIndex(pageIndex)
        guard images.indices.contains(index) else {
            return nil
        }

        return images[index]
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, images.count - 1))
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

private struct DaybookPageCurlReaderView: UIViewControllerRepresentable {
    let comicBook: DaybookComicBook
    @Binding var currentPageIndex: Int
    @Binding var isPageTurnActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear

        let initialIndex = clampedPageIndex(currentPageIndex)
        let initialController = context.coordinator.hostingController(for: initialIndex)
        pageViewController.setViewControllers(
            [initialController],
            direction: .forward,
            animated: false
        )
        context.coordinator.presentedPageIndex = initialIndex

        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self

        let targetIndex = clampedPageIndex(currentPageIndex)
        guard targetIndex != context.coordinator.presentedPageIndex,
              !context.coordinator.isAnimatingProgrammaticTurn else {
            return
        }

        let direction: UIPageViewController.NavigationDirection = targetIndex > context.coordinator.presentedPageIndex ? .forward : .reverse
        let nextController = context.coordinator.hostingController(for: targetIndex)

        context.coordinator.isAnimatingProgrammaticTurn = true
        isPageTurnActive = true

        pageViewController.setViewControllers(
            [nextController],
            direction: direction,
            animated: true
        ) { completed in
            context.coordinator.isAnimatingProgrammaticTurn = false
            isPageTurnActive = false

            guard completed else {
                return
            }

            context.coordinator.presentedPageIndex = targetIndex
        }
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, comicBook.totalPageCount - 1))
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: DaybookPageCurlReaderView
        var presentedPageIndex: Int
        var isAnimatingProgrammaticTurn = false

        init(parent: DaybookPageCurlReaderView) {
            self.parent = parent
            self.presentedPageIndex = parent.currentPageIndex
        }

        func hostingController(for pageIndex: Int) -> UIViewController {
            let controller = UIHostingController(
                rootView: DaybookComicPageContent(
                    comicBook: parent.comicBook,
                    pageIndex: parent.clampedPageIndex(pageIndex)
                )
            )
            controller.view.backgroundColor = .clear
            controller.view.tag = parent.clampedPageIndex(pageIndex)
            return controller
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            let previousIndex = viewController.view.tag - 1
            guard previousIndex >= 0 else {
                return nil
            }

            return hostingController(for: previousIndex)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            let nextIndex = viewController.view.tag + 1
            guard nextIndex < parent.comicBook.totalPageCount else {
                return nil
            }

            return hostingController(for: nextIndex)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            parent.isPageTurnActive = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            parent.isPageTurnActive = false

            guard completed,
                  let visibleController = pageViewController.viewControllers?.first else {
                return
            }

            let visibleIndex = parent.clampedPageIndex(visibleController.view.tag)
            presentedPageIndex = visibleIndex
            parent.currentPageIndex = visibleIndex
        }
    }
}

private struct DaybookComicSummaryStrip: View {
    let comicBook: DaybookComicBook
    var onOpenComic: () -> Void

    private let coverHeight: CGFloat = 118
    private let spineWidth: CGFloat = 8

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            comicCoverThumbnail

            VStack(alignment: .leading, spacing: 10) {
                Text("Monthly Comic")
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                VStack(alignment: .leading, spacing: 7) {
                    summaryRow(
                        text: comicBook.entryCountText,
                        systemImage: "book.pages.fill"
                    )
                    summaryRow(
                        text: comicBook.storyboardCountText,
                        systemImage: "photo.on.rectangle.angled"
                    )
                }

                Button(action: onOpenComic) {
                    Label("Open Comic", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel("Open comic in reader mode")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }

    private func summaryRow(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.homeMutedText)
            .labelStyle(.titleAndIcon)
    }

    private var comicCoverThumbnail: some View {
        HStack(spacing: 0) {
            DaybookComicBinder()
                .frame(width: spineWidth, height: coverHeight)

            Image(comicBook.coverImageName)
                .resizable()
                .scaledToFill()
                .frame(width: coverWidth, height: coverHeight)
                .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.black.opacity(0.88), lineWidth: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
    }

    private var coverWidth: CGFloat {
        let ratio = comicBook.imageAspectRatio(for: 0)
        return max(58, coverHeight * ratio)
    }
}

private enum DaybookTab: String, CaseIterable, Identifiable {
    case entries
    case comic

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .entries:
            return "Entries"
        case .comic:
            return "Comic"
        }
    }
}

private struct DaybookGalleryGrid: View {
    let comicBook: DaybookComicBook
    let onOpenImage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Text("Storyboards")
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Text(comicBook.storyboardCountText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }
            .padding(.top, 6)

            if comicBook.storyPages.isEmpty {
                DaybookEmptyComicState(title: "No storyboards yet", message: "Storyboards from this month will appear here.")
            } else {
                GeometryReader { proxy in
                    let spacing: CGFloat = 8
                    let columnWidth = (proxy.size.width - spacing) / 2

                    HStack(alignment: .top, spacing: spacing) {
                        storyboardColumn(
                            pages: comicBook.storyPages.enumerated().filter { $0.offset.isMultiple(of: 2) },
                            width: columnWidth
                        )

                        storyboardColumn(
                            pages: comicBook.storyPages.enumerated().filter { !$0.offset.isMultiple(of: 2) },
                            width: columnWidth
                        )
                    }
                }
                .frame(height: masonryHeight(for: comicBook.storyPages))
            }
        }
    }

    private func storyboardColumn(
        pages: [(offset: Int, element: DaybookStoryPage)],
        width: CGFloat
    ) -> some View {
        VStack(spacing: 8) {
            ForEach(pages, id: \.element.id) { item in
                let page = item.element
                Button {
                    onOpenImage(item.offset)
                } label: {
                    Image(page.imageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: galleryHeight(for: page, width: width))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            Text("\(item.offset + 1)")
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(.black.opacity(0.62), in: Capsule())
                                .padding(8)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(page.title), image \(item.offset + 1) of \(comicBook.storyPages.count)")
            }
        }
    }

    private func galleryHeight(for page: DaybookStoryPage, width: CGFloat) -> CGFloat {
        guard let image = UIImage(named: page.imageName), image.size.width > 0 else {
            return width * 1.28
        }

        return min(width * 1.72, max(width * 0.88, width * (image.size.height / image.size.width)))
    }

    private func masonryHeight(for pages: [DaybookStoryPage]) -> CGFloat {
        let rows = max(1, Int(ceil(Double(pages.count) / 2.0)))
        return CGFloat(rows) * 312 + CGFloat(max(0, rows - 1)) * 8
    }
}

private struct DaybookComicTab: View {
    let comicBook: DaybookComicBook
    @Binding var currentPageIndex: Int
    @Binding var previewHorizontalPosition: Double
    @Binding var previewZoom: Double
    var bookHorizontalInset: CGFloat = 0
    var headerHorizontalInset: CGFloat = 0
    var availableBookWidth: CGFloat?
    var onOpenReader: (() -> Void)?
    var onOpenGalleryImage: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Text(comicBook.monthTitle)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Text(comicBook.pageCountText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }
            .padding(.top, 6)
            .padding(.horizontal, headerHorizontalInset)

            if comicBook.storyPages.isEmpty {
                DaybookEmptyComicState(title: "No comic pages yet", message: "Entries with storyboards will become this month's issue.")
                    .padding(.horizontal, headerHorizontalInset)
            } else {
                DaybookComicBookView(
                    comicBook: comicBook,
                    currentPageIndex: $currentPageIndex,
                    previewHorizontalPosition: $previewHorizontalPosition,
                    previewZoom: $previewZoom,
                    availableWidth: availableBookWidth,
                    onOpenReader: onOpenReader
                )
                .padding(.horizontal, bookHorizontalInset)

                if let onOpenGalleryImage {
                    DaybookGalleryGrid(comicBook: comicBook, onOpenImage: onOpenGalleryImage)
                        .padding(.top, 8)
                }
            }
        }
    }
}

private enum DaybookComicPreviewMetrics {
    static let sliderMinimumZoom: Double = 0.5
    static let maximumZoom: Double = 2.5

    static var sliderZoomRange: ClosedRange<Double> {
        sliderMinimumZoom...maximumZoom
    }

    static var sliderZoomCenter: Double {
        (sliderMinimumZoom + maximumZoom) / 2
    }
}

private struct DaybookComicBookView: View {
    let comicBook: DaybookComicBook
    @Binding var currentPageIndex: Int
    @Binding var previewHorizontalPosition: Double
    @Binding var previewZoom: Double
    var showsCaption = true
    var availableWidth: CGFloat?
    var showsCoverOverlay = false
    var onOpenReader: (() -> Void)?
    @State private var programmaticTurnOffset = 0
    @State private var programmaticTurnProgress: CGFloat = 0
    @State private var isBackwardTurnActive = false
    @State private var isPageTurnActive = false
    @State private var layoutPageIndex = 0
    private let binderWidth: CGFloat = 12
    private let previewScale: CGFloat = 0.8
    private let comicTabHorizontalInset: CGFloat = 16
    private let horizontalOverscrollPadding: CGFloat = 64

    init(
        comicBook: DaybookComicBook,
        currentPageIndex: Binding<Int>,
        previewHorizontalPosition: Binding<Double>,
        previewZoom: Binding<Double>,
        showsCaption: Bool = true,
        availableWidth: CGFloat? = nil,
        showsCoverOverlay: Bool = false,
        onOpenReader: (() -> Void)? = nil
    ) {
        self.comicBook = comicBook
        self._currentPageIndex = currentPageIndex
        self._previewHorizontalPosition = previewHorizontalPosition
        self._previewZoom = previewZoom
        self.showsCaption = showsCaption
        self.availableWidth = availableWidth
        self.showsCoverOverlay = showsCoverOverlay
        self.onOpenReader = onOpenReader
    }

    var body: some View {
        VStack(spacing: 10) {
            comicPreviewRow

            if onOpenReader != nil {
                Button {
                    onOpenReader?()
                } label: {
                    Label("Tap comic to expand", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.homeMutedText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tap comic to expand into reader mode")
            }

            HStack(spacing: 10) {
                Button {
                    turnPage(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(currentPageIndex == 0 || isTurningProgrammatically ? Color.homeMutedText.opacity(0.35) : Color.storyInk)
                        .frame(width: 38, height: 34)
                        .background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(currentPageIndex == 0 || isTurningProgrammatically)
                .accessibilityLabel("Previous comic page")

                Text("\(currentPageIndex + 1) / \(comicBook.totalPageCount)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.homeMutedText)
                    .frame(minWidth: 58)

                Button {
                    turnPage(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(currentPageIndex >= comicBook.totalPageCount - 1 || isTurningProgrammatically ? Color.homeMutedText.opacity(0.35) : Color.storyInk)
                        .frame(width: 38, height: 34)
                        .background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(currentPageIndex >= comicBook.totalPageCount - 1 || isTurningProgrammatically)
                .accessibilityLabel("Next comic page")
            }

            if onOpenReader != nil {
                Button {
                    onOpenReader?()
                } label: {
                    Label("Open Comic", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open comic in reader mode")
            }

            if showsCaption {
                DaybookComicPageCaption(comicBook: comicBook, pageIndex: currentPageIndex)
            }
        }
        .onAppear {
            currentPageIndex = clampedPageIndex(currentPageIndex)
            layoutPageIndex = currentPageIndex
        }
        .onChange(of: comicBook.totalPageCount) { _ in
            currentPageIndex = clampedPageIndex(currentPageIndex)
        }
        .onChange(of: currentPageIndex) { newIndex in
            if !isPageTurnActive {
                layoutPageIndex = newIndex
            }
        }
        .onChange(of: isPageTurnActive) { turning in
            if !turning {
                layoutPageIndex = currentPageIndex
            }
        }
    }

    private var comicPreviewRow: some View {
        Color.clear
            .frame(height: scaledPageHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                comicPreview
                    .offset(x: horizontalContentOffset)
            }
            .padding(.horizontal, -comicTabHorizontalInset)
            .animation(.easeInOut(duration: 0.15), value: previewHorizontalPosition)
            .animation(.easeInOut(duration: 0.15), value: previewZoom)
    }

    private var comicPreview: some View {
        DaybookPageTurnView(
            comicBook: comicBook,
            currentPageIndex: $currentPageIndex,
            programmaticTurnOffset: programmaticTurnOffset,
            programmaticTurnProgress: programmaticTurnProgress,
            showsCoverOverlay: showsCoverOverlay,
            isBackwardTurnActive: $isBackwardTurnActive,
            isPageTurnActive: $isPageTurnActive,
            turnPageWidth: scaledPageWidth,
            leadingSpread: AnyView(comicPreviewLeadingSpread),
            onTap: onOpenReader
        )
        .frame(width: spreadContentWidth, height: scaledPageHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.03, green: 0.03, blue: 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 18, y: 10)
    }

    private var comicPreviewLeadingSpread: some View {
        HStack(spacing: 0) {
            if let leftPageIndex = spreadLeftPageIndex, !isBackwardTurnActive {
                DaybookComicPageContent(
                    comicBook: comicBook,
                    pageIndex: leftPageIndex,
                    showsCoverOverlay: showsCoverOverlay
                )
                .frame(width: scaledPageWidth(for: leftPageIndex), height: scaledPageHeight)
            }

            DaybookComicBinder()
                .frame(width: scaledBinderWidth, height: scaledPageHeight)
        }
    }

    private var spreadLeftPageIndex: Int? {
        guard layoutPageIndex > 0 else {
            return nil
        }

        return layoutPageIndex - 1
    }

    private var previewZoomScale: CGFloat {
        CGFloat(previewZoom)
    }

    private var layoutWidth: CGFloat {
        max(1, (availableWidth ?? UIScreen.main.bounds.width - (comicTabHorizontalInset * 2)) * previewScale)
    }

    private var spreadAspectRatio: CGFloat {
        var ratio = comicBook.imageAspectRatio(for: layoutPageIndex)

        if let leftPageIndex = spreadLeftPageIndex {
            ratio = max(ratio, comicBook.imageAspectRatio(for: leftPageIndex))
        }

        return ratio
    }

    private var scaledPageHeight: CGFloat {
        let maxPageWidth = max(1, layoutWidth - binderWidth) * previewZoomScale
        return maxPageWidth / spreadAspectRatio
    }

    private func scaledPageWidth(for pageIndex: Int) -> CGFloat {
        scaledPageHeight * comicBook.imageAspectRatio(for: pageIndex)
    }

    private var scaledPageWidth: CGFloat {
        scaledPageWidth(for: currentPageIndex)
    }

    private var scaledBinderWidth: CGFloat {
        binderWidth * previewZoomScale
    }

    private var spreadContentWidth: CGFloat {
        var width = scaledBinderWidth + scaledPageWidth(for: layoutPageIndex)

        if let leftPageIndex = spreadLeftPageIndex {
            width += scaledPageWidth(for: leftPageIndex)
        }

        return width
    }

    private var comicRowWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    private var horizontalContentOffset: CGFloat {
        let overflow = spreadContentWidth - comicRowWidth
        let overscroll = horizontalOverscrollPadding

        if overflow <= 0 {
            let centeredOffset = (comicRowWidth - spreadContentWidth) / 2
            let fitTravel = overscroll * 2
            return centeredOffset + overscroll - (CGFloat(previewHorizontalPosition) * fitTravel)
        }

        let totalTravel = overflow + (overscroll * 2)
        return overscroll - (CGFloat(previewHorizontalPosition) * totalTravel)
    }

    private func turnPage(by offset: Int) {
        guard !isTurningProgrammatically else {
            return
        }

        let nextPageIndex = clampedPageIndex(currentPageIndex + offset)
        guard nextPageIndex != currentPageIndex else {
            return
        }

        programmaticTurnOffset = offset
        programmaticTurnProgress = 0.02

        withAnimation(.easeInOut(duration: 0.32)) {
            programmaticTurnProgress = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            var transaction = Transaction()
            transaction.animation = nil

            withTransaction(transaction) {
                currentPageIndex = nextPageIndex
                programmaticTurnOffset = 0
                programmaticTurnProgress = 0
            }
        }
    }

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, comicBook.totalPageCount - 1))
    }

    private var isTurningProgrammatically: Bool {
        programmaticTurnOffset != 0
    }
}

private struct DaybookScrollClipDisabledModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

private struct DaybookComicBinder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.07, blue: 0.08),
                    Color(red: 0.16, green: 0.16, blue: 0.18),
                    Color(red: 0.04, green: 0.04, blue: 0.05)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Rectangle()
                .fill(.black.opacity(0.38))
                .frame(width: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CenterSnappingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let centerValue: Double

    private let trackHorizontalInset: CGFloat = 16
    private let snapThresholdRatio: Double = 0.035

    private var normalizedCenter: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat((centerValue - range.lowerBound) / span)
    }

    private var snapThreshold: Double {
        (range.upperBound - range.lowerBound) * snapThresholdRatio
    }

    var body: some View {
        Slider(value: snappingBinding, in: range)
            .tint(Color.homeAccent)
            .overlay {
                GeometryReader { proxy in
                    let tickX = trackHorizontalInset + normalizedCenter * max(0, proxy.size.width - (trackHorizontalInset * 2))

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            value = centerValue
                        }
                    } label: {
                        Capsule()
                            .fill(Color.homeMutedText.opacity(0.5))
                            .frame(width: 2, height: 13)
                    }
                    .buttonStyle(.plain)
                    .position(x: tickX, y: proxy.size.height / 2)
                    .accessibilityLabel("Snap to center")
                }
            }
    }

    private var snappingBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                if abs(newValue - centerValue) <= snapThreshold {
                    value = centerValue
                } else {
                    value = newValue
                }
            }
        )
    }
}

private struct DaybookComicPreviewControlSliders: View {
    @Binding var horizontalPosition: Double
    @Binding var zoom: Double
    let zoomRange: ClosedRange<Double>
    let zoomCenterValue: Double

    private let horizontalRange: ClosedRange<Double> = 0...1
    private let horizontalCenterValue: Double = 0.5

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .frame(width: 18)

                CenterSnappingSlider(
                    value: $horizontalPosition,
                    range: horizontalRange,
                    centerValue: horizontalCenterValue
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Slide comic left or right")

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .frame(width: 18)

                CenterSnappingSlider(
                    value: $zoom,
                    range: zoomRange,
                    centerValue: zoomCenterValue
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Zoom comic in or out")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 14, y: 4)
    }
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

private struct DaybookReaderPageStack: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.78, green: 0.76, blue: 0.70))
                .offset(x: 5, y: 5)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.88, green: 0.86, blue: 0.80))
                .offset(x: 3, y: 3)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: 0.96, green: 0.94, blue: 0.88))
                .offset(x: 1.5, y: 1.5)
        }
        .overlay(alignment: .trailing) {
            VStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(Color.black.opacity(index.isMultiple(of: 2) ? 0.16 : 0.08))
                        .frame(height: 1)
                }
            }
            .padding(.vertical, 20)
            .frame(width: 18)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                ForEach(0..<2, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 1)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 2)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, x: 4, y: 7)
        .allowsHitTesting(false)
    }
}

private struct DaybookReaderSpine: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.76),
                    Color.black.opacity(0.18),
                    Color.white.opacity(0.12),
                    Color.black.opacity(0.34)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.34))
                .frame(width: 2)
        }
    }
}

private struct DaybookReaderSwipeCue: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(
                colors: [
                    .clear,
                    Color.white.opacity(0.08),
                    Color.black.opacity(0.3)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.02),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
                .padding(.top, 18)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct DaybookReaderPageBlock: View {
    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<2, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(index == 0 ? 0.18 : 0.1))
                    .frame(height: 1)
            }
        }
        .padding(.horizontal, 28)
        .background(
            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
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

private struct DaybookTurningPage: View {
    let comicBook: DaybookComicBook
    let pageIndex: Int
    let progress: CGFloat
    let style: DaybookPageFoldStyle
    let showsCoverOverlay: Bool

    private let perspective: CGFloat = 0.65

    var body: some View {
        ZStack {
            if showsFrontFace {
                pageFace
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

    private var pageFace: some View {
        DaybookComicPageContent(
            comicBook: comicBook,
            pageIndex: pageIndex,
            showsCoverOverlay: showsCoverOverlay
        )
        .id(pageIndex)
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

private struct DaybookPageTurnView: View {
    let comicBook: DaybookComicBook
    @Binding var currentPageIndex: Int
    let programmaticTurnOffset: Int
    let programmaticTurnProgress: CGFloat
    let showsCoverOverlay: Bool
    @Binding var isBackwardTurnActive: Bool
    @Binding var isPageTurnActive: Bool
    var turnPageWidth: CGFloat? = nil
    var leadingSpread: AnyView? = nil
    var leadingEdgeReserve: CGFloat = 0
    var onTap: (() -> Void)?
    @State private var dragTranslation: CGFloat = 0
    @State private var pendingTurnOffset = 0
    @State private var pendingTurnProgress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let turnWidth = max(1, turnPageWidth ?? proxy.size.width)
            let pageTurn = pageTurnState(width: turnWidth)

            HStack(spacing: 0) {
                if leadingEdgeReserve > 0 {
                    Color.clear
                        .frame(width: leadingEdgeReserve)
                        .allowsHitTesting(false)
                }

                pageTurnInteractionArea(pageTurn: pageTurn, turnWidth: turnWidth, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Comic book page \(currentPageIndex + 1) of \(comicBook.totalPageCount)")
            .onChange(of: pageTurn.isTurningBackward) { isTurningBackward in
                isBackwardTurnActive = isTurningBackward
            }
            .onChange(of: pageTurn.isTurningForward || pageTurn.isTurningBackward || pendingTurnOffset != 0) { turning in
                isPageTurnActive = turning
            }
            .onAppear {
                isBackwardTurnActive = pageTurn.isTurningBackward
                isPageTurnActive = pageTurn.isTurningForward || pageTurn.isTurningBackward
            }
        }
    }

    private func pageTurnInteractionArea(
        pageTurn: (progress: CGFloat, isTurningForward: Bool, isTurningBackward: Bool),
        turnWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            if let leadingSpread {
                leadingSpread
                    .allowsHitTesting(false)
            }

            turnPageContent(pageTurn: pageTurn, width: turnWidth)
                .frame(width: turnWidth, height: height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .simultaneousGesture(
            TapGesture().onEnded {
                onTap?()
            }
        )
    }

    @ViewBuilder
    private func turnPageContent(
        pageTurn: (progress: CGFloat, isTurningForward: Bool, isTurningBackward: Bool),
        width: CGFloat
    ) -> some View {
        ZStack {
            if let animation = activeTurnAnimation(for: pageTurn) {
                switch animation {
                case .forward(let revealed, let folding):
                    pageView(at: revealed)

                    DaybookTurningPage(
                        comicBook: comicBook,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .foldLeft,
                        showsCoverOverlay: showsCoverOverlay
                    )
                    .zIndex(1)

                case .unfoldPrevious(let revealed, let folding):
                    pageView(at: revealed)

                    DaybookTurningPage(
                        comicBook: comicBook,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .unfoldFromLeft,
                        showsCoverOverlay: showsCoverOverlay
                    )
                    .zIndex(1)

                case .foldCurrentRight(let revealed, let folding):
                    pageView(at: revealed)

                    DaybookTurningPage(
                        comicBook: comicBook,
                        pageIndex: folding,
                        progress: pageTurn.progress,
                        style: .foldRight,
                        showsCoverOverlay: showsCoverOverlay
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
        DaybookComicPageContent(
            comicBook: comicBook,
            pageIndex: pageIndex,
            showsCoverOverlay: showsCoverOverlay
        )
        .id(pageIndex)
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
            guard currentPageIndex < comicBook.totalPageCount - 1 else { return nil }
            return .forward(revealed: currentPageIndex + 1, folding: currentPageIndex)
        }

        if pageTurn.isTurningBackward {
            guard currentPageIndex > 0 else { return nil }
            if leadingSpread != nil {
                return .foldCurrentRight(revealed: currentPageIndex - 1, folding: currentPageIndex)
            }
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

        if predicted < -threshold, currentPageIndex < comicBook.totalPageCount - 1 {
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

    private func clampedPageIndex(_ pageIndex: Int) -> Int {
        min(max(0, pageIndex), max(0, comicBook.totalPageCount - 1))
    }
}

private struct DaybookComicPageCaption: View {
    let comicBook: DaybookComicBook
    let pageIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.homeMutedText)

            Text(title)
                .font(.system(size: 24, weight: .black, design: .serif))
                .foregroundStyle(Color.storyInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let bodyText {
                Text(bodyText)
                    .font(.system(size: 14, weight: .semibold))
                    .lineSpacing(4)
                    .foregroundStyle(Color.storyInk.opacity(0.72))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var eyebrow: String {
        if pageIndex == 0 {
            return "Issue #\(comicBook.issueNumber) • 1 / \(comicBook.totalPageCount)"
        }

        if pageIndex == comicBook.totalPageCount - 1 {
            return "Back Cover • \(pageIndex + 1) / \(comicBook.totalPageCount)"
        }

        return "\(storyPage.dateText) • \(pageIndex + 1) / \(comicBook.totalPageCount)"
    }

    private var title: String {
        if pageIndex == 0 {
            return comicBook.monthTitle
        }

        if pageIndex == comicBook.totalPageCount - 1 {
            return "Issue Notes"
        }

        return storyPage.title
    }

    private var bodyText: String? {
        if pageIndex == 0 {
            return "\(comicBook.entryCountText) • \(comicBook.storyboardCountText)"
        }

        if pageIndex == comicBook.totalPageCount - 1 {
            return "Most visited: \(comicBook.mostVisitedLocation)\nTheme: \(comicBook.mostCommonTheme)"
        }

        return storyPage.excerpt
    }

    private var storyPage: DaybookStoryPage {
        comicBook.storyPages[min(max(0, pageIndex - 1), max(0, comicBook.storyPages.count - 1))]
    }
}

private struct DaybookEmptyComicState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.pages")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.homeAccent.opacity(0.68))

            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
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
}

private struct DaybookComicPageContent: View {
    let comicBook: DaybookComicBook
    let pageIndex: Int
    var showsCoverOverlay = false

    var body: some View {
        if pageIndex == 0 {
            DaybookComicCoverPage(
                comicBook: comicBook,
                showsCoverOverlay: showsCoverOverlay
            )
        } else if pageIndex == comicBook.totalPageCount - 1 {
            DaybookComicBackCoverPage(comicBook: comicBook)
        } else {
            let storyPage = comicBook.storyPages[pageIndex - 1]

            DaybookComicStoryPage(page: storyPage)
        }
    }
}

private struct DaybookComicCoverPage: View {
    let comicBook: DaybookComicBook
    var showsCoverOverlay = false

    var body: some View {
        GeometryReader { proxy in
            Image(comicBook.coverImageName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.black.opacity(0.34), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 22)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.black, lineWidth: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .overlay {
                    if showsCoverOverlay {
                        Color.black.opacity(0.28)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if showsCoverOverlay {
                        coverText
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                }
                .shadow(color: .black.opacity(0.32), radius: 12, y: 7)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var coverText: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(comicBook.entryCountText.lowercased(), systemImage: "book.pages.fill")
                Label(comicBook.storyboardCountText.lowercased(), systemImage: "photo.on.rectangle.angled")
            }
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.68)

            Text(comicBook.monthTitle)
                .font(.system(size: 30, weight: .black, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Text("Daily")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.58), radius: 8, y: 3)
    }
}

private struct DaybookComicStoryPage: View {
    let page: DaybookStoryPage

    var body: some View {
        GeometryReader { proxy in
            Image(page.imageName)
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
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.black, lineWidth: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct DaybookComicBackCoverPage: View {
    let comicBook: DaybookComicBook

    var body: some View {
        GeometryReader { proxy in
            Image(comicBook.backCoverImageName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.black.opacity(0.34), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 22)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.black, lineWidth: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.32), radius: 12, y: 7)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct DaybookComicBook {
    let chapters: [PrototypeChapter]

    private let pageImageNames = journalSampleImages(startIndex: 0, count: 16)
    let issueNumber = 23
    let monthTitle = "June 2026"

    var storyPages: [DaybookStoryPage] {
        Array(monthEntries.prefix(pageImageNames.count).enumerated()).map { index, item in
            DaybookStoryPage(
                entry: item.entry,
                date: item.date,
                chapterTitle: item.chapter.title,
                imageName: pageImageNames[index]
            )
        }
    }

    var totalPageCount: Int {
        storyPages.count + 2
    }

    var coverImageName: String {
        storyPages.first?.imageName ?? regularSetImageNames.first ?? "IMG_9080"
    }

    var backCoverImageName: String {
        storyPages.last?.imageName ?? coverImageName
    }

    func imageName(for pageIndex: Int) -> String {
        if pageIndex == 0 {
            return coverImageName
        }

        if pageIndex == totalPageCount - 1 {
            return backCoverImageName
        }

        return storyPages[min(max(0, pageIndex - 1), max(0, storyPages.count - 1))].imageName
    }

    func imageAspectRatio(for pageIndex: Int) -> CGFloat {
        let imageName = imageName(for: pageIndex)

        guard let image = UIImage(named: imageName), image.size.height > 0 else {
            return 0.57
        }

        return image.size.width / image.size.height
    }

    var entryCountValue: String {
        "\(monthEntries.count)"
    }

    var storyboardCountValue: String {
        "\(storyPages.count)"
    }

    var entryCountText: String {
        "\(entryCountValue) \(monthEntries.count == 1 ? "Entry" : "Entries")"
    }

    var storyboardCountText: String {
        "\(storyboardCountValue) \(storyPages.count == 1 ? "Storyboard" : "Storyboards")"
    }

    var pageCountText: String {
        "\(totalPageCount) \(totalPageCount == 1 ? "page" : "pages")"
    }

    var mostVisitedLocation: String {
        mostCommonValue(storyPages.compactMap(\.location)) ?? "Uncharted"
    }

    var mostCommonTheme: String {
        mostCommonValue(storyPages.map(\.chapterTitle)) ?? "Everyday Stories"
    }

    var topCharactersText: String {
        let names = storyPages
            .flatMap { page in
                characterWords(in: page.title + " " + page.excerpt)
            }
            .filter { word in
                guard let firstScalar = word.unicodeScalars.first else { return false }
                return CharacterSet.uppercaseLetters.contains(firstScalar)
                    && word.count > 2
                    && !excludedCharacterWords.contains(word)
            }

        let topNames = Array(countsByValue(names).sorted { $0.value > $1.value }.prefix(2).map(\.key))
        return topNames.isEmpty ? "Mike\nCooper" : topNames.joined(separator: "\n")
    }

    private var monthEntries: [DaybookMonthEntry] {
        chapters.enumerated()
            .flatMap { dayOffset, chapter in
                let date = DailyJournalData.journalDate(dayOffset: dayOffset)
                return chapter.entries.enumerated().map { entryIndex, entry in
                    DaybookMonthEntry(
                        date: date,
                        entryIndex: entryIndex,
                        chapter: chapter,
                        entry: entry
                    )
                }
            }
            .sorted { left, right in
                if left.date == right.date {
                    return left.entryIndex < right.entryIndex
                }

                return left.date < right.date
            }
    }

    private var excludedCharacterWords: Set<String> {
        ["The", "Every", "June", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    }

    private func mostCommonValue(_ values: [String]) -> String? {
        countsByValue(values).max { $0.value < $1.value }?.key
    }

    private func countsByValue(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in
            let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedValue.isEmpty else {
                return
            }

            counts[cleanedValue, default: 0] += 1
        }
    }

    private func characterWords(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }
}

private struct DaybookMonthEntry {
    let date: Date
    let entryIndex: Int
    let chapter: PrototypeChapter
    let entry: PrototypeEntry
}

private struct DaybookStoryPage: Identifiable {
    let entry: PrototypeEntry
    let date: Date
    let chapterTitle: String
    let imageName: String

    var id: String {
        imageName
    }

    var title: String {
        entry.title
    }

    var excerpt: String {
        entry.body
    }

    var location: String? {
        entry.location
    }

    var dateText: String {
        date.formatted(.dateTime.month(.wide).day())
    }
}

enum DailyJournalData {
    static func allChapters(cloudEntries: [JournalEntry]? = nil) -> [PrototypeChapter] {
        systemChapters(cloudEntries: cloudEntries)
            + UserChapterStore.load()
                .filter { !SystemJournalTitles.all.contains($0.title) }
                .map(chapterWithStoredEntries)
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
            systemJournal: chapter.systemJournal,
            entries: chapter.entries
        )
    }

    static func detailView(
        for chapter: PrototypeChapter,
        dayOffset: Int,
        onNewEntryPresentationChange: @escaping (Bool) -> Void = { _ in },
        onChapterUpdated: @escaping (PrototypeChapter) -> Void = { _ in },
        onOpenExistingEntry: ((CreateEntryDraft, Bool, UIImage?) -> Void)? = nil,
        onAddEntry: @escaping (PrototypeEntry) -> Void
    ) -> some View {
        let datedChapter = dateTitledChapter(from: chapter, dayOffset: dayOffset)

        return PrototypeChapterDetailView(
            chapter: datedChapter.copy(title: chapter.title),
            entryDate: journalDate(dayOffset: dayOffset),
            presentation: .dailyJournal,
            onNewEntryPresentationChange: onNewEntryPresentationChange,
            onChapterUpdated: onChapterUpdated,
            onOpenExistingEntry: onOpenExistingEntry,
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

    private static func systemChapters(cloudEntries: [JournalEntry]?) -> [PrototypeChapter] {
        PrototypeChapter.SystemJournal.orderedCases.map { systemJournal in
            let appearance = SystemJournalAppearanceStore.appearance(for: systemJournal)
            return PrototypeChapter(
                id: systemJournal.id,
                title: systemJournal.title,
                subtitle: systemJournal.subtitle,
                color: appearance.color ?? systemJournal.color,
                symbol: systemJournal.symbol,
                coverImageName: appearance.coverImageName,
                remoteCover: appearance.remoteCover,
                kind: .journal,
                isFavorite: false,
                createdAt: .distantPast,
                updatedAt: Date(),
                systemJournal: systemJournal,
                entries: systemEntries(for: systemJournal, cloudEntries: cloudEntries)
            )
        }
    }

    private static func systemEntries(
        for systemJournal: PrototypeChapter.SystemJournal,
        cloudEntries: [JournalEntry]?
    ) -> [PrototypeEntry] {
        if let cloudEntries {
            return cloudEntries
                .filter { $0.status != JournalEntryStatus.archived.rawValue }
                .filter { entry in
                    switch systemJournal {
                    case .drafts:
                        return entry.status != JournalEntryStatus.completed.rawValue
                    case .completed:
                        return entry.status == JournalEntryStatus.completed.rawValue
                    }
                }
                .map { PrototypeEntry(cloudEntry: $0) }
        }

        return CreateEntryDraftStore.loadAll()
            .filter { entry in
                switch systemJournal {
                case .drafts:
                    return entry.status != JournalEntryStatus.completed.rawValue
                case .completed:
                    return entry.status == JournalEntryStatus.completed.rawValue
                }
            }
            .map { $0.prototypeEntry() }
    }
}

private enum SystemJournalTitles {
    static let all = Set(PrototypeChapter.SystemJournal.orderedCases.map(\.title))
}

private struct DailyJournalEntrySummary: Identifiable {
    let dayOffset: Int
    let chapter: PrototypeChapter
    let entry: PrototypeEntry
    let coverImageName: String?

    var id: UUID {
        entry.id
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

private struct AllJournalEntriesSection: View {
    @Binding var chapters: [PrototypeChapter]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if allJournalEntries.isEmpty {
                noJournalEntries
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(allJournalEntryDays) { day in
                        journalDayGroup(day)
                    }
                }
            }
        }
    }

    private func journalDayGroup(_ day: DailyJournalDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                dailyJournalDetail(for: day.sourceChapter, dayOffset: day.dayOffset)
            } label: {
                journalDayHeader(day)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open journal for \(day.fullDateText)")

            ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, item in
                NavigationLink {
                    PrototypeEntryDetailView(
                        entry: item.entry,
                        chapter: item.chapter,
                        title: "Journal Entry"
                    )
                } label: {
                    PrototypeEntryRow(
                        entry: regularPhotoDisplayEntry(for: item.entry, dayOffset: day.dayOffset, entryIndex: index),
                        accentColor: Color.homeAccent,
                        showsDate: false,
                        thumbnailSize: 64,
                        inlineLeadingCoverImageName: item.coverImageName,
                        showsReferencePhotos: false,
                        isCompact: true,
                        showsBodyPreview: true
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.homeBorder.opacity(0.7))
                        .frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func regularPhotoDisplayEntry(
        for entry: PrototypeEntry,
        dayOffset: Int,
        entryIndex: Int
    ) -> PrototypeEntry {
        guard !entry.imageNames.isEmpty else {
            return entry
        }

        return entry.copy(
            imageNames: regularPhotoNames(
                startIndex: (dayOffset * 3) + (entryIndex * 2),
                count: entry.imageNames.count
            )
        )
    }

    private func regularPhotoNames(startIndex: Int, count: Int) -> [String] {
        (0..<count).map { offset in
            regularSetImageNames[(startIndex + offset) % regularSetImageNames.count]
        }
    }

    private func journalDateBadge(_ day: DailyJournalDaySummary) -> some View {
        VStack(spacing: 0) {
            Text(day.monthText)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text(day.dayText)
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 43, height: 52)
        .background(
            LinearGradient(
                colors: [Color.homeAccent, Color.homeAccent.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .shadow(color: Color.homeAccent.opacity(0.22), radius: 5, y: 3)
    }

    private func journalDayHeader(_ day: DailyJournalDaySummary) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(day.compactSectionDateText)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer(minLength: 8)

            Text("\(day.entries.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .padding(.horizontal, 16)
        .background(Color.homePageBackground)
    }

    private var noJournalEntries: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.pages")
                .font(.system(size: 28))
                .foregroundStyle(Color.homeAccent.opacity(0.68))

            Text("No journal entries yet")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text("Entries from every day will appear here.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
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

    private var allJournalEntries: [DailyJournalEntrySummary] {
        allJournalEntryDays.flatMap(\.entries)
    }

    private var allJournalEntryDays: [DailyJournalDaySummary] {
        var nextStoryboardCoverIndex = 0

        return chapters.enumerated().compactMap { dayOffset, chapter -> DailyJournalDaySummary? in
            let datedChapter = DailyJournalData.dateTitledChapter(from: chapter, dayOffset: dayOffset)
            let entries = datedChapter.entries.map { entry in
                let coverImageName = storyboardExampleImageName(for: nextStoryboardCoverIndex)
                nextStoryboardCoverIndex += 1

                return DailyJournalEntrySummary(
                    dayOffset: dayOffset,
                    chapter: datedChapter,
                    entry: entry,
                    coverImageName: coverImageName
                )
            }

            guard !entries.isEmpty else {
                return nil
            }

            return DailyJournalDaySummary(
                dayOffset: dayOffset,
                sourceChapter: chapter,
                chapter: datedChapter,
                entries: entries
            )
        }
    }

    private var storyboardExampleImageNames: [String] {
        (1...16).map { "storyboard\($0)" }
    }

    private func storyboardExampleImageName(for index: Int) -> String? {
        guard storyboardExampleImageNames.indices.contains(index) else {
            return nil
        }

        return storyboardExampleImageNames[index]
    }

    private func dailyJournalDetail(for chapter: PrototypeChapter, dayOffset: Int) -> some View {
        DailyJournalData.detailView(for: chapter, dayOffset: dayOffset) { entry in
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
}

private struct DailyJournalDaySummary: Identifiable {
    let dayOffset: Int
    let sourceChapter: PrototypeChapter
    let chapter: PrototypeChapter
    let entries: [DailyJournalEntrySummary]

    var id: Int {
        dayOffset
    }

    var monthText: String {
        date.formatted(.dateTime.month(.abbreviated)).uppercased()
    }

    var dayText: String {
        date.formatted(.dateTime.day())
    }

    var fullDateText: String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    var sectionDateText: String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var compactSectionDateText: String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }

    var entryCountText: String {
        "\(entries.count) \(entries.count == 1 ? "entry" : "entries")"
    }

    private var date: Date {
        DailyJournalData.journalDate(dayOffset: dayOffset)
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
            imageNames: []
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
            .appendingPathComponent("Storytopia", isDirectory: true)
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
        }
    }
}

private enum EntriesSessionMemoryCache {
    private static var snapshotsByQueryKey: [EntriesCloudFetchCache.EntryQueryKey: Snapshot] = [:]

    static func snapshot(for queryKey: EntriesCloudFetchCache.EntryQueryKey) -> Snapshot? {
        snapshotsByQueryKey[queryKey]
    }

    static func store(_ snapshot: Snapshot, for queryKey: EntriesCloudFetchCache.EntryQueryKey) {
        snapshotsByQueryKey[queryKey] = snapshot
    }

    static func invalidate(userID: UUID?) {
        guard let userID else {
            snapshotsByQueryKey.removeAll()
            return
        }

        snapshotsByQueryKey = snapshotsByQueryKey.filter { $0.key.userID != userID }
    }

    struct Snapshot {
        let entries: [CreateEntryDraft]
        let sampleEntries: [CreateEntryDraft]
        let completedStoryboards: [GeneratedStoryboard]
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

        guard let data = image.storytopiaPreparedJPEGData(compressionQuality: 0.86) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(for: entry), options: [.atomic])
        } catch {
            print("[Storytopia] Entry thumbnail cache write failed: \(error.localizedDescription)")
        }
    }

    private static var cacheDirectory: URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Storytopia", isDirectory: true)
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

    private let thumbnailRendererVersion = 12
    private let thumbnailRendererVersionKey = "StorytopiaEntryThumbnailRendererVersion"

    @State private var showsPrototypeData = true
    @State private var entries: [CreateEntryDraft] = []
    @State private var sampleEntries: [CreateEntryDraft] = []
    @State private var completedStoryboards: [GeneratedStoryboard] = []
    @State private var cloudStoryboardClientIDs: Set<UUID> = []
    @State private var failedCloudStoryboardClientIDs: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var entryBeingRenamed: CreateEntryDraft?
    @State private var renamedEntryTitle = ""
    @State private var sampleEntryBeingPreviewed: CreateEntryDraft?
    @State private var entriesPendingDeletion: [EntryDisplayItem] = []
    @State private var entryDeleteErrorMessage: String?
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
    @State private var cloudEntries: [JournalEntry] = []
    @State private var cloudEntryCounts: JournalEntrySummaryCounts?
    @State private var cloudEntryThumbnails: [UUID: UIImage] = [:]
    @State private var cloudEntryThumbnailVersions: [UUID: String] = [:]
    @State private var isLoadingCloudEntries = false
    @State private var isLoadingMoreCloudEntries = false
    @State private var hasMoreCloudEntries = true
    @State private var nextCloudEntryOffset = 0
    @State private var cloudEntriesErrorMessage: String?
    @State private var openingEntryPreview: EntryOpeningPreview?
    @State private var isFinishingEntryOpening = false
    @State private var hasLoadedEntriesForSession = false
    @State private var loadedEntryQueryKey: EntriesCloudFetchCache.EntryQueryKey?
    @State private var entryThumbnailBackfillTask: Task<Void, Never>?
    @State private var cloudEntryThumbnailBackfillTask: Task<Void, Never>?
    @State private var completedStoryboardLoadTask: Task<Void, Never>?
    @State private var cloudThumbnailIDsBeingLoaded: Set<UUID> = []
    private let cloudEntriesPageSize = 30
    @AppStorage("StorytopiaSelectedEntryLayout") private var selectedEntryLayoutRawValue = JournalEntryLayout.grid.rawValue
    @AppStorage("StorytopiaSelectedEntriesTab") private var selectedEntryTabRawValue = EntriesTab.all.rawValue
    @AppStorage("StorytopiaSelectedEntrySort") private var selectedEntrySortRawValue = EntrySortOption.entryDate.rawValue

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
            EntrySortOption(rawValue: selectedEntrySortRawValue) ?? .entryDate
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
    }

    private var entriesScreenWithPresentation: some View {
        entriesScreenWithLifecycle
            .sheet(item: $sampleEntryBeingPreviewed) { entry in
                EntrySamplePreview(entry: entry)
            }
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
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(Color.homePageBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
            .onChange(of: selectedEntryTabRawValue) { _ in
                refreshEntries()
            }
            .onChange(of: selectedEntrySortRawValue) { _ in
                refreshEntries()
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
            Color.homePageBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                header
                    .padding(.horizontal, 16)

                tabSwitcher
                    .padding(.horizontal, 16)

                layoutSwitcherRow
                    .padding(.horizontal, 16)

                cloudEntriesNotice

                if selectedEntryLayout == .list {
                    entryList
                } else if selectedEntryTab == .completed {
                    completedEntryGrid
                } else {
                    entryGrid
                }
            }

            BottomNavigationBar(selectedPage: $selectedPage)

            bottomPrototypeNotice

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

    private var addSelectedEntriesToJournalDestination: some View {
        AddEntryToJournalPage(
            selectedJournalTitle: $selectedEntriesJournalTitle,
            selectedJournalTitles: $selectedEntriesJournalTitles,
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

    private func handleSelectedPageChange(_ newPage: StoryPage) {
        if newPage != .entries {
            dismissAnyKeyboard()
            openingEntryPreview = nil
            isFinishingEntryOpening = false
        }

        if newPage == .entries {
            if let activeDraftID {
                handleReturnToEntriesFromEditedDraft(activeDraftID)
            } else {
                loadEntriesForCurrentPageIfNeeded()
            }
        }
    }

    private func handleReturnToEntriesFromEditedDraft(_ draftID: UUID) {
        if let draft = CreateEntryDraftStore.load(id: draftID) {
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

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text("Entries")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            Button(editMode == .active ? "Done" : "Select") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if editMode == .active {
                        editMode = .inactive
                        selectedEntryIDs = []
                    } else {
                        editMode = .active
                    }
                }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.homeAccent)
            .disabled(showsSampleEntries)

            entryRefreshButton

            entryCreateButton
        }
        .padding(.top, 12)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(EntriesTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedEntryTab = tab
                    }
                } label: {
                    Text(tabTitle(for: tab))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(selectedEntryTab == tab ? Color.white : Color.storyInk.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            Group {
                                if selectedEntryTab == tab {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.homeAccent)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedEntryTab == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .padding(.top, 2)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
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

    private var entryLayoutSwitcher: some View {
        HStack(spacing: 4) {
            entryLayoutButton(.grid)
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

    private func tabTitle(for tab: EntriesTab) -> String {
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
            }
        }

        switch tab {
        case .all:
            return authStore.userID == nil ? mergedEntryItems.count : cloudEntryCounts?.all ?? mergedEntryItems.count
        case .drafts:
            return authStore.userID == nil ? draftEntryItems.count : cloudEntryCounts?.drafts ?? draftEntryItems.count
        case .completed:
            return authStore.userID == nil ? completedEntryItems.count : cloudEntryCounts?.completed ?? completedEntryItems.count
        }
    }

    private var entryCreateButton: some View {
        Button {
            isOpeningEntryFromEntries = false
            isOpeningCompletedEntryFromEntries = false
            completedEntryOpenedStoryboardImage = nil
            activeDraftID = nil
            selectedPage = .create
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.storyInk)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create a new entry")
    }

    private var entryRefreshButton: some View {
        Button {
            refreshEntriesFromCloud()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isLoadingCloudEntries ? Color.homeMutedText.opacity(0.5) : Color.homeAccent)
                .frame(width: 34, height: 34)
                .rotationEffect(.degrees(isLoadingCloudEntries ? 180 : 0))
                .animation(.easeInOut(duration: 0.22), value: isLoadingCloudEntries)
        }
        .buttonStyle(.plain)
        .disabled(authStore.userID == nil || isLoadingCloudEntries || isLoadingMoreCloudEntries)
        .accessibilityLabel("Refresh entries from Storytopia cloud")
    }

    @ViewBuilder
    private var selectedEntriesToolbar: some View {
        if editMode == .active && !showsSampleEntries && !selectedEntryIDs.isEmpty {
            HStack(spacing: 12) {
                Text("\(selectedEntryIDs.count) selected")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Button(role: .destructive) {
                    requestDeleteSelectedEntries()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.red)
                        .frame(width: 38, height: 38)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete selected entries")

                Button {
                    openAddSelectedEntriesToJournalPage()
                } label: {
                    Label("Add to Journal", systemImage: "book.closed.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
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

    @ViewBuilder
    private var bottomPrototypeNotice: some View {
        if showsSampleEntries {
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

            Text("Previewing sample entries")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)

            Spacer()

            Button("Show Empty") {
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

    private var entryList: some View {
        List {
            Section {
                if showsCloudLoadingPlaceholder {
                    entryLoadingRows
                } else if filteredEntryItems.isEmpty {
                    emptyEntriesState
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    entryRows
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.homePageBackground)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 104)
        }
        .refreshable {
            refreshEntriesFromCloud()
        }
    }

    @ViewBuilder
    private var entryRows: some View {
        if showsSampleEntries {
            ForEach(filteredEntries) { entry in
                let category = categoryForSampleEntry(entry)

                Button {
                    sampleEntryBeingPreviewed = entry
                } label: {
                    EntryListRow(
                        entry: entry,
                        sortOption: selectedEntrySort,
                        category: category,
                        completedStoryboardImage: category == .completed
                            ? .failed
                            : nil
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: JournalChapterListMetrics.horizontalInset,
                    bottom: 0,
                    trailing: JournalChapterListMetrics.trailingInset
                ))
                .listRowBackground(Color.homePageBackground)
            }
        } else {
            ForEach(Array(filteredEntryItems.enumerated()), id: \.element.id) { index, item in
                let displayEntry = entryForDisplay(item)
                let isCompleted = isCompletedEntryItem(item)
                let completedFallbackIndex = completedStoryboardFallbackIndex(for: item)

                Button {
                    if editMode == .active {
                        toggleEntrySelection(item.id)
                    } else {
                        openEntryItem(
                            item,
                            asCompleted: isCompleted,
                            storyboardImage: isCompleted ? storyboardUIImage(for: item, fallbackIndex: completedFallbackIndex) : nil
                        )
                    }
                } label: {
                    EntryListRow(
                        entry: displayEntry,
                        sortOption: selectedEntrySort,
                        category: categoryForEntryItem(item),
                        completedStoryboardImage: isCompleted ? storyboardImage(for: item, fallbackIndex: completedFallbackIndex) : nil,
                        isSelecting: editMode == .active,
                        isSelected: selectedEntryIDs.contains(item.id)
                    )
                        .opacity(openingEntryPreview?.id == item.id ? 0.58 : 1)
                }
                .buttonStyle(.plain)
                .disabled(openingEntryPreview != nil)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: JournalChapterListMetrics.horizontalInset,
                    bottom: 0,
                    trailing: JournalChapterListMetrics.trailingInset
                ))
                .listRowBackground(Color.homePageBackground)
                .onAppear {
                    loadMoreCloudEntriesIfNeeded(currentIndex: index, totalCount: filteredEntryItems.count)
                    loadCloudThumbnailIfNeeded(for: item)
                }
                .onDrag {
                    draggingEntryID = item.id
                    return NSItemProvider(object: item.id.uuidString as NSString)
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

            if isLoadingMoreCloudEntries {
                EntryListLoadingRow()
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: JournalChapterListMetrics.horizontalInset,
                        bottom: 0,
                        trailing: JournalChapterListMetrics.trailingInset
                    ))
                    .listRowBackground(Color.homePageBackground)
            }
        }
    }

    @ViewBuilder
    private var entryLoadingRows: some View {
        ForEach(0..<4, id: \.self) { _ in
            EntryListLoadingRow()
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: JournalChapterListMetrics.horizontalInset,
                    bottom: 0,
                    trailing: JournalChapterListMetrics.trailingInset
                ))
                .listRowBackground(Color.homePageBackground)
        }
    }

    private var entryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showsCloudLoadingPlaceholder {
                    entryGridLoadingPlaceholders
                } else if filteredEntryItems.isEmpty {
                    emptyEntriesState
                        .padding(.horizontal, 16)
                } else {
                    LazyVGrid(columns: entryGridColumns, spacing: 14) {
                        if showsSampleEntries {
                            ForEach(filteredEntries) { entry in
                                sampleEntryGridCard(for: entry)
                            }
                        } else {
                            ForEach(Array(filteredEntryItems.enumerated()), id: \.element.id) { index, item in
                                let displayEntry = entryForDisplay(item)

                                entryGridCard(for: item, displayEntry: displayEntry)
                                    .onAppear {
                                        loadMoreCloudEntriesIfNeeded(currentIndex: index, totalCount: filteredEntryItems.count)
                                        loadCloudThumbnailIfNeeded(for: item)
                                    }
                                    .onDrag {
                                        draggingEntryID = item.id
                                        return NSItemProvider(object: item.id.uuidString as NSString)
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
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)
        }
        .background(Color.homePageBackground)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 104)
        }
        .refreshable {
            refreshEntriesFromCloud()
        }
    }

    private var entryGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }

    private var completedEntryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showsCloudLoadingPlaceholder {
                    entryGridLoadingPlaceholders
                } else if completedEntryItems.isEmpty {
                    emptyEntriesState
                        .padding(.horizontal, 16)
                } else {
                    LazyVGrid(columns: entryGridColumns, spacing: 14) {
                        ForEach(Array(completedEntryItems.enumerated()), id: \.element.id) { index, item in
                            let displayEntry = entryForDisplay(item)

                            CompletedEntryGridCard(
                                entry: displayEntry,
                                title: entryDisplayTitle(displayEntry),
                                sortOption: selectedEntrySort,
                                storyboardImage: storyboardImage(for: item, fallbackIndex: index),
                                isOpening: openingEntryPreview?.id == item.id,
                                isSelecting: editMode == .active && !showsSampleEntries,
                                isSelected: selectedEntryIDs.contains(item.id),
                                onOpen: {
                                    if editMode == .active {
                                        toggleEntrySelection(item.id)
                                    } else {
                                        openEntryItem(item, asCompleted: true, storyboardImage: storyboardUIImage(for: item, fallbackIndex: index))
                                    }
                                }
                            )
                            .onAppear {
                                loadMoreCloudEntriesIfNeeded(currentIndex: index, totalCount: completedEntryItems.count)
                                loadCloudThumbnailIfNeeded(for: item)
                            }
                            .onDrag {
                                draggingEntryID = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
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
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)
        }
        .background(Color.homePageBackground)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 104)
        }
        .refreshable {
            refreshEntriesFromCloud()
        }
    }

    @ViewBuilder
    private func sampleEntryGridCard(for entry: CreateEntryDraft) -> some View {
        if categoryForSampleEntry(entry) == .completed {
            CompletedEntryGridCard(
                entry: entry,
                title: entryDisplayTitle(entry),
                sortOption: selectedEntrySort,
                storyboardImage: .failed,
                category: categoryForSampleEntry(entry),
                isOpening: false,
                onOpen: {
                    sampleEntryBeingPreviewed = entry
                }
            )
        } else {
            EntryGridPreviewCard(
                entry: entry,
                sortOption: selectedEntrySort,
                isEditing: false,
                showsActions: false,
                title: entryDisplayTitle(entry),
                category: categoryForSampleEntry(entry),
                isOpening: false,
                onOpen: {
                    sampleEntryBeingPreviewed = entry
                },
                onDelete: {},
                onRename: nil
            )
        }
    }

    @ViewBuilder
    private func entryGridCard(for item: EntryDisplayItem, displayEntry: CreateEntryDraft) -> some View {
        if isCompletedEntryItem(item) {
            let fallbackIndex = completedStoryboardFallbackIndex(for: item)

            CompletedEntryGridCard(
                entry: displayEntry,
                title: entryDisplayTitle(displayEntry),
                sortOption: selectedEntrySort,
                storyboardImage: storyboardImage(for: item, fallbackIndex: fallbackIndex),
                category: categoryForEntryItem(item),
                isOpening: openingEntryPreview?.id == item.id,
                isSelecting: editMode == .active && !showsSampleEntries,
                isSelected: selectedEntryIDs.contains(item.id),
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
                }
            )
        } else {
            EntryGridPreviewCard(
                entry: displayEntry,
                sortOption: selectedEntrySort,
                isEditing: false,
                showsActions: !showsSampleEntries,
                title: entryDisplayTitle(displayEntry),
                category: categoryForEntryItem(item),
                isOpening: openingEntryPreview?.id == item.id,
                isSelecting: editMode == .active && !showsSampleEntries,
                isSelected: selectedEntryIDs.contains(item.id),
                onOpen: {
                    if showsSampleEntries {
                        sampleEntryBeingPreviewed = displayEntry
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
                }
            )
        }
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
        guard !sourceEntries.isEmpty else {
            return []
        }

        return Array(sourceEntries.prefix(completedEntryCount(for: sourceEntries.count)))
    }

    private var draftEntries: [CreateEntryDraft] {
        let sourceEntries = showsSampleEntries ? sampleEntries : entries
        let completedIDs = Set(completedEntries.map(\.id))
        return sourceEntries.filter { !completedIDs.contains($0.id) }
    }

    private func completedEntryCount(for entryCount: Int) -> Int {
        min(max(entryCount / 3, 1), 4)
    }

    private func generatedStoryboard(for item: EntryDisplayItem) -> GeneratedStoryboard? {
        completedStoryboards.first { $0.clientEntryID == item.id && $0.isPrimary }
            ?? completedStoryboards.first { $0.clientEntryID == item.id }
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
        switch selectedEntryTab {
        case .all:
            return showsSampleEntries ? sampleEntries : entries
        case .drafts:
            return draftEntries
        case .completed:
            return completedEntries
        }
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
        selectedEntriesJournalTitles = []
        selectedEntriesJournalTitle = nil

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
        selectedEntryIDs = []
        editMode = .inactive
        refreshEntries(forceCloudReload: true)
    }

    private func requestDeleteSelectedEntries() {
        requestDeleteEntries(selectedEntryItems)
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
            print("[Storytopia] Could not refresh journals before adding selected entries.")
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
        authStore.userID != nil
            && entries.isEmpty
            && cloudEntries.isEmpty
            && !isLoadingCloudEntries
            && cloudEntriesErrorMessage == nil
            && showsPrototypeData
            && !sampleEntries.isEmpty
    }

    private var showsCloudLoadingPlaceholder: Bool {
        isLoadingCloudEntries
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

        return "Are you sure you want to delete these entries? This can't be undone."
    }

    private func requestDeleteEntry(_ entry: EntryDisplayItem) {
        entriesPendingDeletion = [entry]
        entryDeleteErrorMessage = nil
    }

    private func requestDeleteEntries(_ entries: [EntryDisplayItem]) {
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
            entryDeleteErrorMessage = "Could not delete from Storytopia cloud. Check your connection and try again."
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
            thumbnail: entryThumbnail
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
                entryRenameErrorMessage = "Saved locally. Could not sync the title to Storytopia cloud."
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

        applyManualEntryOrder(orderedIDs)

        if authStore.userID == nil {
            CreateEntryDraftStore.saveOrder(entries.map(\.id))
        } else {
            persistManualCloudEntryOrder()
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

        scheduleEntryThumbnailBackfill()
        scheduleCloudEntryThumbnailBackfill()
        guard !EntriesCloudFetchCache.hasFreshEntrySummaries(for: queryKey) else {
            Task {
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
        completedStoryboards = snapshot.completedStoryboards
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
                completedStoryboards: completedStoryboards,
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
        hasLoadedEntriesForSession = false
        loadedEntryQueryKey = nil
        cloudThumbnailIDsBeingLoaded = []
        cloudEntryThumbnailVersions = [:]
    }

    private func refreshEntriesFromCloud() {
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

    private func cancelThumbnailBackfills() {
        entryThumbnailBackfillTask?.cancel()
        entryThumbnailBackfillTask = nil
        cloudEntryThumbnailBackfillTask?.cancel()
        cloudEntryThumbnailBackfillTask = nil
        completedStoryboardLoadTask?.cancel()
        completedStoryboardLoadTask = nil
    }

    private func refreshEntries(forceCloudReload: Bool = false) {
        guard let userID = authStore.userID else {
            resetEntriesSessionState()
            entries = []
            sampleEntries = []
            completedStoryboards = []
            cloudEntries = []
            cloudEntryCounts = nil
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
            return
        }

        let queryKey = currentEntryQueryKey(userID: userID)
        hasLoadedEntriesForSession = true
        loadedEntryQueryKey = queryKey

        entries = []
        completedStoryboards = GeneratedStoryboardStore.load()
        scheduleCompletedStoryboardLoad()
        if entries.isEmpty && showsPrototypeData && sampleEntries.isEmpty {
            sampleEntries = EntriesSampleData.entries()
        }
        scheduleEntryThumbnailBackfill()
        scheduleCloudEntryThumbnailBackfill()
        isDraftSaved = false
        storeCurrentEntriesSessionSnapshot()

        if forceCloudReload {
            cloudEntryThumbnails = [:]
            cloudEntryThumbnailVersions = [:]
        }

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

        if !forceReload, let cachedEntries = EntriesCloudFetchCache.entrySummaries(for: queryKey) {
            if cloudEntries != cachedEntries.entries {
                cloudEntries = cachedEntries.entries
            }
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

        guard forceReload || EntriesCloudFetchCache.shouldLoadStoryboards(for: userID) else {
            return
        }

        guard !completedEntryItems.isEmpty else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            EntriesCloudFetchCache.markStoryboardsLoaded(for: userID)
            storeCurrentEntriesSessionSnapshot()
            return
        }

        do {
            let primaryRows = try await SupabaseStoryboardService().loadPrimaryCompletedStoryboards()
            let completedEntryIDs = Set(completedEntryItems.map(\.id))
            let localStoryboardIDs = Set(completedStoryboards.map(\.id))
            var rowsToDownload = primaryRows.filter {
                completedEntryIDs.contains($0.clientEntryID) && !localStoryboardIDs.contains($0.id)
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
            EntriesCloudFetchCache.markStoryboardsLoaded(for: userID)

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
        if let localDraftID = item.localDraftID {
            return localDraftID
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
                print("[Storytopia] Entry character download skipped: \(error.localizedDescription)")
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
            thumbnail: entry.thumbnail
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

    private func loadCloudThumbnailIfNeeded(for item: EntryDisplayItem) {
        guard
            let cloudEntry = item.cloudEntry,
            cloudEntryThumbnails[item.id] == nil,
            !cloudThumbnailIDsBeingLoaded.contains(item.id)
        else {
            return
        }

        cloudThumbnailIDsBeingLoaded.insert(item.id)
        Task {
            defer {
                cloudThumbnailIDsBeingLoaded.remove(item.id)
            }

            guard let thumbnailStoragePath = cloudEntry.thumbnailStoragePath else {
                await renderLocalCloudThumbnail(for: cloudEntry)
                return
            }

            do {
                let thumbnail = try await SupabaseEntryThumbnailService().downloadThumbnail(
                    storagePath: thumbnailStoragePath,
                    bypassCache: true
                )
                cloudEntryThumbnails[item.id] = thumbnail
                cloudEntryThumbnailVersions[item.id] = cloudThumbnailVersion(for: cloudEntry)
                EntriesCloudThumbnailDiskCache.store(thumbnail, for: cloudEntry)
                storeCurrentEntriesSessionSnapshot()
            } catch {
                await renderLocalCloudThumbnail(for: cloudEntry)
            }
        }
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
                GeneratedStoryboardStore.load()
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
}

private enum EntriesSampleData {
    private struct Sample {
        let id: String
        let title: String
        let text: String
        let daysAgo: Int
        let location: String
        let paperStyleRawValue: String
        let paperColorIndex: Int
        let textColorIndex: Int
        let textSize: Double
    }

    @MainActor
    static func entries() -> [CreateEntryDraft] {
        samples.enumerated().map { index, sample in
            let date = Calendar.current.date(byAdding: .day, value: -sample.daysAgo, to: Date()) ?? Date()
            let thumbnail = DraftThumbnailRenderer.render(
                title: sample.title,
                text: sample.text,
                richText: NotebookRichTextDocument(text: sample.text),
                photos: [],
                fontChoiceRawValue: nil,
                textColorIndex: sample.textColorIndex,
                textSize: sample.textSize,
                paperStyleRawValue: sample.paperStyleRawValue,
                paperColorIndex: sample.paperColorIndex,
                isBold: false,
                isItalic: index == 5,
                isUnderlined: false,
                isStrikethrough: false,
                isHighlighted: index == 1,
                textAlignmentRawValue: "leading"
            )

            return CreateEntryDraft(
                id: UUID(uuidString: sample.id) ?? UUID(),
                title: sample.title,
                text: sample.text,
                richText: NotebookRichTextDocument(text: sample.text),
                photos: [],
                artStyle: "Cozy Storybook",
                location: sample.location,
                date: date,
                datePrecision: .exact,
                savesDraft: true,
                isPrivate: index == 3,
                status: JournalEntryStatus.draft.rawValue,
                fontChoiceRawValue: nil,
                textColorIndex: sample.textColorIndex,
                textSize: sample.textSize,
                paperStyleRawValue: sample.paperStyleRawValue,
                paperColorIndex: sample.paperColorIndex,
                isBold: false,
                isItalic: index == 5,
                isUnderlined: false,
                isStrikethrough: false,
                isHighlighted: index == 1,
                textAlignmentRawValue: "leading",
                thumbnail: thumbnail,
                createdAt: date,
                updatedAt: date,
                displayOrder: index
            )
        }
    }

    private static let samples: [Sample] = [
        Sample(
            id: "10000000-0000-0000-0000-000000000001",
            title: "Morning Light",
            text: "The kitchen was quiet except for the kettle. I watched the first strip of sun reach the table and felt like the whole day was waiting politely.",
            daysAgo: 0,
            location: "Home",
            paperStyleRawValue: "collegeRuled",
            paperColorIndex: 1,
            textColorIndex: 1,
            textSize: 18
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000002",
            title: "Tiny Win",
            text: "Finished the thing I kept avoiding. It only took twenty minutes, which is both hilarious and a little rude.",
            daysAgo: 1,
            location: "Desk",
            paperStyleRawValue: "blank",
            paperColorIndex: 4,
            textColorIndex: 4,
            textSize: 20
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000003",
            title: "Rain Walk",
            text: "Took the long way home after lunch. The sidewalks were shiny, the trees smelled awake, and nobody seemed in a rush.",
            daysAgo: 2,
            location: "Maple Street",
            paperStyleRawValue: "watercolorPaper",
            paperColorIndex: 0,
            textColorIndex: 2,
            textSize: 18
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000004",
            title: "What I Needed",
            text: "A slow dinner, a charged phone left in another room, and a conversation that did not try to solve anything.",
            daysAgo: 3,
            location: "West Village",
            paperStyleRawValue: "cottonPaper",
            paperColorIndex: 0,
            textColorIndex: 6,
            textSize: 19
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000005",
            title: "Saturday Errands",
            text: "Bought flowers, returned the library book, remembered batteries, forgot basil. The list was almost victorious.",
            daysAgo: 5,
            location: "Downtown",
            paperStyleRawValue: "blank",
            paperColorIndex: 5,
            textColorIndex: 8,
            textSize: 18
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000006",
            title: "A Line to Keep",
            text: "There are days that do not announce themselves as important until later. Today had that quiet shimmer.",
            daysAgo: 7,
            location: "Park Bench",
            paperStyleRawValue: "recycledPaper",
            paperColorIndex: 0,
            textColorIndex: 5,
            textSize: 21
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000007",
            title: "Coffee Notes",
            text: "The cafe playlist was all old soul songs. I wrote three messy ideas and one good sentence.",
            daysAgo: 9,
            location: "Corner Cafe",
            paperStyleRawValue: "collegeRuled",
            paperColorIndex: 2,
            textColorIndex: 3,
            textSize: 18
        ),
        Sample(
            id: "10000000-0000-0000-0000-000000000008",
            title: "Before Sleep",
            text: "Grateful for clean sheets, a book with short chapters, and the particular relief of putting tomorrow down for a while.",
            daysAgo: 12,
            location: "Bedroom",
            paperStyleRawValue: "blank",
            paperColorIndex: 6,
            textColorIndex: 7,
            textSize: 19
        )
    ]
}

private struct EntrySamplePreview: View {
    let entry: CreateEntryDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewImage

                    VStack(alignment: .leading, spacing: 8) {
                        Text(entryDisplayTitle(entry))
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(Color.storyInk)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))

                            if !entry.location.isEmpty {
                                Text("•")
                                Text(entry.location)
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                    }

                    Text(entry.text)
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .lineSpacing(5)
                        .foregroundStyle(Color.storyInk)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.homeBorder, lineWidth: 1)
                        )
                }
                .padding(18)
            }
            .background(Color.homePageBackground.ignoresSafeArea())
            .navigationTitle("Sample Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
                }
            }
        }
        .onDisappear {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .endEditing(true)
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var previewImage: some View {
        if let thumbnail = entry.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.storyInk.opacity(0.09), radius: 9, y: 5)
        }
    }
}

private struct EntryListRow: View {
    let entry: CreateEntryDraft
    let sortOption: EntrySortOption
    var category: EntriesTab?
    var completedStoryboardImage: CompletedStoryboardImage?
    var isSelecting = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.storyPurple : Color.homeBorder)
                    .frame(width: 22, height: 22)
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

            VStack(alignment: .trailing, spacing: 2) {
                Text(entryDateDisplay.label)
                    .font(.system(size: 10, weight: .bold))

                Text(entryDateDisplay.dateText)
                    .font(.system(size: 12, weight: .regular))
            }
            .foregroundStyle(Color.homeMutedText)
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: JournalChapterListMetrics.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("\(entryDisplayTitle(entry)), \(entryDateDisplay.inlineText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var entryIcon: some View {
        Group {
            if let completedStoryboardImage {
                storyboardThumbnail(completedStoryboardImage)
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
            width: JournalChapterListMetrics.coverWidth,
            height: JournalChapterListMetrics.coverHeight
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

private struct EntrySelectionBadge: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 23, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(isSelected ? Color.white : Color.homeBorder, isSelected ? Color.storyPurple : Color.white)
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.9), in: Circle())
            .shadow(color: Color.storyInk.opacity(0.14), radius: 5, y: 2)
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

    var body: some View {
        Text(entryPreviewDateText(entry, sortOption: sortOption))
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
    let isEditing: Bool
    let showsActions: Bool
    let title: String
    var category: EntriesTab?
    var isOpening = false
    var isSelecting = false
    var isSelected = false
    let onOpen: () -> Void
    let onDelete: () -> Void
    var onRename: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                previewImage
                    .aspectRatio(260.0 / 340.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: Color.storyInk.opacity(0.09), radius: 9, y: 5)
                    .overlay(alignment: .top) {
                        StoryPhotoTape(width: 48, height: 14, rotation: -2)
                            .offset(y: -7)
                    }

                if isEditing {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.red.opacity(0.92), in: Circle())
                            .shadow(color: Color.storyInk.opacity(0.16), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Delete \(title)")
                }

                if isSelecting {
                    EntrySelectionBadge(isSelected: isSelected)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let category {
                    EntryCategoryPill(category: category)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }

            EntryPreviewDateBlock(entry: entry, sortOption: sortOption)
        }
        .contentShape(Rectangle())
        .scaleEffect(isOpening ? 0.96 : 1)
        .opacity(isOpening ? 0.62 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isOpening)
        .onTapGesture {
            onOpen()
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
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(entryPreviewDateText(entry, sortOption: sortOption))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var previewImage: some View {
        if let thumbnail = entry.thumbnail {
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
    let storyboardImage: CompletedStoryboardImage
    let category: EntriesTab?
    let isOpening: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onOpen: () -> Void
    let accessibilityLabel: String

    init(
        entry: CreateEntryDraft,
        title: String,
        sortOption: EntrySortOption,
        storyboardImage: CompletedStoryboardImage,
        category: EntriesTab? = nil,
        isOpening: Bool = false,
        isSelecting: Bool = false,
        isSelected: Bool = false,
        onOpen: @escaping () -> Void
    ) {
        self.entry = entry
        self.title = title
        self.sortOption = sortOption
        self.storyboardImage = storyboardImage
        self.category = category
        self.isOpening = isOpening
        self.isSelecting = isSelecting
        self.isSelected = isSelected
        self.onOpen = onOpen
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

                    if isSelecting {
                        EntrySelectionBadge(isSelected: isSelected)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .zIndex(3)
                    }
                }
            }
                .aspectRatio(260.0 / 340.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .shadow(color: Color.storyInk.opacity(0.09), radius: 9, y: 5)

            EntryPreviewDateBlock(entry: entry, sortOption: sortOption)
        }
        .contentShape(Rectangle())
        .scaleEffect(isOpening ? 0.96 : 1)
        .opacity(isOpening ? 0.62 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isOpening)
        .onTapGesture {
            onOpen()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityLabel), \(entryPreviewDateText(entry, sortOption: sortOption))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var entryPreviewImage: some View {
        if let thumbnail = entry.thumbnail {
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
        }
        .frame(width: overlayWidth, height: overlayHeight)
        .rotationEffect(.degrees(2))
        .shadow(color: Color.storyInk.opacity(0.16), radius: 6, y: 4)
        .position(x: size.width * 0.76, y: size.height * 0.27)
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
        .position(x: size.width * 0.76, y: size.height * 0.27)
    }
}

private enum EntriesTab: String, CaseIterable, Identifiable {
    case all
    case drafts
    case completed

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

    static let menuOptions: [EntrySortOption] = [.manual, .entryDate, .cloudCreated, .updated]

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
    static let rowHeight: CGFloat = 50
    static let horizontalInset: CGFloat = 16
    static let trailingInset: CGFloat = 12
    static let coverWidth: CGFloat = 26
    static let coverHeight: CGFloat = 34
}

private struct JournalChapterListRow: View {
    let chapter: PrototypeChapter
    let coverImage: UIImage?
    let remoteCoverURL: URL?
    let fallbackImageName: String?

    var body: some View {
        HStack(spacing: 10) {
            JournalListCover(
                color: chapter.color,
                coverImage: coverImage,
                remoteCoverURL: remoteCoverURL,
                fallbackImageName: fallbackImageName,
                width: JournalChapterListMetrics.coverWidth,
                height: JournalChapterListMetrics.coverHeight
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(chapter.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.storyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    if chapter.isSystemJournal {
                        SystemJournalBadge(style: .list)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Text("\(chapter.entries.count) \(chapter.entries.count == 1 ? "entry" : "entries")")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .frame(height: JournalChapterListMetrics.rowHeight)
        .accessibilityLabel(chapter.title)
        .accessibilityHint(chapter.isSystemJournal ? "Built-in journals can't be moved or deleted." : "")
    }
}

private struct SystemJournalBadge: View {
    enum Style {
        case cover
        case list
    }

    let style: Style

    var body: some View {
        HStack(spacing: iconTextSpacing) {
            Image(systemName: "shield.fill")

            Text("System")
        }
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(backgroundColor, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("System journal")
    }

    private var iconTextSpacing: CGFloat {
        switch style {
        case .cover:
            return 2
        case .list:
            return 3
        }
    }

    private var fontSize: CGFloat {
        switch style {
        case .cover:
            return 8
        case .list:
            return 10
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .cover:
            return 5
        case .list:
            return 7
        }
    }

    private var height: CGFloat {
        switch style {
        case .cover:
            return 16
        case .list:
            return 20
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .cover:
            return Color.white
        case .list:
            return Color.storyInk
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .cover:
            return Color.black.opacity(0.36)
        case .list:
            return Color.homeAccent.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch style {
        case .cover:
            return Color.white.opacity(0.26)
        case .list:
            return Color.homeAccent.opacity(0.22)
        }
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
    let symbol: String

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
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 74, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.24))
                }
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
            .overlay(alignment: .topLeading) {
                if chapter.isSystemJournal {
                    SystemJournalBadge(style: .cover)
                        .padding(8)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var chapter: PrototypeChapter
    let onCreateStory: (PrototypeEntry) -> Void
    let onNewEntryPresentationChange: (Bool) -> Void
    let onChapterUpdated: (PrototypeChapter) -> Void
    let onOpenExistingEntry: ((CreateEntryDraft, Bool, UIImage?) -> Void)?
    let entryDate: Date
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
    @State private var editMode: EditMode = .inactive
    @State private var draggingEntryID: UUID?
    @State private var isShowingCoverCustomization = false
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

    private var sections: [String] {
        chapter.systemJournal == .drafts ? ["Pages"] : ["Pages", "Media"]
    }

    private static func initialSection(for chapter: PrototypeChapter, presentation: Presentation) -> String {
        chapter.systemJournal == .drafts || presentation == .dailyJournal ? "Pages" : "Media"
    }

    private var mediaImageNames: [String] {
        chapter.entries.flatMap(\.imageNames)
    }

    private var mediaLoadID: String {
        let entryIDs = chapter.entries.map(\.id.uuidString).sorted().joined(separator: ",")
        return "\(chapter.id.uuidString)-\(entryIDs)-\(authStore.userID?.uuidString ?? "local")"
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
        if let storedCoverImage = customization.storedCoverImage {
            JournalCoverStore.save(storedCoverImage, for: chapter.coverStorageKey)
        } else if customization.clearsStoredCover {
            JournalCoverStore.delete(key: chapter.coverStorageKey)
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
            systemJournal: chapter.systemJournal,
            entries: chapter.entries
        )

        chapter = updatedChapter
        onChapterUpdated(updatedChapter)
        if let systemJournal = updatedChapter.systemJournal {
            SystemJournalAppearanceStore.update(
                systemJournal,
                color: updatedChapter.color,
                coverImageName: updatedChapter.coverImageName,
                remoteCover: updatedChapter.remoteCover
            )
            SystemJournalAppearanceStore.syncToCloud(
                updatedChapter,
                storedCoverImage: customization.storedCoverImage
            )
        } else {
            UserChapterStore.updateAppearance(
                id: updatedChapter.id,
                color: updatedChapter.color,
                coverImageName: updatedChapter.coverImageName,
                remoteCover: updatedChapter.remoteCover
            )
            UserChapterStore.syncToCloud(updatedChapter)
            if let storedCoverImage = customization.storedCoverImage {
                UserChapterStore.uploadCoverToCloud(storedCoverImage, journalID: updatedChapter.id)
            } else if customization.clearsStoredCover {
                UserChapterStore.clearCoverInCloud(journalID: updatedChapter.id)
            }
        }
        isShowingCoverCustomization = false
    }

    init(
        chapter: PrototypeChapter,
        entryDate: Date = Date(),
        presentation: Presentation = .story,
        onNewEntryPresentationChange: @escaping (Bool) -> Void = { _ in },
        onChapterUpdated: @escaping (PrototypeChapter) -> Void = { _ in },
        onOpenExistingEntry: ((CreateEntryDraft, Bool, UIImage?) -> Void)? = nil,
        onCreateStory: @escaping (PrototypeEntry) -> Void
    ) {
        _chapter = State(initialValue: chapter)
        _selectedSection = State(initialValue: Self.initialSection(for: chapter, presentation: presentation))
        self.entryDate = entryDate
        self.presentation = presentation
        self.onNewEntryPresentationChange = onNewEntryPresentationChange
        self.onChapterUpdated = onChapterUpdated
        self.onOpenExistingEntry = onOpenExistingEntry
        self.onCreateStory = onCreateStory
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                Color.homePageBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            journalHeroHeader(toolbarBottomOffset: proxy.safeAreaInsets.top + 44)

                            VStack(alignment: .leading, spacing: 16) {
                                sectionPicker

                                if selectedSection == "Pages" {
                                    entriesList
                                } else {
                                    mediaGrid
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 112)
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                }

                journalDetailFloatingWriteButton
                    .padding(.trailing, 20)
                    .padding(.bottom, 22)
                    .zIndex(2)
            }
        }
        .preferredColorScheme(.light)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.homeAccent)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
                    .opacity(chapter.systemJournal == .completed ? 0 : 1)
                    .disabled(chapter.systemJournal == .completed)
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
                dismissCreate: {
                    isShowingNewStory = false
                },
                onJournalEntryCreated: { _, entry in
                    if let existingIndex = chapter.entries.firstIndex(where: { $0.id == entry.id }) {
                        chapter.entries[existingIndex] = entry
                    } else {
                        chapter.entries.insert(entry, at: 0)
                    }
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
            if !isShowing {
                Task {
                    await loadMediaStoryboards()
                }
            }
        }
        .onChange(of: selectedSection) { newSection in
            if newSection != "Pages" {
                editMode = .inactive
                draggingEntryID = nil
            }
        }
        .onChange(of: isComicReaderPresented) { isPresented in
            if !isPresented {
                bookNavigationOpenProgress = 0
                isOpeningJournalComicReader = false
            }
        }
        .task(id: mediaLoadID) {
            await loadMediaStoryboards()
        }
        .navigationDestination(isPresented: $isComicReaderPresented) {
            JournalStoryboardComicReaderView(
                storyboards: mediaStoryboards,
                currentPageIndex: $comicPageIndex
            )
        }
        .onAppear {
            guard !skipsBookOpenHintOnNextAppear else {
                skipsBookOpenHintOnNextAppear = false
                return
            }

            playBookOpenHint()
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
               mediaStoryboards.indices.contains(selectedMediaIndex) {
                StoryboardImageViewer(
                    storyboards: mediaStoryboards,
                    initialIndex: selectedMediaIndex
                )
            }
        }
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

        if chapter.systemJournal == .drafts {
            return .compose
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
        comicPageIndex = min(max(comicPageIndex, 0), max(0, mediaStoryboards.count - 1))

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
            .padding(.bottom, 14)
    }

    private func heroBanner(toolbarBottomOffset: CGFloat) -> some View {
        let bannerHeight: CGFloat = 276
        let coverTopOffset = min(bannerHeight - 58, toolbarBottomOffset + 94)
        let bannerTitleCenterY = max(112, coverTopOffset - 52)
        let coverOverlap = max(0, bannerHeight - coverTopOffset)
        let coverWidth = min(UIScreen.main.bounds.width * 0.49, 188)

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                JournalDetailBannerBackground(
                    color: chapter.color,
                    coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter.coverStorageKey) : nil,
                    remoteCoverURL: chapter.remoteCover?.imageNSURL ?? chapter.remoteCover?.thumbnailNSURL,
                    fallbackImageName: chapter.coverImageName,
                    symbol: chapter.symbol
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.62),
                        Color.black.opacity(0.44),
                        Color.black.opacity(0.16),
                        Color.black.opacity(0.04)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

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
                    .position(x: bannerProxy.size.width / 2, y: bannerTitleCenterY)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bannerHeight, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                isShowingCoverCustomization = true
            }
            .accessibilityLabel("Change journal cover")

            VStack(alignment: .center, spacing: 14) {
                Button {
                    openJournalComicReader()
                } label: {
                    JournalDetailCoverImage(
                        chapter: chapter,
                        coverImage: chapter.remoteCover == nil ? JournalCoverStore.image(for: chapter.coverStorageKey) : nil,
                        remoteCoverURL: chapter.remoteCover?.thumbnailNSURL ?? chapter.remoteCover?.imageNSURL,
                        fallbackImageName: chapter.coverImageName,
                        openHintProgress: bookOpenHintProgress,
                        navigationOpenProgress: bookNavigationOpenProgress
                    )
                    .frame(
                        width: coverWidth,
                        height: coverWidth / JournalOpeningBook.compactAspectRatio
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
                    .foregroundStyle(Color.homeAccent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isOpeningJournalComicReader)
                .accessibilityLabel("Tap to open journal comic")
            }
            .padding(.horizontal, 16)
            .padding(.top, 0)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 28,
                    style: .continuous
                )
                .fill(Color.homePageBackground)
                .padding(.top, coverOverlap)
            }
            .offset(y: -coverOverlap)
            .padding(.bottom, -coverOverlap)
        }
    }

    private var journalDetailFloatingWriteButton: some View {
        Button {
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 64)
                .offset(x: 0, y: -2)
                .background(Color.homeAccent, in: Circle())
                .shadow(color: Color.storyInk.opacity(0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write")
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
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedSection = section
                    }
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

    private var entriesList: some View {
        JournalDetailEntryBrowser(
            chapter: chapter,
            allowsCreation: chapter.systemJournal != .completed,
            onCreateEntry: {
                activeDraftID = nil
                isOpeningCompletedEntryFromEntries = false
                completedEntryOpenedStoryboardImage = nil
                isShowingNewStory = true
            },
            onOpenEntry: { entry, isCompleted, storyboardImage in
                if let onOpenExistingEntry {
                    onOpenExistingEntry(entry, isCompleted, storyboardImage)
                } else {
                    activeDraftID = entry.id
                    isOpeningCompletedEntryFromEntries = isCompleted
                    completedEntryOpenedStoryboardImage = storyboardImage
                    isShowingNewStory = true
                }
            },
            onEntriesChanged: { entries in
                chapter.entries = entries
                onChapterUpdated(chapter)
            }
        )
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
        chapter.entries.removeAll { $0.id == entry.id }
        StoryEntryStore.delete(entry, from: chapter.title)
        DeletedSampleEntryStore.add(entry, in: chapter.title)
        persistEntryOrder()
    }

    private func persistEntryOrder() {
        StoryEntryStore.saveStoredOrder(from: chapter.entries, for: chapter.title)
    }

    private var pageCountText: String {
        let pageCount = max(mediaStoryboards.count, chapter.entries.count)
        return "\(pageCount) \(pageCount == 1 ? "page" : "pages")"
    }

    private var mediaCountText: String {
        "\(mediaStoryboards.count) \(mediaStoryboards.count == 1 ? "storyboard" : "storyboards")"
    }

    private var mediaGrid: some View {
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
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(Array(mediaStoryboards.enumerated()), id: \.element.id) { index, storyboard in
                        Button {
                            selectedMediaIndex = index
                        } label: {
                            Image(uiImage: storyboard.image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open storyboard \(index + 1) of \(mediaStoryboards.count)")
                    }
                }
            }
        }
    }

    @MainActor
    private func loadMediaStoryboards() async {
        guard chapter.systemJournal != .drafts else {
            mediaStoryboards = []
            mediaStoryboardErrorMessage = nil
            isLoadingMediaStoryboards = false
            return
        }

        let localClientEntryIDs = mediaClientEntryIDsFromLocalEntries()
        let localStoryboards = storyboardsForMedia(clientEntryIDs: localClientEntryIDs, in: GeneratedStoryboardStore.load())
        mediaStoryboards = localStoryboards
        mediaStoryboardErrorMessage = nil

        guard authStore.userID != nil else {
            isLoadingMediaStoryboards = false
            return
        }

        isLoadingMediaStoryboards = true
        defer { isLoadingMediaStoryboards = false }

        do {
            let cloudClientEntryIDs = try await mediaClientEntryIDsFromCloudEntries()
            let allClientEntryIDs = localClientEntryIDs.union(cloudClientEntryIDs)
            let cloudStoryboards = try await SupabaseStoryboardService().loadStoryboardImages(for: allClientEntryIDs)
            mediaStoryboards = mergedMediaStoryboards(localStoryboards + cloudStoryboards)
        } catch {
            mediaStoryboardErrorMessage = "Could not load cloud storyboards."
        }
    }

    private func mediaClientEntryIDsFromLocalEntries() -> Set<UUID> {
        let localEntries = CreateEntryDraftStore.loadAll()

        switch chapter.systemJournal {
        case .drafts:
            return []
        case .completed:
            return Set(localEntries.filter { $0.status == JournalEntryStatus.completed.rawValue }.map(\.id))
                .union(chapter.entries.map(\.id))
        case nil:
            let storedMemberIDs = Set(StoryEntryStore.clientEntryIDs(for: chapter.title))
            let linkedLocalIDs = localEntries
                .filter { EntryJournalLinkStore.loadJournalTitles(for: $0.id).contains(chapter.title) }
                .map(\.id)
            return storedMemberIDs
                .union(chapter.entries.map(\.id))
                .union(linkedLocalIDs)
        }
    }

    private func mediaClientEntryIDsFromCloudEntries() async throws -> Set<UUID> {
        let repository = SupabaseEntryRepository()
        let entries = try await repository.getEntrySummaries()

        switch chapter.systemJournal {
        case .drafts:
            return []
        case .completed:
            return Set(entries.filter { $0.status == JournalEntryStatus.completed.rawValue }.map(\.clientEntryID))
        case nil:
            let memberships = try await SupabaseJournalRepository().getJournalEntryMemberships()
            return Set(
                memberships
                    .filter { $0.journalID == chapter.id }
                    .map { $0.clientEntryID }
            )
        }
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

    private func mergedMediaStoryboards(_ storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        var seen = Set<UUID>()
        return storyboards
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

private struct JournalDetailEntryBrowser: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore

    let chapter: PrototypeChapter
    let allowsCreation: Bool
    let onCreateEntry: () -> Void
    let onOpenEntry: (CreateEntryDraft, Bool, UIImage?) -> Void
    let onEntriesChanged: ([PrototypeEntry]) -> Void

    @State private var localEntries: [CreateEntryDraft] = []
    @State private var cloudEntries: [JournalEntry] = []
    @State private var completedStoryboards: [GeneratedStoryboard] = []
    @State private var cloudStoryboardClientIDs: Set<UUID> = []
    @State private var failedCloudStoryboardClientIDs: Set<UUID> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("StorytopiaSelectedJournalDetailEntryLayout") private var selectedLayoutRawValue = JournalEntryLayout.grid.rawValue
    @AppStorage("StorytopiaSelectedJournalDetailEntrySort") private var selectedSortRawValue = EntrySortOption.entryDate.rawValue

    private var selectedLayout: JournalEntryLayout {
        get { JournalEntryLayout(rawValue: selectedLayoutRawValue) ?? .grid }
        nonmutating set { selectedLayoutRawValue = newValue.rawValue }
    }

    private var selectedSort: EntrySortOption {
        get { EntrySortOption(rawValue: selectedSortRawValue) ?? .entryDate }
        nonmutating set { selectedSortRawValue = newValue.rawValue }
    }

    private var entryGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14),
            count: selectedLayout.gridColumnCount
        )
    }

    private var filteredItems: [EntryDisplayItem] {
        let cloudByClientID = Dictionary(grouping: cloudEntries, by: \.clientEntryID).compactMapValues(\.first)
        let localItems = localEntries
            .map { EntryDisplayItem.local($0, cloudEntry: cloudByClientID[$0.id]) }
            .filter(matchesChapterFilter)
        let localIDs = Set(localEntries.map(\.id))
        let cloudOnlyItems = cloudEntries
            .filter { !localIDs.contains($0.clientEntryID) }
            .map(EntryDisplayItem.cloud)
            .filter(matchesChapterFilter)

        return (localItems + cloudOnlyItems)
            .filter { $0.status != JournalEntryStatus.archived.rawValue }
            .sorted(by: sortEntryItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlsRow

            if let errorMessage {
                cloudErrorNotice(errorMessage)
            }

            if isLoading && filteredItems.isEmpty {
                loadingGrid
            } else if filteredItems.isEmpty {
                emptyState
            } else if selectedLayout == .list {
                entryList
            } else {
                entryGrid
            }
        }
        .onAppear(perform: refreshEntries)
        .onChange(of: authStore.userID) { _ in
            refreshEntries()
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            sortMenu
            Spacer()
            layoutSwitcher
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(EntrySortOption.menuOptions) { option in
                Button {
                    selectedSort = selectedSort.selection(afterChoosing: option)
                } label: {
                    Label(option.menuTitle, systemImage: selectedSort.menuSystemImage(for: option))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedSort.displaySystemImage)
                    .font(.system(size: 12, weight: .bold))
                Text(selectedSort.shortTitle)
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

    private var entryGrid: some View {
        LazyVGrid(columns: entryGridColumns, spacing: 14) {
            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                let displayEntry = entryForDisplay(item)
                if isCompleted(item) {
                    CompletedEntryGridCard(
                        entry: displayEntry,
                        title: entryDisplayTitle(displayEntry),
                        sortOption: selectedSort,
                        storyboardImage: storyboardImage(for: item, fallbackIndex: index),
                        onOpen: {
                            openItem(item, displayEntry: displayEntry, fallbackIndex: index)
                        }
                    )
                } else {
                    EntryGridPreviewCard(
                        entry: displayEntry,
                        sortOption: selectedSort,
                        isEditing: false,
                        showsActions: false,
                        title: entryDisplayTitle(displayEntry),
                        isOpening: false,
                        onOpen: {
                            openItem(item, displayEntry: displayEntry, fallbackIndex: index)
                        },
                        onDelete: {},
                        onRename: nil
                    )
                }
            }
        }
    }

    private var entryList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                let displayEntry = entryForDisplay(item)
                Button {
                    openItem(item, displayEntry: displayEntry, fallbackIndex: index)
                } label: {
                    EntryListRow(
                        entry: displayEntry,
                        sortOption: selectedSort,
                        category: chapter.isSystemJournal ? nil : (isCompleted(item) ? .completed : .drafts),
                        completedStoryboardImage: isCompleted(item) ? storyboardImage(for: item, fallbackIndex: index) : nil
                    )
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
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
        localEntries = CreateEntryDraftStore.loadAll()
        completedStoryboards = GeneratedStoryboardStore.load()
        onEntriesChanged(filteredItems.map { entryForDisplay($0).prototypeEntry() })

        guard authStore.userID != nil else {
            cloudEntries = []
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        Task {
            do {
                let entries = try await SupabaseEntryRepository().getEntrySummaries()
                await MainActor.run {
                    cloudEntries = entries
                    errorMessage = nil
                    isLoading = false
                    onEntriesChanged(filteredItems.map { entryForDisplay($0).prototypeEntry() })
                    loadMissingCompletedStoryboards()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not load cloud entries."
                    isLoading = false
                }
            }
        }
    }

    private func loadMissingCompletedStoryboards() {
        guard authStore.userID != nil else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            return
        }

        let completedClientEntryIDs = Set(filteredItems.filter { isCompleted($0) }.map(\.id))
        let cachedClientEntryIDs = Set(completedStoryboards.compactMap(\.clientEntryID))
        let missingClientEntryIDs = completedClientEntryIDs.subtracting(cachedClientEntryIDs)

        guard !missingClientEntryIDs.isEmpty else {
            cloudStoryboardClientIDs = []
            failedCloudStoryboardClientIDs = []
            return
        }

        cloudStoryboardClientIDs.formUnion(missingClientEntryIDs)
        failedCloudStoryboardClientIDs.subtract(missingClientEntryIDs)

        Task {
            let storyboardService = SupabaseStoryboardService()

            do {
                let rows = try await storyboardService.loadPrimaryCompletedStoryboards()
                let rowsToDownload = rows.filter { missingClientEntryIDs.contains($0.clientEntryID) }
                let rowClientEntryIDs = Set(rowsToDownload.map(\.clientEntryID))
                var downloadedStoryboards: [GeneratedStoryboard] = []
                var failedClientEntryIDs = missingClientEntryIDs.subtracting(rowClientEntryIDs)

                for row in rowsToDownload {
                    do {
                        let image = try await storyboardService.downloadStoryboardImage(storagePath: row.storagePath)
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
                        downloadedStoryboards.append(cachedStoryboard)
                    } catch {
                        failedClientEntryIDs.insert(row.clientEntryID)
                    }
                }

                await MainActor.run {
                    var mergedStoryboards = completedStoryboards
                    for storyboard in downloadedStoryboards {
                        mergedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: mergedStoryboards)
                        if let clientEntryID = storyboard.clientEntryID {
                            cloudStoryboardClientIDs.remove(clientEntryID)
                        }
                    }

                    completedStoryboards = mergedStoryboards
                    GeneratedStoryboardStore.save(mergedStoryboards)
                    cloudStoryboardClientIDs.subtract(failedClientEntryIDs)
                    failedCloudStoryboardClientIDs.formUnion(failedClientEntryIDs)
                    onEntriesChanged(filteredItems.map { entryForDisplay($0).prototypeEntry() })
                }
            } catch {
                await MainActor.run {
                    cloudStoryboardClientIDs.subtract(missingClientEntryIDs)
                    failedCloudStoryboardClientIDs.formUnion(missingClientEntryIDs)
                }
            }
        }
    }

    private func matchesChapterFilter(_ entry: CreateEntryDraft) -> Bool {
        switch chapter.systemJournal {
        case .drafts:
            return entry.status != JournalEntryStatus.completed.rawValue
        case .completed:
            return entry.status == JournalEntryStatus.completed.rawValue
        case nil:
            let memberIDs = Set(StoryEntryStore.clientEntryIDs(for: chapter.title))
            return memberIDs.contains(entry.id) || EntryJournalLinkStore.loadJournalTitles(for: entry.id).contains(chapter.title)
        }
    }

    private func matchesChapterFilter(_ entry: JournalEntry) -> Bool {
        switch chapter.systemJournal {
        case .drafts:
            return entry.status != JournalEntryStatus.completed.rawValue
        case .completed:
            return entry.status == JournalEntryStatus.completed.rawValue
        case nil:
            return Set(StoryEntryStore.clientEntryIDs(for: chapter.title)).contains(entry.clientEntryID)
        }
    }

    private func matchesChapterFilter(_ item: EntryDisplayItem) -> Bool {
        switch chapter.systemJournal {
        case .drafts:
            return item.status != JournalEntryStatus.completed.rawValue
        case .completed:
            return item.status == JournalEntryStatus.completed.rawValue
        case nil:
            return matchesChapterFilter(item.entry)
        }
    }

    private func sortEntryItems(_ lhs: EntryDisplayItem, _ rhs: EntryDisplayItem) -> Bool {
        let lhsDate = sortDate(for: lhs)
        let rhsDate = sortDate(for: rhs)

        if lhsDate != rhsDate {
            return selectedSort.sortsAscending ? lhsDate < rhsDate : lhsDate > rhsDate
        }

        return selectedSort.sortsAscending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
    }

    private func sortDate(for item: EntryDisplayItem) -> Date {
        switch selectedSort {
        case .manual, .cloudCreated, .cloudCreatedOldest:
            return item.createdAt
        case .entryDate, .entryDateOldest:
            let entry = item.entry
            return entry.datePrecision == .noDate ? item.createdAt : entry.date
        case .updated, .updatedOldest:
            return item.updatedAt
        }
    }

    private func entryForDisplay(_ item: EntryDisplayItem) -> CreateEntryDraft {
        let entry = item.entry
        guard entry.thumbnail == nil else {
            return entry
        }

        return entry.replacingThumbnail(renderThumbnail(for: entry))
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

    private func isCompleted(_ item: EntryDisplayItem) -> Bool {
        item.status == JournalEntryStatus.completed.rawValue
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

    private func openItem(_ item: EntryDisplayItem, displayEntry: CreateEntryDraft, fallbackIndex: Int) {
        let isCompleted = isCompleted(item)
        let storyboardImage = isCompleted ? storyboardUIImage(for: item, fallbackIndex: fallbackIndex) : nil
        let entryToOpen = materializedEntry(for: item, displayEntry: displayEntry)
        onOpenEntry(entryToOpen, isCompleted, storyboardImage)
    }

    private func materializedEntry(for item: EntryDisplayItem, displayEntry: CreateEntryDraft) -> CreateEntryDraft {
        guard !item.isLocal else {
            return displayEntry
        }

        _ = CreateEntryDraftStore.save(
            id: displayEntry.id,
            title: displayEntry.title,
            text: displayEntry.text,
            richText: displayEntry.richText,
            referencePhotos: [],
            characters: [],
            artStyle: displayEntry.artStyle,
            location: displayEntry.location,
            date: displayEntry.date,
            datePrecision: displayEntry.datePrecision,
            savesDraft: displayEntry.savesDraft,
            isPrivate: displayEntry.isPrivate,
            status: JournalEntryStatus(rawValue: item.status) ?? .draft,
            fontChoiceRawValue: displayEntry.fontChoiceRawValue,
            textColorIndex: displayEntry.textColorIndex,
            textSize: displayEntry.textSize,
            paperStyleRawValue: displayEntry.paperStyleRawValue,
            paperColorIndex: displayEntry.paperColorIndex,
            isBold: displayEntry.isBold,
            isItalic: displayEntry.isItalic,
            isUnderlined: displayEntry.isUnderlined,
            isStrikethrough: displayEntry.isStrikethrough,
            isHighlighted: displayEntry.isHighlighted,
            textAlignmentRawValue: displayEntry.textAlignmentRawValue,
            thumbnail: displayEntry.thumbnail
        )

        return displayEntry
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

private struct NewStorySheet: View {
    let chapterTitle: String
    let accentColor: Color
    let collectionLabel: String
    let locksEntryDate: Bool
    let onCreate: (PrototypeEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var bodyRichText: NotebookRichTextDocument?
    @State private var location = ""
    @State private var storyDate: Date
    @State private var isPrivateEntry = false
    @State private var isShowingExpandedEditor = false
    @FocusState private var isTitleFocused: Bool
    @State private var editorFocusRequestID = 0

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBody: String {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        chapterTitle: String,
        accentColor: Color,
        initialDate: Date = Date(),
        collectionLabel: String = "Chapter",
        locksEntryDate: Bool = false,
        onCreate: @escaping (PrototypeEntry) -> Void
    ) {
        self.chapterTitle = chapterTitle
        self.accentColor = accentColor
        self.collectionLabel = collectionLabel
        self.locksEntryDate = locksEntryDate
        self.onCreate = onCreate
        _storyDate = State(initialValue: initialDate)
    }

    var body: some View {
        ZStack {
            newStoryBackground
                .onTapGesture {
                    dismissKeyboard()
                }

            VStack(alignment: .leading, spacing: 0) {
                pageHeader

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        editorCard
                        storyDetailsCard
                        entryPrivacyCard
                        saveEntryButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $isShowingExpandedEditor) {
            ExpandedEntryEditor(
                entryText: $bodyText,
                entryRichText: $bodyRichText,
                storyTitle: $title
            )
        }
        .background(newStoryBackground)
        .onDisappear {
            dismissKeyboard()
        }
        .preferredColorScheme(.light)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                dismissKeyboard()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.72))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Text("New Entry")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundColor(Color.storyGray.opacity(0.46))

            Spacer()

            Button {
                createStory()
            } label: {
                Text("Save")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accentColor)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .disabled(trimmedTitle.isEmpty || trimmedBody.isEmpty)
            .opacity(trimmedTitle.isEmpty || trimmedBody.isEmpty ? 0.42 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var newStoryBackground: some View {
        ZStack {
            Color.storyCream

            LinearGradient(
                colors: [
                    accentColor.opacity(0.22),
                    Color.storyCream,
                    Color.storyBlush.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var editorCard: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                ZStack(alignment: .topLeading) {
                    NotebookPaperBackground(
                        showsPaperWash: false,
                        showsRuledLines: true,
                        firstRuledLineY: NotebookMetrics.firstNotebookRuleY
                    )
                    .frame(maxWidth: .infinity, minHeight: 504, maxHeight: .infinity)

                    NotebookEditorContent(
                        storyTitle: $title,
                        entryText: $bodyText,
                        entryRichText: $bodyRichText,
                        isTitleFocused: $isTitleFocused,
                        editorFocusRequestID: editorFocusRequestID,
                        bodyPlaceholder: "Start writing...",
                        scrollsInternally: false,
                        pageHeight: 504,
                        onTitleSubmit: {
                            editorFocusRequestID += 1
                        }
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 504)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(height: 504)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .notebookPageChrome()
        .overlay(alignment: .bottomTrailing) {
            Button {
                dismissKeyboard()
                isShowingExpandedEditor = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background(accentColor.opacity(0.1), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(accentColor.opacity(0.26), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand to full page")
            .padding(8)
        }
        .padding(.horizontal, -16)
    }

    private var storyDetailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Story Details")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            HStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 20)

                Text(collectionLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.9))
                    .frame(width: 90, alignment: .leading)

                Text(chapterTitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)

            Divider()
                .padding(.leading, 44)

            storyTextFieldRow

            Divider()
                .padding(.leading, 44)

            DatePicker(
                selection: $storyDate,
                displayedComponents: locksEntryDate ? [.hourAndMinute] : [.date, .hourAndMinute]
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accentColor)
                        .frame(width: 20)

                    Text("Date/time")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.storyInk.opacity(0.9))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .tint(accentColor)
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var storyTextFieldRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "location")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 20)

            Text("Location")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.9))
                .frame(width: 72, alignment: .leading)

            TextField("Add a location", text: $location)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.storyInk)
                .tint(accentColor)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var entryPrivacyCard: some View {
        Toggle(isOn: $isPrivateEntry) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Private Entry")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text("Only you can see this entry")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: accentColor))
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var saveEntryButton: some View {
        Button {
            createStory()
        } label: {
            HStack(spacing: 7) {
                Text("Save Entry")
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: [accentColor.opacity(0.92), accentColor],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .shadow(color: accentColor.opacity(0.18), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(trimmedTitle.isEmpty || trimmedBody.isEmpty)
        .opacity(trimmedTitle.isEmpty || trimmedBody.isEmpty ? 0.48 : 1)
        .padding(.top, 2)
    }

    private func dismissKeyboard() {
        isTitleFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func createStory() {
        guard !trimmedTitle.isEmpty, !trimmedBody.isEmpty else {
            return
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d"

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        EntryLocationRecentStore.add(trimmedLocation)
        let trimmedRichText = currentBodyRichText()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            PrototypeEntry(
                weekday: weekdayFormatter.string(from: storyDate).uppercased(),
                day: dayFormatter.string(from: storyDate),
                title: trimmedTitle,
                body: trimmedBody,
                richText: trimmedRichText,
                time: timeFormatter.string(from: storyDate),
                location: trimmedLocation.isEmpty ? nil : trimmedLocation,
                imageNames: []
            )
        )
        dismiss()
    }

    private func currentBodyRichText() -> NotebookRichTextDocument? {
        guard !bodyText.isEmpty else {
            return nil
        }

        return (bodyRichText ?? NotebookRichTextDocument(text: bodyText))
            .normalized(for: bodyText)
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

private struct VerticalComicViewer: View {
    let imageNames: [String]
    let initialIndex: Int
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @State private var visibleIndex: Int

    init(imageNames: [String], initialIndex: Int, accentColor: Color) {
        self.imageNames = imageNames
        self.initialIndex = initialIndex
        self.accentColor = accentColor
        _visibleIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.storyInk
                .ignoresSafeArea()

            ZoomableVerticalComicView(
                imageNames: imageNames,
                initialIndex: initialIndex,
                visibleIndex: $visibleIndex
            )
            .background(Color.black)

            HStack {
                Text("\(visibleIndex + 1) of \(imageNames.count)")
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
                .accessibilityLabel("Close comic viewer")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

private struct ZoomableVerticalComicView: UIViewRepresentable {
    let imageNames: [String]
    let initialIndex: Int
    @Binding var visibleIndex: Int

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
        context.coordinator.imageViews = imageNames.enumerated().compactMap { index, imageName in
            guard let image = UIImage(named: imageName) else {
                return nil
            }

            if index > 0 {
                stackView.addArrangedSubview(
                    makeImageBoundary(nextIndex: index, totalCount: imageNames.count)
                )
            }

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
                    multiplier: image.size.height / image.size.width
                )
            ])

            stackView.addArrangedSubview(pageView)
            context.coordinator.pageViews.append(pageView)
            return imageView
        }

        DispatchQueue.main.async {
            context.coordinator.scrollToInitialImage(in: scrollView)
        }

        return scrollView
    }

    private func makeImageBoundary(nextIndex: Int, totalCount: Int) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.035, alpha: 1)
        container.translatesAutoresizingMaskIntoConstraints = false

        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.86)
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        let numberLabel = UILabel()
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.text = "\(nextIndex + 1) / \(totalCount)"
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

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableVerticalComicView
        weak var stackView: UIStackView?
        var pageViews: [UIView] = []
        var imageViews: [UIImageView] = []
        private var didScrollToInitialImage = false

        init(parent: ZoomableVerticalComicView) {
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
                pageViews.indices.contains(parent.initialIndex)
            else {
                return
            }

            scrollView.layoutIfNeeded()
            stackView?.layoutIfNeeded()

            let imageView = pageViews[parent.initialIndex]
            let targetY = max(
                0,
                imageView.frame.midY - (scrollView.bounds.height / 2)
            )
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            didScrollToInitialImage = true
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
                closestIndex != parent.visibleIndex
            else {
                return
            }

            parent.visibleIndex = closestIndex
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

    enum SystemJournal: String, CaseIterable {
        case drafts
        case completed

        static let orderedCases: [SystemJournal] = [.drafts, .completed]

        static func journal(for id: UUID) -> SystemJournal? {
            orderedCases.first { $0.id == id }
        }

        var title: String {
            switch self {
            case .drafts:
                return "Drafts"
            case .completed:
                return "Completed"
            }
        }

        var subtitle: String {
            switch self {
            case .drafts:
                return "Entries without storyboards"
            case .completed:
                return "Generated storyboards"
            }
        }

        var id: UUID {
            switch self {
            case .drafts:
                return UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            case .completed:
                return UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
            }
        }

        var sortOrder: Int {
            switch self {
            case .drafts:
                return 0
            case .completed:
                return 1
            }
        }

        var color: Color {
            switch self {
            case .drafts:
                return Color.homeAccent
            case .completed:
                return Color.storyInk
            }
        }

        var symbol: String {
            switch self {
            case .drafts:
                return "doc.text.fill"
            case .completed:
                return "checkmark.seal.fill"
            }
        }

        var coverStorageKey: String {
            "system-\(rawValue)"
        }
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
    let systemJournal: SystemJournal?
    var entries: [PrototypeEntry]

    var isSystemJournal: Bool {
        systemJournal != nil
    }

    var coverStorageKey: String {
        systemJournal?.coverStorageKey ?? title
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
        systemJournal: SystemJournal? = nil,
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
        self.systemJournal = systemJournal
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
            systemJournal: nil,
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
            systemJournal: systemJournal,
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

    private static let storageKey = "StorytopiaUserChapters"

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
            let data = UserDefaults.standard.data(forKey: storageKey),
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

        UserDefaults.standard.set(data, forKey: storageKey)
        syncToCloud(chapter)
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

        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func replace(with chapters: [PrototypeChapter]) {
        let updatedRecords = chapters.map { chapter in
            let existingRecord = record(for: chapter)

            return Record(
                id: chapter.id,
                title: chapter.title,
                subtitle: chapter.subtitle,
                symbol: chapter.symbol,
                kind: chapter.kind == .storyboard ? "storyboard" : "journal",
                colorHex: colorHex(for: chapter),
                coverImageName: chapter.coverImageName ?? existingRecord?.coverImageName,
                remoteCover: chapter.remoteCover ?? existingRecord?.remoteCover,
                createdAt: chapter.createdAt,
                updatedAt: chapter.updatedAt
            )
        }

        guard let data = try? JSONEncoder().encode(updatedRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func delete(title: String) {
        let remainingRecords = records.filter { $0.title != title }
        guard let data = try? JSONEncoder().encode(remainingRecords) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
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

        UserDefaults.standard.set(data, forKey: storageKey)
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

        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func syncToCloud(_ chapter: PrototypeChapter) {
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
                displayOrder: displayOrder(for: chapter.title)
            )
            syncEntriesToCloud(chapter.entries, journalID: chapter.id)
        }
    }

    static func syncAllToCloud(_ chapters: [PrototypeChapter]) {
        chapters
            .filter { contains(title: $0.title) }
            .forEach(syncToCloud)
    }

    static func syncOrderToCloud(_ chapters: [PrototypeChapter]) {
        chapters
            .filter { contains(title: $0.title) }
            .enumerated()
            .forEach { offset, chapter in
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
                        displayOrder: offset
                    )
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
                displayOrder: displayOrder(for: chapter.title)
            )

            try await SupabaseJournalRepository().replaceJournalEntries(
                journalID: chapter.id,
                clientEntryIDs: StoryEntryStore.clientEntryIDs(for: chapter.title)
            )
        } catch {
            print("[Storytopia] Could not sync journal entries to cloud for \(title).")
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
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decodedRecords = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }

        let migratedRecords = migrateRecords(decodedRecords)
        if migratedRecords != decodedRecords,
           let data = try? JSONEncoder().encode(migratedRecords) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        return migratedRecords
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
        UIColor(color).storytopiaHexString ?? "#3D2678"
    }

    private static func displayOrder(for title: String) -> Int {
        records.firstIndex { $0.title == title } ?? 0
    }

    private static func stableID(for title: String, occurrence: Int) -> UUID {
        let namespace = "StorytopiaJournal:\(title):\(occurrence)"
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

private enum SystemJournalAppearanceStore {
    struct Appearance {
        let color: Color?
        let coverImageName: String?
        let remoteCover: JournalRemoteCover?
    }

    private struct Record: Codable {
        let colorHex: String?
        let coverImageName: String?
        let remoteCover: JournalRemoteCover?
    }

    private static let legacyStorageKey = "StorytopiaSystemJournalAppearances"
    private static let storagePrefix = "StorytopiaSystemJournalAppearance"

    static func appearance(for systemJournal: PrototypeChapter.SystemJournal) -> Appearance {
        let defaults = UserDefaults.standard
        let legacyRecord = legacyRecords[systemJournal.rawValue]
        let colorHex = defaults.string(forKey: key("colorHex", for: systemJournal)) ?? legacyRecord?.colorHex
        let coverImageName = defaults.string(forKey: key("coverImageName", for: systemJournal)) ?? legacyRecord?.coverImageName
        let remoteCover = remoteCover(for: systemJournal) ?? legacyRecord?.remoteCover

        return Appearance(
            color: colorHex.flatMap(Color.init(hex:)),
            coverImageName: coverImageName,
            remoteCover: remoteCover
        )
    }

    static func update(
        _ systemJournal: PrototypeChapter.SystemJournal,
        color: Color,
        coverImageName: String?,
        remoteCover: JournalRemoteCover?
    ) {
        let defaults = UserDefaults.standard
        defaults.set(UserChapterStore.colorHex(for: color), forKey: key("colorHex", for: systemJournal))

        if let coverImageName {
            defaults.set(coverImageName, forKey: key("coverImageName", for: systemJournal))
        } else {
            defaults.removeObject(forKey: key("coverImageName", for: systemJournal))
        }

        if let remoteCover, let data = try? JSONEncoder().encode(remoteCover) {
            defaults.set(data, forKey: key("remoteCover", for: systemJournal))
        } else {
            defaults.removeObject(forKey: key("remoteCover", for: systemJournal))
        }

        defaults.synchronize()
    }

    static func syncToCloud(_ chapter: PrototypeChapter, storedCoverImage: UIImage?) {
        guard let systemJournal = chapter.systemJournal else {
            return
        }

        Task {
            do {
                let repository = SupabaseJournalRepository()
                try await repository.upsertJournal(
                    id: systemJournal.id,
                    title: systemJournal.title,
                    subtitle: systemJournal.subtitle,
                    colorHex: UserChapterStore.colorHex(for: chapter.color),
                    symbol: systemJournal.symbol,
                    coverImageName: chapter.coverImageName,
                    remoteCover: chapter.remoteCover,
                    kind: chapter.kind == .storyboard ? "storyboard" : "journal",
                    isFavorite: chapter.isFavorite,
                    displayOrder: systemJournal.sortOrder
                )

                if let storedCoverImage {
                    try await repository.uploadCover(storedCoverImage, journalID: systemJournal.id)
                } else if chapter.remoteCover != nil || JournalCoverStore.image(for: systemJournal.coverStorageKey) == nil {
                    try await repository.clearCover(journalID: systemJournal.id)
                }
            } catch {
                print("[Storytopia] System journal cloud sync failed: \(error.localizedDescription)")
            }
        }
    }

    static func syncLocalAppearancesToCloudIfNeeded(existingCloudJournals: [StoryJournal]) {
        let existingSystemIDs = Set(existingCloudJournals.compactMap { cloudJournal in
            PrototypeChapter.SystemJournal.journal(for: cloudJournal.id)?.id
        })

        for systemJournal in PrototypeChapter.SystemJournal.orderedCases where !existingSystemIDs.contains(systemJournal.id) {
            let appearance = appearance(for: systemJournal)
            let storedCoverImage = JournalCoverStore.image(for: systemJournal.coverStorageKey)
            let hasLocalAppearance = appearance.color != nil
                || appearance.coverImageName != nil
                || appearance.remoteCover != nil
                || storedCoverImage != nil

            guard hasLocalAppearance else {
                continue
            }

            let chapter = PrototypeChapter(
                id: systemJournal.id,
                title: systemJournal.title,
                subtitle: systemJournal.subtitle,
                color: appearance.color ?? systemJournal.color,
                symbol: systemJournal.symbol,
                coverImageName: appearance.coverImageName,
                remoteCover: appearance.remoteCover,
                kind: .journal,
                isFavorite: false,
                createdAt: .distantPast,
                updatedAt: Date(),
                systemJournal: systemJournal,
                entries: []
            )
            syncToCloud(chapter, storedCoverImage: storedCoverImage)
        }
    }

    private static func key(_ field: String, for systemJournal: PrototypeChapter.SystemJournal) -> String {
        "\(storagePrefix).\(systemJournal.rawValue).\(field)"
    }

    private static func remoteCover(for systemJournal: PrototypeChapter.SystemJournal) -> JournalRemoteCover? {
        guard
            let data = UserDefaults.standard.data(forKey: key("remoteCover", for: systemJournal))
        else {
            return nil
        }

        return try? JSONDecoder().decode(JournalRemoteCover.self, from: data)
    }

    private static var legacyRecords: [String: Record] {
        guard
            let data = UserDefaults.standard.data(forKey: legacyStorageKey),
            let decodedRecords = try? JSONDecoder().decode([String: Record].self, from: data)
        else {
            return [:]
        }

        return decodedRecords
    }
}

private enum DeletedSampleChapterStore {
    private static let storageKey = "StorytopiaDeletedSampleChapters"

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
    private static let storageKey = "StorytopiaDeletedSampleEntries"

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

        init(cloudEntry entry: JournalEntry, chapterTitle: String) {
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

    private static let storageKey = "StorytopiaChapterStories"

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

    static func replaceCloudMemberships(
        _ memberships: [JournalEntryMembership],
        journals: [PrototypeChapter],
        entries: [JournalEntry]
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

    static func upsert(_ entry: PrototypeEntry, to chapterTitle: String) {
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
        syncToCloud(chapterTitle: chapterTitle)
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

    init(
        id: UUID = UUID(),
        weekday: String,
        day: String,
        title: String,
        body: String,
        richText: NotebookRichTextDocument? = nil,
        time: String,
        location: String?,
        imageNames: [String]
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
            imageNames: imageNames
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
