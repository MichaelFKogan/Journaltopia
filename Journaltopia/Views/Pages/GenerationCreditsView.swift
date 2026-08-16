import SwiftUI

struct GenerationCreditsView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var signInGate: SignInGate

    @State private var selectedPack = CreditPack.featured
    @State private var isPurchaseUnavailableAlertPresented = false

    private let creditPacks = CreditPack.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                balanceSection
                usageSection
                pricingSection
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
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
        .alert("Purchases Coming Soon", isPresented: $isPurchaseUnavailableAlertPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Credit purchases are not connected in this build yet.")
        }
    }

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
                    .frame(width: 48, height: 48)
                    .background(Color.homeAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Generation Credits")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text(balanceSubtitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.storyInk.opacity(0.64))
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
                }
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

    private var pricingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Buy More Credits")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.storyInk)

            VStack(spacing: 10) {
                ForEach(creditPacks) { pack in
                    Button {
                        selectedPack = pack
                    } label: {
                        CreditPackRow(pack: pack, isSelected: selectedPack == pack)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pack.title), \(pack.price)")
                    .accessibilityHint("Selects this credit pack")
                }
            }

            Button {
                guard signInGate.requireAccount(for: .spendCredits) else {
                    return
                }

                isPurchaseUnavailableAlertPresented = true
            } label: {
                Text(purchaseButtonTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Purchasing is not available in this build")

            Text("Purchases are not connected in this build yet.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
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

    private var balanceText: String {
        guard let balance = generationCreditStore.balance else {
            return generationCreditStore.isRefreshing ? "..." : "-"
        }

        return String(balance)
    }

    private var balanceSubtitle: String {
        switch authStore.status {
        case .signedIn:
            return authStore.email ?? "Your current balance"
        case .loading:
            return "Checking your account"
        case .misconfigured:
            return "Credits require Supabase"
        case .signedOut:
            return "Sign in to sync and use credits"
        }
    }

    private var purchaseButtonTitle: String {
        "Buy \(selectedPack.title)"
    }

    private func formattedCreditCount(_ count: Int) -> String {
        count == 1 ? "1 credit" : "\(count) credits"
    }
}

private struct CreditPack: Identifiable, Hashable {
    let id: Int
    let title: String
    let detail: String
    let price: String

    static let all = [
        CreditPack(id: 10, title: "10 Credits", detail: "Starter pack", price: "$2.99"),
        CreditPack(id: 25, title: "25 Credits", detail: "Best for a few journals", price: "$5.99"),
        CreditPack(id: 60, title: "60 Credits", detail: "Most flexible", price: "$11.99")
    ]

    static var featured: CreditPack {
        all[1]
    }
}

private struct CreditPackRow: View {
    let pack: CreditPack
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? Color.homeAccent : Color.storyInk.opacity(0.28))
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(pack.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(pack.detail)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.storyInk.opacity(0.58))
            }

            Spacer()

            Text(pack.price)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyInk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.homeAccent : Color.storyBorder.opacity(0.62), lineWidth: isSelected ? 1.5 : 1)
        )
    }
}
