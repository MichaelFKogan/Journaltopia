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

    enum EmailSignUpResult: Equatable {
        case signedIn
        case confirmationEmailSent
    }

    @Published private(set) var status: AuthStatus = .loading
    @Published private(set) var currentUser: User?
    @Published private(set) var isPasswordRecoveryPresented = false
    @Published var errorMessage: String?

    private let client: SupabaseClient
    private let accountDeletionService: AccountDeletionService
    private let appleReauthorizationService = AppleReauthorizationService()
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
        self.accountDeletionService = AccountDeletionService(client: client)
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
            _ = try JournaltopiaSupabaseConfig.projectURL
            _ = try JournaltopiaSupabaseConfig.anonKey

            try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: JournaltopiaSupabaseConfig.redirectURL
            ) { session in
                session.presentationContextProvider = AuthPresentationContextProvider.shared
                session.prefersEphemeralWebBrowserSession = false
            }
        } catch {
            status = .signedOut
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil

        do {
            _ = try JournaltopiaSupabaseConfig.projectURL
            _ = try JournaltopiaSupabaseConfig.anonKey

            let trimmedEmail = try normalizedEmail(email)
            try validatePassword(password, enforcesMinimumLength: false)

            let session = try await client.auth.signIn(email: trimmedEmail, password: password)
            JournaltopiaLocalAccountScope.setActiveUserID(session.user.id)
            currentUser = session.user
            status = .signedIn
        } catch {
            status = .signedOut
            errorMessage = userFacingMessage(for: error)
        }
    }

    func createAccount(email: String, password: String) async -> EmailSignUpResult? {
        errorMessage = nil

        do {
            _ = try JournaltopiaSupabaseConfig.projectURL
            _ = try JournaltopiaSupabaseConfig.anonKey

            let trimmedEmail = try normalizedEmail(email)
            try validatePassword(password, enforcesMinimumLength: true)

            let response = try await client.auth.signUp(
                email: trimmedEmail,
                password: password,
                redirectTo: JournaltopiaSupabaseConfig.redirectURL
            )

            if let session = response.session {
                JournaltopiaLocalAccountScope.setActiveUserID(session.user.id)
                currentUser = session.user
                status = .signedIn
                return .signedIn
            }

            status = .signedOut
            return .confirmationEmailSent
        } catch {
            status = .signedOut
            errorMessage = userFacingMessage(for: error)
            return nil
        }
    }

    func sendPasswordReset(email: String) async -> Bool {
        errorMessage = nil

        do {
            _ = try JournaltopiaSupabaseConfig.projectURL
            _ = try JournaltopiaSupabaseConfig.anonKey

            let trimmedEmail = try normalizedResetEmail(email)

            try await client.auth.resetPasswordForEmail(
                trimmedEmail,
                redirectTo: JournaltopiaSupabaseConfig.redirectURL
            )
            return true
        } catch {
            status = .signedOut
            errorMessage = userFacingMessage(for: error)
            return false
        }
    }

    func updatePassword(_ password: String, confirmation: String) async -> Bool {
        errorMessage = nil

        do {
            try validatePassword(password, enforcesMinimumLength: true)
            guard password == confirmation else {
                throw EmailPasswordSignInError.passwordsDoNotMatch
            }

            currentUser = try await client.auth.update(user: UserAttributes(password: password))
            isPasswordRecoveryPresented = false
            status = .signedIn
            return true
        } catch {
            errorMessage = userFacingMessage(for: error)
            return false
        }
    }

    func dismissPasswordRecovery() {
        isPasswordRecoveryPresented = false
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
            _ = try JournaltopiaSupabaseConfig.projectURL
            _ = try JournaltopiaSupabaseConfig.anonKey

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
            JournaltopiaLocalAccountScope.setActiveUserID(session.user.id)
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
        purgeLocalAccountData()

        if let signOutError {
            // Auth state stays with `startListening()`, which the emitted sign-out event reaches on
            // its own — unchanged from before the purge existed.
            errorMessage = userFacingMessage(for: signOutError)
            return
        }

        currentUser = nil
        status = .signedOut
    }

    /// True when this account signed in with Apple, and so needs its Apple authorization revoked
    /// before it can be deleted.
    ///
    /// Read from the linked identities rather than from how *this* session happened to start: an
    /// account can have several providers, and one that signed in with Google today still has an
    /// Apple authorization to revoke if Apple is among its identities.
    var hasAppleIdentity: Bool {
        currentUser?.identities?.contains { $0.provider == "apple" } ?? false
    }

    /// Permanently deletes this account on the server, then returns the device to signed-out.
    ///
    /// Returns `true` only once the server has confirmed the account is gone. The order is the point:
    /// nothing local is thrown away, and the user is not signed out, until the deletion has actually
    /// succeeded — so a failure leaves them signed in, looking at their own journals, able to try
    /// again. Signing out first would strand a live account behind a signed-out screen.
    ///
    /// For an account linked to Apple, this begins by asking Apple to confirm. That code is what lets
    /// the server revoke Journaltopia's authorization, which App Store Review Guideline 5.1.1(v)
    /// requires of a deletion — and which nothing stored on this device or in our database could do,
    /// because the app has never held an Apple refresh token. Cancelling the Apple sheet cancels the
    /// deletion, silently: the person declined, they did not hit an error.
    ///
    /// The cleanup afterwards is the *same* cleanup sign-out performs, deliberately: ``LocalUserDataPurge``
    /// is the one place that decides what leaves this device, and a second list maintained here
    /// would be a second list to forget to update.
    func deleteAccount() async -> Bool {
        errorMessage = nil

        var appleAuthorizationCode: String?
        if hasAppleIdentity {
            do {
                appleAuthorizationCode = try await appleReauthorizationService.authorizationCode()
            } catch AppleReauthorizationError.cancelled {
                return false
            } catch {
                errorMessage = userFacingMessage(for: error)
                return false
            }
        }

        do {
            try await accountDeletionService.deleteAccount(
                appleAuthorizationCode: appleAuthorizationCode
            )
        } catch {
            errorMessage = userFacingMessage(for: error)
            return false
        }

        // The account no longer exists, so `.local` is the only scope with any meaning left — there
        // are no other sessions to revoke, they died with the user row. The SDK ignores the 401/403/404
        // that the logout endpoint now returns for a deleted user, and drops the local session either
        // way; `try?` covers the offline case, where the purge below still has to run.
        try? await client.auth.signOut(scope: .local)

        purgeLocalAccountData()

        // Set explicitly rather than left to `authStateChanges`, which may not deliver if the sign-out
        // call above never reached the network. Nothing of the deleted account may stay on screen.
        currentUser = nil
        status = .signedOut
        return true
    }

    /// Everything that has to leave this device when an account stops being the one signed in.
    private func purgeLocalAccountData() {
        LocalUserDataPurge.purgeAll()
        JournaltopiaLocalAccountScope.setActiveUserID(nil)
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
            JournaltopiaLocalAccountScope.setActiveUserID(session.user.id)
            currentUser = session.user
            status = .signedIn
        } catch {
            JournaltopiaLocalAccountScope.setActiveUserID(nil)
            currentUser = nil
            status = .signedOut
        }
    }

    func handleOpenURL(_ url: URL) {
        client.auth.handle(url)
    }

    private func validateConfiguration() {
        do {
            _ = try JournaltopiaSupabaseConfig.projectURL
            _ = try JournaltopiaSupabaseConfig.anonKey
        } catch {
            status = .misconfigured(userFacingMessage(for: error))
        }
    }

    private func startListening() {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }

            for await (event, session) in await client.auth.authStateChanges {
                await MainActor.run {
                    if case .misconfigured = self.status {
                        return
                    }

                    JournaltopiaLocalAccountScope.setActiveUserID(session?.user.id)
                    self.currentUser = session?.user
                    self.status = session == nil ? .signedOut : .signedIn

                    if event == .passwordRecovery {
                        self.isPasswordRecoveryPresented = true
                    }
                }
            }
        }
    }

    private func normalizedEmail(_ email: String) throws -> String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            throw EmailPasswordSignInError.missingEmail
        }

        return trimmedEmail
    }

    private func normalizedResetEmail(_ email: String) throws -> String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            throw EmailPasswordSignInError.missingResetEmail
        }

        return trimmedEmail
    }

    private func validatePassword(_ password: String, enforcesMinimumLength: Bool) throws {
        guard !password.isEmpty else {
            throw EmailPasswordSignInError.missingPassword
        }

        guard !enforcesMinimumLength || password.count >= 6 else {
            throw EmailPasswordSignInError.passwordTooShort
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

private enum EmailPasswordSignInError: LocalizedError {
    case missingEmail
    case missingPassword
    case missingResetEmail
    case passwordTooShort
    case passwordsDoNotMatch

    var errorDescription: String? {
        switch self {
        case .missingEmail:
            return "Enter your email address."
        case .missingPassword:
            return "Enter your password."
        case .missingResetEmail:
            return "Enter your email address first."
        case .passwordTooShort:
            return "Use at least 6 characters for your password."
        case .passwordsDoNotMatch:
            return "The passwords do not match."
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
