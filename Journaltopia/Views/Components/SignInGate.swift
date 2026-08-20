import Combine
import SwiftUI

/// An action a signed-out visitor can reach but cannot complete, because completing it would mean
/// writing content nobody owns.
///
/// The list is deliberately named after what the user was trying to do rather than after the store
/// it would have written to: the gate's whole job is to explain the refusal in the user's terms.
enum AccountRequiredAction: String, Equatable {
    case signIn
    case createEntry
    case saveEntry
    case editEntry
    case deleteEntry
    case generateStoryboard
    case attachReferencePhoto
    case saveCharacter
    case customizePaper
    case createJournal
    case editJournal
    case deleteJournal
    case reorderContent
    case customizeJournalCover
    case spendCredits

    var title: String {
        switch self {
        case .signIn:
            return "Sign In to Journaltopia"
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
        case .customizePaper:
            return "Sign In for Paper Styles"
        case .createJournal, .editJournal, .customizeJournalCover, .reorderContent:
            return "Sign In to Edit Journals"
        case .spendCredits:
            return "Sign In to Use Credits"
        }
    }

    var message: String {
        switch self {
        case .signIn:
            return "Use one account to keep your journals, entries, characters, and generation credits available across devices."
        case .createEntry:
            return "Your entries are saved to your account so they follow you across devices. Sign in to start writing — you can keep browsing the sample stories either way."
        case .saveEntry:
            return "Saving keeps this entry in your account. Sign in to save it, or keep reading the samples without an account."
        case .editEntry:
            return "The sample stories are shared with everyone, so they can be read but not edited. Sign in to write entries of your own."
        case .deleteEntry:
            return "The sample stories belong to everyone browsing Journaltopia. Sign in to manage entries in your own library."
        case .deleteJournal:
            return "Sample journals are part of the shared preview. Sign in to create and delete journals of your own."
        case .generateStoryboard:
            return "Storyboard generation runs on your account and spends your generation credits. Sign in to generate one."
        case .attachReferencePhoto:
            return "Reference photos are uploaded to your account. Sign in to add them to an entry."
        case .saveCharacter:
            return "Your character library is stored with your account so it is there for every entry. Sign in to save one."
        case .customizePaper:
            return "Paper image styles are included with Journaltopia+. Sign in to use them in your entries."
        case .createJournal:
            return "Journals are saved to your account. Sign in to make one — the sample journals stay browsable without an account."
        case .editJournal, .customizeJournalCover:
            return "The sample journals are shared with everyone browsing Journaltopia. Sign in to create and customize journals of your own."
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
    @Published private(set) var mode: JournaltopiaContentMode = .loading

    func update(mode: JournaltopiaContentMode) {
        guard self.mode != mode else {
            return
        }

        // The request is left in place when an account arrives so the success page can stay up.
        // Closing the page is what completes it.
        self.mode = mode
    }

    /// Whether there is an account behind this action.
    ///
    /// Sample authoring passes: it is a signed-in admin, and every write it reaches routes itself to
    /// the sample tables further down. The question this answers is "is anyone signed in?", not
    /// "which tables does this write to" — that second one is ``JournaltopiaContentMode``'s
    /// `canPersistUserContent`, and conflating them here would lock sample authors out of the
    /// journals and entries they are signed in to edit.
    @discardableResult
    func requireAccount(for action: AccountRequiredAction, retry: (() -> Void)? = nil) -> Bool {
        if mode.canPersistUserContent || mode.isSampleAuthoring {
            return true
        }

        // `.loading` has no answer yet and `.unavailable` has an answer signing in cannot change.
        // Both refuse the write; only signed-out browsing gets the sign-in page.
        guard mode.requiresSignIn else {
            return false
        }

        pendingRequest = SignInGateRequest(action: action, retry: retry)
        return false
    }

    func dismiss() {
        // Closing after a successful sign-in is the moment the success page is done, so the action
        // the user originally wanted runs then — not the instant the session lands.
        if mode.canPersistUserContent || mode.isSampleAuthoring {
            completePendingRequest()
            return
        }

        pendingRequest = nil
    }

    /// Runs the pending retry and clears the request. Called when the user closes the success page.
    func completePendingRequest() {
        let retry = pendingRequest?.retry
        pendingRequest = nil
        retry?()
    }
}

/// The page the gate presents. Mounted once at the app root so every screen shares it.
struct SignInGatePage: View {
    @EnvironmentObject private var signInGate: SignInGate

    let request: SignInGateRequest

    var body: some View {
        SignInView(
            promptTitle: request.action.title,
            promptSubtitle: request.action.message,
            // Deliberate Sign In has nowhere else to "keep browsing" from; interrupted writes still
            // offer an explicit way out of the page. After a successful sign-in the same close
            // completes the pending retry, once the user has left the success page.
            onContinueBrowsing: request.action == .signIn ? nil : { signInGate.dismiss() }
        )
    }
}
