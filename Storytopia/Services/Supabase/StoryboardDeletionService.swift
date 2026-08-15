import Foundation

/// What a pending deletion will cost, so a confirmation can be specific before anything is
/// removed. `entriesReturningToDrafts` counts entries whose last storyboard is being deleted.
struct StoryboardDeletionPreview {
    let storyboardCount: Int
    let affectedEntryCount: Int
    let entriesReturningToDrafts: Int

    var isEmpty: Bool {
        storyboardCount == 0
    }

    var demotesAnyEntry: Bool {
        entriesReturningToDrafts > 0
    }

    static let empty = StoryboardDeletionPreview(
        storyboardCount: 0,
        affectedEntryCount: 0,
        entriesReturningToDrafts: 0
    )
}

/// What a deletion actually did, so every surface can reconcile its own state without
/// re-querying.
struct StoryboardDeletionOutcome {
    var deletedStoryboardIDs: Set<UUID> = []
    var entriesReturnedToDrafts: Set<UUID> = []
    /// Entry id to the storyboard promoted in place of a deleted primary.
    var promotedPrimaries: [UUID: UUID] = [:]

    var isEmpty: Bool {
        deletedStoryboardIDs.isEmpty
    }
}

/// Thrown when at least one entry's storyboards could not be deleted. The partial outcome
/// still has to reach the UI so the surfaces do not keep showing storyboards that are gone.
struct StoryboardDeletionError: LocalizedError {
    let outcome: StoryboardDeletionOutcome
    let failedEntryCount: Int

    var errorDescription: String? {
        if outcome.isEmpty {
            return "Could not delete. Check your connection and try again."
        }

        return "Some storyboards could not be deleted. Check your connection and try again."
    }
}

/// Single owner of the storyboard deletion rules, shared by the entry editor and the profile
/// grid: delete the artwork, promote a new primary when the deleted one was primary, and send
/// an entry back to drafts once its last storyboard is gone.
@MainActor
struct StoryboardDeletionService {
    private let storyboardService: SupabaseStoryboardService
    private let repository: SupabaseEntryRepository

    init(
        storyboardService: SupabaseStoryboardService = SupabaseStoryboardService(),
        repository: SupabaseEntryRepository = SupabaseEntryRepository()
    ) {
        self.storyboardService = storyboardService
        self.repository = repository
    }

    /// Storyboards from the selection that can actually be deleted, grouped by entry.
    static func deletableStoryboardIDsByEntry(_ storyboards: [GeneratedStoryboard]) -> [UUID: Set<UUID>] {
        var grouped: [UUID: Set<UUID>] = [:]

        for storyboard in storyboards {
            guard storyboard.isDeletable, let clientEntryID = storyboard.clientEntryID else {
                continue
            }

            grouped[clientEntryID, default: []].insert(storyboard.id)
        }

        return grouped
    }

    func preview(_ storyboards: [GeneratedStoryboard], isSignedIn: Bool) async -> StoryboardDeletionPreview {
        let grouped = Self.deletableStoryboardIDsByEntry(storyboards)
        guard !grouped.isEmpty else {
            return .empty
        }

        let storyboardCount = grouped.values.reduce(0) { $0 + $1.count }
        let existingIDsByEntry = await existingStoryboardIDsByEntry(
            clientEntryIDs: Set(grouped.keys),
            isSignedIn: isSignedIn
        )

        let entriesReturningToDrafts = grouped.reduce(into: 0) { total, element in
            let (clientEntryID, selectedIDs) = element
            let existingIDs = existingIDsByEntry[clientEntryID] ?? selectedIDs
            if existingIDs.subtracting(selectedIDs).isEmpty {
                total += 1
            }
        }

        return StoryboardDeletionPreview(
            storyboardCount: storyboardCount,
            affectedEntryCount: grouped.count,
            entriesReturningToDrafts: entriesReturningToDrafts
        )
    }

