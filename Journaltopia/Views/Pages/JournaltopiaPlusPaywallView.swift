import StoreKit
import SwiftUI

/// The Journaltopia+ plan picker.
///
/// Presented as a sheet by ``EntitlementGate``, and pushed as a page from Settings and the credits
/// screen. The two differ only in whether there is a close button.
///
/// The price is never written down here. `SubscriptionStore.localizedPrice` comes from the `Product`
/// StoreKit loaded, which is App Store Connect's price in the viewer's own currency and territory —
/// a "$14.99" literal would be wrong nearly everywhere and stale eventually. While the product is
/// still loading the button says so rather than showing a number that might be wrong.
struct JournaltopiaPlusPaywallView: View {
    enum Presentation {
        case sheet
        case page
    }

    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var signInGate: SignInGate

    let presentation: Presentation
    var promptTitle: String?
    var promptSubtitle: String?
    var onDismiss: (() -> Void)?
    var onFreePlan: (() -> Void)?
    var onPlanActivated: (() -> Void)?

    @State private var restoreOutcome: SubscriptionRestoreOutcome?

    private var isSignedIn: Bool {
        authStore.userID != nil
    }

    private var isPurchasing: Bool {
        subscriptionStore.purchasePhase == .purchasing
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                planCards
                purchaseSection
                reassurance
            }
            .padding(.horizontal, 24)
            .padding(.top, presentation == .sheet ? 36 : 18)
            .padding(.bottom, 30)
        }
        .background(WatercolorPaperPageBackground())
        .navigationTitle(presentation == .page ? "Choose Your Plan" : "")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            if presentation == .sheet {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.storyInk)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.82), in: Circle())
                        .contentShape(Circle())
                        .shadow(color: Color.storyInk.opacity(0.08), radius: 9, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padding(.leading, 22)
                .accessibilityLabel("Close")
            }
        }
        .task {
            // Loading the product is what makes a real price available. Safe to repeat: the store
            // keeps the first one it resolves.
            await subscriptionStore.refresh(isSignedIn: isSignedIn)
        }
        .onChange(of: subscriptionStore.state) { state in
            guard state.isSubscribed else {
                return
            }

            onPlanActivated?()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(promptTitle ?? "Choose your plan")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text(promptSubtitle ?? "Start for free. Upgrade anytime\nwhen you're ready.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, presentation == .sheet ? 46 : 0)
    }

    private var planCards: some View {
        VStack(spacing: 14) {
            freePlanCard
            plusPlanCard
        }
    }

    private var freePlanCard: some View {
        planCard(isHighlighted: false) {
            VStack(alignment: .leading, spacing: 12) {
                planHeader(
                    title: "Free",
                    subtitle: "Write your journal",
                    price: "$0",
                    caption: nil,
                    badge: nil
                )

                VStack(alignment: .leading, spacing: 12) {
                    featureRow("Write journal entries", isIncluded: true)
                    featureRow("Organize with journals", isIncluded: true)
                    featureRow("Add characters & reference photos", isIncluded: true)
                    featureRow("Generate storyboard images", isIncluded: false)
                    featureRow("Use AI credits", isIncluded: false)
                }

                planImage(name: "1-1", height: 94)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            onFreePlan?()
        }
    }

    private var plusPlanCard: some View {
        Button {
            startPurchase()
        } label: {
            planCard(isHighlighted: true) {
                VStack(alignment: .leading, spacing: 12) {
                    planHeader(
                        title: "Journaltopia Plus",
                        subtitle: "Generate storyboards",
                        price: plusPriceTitle,
                        caption: plusPriceCaption,
                        badge: "Most Popular"
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        featureRow("Everything in Free", isIncluded: true)
                        featureRow("Generate storyboard images\n(25 credits/month)", isIncluded: true)
                        featureRow("HD storyboard quality", isIncluded: true)
                        featureRow("Use credits for Standard or HD", isIncluded: true)
                        featureRow("Priority generation", isIncluded: true)
                    }

                    planImage(name: "2-2", height: 118)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || subscriptionStore.product == nil || subscriptionStore.state.isSubscribed)
        .opacity(subscriptionStore.product == nil || subscriptionStore.state.isSubscribed ? 0.72 : 1)
        .accessibilityLabel(primaryButtonTitle)
    }

    private func planCard<Content: View>(
        isHighlighted: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isHighlighted ? Color.storyPurple : Color.storyBorder.opacity(0.78), lineWidth: isHighlighted ? 1.7 : 1)
            )
    }

    private func planHeader(
        title: String,
        subtitle: String,
        price: String,
        caption: String?,
        badge: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 25, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Color.storyPurple.opacity(0.76), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 0) {
                Text(price)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                if let caption {
                    Text(caption)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.storyPurple)
                }
            }
        }
    }

    private func featureRow(_ text: String, isIncluded: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isIncluded ? "checkmark" : "xmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isIncluded ? Color.storyPurple : Color.storyGray.opacity(0.66))
                .frame(width: 16, height: 18)

            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isIncluded ? Color.storyInk : Color.homeMutedText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func planImage(name: String, height: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.74), lineWidth: 1)
            )
    }

    private var purchaseSection: some View {
        VStack(spacing: 10) {
            if subscriptionStore.state.isSubscribed {
                activeBanner
            } else if isPurchasing {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Color.storyPurple)

                    Text("Starting Journaltopia Plus...")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                }
                .frame(maxWidth: .infinity)
            }

            if subscriptionStore.purchasePhase == .awaitingApproval {
                noticeText(
                    "This purchase needs approval before it can finish. Journaltopia will unlock as soon as it is approved.",
                    tint: Color.storyPurple
                )
            }

            if let errorMessage = subscriptionStore.errorMessage {
                noticeText(errorMessage, tint: Color.red.opacity(0.85))
            }

            RestorePurchasesButton(outcome: $restoreOutcome)
        }
    }

    /// The promise worth making explicitly, because it is a thing people reasonably fear about a
    /// subscription attached to their own writing.
    private var reassurance: some View {
        Text("Cancel anytime. No commitment.")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.homeMutedText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var activeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.storyPurple)

            VStack(alignment: .leading, spacing: 2) {
                Text("Journaltopia+ is active")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(JournaltopiaPlusFormatting.renewalCaption(for: subscriptionStore.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.4), lineWidth: 1)
        )
    }

    private func noticeText(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryButtonTitle: String {
        if isPurchasing {
            return "Starting Journaltopia Plus"
        }

        return subscriptionStore.product == nil ? "Loading Journaltopia Plus" : "Start Journaltopia Plus"
    }

    private var plusPriceTitle: String {
        guard let price = subscriptionStore.localizedPrice else {
            return "Loading"
        }

        return price
    }

    private var plusPriceCaption: String? {
        subscriptionStore.localizedPrice == nil ? nil : "/month"
    }

    private func startPurchase() {
        guard signInGate.requireAccount(for: .spendCredits) else {
            return
        }

        Task {
            await subscriptionStore.purchaseJournaltopiaPlus(isSignedIn: isSignedIn)
            await generationCreditStore.refresh(isSignedIn: isSignedIn)
            if subscriptionStore.state.isSubscribed {
                onPlanActivated?()
            }
        }
    }
}

