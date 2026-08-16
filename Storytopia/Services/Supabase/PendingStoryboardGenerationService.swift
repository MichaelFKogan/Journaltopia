import Combine
import Foundation
import Supabase
import SwiftUI
import UIKit

/// The server owns the lifecycle of a storyboard generation:
///
///     pending -> processing -> completed | failed
///
/// `pending` is written when `generate-storyboard` reserves the row and returns. `processing` is
/// written by the background worker when it actually starts. Only the worker — or the stale-job
/// sweeper that will run on a schedule beside it — may write `failed`, and only the server may
/// refund a reserved credit.
///
/// This file is the client half of that contract, and it is deliberately powerless: it reads rows,
/// adopts the ones that finished, and reports what the row says. It never writes a status, never
/// refunds, and never decides on its own that a slow generation has died. A generation that has sat
/// too long is surfaced as stalled — wording in the UI, nothing more — and stays pending locally
/// until the sweeper resolves it server-side.
///
/// The sweeper (not yet implemented) is expected to: find rows stuck in `pending` or `processing`
/// past their deadline, mark them `failed`, refund the reserved credit idempotently, and record the
/// outcome in `generation_error` and `refunded_credits`. Everything below already reads those
/// columns, so the client needs no change when it lands.

/// What the app has to remember about a generation it fired and did not wait for: which remote row
/// to reconcile, and which entry it belongs to. Everything else — art style, quality, storage path,
/// panel layout, failure reason, refund — is read back from Supabase or from the entry's own local
/// draft at reconcile time, so this record cannot drift out of sync with either.
struct PendingStoryboardGeneration: Codable, Identifiable, Equatable, Sendable {
    /// The `entry_storyboards.id` the function reserved for this generation.
    let id: UUID
    let clientEntryID: UUID
    let requestedAt: Date

    init(id: UUID, clientEntryID: UUID, requestedAt: Date = Date()) {
        self.id = id
        self.clientEntryID = clientEntryID
        self.requestedAt = requestedAt
    }

    var age: TimeInterval {
        Date().timeIntervalSince(requestedAt)
    }
}

/// Pending generations live beside the finished storyboards, in the same account scope, so signing
/// out or switching accounts hides them exactly the way it hides everything else local.
extension GeneratedStoryboardStore {
    private static var pendingGenerationKey: String {
        StorytopiaLocalAccountScope.scopedUserDefaultsKey("StorytopiaPendingStoryboardGenerations")
    }

    static func registerPendingGeneration(_ pendingGeneration: PendingStoryboardGeneration) {
        var updated = pendingGenerations().filter { $0.id != pendingGeneration.id }
        updated.append(pendingGeneration)
        persistPendingGenerations(updated)
    }

    static func pendingGenerations() -> [PendingStoryboardGeneration] {
        guard
            let data = UserDefaults.standard.data(forKey: pendingGenerationKey),
            let records = try? JSONDecoder().decode([PendingStoryboardGeneration].self, from: data)
        else {
            return []
        }

        return records.sorted { $0.requestedAt < $1.requestedAt }
    }

    /// Only ever called once a generation is fully reconciled, or once its row no longer exists.
    static func clearPendingGenerations(ids: Set<UUID>) {
        guard !ids.isEmpty else {
            return
        }

        persistPendingGenerations(pendingGenerations().filter { !ids.contains($0.id) })
    }

    private static func persistPendingGenerations(_ records: [PendingStoryboardGeneration]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: pendingGenerationKey)
    }
}

/// Mirrors the `generation_status` column. Unknown values are treated as `processing`, because an
/// unrecognized status is still the server's business and not a reason for the client to give up.
enum RemoteStoryboardGenerationState: String, Codable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

/// What the server reported about the reserved credit. The client never derives this from a balance
/// comparison: a balance can move for reasons that have nothing to do with this generation.
enum PendingStoryboardCreditRefund: Equatable {
    /// The server recorded a refund of this many credits.
    case refunded(Int)
    /// The server explicitly recorded that nothing was refunded.
    case notRefunded
    /// No refund has been recorded yet. The sweeper may still get to it.
    case unreported
}

