import AuthenticationServices
import SwiftUI
import UIKit

struct SignInView: View {
    private enum SignInProvider {
        case apple
        case google
        case email
    }

    @EnvironmentObject private var authStore: SupabaseAuthStore
    @Environment(\.dismiss) private var dismiss

    let promptTitle: String?
    let promptSubtitle: String?
    let onContinueBrowsing: (() -> Void)?

    @State private var signingInProvider: SignInProvider?
    /// Which half of the same two buttons the copy is describing. Apple and Google make no
    /// distinction between signing up and signing in — the first tap creates the account — but a
    /// visitor without one still needs to see somewhere that says so.
    @State private var isCreatingAccount: Bool
    @State private var emailAddress = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isSendingPasswordReset = false
    @State private var passwordResetMessage: String?

    init(
        promptTitle: String? = nil,
        promptSubtitle: String? = nil,
        startsCreatingAccount: Bool = false,
        onContinueBrowsing: (() -> Void)? = nil
    ) {
        self.promptTitle = promptTitle
        self.promptSubtitle = promptSubtitle
        self.onContinueBrowsing = onContinueBrowsing
        _isCreatingAccount = State(initialValue: startsCreatingAccount)
    }

    var body: some View {
        GeometryReader { proxy in
            let heroHeight = heroHeight(for: proxy.size)
            let overlap: CGFloat = 78

            ZStack(alignment: .top) {
                Color(red: 0.99, green: 0.97, blue: 0.94)
                    .ignoresSafeArea()

                hero(height: heroHeight)
                    .ignoresSafeArea(edges: .top)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: max(heroHeight - overlap, 170))

                        authPanel
                            .frame(maxWidth: 430)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: proxy.size.height)
                }
                .ignoresSafeArea(edges: .top)

                dismissButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 18)
                    .padding(.top, proxy.safeAreaInsets.top + 6)
            }
        }
        .preferredColorScheme(.light)
        .onChange(of: authStore.status) { status in
            if status == .signedIn {
                signingInProvider = nil
            }
        }
    }

    private var authPanel: some View {
        VStack(spacing: 24) {
            header

            statusContent

            if let errorMessage = authStore.errorMessage {
                errorText(errorMessage)
            }

            continueBrowsingButton
        }
        .padding(.horizontal, 30)
        .padding(.top, 28)
        .padding(.bottom, 34)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
            .fill(Color(red: 1.0, green: 0.99, blue: 0.97))
        )
        .shadow(color: Color.storyInk.opacity(0.12), radius: 22, y: -4)
    }

    private func heroHeight(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.36, 245), 320)
    }

    private func hero(height: CGFloat) -> some View {
        HomeLoopingVideoBackground(resourceName: "homepage_banner")
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
            }
    }

    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.storyInk.opacity(0.78))
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.82), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                )
                .shadow(color: Color.storyInk.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private var header: some View {
        VStack(spacing: 9) {
            Text(title)
                .font(.system(size: 29, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch authStore.status {
        case .loading:
            loadingState
        case .signedOut:
            signInOptions
        case .signedIn:
            signedInState
        case .misconfigured(let message):
            misconfiguredState(message)
        }
    }

    private var signInOptions: some View {
        VStack(spacing: 12) {
            appleSignInButton

            googleSignInButton

            divider

            emailPasswordFields

            forgotPasswordButton

            emailSignInButton

            accountModeToggle
        }
        .padding(.top, 3)
    }

    private var accountModeToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isCreatingAccount.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(isCreatingAccount ? "Already have an account?" : "Don't have an account?")
                    .foregroundStyle(Color.homeMutedText)

                Text(isCreatingAccount ? "Sign In" : "Create account")
                    .foregroundStyle(Color.storyPurple)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
    }

    private var appleSignInButton: some View {
        ZStack {
            SignInWithAppleButton(
                .continue,
                onRequest: { request in
                    signingInProvider = .apple
                    authStore.prepareSignInWithAppleRequest(request)
                },
                onCompletion: { result in
                    Task {
                        await authStore.completeSignInWithApple(result)
                        signingInProvider = nil
                    }
                }
            )
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if signingInProvider == .apple {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .disabled(isAuthInteractionDisabled)
        .allowsHitTesting(!isAuthInteractionDisabled)
        .accessibilityLabel(isCreatingAccount ? "Sign up with Apple" : "Sign in with Apple")
    }

    private var emailPasswordFields: some View {
        VStack(spacing: 9) {
            inputField(
                systemName: "envelope",
                placeholder: "Email address",
                text: $emailAddress,
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                isSecure: false
            )

            inputField(
                systemName: "lock",
                placeholder: "Password",
                text: $password,
                keyboardType: .default,
                textContentType: .password,
                isSecure: !isPasswordVisible,
                trailingButton: passwordVisibilityButton
            )
        }
    }

    private func inputField(
        systemName: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        textContentType: UITextContentType,
        isSecure: Bool,
        trailingButton: AnyView? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(systemName == "lock" ? Color.storyPurple : Color.homeMutedText.opacity(0.82))
                .frame(width: 20)

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.storyInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .disabled(isAuthInteractionDisabled)

            if let trailingButton {
                trailingButton
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.58), lineWidth: 1)
        )
    }

    private var passwordVisibilityButton: AnyView {
        AnyView(
            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText.opacity(0.72))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isAuthInteractionDisabled)
            .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
        )
    }

    @ViewBuilder
    private var forgotPasswordButton: some View {
        VStack(spacing: 5) {
            Button {
                sendPasswordReset()
            } label: {
                if isSendingPasswordReset {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.storyPurple)
                        .frame(height: 20)
                } else {
                    Text("Forgot password?")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                        .frame(height: 20)
                }
            }
            .buttonStyle(.plain)
            .disabled(isAuthInteractionDisabled || isSendingPasswordReset)

            if let passwordResetMessage {
                Text(passwordResetMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private var emailSignInButton: some View {
        Button {
            signInWithEmail()
        } label: {
            HStack(spacing: 8) {
                if signingInProvider == .email {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                Text(signingInProvider == .email ? "Signing In" : "Sign In")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.46, green: 0.25, blue: 0.96),
                        Color.storyPurple
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .shadow(color: Color.storyPurple.opacity(0.22), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
        .padding(.top, 8)
        .accessibilityLabel("Sign in with email")
    }

    private var googleSignInButton: some View {
        Button(action: signInWithGoogle) {
            HStack(spacing: 10) {
                if signingInProvider == .google {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.storyPurple)
                } else {
                    googleMark
                }

                Text(googleButtonTitle)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(Color.storyInk)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.58), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
        .accessibilityLabel(isCreatingAccount ? "Sign up with Google" : "Sign in with Google")
    }

    private var googleMark: some View {
        Image("google-icon")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
    }

    private var divider: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(Color.storyBorder.opacity(0.45))
                .frame(height: 1)

            Text("or")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText.opacity(0.84))

            Rectangle()
                .fill(Color.storyBorder.opacity(0.45))
                .frame(height: 1)
        }
        .padding(.vertical, 7)
    }

    private var googleButtonTitle: String {
        if signingInProvider == .google {
            return isCreatingAccount ? "Creating Account" : "Signing In"
        }

        return isCreatingAccount ? "Sign Up with Google" : "Sign In with Google"
    }

    private var loadingState: some View {
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.storyPurple)

            Text("Checking for a saved session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.storyInk)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 154)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
    }

    private var signedInState: some View {
        VStack(spacing: 11) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.storyPurple)

            Text("You're signed in")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text(authStore.email ?? authStore.displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 164)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
    }

    private func misconfiguredState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Color.storyGold)

            Text("Authentication Unavailable")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.storyInk)

            errorText(message)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.red)
            .multilineTextAlignment(.center)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var continueBrowsingButton: some View {
        if let onContinueBrowsing, canContinueBrowsing {
            Button(action: onContinueBrowsing) {
                Text(continueBrowsingTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.homeAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private var isAuthInteractionDisabled: Bool {
        signingInProvider != nil || isSendingPasswordReset || authStore.status == .loading
    }

    private var canContinueBrowsing: Bool {
        switch authStore.status {
        case .signedOut, .misconfigured:
            return signingInProvider == nil
        case .loading, .signedIn:
            return false
        }
    }

    private var continueBrowsingTitle: String {
        "Continue Without Signing In"
    }

    private var title: String {
        switch authStore.status {
        case .signedIn:
            return "Welcome back"
        case .misconfigured:
            return "Sign In Needs Setup"
        case .loading, .signedOut:
            // The create-account copy replaces the prompt: someone who has just said they have no
            // account should not still be reading why this particular action needed one.
            if isCreatingAccount {
                return "Create Your Account"
            }

            if let promptTitle {
                return promptTitle
            }

            return "Welcome back"
        }
    }

    private var subtitle: String {
        switch authStore.status {
        case .signedIn:
            return "Your Journaltopia account is ready on this device."
        case .misconfigured:
            return "Journaltopia cannot reach its account provider until configuration is complete."
        case .loading:
            return "Looking for an existing account session."
        case .signedOut:
            if isCreatingAccount {
                return "Continue with Apple or Google and Journaltopia makes the account for you."
            }

            if let promptSubtitle {
                return promptSubtitle
            }

            return "Sign in to continue creating your storyboards."
        }
    }

    private func signInWithGoogle() {
        Task {
            passwordResetMessage = nil
            signingInProvider = .google
            await authStore.signInWithGoogle()
            signingInProvider = nil
        }
    }

    private func signInWithEmail() {
        Task {
            passwordResetMessage = nil
            signingInProvider = .email
            await authStore.signIn(email: emailAddress, password: password)
            signingInProvider = nil
        }
    }

    private func sendPasswordReset() {
        Task {
            passwordResetMessage = nil
            isSendingPasswordReset = true
            let didSend = await authStore.sendPasswordReset(email: emailAddress)
            isSendingPasswordReset = false

            if didSend {
                passwordResetMessage = "Password reset email sent."
            }
        }
    }
}

struct SignInView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SignInView()
                .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
                .previewDisplayName("Full Screen Signed Out")

            SignInView()
                .environmentObject(SupabaseAuthStore.preview(status: .loading))
                .previewDisplayName("Loading")

            SignInView()
                .environmentObject(
                    SupabaseAuthStore.preview(
                        status: .misconfigured("Missing JOURNALTOPIA_SUPABASE_URL or JOURNALTOPIA_SUPABASE_ANON_KEY."),
                        errorMessage: nil
                    )
                )
                .previewDisplayName("Misconfigured")
        }
    }
}
