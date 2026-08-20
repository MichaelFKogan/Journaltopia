import XCTest
@testable import Journaltopia

/// Covers the client's half of account deletion: that the request cannot name an account, and that
/// the app only believes a deletion happened when the server actually says so.
///
/// The server's half — cascades, the storage sweep, authorization, retries — is covered where it can
/// actually be exercised: `supabase/tests/account_deletion_test.sql` and
/// `supabase/tests/delete_account_integration.sh`.
final class AccountDeletionTests: XCTestCase {

    private let projectURL = URL(string: "https://example.supabase.co")!

    private func request(
        accessToken: String = "test-access-token",
        appleAuthorizationCode: String? = nil
    ) throws -> URLRequest {
        try AccountDeletionService.makeRequest(
            projectURL: projectURL,
            anonKey: "test-anon-key",
            accessToken: accessToken,
            timeout: 60,
            appleAuthorizationCode: appleAuthorizationCode
        )
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: projectURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - The request names no account

    /// A Google or email-only account sends nothing at all, and never involves Apple.
    func testNonAppleRequestCarriesNoBody() throws {
        XCTAssertNil(try request().httpBody)
        XCTAssertNil(try request().httpBodyStream)
    }

    func testRequestAuthenticatesAsTheCurrentSession() throws {
        XCTAssertEqual(
            try request(accessToken: "session-token").value(forHTTPHeaderField: "Authorization"),
            "Bearer session-token"
        )
    }

    func testRequestPostsToTheDeleteAccountFunction() throws {
        XCTAssertEqual(try request().httpMethod, "POST")
        XCTAssertEqual(
            try request().url?.absoluteString,
            "https://example.supabase.co/functions/v1/delete-account"
        )
    }

    /// A different session produces a different request and nothing else changes — the account being
    /// deleted travels only in the token.
    func testDifferentSessionsDifferOnlyInTheirToken() throws {
        let first = try request(accessToken: "token-a")
        let second = try request(accessToken: "token-b")

        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(first.httpBody, second.httpBody)
        XCTAssertNotEqual(
            first.value(forHTTPHeaderField: "Authorization"),
            second.value(forHTTPHeaderField: "Authorization")
        )
    }

    // MARK: - The Apple body is a credential, not an identity

    /// The Apple code is the *only* thing the body may carry. In particular there is still no user id
    /// in it, so adding Apple revocation did not open a way to aim the deletion at another account.
    func testAppleRequestCarriesOnlyTheAuthorizationCode() throws {
        let body = try XCTUnwrap(try request(appleAuthorizationCode: "apple-code-123").httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(json["appleAuthorizationCode"] as? String, "apple-code-123")
        XCTAssertEqual(json.keys.count, 1)
        XCTAssertNil(json["user_id"])
        XCTAssertNil(json["userID"])
    }

    /// Two accounts deleting at the same moment differ in their token and their Apple code; neither
    /// field lets one of them name the other.
    func testAppleCodeDoesNotChangeWhichAccountIsAddressed() throws {
        let first = try request(accessToken: "token-a", appleAuthorizationCode: "code-a")
        let second = try request(accessToken: "token-b", appleAuthorizationCode: "code-b")

        XCTAssertEqual(first.url, second.url)
        XCTAssertNotEqual(first.httpBody, second.httpBody)
    }

    // MARK: - Only a 2xx means the account is gone

    func testSuccessIsAcceptedOnTwoHundred() throws {
        XCTAssertNoThrow(try AccountDeletionService.validate(response: response(200), data: Data()))
    }

    func testUnauthenticatedIsReportedSeparatelySoTheAppCanAskForSignIn() {
        XCTAssertThrowsError(
            try AccountDeletionService.validate(response: response(401), data: Data())
        ) { error in
            XCTAssertEqual(error as? AccountDeletionError, .notAuthenticated)
        }
    }

    /// A storage sweep that failed halfway is a 500, and it must not read as success: the account
    /// still exists, and the app has to leave the user signed in and able to try again.
    func testPartialFailureIsRetryableRatherThanSuccess() {
        let body = Data(#"{"error":"Your account could not be deleted. Please try again.","code":"storage_cleanup_failed"}"#.utf8)

        XCTAssertThrowsError(
            try AccountDeletionService.validate(response: response(500), data: body)
        ) { error in
            XCTAssertEqual(error as? AccountDeletionError, .unavailable)
        }
    }

    func testEveryFailureCarriesAUserFacingMessage() {
        let failures: [AccountDeletionError] = [
            .notAuthenticated,
            .unavailable,
            .appleReauthorizationRequired,
            .appleIdentityMismatch,
            .appleRevocationFailed
        ]

        for failure in failures {
            XCTAssertFalse(failure.localizedDescription.isEmpty)
        }
    }

    // MARK: - Apple failures stop the deletion

    private func appleFailure(_ code: String, status: Int) -> AccountDeletionError? {
        let body = Data(#"{"error":"nope","code":"\#(code)"}"#.utf8)

        do {
            try AccountDeletionService.validate(response: response(status), data: body)
            return nil
        } catch {
            return error as? AccountDeletionError
        }
    }

    /// A code that expired between the Apple sheet and the request. Distinct from a generic failure
    /// because the fix is to confirm with Apple again, which the app can do straight away.
    func testExpiredAppleCodeAsksForAFreshConfirmation() {
        XCTAssertEqual(appleFailure("apple_reauthorization_required", status: 400), .appleReauthorizationRequired)
    }

    /// Someone approved the Apple sheet with a different Apple ID than the account is linked to.
    func testMismatchedAppleIdentityIsItsOwnFailure() {
        XCTAssertEqual(appleFailure("apple_identity_mismatch", status: 403), .appleIdentityMismatch)
    }

    /// The compliance case. If Apple cannot be reached, or refuses, the deletion must fail — deleting
    /// anyway would leave Journaltopia authorized under the person's Apple ID, which is exactly what
    /// Guideline 5.1.1(v) forbids.
    func testApplyRevocationFailureIsNeverReportedAsSuccess() {
        for code in ["apple_unreachable", "apple_exchange_failed", "apple_revocation_failed", "apple_not_configured"] {
            XCTAssertEqual(appleFailure(code, status: 502), .appleRevocationFailed, code)
        }
    }
}

extension AccountDeletionError: Equatable {
    static func == (lhs: AccountDeletionError, rhs: AccountDeletionError) -> Bool {
        switch (lhs, rhs) {
        case (.notAuthenticated, .notAuthenticated),
             (.unavailable, .unavailable),
             (.appleReauthorizationRequired, .appleReauthorizationRequired),
             (.appleIdentityMismatch, .appleIdentityMismatch),
             (.appleRevocationFailed, .appleRevocationFailed):
            return true
        default:
            return false
        }
    }
}
