import Foundation

/// Remembers which local draft is the Create page's unfinished compose.
///
/// A brand-new entry gets a local id the first time the user types something worth keeping, long
/// before it has any business existing in Supabase. That draft is not a normal entry yet — the
/// signed-in Entries list is built from cloud rows and will not show it — so without a pointer the
/// only way back to it after a relaunch would be to scan every local draft and guess. This is the
/// pointer: one id, scoped to the signed-in account the same way the drafts themselves are, cleared
/// the moment the entry is committed, discarded, or deleted.
enum UnfinishedCreateSessionStore {
    private static let storageKey = "StorytopiaUnfinishedCreateSession"

    static var draftID: UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: scopedStorageKey) else {
            return nil
        }

        return UUID(uuidString: rawValue)
    }

    static func setDraftID(_ draftID: UUID) {
        UserDefaults.standard.set(draftID.uuidString, forKey: scopedStorageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: scopedStorageKey)
    }

    /// Clears the pointer only when it still names `draftID`, so finishing one entry cannot retire
    /// the recovery pointer of a compose session that has since moved on to another.
    static func clearIfMatches(draftID: UUID) {
        guard self.draftID == draftID else {
            return
        }

        clear()
    }

    private static var scopedStorageKey: String {
        StorytopiaLocalAccountScope.scopedUserDefaultsKey(storageKey)
    }
}

/// Decides whether a downloaded cloud entry may be written over the local draft cache.
///
/// Every path that opens an entry re-downloads it and writes the result into
/// `CreateEntryDraftStore`. That is the right thing to do for a cache, and the wrong thing to do
/// for edits the user autosaved locally and has not committed yet — those are newer than anything
/// the server holds. The rule is deliberately not "local always wins": only an explicitly
/// uncommitted draft is protected, so a synchronized copy still gets refreshed from the cloud.
enum CreateEntryCloudMaterialization {
    enum Decision: Equatable {
        /// Nothing locally uncommitted is at risk — write the cloud snapshot into the cache.
        case materializeCloud
        /// The local copy is ahead of Supabase — open it instead of overwriting it.
        case preserveLocalEdits
    }

    static func decision(hasLocalDraft: Bool, hasUncommittedLocalEdits: Bool) -> Decision {
        guard hasLocalDraft else {
            return .materializeCloud
        }

        return hasUncommittedLocalEdits ? .preserveLocalEdits : .materializeCloud
    }

    /// Reads both facts straight from the local draft store.
    static func decision(for draftID: UUID) -> Decision {
        decision(
            hasLocalDraft: CreateEntryDraftStore.exists(id: draftID),
            hasUncommittedLocalEdits: CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID)
        )
    }
}

/// Debounces local autosave: one write a couple of seconds after typing stops, rather than one per
/// keystroke.
///
/// Kept as its own object, away from the editor's view state, so the two things that make a
/// debounce dangerous — a pending write firing after the entry was discarded, and a pending write
/// firing after the entry moved on — are handled in one place with one rule: scheduling again or
/// cancelling retires whatever was already in flight.
@MainActor
final class LocalDraftAutosaveScheduler {
    static let defaultDebounceInterval: TimeInterval = 2

    let debounceInterval: TimeInterval
    /// Bumped by every schedule and every cancel. A delayed block only runs if the generation it
    /// was scheduled with is still the one being waited on, so a stale write cannot land.
    private var currentGeneration = 0
    private var pendingGeneration: Int?

    init(debounceInterval: TimeInterval = LocalDraftAutosaveScheduler.defaultDebounceInterval) {
        self.debounceInterval = debounceInterval
    }

    var hasPendingWork: Bool {
        pendingGeneration != nil
    }

    /// Replaces any pending write with this one, `debounceInterval` from now.
    func schedule(_ work: @escaping () -> Void) {
        currentGeneration += 1
        let generation = currentGeneration
        pendingGeneration = generation

        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval) { [weak self] in
            guard let self, self.pendingGeneration == generation else {
                return
            }

            self.pendingGeneration = nil
            work()
        }
    }

    /// Drops any pending write. The caller is saying the content it would have saved is no longer
    /// the content that should be on disk.
    func cancelPending() {
        currentGeneration += 1
        pendingGeneration = nil
    }

    /// Cancels the pending write and runs `work` now — for the moments, like backgrounding, where
    /// waiting out the debounce means waiting past the point the process may be killed.
    func flush(_ work: () -> Void) {
        cancelPending()
        work()
    }
}
