import SwiftUI

struct SettingsView: View {
    /// How this screen was reached. A pushed page is part of the navigation stack it came from; a
    /// sheet has to close itself and cannot rely on the app root's sign-in sheet, which is already
    /// underneath it.
    enum Presentation {
        case page
        case sheet
    }

    var presentation: Presentation = .page
    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    var contentMode: JournaltopiaContentMode = .user
    var showsBottomNavigation = false

    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var isSigningOut = false
    @State private var restoreOutcome: SubscriptionRestoreOutcome?
    @State private var isRestoring = false
    @State private var isManageSubscriptionPresented = false
    @State private var isSignInPagePresented = false
    @State private var isPaywallSheetPresented = false
    @State private var showsSignedOutConfirmation = false
    @State private var isDeleteAccountConfirmationPresented = false
    @State private var isDeletingAccount = false
    @State private var showsAccountDeletedConfirmation = false
    @State private var isHelpPresented = false
    @State private var isAboutPresented = false
    @State private var isPrivacyPolicyPresented = false

    var body: some View {
        List {
            Section("Account") {
                if case .signedIn = authStore.status {
                    accountStatusRow
                } else {
                    accountActionRow
                }
            }

            Section("Extra") {
                SettingsNavigationRow(
                    systemName: "slider.horizontal.3",
                    title: "Extra",
                    subtitle: "Testing tools and hidden pages",
                    accessibilityLabel: "Open extra settings"
                ) {
                    SettingsExtraView(
                        selectedPage: $selectedPage,
                        generatedStoryboards: $generatedStoryboards,
                        contentMode: contentMode,
                        showsBottomNavigation: showsBottomNavigation
                    )
                }
            }

            Section("Journaltopia+") {
                subscriptionStatusRow
                generationCreditsRow

                if authStore.userID != nil {
                    switch subscriptionStore.state {
                    case .subscribed:
                        manageSubscriptionRow
                        restorePurchasesRow
                    case .notSubscribed:
                        upgradeRow
                        restorePurchasesRow
                    case .unresolved, .signedOut:
                        EmptyView()
                    }
                }

                if let restoreOutcome {
                    Text(restoreOutcome.message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(restoreOutcome.isSuccess ? Color.storyPurple : Color.homeMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("App") {
                Button {
                    isHelpPresented = true
                } label: {
                    SettingsRowContent(
                        systemName: "questionmark.circle",
                        title: "Help & Support",
                        subtitle: "Contact and troubleshooting",
                        showsChevron: true
                    )
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Help and support")

                Button {
                    isAboutPresented = true
                } label: {
                    SettingsRowContent(
                        systemName: "info.circle",
                        title: "About",
                        subtitle: appVersionSubtitle,
                        showsChevron: true
                    )
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About Journaltopia")

                Button {
                    isPrivacyPolicyPresented = true
                } label: {
                    SettingsRowContent(
                        systemName: "hand.raised",
                        title: "Privacy Policy",
                        subtitle: "How your data is handled",
                        showsChevron: true
                    )
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Privacy policy")
            }

            if case .signedIn = authStore.status {
                Section {
                    accountFooterActions
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 28, trailing: 20))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WatercolorPaperPageBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsBottomNavigation {
                BottomNavigationBar(selectedPage: $selectedPage)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
                }
            }
        }
        .overlay {
            if showsAccountDeletedConfirmation {
                accountDeletedConfirmationCard
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else if showsSignedOutConfirmation {
                signedOutConfirmationCard
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: showsSignedOutConfirmation)
        .animation(.snappy(duration: 0.22), value: showsAccountDeletedConfirmation)
        // The second of the two deliberate steps. Nothing has been sent when this appears: the first
        // tap opens this, and only "Delete My Account" below starts the deletion.
        .alert("Delete Account?", isPresented: $isDeleteAccountConfirmationPresented) {
            Button("Delete My Account", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAccountConfirmationMessage)
        }
        .alert("Help & Support", isPresented: $isHelpPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(helpSupportPlaceholderMessage)
        }
        .alert("About Journaltopia", isPresented: $isAboutPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appAboutMessage)
        }
        .alert("Privacy Policy", isPresented: $isPrivacyPolicyPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(privacyPolicyPlaceholderMessage)
        }
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .enableInteractivePopGesture()
        // Presented from here rather than through the gate: Settings can already be presented over
        // the root, so it owns this page directly.
        .fullScreenCover(isPresented: $isSignInPagePresented) {
            SignInView(
                promptTitle: AccountRequiredAction.signIn.title,
                promptSubtitle: AccountRequiredAction.signIn.message
            )
        }
        .sheet(isPresented: $isPaywallSheetPresented) {
            JournaltopiaPlusPaywallView(
                presentation: .sheet,
                onDismiss: { isPaywallSheetPresented = false }
            )
        }
        .task {
            await authStore.refreshCurrentUser()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
    }

    private var isSignedOut: Bool {
        authStore.status == .signedOut
    }

    private func presentSignIn() {
        switch presentation {
        case .page:
            signInGate.requireAccount(for: .signIn)
        case .sheet:
            isSignInPagePresented = true
        }
    }

    private func signOut() {
        Task {
            isSigningOut = true
            await authStore.signOut()
            isSigningOut = false
            presentSignedOutConfirmation()
        }
    }

    /// Apple-linked accounts get one extra sentence, because they get one extra step: the Apple sheet
    /// appears before anything is deleted, and an unexplained system prompt mid-deletion would read as
    /// something having gone wrong.
    private var deleteAccountConfirmationMessage: String {
        let summary = """
            This permanently deletes your Journaltopia account and everything in it, your journals, entries, uploaded photos, and generated storyboards.

            This cannot be undone.
            """

        guard authStore.hasAppleIdentity else {
            return summary
        }

        return summary + "\n\nYou'll be asked to confirm with Apple so Journaltopia can remove its access to your Apple ID."
    }

    /// Runs the deletion, and does nothing at all if one is already running.
    ///
    /// `isDeletingAccount` is the guard against a double submission as well as the loading state:
    /// the row disables itself on it, and it is set before the first `await` so a second tap landing
    /// in the same run loop cannot get past it.
    private func deleteAccount() {
        guard !isDeletingAccount else {
            return
        }

        Task {
            isDeletingAccount = true
            let didDelete = await authStore.deleteAccount()
            isDeletingAccount = false

            // On failure the account is untouched and still signed in; `authStore.errorMessage`
            // already carries a retryable explanation and is rendered under the account rows.
            if didDelete {
                presentAccountDeletedConfirmation()
            }
        }
    }

    private func presentAccountDeletedConfirmation() {
        showsSignedOutConfirmation = false
        showsAccountDeletedConfirmation = true
    }

    private func dismissAccountDeletedConfirmation() {
        showsAccountDeletedConfirmation = false
    }

    private func presentSignedOutConfirmation() {
        showsAccountDeletedConfirmation = false
        showsSignedOutConfirmation = true
    }

    private func dismissSignedOutConfirmation() {
        showsSignedOutConfirmation = false
    }

    private var signedOutConfirmationCard: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)

                VStack(spacing: 8) {
                    Text("Signed Out")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text("This device is signed-out. You can sign in again to continue using your account.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Signed out. This device is back in signed-out mode.")

            Button {
                dismissSignedOutConfirmation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.55))
                    .frame(width: 36, height: 36)
                    .background(Color.homeInputGray.opacity(0.85), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("Close")
        }
        .frame(maxWidth: 360)
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.storyPurple.opacity(0.14), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    }

    @ViewBuilder
    private var accountFooterActions: some View {
        if case .signedIn = authStore.status {
            VStack(spacing: 16) {
                Button {
                    signOut()
                } label: {
                    HStack(spacing: 8) {
                        if isSigningOut {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(isSigningOut ? "Signing Out" : "Sign Out")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.storyInk.opacity(0.08), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Also disabled mid-deletion: signing out first would strand a live account behind a
                // signed-out screen, since the deletion only completes when the server says so.
                .disabled(isSigningOut || isDeletingAccount)

                Button(role: .destructive) {
                    isDeleteAccountConfirmationPresented = true
                } label: {
                    HStack(spacing: 8) {
                        if isDeletingAccount {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.red)
                        }

                        Text(isDeletingAccount ? "Deleting Account" : "Delete Account")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.red.opacity(0.58), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Both halves of "no duplicate submissions": the button cannot be tapped again while
                // a deletion is in flight, and `deleteAccount()` refuses a second run even if it were.
                .disabled(isDeletingAccount || isSigningOut)
                .accessibilityLabel(isDeletingAccount ? "Deleting account" : "Delete account")
                .accessibilityHint("Asks for confirmation before permanently deleting your account")

                Text("Permanently delete your account and all of your entries, journals, references, characters, and generated storyboards.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 42)
                    .padding(.top, -6)
            }
            .padding(.top, 8)
        }
    }

    private var accountDeletedConfirmationCard: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)

                VStack(spacing: 6) {
                    Text("Account Deleted")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text("Your account and its content have been permanently removed. This device is back in signed-out mode.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Account deleted. Your account and its content have been permanently removed.")

            Button {
                dismissAccountDeletedConfirmation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .background(Color.homeInputGray.opacity(0.85), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("Close")
        }
        .frame(maxWidth: 300)
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.storyPurple.opacity(0.14), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    }

    private var accountStatusRow: some View {
        SettingsRowContent(
            systemName: "person.crop.circle",
            title: accountStatusTitle,
            subtitle: accountStatusSubtitle,
            showsChevron: false
        )
        .padding(.vertical, 4)
    }

    // MARK: - Journaltopia+

    /// Status when signed in; a door into the pricing sheet when signed out. The paywall itself
    /// asks for an account before anything is purchased, so browsing plans does not need one.
    @ViewBuilder
    private var subscriptionStatusRow: some View {
        if isSignedOut {
            Button {
                isPaywallSheetPresented = true
            } label: {
                SettingsRowContent(
                    systemName: "crown.fill",
                    title: "Journaltopia+",
                    subtitle: subscriptionSubtitle,
                    showsChevron: true
                )
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Journaltopia+")
            .accessibilityHint("Shows plans and pricing")
        } else {
            SettingsRowContent(
                systemName: "crown.fill",
                title: "Journaltopia+",
                subtitle: subscriptionSubtitle,
                showsChevron: false,
                trailingContent: {
                    if subscriptionStore.state.isSubscribed {
                        SettingsStatusBadge(title: "Active")
                    }
                }
            )
            .padding(.vertical, 4)
        }
    }

    private var upgradeRow: some View {
        NavigationLink {
            JournaltopiaPlusPaywallView(presentation: .page)
                .enableInteractivePopGesture()
        } label: {
            SettingsRowContent(
                systemName: "arrow.up.circle",
                title: "Upgrade to Journaltopia+",
                subtitle: upgradeSubtitle,
                showsChevron: false
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Upgrade to Journaltopia+")
    }

    /// Apple's own sheet, not a hand-built App Store URL: it handles cancelling, changing plan and
    /// refund requests, and it stays correct as those flows change.
    private var manageSubscriptionRow: some View {
        Button {
            isManageSubscriptionPresented = true
        } label: {
            SettingsRowContent(
                systemName: "creditcard",
                title: "Manage Subscription",
                subtitle: "Change or cancel in the App Store",
                showsChevron: true
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .manageSubscriptionsSheetIfAvailable(isPresented: $isManageSubscriptionPresented)
    }

    private var restorePurchasesRow: some View {
        Button {
            restorePurchases()
        } label: {
            SettingsRowContent(
                systemName: "arrow.clockwise",
                title: isRestoring ? "Restoring…" : "Restore Purchases",
                subtitle: "Bring an existing subscription to this account",
                showsChevron: false,
                trailingContent: {
                    if isRestoring {
                        ProgressView().controlSize(.small)
                    }
                }
            )
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(isRestoring)
    }

    private var subscriptionSubtitle: String {
        guard authStore.userID != nil else {
            return "See plans and pricing"
        }

        switch subscriptionStore.state {
        case .unresolved:
            return "Checking your plan…"
        case .signedOut:
            return "See plans and pricing"
        case .notSubscribed:
            return "Not subscribed"
        case .subscribed:
            guard let periodEnd = subscriptionStore.state.currentPeriodEnd else {
                return "Active"
            }

            return "Active · renews \(JournaltopiaPlusFormatting.formatted(periodEnd))"
        }
    }

    private var upgradeSubtitle: String {
        guard let price = subscriptionStore.localizedPrice else {
            return "25 credits every month"
        }

        return "\(price) per month · 25 credits"
    }

    private func restorePurchases() {
        isRestoring = true
        restoreOutcome = nil

        Task {
            let outcome = await subscriptionStore.restorePurchases(isSignedIn: authStore.userID != nil)
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
            restoreOutcome = outcome
            isRestoring = false
        }
    }

    private var generationCreditsRow: some View {
        NavigationLink {
            GenerationCreditsView()
                .enableInteractivePopGesture()
        } label: {
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
        .buttonStyle(.plain)
        .accessibilityLabel("Open generation credits")
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
                presentSignIn()
            } label: {
                SettingsRowContent(
                    systemName: "person.badge.key",
                    title: "Sign In",
                    subtitle: "Use one account across your devices",
                    showsChevron: false
                )
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        case .signedIn:
            EmptyView()
        }

        if let errorMessage = authStore.errorMessage {
            Text(errorMessage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
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
            return authStore.email ?? authStore.displayName
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
            return authStore.accountProviderName
        }
    }

    private var generationCreditsSubtitle: String {
        switch authStore.status {
        case .signedIn:
            return "Standard storyboards cost 1 credit"
        case .loading:
            return "Checking your account"
        case .misconfigured:
            return "Credits require Supabase"
        case .signedOut:
            return "Sign in to use credits"
        }
    }

    private var appVersionSubtitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case (.some(let version), .some(let build)):
            return "Version \(version) (\(build))"
        case (.some(let version), nil):
            return "Version \(version)"
        default:
            return "App information"
        }
    }

    private var appAboutMessage: String {
        "\(appVersionSubtitle)\n\nJournaltopia turns your memories into private illustrated storyboards."
    }

    private var helpSupportPlaceholderMessage: String {
        "Support contact details are coming soon.\n\nTODO: Replace this placeholder with your support email, help center link, or in-app support flow."
    }

    private var privacyPolicyPlaceholderMessage: String {
        "Privacy policy details are coming soon.\n\nTODO: Replace this placeholder with the final Journaltopia privacy policy text or policy URL."
    }
}

private struct SettingsExtraView: View {
    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    var contentMode: JournaltopiaContentMode = .user
    var showsBottomNavigation = false

    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var entitlementGate: EntitlementGate

    @AppStorage("JournaltopiaSampleAuthorModeEnabled") private var isSampleAuthorModeEnabled = false
    @State private var isOnboardingPreviewPresented = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: debugPlusPlanBinding) {
                    SettingsRowContent(
                        systemName: subscriptionStore.state.isSubscribed ? "crown.fill" : "crown",
                        title: "Journaltopia+ Test Plan",
                        subtitle: debugPlanSubtitle,
                        showsChevron: false,
                        iconColor: subscriptionStore.state.isSubscribed ? Color.storyPurple : Color.homeAccent
                    )
                    .padding(.vertical, 4)
                }
                // Signed out there is no account for an entitlement to belong to, and while a change
                // is in flight the switch would otherwise report the old answer as if it were the
                // new one.
                .disabled(authStore.userID == nil || subscriptionStore.isChangingTestPlan)

                if let testPlanErrorMessage = subscriptionStore.testPlanErrorMessage {
                    Text(testPlanErrorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .padding(.vertical, 2)
                }
            } header: {
                Text("Plan Testing")
            } footer: {
                Text("Writes a real subscription row in Supabase for this account, so generation is actually allowed. Your account must be listed in journaltopia_plus_test_plan_allowlist.")
            }

            Section("Onboarding") {
                Button {
                    isOnboardingPreviewPresented = true
                } label: {
                    SettingsRowContent(
                        systemName: "sparkles.rectangle.stack",
                        title: "Preview Onboarding",
                        subtitle: "Open the first-launch walkthrough",
                        showsChevron: false
                    )
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview onboarding")
            }

            Section("Pages") {
                SettingsNavigationRow(
                    systemName: "rectangle.stack.fill",
                    title: "My Story Reader",
                    subtitle: "Two-page comic without Home scroll",
                    accessibilityLabel: "Open My Story reader test"
                ) {
                    SettingsMyStoryReaderTestPage(
                        selectedPage: $selectedPage,
                        generatedStoryboards: $generatedStoryboards,
                        contentMode: contentMode
                    )
                    .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "person.fill",
                    title: "Profile",
                    subtitle: "Your storyboards and account",
                    accessibilityLabel: "Open profile"
                ) {
                    ProfileView(
                        selectedPage: $selectedPage,
                        generatedStoryboards: $generatedStoryboards,
                        embedsInNavigationStack: false,
                        contentMode: contentMode
                    )
                    .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "book.pages",
                    title: "Start Your Story",
                    subtitle: "Open the account-start page",
                    accessibilityLabel: "Open Start Your Story"
                ) {
                    StartYourStoryView()
                        .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "person.crop.circle.badge.plus",
                    title: "Create An Account",
                    subtitle: "Open the sign-up screen",
                    accessibilityLabel: "Open create an account"
                ) {
                    SignInView(
                        startsCreatingAccount: true
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "crown.fill",
                    title: "Journaltopia+",
                    subtitle: "Compare Free and Journaltopia Plus",
                    accessibilityLabel: "Open Journaltopia Plus"
                ) {
                    JournaltopiaPlusPaywallView(presentation: .page)
                        .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "sparkle.magnifyingglass",
                    title: "Buy Credits",
                    subtitle: "Open the credit top-up screen",
                    accessibilityLabel: "Open buy credits"
                ) {
                    BuyCreditsView(
                        promptTitle: "Buy Credits",
                        promptSubtitle: "Add credits for storyboard generation"
                    )
                    .navigationTitle("Buy Credits")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .enableInteractivePopGesture()
                }

                SettingsNavigationRow(
                    systemName: "sparkle",
                    title: "Credits",
                    subtitle: "Balance, plan, and credit packs",
                    accessibilityLabel: "Open credits"
                ) {
                    GenerationCreditsView()
                        .enableInteractivePopGesture()
                }
            }

            Section("Create") {
                Toggle(isOn: $isSampleAuthorModeEnabled) {
                    SettingsRowContent(
                        systemName: "wand.and.stars.inverse",
                        title: "Sample Author Mode",
                        subtitle: sampleAuthorModeSubtitle,
                        showsChevron: false,
                        iconColor: isSampleAuthorModeEnabled ? Color.storyPurple : Color.homeAccent
                    )
                    .padding(.vertical, 4)
                }
                .disabled(authStore.userID == nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WatercolorPaperPageBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsBottomNavigation {
                BottomNavigationBar(selectedPage: $selectedPage)
            }
        }
        .navigationTitle("Extra")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $isOnboardingPreviewPresented) {
            OnboardingView {
                isOnboardingPreviewPresented = false
            }
        }
    }

    private var debugPlusPlanBinding: Binding<Bool> {
        Binding(
            get: { subscriptionStore.state.isSubscribed },
            set: { isActive in
                Task {
                    // The switch reflects `state`, and `state` is only written by an entitlement
                    // read, so it does not move until the server has actually agreed. That is the
                    // behaviour that was missing: the old toggle flipped instantly and left the
                    // server refusing every generation behind it.
                    await subscriptionStore.setTestPlanActive(isActive)
                    entitlementGate.update(state: subscriptionStore.state)
                }
            }
        )
    }

    private var debugPlanSubtitle: String {
        guard authStore.userID != nil else {
            return "Sign in to change the test plan"
        }

        if subscriptionStore.isChangingTestPlan {
            return "Updating your plan on the server…"
        }

        return subscriptionStore.state.isSubscribed
            ? "Journaltopia Plus active on the server"
            : "Free — generation will be refused"
    }

    private var sampleAuthorModeSubtitle: String {
        if authStore.userID == nil {
            return "Sign in first, then edit the public sample experience"
        }

        return isSampleAuthorModeEnabled ? "Entries opens sample content and saves edits to sample tables" : "Temporarily edit the signed-out sample experience"
    }
}

private struct SettingsMyStoryReaderTestPage: View {
    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    var contentMode: JournaltopiaContentMode = .user

    var body: some View {
        ZStack {
            WatercolorPaperPageBackground()

            MyStoryView(
                selectedPage: $selectedPage,
                generatedStoryboards: $generatedStoryboards,
                contentMode: contentMode,
                showsSettingsButton: false,
                showsBottomNavigation: false,
                embedsInNavigationStack: false
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("My Story Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
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

private struct SettingsStatusBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.storyPurple)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.storyPurple.opacity(0.1), in: Capsule())
    }
}

private struct SettingsRowContent: View {
    let systemName: String?
    let title: String
    let subtitle: String
    var showsChevron = true
    var iconColor = Color.homeAccent
    var trailingContent: (() -> AnyView)?

    init(
        systemName: String? = nil,
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
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 38, height: 38)
                    .background(iconColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

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
