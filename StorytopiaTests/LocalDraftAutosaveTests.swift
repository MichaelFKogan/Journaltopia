import XCTest
import UIKit
@testable import Storytopia

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
        StorytopiaLocalAccountScope.setActiveUserID(scopeID)
        UnfinishedCreateSessionStore.clear()
    }

    override func tearDown() {
        UnfinishedCreateSessionStore.clear()
        try? FileManager.default.removeItem(
            at: StorytopiaLocalAccountScope.scopedDirectory(named: "CreateEntryDrafts")
        )
        StorytopiaLocalAccountScope.setActiveUserID(nil)
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

    /// Discarding an existing entry's edits gives up the local claim, so the committed version is
    /// free to come back the next time the entry is opened.
    func testDiscardingLocalEditsLetsTheCommittedVersionWinAgain() {
        guard let draftID = saveDraft(id: nil, text: "committed", cloudSyncState: .synchronized) else {
            return XCTFail("the draft should have been written")
        }
        XCTAssertTrue(autosave(id: draftID, text: "discarded"))

        CreateEntryDraftStore.markCloudSynchronized(id: draftID)

        XCTAssertEqual(CreateEntryCloudMaterialization.decision(for: draftID), .materializeCloud)
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

        StorytopiaLocalAccountScope.setActiveUserID(UUID())
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "a second signed-in account starts blank")

        StorytopiaLocalAccountScope.setActiveUserID(nil)
        XCTAssertNil(UnfinishedCreateSessionStore.draftID, "anonymous mode starts blank")

        StorytopiaLocalAccountScope.setActiveUserID(scopeID)
        XCTAssertEqual(UnfinishedCreateSessionStore.draftID, composeID, "and the owner still has it")
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
