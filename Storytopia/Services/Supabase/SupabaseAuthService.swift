import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import Supabase
import UIKit

@MainActor
final class SupabaseAuthStore: ObservableObject {
    enum AuthStatus: Equatable {
        case loading
        case signedOut
        case signedIn
        case misconfigured(String)
    }

    @Published private(set) var status: AuthStatus = .loading
    @Published private(set) var currentUser: User?
    @Published var errorMessage: String?

    private let client: SupabaseClient
    private let skipsSessionRefresh: Bool
    private var authStateTask: Task<Void, Never>?
    private var currentAppleSignInNonce: String?

    var userID: UUID? {
        currentUser?.id
    }

    var displayName: String {
        currentUser?.email ?? "Signed in"
    }

    var email: String? {
        currentUser?.email
    }

    init(
        client: SupabaseClient = SupabaseService.shared,
        startsListening: Bool = true,
        validatesConfiguration: Bool = true,
        skipsSessionRefresh: Bool = false
    ) {
        self.client = client
        self.skipsSessionRefresh = skipsSessionRefresh

        if validatesConfiguration {
            validateConfiguration()
        } else {
            status = .signedOut
        }

        if startsListening {
            startListening()
        }
    }

    deinit {
        authStateTask?.cancel()
    }

    func signInWithGoogle() async {
        errorMessage = nil

        do {
            _ = try StorytopiaSupabaseConfig.projectURL
            _ = try StorytopiaSupabaseConfig.anonKey

            try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: StorytopiaSupabaseConfig.redirectURL
            ) { session in
                session.presentationContextProvider = AuthPresentationContextProvider.shared
                session.prefersEphemeralWebBrowserSession = false
            }
        } catch {
            status = .signedOut
            errorMessage = userFacingMessage(for: error)
        }
    }

    func prepareSignInWithAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        errorMessage = nil

        do {
            let nonce = try AppleSignInNonce.random()
            currentAppleSignInNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleSignInNonce.sha256(nonce)
        } catch {
            currentAppleSignInNonce = nil
            status = .signedOut
            errorMessage = userFacingMessage(for: error)
        }
    }

    func completeSignInWithApple(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil

        do {
            _ = try StorytopiaSupabaseConfig.projectURL
            _ = try StorytopiaSupabaseConfig.anonKey

            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AppleSignInError.missingCredential
            }

            guard let identityToken = credential.identityToken,
                  let idToken = String(data: identityToken, encoding: .utf8) else {
                throw AppleSignInError.missingIdentityToken
            }

            guard let nonce = currentAppleSignInNonce else {
                throw AppleSignInError.missingNonce
            }

            currentAppleSignInNonce = nil
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idToken,
                    nonce: nonce
                )
            )
            StorytopiaLocalAccountScope.setActiveUserID(session.user.id)
            currentUser = session.user
            status = .signedIn
        } catch {
            currentAppleSignInNonce = nil
            status = .signedOut

            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return
            }

            errorMessage = userFacingMessage(for: error)
        }
    }

    func signOut() async {
        errorMessage = nil

        var signOutError: Error?
        do {
            try await client.auth.signOut()
        } catch {
            signOutError = error
        }

        // Supabase drops the local session before it calls the logout endpoint, so this device is
        // signed out whether or not that call came back cleanly. The purge therefore runs on both
        // paths: a network error is no reason to leave one account's journals, drafts, storyboards
        // and cached images on the device for whoever signs in next.
        LocalUserDataPurge.purgeAll()
        StorytopiaLocalAccountScope.setActiveUserID(nil)

        if let signOutError {
            // Auth state stays with `startListening()`, which the emitted sign-out event reaches on
            // its own — unchanged from before the purge existed.
            errorMessage = userFacingMessage(for: signOutError)
            return
        }

        currentUser = nil
        status = .signedOut
    }

    func refreshCurrentUser() async {
        if skipsSessionRefresh {
            return
        }

        if case .misconfigured = status {
            return
        }

        do {
            let session = try await client.auth.session
            StorytopiaLocalAccountScope.setActiveUserID(session.user.id)
            currentUser = session.user
            status = .signedIn
        } catch {
            StorytopiaLocalAccountScope.setActiveUserID(nil)
            currentUser = nil
            status = .signedOut
        }
    }

    func handleOpenURL(_ url: URL) {
        client.auth.handle(url)
    }

    private func validateConfiguration() {
        do {
            _ = try StorytopiaSupabaseConfig.projectURL
            _ = try StorytopiaSupabaseConfig.anonKey
        } catch {
            status = .misconfigured(userFacingMessage(for: error))
        }
    }

    private func startListening() {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }

            for await (_, session) in await client.auth.authStateChanges {
                await MainActor.run {
                    if case .misconfigured = self.status {
                        return
                    }

                    StorytopiaLocalAccountScope.setActiveUserID(session?.user.id)
                    self.currentUser = session?.user
                    self.status = session == nil ? .signedOut : .signedIn
                }
            }
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return "Authentication is unavailable right now. Please try again."
    }

    static var preview: SupabaseAuthStore {
        preview(status: .signedOut)
    }

    static func preview(
        status: AuthStatus,
        errorMessage: String? = nil
    ) -> SupabaseAuthStore {
        let store = SupabaseAuthStore(
            client: SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "preview-supabase-anon-key"
            ),
            startsListening: false,
            validatesConfiguration: false,
            skipsSessionRefresh: true
        )
        store.status = status
        store.errorMessage = errorMessage
        return store
    }
}

private enum AppleSignInError: LocalizedError {
    case missingCredential
    case missingIdentityToken
    case missingNonce
    case nonceGenerationFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Apple did not return a usable sign-in credential. Please try again."
        case .missingIdentityToken:
            return "Apple did not return an identity token. Please try again."
        case .missingNonce:
            return "Apple sign-in could not be verified. Please try again."
        case .nonceGenerationFailed:
            return "Journaltopia could not prepare a secure Apple sign-in request. Please try again."
        }
    }
}

private enum AppleSignInNonce {
    private static let length = 32
    private static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._".utf8)

    static func random() throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let result = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard result == errSecSuccess else {
            throw AppleSignInError.nonceGenerationFailed
        }

        let nonceBytes = randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }
        return String(decoding: nonceBytes, as: UTF8.self)
    }

    static func sha256(_ value: String) -> String {
        let inputData = Data(value.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}

final class AuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
