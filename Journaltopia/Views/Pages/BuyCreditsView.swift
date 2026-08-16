import StoreKit
import SwiftUI

/// The "you have run out of credits" screen, presented by ``EntitlementGate`` when a subscriber
/// cannot afford the generation they asked for — or when the server says so with a 402.
///
/// Distinct from the paywall on purpose. Someone here is already paying; showing them "Start
/// Journaltopia+" would be both wrong and insulting. What they need is the balance, when the next 25
/// arrive, and the option to top up.
struct BuyCreditsView: View {
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var authStore: SupabaseAuthStore

    var promptTitle: String?
    var promptSubtitle: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                balanceCard
                CreditPackSection()
                renewalNote
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color.homePageBackground)
        .preferredColorScheme(.light)
        .overlay(alignment: .topTrailing) {
            if onDismiss != nil {
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
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 50, height: 50)
                .background(Color.homeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(promptTitle ?? "Not Enough Credits")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .fixedSize(horizontal: false, vertical: true)

            if let promptSubtitle {
                Text(promptSubtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 18)
    }

    private var balanceCard: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your balance")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Text(generationCreditStore.balance.map { "\($0)" } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.storyInk)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                costLine(OpenAIImageGenerationQuality.standard)
                costLine(OpenAIImageGenerationQuality.highDefinition)
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
    }

    private func costLine(_ quality: OpenAIImageGenerationQuality) -> some View {
        Text("\(quality.title) · \(quality.creditCost == 1 ? "1 credit" : "\(quality.creditCost) credits")")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.homeMutedText)
    }

    private var renewalNote: some View {
        Text(JournaltopiaPlusFormatting.renewalCaption(for: subscriptionStore.state))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.homeMutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The credit packs, shown with real App Store prices where StoreKit has them.
///
/// Purchasing is disabled, and the reason is stated rather than hidden behind a button that fails.
/// See ``CreditPackPurchasing`` for what the server still needs before this can be switched on — the
/// alternative, granting credits when StoreKit reports success, is exactly the client-trusting
/// shortcut the rest of this system exists to avoid.
struct CreditPackSection: View {
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    @State private var selectedPack: JournaltopiaProducts.CreditPack = .twentyFive

    private var availability: CreditPackPurchasing.Availability {
        CreditPackPurchasing.availability(isSubscribed: subscriptionStore.state.isSubscribed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add more credits")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.storyInk)

            VStack(spacing: 10) {
                ForEach(JournaltopiaProducts.CreditPack.allCases) { pack in
                    Button {
                        selectedPack = pack
                    } label: {
                        CreditPackRow(
                            pack: pack,
                            price: price(for: pack),
                            isSelected: selectedPack == pack
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(availability != .available)
                    .accessibilityLabel("\(pack.title), \(price(for: pack) ?? "price unavailable")")
                }
            }

            Button {
                // Intentionally inert. Left in place so the shape of the flow is visible and Phase 5
                // is a wiring change, but it must never grant credits from the client.
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.homeAccent.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityHint(explanation)

            Text(explanation)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttonTitle: String {
        availability == .requiresSubscription
            ? "Journaltopia+ Required"
            : "Buy \(selectedPack.title)"
    }

    private var explanation: String {
        switch availability {
        case .requiresSubscription:
            return "Credit packs are available to Journaltopia+ members."
        case .awaitingServerVerification, .available:
            return CreditPackPurchasing.unavailableExplanation
        }
    }

    /// The App Store's price when StoreKit has the product, and nothing invented when it does not.
    private func price(for pack: JournaltopiaProducts.CreditPack) -> String? {
        subscriptionStore.creditPackProducts.first { $0.id == pack.rawValue }?.displayPrice
    }
}

private struct CreditPackRow: View {
    let pack: JournaltopiaProducts.CreditPack
    let price: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isSelected ? Color.homeAccent : Color.storyInk.opacity(0.26))
                .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 3) {
                Text(pack.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(pack.detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }

            Spacer(minLength: 0)

            Text(price ?? "—")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(price == nil ? Color.homeMutedText : Color.storyInk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.homeAccent : Color.storyBorder.opacity(0.62), lineWidth: isSelected ? 1.5 : 1)
        )
        .opacity(0.92)
    }
}
