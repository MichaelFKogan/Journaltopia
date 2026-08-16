//
//  ContentView.swift
//  Storytopia
//
//  Created by Mike Kogan on 5/28/26.
//

import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var pendingStoryboardMonitor: PendingStoryboardGenerationMonitor
    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedPage: StoryPage = .home
    @State private var pageBehindCreate: StoryPage = .home
    @State private var entryText: String
    @State private var draftStoryTitle: String
    @State private var draftStoryboardPhotos: [CreateEntryReferencePhoto?]
    @State private var isDraftSaved: Bool
    @State private var activeDraftID: UUID?
    @State private var journalCreatePresentation: CreateEntryPresentation?
    @State private var generatedStoryboards: [GeneratedStoryboard]
    @State private var completedEntryOpenedStoryboardImage: UIImage?
    @State private var storyboardGenerationStatus: StoryboardGenerationGlobalStatus?
    @State private var openedStoryboardGenerationImage: UIImage?
    @State private var isOpeningEntryFromEntries: Bool
    @State private var isOpeningCompletedEntryFromEntries: Bool
    @State private var homeStorySoFarPresentation: HomeStorySoFarPresentation?
    @State private var homeStorySoFarPageIndex: Int
    @AppStorage("StorytopiaSampleAuthorModeEnabled") private var isSampleAuthorModeEnabled = false

    init() {
        _entryText = State(initialValue: "")
        _draftStoryTitle = State(initialValue: "")
        _draftStoryboardPhotos = State(initialValue: Array(repeating: nil, count: 5))
        _isDraftSaved = State(initialValue: CreateEntryDraftStore.hasSavedDrafts())
        _activeDraftID = State(initialValue: nil)
        _journalCreatePresentation = State(initialValue: nil)
        _generatedStoryboards = State(initialValue: [])
        _completedEntryOpenedStoryboardImage = State(initialValue: nil)
        _storyboardGenerationStatus = State(initialValue: nil)
        _openedStoryboardGenerationImage = State(initialValue: nil)
        _isOpeningEntryFromEntries = State(initialValue: false)
        _isOpeningCompletedEntryFromEntries = State(initialValue: false)
        _homeStorySoFarPresentation = State(initialValue: nil)
        _homeStorySoFarPageIndex = State(initialValue: 0)
    }

    var body: some View {
        NavigationStack {
            basePage
                .navigationDestination(isPresented: isCreatePagePresented) {
                    createPage
                }
                .navigationDestination(isPresented: isHomeStorySoFarPresented) {
                    if let homeStorySoFarPresentation {
                        HomeStoryboardVerticalViewer(
                            storyboards: homeStorySoFarPresentation.storyboards,
                            currentPageIndex: $homeStorySoFarPageIndex,
                            title: "The Story So Far..."
                        )
                        .navigationBarBackButtonHidden(true)
                        .toolbar(.hidden, for: .navigationBar)
                        .enableInteractivePopGesture()
                    }
                }
        }
        .overlay(alignment: .bottom) {
            StoryboardGenerationBottomBanner(status: storyboardGenerationStatus) { action in
                handleStoryboardGenerationBanner(action)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .fullScreenCover(isPresented: isOpenedStoryboardGenerationImagePresented) {
            if let openedStoryboardGenerationImage {
                StoryboardGenerationImagePreview(image: openedStoryboardGenerationImage) {
                    self.openedStoryboardGenerationImage = nil
                }
            }
        }
        // Mounted at the root so any screen, sheet or pushed destination can raise it without
        // owning a presentation of its own.
        .sheet(item: signInGateRequest) { request in
            SignInGateSheet(request: request)
        }
        .task {
            // The credit balance is account state that lives on an object rather than on disk, so
            // the sign-out purge has to be handed it before it can clear it.
            LocalUserDataPurge.register(generationCreditStore: generationCreditStore)

            await authStore.refreshCurrentUser()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
            reloadScopedLocalState()

            // Launch is the first of the two moments a generation can be picked back up. Anything
            // still running on the server from a previous session resumes being watched here.
            pendingStoryboardMonitor.attach(creditStore: generationCreditStore)
            pendingStoryboardMonitor.resume(isSignedIn: authStore.userID != nil)
        }
        .onAppear {
            signInGate.update(mode: contentMode)
        }
        .onChange(of: contentMode) { mode in
            signInGate.update(mode: mode)

            // Signed-out browsing reads the sample pack from memory. Anything held from a previous
            // mode is another account's or another pack's, so it goes rather than being reused.
            if !mode.showsSampleContent || mode.isSampleAuthoring {
                SampleContentStore.clear()
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else {
                pendingStoryboardMonitor.suspend()
                return
            }

            pendingStoryboardMonitor.resume(isSignedIn: authStore.userID != nil)
        }
        .onReceive(pendingStoryboardMonitor.$status.compactMap { $0 }) { restoredStatus in
            // The monitor owns the banner for anything it is watching, including generations this
            // session never saw start.
            withAnimation(.snappy(duration: 0.24)) {
                storyboardGenerationStatus = restoredStatus
            }
        }
        .onReceive(pendingStoryboardMonitor.$restoredStoryboard.compactMap { $0 }) { storyboard in
            generatedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: generatedStoryboards)
            pendingStoryboardMonitor.consumeRestoredStoryboard()
        }
        .onChange(of: authStore.userID) { userID in
            Task {
                await generationCreditStore.refresh(isSignedIn: userID != nil)
            }
            reloadScopedLocalState()
            pendingStoryboardMonitor.resume(isSignedIn: userID != nil)
        }
        .onChange(of: selectedPage) { _ in
            endWindowEditing()
        }
        .onChange(of: isSampleAuthorModeEnabled) { _ in
            if selectedPage == .create {
                dismissCreatePage()
            }
            reloadScopedLocalState()
        }
    }

    /// Derived once, here, and threaded down. Screens no longer each re-derive "am I signed out?"
    /// from `authStore.userID`, which is what used to make a still-loading session and a
    /// misconfigured build both look exactly like a signed-out visitor.
    private var contentMode: StorytopiaContentMode {
        StorytopiaContentMode(
            status: authStore.status,
            isSampleAuthorModeEnabled: isSampleAuthorModeEnabled
        )
    }

    private var signInGateRequest: Binding<SignInGateRequest?> {
        Binding(
            get: { signInGate.pendingRequest },
            set: { request in
                if request == nil {
                    signInGate.dismiss()
                }
            }
        )
    }

    private var isCreatePagePresented: Binding<Bool> {
        Binding(
            get: { selectedPage == .create },
            set: { isPresented in
                guard !isPresented, selectedPage == .create else {
                    return
                }

                dismissCreatePage()
            }
        )
    }

    private var pageSelection: Binding<StoryPage> {
        Binding(
            get: { selectedPage },
            set: { newPage in
                selectPage(newPage)
            }
        )
    }

    private var isHomeStorySoFarPresented: Binding<Bool> {
        Binding(
            get: { homeStorySoFarPresentation != nil },
            set: { isPresented in
                if !isPresented {
                    homeStorySoFarPresentation = nil
                }
            }
        )
    }

    private func selectPage(_ newPage: StoryPage) {
        if newPage == .create {
            if selectedPage != .create {
                pageBehindCreate = selectedPage
            }

            if !isOpeningEntryFromEntries {
                resetFreshCreateState()
            } else if !isOpeningCompletedEntryFromEntries {
                completedEntryOpenedStoryboardImage = nil
            }
        } else {
            pageBehindCreate = newPage
            journalCreatePresentation = nil
            isOpeningEntryFromEntries = false
            isOpeningCompletedEntryFromEntries = false
            completedEntryOpenedStoryboardImage = nil
        }

        selectedPage = newPage
    }

    @ViewBuilder
    private var basePage: some View {
        switch pageBehindCreate {
        case .home:
            HomeView(
                selectedPage: pageSelection,
                generatedStoryboards: $generatedStoryboards,
                contentMode: contentMode,
                openCreatePage: openCreatePageFromHome,
                openEntriesPage: openEntriesPageFromHome,
                openJournalsPage: openJournalsPage,
                openStorySoFarPage: openStorySoFarPage
            )
                .transition(.identity)
                .zIndex(0)
        case .today:
            DaybookView(selectedPage: pageSelection, contentMode: contentMode)
                .transition(.identity)
                .zIndex(0)
        case .entries:
            EntriesView(
                selectedPage: pageSelection,
                isDraftSaved: $isDraftSaved,
                activeDraftID: $activeDraftID,
                completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
                isOpeningEntryFromEntries: $isOpeningEntryFromEntries,
                isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
                contentMode: contentMode
            )
                .transition(.identity)
                .zIndex(0)
        case .journal:
            JournalView(
                selectedPage: pageSelection,
                isDraftSaved: $isDraftSaved,
                activeDraftID: $activeDraftID,
                journalCreatePresentation: $journalCreatePresentation,
                completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
                isOpeningEntryFromEntries: $isOpeningEntryFromEntries,
                isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
                generatedStoryboards: $generatedStoryboards,
                storyboardGenerationStatus: $storyboardGenerationStatus,
                contentMode: contentMode
            )
                .transition(.identity)
                .zIndex(0)
        case .profile:
            ProfileView(
                selectedPage: pageSelection,
                generatedStoryboards: $generatedStoryboards,
                contentMode: contentMode
            )
            .transition(.identity)
            .zIndex(0)
        case .settings:
            NavigationStack {
                SettingsView(selectedPage: pageSelection)
            }
                .transition(.identity)
                .zIndex(0)
        case .create:
            EmptyView()
        }
    }

    private var createEntryPresentation: CreateEntryPresentation {
        if pageBehindCreate == .entries, activeDraftID != nil {
            return .editDraft
        }

        if pageBehindCreate == .journal,
           activeDraftID != nil,
           let journalCreatePresentation {
            return journalCreatePresentation
        }

        if pageBehindCreate == .journal, activeDraftID != nil {
            return .editDraft
        }

        if pageBehindCreate == .journal, let journalCreatePresentation {
            return journalCreatePresentation
        }

        return .compose
    }

    private var createPage: some View {
        CreateEntryView(
            presentation: createEntryPresentation,
            entryText: $entryText,
            storyTitle: $draftStoryTitle,
            storyboardPhotos: $draftStoryboardPhotos,
            isDraftSaved: $isDraftSaved,
            activeDraftID: $activeDraftID,
            selectedPage: pageSelection,
            generatedStoryboards: $generatedStoryboards,
            completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
            isOpeningEntryFromEntries: isOpeningEntryFromEntries,
            isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
            storyboardGenerationStatus: $storyboardGenerationStatus,
            contentMode: contentMode,
            dismissCreate: {
                dismissCreatePage()
            }
        )
    }

    private func openCreatePageFromHome() {
        resetHomeCardState()
        selectPage(.create)
    }

    private func openEntriesPageFromHome() {
        resetHomeCardState()
        selectPage(.entries)
    }

    private func openJournalsPage() {
        resetHomeCardState()
        selectPage(.journal)
    }

    private func openStorySoFarPage() {
        guard !generatedStoryboards.isEmpty else {
            return
        }

        // Snapshot at open time so a Home reload can't wipe the pushed page.
        homeStorySoFarPageIndex = 0
        homeStorySoFarPresentation = HomeStorySoFarPresentation(storyboards: generatedStoryboards)
    }

    private var isOpenedStoryboardGenerationImagePresented: Binding<Bool> {
        Binding(
            get: { openedStoryboardGenerationImage != nil },
            set: { isPresented in
                if !isPresented {
                    openedStoryboardGenerationImage = nil
                }
            }
        )
    }

    private func handleStoryboardGenerationBanner(_ action: StoryboardGenerationBottomBanner.Action) {
        switch action {
        case .open:
            if let image = storyboardGenerationStatus?.image {
                openedStoryboardGenerationImage = image
            }
        case .dismiss:
            // Both writers have to forget it, or the monitor's next tick puts it straight back.
            pendingStoryboardMonitor.dismissStatus()
            withAnimation(.snappy(duration: 0.24)) {
                storyboardGenerationStatus = nil
            }
        }
    }

    private func dismissCreatePage() {
        endWindowEditing()
        selectedPage = pageBehindCreate
        journalCreatePresentation = nil
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
        completedEntryOpenedStoryboardImage = nil
    }

    private func endWindowEditing() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .endEditing(true)
    }

    private func resetHomeCardState() {
        homeStorySoFarPresentation = nil
        journalCreatePresentation = nil
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
        completedEntryOpenedStoryboardImage = nil
    }

    private func resetFreshCreateState() {
        activeDraftID = nil
        entryText = ""
        draftStoryTitle = ""
        draftStoryboardPhotos = Array(repeating: nil, count: 5)
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
        completedEntryOpenedStoryboardImage = nil
    }

    private func reloadScopedLocalState() {
        // A session that has not resolved yet is not a signed-out one. Clearing here would throw
        // away the previous scope's state on every launch, before anyone has said it is wrong.
        guard contentMode.isResolved else {
            return
        }

        guard authStore.userID != nil else {
            isDraftSaved = false
            generatedStoryboards = []
            activeDraftID = nil
            completedEntryOpenedStoryboardImage = nil
            isOpeningEntryFromEntries = false
            isOpeningCompletedEntryFromEntries = false
            return
        }

        isDraftSaved = CreateEntryDraftStore.hasSavedDrafts()
        if selectedPage == .create || pageBehindCreate == .profile {
            generatedStoryboards = GeneratedStoryboardStore.load()
        }
        activeDraftID = nil
        journalCreatePresentation = nil
        completedEntryOpenedStoryboardImage = nil
        isOpeningEntryFromEntries = false
        isOpeningCompletedEntryFromEntries = false
    }
}

