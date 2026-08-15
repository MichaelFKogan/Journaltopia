import Foundation
import Combine
import Supabase

struct GenerationCreditBalance: Decodable, Sendable {
    let generationCredits: Int

    enum CodingKeys: String, CodingKey {
        case generationCredits = "generation_credits"
    }
}

private struct GenerationCreditSpendPayload: Encodable, Sendable {
    let creditCost: Int

    enum CodingKeys: String, CodingKey {
        case creditCost = "credit_cost"
    }
}

private struct GenerationCreditUpdate: Encodable, Sendable {
    let generationCredits: Int

    enum CodingKeys: String, CodingKey {
        case generationCredits = "generation_credits"
    }
}

enum GenerationCreditError: LocalizedError {
    case notAuthenticated
    case insufficientCredits
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Your session expired. Sign in again before generating a storyboard."
        case .insufficientCredits:
            return "You do not have enough credits to generate this storyboard."
        case .unavailable:
            return "Credits are unavailable right now. Please try again."
        }
    }

    /// The credit RPCs raise named exceptions, so a failure only means "insufficient credits" when
    /// Postgres says so. Everything else — an expired session, a dropped connection, a decode
    /// failure — used to be relabelled as an empty balance, which made real problems unreadable.
    static func mapped(from error: Error, context: String) -> GenerationCreditError {
        print("[Storytopia] \(context) failed: \(error)")

        if let creditError = error as? GenerationCreditError {
            return creditError
        }

        if let postgrestError = error as? PostgrestError {
            let message = postgrestError.message.lowercased()

            if message.contains("insufficient_generation_credits") {
                return .insufficientCredits
            }

            if message.contains("not_authenticated") {
                return .notAuthenticated
            }
        }

        return .unavailable
    }
}

struct GenerationCreditService {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func fetchBalance() async throws -> Int {
        let userID = try await authenticatedUserID()

        do {
            let row: GenerationCreditBalance = try await client
                .from("profiles")
                .select("generation_credits")
                .eq("id", value: userID)
                .single()
                .execute()
                .value

            return max(0, row.generationCredits)
        } catch {
            throw GenerationCreditError.mapped(from: error, context: "fetch generation credits")
        }
    }

    func spendCredit(cost: Int) async throws -> Int {
        guard cost > 0 else {
            return try await fetchBalance()
        }

        do {
            let balance: Int = try await client
                .rpc(
                    "spend_generation_credit",
                    params: GenerationCreditSpendPayload(creditCost: cost)
                )
                .execute()
                .value

            return max(0, balance)
        } catch {
            throw GenerationCreditError.mapped(from: error, context: "spend_generation_credit")
        }
    }

    /// Returns a reserved credit when the generation it was reserved for never produced an image.
    func refundCredit(cost: Int) async throws -> Int {
        guard cost > 0 else {
            return try await fetchBalance()
        }

        do {
            let balance: Int = try await client
                .rpc(
                    "refund_generation_credit",
                    params: GenerationCreditSpendPayload(creditCost: cost)
                )
                .execute()
                .value

            return max(0, balance)
        } catch {
            throw GenerationCreditError.mapped(from: error, context: "refund_generation_credit")
        }
    }

    func setBalance(_ balance: Int) async throws -> Int {
        let userID = try await authenticatedUserID()
        let clampedBalance = max(0, balance)

        do {
            try await client
                .from("profiles")
                .update(GenerationCreditUpdate(generationCredits: clampedBalance))
                .eq("id", value: userID)
                .execute()

            return try await fetchBalance()
        } catch {
            throw GenerationCreditError.mapped(from: error, context: "set generation credits")
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
    @Published private(set) var balance: Int?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let service: GenerationCreditService

    init(service: GenerationCreditService = GenerationCreditService()) {
        self.service = service
    }

    func reset() {
        balance = nil
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
            balance = try await service.fetchBalance()
        } catch {
            errorMessage = error.localizedDescription
        }

        isRefreshing = false
    }

    /// True only when a balance has actually been read from Supabase.
    var hasKnownBalance: Bool {
        balance != nil
    }

    /// Fails closed: an unknown balance is not permission to spend, it is a reason to refresh.
    func canSpend(_ cost: Int) -> Bool {
        guard let balance else {
            return false
        }

        return balance >= cost
    }

    func spend(_ cost: Int) async throws {
        let updatedBalance = try await service.spendCredit(cost: cost)
        balance = updatedBalance
        errorMessage = nil
    }

    /// Best-effort return of a reserved credit. A failure here must not replace the error that
    /// caused the refund, so it is logged and the stale balance is re-read instead of thrown.
    func refundQuietly(_ cost: Int) async {
        do {
            balance = try await service.refundCredit(cost: cost)
        } catch {
            print("[Storytopia] Could not refund \(cost) generation credit(s): \(error.localizedDescription)")
            balance = try? await service.fetchBalance()
        }
    }

    func setBalance(_ newBalance: Int) async throws {
        let updatedBalance = try await service.setBalance(newBalance)
        balance = updatedBalance
        errorMessage = nil
    }
}
