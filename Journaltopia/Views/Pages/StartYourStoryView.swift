import AuthenticationServices
import SwiftUI

struct StartYourStoryView: View {
    private enum SignInProvider {
        case apple
        case google
    }

    @EnvironmentObject private var authStore: SupabaseAuthStore
    @Environment(\.dismiss) private var dismiss

    let showsNavigationChrome: Bool
    let onExploreFirst: (() -> Void)?
    let onAuthenticated: (() -> Void)?

    @State private var signingInProvider: SignInProvider?
    @State private var isSignInPresented = false
    @State private var isSignInPagePresented = false

    init(
        showsNavigationChrome: Bool = true,
        onExploreFirst: (() -> Void)? = nil,
        onAuthenticated: (() -> Void)? = nil
    ) {
        self.showsNavigationChrome = showsNavigationChrome
        self.onExploreFirst = onExploreFirst
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        ZStack {
            if showsNavigationChrome {
                WatercolorPaperPageBackground()
            }

            ScrollView {
                VStack(spacing: showsNavigationChrome ? 10 : 0) {
                    startCard

                    if showsNavigationChrome {
                        continueButton
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .padding(.bottom, showsNavigationChrome ? 0 : 68)
            }

            if !showsNavigationChrome {
                VStack {
                    Spacer()

                    continueButton
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle("Start Your Story")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsNavigationChrome ? .visible : .hidden, for: .navigationBar)
        .navigationDestination(isPresented: $isSignInPresented) {
            SignInView()
                .toolbar(.hidden, for: .navigationBar)
                .enableInteractivePopGesture()
        }
        .fullScreenCover(isPresented: $isSignInPagePresented) {
            SignInView()
        }
        .preferredColorScheme(.light)
        .onChange(of: authStore.status) { status in
            if status == .signedIn {
                signingInProvider = nil
                isSignInPresented = false
                isSignInPagePresented = false
                onAuthenticated?()
            }
        }
    }

    private var startCard: some View {
        VStack(spacing: 12) {
            header
            heroPhoto
            statusContent
            accountToggle
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: 360)
        .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.08), radius: 18, y: 10)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Start your story")
                .font(.system(size: 25, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .multilineTextAlignment(.center)

            Text("Create a free account to start writing and keep your journals and stories synced across your devices.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
    }

    private var heroPhoto: some View {
        Image("start-your-story")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 162)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.storyInk.opacity(0.08), lineWidth: 1)
            )
            .accessibilityHidden(true)
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
        VStack(spacing: 8) {
            appleSignInButton
            googleSignInButton
            emailButton

            if let errorMessage = authStore.errorMessage {
                errorText(errorMessage)
                    .padding(.top, 2)
            }
        }
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
            .frame(height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            if signingInProvider == .apple {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .disabled(isAuthInteractionDisabled)
        .allowsHitTesting(!isAuthInteractionDisabled)
        .accessibilityLabel("Continue with Apple")
    }

    private var googleSignInButton: some View {
        Button(action: signInWithGoogle) {
            HStack(spacing: 10) {
                if signingInProvider == .google {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.storyPurple)
                } else {
                    Text("G")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
                }

                Text(signingInProvider == .google ? "Connecting to Google" : "Continue with Google")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
        .accessibilityLabel("Continue with Google")
    }

    private var emailButton: some View {
        Button {} label: {
            Text("Continue with Email")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyPurple.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.storyPurple.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.storyPurple.opacity(0.22), lineWidth: 1.2)
                )
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel("Continue with Email")
        .accessibilityHint("Email sign in is not available yet")
    }

    private var accountToggle: some View {
        Button {
            if showsNavigationChrome {
                isSignInPresented = true
            } else {
                isSignInPagePresented = true
            }
        } label: {
            HStack(spacing: 0) {
                Text("Already have an account? ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Text("Sign In")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
            }
        }
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
        .accessibilityLabel("Already have an account? Sign In")
    }

    private var continueButton: some View {
        Button {
            if let onExploreFirst {
                onExploreFirst()
            } else {
                dismiss()
            }
        } label: {
            HStack(spacing: 8) {
                Text("Continue To Journaltopia")
                    .font(.system(size: 16, weight: .bold))

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.storyPurple.opacity(0.18), radius: 10, y: 5)
        }
        .frame(maxWidth: 360)
        .buttonStyle(.plain)
        .disabled(isAuthInteractionDisabled)
        .accessibilityLabel("Continue To Journaltopia")
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.storyPurple)

            Text("Looking for a saved session")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.storyInk)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 102)
    }

    private var signedInState: some View {
        VStack(spacing: 9) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.storyPurple)

            Text("You're signed in")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text(authStore.email ?? authStore.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.48), lineWidth: 1)
        )
    }

    private func misconfiguredState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.storyGold)

            Text("Authentication Unavailable")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            errorText(message)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.48), lineWidth: 1)
        )
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.red)
            .multilineTextAlignment(.center)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isAuthInteractionDisabled: Bool {
        signingInProvider != nil || authStore.status == .loading
    }

    private func signInWithGoogle() {
        Task {
            signingInProvider = .google
            await authStore.signInWithGoogle()
            signingInProvider = nil
        }
    }
}

#Preview {
    NavigationStack {
        StartYourStoryView()
            .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
    }
}
