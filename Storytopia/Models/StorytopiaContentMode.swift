import Foundation

/// The single answer to "whose content is this screen showing, and may it be written back?"
///
/// Before this existed every screen asked `authStore.userID != nil` and derived its own answer, which
/// collapsed three genuinely different situations into one. A launch still checking for a saved
/// session, a build with no Supabase credentials, and a real signed-out visitor all produced `nil`,
/// so all three rendered the signed-out sample experience — the first as a flash of samples that
/// swapped to the user's content a moment later, the second as a permanently empty sample browse
/// that could never load a pack.
///
/// Deriving the mode once, at the app root, and threading it down is what keeps those apart. It also
/// means a screen never has to decide *both* which data source to read *and* whether a write is
/// allowed: ``showsSampleContent`` answers the first, ``canPersistUserContent`` the second, and they
/// are not the same question — sample authoring reads samples and writes them back, signed-out
/// browsing reads samples and writes nothing.
enum StorytopiaContentMode: Equatable {
    /// Still resolving a saved session. Not signed out — a screen that commits to a data source here
    /// will have to undo it a moment later, so screens wait instead.
    case loading
    /// Supabase is not configured, so neither user content nor the sample pack can load. Carries the
    /// message to show, because "sign in" is not the fix.
    case unavailable(String)
    /// Signed out. Samples are the content, and nothing on this screen may write.
    case sampleBrowsing
    /// Signed in with Sample Author Mode on. Samples are the content, and edits go to the sample
    /// tables rather than to the account.
    case sampleAuthoring
    /// Signed in. The account's own content, and writes go to it.
    case user

    init(status: SupabaseAuthStore.AuthStatus, isSampleAuthorModeEnabled: Bool) {
        switch status {
        case .loading:
            self = .loading
        case .misconfigured(let message):
            self = .unavailable(message)
        case .signedOut:
            self = .sampleBrowsing
        case .signedIn:
            self = isSampleAuthorModeEnabled ? .sampleAuthoring : .user
        }
    }

    /// Whether this screen reads the sample pack instead of the account's content.
    var showsSampleContent: Bool {
        switch self {
        case .sampleBrowsing, .sampleAuthoring:
            return true
        case .loading, .unavailable, .user:
            return false
        }
    }

    /// Whether a write that claims account ownership — a saved entry, a created journal, a generated
    /// storyboard — may go ahead.
    ///
    /// False for sample authoring on purpose: those edits are real, but they belong to the sample
    /// tables and travel through `SupabaseSampleStoryService`, never through the account's stores.
    /// Callers that serve both check ``isSampleAuthoring`` first.
    var canPersistUserContent: Bool {
        self == .user
    }

    var isSampleAuthoring: Bool {
        self == .sampleAuthoring
    }

    /// Whether an account-required action should present the sign-in gate.
    ///
    /// Only signed-out browsing. Signing in cannot fix a `.loading` that has not settled or a build
    /// with no credentials, so those get their own message rather than a sign-in button.
    var requiresSignIn: Bool {
        self == .sampleBrowsing
    }

    /// Whether the mode has settled enough for a screen to pick a data source and start loading.
    var isResolved: Bool {
        self != .loading
    }

    /// The message to show in place of content when nothing can load at all.
    var unavailableMessage: String? {
        if case .unavailable(let message) = self {
            return message
        }

        return nil
    }

    /// The authoring mode `CreateEntryView` runs in. Signed-out browsing opens the editor in the
    /// ordinary user mode — the gate stops the writes, not the typing.
    var authoringMode: CreateEntryAuthoringMode {
        isSampleAuthoring ? .sampleStudio : .user
    }

    /// Identity for `.task(id:)` and `.onChange` so a screen reloads exactly when the mode or the
    /// account behind it changes, and not on every unrelated auth republish.
    func loadIdentity(userID: UUID?) -> String {
        switch self {
        case .loading:
            return "loading"
        case .unavailable:
            return "unavailable"
        case .sampleBrowsing:
            return "signed-out-samples"
        case .sampleAuthoring:
            return "sample-author"
        case .user:
            return "user-\(userID?.uuidString ?? "unknown")"
        }
    }
}
