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
            return "Sign in before generating a storyboard."
        case .insufficientCredits:
            return "You do not have enough credits to generate this storyboard."
        case .unavailable:
            return "Credits are unavailable right now. Please try again."
        }
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
            throw GenerationCreditError.unavailable
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
            throw GenerationCreditError.insufficientCredits
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
            throw GenerationCreditError.unavailable
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

    func canSpend(_ cost: Int) -> Bool {
        guard let balance else {
            return true
        }

        return balance >= cost
    }

    func spend(_ cost: Int) async throws {
        let updatedBalance = try await service.spendCredit(cost: cost)
        balance = updatedBalance
        errorMessage = nil
    }

    func setBalance(_ newBalance: Int) async throws {
        let updatedBalance = try await service.setBalance(newBalance)
        balance = updatedBalance
        errorMessage = nil
    }
}
