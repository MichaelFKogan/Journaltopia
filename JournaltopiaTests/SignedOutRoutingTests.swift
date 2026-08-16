import XCTest
import UIKit
@testable import Journaltopia

/// Covers the decisions that used to be made screen-by-screen from `authStore.userID != nil`: which
/// content source a screen reads, and whether a write that claims account ownership is allowed.
///
/// The cases worth pinning are the ones that a `userID` check cannot express at all. A session still
/// being checked and a build with no Supabase credentials both produce a nil user ID, and both used
/// to render as a signed-out visitor — the first as a flash of sample content, the second as a
/// permanently empty browse. Neither is signed out, and neither is fixed by signing in.
@MainActor
final class SignedOutRoutingTests: XCTestCase {

    override func tearDown() {
        SampleContentStore.clear()
        super.tearDown()
    }

    // MARK: - Mode derivation

    func testSignedOutStatusBrowsesSamples() {
        let mode = JournaltopiaContentMode(status: .signedOut, isSampleAuthorModeEnabled: false)

        XCTAssertEqual(mode, .sampleBrowsing)
        XCTAssertTrue(mode.showsSampleContent)
        XCTAssertFalse(mode.canPersistUserContent)
        XCTAssertTrue(mode.requiresSignIn)
        XCTAssertTrue(mode.isResolved)
        XCTAssertNil(mode.unavailableMessage)
    }

    /// Sample Author Mode is a device toggle, so it is only meaningful with an account behind it.
    /// A signed-out device with the toggle left on from a previous session still browses.
    func testSampleAuthorToggleWithoutAccountStillBrowses() {
        let mode = JournaltopiaContentMode(status: .signedOut, isSampleAuthorModeEnabled: true)

        XCTAssertEqual(mode, .sampleBrowsing)
        XCTAssertFalse(mode.isSampleAuthoring)
        XCTAssertEqual(mode.authoringMode, .user)
    }

    func testSignedInWithSampleAuthorModeAuthorsSamples() {
        let mode = JournaltopiaContentMode(status: .signedIn, isSampleAuthorModeEnabled: true)

        XCTAssertEqual(mode, .sampleAuthoring)
        XCTAssertTrue(mode.showsSampleContent)
        XCTAssertEqual(mode.authoringMode, .sampleStudio)
        // Sample edits are real, but they go to the sample tables rather than to the account, so the
        // gate must not wave them through as account writes.
        XCTAssertFalse(mode.canPersistUserContent)
        XCTAssertFalse(mode.requiresSignIn)
    }

    func testSignedInReadsAndWritesTheAccount() {
        let mode = JournaltopiaContentMode(status: .signedIn, isSampleAuthorModeEnabled: false)

        XCTAssertEqual(mode, .user)
        XCTAssertFalse(mode.showsSampleContent)
        XCTAssertTrue(mode.canPersistUserContent)
        XCTAssertFalse(mode.requiresSignIn)
        XCTAssertEqual(mode.authoringMode, .user)
    }

    /// The case a `userID` check cannot see. Launch has a nil user ID before `refreshCurrentUser()`
    /// resolves, and screens used to commit to sample content on the strength of it.
    func testLoadingIsNotSignedOut() {
        let mode = JournaltopiaContentMode(status: .loading, isSampleAuthorModeEnabled: false)

        XCTAssertEqual(mode, .loading)
        XCTAssertFalse(mode.isResolved)
        XCTAssertFalse(mode.showsSampleContent)
        XCTAssertFalse(mode.canPersistUserContent)
        // Signing in is not what a still-running session check is waiting for.
        XCTAssertFalse(mode.requiresSignIn)
    }

    /// The other one. Without credentials neither the account's content nor the sample pack can
    /// load, so an empty sample browse would be a lie and a sign-in button would not fix it.
    func testMisconfiguredIsNotSignedOut() {
        let mode = JournaltopiaContentMode(
            status: .misconfigured("Supabase is not configured."),
            isSampleAuthorModeEnabled: false
        )

        XCTAssertTrue(mode.isResolved)
        XCTAssertFalse(mode.showsSampleContent)
        XCTAssertFalse(mode.canPersistUserContent)
        XCTAssertFalse(mode.requiresSignIn)
        XCTAssertEqual(mode.unavailableMessage, "Supabase is not configured.")
    }

