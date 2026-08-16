import XCTest
import UIKit
@testable import Journaltopia

/// Covers the local autosave/recovery layer: the uncommitted-edits flag drafts carry, the pointer
/// that finds an unfinished compose again after a relaunch, the rule that decides whether a cloud
/// download may overwrite the local copy, and the debounce that keeps typing from writing to disk
/// on every keystroke.
///
/// Every test here runs against a throwaway account scope, so nothing it writes can be confused
/// with — or leak into — the drafts of a real signed-in user.
@MainActor
final class LocalDraftAutosaveTests: XCTestCase {

    private var scopeID: UUID!

    override func setUp() {
        super.setUp()
        scopeID = UUID()
        JournaltopiaLocalAccountScope.setActiveUserID(scopeID)
        UnfinishedCreateSessionStore.clear()
    }

    override func tearDown() {
        UnfinishedCreateSessionStore.clear()
        try? FileManager.default.removeItem(
            at: JournaltopiaLocalAccountScope.scopedDirectory(named: "CreateEntryDrafts")
        )
        JournaltopiaLocalAccountScope.setActiveUserID(nil)
        scopeID = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func image(_ color: UIColor = .red) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    @discardableResult
    private func saveDraft(
        id: UUID?,
        title: String = "Title",
        text: String = "Text",
        photos: [UIImage] = [],
        cloudSyncState: CreateEntryDraftCloudSyncState = .unchanged
    ) -> UUID? {
        CreateEntryDraftStore.save(
            id: id,
            title: title,
            text: text,
            richText: NotebookRichTextDocument(text: text),
            photos: photos,
            artStyle: "Anime",
            location: "",
            date: Date(),
            savesDraft: true,
            isPrivate: false,
            thumbnail: image(.blue),
            cloudSyncState: cloudSyncState
        )
    }

    private func autosave(id: UUID, title: String = "Title", text: String) -> Bool {
        CreateEntryDraftStore.autosaveEditorState(
            id: id,
            title: title,
            text: text,
            richText: NotebookRichTextDocument(text: text),
            artStyle: "Anime",
            location: "",
            date: Date(),
            datePrecision: .noDate,
            savesDraft: true,
            isPrivate: false,
            fontChoiceRawValue: "sans",
            textColorIndex: 0,
            textSize: 1,
            paperStyleRawValue: "classic",
            paperColorIndex: 0,
            isBold: false,
            isItalic: false,
            isUnderlined: false,
            isStrikethrough: false,
            isHighlighted: false,
            textAlignmentRawValue: "leading"
        )
    }

    /// Applies a discard exactly as `CreateEntryView.applyDiscardOutcome` does: the policy picks the
    /// outcome, and the outcome decides what happens to the local draft. The editor's own state
    /// resets are not modelled here — this is about what survives on disk.
    private func discard(draftID: UUID, hasCommittedCloudVersion: Bool) {
        let outcome = DiscardLocalEditsPolicy.outcome(
            isUnfinishedCompose: UnfinishedCreateSessionStore.draftID == draftID,
            hasUncommittedLocalEdits: CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID),
            hasCommittedCloudVersion: hasCommittedCloudVersion
        )

        switch outcome {
        case .deleteUnfinishedCompose:
            CreateEntryDraftStore.delete(id: draftID)
            UnfinishedCreateSessionStore.clear()
            EntryCloudSyncFailureStore.clear(clientEntryID: draftID)
        case .deleteLocalCache:
            CreateEntryDraftStore.delete(id: draftID)
        case .keepLocalCopy:
            CreateEntryDraftStore.markCloudSynchronized(id: draftID)
        }
    }

