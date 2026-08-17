import Foundation
import Combine
import Supabase

/// The two balances, and the total the app usually shows.
///
/// They behave differently and the difference is visible to the user, so it is modelled rather than
/// summed away: monthly credits are replaced at each renewal and vanish when a subscription lapses,
/// purchased credits never expire. The total is derived here for the same reason it is derived in
/// the database — one place, no drift.
struct GenerationCreditBalance: Decodable, Sendable, Equatable {
    let monthly: Int
    let purchased: Int

    var total: Int {
        monthly + purchased
    }

    static let empty = GenerationCreditBalance(monthly: 0, purchased: 0)

    init(monthly: Int, purchased: Int) {
        self.monthly = max(0, monthly)
        self.purchased = max(0, purchased)
    }

    enum CodingKeys: String, CodingKey {
        case monthly = "monthly_generation_credits"
        case purchased = "purchased_generation_credits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            monthly: try container.decodeIfPresent(Int.self, forKey: .monthly) ?? 0,
            purchased: try container.decodeIfPresent(Int.self, forKey: .purchased) ?? 0
        )
    }
}

enum GenerationCreditError: LocalizedError {
    case notAuthenticated
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Your session expired. Sign in again before generating a storyboard."
        case .unavailable:
            return "Credits are unavailable right now. Please try again."
        }
    }

    /// A failure here is either an expired session or something transient. It is never "you are out
    /// of credits": this type only reads the balance now, and the one operation that can run out —
    /// reserving a generation — reports that itself, as a 402 from `generate-storyboard`.
    static func mapped(from error: Error, context: String) -> GenerationCreditError {
        print("[Journaltopia] \(context) failed: \(error)")

        if let creditError = error as? GenerationCreditError {
            return creditError
        }

        if let postgrestError = error as? PostgrestError,
           postgrestError.message.lowercased().contains("not_authenticated") {
            return .notAuthenticated
        }

        return .unavailable
    }
}

/// Read-only. The balance is server-owned: it is spent by `reserve_storyboard_generation` and
/// returned by the storyboard lifecycle's failing transition, both inside the database, and the app
/// has no privilege to write `profiles.generation_credits` at all. Anything here that mutated it
/// was either dead or a way around that, so the whole mutation surface is gone.
struct GenerationCreditService {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    /// Reads both buckets straight from the profile. The app never derives them from ledger history —
    /// the balances are columns, and replaying a ledger to find out what someone has would be both
    /// slower and a second source of truth.
    func fetchBalance() async throws -> GenerationCreditBalance {
        let userID = try await authenticatedUserID()

        do {
            let row: GenerationCreditBalance = try await client
                .from("profiles")
                .select("monthly_generation_credits,purchased_generation_credits")
                .eq("id", value: userID)
                .single()
                .execute()
                .value

            return row
        } catch {
            throw GenerationCreditError.mapped(from: error, context: "fetch generation credits")
        }
    }

    private func authenticatedUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw GenerationCreditError.notAuthenticated
        }
    }
}

@MainActor
final class GenerationCreditStore: ObservableObject {
    /// Both buckets, or nil when nothing has been read yet. Nil is not zero — see ``canSpend(_:)``.
    @Published private(set) var credits: GenerationCreditBalance?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let service: GenerationCreditService

    init(service: GenerationCreditService = GenerationCreditService()) {
        self.service = service
    }

    /// The total, for the many places that only care how many credits there are.
    var balance: Int? {
        credits?.total
    }

    var monthlyCredits: Int? {
        credits?.monthly
    }

    var purchasedCredits: Int? {
        credits?.purchased
    }

    func reset() {
        credits = nil
        isRefreshing = false
        errorMessage = nil
    }

    func refresh(isSignedIn: Bool) async {
        guard isSignedIn else {
            reset()
            return
        }

        isRefreshing = true
        errorMessage = nil

        do {
            credits = try await service.fetchBalance()
        } catch {
            errorMessage = error.localizedDescription
        }

        isRefreshing = false
    }

    /// Adopts balances the server just returned, so a purchase or redemption shows immediately
    /// rather than after another round trip. Only ever called with values the server computed.
    func apply(_ balance: GenerationCreditBalance) {
        credits = balance
        errorMessage = nil
    }

    /// True only when a balance has actually been read from Supabase.
    var hasKnownBalance: Bool {
        credits != nil
    }

    /// Fails closed: an unknown balance is not permission to spend, it is a reason to refresh.
    ///
    /// Spends against the total, because the server spends monthly first and falls through to
    /// purchased — a cost the two buckets can only cover together is still affordable.
    func canSpend(_ cost: Int) -> Bool {
        guard let credits else {
            return false
        }

        return credits.total >= cost
    }
}