struct PendingStoryboardGenerationFailure: Equatable {
    /// The server's own explanation, not a message this client invented.
    let message: String?
    let refund: PendingStoryboardCreditRefund
}

/// Why a generation is still outstanding after a status check.
struct PendingStoryboardGenerationProgress: Equatable {
    /// `nil` when the row has not been observed yet — a just-fired request whose insert this device
    /// has not managed to read back.
    let state: RemoteStoryboardGenerationState?

    /// The generation has taken longer than its stage should. Presentation only: the row is still
    /// the server's to resolve, and this device keeps polling it.
    let isStalled: Bool
}

enum PendingStoryboardGenerationOutcome {
    /// The server still owns this generation. The local record stays.
    case waiting(PendingStoryboardGenerationProgress)
    /// Downloaded, persisted, and applied to local entry state. Safe to forget.
    case completed(GeneratedStoryboard)
    /// The server declared this failed. Safe to forget.
    case failed(PendingStoryboardGenerationFailure)
    /// The row no longer exists — the entry was deleted and took its storyboards with it. There is
    /// nothing left to reconcile and nothing to report.
    case vanished
}

/// Reads the status of generations the app fired and walked away from, and adopts the ones the
/// server finished. Every step is restartable and idempotent: reconciling the same completed
/// generation twice writes the same bytes to the same paths and reaches the same state.
struct PendingStoryboardGenerationService {
    /// A row that has not left `pending` this long probably means the worker never picked the job
    /// up. Used only to word the UI; the row stays the server's to resolve.
    static let pendingStallThreshold: TimeInterval = 90

    /// `processing` past the function's own OpenAI timeout plus upload slack is equally suspect, and
    /// equally not this client's call to make.
    static let processingStallThreshold: TimeInterval = 8 * 60

    /// The row is inserted before the response is sent, so a request this device has a storyboard id
    /// for should have a row within seconds. A short grace period covers replication lag.
    static let missingRowGrace: TimeInterval = 60

    private let client: SupabaseClient
    private let storyboardService: SupabaseStoryboardService
    private let entryRepository: SupabaseEntryRepository

    init(
        client: SupabaseClient = SupabaseService.shared,
        storyboardService: SupabaseStoryboardService = SupabaseStoryboardService(),
        entryRepository: SupabaseEntryRepository = SupabaseEntryRepository()
    ) {
        self.client = client
        self.storyboardService = storyboardService
        self.entryRepository = entryRepository
    }

    /// Resolves every pending generation in one round trip, in the order given. A batch that cannot
    /// be read throws, so the caller retries the whole round rather than mistaking an offline device
    /// for a set of results.
    func outcomes(
        for pendingGenerations: [PendingStoryboardGeneration]
    ) async throws -> [(pending: PendingStoryboardGeneration, outcome: PendingStoryboardGenerationOutcome)] {
        guard !pendingGenerations.isEmpty else {
            return []
        }

        let rowsByID = try await statusRows(ids: pendingGenerations.map(\.id))
        var resolved: [(pending: PendingStoryboardGeneration, outcome: PendingStoryboardGenerationOutcome)] = []

        for pendingGeneration in pendingGenerations {
            let outcome = await self.outcome(for: pendingGeneration, row: rowsByID[pendingGeneration.id])
            resolved.append((pendingGeneration, outcome))
        }

        return resolved
    }

    private func outcome(
        for pendingGeneration: PendingStoryboardGeneration,
        row: PendingStoryboardStatusRow?
    ) async -> PendingStoryboardGenerationOutcome {
        guard let row else {
            guard pendingGeneration.age > Self.missingRowGrace else {
                return .waiting(PendingStoryboardGenerationProgress(state: nil, isStalled: false))
            }

            // Not a failure and not a refund claim — just a row that is not there to reconcile, most
            // often because the entry was deleted and cascaded its storyboards away.
            return .vanished
        }

        switch row.state {
        case .completed:
            return await reconcileCompletedGeneration(pendingGeneration, row: row)
        case .failed:
            return .failed(
                PendingStoryboardGenerationFailure(
                    message: row.generationError,
                    refund: refund(for: row)
                )
            )
        case .pending, .processing:
            return .waiting(
                PendingStoryboardGenerationProgress(
                    state: row.state,
                    isStalled: isStalled(pendingGeneration, state: row.state)
                )
            )
        }
    }

