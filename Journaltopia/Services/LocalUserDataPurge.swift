import Foundation

/// The one place that decides what leaves this device when a user signs out.
///
/// Sign-out used to clear only the account-scope pointer and the in-memory `currentUser`, which left
/// every local copy of the previous account's writing — drafts, storyboards, journal covers, cached
/// Supabase images, location recents, generation state — sitting on the device for whoever signed in
/// next. This type is the answer, and it is deliberately the *only* answer: anything that persists
/// user content locally is covered here or it is not covered at all.
///
/// Two rules are what keep a store from being forgotten:
///
/// 1. **UserDefaults is purged by prefix, not by list.** Every key this app writes begins with
///    `Journaltopia`, so a store added next month is erased on sign-out the day it is written, with
///    nobody remembering to come back here. The list that *is* maintained is the inverse —
///    ``devicePreferenceKeys``, the keys that describe this device rather than this account and so
///    survive on purpose.
/// 2. **Directories are removed whole.** `JournaltopiaAccounts` goes at its root, so every account
///    scope goes with it, `anonymous` included. That matters more than it looks: the draft and
///    storyboard stores migrate anonymous-scope content into whichever account signs in next, so
///    anything left behind under `anonymous` would follow User B into their account.
///
/// Every step runs isolated from the others. One failed removal — a file held open, a directory that
/// was never created — must not stop the rest, because a purge that quietly gave up halfway is the
/// same leak this exists to close.
@MainActor
enum LocalUserDataPurge {
    private static let legacyPrefix = "Story" + "topia"

    // MARK: - Registration

    /// Credits live on an `ObservableObject` the app owns, not in a store this file can reach, so
    /// the owner hands it over once at launch. Weak on purpose: the purge is not a reason to keep a
    /// view model alive.
    private static weak var generationCreditStore: GenerationCreditStore?

    static func register(generationCreditStore store: GenerationCreditStore) {
        generationCreditStore = store
    }

    // MARK: - What survives a sign-out

    /// Keys about the device rather than the person using it.
    ///
    /// Layout pickers, entry sort, the image-quality picker, the thumbnail renderer version and the
    /// one-shot reader gesture hints all describe how this install is set up. None of them carry
    /// another account's content, and resetting them at every sign-out would make a shared device
    /// feel broken instead of private.
    ///
    /// Anything *not* listed here and prefixed `Journaltopia` is treated as account content and
    /// purged — except install-level walkthrough state, which should not return after sign-out.
    static let devicePreferenceKeys: Set<String> = [
        "JournaltopiaHasCompletedOnboarding",
        // Install-level: once this device has moved past the first signed-out auth wall (onboarding
        // or "Continue Without Signing In"), signing out must not raise that wall again.
        "JournaltopiaSignedOutSignInPromptDismissed",
        "JournaltopiaSampleAuthorModeEnabled",
        "JournaltopiaSelectedJournalLayout",
        "JournaltopiaSelectedJournalDetailEntryLayout",
        "JournaltopiaSelectedEntryLayout",
        "JournaltopiaSelectedEntrySort",
        "JournaltopiaImageGenerationQuality",
        "JournaltopiaEntryThumbnailRendererVersion",
        // Unprefixed, so the sweep would miss them anyway. Listed so this stays the complete
        // statement of what a sign-out is allowed to leave behind.
        "journalStoryboardComicReaderGestureHintSeen"
    ]

    /// The prefix every Journaltopia-written default shares, including the `.<scope-id>` suffixed
    /// forms that `JournaltopiaLocalAccountScope` produces and the unscoped legacy keys that predate
    /// scoping.
    static let userDefaultsKeyPrefix = "Journaltopia"

    /// Folders under `Documents` that hold account content.
    ///
    /// `JournaltopiaAccounts` is the scoped tree every current store writes into. The rest are the
    /// unscoped locations earlier versions used, which the migration paths still read from — leaving
    /// them would hand User A's drafts and storyboards straight to User B on their first launch.
    /// `JournalCovers` was never scoped at all.
    static let documentsFolderNames = [
        "JournaltopiaAccounts",
        "\(legacyPrefix)Accounts",
        "CreateEntryDrafts",
        "CreateEntryDraft",
        "GeneratedStoryboards",
        "JournalCovers"
    ]

    /// Folders under `Caches` that hold account content: downloaded Supabase images, the entries
    /// fetch cache, and rendered cloud entry thumbnails.
    static let cachesFolderNames = [
        "JournaltopiaSupabaseImageCache",
        "\(legacyPrefix)SupabaseImageCache",
        "Journaltopia",
        legacyPrefix
    ]

    // MARK: - Purging

