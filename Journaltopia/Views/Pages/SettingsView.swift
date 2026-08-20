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
    @State private var signedOutConfirmationHideTask: Task<Void, Never>?
    @State private var isDeleteAccountConfirmationPresented = false
    @State private var isDeletingAccount = false
    @State private var showsAccountDeletedConfirmation = false

    var body: some View {
        List {
            Section("Account") {
                // Signed out there is no status worth a row of its own: "Signed Out" only restates
                // what the single action below already says, so the section is just the action.
                if !isSignedOut {
                    accountStatusRow
                }

                accountActionRow

                // Below the sign-out row, and only for an account that exists to be deleted. Its own
                // confirmation carries the warning; this row is a door, not the action.
                if case .signedIn = authStore.status {
                    deleteAccountRow
                }
            }

            Section("Journaltopia+") {
                subscriptionStatusRow

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

            Section("Credits") {
                generationCreditsRow
            }

            Section {
                SettingsNavigationRow(
                    systemName: "ellipsis.circle",
                    title: "Extra",
                    subtitle: "Account, plans, credits, and create tools",
                    accessibilityLabel: "Open extra settings"
                ) {
                    SettingsExtraView()
                        .enableInteractivePopGesture()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WatercolorPaperPageBackground())
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
        .preferredColorScheme(.light)
        .enableInteractivePopGesture()
        // Presented from here rather than through the gate: Settings can already be presented over
        // the root, so it owns this page directly.
        .fullScreenCover(isPresented: $isSignInPagePresented) {
            SignInView(
                promptTitle: AccountRequiredAction.signIn.title,
                promptSubtitle: AccountRequiredAction.signIn.message
            )
            .onChange(of: authStore.status) { status in
                // Closed on the auth store's word, not on the provider call returning — the session
                // arrives through `authStateChanges`, which can land later.
                if status == .signedIn {
                    isSignInPagePresented = false
                }
            }
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
        .onDisappear {
            signedOutConfirmationHideTask?.cancel()
            signedOutConfirmationHideTask = nil
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
            This permanently deletes your Journaltopia account and everything in it             — your journals, entries, uploaded photos, and generated storyboards.

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
        signedOutConfirmationHideTask?.cancel()
        showsSignedOutConfirmation = false
        showsAccountDeletedConfirmation = true

        signedOutConfirmationHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else {
                return
            }

            showsAccountDeletedConfirmation = false
            signedOutConfirmationHideTask = nil
        }
    }

    private func presentSignedOutConfirmation() {
        signedOutConfirmationHideTask?.cancel()
        showsSignedOutConfirmation = true

        signedOutConfirmationHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else {
                return
            }

            showsSignedOutConfirmation = false
            signedOutConfirmationHideTask = nil
        }
    }

    private var signedOutConfirmationCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.storyPurple)

            VStack(spacing: 6) {
                Text("Signed Out")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Text("This device is back in signed-out mode. Your local samples stay available to browse.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: 300)
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.storyPurple.opacity(0.14), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed out. This device is back in signed-out mode.")
        .accessibilityAddTraits(.isStaticText)
    }

    /// The destructive entry point. Tapping it only opens the confirmation — nothing is deleted
    /// until the alert's own destructive button is pressed.
    private var deleteAccountRow: some View {
        Button(role: .destructive) {
            isDeleteAccountConfirmationPresented = true
        } label: {
            HStack(spacing: 12) {
                SettingsRowContent(
                    systemName: "trash",
                    title: isDeletingAccount ? "Deleting Account" : "Delete Account",
                    subtitle: isDeletingAccount
                        ? "Removing your journals, photos, and storyboards"
                        : "Permanently delete your account and its content",
                    showsChevron: false,
                    iconColor: .red
                )

                if isDeletingAccount {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        // Both halves of "no duplicate submissions": the row cannot be tapped again while a deletion
        // is in flight, and `deleteAccount()` refuses a second run even if it were.
        .disabled(isDeletingAccount || isSigningOut)
        .accessibilityLabel(isDeletingAccount ? "Deleting account" : "Delete account")
        .accessibilityHint("Asks for confirmation before permanently deleting your account")
    }

    private var accountDeletedConfirmationCard: some View {
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
        .frame(maxWidth: 300)
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.storyPurple.opacity(0.14), radius: 20, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Account deleted. Your account and its content have been permanently removed.")
        .accessibilityAddTraits(.isStaticText)
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
                        CreditBalanceBadge(
                            balance: generationCreditStore.balance,
                            isRefreshing: generationCreditStore.isRefreshing
                        )
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
                showsChevron: false
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
            Button(role: .destructive) {
                signOut()
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
            // Also disabled mid-deletion: signing out first would strand a live account behind a
            // signed-out screen, since the deletion only completes when the server says so.
            .disabled(isSigningOut || isDeletingAccount)
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
            return "Standard storyboards cost 1 credit; HD costs 2"
        case .loading:
            return "Checking your account"
        case .misconfigured:
            return "Credits require Supabase"
        case .signedOut:
            return "Sign in to use credits"
        }
    }
}

private struct SettingsExtraView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore

    @AppStorage("JournaltopiaSampleAuthorModeEnabled") private var isSampleAuthorModeEnabled = false
    @State private var isOnboardingPreviewPresented = false

    var body: some View {
        List {
            Section("Pages") {
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
        .navigationTitle("Extra")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $isOnboardingPreviewPresented) {
            OnboardingView {
                isOnboardingPreviewPresented = false
            }
        }
    }

    private var sampleAuthorModeSubtitle: String {
        if authStore.userID == nil {
            return "Sign in first, then edit the public sample experience"
        }

        return isSampleAuthorModeEnabled ? "Entries opens sample content and saves edits to sample tables" : "Temporarily edit the signed-out sample experience"
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
