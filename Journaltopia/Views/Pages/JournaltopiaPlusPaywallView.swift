import StoreKit
import SwiftUI

/// The Journaltopia+ paywall.
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

    @State private var restoreOutcome: SubscriptionRestoreOutcome?

    private var isSignedIn: Bool {
        authStore.userID != nil
    }

    private var isPurchasing: Bool {
        subscriptionStore.purchasePhase == .purchasing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                benefits
                creditCosts
                reassurance
                purchaseSection
            }
            .padding(.horizontal, 20)
            .padding(.top, presentation == .sheet ? 8 : 18)
            .padding(.bottom, 28)
        }
        .background(Color.homePageBackground)
        .navigationTitle(presentation == .page ? "Journaltopia+" : "")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .overlay(alignment: .topTrailing) {
            if presentation == .sheet {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.55))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.9), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.trailing, 16)
                .accessibilityLabel("Close")
            }
        }
        .task {
            // Loading the product is what makes a real price available. Safe to repeat: the store
            // keeps the first one it resolves.
            await subscriptionStore.refresh(isSignedIn: isSignedIn)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 54, height: 54)
                .background(Color.storyPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(promptTitle ?? "Journaltopia+")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(promptSubtitle ?? "Turn your entries into AI graphic novel pages, with 25 AI credits every month.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, presentation == .sheet ? 18 : 0)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 0) {
            benefitRow(
                icon: "wand.and.stars",
                title: "AI storyboard generation",
                detail: "The whole reason Journaltopia+ exists."
            )
            Divider().padding(.leading, 46)
            benefitRow(
                icon: "sparkle",
                title: "25 AI credits every month",
                detail: "Monthly credits reset each billing period."
            )
            Divider().padding(.leading, 46)
            benefitRow(
                icon: "square.stack.3d.up",
                title: "Standard and HD pages",
                detail: "Choose the quality that suits the memory."
            )
        }
        .padding(.vertical, 4)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
    }

    private func benefitRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 34, height: 34)
                .background(Color.homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var creditCosts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What a page costs")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)

            HStack(spacing: 10) {
                costChip(
                    title: OpenAIImageGenerationQuality.standard.title,
                    cost: OpenAIImageGenerationQuality.standard.creditCost
                )
                costChip(
                    title: OpenAIImageGenerationQuality.highDefinition.title,
                    cost: OpenAIImageGenerationQuality.highDefinition.creditCost
                )
            }
        }
    }

    private func costChip(title: String, cost: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text(cost == 1 ? "1 credit" : "\(cost) credits")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
    }

    /// The two promises worth making explicitly, because both are things people reasonably fear
    /// about a subscription attached to their own writing.
    private var reassurance: some View {
        VStack(alignment: .leading, spacing: 9) {
            reassuranceRow("Writing, journals, characters and photos stay free — always.")
            reassuranceRow("Pages you have already generated stay yours to read, even if you cancel.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.storyPurple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reassuranceRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.storyPurple.opacity(0.85))

            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if subscriptionStore.state.isSubscribed {
                activeBanner
            } else {
                Button {
                    startPurchase()
                } label: {
                    HStack(spacing: 8) {
                        if isPurchasing {
                            ProgressView().tint(.white)
                        }

                        Text(primaryButtonTitle)
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
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
                .disabled(isPurchasing || subscriptionStore.product == nil)
                .opacity(subscriptionStore.product == nil ? 0.55 : 1)
                .accessibilityLabel(primaryButtonTitle)

                Text(priceCaption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)
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
            return "Starting…"
        }

        return subscriptionStore.product == nil ? "Loading Journaltopia+…" : "Start Journaltopia+"
    }

    /// Never invents a price. An unresolved product says so instead of showing a number.
    private var priceCaption: String {
        guard let price = subscriptionStore.localizedPrice else {
            return "Fetching the current price from the App Store…"
        }

        return "\(price) per month. Cancel anytime in Settings."
    }

    private func startPurchase() {
        guard signInGate.requireAccount(for: .spendCredits) else {
            return
        }

        Task {
            await subscriptionStore.purchaseJournaltopiaPlus(isSignedIn: isSignedIn)
            await generationCreditStore.refresh(isSignedIn: isSignedIn)
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