    @discardableResult
    func delete(_ storyboards: [GeneratedStoryboard], isSignedIn: Bool) async throws -> StoryboardDeletionOutcome {
        let grouped = Self.deletableStoryboardIDsByEntry(storyboards)
        guard !grouped.isEmpty else {
            return StoryboardDeletionOutcome()
        }

        var outcome = StoryboardDeletionOutcome()
        var failedEntryCount = 0

        for (clientEntryID, storyboardIDs) in grouped {
            do {
                try await deleteStoryboards(
                    ids: storyboardIDs,
                    clientEntryID: clientEntryID,
                    isSignedIn: isSignedIn,
                    outcome: &outcome
                )
            } catch {
                print("[Storytopia] Storyboard delete failed for entry \(clientEntryID): \(error.localizedDescription)")
                failedEntryCount += 1
            }
        }

        // Announced once, after every entry has its final storyboards and status, so observers
        // never reload against a deleted storyboard whose entry is still marked completed.
        if !outcome.isEmpty {
            NotificationCenter.default.post(name: .storytopiaGeneratedStoryboardsChanged, object: nil)
        }

        guard failedEntryCount == 0 else {
            throw StoryboardDeletionError(outcome: outcome, failedEntryCount: failedEntryCount)
        }

        return outcome
    }

    /// Cloud first, then local: if the cloud delete fails there is nothing to undo locally and
    /// the storyboard stays visible, rather than vanishing and reappearing on the next sync.
    private func deleteStoryboards(
        ids: Set<UUID>,
        clientEntryID: UUID,
        isSignedIn: Bool,
        outcome: inout StoryboardDeletionOutcome
    ) async throws {
        var remaining: [GeneratedStoryboardSummary]

        if isSignedIn {
            let remainingRows = try await storyboardService.deleteStoryboards(
                ids: ids,
                clientEntryID: clientEntryID
            )
            GeneratedStoryboardStore.remove(ids: ids, postsChangeNotification: false)
            remaining = remainingRows.map(GeneratedStoryboardSummary.init)
        } else {
            GeneratedStoryboardStore.remove(ids: ids, postsChangeNotification: false)
            remaining = GeneratedStoryboardStore.summaries(clientEntryID: clientEntryID)
        }

        outcome.deletedStoryboardIDs.formUnion(ids)

        guard let newestRemaining = remaining.max(by: { $0.createdAt < $1.createdAt }) else {
            CreateEntryDraftStore.updateStatus(.draft, for: clientEntryID)
            if isSignedIn {
                try await repository.updateEntryStatus(clientEntryID: clientEntryID, status: .draft)
            }
            outcome.entriesReturnedToDrafts.insert(clientEntryID)
            print("[Storytopia] Entry \(clientEntryID) returned to drafts after its last storyboard was deleted.")
            return
        }

        // A completed entry whose primary was deleted would render with no artwork, so the
        // newest survivor takes over.
        guard !remaining.contains(where: \.isPrimary) else {
            return
        }

        GeneratedStoryboardStore.markPrimary(
            storyboardID: newestRemaining.id,
            clientEntryID: clientEntryID,
            postsChangeNotifications: false
        )

        if isSignedIn {
            try await storyboardService.setPrimaryStoryboard(
                id: newestRemaining.id,
                clientEntryID: clientEntryID
            )
        }

        outcome.promotedPrimaries[clientEntryID] = newestRemaining.id
    }

    private func existingStoryboardIDsByEntry(
        clientEntryIDs: Set<UUID>,
        isSignedIn: Bool
    ) async -> [UUID: Set<UUID>] {
        if isSignedIn {
            do {
                let rows = try await storyboardService.storyboardRows(for: clientEntryIDs)
                return rows.reduce(into: [:]) { result, row in
                    result[row.clientEntryID, default: []].insert(row.id)
                }
            } catch {
                print("[Storytopia] Storyboard deletion preview fell back to local counts: \(error.localizedDescription)")
            }
        }

        return clientEntryIDs.reduce(into: [:]) { result, clientEntryID in
            result[clientEntryID] = Set(
                GeneratedStoryboardStore.summaries(clientEntryID: clientEntryID).map(\.id)
            )
        }
    }
}

private extension GeneratedStoryboardSummary {
    init(_ row: EntryStoryboard) {
        self.init(
            id: row.id,
            clientEntryID: row.clientEntryID,
            createdAt: row.createdAt,
            isPrimary: row.isPrimary,
            isSampleContent: false,
            storagePath: row.storagePath
        )
    }
}