    /// Adopts a finished generation the same way the in-session path does, and in an order that can
    /// be interrupted at any point: the image is cached under the row's own id, the storyboard is
    /// merged by that id, and the entry's status is set to a value it may already hold. Re-running
    /// this after a crash overwrites identical state rather than duplicating anything.
    ///
    /// Any step that does not succeed returns `.waiting`, which keeps the local record alive for the
    /// next poll. The record is only cleared once every step below has come back clean.
    private func reconcileCompletedGeneration(
        _ pendingGeneration: PendingStoryboardGeneration,
        row: PendingStoryboardStatusRow
    ) async -> PendingStoryboardGenerationOutcome {
        guard let storagePath = row.storagePath else {
            // A completed row without a storage path is a server-side contradiction. Wait rather
            // than invent a failure; the sweeper owns rows that never resolve.
            print("[Storytopia] Completed storyboard row has no storage path: \(pendingGeneration.id)")
            return .waiting(PendingStoryboardGenerationProgress(state: .completed, isStalled: true))
        }

        let storyboard: GeneratedStoryboard
        if let alreadyPersisted = locallyPersistedStoryboard(pendingGeneration) {
            // A previous run got this far before being interrupted. The bytes on disk are the same
            // bytes this run would download, so it picks up from the local state instead.
            storyboard = alreadyPersisted
        } else {
            let image: UIImage
            do {
                image = try await storyboardService.downloadStoryboardImage(storagePath: storagePath)
            } catch {
                print("[Storytopia] Pending storyboard download failed: \(pendingGeneration.id) \(error.localizedDescription)")
                return .waiting(
                    PendingStoryboardGenerationProgress(
                        state: .completed,
                        isStalled: pendingGeneration.age > Self.processingStallThreshold
                    )
                )
            }

            do {
                storyboard = try persistStoryboard(image: image, pendingGeneration: pendingGeneration, row: row, storagePath: storagePath)
            } catch {
                print("[Storytopia] Pending storyboard could not be stored locally: \(pendingGeneration.id) \(error.localizedDescription)")
                return .waiting(PendingStoryboardGenerationProgress(state: .completed, isStalled: false))
            }
        }

        guard await markEntryCompleted(clientEntryID: pendingGeneration.clientEntryID) else {
            return .waiting(PendingStoryboardGenerationProgress(state: .completed, isStalled: false))
        }

        return .completed(storyboard)
    }

    /// Writes the image under the storyboard's own id and merges it into the stored set. Both are
    /// keyed by that id, so a repeat run replaces rather than appends.
    private func persistStoryboard(
        image: UIImage,
        pendingGeneration: PendingStoryboardGeneration,
        row: PendingStoryboardStatusRow,
        storagePath: String
    ) throws -> GeneratedStoryboard {
        let draft = CreateEntryDraftStore.load(id: pendingGeneration.clientEntryID)

        let storyboard = try GeneratedStoryboardStore.persistedStoryboard(
            image: image,
            clientEntryID: pendingGeneration.clientEntryID,
            promptText: draft?.text ?? "",
            artStyle: row.artStyle ?? draft?.artStyle ?? "Anime",
            generationQuality: row.generationQuality,
            panelLayout: row.panelLayout,
            sourcePhotoCount: min(
                (draft?.photos.count ?? 0) + (draft?.characters.count ?? 0),
                EntryCharacterRules.maxGenerationImageCount
            ),
            createdAt: row.createdAt ?? pendingGeneration.requestedAt,
            id: pendingGeneration.id,
            storagePath: storagePath,
            cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
            isPrimary: row.isPrimary ?? true
        )

        GeneratedStoryboardStore.save(
            GeneratedStoryboardStore.merging(storyboard, into: GeneratedStoryboardStore.load())
        )

        return storyboard
    }

