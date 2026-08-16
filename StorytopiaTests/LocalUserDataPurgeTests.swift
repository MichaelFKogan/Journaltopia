import XCTest
import UIKit
@testable import Storytopia

/// Covers the sign-out purge: that everything one account persisted locally is gone afterwards, that
/// the things which are deliberately about the device survive, and — the case that actually leaked —
/// that nothing User A left behind can be picked up by User B signing in on the same device.
///
/// The relaunch in the lifecycle these tests model is `UserDefaults` and the file system, which are
/// exactly what survives a force quit. Reading them back through a *fresh* account scope, rather
/// than the one that wrote them, is what stands in for "quit the app and sign in as someone else":
/// no in-process state carries over, because every store re-reads from disk under the new scope.
@MainActor
final class LocalUserDataPurgeTests: XCTestCase {

    private var userA: UUID!
    private var userB: UUID!

    override func setUp() {
        super.setUp()
        userA = UUID()
        userB = UUID()
    }

    override func tearDown() {
        LocalUserDataPurge.purgeAll()
        StorytopiaLocalAccountScope.setActiveUserID(nil)
        userA = nil
        userB = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func image(_ color: UIColor = .red) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// Writes one of everything the app persists locally, in whatever scope is currently active.
    @discardableResult
    private func createLocalContent(title: String) -> UUID {
        let draftID = CreateEntryDraftStore.save(
            id: nil,
            title: title,
            text: "\(title) body",
            richText: NotebookRichTextDocument(text: "\(title) body"),
            photos: [image(.green)],
            artStyle: "Anime",
            location: "Kyoto",
            date: Date(),
            savesDraft: true,
            isPrivate: false,
            thumbnail: image(.blue)
        ) ?? UUID()

        UnfinishedCreateSessionStore.setDraftID(draftID)
        EntryLocationRecentStore.add("Kyoto")
        EntryCloudSyncFailureStore.markNotSaved(clientEntryID: draftID, reason: "offline")
        EntryJournalLinkStore.save(journalTitle: title, journalEntryID: UUID(), for: draftID)
        GeneratedStoryboardStore.registerPendingGeneration(
            PendingStoryboardGeneration(id: UUID(), clientEntryID: draftID, requestedAt: Date())
        )
        SupabaseStorageImageCache.store(
            Data("\(title) image".utf8),
            bucketName: "storytopia-media",
            storagePath: "\(title)/panel.png"
        )

        return draftID
    }

    /// Everything `createLocalContent` wrote, read back through whatever scope is active now.
    private func localContentIsPresent(draftID: UUID, title: String) -> Bool {
        CreateEntryDraftStore.exists(id: draftID)
            || CreateEntryDraftStore.hasSavedDrafts()
            || UnfinishedCreateSessionStore.draftID != nil
            || !EntryLocationRecentStore.all.isEmpty
            || EntryCloudSyncFailureStore.isNotSaved(clientEntryID: draftID)
            || !EntryJournalLinkStore.loadJournalTitles(for: draftID).isEmpty
            || !GeneratedStoryboardStore.pendingGenerations().isEmpty
            || !GeneratedStoryboardStore.load().isEmpty
            || SupabaseStorageImageCache.data(
                bucketName: "storytopia-media",
                storagePath: "\(title)/panel.png"
            ) != nil
    }

    // MARK: - The sign-out lifecycle

    /// Sign in as A, create content, sign out, "relaunch", sign in as B: none of A's content may be
    /// reachable at any point after the purge.
    func testPurgeLeavesNothingForTheNextAccount() {
        StorytopiaLocalAccountScope.setActiveUserID(userA)
        let draftID = createLocalContent(title: "UserA")
        XCTAssertTrue(
            localContentIsPresent(draftID: draftID, title: "UserA"),
            "Test setup should have written content for User A"
        )

        LocalUserDataPurge.purgeAll()
        StorytopiaLocalAccountScope.setActiveUserID(nil)

        // Step 3-5: signed out, relaunched, nothing left in the signed-out (anonymous) scope.
        XCTAssertFalse(
            localContentIsPresent(draftID: draftID, title: "UserA"),
            "Signed-out relaunch still reaches User A's local content"
        )

        // Step 6: User B signs in and must see an empty device.
        StorytopiaLocalAccountScope.setActiveUserID(userB)
        XCTAssertFalse(
            localContentIsPresent(draftID: draftID, title: "UserA"),
            "User B can reach User A's local content"
        )
    }

    /// Signing back in as the same account must not resurrect anything either — a purge that only
    /// hid content behind the scope pointer would pass the User B check and fail this one.
    func testPurgedContentDoesNotReturnForTheSameAccount() {
        StorytopiaLocalAccountScope.setActiveUserID(userA)
        let draftID = createLocalContent(title: "UserA")

        LocalUserDataPurge.purgeAll()
        StorytopiaLocalAccountScope.setActiveUserID(userA)

        XCTAssertFalse(
            localContentIsPresent(draftID: draftID, title: "UserA"),
            "Signing back in resurrected content the purge should have deleted"
        )
    }

    /// The leak the scoped stores create on their own: content written while signed out is migrated
    /// into whichever account signs in next. If sign-out purged only the account's own scope, User
    /// A's work would arrive in User B's account through that migration.
    func testAnonymousScopeContentIsPurgedSoItCannotMigrateIntoTheNextAccount() {
        StorytopiaLocalAccountScope.setActiveUserID(nil)
        let draftID = createLocalContent(title: "Anonymous")

        LocalUserDataPurge.purgeAll()

        StorytopiaLocalAccountScope.setActiveUserID(userB)
        XCTAssertFalse(
            localContentIsPresent(draftID: draftID, title: "Anonymous"),
            "Anonymous-scope content migrated into the next account that signed in"
        )
    }

    // MARK: - What the purge must not touch

    func testDevicePreferencesSurviveThePurge() {
        let defaults = UserDefaults.standard
        for key in LocalUserDataPurge.devicePreferenceKeys {
            defaults.set("kept", forKey: key)
        }
        defer {
            for key in LocalUserDataPurge.devicePreferenceKeys {
                defaults.removeObject(forKey: key)
            }
        }

        LocalUserDataPurge.purgeAll()

        for key in LocalUserDataPurge.devicePreferenceKeys {
            XCTAssertEqual(
                defaults.string(forKey: key),
                "kept",
                "Device preference \(key) was cleared by the sign-out purge"
            )
        }
    }

    /// A device preference stays a device preference in its scoped form, so a store that starts
    /// writing one per account does not quietly become purgeable.
    func testScopedDevicePreferenceKeysAreAlsoPreserved() {
        StorytopiaLocalAccountScope.setActiveUserID(userA)

        XCTAssertFalse(
            LocalUserDataPurge.shouldPurgeUserDefaultsKey(
                StorytopiaLocalAccountScope.scopedUserDefaultsKey("StorytopiaSelectedEntryLayout")
            )
        )
        XCTAssertTrue(
            LocalUserDataPurge.shouldPurgeUserDefaultsKey(
                StorytopiaLocalAccountScope.scopedUserDefaultsKey("StorytopiaUserChapters")
            )
        )
    }

    /// Defaults that belong to the system or to a dependency are none of the purge's business.
    func testForeignUserDefaultsKeysAreLeftAlone() {
        XCTAssertFalse(LocalUserDataPurge.shouldPurgeUserDefaultsKey("AppleLanguages"))
        XCTAssertFalse(LocalUserDataPurge.shouldPurgeUserDefaultsKey("sb-storytopia-auth-token"))
        XCTAssertFalse(LocalUserDataPurge.shouldPurgeUserDefaultsKey("NSInterfaceStyle"))
    }

    /// Account state that is *not* content still has to go: onboarding progress belongs to the
    /// person, and User B should meet the sample banner for themselves.
    func testAccountOnboardingStateIsPurged() {
        XCTAssertTrue(LocalUserDataPurge.shouldPurgeUserDefaultsKey("StorytopiaEntriesSampleBannerDismissed"))
        XCTAssertTrue(LocalUserDataPurge.shouldPurgeUserDefaultsKey("StorytopiaEntriesSamplesCompleted"))
        XCTAssertTrue(LocalUserDataPurge.shouldPurgeUserDefaultsKey("StorytopiaActiveSampleStoryPack"))
    }

    // MARK: - Failure isolation

    /// One unusable location must not cost the purge everything after it. A file sitting where a
    /// directory is expected cannot be removed as a tree, which is the closest reproducible stand-in
    /// for a removal that fails partway through a real purge.
    func testPurgeContinuesAfterAFailedStep() throws {
        StorytopiaLocalAccountScope.setActiveUserID(userA)
        let draftID = createLocalContent(title: "UserA")

        // Make the caches sweep hit something it cannot delete cleanly, then confirm the defaults
        // and documents steps still ran.
        let cachesURL = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let blockerURL = cachesURL.appendingPathComponent("StorytopiaSupabaseImageCache", isDirectory: true)
        try? FileManager.default.removeItem(at: blockerURL)
        FileManager.default.createFile(atPath: blockerURL.path, contents: Data("not a directory".utf8))
        defer { try? FileManager.default.removeItem(at: blockerURL) }

        LocalUserDataPurge.purgeAll()

        XCTAssertFalse(CreateEntryDraftStore.exists(id: draftID), "Documents purge was skipped")
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "UserDefaults purge was skipped")
        XCTAssertTrue(EntryLocationRecentStore.all.isEmpty, "UserDefaults purge was skipped")
    }

    /// Purging an already-empty device is a no-op, not a crash — sign-out can run twice, and can run
    /// when there was never anything to clear.
    func testPurgeIsSafeToRepeatOnAnEmptyDevice() {
        LocalUserDataPurge.purgeAll()
        LocalUserDataPurge.purgeAll()

        XCTAssertTrue(CreateEntryDraftStore.loadAll().isEmpty)
        XCTAssertTrue(GeneratedStoryboardStore.load().isEmpty)
    }

    // MARK: - In-memory state

    func testGenerationCreditStoreIsResetByThePurge() async {
        let creditStore = GenerationCreditStore()
        LocalUserDataPurge.register(generationCreditStore: creditStore)

        creditStore.errorMessage = "stale"
        LocalUserDataPurge.purgeAll()

        XCTAssertNil(creditStore.balance)
        XCTAssertNil(creditStore.errorMessage)
        XCTAssertFalse(creditStore.hasKnownBalance)
    }
}
