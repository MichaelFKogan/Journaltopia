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

    @State private var selectedPage: StoryPage = .journal
    @State private var pageBehindCreate: StoryPage = .journal
    @State private var entryText: String
    @State private var draftStoryTitle: String
    @State private var draftStoryboardPhotos: [CreateEntryReferencePhoto?]
    @State private var isDraftSaved: Bool
    @State private var activeDraftID: UUID?
    @State private var journalCreatePresentation: CreateEntryPresentation?
    @State private var generatedStoryboards: [GeneratedStoryboard]
    @State private var completedEntryOpenedStoryboardImage: UIImage?
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
        _isOpeningEntryFromEntries = State(initialValue: false)
        _isOpeningCompletedEntryFromEntries = State(initialValue: false)
    }

    var body: some View {
        ZStack {
            basePage

            if selectedPage == .create {
                createPage
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.32), value: selectedPage)
        .task {
            await authStore.refreshCurrentUser()
            reloadScopedLocalState()
        }
        .onChange(of: authStore.userID) { _ in
            reloadScopedLocalState()
        }
        .onChange(of: selectedPage) { _ in
            endWindowEditing()
        }
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
        case .explore:
            ExploreView(selectedPage: pageSelection)
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
                generatedStoryboards: $generatedStoryboards
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
            dismissCreate: {
                endWindowEditing()
                selectedPage = pageBehindCreate
                journalCreatePresentation = nil
                isOpeningEntryFromEntries = false
                isOpeningCompletedEntryFromEntries = false
                completedEntryOpenedStoryboardImage = nil
            }
        )
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SupabaseAuthStore.preview)
    }
}
