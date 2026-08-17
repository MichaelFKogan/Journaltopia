import Foundation

/// The signed-out sample pack, held in memory for the length of the session.
///
/// Journals used to make its sample entries browsable by *writing them to disk* — every sample entry
/// went through `CreateEntryDraftStore` and every sample storyboard through
/// `GeneratedStoryboardStore` — because the journal detail screen reads its entries from those two
/// stores and had no other way to find them. Signed out, those stores resolve to the `anonymous`
/// scope, and `CreateEntryDraftStore.migrateLegacyDraftIfNeeded()` and
/// `GeneratedStoryboardStore.migrateLegacyStoryboardsIfNeeded()` merge the anonymous scope into
/// whichever account signs in next. The result was that browsing the samples signed out seeded a
/// copy of the demo pack into the first real account to sign in on the device.
///
/// This is the read path those screens use instead. It is memory only and it is never migrated,
/// which is the entire point: browsing writes nothing, so there is nothing to inherit.
///
/// Sample *authoring* deliberately does not come through here. Those edits are real writes to the
/// sample tables by a signed-in admin, and they still round-trip through the on-disk stores the way
/// they always have.
@MainActor
enum SampleContentStore {
    private(set) static var entriesByID: [UUID: CreateEntryDraft] = [:]
    private(set) static var storyboardsByEntryID: [UUID: [GeneratedStoryboard]] = [:]
    /// Pack order, so `entries(ids:)` can hand back the order the pack author chose rather than a
    /// dictionary's.
    private(set) static var orderedEntryIDs: [UUID] = []

    /// The pack the rest of this store was built from.
    ///
    /// Kept whole because the screens are destroyed and rebuilt on every navigation, and a rebuilt
    /// screen needs the pack's *own* shape — `pack.entries` and `pack.journals` as the author
    /// arranged them — not the flattened lookup above. Reading it is what lets Entries and Journals
    /// come back with content already on screen instead of blanking while the same pack is fetched
    /// again.
    private(set) static var pack: SampleStoryPack?

    static var isEmpty: Bool {
        entriesByID.isEmpty && storyboardsByEntryID.isEmpty
    }

    static func replace(with pack: SampleStoryPack) {
        self.pack = pack

        // Journal entries and top-level pack entries overlap; the journal copy wins because it is
        // the one the journal screens display.
        var entries: [UUID: CreateEntryDraft] = [:]
        var order: [UUID] = []

        for entry in pack.entries + pack.journals.flatMap(\.entries) {
            if entries[entry.id] == nil {
                order.append(entry.id)
            }
            entries[entry.id] = entry
        }

        entriesByID = entries
        orderedEntryIDs = order
        storyboardsByEntryID = pack.storyboardsByEntryID.mapValues { storyboards in
            storyboards.sorted { left, right in
                if left.isPrimary != right.isPrimary {
                    return left.isPrimary
                }

                return left.createdAt < right.createdAt
            }
        }
    }

    static func clear() {
        pack = nil
        entriesByID = [:]
        storyboardsByEntryID = [:]
        orderedEntryIDs = []
    }

    static func entry(id: UUID) -> CreateEntryDraft? {
        entriesByID[id]
    }

    /// The requested entries in pack order. Unknown IDs are skipped rather than faked, so a journal
    /// whose membership points at something the pack no longer carries simply shows fewer entries.
    static func entries(ids: [UUID]) -> [CreateEntryDraft] {
        let requested = Set(ids)
        return orderedEntryIDs
            .filter { requested.contains($0) }
            .compactMap { entriesByID[$0] }
    }

    static func storyboards(clientEntryIDs: Set<UUID>) -> [GeneratedStoryboard] {
        orderedEntryIDs
            .filter { clientEntryIDs.contains($0) }
            .flatMap { storyboardsByEntryID[$0] ?? [] }
    }

    static func storyboards(clientEntryID: UUID) -> [GeneratedStoryboard] {
        storyboardsByEntryID[clientEntryID] ?? []
    }

    static var allStoryboards: [GeneratedStoryboard] {
        orderedEntryIDs.flatMap { storyboardsByEntryID[$0] ?? [] }
    }
}
