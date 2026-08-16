import SwiftUI

struct SupabaseJournalTestView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore

    @State private var entries: [JournalEntry] = []
    @State private var selectedEntry: JournalEntry?
    @State private var title = ""
    @State private var content = ""
    @State private var isLoadingEntries = false
    @State private var isSaving = false
    @State private var message: String?

    private let repository = SupabaseEntryRepository()

    var body: some View {
        ZStack {
            Color.homePageBackground
                .ignoresSafeArea()

            contentView
        }
        .navigationTitle("Cloud Journal Test")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await authStore.refreshCurrentUser()
            await loadEntriesIfSignedIn()
        }
        .onChange(of: authStore.userID) { _ in
            Task {
                await loadEntriesIfSignedIn()
            }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var contentView: some View {
        switch authStore.status {
        case .loading:
            ProgressView("Checking session...")
                .tint(Color.homeAccent)
        case .misconfigured(let configurationMessage):
            statePanel(
                systemName: "exclamationmark.triangle",
                title: "Supabase needs configuration",
                subtitle: configurationMessage,
                buttonTitle: nil,
                action: {}
            )
            .padding(20)
        case .signedOut:
            statePanel(
                systemName: "person.badge.key",
                title: "Sign in to test private entries",
                subtitle: "Google Sign-In uses Supabase Auth and returns to Journaltopia through the app URL scheme.",
                buttonTitle: "Continue with Google"
            ) {
                Task {
                    await authStore.signInWithGoogle()
                }
            }
            .padding(20)
        case .signedIn:
            signedInContent
        }
    }

    private var signedInContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accountHeader
                editorCard
                entriesSection

                if let message {
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 42, height: 42)
                .background(Color.homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Signed in")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(authStore.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)
            }

            Spacer()

            Button("Sign Out") {
                Task {
                    await authStore.signOut()
                    entries = []
                    clearEditor()
                }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.homeAccent)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedEntry == nil ? "New Draft Entry" : "Edit Draft Entry")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $content)
                .font(.system(size: 15))
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.homeInputGray.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    Task {
                        await saveEntry()
                    }
                } label: {
                    Label(selectedEntry == nil ? "Create" : "Update", systemImage: selectedEntry == nil ? "plus" : "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                if selectedEntry != nil {
                    Button {
                        clearEditor()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.storyInk)
                            .frame(width: 42, height: 42)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.homeBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel editing")
                }
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your Supabase Entries")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Button {
                    Task {
                        await loadEntries()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.homeAccent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingEntries)
                .accessibilityLabel("Refresh entries")
            }

            if isLoadingEntries {
                ProgressView()
                    .tint(Color.homeAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if entries.isEmpty {
                Text("No cloud entries yet.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.homeBorder, lineWidth: 1)
                    )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: JournalEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title ?? "Untitled")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(1)

                Text(entry.content ?? "No content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(2)

                Text(entry.status.capitalized)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
            }

            Spacer()

            Button {
                selectedEntry = entry
                title = entry.title ?? ""
                content = entry.content ?? ""
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit entry")

            Button(role: .destructive) {
                Task {
                    await deleteEntry(entry)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.red)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete entry")
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private func statePanel(
        systemName: String,
        title: String,
        subtitle: String,
        buttonTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.homeAccent)

            Text(title)
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)

            if let buttonTitle {
                Button(action: action) {
                    Label(buttonTitle, systemImage: "g.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let errorMessage = authStore.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }

    private func loadEntriesIfSignedIn() async {
        guard authStore.userID != nil else { return }
        await loadEntries()
    }

    private func loadEntries() async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }

        do {
            entries = try await repository.getEntries()
            message = nil
        } catch {
            message = userFacingMessage(for: error)
        }
    }

    private func saveEntry() async {
        isSaving = true
        defer { isSaving = false }

        do {
            if let selectedEntry {
                _ = try await repository.updateEntry(
                    id: selectedEntry.id,
                    title: title,
                    content: content
                )
                message = "Entry updated."
            } else {
                _ = try await repository.createEntry(title: title, content: content)
                message = "Entry created."
            }

            clearEditor()
            await loadEntries()
        } catch {
            message = userFacingMessage(for: error)
        }
    }

    private func deleteEntry(_ entry: JournalEntry) async {
        do {
            try await repository.deleteEntry(id: entry.id)
            entries.removeAll { $0.id == entry.id }
            if selectedEntry?.id == entry.id {
                clearEditor()
            }
            message = "Entry deleted."
        } catch {
            message = userFacingMessage(for: error)
        }
    }

    private func clearEditor() {
        selectedEntry = nil
        title = ""
        content = ""
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return "Something went wrong. Please try again."
    }
}
