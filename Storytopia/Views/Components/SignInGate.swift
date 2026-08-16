import Combine
import SwiftUI

/// An action a signed-out visitor can reach but cannot complete, because completing it would mean
/// writing content nobody owns.
///
/// The list is deliberately named after what the user was trying to do rather than after the store
/// it would have written to: the gate's whole job is to explain the refusal in the user's terms.
enum AccountRequiredAction: String, Equatable {
    case createEntry
    case saveEntry
    case editEntry
    case deleteEntry
    case generateStoryboard
    case attachReferencePhoto
    case saveCharacter
    case createJournal
    case editJournal
    case deleteJournal
    case reorderContent
    case customizeJournalCover
    case spendCredits

    var title: String {
        switch self {
        case .createEntry, .saveEntry, .editEntry:
            return "Sign In to Write"
        case .deleteEntry, .deleteJournal:
            return "Sign In to Delete"
        case .generateStoryboard:
            return "Sign In to Generate"
        case .attachReferencePhoto:
            return "Sign In to Add Photos"
        case .saveCharacter:
            return "Sign In to Save Characters"
        case .createJournal, .editJournal, .customizeJournalCover, .reorderContent:
            return "Sign In to Edit Journals"
        case .spendCredits:
            return "Sign In to Use Credits"
        }
    }

    var message: String {
        switch self {
        case .createEntry:
            return "Your entries are saved to your account so they follow you across devices. Sign in to start writing — you can keep browsing the sample stories either way."
        case .saveEntry:
            return "Saving keeps this entry in your account. Sign in to save it, or keep reading the samples without an account."
        case .editEntry:
            return "The sample stories are shared with everyone, so they can be read but not edited. Sign in to write entries of your own."
        case .deleteEntry:
            return "The sample stories belong to everyone browsing Storytopia. Sign in to manage entries in your own library."
        case .deleteJournal:
            return "Sample journals are part of the shared preview. Sign in to create and delete journals of your own."
        case .generateStoryboard:
            return "Storyboard generation runs on your account and spends your generation credits. Sign in to generate one."
        case .attachReferencePhoto:
            return "Reference photos are uploaded to your account. Sign in to add them to an entry."
        case .saveCharacter:
            return "Your character library is stored with your account so it is there for every entry. Sign in to save one."
        case .createJournal:
            return "Journals are saved to your account. Sign in to make one — the sample journals stay browsable without an account."
        case .editJournal, .customizeJournalCover:
            return "The sample journals are shared with everyone browsing Storytopia. Sign in to create and customize journals of your own."
        case .reorderContent:
            return "Ordering is saved with your account. Sign in to arrange your own journals and entries."
        case .spendCredits:
            return "Generation credits live on your account. Sign in to see your balance and use them."
        }
    }
}

/// One request to the gate. Carries the retry so the action the user actually wanted can run itself
/// the moment sign-in lands, rather than making them find the button again.
struct SignInGateRequest: Identifiable {
    let id = UUID()
    let action: AccountRequiredAction
    let retry: (() -> Void)?
}

/// The one place an account-required action is turned away.
///
/// Every screen asks the same question through ``requireAccount(for:retry:)`` and gets back a plain
/// `Bool`, so a call site reads as a guard rather than as a presentation:
///
/// ```swift
/// guard signInGate.requireAccount(for: .createJournal) else { return }
/// ```
///
/// A `false` means the gate has already taken over — it is showing, or it has explained why signing
/// in is not the answer right now. Callers do no presentation of their own, which is what keeps this
/// from turning back into an alert per screen.
@MainActor
final class SignInGate: ObservableObject {
    @Published private(set) var pendingRequest: SignInGateRequest?
    @Published private(set) var mode: StorytopiaContentMode = .loading

    func update(mode: StorytopiaContentMode) {
        guard self.mode != mode else {
            return
        }

        self.mode = mode

        // A resolved account makes any outstanding request moot: either the user signed in and the
        // retry has already run, or they are somewhere the request no longer applies.
        if mode.canPersistUserContent || mode.isSampleAuthoring {
            pendingRequest = nil
        }
    }

    /// Whether there is an account behind this action.
    ///
    /// Sample authoring passes: it is a signed-in admin, and every write it reaches routes itself to
    /// the sample tables further down. The question this answers is "is anyone signed in?", not
    /// "which tables does this write to" — that second one is ``StorytopiaContentMode``'s
    /// `canPersistUserContent`, and conflating them here would lock sample authors out of the
    /// journals and entries they are signed in to edit.
    @discardableResult
    func requireAccount(for action: AccountRequiredAction, retry: (() -> Void)? = nil) -> Bool {
        if mode.canPersistUserContent || mode.isSampleAuthoring {
            return true
        }

        // `.loading` has no answer yet and `.unavailable` has an answer signing in cannot change.
        // Both refuse the write; only signed-out browsing gets the sign-in sheet.
        guard mode.requiresSignIn else {
            return false
        }

        pendingRequest = SignInGateRequest(action: action, retry: retry)
        return false
    }

    func dismiss() {
        pendingRequest = nil
    }

    /// Runs the pending retry and clears the request. Called when sign-in succeeds.
    func completePendingRequest() {
        let retry = pendingRequest?.retry
        pendingRequest = nil
        retry?()
    }
}

/// The sheet the gate presents. Mounted once at the app root so every screen shares it.
struct SignInGateSheet: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var signInGate: SignInGate

    let request: SignInGateRequest

    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.storyInk.opacity(0.14))
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            VStack(spacing: 16) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 62, height: 62)
                    .background(Color.storyPurple.opacity(0.12), in: Circle())

                VStack(spacing: 9) {
                    Text(request.action.title)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                        .multilineTextAlignment(.center)

                    Text(request.action.message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorMessage = authStore.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button(action: signIn) {
                        HStack(spacing: 8) {
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }

                            Text(isSigningIn ? "Signing In" : "Sign In with Google")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSigningIn)

                    Button {
                        signInGate.dismiss()
                    } label: {
                        Text("Keep Browsing")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.homeAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Color.homePageBackground)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.light)
        .onChange(of: authStore.status) { status in
            // The sheet closes on the auth store's word, not on the OAuth call returning: the
            // session arrives through `authStateChanges`, which can land after `signInWithGoogle()`
            // has already come back.
            guard status == .signedIn else {
                return
            }

            isSigningIn = false
            signInGate.completePendingRequest()
        }
    }

    private func signIn() {
        Task {
            isSigningIn = true
            await authStore.signInWithGoogle()
            isSigningIn = false
        }
    }
}
