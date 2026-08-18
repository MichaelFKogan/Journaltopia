import SwiftUI

/// The credits screen, reached from Home, Profile and Settings.
///
/// One screen, three faces, because the useful thing to say differs completely by account state:
///
///   signed out    what Journaltopia+ is, and a way to sign in
///   free          what Journaltopia+ is, what it costs, and how to start
///   subscribed    the balance, when the next 25 arrive, and how to top up
///
/// Everything shown here is read from the server — the balance from `profiles.generation_credits`
/// through `GenerationCreditStore`, the plan from the `journaltopia_plus_entitlement` view through
/// `SubscriptionStore`. Nothing on this screen can change a balance; that is the server's job, and
/// the client has no privilege to do it.
struct GenerationCreditsView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var signInGate: SignInGate

    @State private var restoreOutcome: SubscriptionRestoreOutcome?

    private var isSignedIn: Bool {
        authStore.userID != nil
    }

    private var isSubscribed: Bool {
        subscriptionStore.state.isSubscribed
    }

    /// True only when the balance is known *and* short of an HD page. Drives the emphasis on the
    /// credit pack section, so someone who has run out sees it first.
    private var isLowOnCredits: Bool {
        guard let balance = generationCreditStore.balance else {
            return false
        }

        return balance < OpenAIImageGenerationQuality.highDefinition.creditCost
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                balanceSection

                switch subscriptionStore.state {
                case .subscribed:
                    subscriberSections
                case .notSubscribed, .signedOut:
                    upgradeSection
                case .unresolved:
                    // Never show "not subscribed" before the server has answered — that is how a
                    // paying subscriber gets told to subscribe again on a cold launch.
                    resolvingSection
                }

                usageSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Color.homePageBackground)
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .preferredColorScheme(.light)
        .enableInteractivePopGesture()
        .task {
            await authStore.refreshCurrentUser()
            await generationCreditStore.refresh(isSignedIn: isSignedIn)
            await subscriptionStore.refresh(isSignedIn: isSignedIn)
        }
    }

    // MARK: - Balance

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
                    .frame(width: 48, height: 48)
                    .background(Color.homeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Credits")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text(balanceSubtitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.storyInk.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if authStore.status == .signedOut {
                Button {
                    signInGate.requireAccount(for: .spendCredits)
                } label: {
                    Text("Sign In to Use Credits")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(balanceText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.storyInk)
                        .monospacedDigit()

                    Text("credits")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.58))

                    Spacer(minLength: 0)

                    if isSubscribed {
                        Text("Journaltopia+")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.storyPurple)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.storyPurple.opacity(0.12), in: Capsule())
                    }
                }

                if let split = CreditBucketFormatting.split(for: generationCreditStore) {
                    Text(split)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.homeMutedText)
                }

                // The one place the difference is spelled out. Every other surface just shows the
                // split and trusts this screen to have explained it.
                Text(CreditBucketFormatting.explanation)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = generationCreditStore.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
    }

    // MARK: - Subscriber

    @ViewBuilder
    private var subscriberSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            planRow(
                icon: "checkmark.seal.fill",
                title: "Journaltopia+ is active",
                detail: JournaltopiaPlusFormatting.renewalCaption(for: subscriptionStore.state)
            )

            planRow(
                icon: "arrow.clockwise",
                title: "25 monthly credits each period",
                detail: monthlyResetDetail
            )
        }
        .padding(4)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )

        if isLowOnCredits {
            Text("You are low on credits. Your next 25 arrive with your renewal.")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.storyPurple.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        CreditPackSection()

        RestorePurchasesButton(outcome: $restoreOutcome)
    }

    private func planRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 32, height: 32)
                .background(Color.storyPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Free

    private var upgradeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Journaltopia+")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Text("AI storyboard generation with 25 credits every month. Writing, journals and characters stay free.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(priceLine)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
            )

            NavigationLink {
                JournaltopiaPlusPaywallView(presentation: .page)
                    .enableInteractivePopGesture()
            } label: {
                Text("Start Journaltopia+")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        LinearGradient(
                            colors: [Color.storyPurple.opacity(0.95), Color.storyPurple],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(.plain)

            RestorePurchasesButton(outcome: $restoreOutcome)
        }
    }

    private var resolvingSection: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)

            Text("Checking your Journaltopia+ status…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
    }

    // MARK: - Costs

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storyboard Costs")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.storyInk)

            VStack(spacing: 10) {
                creditCostRow(
                    title: OpenAIImageGenerationQuality.standard.title,
                    subtitle: "Good for quick storyboards",
                    cost: OpenAIImageGenerationQuality.standard.creditCost
                )

                Divider()

                creditCostRow(
                    title: OpenAIImageGenerationQuality.highDefinition.title,
                    subtitle: "Sharper storyboard images",
                    cost: OpenAIImageGenerationQuality.highDefinition.creditCost
                )
            }
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
            )
        }
    }

    private func creditCostRow(title: String, subtitle: String, cost: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.storyInk.opacity(0.58))
            }

            Spacer()

            Text(formattedCreditCount(cost))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.homeAccent.opacity(0.1), in: Capsule())
        }
    }

    // MARK: - Text

    private var balanceText: String {
        guard let balance = generationCreditStore.balance else {
            return generationCreditStore.isRefreshing ? "..." : "-"
        }

        return String(balance)
    }

    private var balanceSubtitle: String {
        switch authStore.status {
        case .signedIn:
            return isSubscribed
                ? (JournaltopiaPlusFormatting.periodEndCaption(for: subscriptionStore.state) ?? "Journaltopia+ active")
                : "Journaltopia+ includes 25 credits a month"
        case .loading:
            return "Checking your account"
        case .misconfigured:
            return "Credits require Supabase"
        case .signedOut:
            return "Sign in to sync and use credits"
        }
    }

    /// Names the reset date when there is one, because "resets on the 3rd" is the fact a subscriber
    /// deciding whether to buy a pack actually needs.
    private var monthlyResetDetail: String {
        guard let periodEnd = subscriptionStore.state.currentPeriodEnd else {
            return "Monthly credits reset each period and do not roll over."
        }

        return "Resets \(JournaltopiaPlusFormatting.formatted(periodEnd)) · unused monthly credits do not roll over."
    }

    private var priceLine: String {
        guard let price = subscriptionStore.localizedPrice else {
            return "Fetching the current price…"
        }

        return "\(price) per month"
    }

    private func formattedCreditCount(_ count: Int) -> String {
        count == 1 ? "1 credit" : "\(count) credits"
    }
}