    /// `.task(id:)` and `.onChange` hang off this, so two different modes must never share an
    /// identity — otherwise a screen keeps the previous mode's content without reloading.
    func testLoadIdentitiesAreDistinctPerMode() {
        let userID = UUID()
        let identities = [
            JournaltopiaContentMode.loading,
            .unavailable("nope"),
            .sampleBrowsing,
            .sampleAuthoring,
            .user
        ].map { $0.loadIdentity(userID: userID) }

        XCTAssertEqual(Set(identities).count, identities.count)
    }

    func testUserLoadIdentityChangesWithAccount() {
        let mode = JournaltopiaContentMode.user

        XCTAssertNotEqual(mode.loadIdentity(userID: UUID()), mode.loadIdentity(userID: UUID()))
    }

    /// Browsing is the same pack for everyone, so the identity must not vary with a stale user ID —
    /// otherwise signing out would reload samples once per previous account.
    func testSampleBrowsingLoadIdentityIgnoresAccount() {
        XCTAssertEqual(
            JournaltopiaContentMode.sampleBrowsing.loadIdentity(userID: UUID()),
            JournaltopiaContentMode.sampleBrowsing.loadIdentity(userID: nil)
        )
    }

    // MARK: - The gate

    func testGateAllowsSignedInWrites() {
        let gate = SignInGate()
        gate.update(mode: .user)

        XCTAssertTrue(gate.requireAccount(for: .saveEntry))
        XCTAssertNil(gate.pendingRequest)
    }

    func testGateRefusesAndPresentsWhenSignedOut() {
        let gate = SignInGate()
        gate.update(mode: .sampleBrowsing)

        XCTAssertFalse(gate.requireAccount(for: .createJournal))
        XCTAssertEqual(gate.pendingRequest?.action, .createJournal)
    }

    /// A refusal is not the same as an offer to sign in. Neither of these can be resolved by signing
    /// in, so neither should raise the sheet.
    func testGateRefusesWithoutPresentingWhenSignInCannotHelp() {
        for mode in [JournaltopiaContentMode.loading, .unavailable("no credentials")] {
            let gate = SignInGate()
            gate.update(mode: mode)

            XCTAssertFalse(gate.requireAccount(for: .generateStoryboard), "\(mode)")
            XCTAssertNil(gate.pendingRequest, "\(mode)")
        }
    }

    /// A sample author is signed in. The gate asks whether there is an account, not which tables the
    /// write lands in, so it must let them through — locking them out would break the journal and
    /// entry editing they turned Sample Author Mode on to do.
    func testGateAllowsSampleAuthorWrites() {
        let gate = SignInGate()
        gate.update(mode: .sampleAuthoring)

        XCTAssertTrue(gate.requireAccount(for: .saveEntry))
        XCTAssertNil(gate.pendingRequest)
    }

    func testSuccessfulSignInRunsTheActionTheUserWanted() {
        let gate = SignInGate()
        gate.update(mode: .sampleBrowsing)

        var retried = 0
        XCTAssertFalse(gate.requireAccount(for: .generateStoryboard) { retried += 1 })

        gate.completePendingRequest()

        XCTAssertEqual(retried, 1)
        XCTAssertNil(gate.pendingRequest)
    }

    func testDismissDropsTheRequestWithoutRetrying() {
        let gate = SignInGate()
        gate.update(mode: .sampleBrowsing)

        var retried = 0
        _ = gate.requireAccount(for: .saveEntry) { retried += 1 }
        gate.dismiss()

        XCTAssertEqual(retried, 0)
        XCTAssertNil(gate.pendingRequest)
    }

    /// Signing in elsewhere — Settings, or a second gate — resolves the account, so an outstanding
    /// request has nothing left to ask for.
    func testResolvingAnAccountClearsAnOutstandingRequest() {
        let gate = SignInGate()
        gate.update(mode: .sampleBrowsing)
        _ = gate.requireAccount(for: .createEntry)
        XCTAssertNotNil(gate.pendingRequest)

        gate.update(mode: .user)

        XCTAssertNil(gate.pendingRequest)
    }

    // MARK: - Sample content source

