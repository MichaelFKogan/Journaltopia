import SwiftUI

struct SettingsView: View {
    @Binding var selectedPage: StoryPage
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedArtStyle = "Anime"
    @State private var isSigningIn = false
    @State private var isSigningOut = false

    private let artStyles = ["Anime", "Graphic Novel", "Pixel Art", "Manga", "Cozy Storybook", "Pop Art", "Colored Journal"]

    var body: some View {
        List {
            Section("Account") {
                accountStatusRow

                generationCreditsRow

                accountActionRow

                SettingsRow(
                    systemName: "person.circle",
                    title: "Profile",
                    subtitle: "View your storyboard collection"
                ) {
                    dismiss()
                }

                SettingsNavigationRow(
                    systemName: "lock.cloud",
                    title: "Cloud Journal Test",
                    subtitle: "Test Supabase sign-in and private entries",
                    accessibilityLabel: "Open cloud journal test"
                ) {
                    SupabaseJournalTestView()
                        .enableInteractivePopGesture()
                }
            }

            Section("Journal") {
                SettingsNavigationRow(
                    systemName: "calendar",
                    title: "Daily",
                    subtitle: "Open your daily journal",
                    accessibilityLabel: "Open daily journal"
                ) {
                    DaybookView(
                        selectedPage: $selectedPage,
                        embedsInNavigationStack: false,
                        showsBottomNavigation: false
                    )
                    .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "book.closed",
                    title: "All Journals",
                    subtitle: "Open the classic journals list",
                    accessibilityLabel: "Open all journals"
                ) {
                    ClassicJournalView(
                        selectedPage: $selectedPage,
                        isDraftSaved: .constant(false),
                        activeDraftID: .constant(nil),
                        embedsInNavigationStack: false,
                        showsBottomNavigation: false
                    )
                    .enableInteractivePopGesture()
                }
            }

            Section("Create") {
                SettingsNavigationRow(
                    systemName: "square.and.pencil",
                    title: "Create Visual Test",
                    subtitle: "Preview Create with Cloud Journal styling",
                    accessibilityLabel: "Open create visual test"
                ) {
                    CreateVisualTestView()
                        .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "paintpalette",
                    title: "Choose Art Style",
                    subtitle: "Preview and pick a storyboard look",
                    accessibilityLabel: "Open choose art style"
                ) {
                    ArtStyleGridSheet(
                        artStyles: artStyles,
                        selectedArtStyle: $selectedArtStyle
                    )
                    .enableInteractivePopGesture()
                }
            }

            Section("More Pages") {
                SettingsRow(
                    systemName: "doc.text",
                    title: "Entries",
                    subtitle: "Open your saved drafts and completed stories"
                ) {
                    selectedPage = .entries
                    dismiss()
                }

                SettingsNavigationRow(
                    systemName: "safari",
                    title: "Explore",
                    subtitle: "Open the explore feed",
                    accessibilityLabel: "Open explore"
                ) {
                    ExploreView(
                        selectedPage: $selectedPage,
                        showsBottomNavigation: false
                    )
                    .enableInteractivePopGesture()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.homePageBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preferredColorScheme(.light)
        .enableInteractivePopGesture()
        .task {
            await authStore.refreshCurrentUser()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
    }

    private var accountStatusRow: some View {
        SettingsRowContent(
            systemName: accountStatusIconName,
            title: accountStatusTitle,
            subtitle: accountStatusSubtitle,
            showsChevron: false
        )
        .padding(.vertical, 4)
    }

    private var generationCreditsRow: some View {
        SettingsRowContent(
            systemName: "sparkle",
            title: "Generation Credits",
            subtitle: generationCreditsSubtitle,
            showsChevron: false,
            trailingContent: {
                CreditBalanceBadge(
                    balance: generationCreditStore.balance,
                    isRefreshing: generationCreditStore.isRefreshing
                )
            }
        )
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var accountActionRow: some View {
        switch authStore.status {
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)

                Text("Checking session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyInk)
            }
            .padding(.vertical, 8)
        case .misconfigured:
            EmptyView()
        case .signedOut:
            Button {
                Task {
                    isSigningIn = true
                    await authStore.signInWithGoogle()
                    isSigningIn = false
                }
            } label: {
                SettingsRowContent(
                    systemName: "person.badge.key",
                    title: isSigningIn ? "Signing In" : "Sign In with Google",
                    subtitle: "Use one account across your devices",
                    showsChevron: false
                )
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isSigningIn)
        case .signedIn:
            Button(role: .destructive) {
                Task {
                    isSigningOut = true
                    await authStore.signOut()
                    isSigningOut = false
                }
            } label: {
                SettingsRowContent(
                    systemName: "rectangle.portrait.and.arrow.right",
                    title: isSigningOut ? "Signing Out" : "Sign Out",
                    subtitle: "Return this device to signed-out mode",
                    showsChevron: false,
                    iconColor: .red
                )
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut)
        }

        if let errorMessage = authStore.errorMessage {
            Text(errorMessage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountStatusIconName: String {
        switch authStore.status {
        case .loading:
            return "person.crop.circle.badge.clock"
        case .misconfigured:
            return "exclamationmark.triangle"
        case .signedOut:
            return "person.crop.circle.badge.xmark"
        case .signedIn:
            return "checkmark.seal"
        }
    }

    private var accountStatusTitle: String {
        switch authStore.status {
        case .loading:
            return "Checking Account"
        case .misconfigured:
            return "Supabase Not Configured"
        case .signedOut:
            return "Signed Out"
        case .signedIn:
            return "Signed In"
        }
    }

    private var accountStatusSubtitle: String {
        switch authStore.status {
        case .loading:
            return "Looking for a saved session"
        case .misconfigured(let message):
            return message
        case .signedOut:
            return "Local entries stay on this device"
        case .signedIn:
            return authStore.email ?? authStore.displayName
        }
    }

    private var generationCreditsSubtitle: String {
        switch authStore.status {
        case .signedIn:
            return "Standard and HD storyboards cost 1 credit"
        case .loading:
            return "Checking your account"
        case .misconfigured:
            return "Credits require Supabase"
        case .signedOut:
            return "Sign in to use credits"
        }
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let systemName: String
    let title: String
    let subtitle: String
    let accessibilityLabel: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowContent(
                systemName: systemName,
                title: title,
                subtitle: subtitle,
                showsChevron: false
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SettingsRow: View {
    let systemName: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowContent(
                systemName: systemName,
                title: title,
                subtitle: subtitle
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowContent: View {
    let systemName: String
    let title: String
    let subtitle: String
    var showsChevron = true
    var iconColor = Color.homeAccent
    var trailingContent: (() -> AnyView)?

    init(
        systemName: String,
        title: String,
        subtitle: String,
        showsChevron: Bool = true,
        iconColor: Color = Color.homeAccent,
        @ViewBuilder trailingContent: @escaping () -> some View = { EmptyView() }
    ) {
        self.systemName = systemName
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.iconColor = iconColor
        self.trailingContent = { AnyView(trailingContent()) }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 38, height: 38)
                .background(iconColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            if let trailingContent {
                trailingContent()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
        }
        .contentShape(Rectangle())
    }
}
