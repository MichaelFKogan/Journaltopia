import Foundation
import Supabase

/// Asks the server to permanently delete the signed-in account.
///
/// Deliberately shaped like ``CreditPackRedemptionService``. The request names no account: the only
/// field it can carry is a fresh Sign in with Apple authorization code, which is a *credential*, not
/// a claim about who is calling. `delete-account` reads the account out of the JWT and works on that,
/// and it checks any Apple code against the identity already linked to that account before using it.
/// A modified client can ask to delete *itself*, which it is already entitled to do, and there is no
/// field in which it could name somebody else.
///
/// The service role key is not here and cannot be: cascading a user out of `auth.users` needs admin
/// authority, so that authority lives in the Edge Function where the app cannot reach it.
struct AccountDeletionService {
    private let client: SupabaseClient
    /// Deletion sweeps every private object the account owns before it removes the user, so this is
    /// sized for an account with a lot of storyboards rather than for a typical round trip.
    private let requestTimeout: TimeInterval = 60

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    private struct DeletePayload: Encodable {
        let appleAuthorizationCode: String
    }

    struct DeleteErrorResponse: Decodable {
        let error: String?
        let code: String?
    }

    /// Returns once the account is gone. Anything else throws.
    ///
    /// Safe to call again after a failure: the server's sweep is idempotent, so a retry picks up
    /// wherever the last attempt stopped rather than tripping over what it already removed.
    /// - Parameter appleAuthorizationCode: A code obtained from Apple moments ago, for accounts with
    ///   a Sign in with Apple identity. `nil` for Google and email-only accounts, which the server
    ///   never takes to Apple.
    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            throw AccountDeletionError.notAuthenticated
        }

        let request = try Self.makeRequest(
            projectURL: try JournaltopiaSupabaseConfig.projectURL,
            anonKey: try JournaltopiaSupabaseConfig.anonKey,
            accessToken: session.accessToken,
            timeout: requestTimeout,
            appleAuthorizationCode: appleAuthorizationCode
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionError.unavailable
        }

        try Self.validate(response: httpResponse, data: data)
    }

    /// Builds the request, and is separated out so the shape of it can be asserted in a test.
    ///
    /// The account to delete is the bearer of this token, decided server-side; there is deliberately
    /// nowhere in this request to name a different one. The body, when there is one, carries only an
    /// Apple authorization code — a credential the server verifies belongs to this same account.
    static func makeRequest(
        projectURL: URL,
        anonKey: String,
        accessToken: String,
        timeout: TimeInterval,
        appleAuthorizationCode: String? = nil
    ) throws -> URLRequest {
        let functionURL = projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("delete-account")

        var request = URLRequest(url: functionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        // Omitted entirely for a non-Apple account, so the server's ordinary path stays bodyless.
        if let appleAuthorizationCode {
            request.httpBody = try JSONEncoder().encode(
                DeletePayload(appleAuthorizationCode: appleAuthorizationCode)
            )
        }

        return request
    }

    /// Turns the server's answer into either "the account is gone" or a retryable error.
    ///
    /// Success is only ever a 2xx, which `delete-account` returns after the auth user has actually
    /// been deleted — so there is no status here that reports success for a half-finished deletion.
    static func validate(response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else {
            return
        }

        let failure = try? JSONDecoder().decode(DeleteErrorResponse.self, from: data)

        // The session no longer identifies anyone — either it expired, or an earlier attempt already
        // deleted the account. Both mean "sign in again", and neither is worth retrying as-is.
        if response.statusCode == 401 {
            throw AccountDeletionError.notAuthenticated
        }

        // Apple refused, or was not reachable. Nothing has been deleted — the server revokes before it
        // touches anything — so these are reported in Apple's own terms rather than as a generic
        // failure, because what to do next differs: re-confirm with Apple, or simply try again.
        switch failure?.code {
        case "apple_reauthorization_required":
            throw AccountDeletionError.appleReauthorizationRequired
        case "apple_identity_mismatch":
            throw AccountDeletionError.appleIdentityMismatch
        case "apple_unreachable", "apple_exchange_failed",
             "apple_revocation_failed", "apple_not_configured":
            throw AccountDeletionError.appleRevocationFailed
        default:
            break
        }

        print("[Journaltopia] Account deletion failed: \(response.statusCode) \(failure?.error ?? "")")
        throw AccountDeletionError.unavailable
    }
}

enum AccountDeletionError: LocalizedError {
    case notAuthenticated
    case unavailable
    case appleReauthorizationRequired
    case appleIdentityMismatch
    case appleRevocationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in again before deleting your account."
        case .appleReauthorizationRequired:
            return "Your Apple confirmation expired. Please try deleting your account again."
        case .appleIdentityMismatch:
            return "That Apple ID is not the one linked to this Journaltopia account."
        case .appleRevocationFailed:
            // Deliberately not a success. Deleting the account without revoking Journaltopia's Apple
            // authorization would leave the app authorized under the person's Apple ID, which is the
            // thing Guideline 5.1.1(v) exists to prevent — so deletion stops here and is retried.
            return "Journaltopia could not remove its access to your Apple ID. Please try again."
        case .unavailable:
            // Every server-side failure lands here, and every one of them is retryable: the account
            // is only reported deleted once it actually is, so a failure means nothing was lost and
            // pressing the button again resumes.
            return "Your account could not be deleted. Please try again."
        }
    }
}
