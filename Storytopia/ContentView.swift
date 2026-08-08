//
//  ContentView.swift
//  Storytopia
//
//  Created by Mike Kogan on 5/28/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore

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
    }

    var body: some View {
        NavigationStack {
            basePage
                .navigationDestination(isPresented: isCreatePagePresented) {
                    createPage
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
        .task {
            await authStore.refreshCurrentUser()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
            reloadScopedLocalState()
        }
        .onChange(of: authStore.userID) { userID in
            Task {
                await generationCreditStore.refresh(isSignedIn: userID != nil)
            }
            reloadScopedLocalState()
        }
        .onChange(of: selectedPage) { _ in
            endWindowEditing()
        }
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
                if newPage == .create {
                    if selectedPage != .create {
                        pageBehindCreate = selectedPage
                    }

                    if !isOpeningEntryFromEntries {
                        activeDraftID = nil
                        completedEntryOpenedStoryboardImage = nil
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
        )
    }

    @ViewBuilder
    private var basePage: some View {
        switch pageBehindCreate {
        case .home:
            HomeView(selectedPage: pageSelection)
                .transition(.identity)
                .zIndex(0)
        case .today:
            DaybookView(selectedPage: pageSelection)
                .transition(.identity)
                .zIndex(0)
        case .entries:
            EntriesView(
                selectedPage: pageSelection,
                isDraftSaved: $isDraftSaved,
                activeDraftID: $activeDraftID,
                completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
                isOpeningEntryFromEntries: $isOpeningEntryFromEntries,
                isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries
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
                storyboardGenerationStatus: $storyboardGenerationStatus
            )
                .transition(.identity)
                .zIndex(0)
        case .profile:
            ProfileView(
                selectedPage: pageSelection,
                generatedStoryboards: $generatedStoryboards
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
            isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
            storyboardGenerationStatus: $storyboardGenerationStatus,
            dismissCreate: {
                dismissCreatePage()
            }
        )
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

    private func reloadScopedLocalState() {
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
                .accessibilityLabel(status.title)
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

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 14)
                .padding(.vertical, 72)

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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SupabaseAuthStore.preview)
            .environmentObject(GenerationCreditStore())
    }
}