    /// The storyboard this generation produced, if a previous run already stored it and its image is
    /// still readable. A metadata row whose image file is gone reads as absent, so the next run
    /// downloads it again.
    private func locallyPersistedStoryboard(_ pendingGeneration: PendingStoryboardGeneration) -> GeneratedStoryboard? {
        let isKnown = GeneratedStoryboardStore
            .summaries(clientEntryID: pendingGeneration.clientEntryID)
            .contains { $0.id == pendingGeneration.id }

        guard isKnown else {
            return nil
        }

        return GeneratedStoryboardStore
            .load(clientEntryIDs: [pendingGeneration.clientEntryID])
            .first { $0.id == pendingGeneration.id }
    }

    /// Completion is the last thing the in-session flow does, and it is idempotent on both sides:
    /// the local write skips when the status already matches, and the cloud write sets a value the
    /// row may already hold. Returns false when the cloud write fails, which keeps the generation
    /// pending so the next poll finishes the job.
    private func markEntryCompleted(clientEntryID: UUID) async -> Bool {
        CreateEntryDraftStore.updateStatus(.completed, for: clientEntryID)

        do {
            try await entryRepository.updateEntryStatus(clientEntryID: clientEntryID, status: .completed)
            return true
        } catch {
            print("[Storytopia] Pending storyboard entry completion deferred: \(clientEntryID) \(error.localizedDescription)")
            return false
        }
    }

    private func isStalled(_ pendingGeneration: PendingStoryboardGeneration, state: RemoteStoryboardGenerationState) -> Bool {
        switch state {
        case .pending:
            return pendingGeneration.age > Self.pendingStallThreshold
        case .processing:
            return pendingGeneration.age > Self.processingStallThreshold
        case .completed, .failed:
            return false
        }
    }

    private func refund(for row: PendingStoryboardStatusRow) -> PendingStoryboardCreditRefund {
        guard let refundedCredits = row.refundedCredits else {
            return .unreported
        }

        return refundedCredits > 0 ? .refunded(refundedCredits) : .notRefunded
    }

    private func statusRows(ids: [UUID]) async throws -> [UUID: PendingStoryboardStatusRow] {
        let userID = try await client.auth.session.user.id
        var rowsByID: [UUID: PendingStoryboardStatusRow] = [:]

        for start in stride(from: 0, to: ids.count, by: 80) {
            let chunk = Array(ids[start..<min(start + 80, ids.count)])
            let values: [any PostgrestFilterValue] = chunk.map { $0 as any PostgrestFilterValue }

            // Selected as a whole row rather than by name so the columns the sweeper will write stay
            // optional: a project that has not run the migration yet decodes them as nil.
            let page: [PendingStoryboardStatusRow] = try await client
                .from("entry_storyboards")
                .select()
                .eq("user_id", value: userID)
                .in("id", values: values)
                .execute()
                .value

            for row in page {
                rowsByID[row.id] = row
            }
        }

        return rowsByID
    }
}

/// Only the columns this flow reads. Everything written after the row is inserted is optional,
/// because a row that is still `pending` has not been given those values yet.
private struct PendingStoryboardStatusRow: Decodable {
    let id: UUID
    let generationStatus: String
    let storagePath: String?
    let artStyle: String?
    let generationQuality: OpenAIImageGenerationQuality?
    let panelLayout: String?
    let isPrimary: Bool?
    let createdAt: Date?
    let generationError: String?
    let refundedCredits: Int?

    /// An unrecognized status is read as `processing`: the server has moved the row somewhere this
    /// build does not know about, which is a reason to keep waiting, not to treat it as finished.
    var state: RemoteStoryboardGenerationState {
        RemoteStoryboardGenerationState(rawValue: generationStatus) ?? .processing
    }

    enum CodingKeys: String, CodingKey {
        case id
        case generationStatus = "generation_status"
        case storagePath = "storage_path"
        case artStyle = "art_style"
        case generationQuality = "generation_quality"
        case panelLayout = "panel_layout"
        case isPrimary = "is_primary"
        case createdAt = "created_at"
        case generationError = "generation_error"
        case refundedCredits = "refunded_credits"
    }
}

/// Owns the polling loop and the banner state for generations that outlived the view that started
/// them. Views call `resume()` on launch and on every return to `.active`, and `suspend()` when the
/// app leaves the foreground; nothing else drives it.
@MainActor
final class PendingStoryboardGenerationMonitor: ObservableObject {
    /// Generations this device still has to reconcile. Empty means nothing is outstanding.
    @Published private(set) var pendingGenerations: [PendingStoryboardGeneration] = []