    private func autosaveSignature(
        title: String = "Title",
        text: String = "Text",
        artStyle: String = "Anime",
        location: String = "",
        date: Date = Date(timeIntervalSince1970: 1_000_000),
        datePrecision: EntryDatePrecision = .noDate,
        savesDraft: Bool = true,
        isPrivate: Bool = false,
        statusRawValue: String = JournalEntryStatus.draft.rawValue,
        fontChoiceRawValue: String = "sans",
        textColorIndex: Int = 0,
        textSize: Double = 1,
        paperStyleRawValue: String = "classic",
        paperColorIndex: Int = 0
    ) -> CreateEntryAutosaveSignature {
        CreateEntryAutosaveSignature(
            title: title,
            text: text,
            richText: NotebookRichTextDocument(text: text),
            photoIDs: [],
            characters: [],
            artStyle: artStyle,
            location: location,
            date: date,
            datePrecision: datePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivate,
            statusRawValue: statusRawValue,
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex
        )
    }

    // MARK: - Uncommitted-edit metadata

    func testANewDraftIsNotFlaggedAheadOfTheCloudUntilAutosaveSaysSo() {
        guard let draftID = saveDraft(id: nil) else {
            return XCTFail("the draft should have been written")
        }

        XCTAssertTrue(CreateEntryDraftStore.exists(id: draftID))
        XCTAssertFalse(
            CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID),
            "a plain save carries no claim about the cloud either way"
        )
    }

    func testAutosaveFlagsTheDraftAsAheadOfTheCloudAndCommittingClearsIt() {
        guard let draftID = saveDraft(id: nil) else {
            return XCTFail("the draft should have been written")
        }

        XCTAssertTrue(autosave(id: draftID, text: "typed some more"))
        XCTAssertTrue(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))

        CreateEntryDraftStore.markCloudSynchronized(id: draftID)
        XCTAssertFalse(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))
    }

    func testAFullSaveCarriesTheUncommittedFlagForwardUnlessItIsToldOtherwise() {
        guard let draftID = saveDraft(id: nil, cloudSyncState: .uncommitted) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))

        // The default `.unchanged` is what every pre-existing caller uses: it must not silently
        // declare an autosaved draft synchronized.
        saveDraft(id: draftID, text: "media rewrite")
        XCTAssertTrue(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))

        saveDraft(id: draftID, text: "cloud snapshot", cloudSyncState: .synchronized)
        XCTAssertFalse(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))
    }

    func testAutosaveRewritesTheWritingWithoutDisturbingPhotosOrTheThumbnail() {
        guard let draftID = saveDraft(id: nil, text: "first", photos: [image(.green), image(.blue)]) else {
            return XCTFail("the draft should have been written")
        }
        let originalPhotoIDs = CreateEntryDraftStore.load(id: draftID)?.photos.map(\.id)

        XCTAssertTrue(autosave(id: draftID, title: "Renamed", text: "second"))

        guard let reloaded = CreateEntryDraftStore.load(id: draftID) else {
            return XCTFail("the draft should still be readable")
        }
        XCTAssertEqual(reloaded.text, "second")
        XCTAssertEqual(reloaded.title, "Renamed")
        XCTAssertEqual(reloaded.photos.map(\.id), originalPhotoIDs, "autosave must not re-encode media")
        XCTAssertNotNil(reloaded.thumbnail, "autosave must not drop the thumbnail")
    }

    func testAutosaveReportsFailureWhenThereIsNoDraftOnDiskYet() {
        XCTAssertFalse(
            autosave(id: UUID(), text: "nothing to update"),
            "the caller needs this answer to know it has to fall back to a full save"
        )
    }

    func testDeletingADraftTakesItsUncommittedFlagWithIt() {
        guard let draftID = saveDraft(id: nil, cloudSyncState: .uncommitted) else {
            return XCTFail("the draft should have been written")
        }

        CreateEntryDraftStore.delete(id: draftID)

        XCTAssertFalse(CreateEntryDraftStore.exists(id: draftID))
        XCTAssertFalse(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))
    }

    /// The autosave write is a synchronous local file write that returns a `Bool`. There is no
    /// suspension point it could reach Supabase through, and no Supabase type in its signature.
    func testAutosaveIsAPurelyLocalWrite() {
        guard let draftID = saveDraft(id: nil, text: "before") else {
            return XCTFail("the draft should have been written")
        }
        let originalUpdatedAt = CreateEntryDraftStore.load(id: draftID)?.updatedAt

        XCTAssertTrue(autosave(id: draftID, text: "after"))

        let updatedDraft = CreateEntryDraftStore.load(id: draftID)
        XCTAssertEqual(updatedDraft?.text, "after")
        XCTAssertNotNil(originalUpdatedAt)
        XCTAssertGreaterThanOrEqual(
            updatedDraft?.updatedAt ?? .distantPast,
            originalUpdatedAt ?? .distantFuture
        )
    }

    // MARK: - Cloud materialization precedence

    func testAnEntryWithNoLocalCopyMaterializesFromTheCloud() {
        XCTAssertEqual(
            CreateEntryCloudMaterialization.decision(hasLocalDraft: false, hasUncommittedLocalEdits: false),
            .materializeCloud
        )
        XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: UUID()), .materializeCloud)
    }

    func testASynchronizedLocalCopyStillLetsTheCloudRefreshIt() {
        guard let draftID = saveDraft(id: nil, cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }

        XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: draftID), .materializeCloud)
    }

    func testLocallyAutosavedEditsAreNotOverwrittenByTheOlderCloudSnapshot() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "typed after the last save"))

        XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: draftID), .preserveLocalEdits)
    }

    func testReopeningRepeatedlyKeepsProtectingThePendingLocalEdits() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "pending"))

        for _ in 0..<3 {
            XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: draftID), .preserveLocalEdits)
            XCTAssertEqual(CreateEntryDraftStore.load(id: draftID)?.text, "pending")
        }
    }

    func testCommittingTheLocalEditsHandsControlBackToTheCloud() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "pending"))
        XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: draftID), .preserveLocalEdits)

        // What `EntrySaveService` does the moment Supabase confirms the entry row.
        CreateEntryDraftStore.markCloudSynchronized(id: draftID)

        XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: draftID), .materializeCloud)
    }

    // MARK: - Discarding unsaved edits

    func testDiscardChoosesDeletionOnlyWhenThereIsSomethingToFallBackOn() {
        XCTAssertEqual(
            DiscardLocalEditsPolicy.outcome(
                isUnfinishedCompose: true,
                hasUncommittedLocalEdits: true,
                hasCommittedCloudVersion: false
            ),
            .deleteUnfinishedCompose,
            "a compose that never reached Supabase goes entirely"
        )

        XCTAssertEqual(
            DiscardLocalEditsPolicy.outcome(
                isUnfinishedCompose: false,
                hasUncommittedLocalEdits: true,
                hasCommittedCloudVersion: true
            ),
            .deleteLocalCache,
            "a cloud-backed entry drops its dirty cache and refetches"
        )

        XCTAssertEqual(
            DiscardLocalEditsPolicy.outcome(
                isUnfinishedCompose: false,
                hasUncommittedLocalEdits: true,
                hasCommittedCloudVersion: false
            ),
            .keepLocalCopy,
            "with nothing committed anywhere, deleting would be data loss rather than a discard"
        )

        XCTAssertEqual(
            DiscardLocalEditsPolicy.outcome(
                isUnfinishedCompose: false,
                hasUncommittedLocalEdits: false,
                hasCommittedCloudVersion: true
            ),
            .keepLocalCopy,
            "nothing was autosaved, so the copy on disk is already the committed one"
        )
    }

    /// 1 and 2: an existing entry is edited, the edit is autosaved locally, and discarding it takes
    /// the discarded writing out of the local store there and then.
    func testDiscardingACloudBackedEntryRemovesTheDiscardedTextImmediately() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "discarded"))
        XCTAssertEqual(CreateEntryDraftStore.load(id: draftID)?.text, "discarded")

        discard(draftID: draftID, hasCommittedCloudVersion: true)

        XCTAssertNil(CreateEntryDraftStore.load(id: draftID), "the dirty cache is gone")
        XCTAssertFalse(CreateEntryDraftStore.exists(id: draftID))
        XCTAssertFalse(
            CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID),
            "and nothing is left behind claiming to be ahead of the cloud"
        )
    }

    /// 3: reopening goes back through materialization, which writes the committed version.
    func testReopeningAfterDiscardBringsBackTheCommittedVersion() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "discarded"))
        discard(draftID: draftID, hasCommittedCloudVersion: true)

        XCTAssertEqual(
            CreateEntryCloudMaterialization.decision(for: draftID),
            .materializeCloud,
            "with no local draft left there is nothing to protect, so the cloud copy is written"
        )

        // What `materializeCloudEntryIfNeeded` does once the download lands.
        saveDraft(id: draftID, text: "committed", cloudSyncState: .synchronized)

        XCTAssertEqual(CreateEntryDraftStore.load(id: draftID)?.text, "committed")
        XCTAssertFalse(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))
    }

    /// 4: with no cloud round trip at all — the offline case — the discarded text still has nowhere
    /// to come back from, because the local store no longer holds it.
    func testDiscardedTextCannotReturnFromTheLocalStoreOffline() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "discarded"))
        discard(draftID: draftID, hasCommittedCloudVersion: true)

        // Every local read the editor could make on reopen, with the network unavailable.
        XCTAssertNil(CreateEntryDraftStore.load(id: draftID))
        XCTAssertNil(CreateEntryDraftStore.createdAt(id: draftID))
        XCTAssertFalse(CreateEntryDraftStore.exists(id: draftID))
        XCTAssertFalse(
            CreateEntryDraftStore.loadAll().contains { $0.id == draftID },
            "and it is not reachable through a full scan either"
        )
    }

    /// 5: the debounce is cancelled before the draft is touched, so a write that was already in
    /// flight when the user hit Discard cannot put the discarded text on disk behind them. Here
    /// nothing had been autosaved yet, so the committed copy is simply left intact.
    func testAPendingAutosaveCannotWriteDiscardedTextOverTheCommittedCopy() async {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        let scheduler = LocalDraftAutosaveScheduler(debounceInterval: 0.1)

        // The user types, which queues a write, and then discards before it fires.
        scheduler.schedule {
            _ = self.autosave(id: draftID, text: "discarded")
        }
        scheduler.cancelPending()
        discard(draftID: draftID, hasCommittedCloudVersion: true)

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(
            CreateEntryDraftStore.load(id: draftID)?.text,
            "committed",
            "the queued write never landed"
        )
        XCTAssertFalse(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))
    }

    /// And when an autosave *had* already landed, so the discard deleted the dirty cache, a second
    /// write still queued behind it must not recreate the draft it just removed.
    func testAPendingAutosaveCannotResurrectADraftDeletedByDiscard() async {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "discarded"))

        let scheduler = LocalDraftAutosaveScheduler(debounceInterval: 0.1)
        scheduler.schedule {
            _ = self.autosave(id: draftID, text: "discarded even more")
        }
        scheduler.cancelPending()
        discard(draftID: draftID, hasCommittedCloudVersion: true)

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(CreateEntryDraftStore.exists(id: draftID), "the queued write never landed")
        XCTAssertNil(CreateEntryDraftStore.load(id: draftID))
    }

    func testDiscardingAnUnfinishedComposeAlsoRetiresItsRecoveryPointer() {
        guard let draftID = saveDraft(id: nil, text: "half an entry", cloudSyncState: .uncommitted) else {
            return XCTFail("the draft should have been written")
        }
        UnfinishedCreateSessionStore.setDraftID(draftID)

        discard(draftID: draftID, hasCommittedCloudVersion: false)

        XCTAssertFalse(CreateEntryDraftStore.exists(id: draftID))
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "so a relaunch cannot restore it")
    }

    func testAnEntryWithNothingCommittedAnywhereKeepsItsOnlyCopy() {
        guard let draftID = saveDraft(id: nil, text: "local only", cloudSyncState: .uncommitted) else {
            return XCTFail("the draft should have been written")
        }

        discard(draftID: draftID, hasCommittedCloudVersion: false)

        XCTAssertEqual(
            CreateEntryDraftStore.load(id: draftID)?.text,
            "local only",
            "there is no committed version to restore, so this is the entry rather than an edit to it"
        )
        XCTAssertFalse(CreateEntryDraftStore.hasUncommittedLocalEdits(id: draftID))
    }

    // MARK: - Unfinished compose pointer

    func testThePointerRemembersAndForgetsTheUnfinishedCompose() {
        let draftID = UUID()
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "an untouched Create page points at nothing")

        UnfinishedCreateSessionStore.setDraftID(draftID)
        XCTAssertEqual(UnfinishedCreateSessionStore.draftID, draftID)

        UnfinishedCreateSessionStore.clear()
        XCTAssertNil(UnfinishedCreateSessionStore.draftID)
    }

    func testClearingThePointerOnlyRetiresTheDraftItActuallyNames() {
        let composeID = UUID()
        UnfinishedCreateSessionStore.setDraftID(composeID)

        UnfinishedCreateSessionStore.clearIfMatches(draftID: UUID())
        XCTAssertEqual(
            UnfinishedCreateSessionStore.draftID,
            composeID,
            "saving some other entry must not strand this compose session"
        )

        UnfinishedCreateSessionStore.clearIfMatches(draftID: composeID)
        XCTAssertNil(UnfinishedCreateSessionStore.draftID)
    }

    func testAnotherAccountNeverSeesThisAccountsUnfinishedCompose() {
        let composeID = UUID()
        UnfinishedCreateSessionStore.setDraftID(composeID)

        JournaltopiaLocalAccountScope.setActiveUserID(UUID())
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "a second signed-in account starts blank")

        JournaltopiaLocalAccountScope.setActiveUserID(nil)
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "anonymous mode starts blank")

        JournaltopiaLocalAccountScope.setActiveUserID(scopeID)
        XCTAssertEqual(UnfinishedCreateSessionStore.draftID, composeID, "and the owner still has it")
    }

    // MARK: - Formatting and other persisted settings

    /// Autosave watches one normalized signature rather than a handful of text bindings, so a
    /// change to a persisted setting is as visible to it as a keystroke. Each of these would have
    /// gone unnoticed by a text-only trigger set.
    func testEveryPersistedEditorSettingIsVisibleToAutosave() {
        let baseline = autosaveSignature()

        let changes: [(String, CreateEntryAutosaveSignature)] = [
            ("font", autosaveSignature(fontChoiceRawValue: "serif")),
            ("paper style", autosaveSignature(paperStyleRawValue: "grid")),
            ("paper colour", autosaveSignature(paperColorIndex: 3)),
            ("text colour", autosaveSignature(textColorIndex: 2)),
            ("text size", autosaveSignature(textSize: 1.4)),
            ("art style", autosaveSignature(artStyle: "Manga")),
            ("location", autosaveSignature(location: "Lisbon")),
            ("date", autosaveSignature(date: Date(timeIntervalSince1970: 2_000_000))),
            ("date precision", autosaveSignature(datePrecision: .dateOnly)),
            ("privacy", autosaveSignature(isPrivate: true)),
            ("saves-draft", autosaveSignature(savesDraft: false)),
            ("status", autosaveSignature(statusRawValue: JournalEntryStatus.completed.rawValue))
        ]

        for (field, changed) in changes {
            XCTAssertNotEqual(baseline, changed, "a \(field) change has to reach autosave")
        }
    }

    func testAFontOnlyChangeProducesExactlyOneDebouncedWrite() async {
        let driver = AutosaveWiringDriver(hydratedWith: autosaveSignature(), debounceInterval: 0.12)

        driver.apply(autosaveSignature(fontChoiceRawValue: "serif"))

        await driver.waitForQuiet()
        XCTAssertEqual(driver.writes.count, 1)
        XCTAssertEqual(driver.writes.first?.fontChoiceRawValue, "serif")
    }

    func testAPaperOnlyChangeProducesADebouncedWrite() async {
        let driver = AutosaveWiringDriver(hydratedWith: autosaveSignature(), debounceInterval: 0.12)

        driver.apply(autosaveSignature(paperStyleRawValue: "grid", paperColorIndex: 2))

        await driver.waitForQuiet()
        XCTAssertEqual(driver.writes.count, 1)
        XCTAssertEqual(driver.writes.first?.paperStyleRawValue, "grid")
    }

    func testANonTextSettingSuchAsPrivacyProducesADebouncedWrite() async {
        let driver = AutosaveWiringDriver(hydratedWith: autosaveSignature(), debounceInterval: 0.12)

        driver.apply(autosaveSignature(isPrivate: true))

        await driver.waitForQuiet()
        XCTAssertEqual(driver.writes.count, 1)
        XCTAssertEqual(driver.writes.first?.isPrivate, true)
    }

    func testSeveralFormattingChangesInOneWindowCollapseIntoOneWrite() async {
        let driver = AutosaveWiringDriver(hydratedWith: autosaveSignature(), debounceInterval: 0.12)

        // What one trip through the formatting sheet looks like.
        driver.apply(autosaveSignature(fontChoiceRawValue: "serif"))
        driver.apply(autosaveSignature(fontChoiceRawValue: "serif", textColorIndex: 2))
        driver.apply(autosaveSignature(fontChoiceRawValue: "serif", textColorIndex: 2, textSize: 1.4))
        driver.apply(
            autosaveSignature(
                fontChoiceRawValue: "serif",
                textColorIndex: 2,
                textSize: 1.4,
                paperStyleRawValue: "grid"
            )
        )

        await driver.waitForQuiet()
        XCTAssertEqual(driver.writes.count, 1, "one settled state, one local write")
        XCTAssertEqual(driver.writes.first?.paperStyleRawValue, "grid")
        XCTAssertEqual(driver.writes.first?.textSize, 1.4)
    }

    func testHydratingTheEditorDoesNotProduceAWrite() async {
        let driver = AutosaveWiringDriver(hydratedWith: autosaveSignature(), debounceInterval: 0.12)

        // Opening an entry replaces every field at once. The trigger fires, but the state now
        // matches what is already on disk, so the write that lands has nothing to do.
        driver.hydrate(with: autosaveSignature(text: "restored", fontChoiceRawValue: "serif"))

        await driver.waitForQuiet()
        XCTAssertEqual(driver.writes.count, 0, "hydration must not manufacture a draft")
    }

    func testAnEditAfterHydrationStillWrites() async {
        let driver = AutosaveWiringDriver(hydratedWith: autosaveSignature(), debounceInterval: 0.12)
        driver.hydrate(with: autosaveSignature(text: "restored"))
        await driver.waitForQuiet()

        driver.apply(autosaveSignature(text: "restored", paperColorIndex: 4))

        await driver.waitForQuiet()
        XCTAssertEqual(driver.writes.count, 1)
    }

    // MARK: - Debounce

    func testRapidEditsCollapseIntoASingleWrite() async {
        let scheduler = LocalDraftAutosaveScheduler(debounceInterval: 0.12)
        var writes = 0
        let written = expectation(description: "one debounced write")

        for _ in 0..<5 {
            scheduler.schedule {
                writes += 1
                written.fulfill()
            }
        }
        XCTAssertTrue(scheduler.hasPendingWork)

        await fulfillment(of: [written], timeout: 2)
        XCTAssertEqual(writes, 1, "five keystrokes are one write, not five")
        XCTAssertFalse(scheduler.hasPendingWork)
    }

    func testCancellingStopsAWriteThatHasNotFiredYet() async {
        let scheduler = LocalDraftAutosaveScheduler(debounceInterval: 0.1)
        var writes = 0

        scheduler.schedule { writes += 1 }
        scheduler.cancelPending()
        XCTAssertFalse(scheduler.hasPendingWork)

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(writes, 0, "a discarded entry must not be resurrected by a pending autosave")
    }

    func testFlushWritesNowAndLeavesNothingBehindToFireLater() async {
        let scheduler = LocalDraftAutosaveScheduler(debounceInterval: 0.1)
        var writes = 0

        scheduler.schedule { writes += 1 }
        scheduler.flush { writes += 1 }

        XCTAssertEqual(writes, 1, "backgrounding writes immediately")
        XCTAssertFalse(scheduler.hasPendingWork)

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(writes, 1, "and the debounced write it replaced never lands")
    }

    func testASecondEditAfterAFlushSchedulesAgain() async {
        let scheduler = LocalDraftAutosaveScheduler(debounceInterval: 0.1)
        var writes = 0
        let written = expectation(description: "the follow-up write")

        scheduler.flush { writes += 1 }
        scheduler.schedule {
            writes += 1
            written.fulfill()
        }

        await fulfillment(of: [written], timeout: 2)
        XCTAssertEqual(writes, 2)
    }
}