    /// Clears every local trace of the signed-in account.
    ///
    /// Safe to call when nobody is signed in, and safe to call twice — each step is a removal, not a
    /// mutation of something that has to exist first. Deliberately independent of the current
    /// account scope: it purges *all* scopes, so it cannot be defeated by being called after the
    /// scope pointer has already been reset.
    static func purgeAll() {
        for step in steps {
            do {
                try step.run()
            } catch {
                // Keep going. A step that could not finish is worth reporting, but abandoning the
                // remaining steps would leave more of the account behind than the failure itself.
                print("[Journaltopia] Sign-out purge step '\(step.name)' failed: \(error.localizedDescription)")
            }
        }
    }

    private struct PurgeStep {
        let name: String
        let run: () throws -> Void
    }

    /// The complete purge list. Adding local user storage means adding it here — or, for anything
    /// living in `UserDefaults` under the `Journaltopia` prefix, nowhere at all.
    private static var steps: [PurgeStep] {
        [
            PurgeStep(name: "user-defaults") {
                purgeUserDefaults()
            },
            PurgeStep(name: "documents") {
                try purgeDirectories(
                    named: documentsFolderNames,
                    in: .documentDirectory
                )
            },
            PurgeStep(name: "caches") {
                try purgeDirectories(
                    named: cachesFolderNames,
                    in: .cachesDirectory
                )
            },
            PurgeStep(name: "in-memory-caches") {
                JournalLocalCachePurge.purgeInMemoryCaches()
                ProfileLocalCachePurge.purgeInMemoryCaches()
                HomeLocalCachePurge.purgeInMemoryCaches()
            },
            PurgeStep(name: "generation-credits") {
                generationCreditStore?.reset()
            }
        ]
    }

    /// Removes every `Journaltopia`-prefixed default that is not a device preference.
    ///
    /// This covers, without naming them: `CreateEntryDraftStore`'s recovery pointer,
    /// `GeneratedStoryboardStore`'s metadata and pending generations, `EntryLocationRecentStore`,
    /// `EntryCloudSyncFailureStore`, `EntryJournalLinkStore`, `UserChapterStore`, `StoryEntryStore`,
    /// the journal cover and page-background stores, the deleted-sample bookkeeping, and the cached
    /// sample story pack — in every scope, plus their unscoped legacy forms.
    private static func purgeUserDefaults() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys

        for key in keys where shouldPurgeUserDefaultsKey(key) {
            defaults.removeObject(forKey: key)
        }
    }

    /// A key is account content when it is one of ours and is not on the device-preference list.
    /// Scoped keys arrive as `BaseKey.<scope-id>`, so the base name is what gets checked.
    static func shouldPurgeUserDefaultsKey(_ key: String) -> Bool {
        guard key.hasPrefix(userDefaultsKeyPrefix) || key.hasPrefix(legacyPrefix) else {
            return false
        }

        let baseKey = unscopedBaseKey(for: key)
        let normalizedBaseKey = baseKey.hasPrefix(legacyPrefix)
            ? userDefaultsKeyPrefix + String(baseKey.dropFirst(legacyPrefix.count))
            : baseKey

        return !devicePreferenceKeys.contains(normalizedBaseKey)
    }

    /// Strips a trailing `.<scope-id>` so a scoped key can be matched against the device-preference
    /// list. Base keys never contain a dot, so the first one is the scope separator.
    private static func unscopedBaseKey(for key: String) -> String {
        guard let separatorIndex = key.firstIndex(of: ".") else {
            return key
        }

        return String(key[key.startIndex..<separatorIndex])
    }

    /// Removes each named folder from `searchPath`, collecting failures so one stuck folder does not
    /// spare the others. A folder that was never created is not a failure.
    private static func purgeDirectories(
        named folderNames: [String],
        in searchPath: FileManager.SearchPathDirectory
    ) throws {
        guard let baseURL = FileManager.default.urls(for: searchPath, in: .userDomainMask).first else {
            return
        }

        var failures: [String] = []

        for folderName in folderNames {
            let folderURL = baseURL.appendingPathComponent(folderName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folderURL.path) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: folderURL)
            } catch {
                failures.append("\(folderName): \(error.localizedDescription)")
            }
        }

        guard failures.isEmpty else {
            throw LocalUserDataPurgeError.directoriesNotRemoved(failures)
        }
    }
}

enum LocalUserDataPurgeError: LocalizedError {
    case directoriesNotRemoved([String])

    var errorDescription: String? {
        switch self {
        case .directoriesNotRemoved(let failures):
            return "Could not remove \(failures.joined(separator: ", "))"
        }
    }
}
