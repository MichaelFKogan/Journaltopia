import SwiftUI

struct SettingsView: View {
    @Binding var selectedPage: StoryPage
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.openURL) private var openURL

    @State private var isSigningOut = false
    @State private var restoreOutcome: SubscriptionRestoreOutcome?
    @State private var isRestoring = false
    @State private var isManageSubscriptionPresented = false

    var body: some View {
        List {
            Section("Account") {
                accountStatusRow

                accountActionRow
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

            Section("AI Credits") {
                generationCreditsRow
            }

            Section {
                SettingsNavigationRow(
                    systemName: "ellipsis.circle",
                    title: "Extra",
                    subtitle: "Tests, daily journal, and create tools",
                    accessibilityLabel: "Open extra settings"
                ) {
                    SettingsExtraView(
                        selectedPage: $selectedPage
                    )
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

    // MARK: - Journaltopia+

    /// Status only — no marketing. Someone in Settings is looking for a fact.
    private var subscriptionStatusRow: some View {
        SettingsRowContent(
            systemName: subscriptionStore.state.isSubscribed ? "checkmark.seal.fill" : "sparkles",
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
            return "Sign in to see your plan"
        }

        switch subscriptionStore.state {
        case .unresolved:
            return "Checking your plan…"
        case .signedOut:
            return "Sign in to see your plan"
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
            return "25 AI credits every month"
        }

        return "\(price) per month · 25 AI credits"
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
                signInGate.requireAccount(for: .signIn)
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

    @Binding var selectedPage: StoryPage
    @AppStorage("JournaltopiaSampleAuthorModeEnabled") private var isSampleAuthorModeEnabled = false
    @State private var isOnboardingPreviewPresented = false

    private var contentMode: JournaltopiaContentMode {
        JournaltopiaContentMode(
            status: authStore.status,
            isSampleAuthorModeEnabled: isSampleAuthorModeEnabled
        )
    }

    var body: some View {
        List {
            Section("Tests") {
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
                        showsBottomNavigation: false,
                        contentMode: contentMode
                    )
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

                SettingsNavigationRow(
                    systemName: "wand.and.stars",
                    title: "Sample Studio",
                    subtitle: sampleStudioSubtitle,
                    accessibilityLabel: "Open sample studio"
                ) {
                    SampleStudioView()
                        .enableInteractivePopGesture()
                }

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
                    systemName: "text.cursor",
                    title: "Stock Text Editor",
                    subtitle: "Compare Create/Write typing with Apple TextEditor",
                    accessibilityLabel: "Open stock text editor test"
                ) {
                    StockTextEditorTestView()
                        .enableInteractivePopGesture()
                }
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

    private var sampleStudioSubtitle: String {
        authStore.userID == nil ? "Sign in as a sample admin to author demo stories" : "Author public first-run sample stories"
    }

    private var sampleAuthorModeSubtitle: String {
        if authStore.userID == nil {
            return "Sign in first, then edit the public sample experience"
        }

        return isSampleAuthorModeEnabled ? "Entries opens sample content and saves edits to sample tables" : "Temporarily edit the signed-out sample experience"
    }
}

private struct SampleStudioView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore

    @State private var samplePack: SampleStoryPack?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedPage: StoryPage = .entries
    @State private var entryText = ""
    @State private var storyTitle = ""
    @State private var storyboardPhotos: [CreateEntryReferencePhoto?] = Array(repeating: nil, count: 5)
    @State private var isDraftSaved = false
    @State private var activeDraftID: UUID?
    @State private var generatedStoryboards: [GeneratedStoryboard] = []
    @State private var completedEntryOpenedStoryboardImage: UIImage?
    @State private var isOpeningCompletedEntryFromEntries = false
    @State private var storyboardGenerationStatus: StoryboardGenerationGlobalStatus?
    @State private var scratchDraftID: UUID?

    var body: some View {
        content
            .navigationTitle("Sample Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openNewSampleEntry()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(authStore.userID == nil || isLoading)
                    .accessibilityLabel("Create sample entry")
                }
            }
            .background(Color.homePageBackground)
            .preferredColorScheme(.light)
            .navigationDestination(isPresented: isCreatePresented) {
                CreateEntryView(
                    presentation: activeDraftID == nil ? .compose : .editDraft,
                    entryText: $entryText,
                    storyTitle: $storyTitle,
                    storyboardPhotos: $storyboardPhotos,
                    isDraftSaved: $isDraftSaved,
                    activeDraftID: $activeDraftID,
                    selectedPage: pageSelection,
                    generatedStoryboards: $generatedStoryboards,
                    completedEntryOpenedStoryboardImage: $completedEntryOpenedStoryboardImage,
                    isOpeningCompletedEntryFromEntries: $isOpeningCompletedEntryFromEntries,
                    storyboardGenerationStatus: $storyboardGenerationStatus,
                    contentMode: .sampleAuthoring,
                    dismissCreate: {
                        closeCreateAndRefresh()
                    }
                )
            }
            .task {
                await loadSamples()
            }
    }

    @ViewBuilder
    private var content: some View {
        if authStore.userID == nil {
            List {
                Section {
                    SettingsRowContent(
                        systemName: "person.badge.key",
                        title: "Sign In Required",
                        subtitle: "Sample Studio writes to Supabase sample tables.",
                        showsChevron: false
                    )
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else {
            List {
                Section {
                    Text("Create and edit the public first-run sample stories using Journaltopia's real entry flow. Saves go to the sample tables and sample-story-assets bucket.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }

                if isLoading {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading sample pack")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.storyInk)
                        }
                        .padding(.vertical, 8)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Sample Entries") {
                    let entries = samplePack?.entries ?? []
                    if entries.isEmpty && !isLoading {
                        Button {
                            openNewSampleEntry()
                        } label: {
                            SettingsRowContent(
                                systemName: "plus.circle",
                                title: "Create First Sample",
                                subtitle: "Start the public demo pack",
                                showsChevron: false
                            )
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(entries) { entry in
                            Button {
                                openSampleEntry(entry)
                            } label: {
                                SampleStudioEntryRow(
                                    entry: entry,
                                    storyboardCount: samplePack?.storyboardsByEntryID[entry.id]?.count ?? 0
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable {
                await loadSamples()
            }
        }
    }

    private var isCreatePresented: Binding<Bool> {
        Binding(
            get: { selectedPage == .create },
            set: { isPresented in
                if !isPresented {
                    closeCreateAndRefresh()
                }
            }
        )
    }

    private var pageSelection: Binding<StoryPage> {
        Binding(
            get: { selectedPage },
            set: { newPage in
                if newPage == .create {
                    selectedPage = .create
                } else {
                    closeCreateAndRefresh()
                }
            }
        )
    }

    @MainActor
    private func openNewSampleEntry() {
        prepareCreateScratch()
        activeDraftID = nil
        selectedPage = .create
    }

    @MainActor
    private func openSampleEntry(_ entry: CreateEntryDraft) {
        prepareCreateScratch()
        let savedID = CreateEntryDraftStore.save(
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
        activeDraftID = savedID ?? entry.id
        scratchDraftID = activeDraftID
        generatedStoryboards = samplePack?.storyboardsByEntryID[entry.id] ?? []
        completedEntryOpenedStoryboardImage = generatedStoryboards.first?.image
        isOpeningCompletedEntryFromEntries = entry.status == JournalEntryStatus.completed.rawValue
        selectedPage = .create
    }

    @MainActor
    private func prepareCreateScratch() {
        entryText = ""
        storyTitle = ""
        storyboardPhotos = Array(repeating: nil, count: 5)
        isDraftSaved = false
        generatedStoryboards = []
        completedEntryOpenedStoryboardImage = nil
        isOpeningCompletedEntryFromEntries = false
        storyboardGenerationStatus = nil
        scratchDraftID = nil
    }

    @MainActor
    private func closeCreateAndRefresh() {
        selectedPage = .entries
        if let scratchDraftID {
            CreateEntryDraftStore.delete(id: scratchDraftID)
        }
        if let activeDraftID {
            CreateEntryDraftStore.delete(id: activeDraftID)
        }
        activeDraftID = nil
        scratchDraftID = nil
        prepareCreateScratch()

        Task {
            await loadSamples()
        }
    }

    @MainActor
    private func loadSamples() async {
        guard authStore.userID != nil else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            samplePack = try await SupabaseSampleStoryService().loadAuthoringPack()
        } catch {
            errorMessage = "Could not load Sample Studio. Make sure this signed-in account is listed in sample_story_admins and the sample migrations are applied."
        }
        isLoading = false
    }
}

private struct SampleStudioEntryRow: View {
    let entry: CreateEntryDraft
    let storyboardCount: Int

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = entry.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: entry.status == JournalEntryStatus.completed.rawValue ? "photo.on.rectangle" : "doc.text")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.homeAccent)
                    .frame(width: 48, height: 60)
                    .background(Color.homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title.isEmpty ? "Untitled Sample" : entry.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(1)

                Text(entry.text.isEmpty ? "No entry text yet" : entry.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(2)

                Text(statusText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.homeMutedText.opacity(0.65))
        }
        .padding(.vertical, 5)
    }

    private var statusText: String {
        if entry.status == JournalEntryStatus.completed.rawValue {
            return storyboardCount == 1 ? "Completed · 1 page" : "Completed · \(storyboardCount) pages"
        }

        return "Draft"
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