    /// Banner state for a generation the app is watching. A view binds this into the global status
    /// it already shows for in-session generations.
    @Published private(set) var status: StoryboardGenerationGlobalStatus?

    /// The most recent storyboard adopted from a finished row, so a view can fold it into the
    /// storyboards it is already displaying without reloading the whole store.
    @Published private(set) var restoredStoryboard: GeneratedStoryboard?

    /// Generation usually lands inside two minutes, so the first stretch is checked closely and the
    /// tail is checked sparingly. Polling continues for as long as a record exists, because only the
    /// server can end one.
    private let fastPollInterval: TimeInterval = 5
    private let slowPollInterval: TimeInterval = 15
    private let fastPollWindow: TimeInterval = 120

    private let service: PendingStoryboardGenerationService
    private weak var creditStore: GenerationCreditStore?
    private var pollTask: Task<Void, Never>?

    init(service: PendingStoryboardGenerationService = PendingStoryboardGenerationService()) {
        self.service = service
    }

    /// Lets the monitor re-read the balance after the server reports a failure. This is a read: the
    /// refund itself happens server-side, and the row is what says whether it happened.
    func attach(creditStore: GenerationCreditStore) {
        self.creditStore = creditStore
    }

    /// Records a generation the app just fired. The record is written before this returns, so a
    /// termination one instant later still leaves something to resume from.
    func track(_ pendingGeneration: PendingStoryboardGeneration) {
        GeneratedStoryboardStore.registerPendingGeneration(pendingGeneration)
        pendingGenerations = GeneratedStoryboardStore.pendingGenerations()
        status = waitingStatus(
            for: pendingGeneration,
            progress: PendingStoryboardGenerationProgress(state: .pending, isStalled: false),
            isRestored: false
        )
        startPolling()
    }

    /// Called on launch and on every foreground. Reloads what is locally known to be outstanding and
    /// starts checking; a signed-out app has nothing to poll for.
    func resume(isSignedIn: Bool) {
        guard isSignedIn else {
            suspend()
            pendingGenerations = []
            return
        }

        pendingGenerations = GeneratedStoryboardStore.pendingGenerations()

        guard let newest = pendingGenerations.last else {
            suspend()
            return
        }

        // The banner comes back before the first round trip, so a user returning to the app sees the
        // generation still running rather than a blank screen that snaps into a result.
        if status == nil || status?.kind == .running {
            status = waitingStatus(
                for: newest,
                progress: PendingStoryboardGenerationProgress(state: nil, isStalled: false),
                isRestored: true
            )
        }

        startPolling()
    }

    func suspend() {
        pollTask?.cancel()
        pollTask = nil
    }

    func dismissStatus() {
        status = nil
    }

    /// Clears the surfaced storyboard once a view has folded it in, so it is not applied twice.
    func consumeRestoredStoryboard() {
        restoredStoryboard = nil
    }