/// Mirrors the three pieces the editor wires together for autosave: a change to the persisted
/// editor state starts a debounce on the real `LocalDraftAutosaveScheduler`, and the write that
/// lands at the end of it is skipped when the state already matches what was last persisted —
/// `CreateEntryView.handleEditorContentChange` and the guards at the top of `performLocalAutosave`.
///
/// The `.onChange(of: currentAutosaveSignature)` binding that feeds it lives in the SwiftUI view
/// and is covered by the build rather than by this driver.
@MainActor
private final class AutosaveWiringDriver {
    private let scheduler: LocalDraftAutosaveScheduler
    private let debounceInterval: TimeInterval
    private var currentSignature: CreateEntryAutosaveSignature
    private var lastPersistedSignature: CreateEntryAutosaveSignature
    private(set) var writes: [CreateEntryAutosaveSignature] = []

    init(hydratedWith signature: CreateEntryAutosaveSignature, debounceInterval: TimeInterval) {
        self.currentSignature = signature
        self.lastPersistedSignature = signature
        self.debounceInterval = debounceInterval
        self.scheduler = LocalDraftAutosaveScheduler(debounceInterval: debounceInterval)
    }

    /// The user changing something the editor persists.
    func apply(_ signature: CreateEntryAutosaveSignature) {
        // SwiftUI only calls `onChange` when the observed value actually differs.
        guard signature != currentSignature else {
            return
        }

        currentSignature = signature
        scheduler.schedule { [weak self] in
            self?.performWrite()
        }
    }

    /// Opening an entry: every field is replaced programmatically and the baseline moves with it,
    /// which is what `loadSavedDraftIfNeeded` does when it sets `autosavedDraftSnapshot`.
    func hydrate(with signature: CreateEntryAutosaveSignature) {
        currentSignature = signature
        lastPersistedSignature = signature
        scheduler.schedule { [weak self] in
            self?.performWrite()
        }
    }

    func waitForQuiet() async {
        try? await Task.sleep(nanoseconds: UInt64((debounceInterval + 0.25) * 1_000_000_000))
    }

    private func performWrite() {
        guard currentSignature != lastPersistedSignature else {
            return
        }

        lastPersistedSignature = currentSignature
        writes.append(currentSignature)
    }
}