private struct HomeStorySoFarPresentation: Identifiable {
    let id = UUID()
    let storyboards: [GeneratedStoryboard]
}

private struct StoryboardGenerationBottomBanner: View {
    enum Action {
        case open
        case dismiss
    }

    let status: StoryboardGenerationGlobalStatus?
    let onAction: (Action) -> Void

    var body: some View {
        Group {
            if let status {
                HStack(spacing: 12) {
                    statusIcon(for: status)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.storyInk)
                            .lineLimit(1)

                        Text(status.message)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.homeMutedText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    if status.kind == .completed {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.storyPurple)
                            .frame(width: 34, height: 34)
                            .background(Color.storyPurple.opacity(0.1), in: Circle())
                    }

                    Button {
                        onAction(.dismiss)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.storyInk.opacity(0.58))
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss storyboard generation status")
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                )
                .shadow(color: Color.storyInk.opacity(0.18), radius: 20, y: 10)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture {
                    guard status.kind == .completed else {
                        return
                    }

                    onAction(.open)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel(
                    status.isRestored && status.kind == .running
                        ? "\(status.title), still running on Storytopia's servers"
                        : status.title
                )
                .accessibilityHint(status.kind == .completed ? "Opens the generated storyboard image" : status.message)
            }
        }
        .animation(.snappy(duration: 0.28), value: status?.id)
    }

    @ViewBuilder
    private func statusIcon(for status: StoryboardGenerationGlobalStatus) -> some View {
        switch status.kind {
        case .running:
            ProgressView()
                .tint(Color.storyPurple)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.82), in: Circle())
        case .completed:
            if let image = status.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.storyPurple, in: Circle())
                            .offset(x: 4, y: 4)
                    }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.82), in: Circle())
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.88))
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.82), in: Circle())
        }
    }
}

private struct StoryboardGenerationImagePreview: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableStoryboardGenerationImageView(image: image)
                .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.18), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 18)
            .accessibilityLabel("Close storyboard preview")
        }
    }
}

private struct ZoomableStoryboardGenerationImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapRecognizer.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapRecognizer)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else {
                return
            }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let tapPoint = recognizer.location(in: imageView)
            let targetScale = min(scrollView.maximumZoomScale, 2.35)
            let zoomSize = CGSize(
                width: scrollView.bounds.width / targetScale,
                height: scrollView.bounds.height / targetScale
            )
            let zoomOrigin = CGPoint(
                x: tapPoint.x - (zoomSize.width / 2),
                y: tapPoint.y - (zoomSize.height / 2)
            )
            scrollView.zoom(to: CGRect(origin: zoomOrigin, size: zoomSize), animated: true)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SupabaseAuthStore.preview)
            .environmentObject(GenerationCreditStore())
            .environmentObject(PendingStoryboardGenerationMonitor())
            .environmentObject(SignInGate())
    }
}
