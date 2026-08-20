import AuthenticationServices
import Foundation
import UIKit

/// Asks Apple, at deletion time, for a fresh authorization code that the server can revoke with.
///
/// Journaltopia signs in with Apple's *identity token* and has never read `authorizationCode`, so
/// there is no stored Apple credential for any existing account — and App Store Review Guideline
/// 5.1.1(v) requires that deleting an account revoke the Sign in with Apple authorization through
/// Apple's REST API. Re-authenticating here is what closes that: every account gets a usable code,
/// including the ones created long before this existed, and Journaltopia never has to hold an Apple
/// refresh token at rest to do it.
///
/// The code is single-use and short-lived, and it is useless on its own — exchanging it requires the
/// private key, which lives only in the Edge Function environment. Nothing secret is added to the app.
@MainActor
final class AppleReauthorizationService: NSObject {

    /// Presents Apple's confirmation and returns the authorization code it issues.
    ///
    /// Throws ``AppleReauthorizationError/cancelled`` if the person dismisses the sheet, which the
    /// caller treats as "do not delete" rather than as a failure to report.
    func authorizationCode() async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // No scopes: this is a re-authorization for revocation, not a sign-in, and name and email are
        // returned on first consent only regardless.
        request.requestedScopes = nil

        let authorization = try await perform(request: request)

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AppleReauthorizationError.unavailable
        }

        guard let codeData = credential.authorizationCode,
              let code = String(data: codeData, encoding: .utf8),
              !code.isEmpty else {
            throw AppleReauthorizationError.unavailable
        }

        return code
    }

    // MARK: - Bridging the delegate callback

    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    private func perform(request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(with result: Result<ASAuthorization, Error>) {
        // Guarded because a controller that reports twice would otherwise crash on resuming a spent
        // continuation.
        guard let continuation else {
            return
        }

        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension AppleReauthorizationService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            finish(with: .success(authorization))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                finish(with: .failure(AppleReauthorizationError.cancelled))
                return
            }

            finish(with: .failure(AppleReauthorizationError.unavailable))
        }
    }
}

extension AppleReauthorizationService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

enum AppleReauthorizationError: LocalizedError, Equatable {
    case cancelled
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            // Shown only if something surfaces it; the delete flow treats a cancel as "stop", silently.
            return "Apple confirmation was cancelled, so your account was not deleted."
        case .unavailable:
            return "Journaltopia could not confirm your Apple sign-in. Please try again."
        }
    }
}
