import AuthenticationServices
import SwiftUI

struct SignInView: View {
    enum PresentationMode {
        case fullScreen
        case sheet
    }

    private enum SignInProvider {
        case apple
        case google
    }

    @EnvironmentObject private var authStore: SupabaseAuthStore

    let presentationMode: PresentationMode
    let promptTitle: String?
    let promptSubtitle: String?
    let onContinueBrowsing: (() -> Void)?

    @State private var signingInProvider: SignInProvider?
    /// Which half of the same two buttons the copy is describing. Apple and Google make no
    /// distinction between signing up and signing in — the first tap creates the account — but a
    /// visitor without one still needs to see somewhere that says so.
    @State private var isCreatingAccount = false

    init(
        presentationMode: PresentationMode,
        promptTitle: String? = nil,
        promptSubtitle: String? = nil,
        onContinueBrowsing: (() -> Void)? = nil
    ) {
        self.presentationMode = presentationMode
        self.promptTitle = promptTitle
        self.promptSubtitle = promptSubtitle
        self.onContinueBrowsing = onContinueBrowsing
    }

    var body: some View {
        ZStack {
            WatercolorPaperPageBackground()

            Group {
                switch presentationMode {
                case .fullScreen:
                    ScrollView {
                        content
                            .frame(maxWidth: 430)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 42)
                            .frame(maxWidth: .infinity, minHeight: 620)
                    }
                case .sheet:
                    VStack(spacing: 0) {
                        Capsule()
                            .fill(Color.storyInk.opacity(0.14))
                            .frame(width: 38, height: 5)
                            .padding(.top, 10)

                        content
                            .padding(.horizontal, 26)
                            .padding(.top, 24)
                            .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .presentationDetents(presentationMode == .sheet ? [.height(520)] : [.large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.light)
        .onChange(of: authStore.status) { status in
            if status == .signedIn {
                signingInProvider = nil
            }
        }
    }

    private var content: some View {
        VStack(spacing: presentationMode == .sheet ? 18 : 24) {
            header

            statusContent

            if let errorMessage = authStore.errorMessage {
                errorText(errorMessage)
            }

            continueBrowsingButton
        }
    }

    private var header: some View {
        VStack(spacing: presentationMode == .sheet ? 13 : 18) {
            Image(systemName: headerIconName)
                .font(.system(size: presentationMode == .sheet ? 25 : 31, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: presentationMode == .sheet ? 60 : 74, height: presentationMode == .sheet ? 60 : 74)
                .background(Color.storyPurple.opacity(0.12), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.storyPurple.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 9) {
                Text(title)
                    .font(.system(size: presentationMode == .sheet ? 23 : 29, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: presentationMode == .sheet ? 15 : 16, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        VStack(spacing: 11) {
            appleSignInButton

            googleSignInButton

            Text("Your private journals, entries, characters, and credits stay connected to your account.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)

            accountModeToggle
        }
        .padding(.top, presentationMode == .sheet ? 1 : 4)
    }

    private var accountModeToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isCreatingAccount.toggle()
            }
        } label: {
            Text(isCreatingAccount ? "Already have an account? Sign In" : "Create an Account")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
    }

    private var appleSignInButton: some View {
        ZStack {
            SignInWithAppleButton(
                isCreatingAccount ? .signUp : .signIn,
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
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if signingInProvider == .apple {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .disabled(isAuthInteractionDisabled)
        .allowsHitTesting(!isAuthInteractionDisabled)
        .accessibilityLabel(isCreatingAccount ? "Sign up with Apple" : "Sign in with Apple")
    }

    private var googleSignInButton: some View {
        Button(action: signInWithGoogle) {
            HStack(spacing: 10) {
                if signingInProvider == .google {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                }

                Text(googleButtonTitle)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
        .accessibilityLabel(isCreatingAccount ? "Sign up with Google" : "Sign in with Google")
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
        .frame(height: presentationMode == .sheet ? 128 : 154)
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
        .frame(height: presentationMode == .sheet ? 136 : 164)
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
        signingInProvider != nil || authStore.status == .loading
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
        presentationMode == .sheet ? "Keep Browsing" : "Continue Without Signing In"
    }

    private var headerIconName: String {
        switch authStore.status {
        case .signedIn:
            return "person.crop.circle.badge.checkmark"
        case .misconfigured:
            return "lock.trianglebadge.exclamationmark"
        case .loading:
            return "person.crop.circle.badge.clock"
        case .signedOut:
            return isCreatingAccount ? "person.crop.circle.badge.plus" : "person.badge.key"
        }
    }

    private var title: String {
        switch authStore.status {
        case .signedIn:
            return "Welcome Back"
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

            return presentationMode == .sheet ? "Sign In to Continue" : "Sign In to Journaltopia"
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
                return "Continue with Apple or Google and Journaltopia makes the account for you — no password to remember."
            }

            if let promptSubtitle {
                return promptSubtitle
            }

            switch presentationMode {
            case .fullScreen:
                return "Save your journals, entries, characters, and storyboard credits across devices."
            case .sheet:
                return "Use one account for private writing, saving, and generation."
            }
        }
    }

    private func signInWithGoogle() {
        Task {
            signingInProvider = .google
            await authStore.signInWithGoogle()
            signingInProvider = nil
        }
    }
}

struct SignInView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SignInView(presentationMode: .fullScreen)
                .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
                .previewDisplayName("Full Screen Signed Out")

            SignInView(presentationMode: .sheet)
                .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
                .frame(height: 520)
                .previewDisplayName("Sheet Signed Out")

            SignInView(presentationMode: .fullScreen)
                .environmentObject(SupabaseAuthStore.preview(status: .loading))
                .previewDisplayName("Loading")

            SignInView(presentationMode: .sheet)
                .environmentObject(
                    SupabaseAuthStore.preview(
                        status: .misconfigured("Missing JOURNALTOPIA_SUPABASE_URL or JOURNALTOPIA_SUPABASE_ANON_KEY."),
                        errorMessage: nil
                    )
                )
                .frame(height: 520)
                .previewDisplayName("Misconfigured")
        }
    }
}