    private func startPolling() {
        guard pollTask == nil else {
            return
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                let outstanding = self.pendingGenerations
                guard !outstanding.isEmpty else {
                    self.pollTask = nil
                    return
                }

                await self.pollOnce(outstanding)

                guard !Task.isCancelled, !self.pendingGenerations.isEmpty else {
                    self.pollTask = nil
                    return
                }

                let interval = self.pollInterval(for: self.pendingGenerations)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func pollOnce(_ outstanding: [PendingStoryboardGeneration]) async {
        let resolved: [(pending: PendingStoryboardGeneration, outcome: PendingStoryboardGenerationOutcome)]
        do {
            resolved = try await service.outcomes(for: outstanding)
        } catch {
            // An unreadable batch is a connectivity problem, not a result. The records stay put and
            // the next tick tries again.
            print("[Storytopia] Pending storyboard status check failed: \(error.localizedDescription)")
            return
        }

        var reconciledIDs: Set<UUID> = []
        var completions: [GeneratedStoryboard] = []
        var failures: [PendingStoryboardGenerationFailure] = []
        var newestProgress: (pending: PendingStoryboardGeneration, progress: PendingStoryboardGenerationProgress)?

        for (pendingGeneration, outcome) in resolved {
            switch outcome {
            case .waiting(let progress):
                newestProgress = (pendingGeneration, progress)
            case .completed(let storyboard):
                reconciledIDs.insert(pendingGeneration.id)
                completions.append(storyboard)
            case .failed(let failure):
                reconciledIDs.insert(pendingGeneration.id)
                failures.append(failure)
            case .vanished:
                reconciledIDs.insert(pendingGeneration.id)
                print("[Storytopia] Pending storyboard row no longer exists: \(pendingGeneration.id)")
            }
        }

        if !reconciledIDs.isEmpty {
            GeneratedStoryboardStore.clearPendingGenerations(ids: reconciledIDs)
            pendingGenerations = GeneratedStoryboardStore.pendingGenerations()
        }

        if let failure = failures.first {
            await applyFailure(failure)
        }

        if let storyboard = completions.last {
            apply(storyboard)
            return
        }

        // Nothing terminal happened, so the banner tracks whatever is still outstanding — including
        // the wording change when a generation crosses into stalled.
        if failures.isEmpty, let newestProgress, status?.kind != .completed {
            status = waitingStatus(for: newestProgress.pending, progress: newestProgress.progress, isRestored: true)
        }
    }

    private func apply(_ storyboard: GeneratedStoryboard) {
        restoredStoryboard = storyboard

        withAnimation(.snappy(duration: 0.24)) {
            status = StoryboardGenerationGlobalStatus(
                entryID: storyboard.clientEntryID,
                storyboardID: storyboard.id,
                title: "Storyboard ready",
                message: "Finished while you were away. Tap to view.",
                journalTitle: journalTitle(for: storyboard.clientEntryID),
                kind: .completed,
                image: storyboard.image
            )
        }

        NotificationCenter.default.post(name: .storytopiaGeneratedStoryboardsChanged, object: nil)
    }

    private func applyFailure(_ failure: PendingStoryboardGenerationFailure) async {
        // Read-only: the balance on screen is refreshed, but whether the credit came back is
        // answered by the row, not by this refresh.
        if let creditStore {
            await creditStore.refresh(isSignedIn: true)
        }

        let reason = failure.message ?? "Storyboard generation failed."
        let creditNote: String
        switch failure.refund {
        case .refunded(let refundedCredits):
            creditNote = refundedCredits == 1
                ? "Your credit was refunded."
                : "Your \(refundedCredits) credits were refunded."
        case .notRefunded, .unreported:
            creditNote = "Checking your credits."
        }

        withAnimation(.snappy(duration: 0.24)) {
            status = StoryboardGenerationGlobalStatus(
                entryID: status?.entryID,
                title: "Storyboard failed",
                message: "\(reason) \(creditNote)",
                journalTitle: status?.journalTitle,
                kind: .failed
            )
        }
    }

    private func waitingStatus(
        for pendingGeneration: PendingStoryboardGeneration,
        progress: PendingStoryboardGenerationProgress,
        isRestored: Bool
    ) -> StoryboardGenerationGlobalStatus {
        let message: String
        if progress.isStalled {
            message = "This is taking longer than usual. Storytopia is still waiting on the server."
        } else if isRestored {
            message = "Still generating on Storytopia's servers. This keeps running if you leave."
        } else {
            message = "Your storyboard image is still in progress."
        }

        return StoryboardGenerationGlobalStatus(
            id: status?.id ?? UUID(),
            entryID: pendingGeneration.clientEntryID,
            storyboardID: pendingGeneration.id,
            title: "Generating storyboard",
            message: message,
            journalTitle: journalTitle(for: pendingGeneration.clientEntryID),
            kind: .running
        )
    }

    private func journalTitle(for clientEntryID: UUID?) -> String? {
        guard let clientEntryID else {
            return status?.journalTitle
        }

        return EntryJournalLinkStore.loadJournalTitle(for: clientEntryID) ?? status?.journalTitle
    }

    private func pollInterval(for outstanding: [PendingStoryboardGeneration]) -> TimeInterval {
        let youngestAge = outstanding.map(\.age).min() ?? 0
        return youngestAge < fastPollWindow ? fastPollInterval : slowPollInterval
    }
}