    func testSampleContentStoreServesEntriesInPackOrder() {
        let first = draft(title: "First")
        let second = draft(title: "Second")
        let third = draft(title: "Third")
        SampleContentStore.replace(with: pack(entries: [first, second, third]))

        let loaded = SampleContentStore.entries(ids: [third.id, first.id])

        XCTAssertEqual(loaded.map(\.title), ["First", "Third"])
    }

    func testSampleContentStoreSkipsEntriesThePackNoLongerCarries() {
        let known = draft(title: "Known")
        SampleContentStore.replace(with: pack(entries: [known]))

        XCTAssertEqual(SampleContentStore.entries(ids: [known.id, UUID()]).map(\.title), ["Known"])
    }

    func testSampleContentStoreSortsStoryboardsPrimaryFirst() {
        let entry = draft(title: "Entry")
        let older = storyboard(clientEntryID: entry.id, createdAt: Date(timeIntervalSince1970: 100), isPrimary: false)
        let newer = storyboard(clientEntryID: entry.id, createdAt: Date(timeIntervalSince1970: 200), isPrimary: false)
        let primary = storyboard(clientEntryID: entry.id, createdAt: Date(timeIntervalSince1970: 300), isPrimary: true)
        SampleContentStore.replace(
            with: pack(entries: [entry], storyboardsByEntryID: [entry.id: [newer, older, primary]])
        )

        XCTAssertEqual(
            SampleContentStore.storyboards(clientEntryID: entry.id).map(\.id),
            [primary.id, older.id, newer.id]
        )
    }

    /// The reason this store exists. Sample browsing used to seed the pack into
    /// `CreateEntryDraftStore`, which resolves to the `anonymous` scope when signed out — and the
    /// anonymous scope is merged into whichever account signs in next.
    func testBrowsingSamplesLeavesNothingForTheNextAccountToInherit() {
        JournaltopiaLocalAccountScope.setActiveUserID(nil)
        let entry = draft(title: "Sample Story")
        SampleContentStore.replace(with: pack(entries: [entry]))

        XCTAssertEqual(SampleContentStore.entries(ids: [entry.id]).count, 1)
        XCTAssertTrue(
            CreateEntryDraftStore.load(ids: [entry.id]).isEmpty,
            "Browsing a sample entry must not write it into the local draft store."
        )

        // And the store is session state, not storage: the next account starts from nothing.
        SampleContentStore.clear()
        XCTAssertTrue(SampleContentStore.isEmpty)
        XCTAssertTrue(SampleContentStore.entries(ids: [entry.id]).isEmpty)
    }

    // MARK: - Helpers

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func draft(title: String, id: UUID = UUID()) -> CreateEntryDraft {
        CreateEntryDraft(
            id: id,
            title: title,
            text: "\(title) body",
            richText: nil,
            photos: [],
            characters: [],
            artStyle: "Anime",
            location: "",
            date: Date(),
            datePrecision: .exact,
            savesDraft: true,
            isPrivate: false,
            status: JournalEntryStatus.completed.rawValue,
            fontChoiceRawValue: nil,
            textColorIndex: nil,
            textSize: nil,
            paperStyleRawValue: nil,
            paperColorIndex: nil,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            isStrikethrough: false,
            isHighlighted: false,
            textAlignmentRawValue: "leading",
            thumbnail: nil,
            createdAt: Date(),
            updatedAt: Date(),
            displayOrder: nil
        )
    }

    private func storyboard(
        clientEntryID: UUID,
        createdAt: Date,
        isPrimary: Bool
    ) -> GeneratedStoryboard {
        GeneratedStoryboard(
            clientEntryID: clientEntryID,
            image: image(),
            promptText: "Sample prompt",
            artStyle: "Anime",
            sourcePhotoCount: 0,
            createdAt: createdAt,
            storagePath: "journaltopia-first-run/sample.png",
            isPrimary: isPrimary,
            isSampleContent: true
        )
    }

    private func pack(
        entries: [CreateEntryDraft],
        journals: [SampleJournal] = [],
        storyboardsByEntryID: [UUID: [GeneratedStoryboard]] = [:]
    ) -> SampleStoryPack {
        SampleStoryPack(
            id: UUID(),
            slug: "journaltopia-first-run",
            version: 1,
            locale: "en",
            entries: entries,
            journals: journals,
            storyboardsByEntryID: storyboardsByEntryID
        )
    }
}