/// Shared restore control, so the paywall, the credits screen and Settings all behave identically
/// and report the same three outcomes.
struct RestorePurchasesButton: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore

    @Binding var outcome: SubscriptionRestoreOutcome?
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                restore()
            } label: {
                HStack(spacing: 7) {
                    if isRestoring {
                        ProgressView().controlSize(.small)
                    }

                    Text(isRestoring ? "Restoring…" : "Restore Purchases")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)

            if let outcome {
                Text(outcome.message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(outcome.isSuccess ? Color.storyPurple : Color.homeMutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func restore() {
        isRestoring = true
        outcome = nil

        Task {
            let result = await subscriptionStore.restorePurchases(isSignedIn: authStore.userID != nil)
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
            outcome = result
            isRestoring = false
        }
    }
}

extension View {
    /// Apple's own Manage Subscriptions sheet, where the platform offers one.
    ///
    /// Preferred over an `itms-apps://` URL because Apple owns these flows — cancelling, changing
    /// plan, requesting a refund — and a hand-built deep link goes stale silently. On a platform
    /// without the sheet the modifier is a no-op rather than a broken button.
    @ViewBuilder
    func manageSubscriptionsSheetIfAvailable(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.manageSubscriptionsSheet(isPresented: isPresented)
        #else
        self
        #endif
    }
}

/// Date and status wording used by every Journaltopia+ surface, so "renews 3 September" reads the
/// same in Settings, on the paywall and on the credits screen.
/// How the two buckets are written, in one place, so "12 monthly · 20 purchased" reads the same
/// everywhere it appears.
enum CreditBucketFormatting {
    /// `12 monthly · 20 purchased`, or nil when there is nothing worth splitting out — an account
    /// with credits in only one bucket is better served by the total alone.
    static func split(for store: GenerationCreditStore) -> String? {
        guard let credits = store.credits, credits.total > 0 else {
            return nil
        }

        guard credits.monthly > 0, credits.purchased > 0 else {
            return credits.purchased > 0 ? "\(credits.purchased) purchased" : "\(credits.monthly) monthly"
        }

        return "\(credits.monthly) monthly · \(credits.purchased) purchased"
    }

    /// The one sentence that explains the difference. Shown on the credits screen and nowhere else —
    /// repeating it on every surface would be noise.
    static let explanation =
        "Monthly credits reset each billing period. Purchased credits never expire."
}

enum JournaltopiaPlusFormatting {
    static func renewalCaption(for state: JournaltopiaPlusState) -> String {
        guard let periodEnd = state.currentPeriodEnd else {
            return "Includes 25 AI credits each month."
        }

        return "Renews \(formatted(periodEnd)) · 25 credits each period."
    }

    static func periodEndCaption(for state: JournaltopiaPlusState) -> String? {
        state.currentPeriodEnd.map { "Current period ends \(formatted($0))" }
    }

    static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
