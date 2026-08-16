import Foundation
import Supabase

/// What the server decided after verifying an Apple transaction with Apple.
struct AppleSubscriptionSyncResult: Decodable, Sendable {
    let isEntitled: Bool
    let status: String
    let productID: String?
    let currentPeriodEnd: Date?
    let grantedCredits: Int
    let creditBalance: Int?

    enum CodingKeys: String, CodingKey {
        case isEntitled
        case status
        case productID
        case currentPeriodEnd
        case grantedCredits
        case creditBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEntitled = try container.decodeIfPresent(Bool.self, forKey: .isEntitled) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "expired"
        productID = try container.decodeIfPresent(String.self, forKey: .productID)
        grantedCredits = try container.decodeIfPresent(Int.self, forKey: .grantedCredits) ?? 0
        creditBalance = try container.decodeIfPresent(Int.self, forKey: .creditBalance)

        // The server answers in ISO-8601 with fractional seconds; the fallback covers a timestamp
        // that arrives without them rather than failing the whole sync over formatting.
        if let raw = try container.decodeIfPresent(String.self, forKey: .currentPeriodEnd) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: raw) {
                currentPeriodEnd = parsed
            } else {
                formatter.formatOptions = [.withInternetDateTime]
                currentPeriodEnd = formatter.date(from: raw)
            }
        } else {
            currentPeriodEnd = nil
        }
    }
}

enum AppleSubscriptionSyncError: LocalizedError, Equatable {
    case notAuthenticated
    /// This Apple subscription already belongs to a different Journaltopia account. There is no safe
    /// automatic resolution — re-pointing it would take an active subscription away from whoever is
    /// currently using it — so it is surfaced as its own case for Phase 4 to explain.
    case alreadyBoundToAnotherAccount
    case verificationFailed(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to link your Journaltopia+ subscription to your account."
        case .alreadyBoundToAnotherAccount:
            return "This Apple subscription is already linked to a different Journaltopia account."
        case .verificationFailed(let message):
            return message
        case .unavailable:
            return "Your subscription could not be synced right now. Please try again."
        }
    }
}

/// Sends a signed Apple transaction to the server for verification.
///
/// The app deliberately sends almost nothing: the JWS Apple gave StoreKit, and nothing else. No
/// product id, no expiry, no user id, and above all no "I am subscribed" flag. Every value the
/// server records is read out of the payload Apple signed, and the account it is bound to comes from
/// the caller's own Supabase session — so a modified client can lie about neither.
struct AppleSubscriptionSyncService {
    private let client: SupabaseClient
    private let requestTimeout: TimeInterval = 30

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    private struct SyncPayload: Encodable {
        let signedTransactionInfo: String
        let signedRenewalInfo: String?
    }

    private struct SyncErrorResponse: Decodable {
        let error: String?
        let code: String?
    }

    func sync(
        signedTransactionInfo: String,
        signedRenewalInfo: String?
    ) async throws -> AppleSubscriptionSyncResult {
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            throw AppleSubscriptionSyncError.notAuthenticated
        }

        let projectURL = try JournaltopiaSupabaseConfig.projectURL
        let anonKey = try JournaltopiaSupabaseConfig.anonKey
        let functionURL = projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("sync-apple-subscription")

        var request = URLRequest(url: functionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(
            SyncPayload(
                signedTransactionInfo: signedTransactionInfo,
                signedRenewalInfo: signedRenewalInfo
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppleSubscriptionSyncError.unavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let failure = try? JSONDecoder().decode(SyncErrorResponse.self, from: data)

            if failure?.code == "already_bound_to_another_account" || httpResponse.statusCode == 409 {
                throw AppleSubscriptionSyncError.alreadyBoundToAnotherAccount
            }

            if httpResponse.statusCode == 401 {
                throw AppleSubscriptionSyncError.verificationFailed(
                    failure?.error ?? "This purchase could not be verified with Apple."
                )
            }

            print("[Journaltopia] Apple subscription sync failed: \(httpResponse.statusCode) \(failure?.error ?? "")")
            throw AppleSubscriptionSyncError.unavailable
        }

        do {
            return try JSONDecoder().decode(AppleSubscriptionSyncResult.self, from: data)
        } catch {
            print("[Journaltopia] Apple subscription sync response unreadable: \(error)")
            throw AppleSubscriptionSyncError.unavailable
        }
    }
}

/// The server's own view of this account's plan, read through RLS.
///
/// This is the authoritative answer for anything that gates on Journaltopia+. StoreKit's opinion is
/// what the app uses to know a purchase happened; this is what the app uses to know the server
/// agrees, and the server is what `generate-storyboard` consults.
struct JournaltopiaPlusEntitlementService {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    private struct EntitlementRow: Decodable {
        let isActive: Bool
        let productID: String?
        let currentPeriodEnd: Date?
        let generationCredits: Int

        enum CodingKeys: String, CodingKey {
            case isActive = "is_active"
            case productID = "product_id"
            case currentPeriodEnd = "current_period_end"
            case generationCredits = "generation_credits"
        }
    }

    func fetchEntitlement() async throws -> JournaltopiaPlusState {
        do {
            _ = try await client.auth.session
        } catch {
            return .signedOut
        }

        let rows: [EntitlementRow] = try await client
            .from("journaltopia_plus_entitlement")
            .select()
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else {
            return .notSubscribed
        }

        return row.isActive
            ? .subscribed(productID: row.productID, currentPeriodEnd: row.currentPeriodEnd)
            : .notSubscribed
    }
}
