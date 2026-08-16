import Foundation
import Combine
import Supabase

struct GenerationCreditBalance: Decodable, Sendable {
    let generationCredits: Int

    enum CodingKeys: String, CodingKey {
        case generationCredits = "generation_credits"
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
        print("[Storytopia] \(context) failed: \(error)")

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
}
