import Foundation
import Supabase
import UIKit

struct SampleStoryPack {
    let id: UUID
    let slug: String
    let version: Int
    let locale: String
    let entries: [CreateEntryDraft]
    let journals: [SampleJournal]
    let storyboardsByEntryID: [UUID: [GeneratedStoryboard]]
}

struct SampleJournal: Identifiable {
    let id: UUID
    let packID: UUID
    let title: String
    let subtitle: String?
    let colorHex: String?
    let symbol: String?
    let coverImageName: String?
    let remoteCover: JournalRemoteCover?
    let kind: String
    let isFavorite: Bool
    let displayOrder: Int
    let entries: [CreateEntryDraft]
    let createdAt: Date
    let updatedAt: Date
}

struct SupabaseSampleStoryService {
    private let client: SupabaseClient
    private let bucketName = "sample-story-assets"
    private let authoringPackSlug = "storytopia-first-run"
    private let authoringPackTitle = "Storytopia First-Run Samples"
    private let authoringLocale = "en"

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func loadActivePack(locale: String = Locale.current.language.languageCode?.identifier ?? "en") async throws -> SampleStoryPack {
        if let pack = try? await loadActivePackFromCloud(locale: locale) {
            SampleStoryPackCache.store(pack)
            return pack
        }

        if let cachedPack = SampleStoryPackCache.load() {
            return cachedPack
        }

        throw SampleStoryServiceError.noSamplePackAvailable
    }

    private func loadActivePackFromCloud(locale: String) async throws -> SampleStoryPack {
        let localizedPack = try await loadPack(locale: locale)
        let fallbackPack = localizedPack == nil && locale != "en"
            ? try await loadPack(locale: "en")
            : nil
        let pack = localizedPack ?? fallbackPack
        guard let pack else {
            throw SampleStoryServiceError.noSamplePackAvailable
        }

        let entryRows = try await loadEntries(packID: pack.id)
        let entryIDs = entryRows.map(\.id)
        let pages = try await loadStoryboardPages(entryIDs: entryIDs)
        let assetsByEntryID = await loadSampleAssets(entryIDs: entryIDs)
        let entries = entryRows.map { $0.draft(assets: assetsByEntryID[$0.id] ?? .empty) }
        let journals = try await loadJournals(packID: pack.id, entries: entries)
        guard !entryRows.isEmpty || !journals.isEmpty else {
            throw SampleStoryServiceError.noSamplePackAvailable
        }

        let storyboardsByEntryID = await loadStoryboards(pages: pages, entries: entryRows)

        return SampleStoryPack(
            id: pack.id,
            slug: pack.slug,
            version: pack.version,
            locale: pack.locale,
            entries: entries,
            journals: journals,
            storyboardsByEntryID: storyboardsByEntryID
        )
    }

    func loadAuthoringPack() async throws -> SampleStoryPack {
        let pack = try await ensureAuthoringPack()
        try await ensureDefaultJournal(packID: pack.id)
        let entryRows = try await loadEntries(packID: pack.id)
        let entryIDs = entryRows.map(\.id)
        let pages = try await loadStoryboardPages(entryIDs: entryIDs)
        let assetsByEntryID = await loadSampleAssets(entryIDs: entryIDs)
        let entries = entryRows.map { $0.draft(assets: assetsByEntryID[$0.id] ?? .empty) }
        let journals = try await loadJournals(packID: pack.id, entries: entries)
        let storyboardsByEntryID = await loadStoryboards(pages: pages, entries: entryRows)

        return SampleStoryPack(
            id: pack.id,
            slug: pack.slug,
            version: pack.version,
            locale: pack.locale,
            entries: entries,
            journals: journals,
            storyboardsByEntryID: storyboardsByEntryID
        )
    }

    func loadActiveSampleEntryIDs(locale: String = Locale.current.language.languageCode?.identifier ?? "en") async throws -> Set<UUID> {
        let localizedPack = try await loadPack(locale: locale)
        let fallbackPack = localizedPack == nil && locale != "en"
            ? try await loadPack(locale: "en")
            : nil
        let pack = localizedPack ?? fallbackPack
        guard let pack else {
            return []
        }

        let entryRows = try await loadEntries(packID: pack.id)
        return Set(entryRows.map(\.id))
    }

    func saveSampleEntry(
        payload: EntryDraftSavePayload,
        status: JournalEntryStatus
    ) async throws -> EntrySaveResult {
        let service = EntrySaveService()
        guard let localDraftID = service.persistLocalDraft(payload, status: status) else {
            throw JournalEntryRepositoryError.operationFailed
        }

        do {
            let pack = try await ensureAuthoringPack()
            try await ensureDefaultJournal(packID: pack.id)
            let displayOrder = try await displayOrderForSampleEntry(id: localDraftID, packID: pack.id)
            let row = SampleEntryUpsert(
                id: localDraftID,
                packID: pack.id,
                title: trimmedOrFallback(payload.title, fallback: "Untitled Sample"),
                bodyText: payload.text,
                richText: payload.richText,
                status: status.rawValue,
                location: trimmedOrNil(payload.location),
                entryDate: payload.datePrecision == .noDate ? nil : payload.date,
                datePrecision: payload.datePrecision.rawValue,
                displayOrder: displayOrder,
                paperStyleRawValue: payload.paperStyleRawValue,
                paperColorIndex: payload.paperColorIndex,
                textColorIndex: payload.textColorIndex,
                textSize: payload.textSize,
                fontChoiceRawValue: payload.fontChoiceRawValue,
                textAlignmentRawValue: payload.textAlignmentRawValue,
                isBold: payload.isBold,
                isItalic: payload.isItalic,
                isUnderlined: payload.isUnderlined,
                isStrikethrough: payload.isStrikethrough,
                isHighlighted: payload.isHighlighted,
                artStyle: trimmedOrNil(payload.artStyle),
                isPrivate: payload.isPrivate,
                onboardingCallouts: []
            )

            try await client
                .from("sample_entries")
                .upsert(row, onConflict: "id")
                .execute()
            let thumbnail = CreateEntryDraftStore.load(id: localDraftID)?.thumbnail
            try await uploadEntryThumbnail(thumbnail, sampleEntryID: localDraftID)
            try await syncSampleJournalMemberships(entryID: localDraftID, packID: pack.id)
            try await syncSampleAssets(entryID: localDraftID, photos: payload.photos, characters: payload.characters)
            SampleStoryPackCache.clear()
            return EntrySaveResult(localDraftID: localDraftID, cloudEntry: nil, state: .saved)
        } catch {
            let message = "Sample cloud save failed: \(error.localizedDescription)"
            print("[Storytopia] \(message)")
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: nil,
                state: .failed("Saved locally. \(message)")
            )
        }
    }

    func prepareSampleEntryForGeneration(
        payload: EntryDraftSavePayload,
        currentStatus: JournalEntryStatus,
        requiresSave: Bool,
        syncReferencePhotos: Bool
    ) async throws -> EntrySaveResult {
        guard requiresSave else {
            guard let localDraftID = payload.id else {
                throw JournalEntryRepositoryError.operationFailed
            }

            return EntrySaveResult(localDraftID: localDraftID, cloudEntry: nil, state: .saved)
        }

        let savePayload = syncReferencePhotos ? payload : payload.withoutMedia()
        return try await saveSampleEntry(
            payload: savePayload,
            status: currentStatus == .completed ? .completed : .draft
        )
    }

    func markSampleEntryCompletedAfterStoryboardSaved(
        payload: EntryDraftSavePayload
    ) async throws -> EntrySaveResult {
        try await saveSampleEntry(payload: payload.withoutMedia(), status: .completed)
    }

    func persistSampleStoryboard(_ storyboard: GeneratedStoryboard) async throws -> GeneratedStoryboard {
        guard let clientEntryID = storyboard.clientEntryID else {
            throw SupabaseStoryboardError.syncFailed
        }

        let pageIndex = try await nextStoryboardPageIndex(for: clientEntryID)
        let storagePath = storyboard.storagePath ?? [
            authoringPackSlug,
            clientEntryID.uuidString.lowercased(),
            "storyboards",
            "\(storyboard.id.uuidString.lowercased()).jpg"
        ].joined(separator: "/")

        guard let imageData = storyboard.image.storytopiaPreparedJPEGData(compressionQuality: 0.9) else {
            throw SupabaseStoryboardError.invalidImage
        }

        try await client.storage
            .from(bucketName)
            .upload(
                storagePath,
                data: imageData,
                options: FileOptions(
                    cacheControl: "31536000",
                    contentType: CreateEntryReferencePhoto.mimeType,
                    upsert: true
                )
            )
        SupabaseStorageImageCache.store(imageData, bucketName: bucketName, storagePath: storagePath)

        let row = SampleStoryboardPageUpsert(
            id: storyboard.id,
            sampleEntryID: clientEntryID,
            storagePath: storagePath,
            pageIndex: pageIndex,
            isPrimary: pageIndex == 0,
            caption: nil,
            artStyle: trimmedOrNil(storyboard.artStyle),
            generationQuality: storyboard.generationQuality?.rawValue,
            panelLayout: storyboard.panelLayout.flatMap(trimmedOrNil)
        )

        try await client
            .from("sample_storyboard_pages")
            .upsert(row, onConflict: "id")
            .execute()

        SampleStoryPackCache.clear()
        return GeneratedStoryboard(
            id: storyboard.id,
            clientEntryID: storyboard.clientEntryID,
            image: storyboard.image,
            promptText: storyboard.promptText,
            artStyle: storyboard.artStyle,
            generationQuality: storyboard.generationQuality,
            panelLayout: storyboard.panelLayout,
            sourcePhotoCount: storyboard.sourcePhotoCount,
            createdAt: storyboard.createdAt,
            imageFileName: storyboard.imageFileName,
            storagePath: storagePath,
            cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
            isPrimary: pageIndex == 0,
            isSampleContent: true
        )
    }

    private func ensureAuthoringPack() async throws -> SampleStoryPackRow {
        if let pack = try await loadPack(slug: authoringPackSlug, locale: authoringLocale) {
            return pack
        }

        let row: SampleStoryPackRow = try await client
            .from("sample_story_packs")
            .insert(
                SampleStoryPackUpsert(
                    id: UUID(),
                    slug: authoringPackSlug,
                    title: authoringPackTitle,
                    version: 1,
                    locale: authoringLocale,
                    isActive: true
                )
            )
            .select()
            .single()
            .execute()
            .value

        return row
    }

    func createSampleJournal(title: String) async throws {
        let pack = try await ensureAuthoringPack()
        let displayOrder = try await nextSampleJournalDisplayOrder(packID: pack.id)
        try await client
            .from("sample_journals")
            .insert(
                SampleJournalUpsert(
                    id: UUID(),
                    packID: pack.id,
                    title: trimmedOrFallback(title, fallback: "Untitled Journal"),
                    subtitle: "Sample journal",
                    colorHex: "#3D2678",
                    symbol: "book.closed.fill",
                    coverImageName: nil,
                    remoteCover: nil,
                    kind: "journal",
                    isFavorite: false,
                    displayOrder: displayOrder
                )
            )
            .execute()
        SampleStoryPackCache.clear()
    }

    func updateSampleJournal(_ journal: SampleJournal) async throws {
        try await client
            .from("sample_journals")
            .upsert(
                SampleJournalUpsert(
                    id: journal.id,
                    packID: journal.packID,
                    title: journal.title,
                    subtitle: journal.subtitle,
                    colorHex: journal.colorHex,
                    symbol: journal.symbol,
                    coverImageName: journal.coverImageName,
                    remoteCover: journal.remoteCover,
                    kind: journal.kind,
                    isFavorite: journal.isFavorite,
                    displayOrder: journal.displayOrder
                ),
                onConflict: "id"
            )
            .execute()
        SampleStoryPackCache.clear()
    }

    func deleteSampleJournal(id: UUID) async throws {
        try await client
            .from("sample_journals")
            .delete()
            .eq("id", value: id)
            .execute()
        SampleStoryPackCache.clear()
    }

    func updateSampleJournalOrder(_ orderedIDs: [UUID]) async throws {
        let pack = try await ensureAuthoringPack()
        let journals = try await loadJournalRows(packID: pack.id)
        let journalsByID = Dictionary(uniqueKeysWithValues: journals.map { ($0.id, $0) })

        for (index, journalID) in orderedIDs.enumerated() {
            guard let journal = journalsByID[journalID] else {
                continue
            }

            try await client
                .from("sample_journals")
                .upsert(
                    SampleJournalUpsert(
                        id: journal.id,
                        packID: journal.packID,
                        title: journal.title,
                        subtitle: journal.subtitle,
                        colorHex: journal.colorHex,
                        symbol: journal.symbol,
                        coverImageName: journal.coverImageName,
                        remoteCover: journal.remoteCover,
                        kind: journal.kind,
                        isFavorite: journal.isFavorite,
                        displayOrder: index
                    ),
                    onConflict: "id"
                )
                .execute()
        }
        SampleStoryPackCache.clear()
    }

    func updateSampleEntryOrder(_ orderedIDs: [UUID]) async throws {
        let pack = try await ensureAuthoringPack()
        let entryRows: [SampleEntryOrderRow] = try await client
            .from("sample_entries")
            .select("id,display_order")
            .eq("pack_id", value: pack.id)
            .execute()
            .value
        let entryIDs = Set(entryRows.map(\.id))

        for (displayOrder, entryID) in orderedIDs.enumerated() where entryIDs.contains(entryID) {
            try await client
                .from("sample_entries")
                .update(SampleEntryDisplayOrderUpdate(displayOrder: displayOrder))
                .eq("id", value: entryID)
                .eq("pack_id", value: pack.id)
                .execute()
        }
        SampleStoryPackCache.clear()
    }

    private func loadPack(locale: String) async throws -> SampleStoryPackRow? {
        let packs: [SampleStoryPackRow] = try await client
            .from("sample_story_packs")
            .select()
            .eq("is_active", value: true)
            .eq("locale", value: locale)
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value

        return packs.first
    }

    private func loadPack(slug: String, locale: String) async throws -> SampleStoryPackRow? {
        let packs: [SampleStoryPackRow] = try await client
            .from("sample_story_packs")
            .select()
            .eq("slug", value: slug)
            .eq("locale", value: locale)
            .order("version", ascending: false)
            .limit(1)
            .execute()
            .value

        return packs.first
    }

    private func loadEntries(packID: UUID) async throws -> [SampleEntryRow] {
        try await client
            .from("sample_entries")
            .select()
            .eq("pack_id", value: packID)
            .order("display_order", ascending: true)
            .execute()
            .value
    }

    private func loadJournals(packID: UUID, entries: [CreateEntryDraft]) async throws -> [SampleJournal] {
        let journalRows = try await loadJournalRows(packID: packID)
        guard !journalRows.isEmpty else {
            return []
        }

        let memberships = try await loadJournalMembershipRows(journalIDs: journalRows.map(\.id))
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let membershipsByJournalID = Dictionary(grouping: memberships, by: \.sampleJournalID)

        return journalRows.map { journal in
            let journalEntries = (membershipsByJournalID[journal.id] ?? [])
                .sorted { $0.position < $1.position }
                .compactMap { entriesByID[$0.sampleEntryID] }

            return SampleJournal(
                id: journal.id,
                packID: journal.packID,
                title: journal.title,
                subtitle: journal.subtitle,
                colorHex: journal.colorHex,
                symbol: journal.symbol,
                coverImageName: journal.coverImageName,
                remoteCover: journal.remoteCover,
                kind: journal.kind,
                isFavorite: journal.isFavorite,
                displayOrder: journal.displayOrder,
                entries: journalEntries,
                createdAt: journal.createdAt,
                updatedAt: journal.updatedAt
            )
        }
    }

    private func loadJournalRows(packID: UUID) async throws -> [SampleJournalRow] {
        try await client
            .from("sample_journals")
            .select()
            .eq("pack_id", value: packID)
            .order("display_order", ascending: true)
            .execute()
            .value
    }

    private func loadJournalMembershipRows(journalIDs: [UUID]) async throws -> [SampleJournalEntryRow] {
        guard !journalIDs.isEmpty else {
            return []
        }

        let values: [any PostgrestFilterValue] = journalIDs.map { $0 as any PostgrestFilterValue }
        return try await client
            .from("sample_journal_entries")
            .select()
            .in("sample_journal_id", values: values)
            .order("position", ascending: true)
            .execute()
            .value
    }

    private func loadStoryboardPages(entryIDs: [UUID]) async throws -> [SampleStoryboardPageRow] {
        guard !entryIDs.isEmpty else {
            return []
        }

        let values: [any PostgrestFilterValue] = entryIDs.map { $0 as any PostgrestFilterValue }
        return try await client
            .from("sample_storyboard_pages")
            .select()
            .in("sample_entry_id", values: values)
            .order("page_index", ascending: true)
            .execute()
            .value
    }

    private func loadSampleAssets(entryIDs: [UUID]) async -> [UUID: SampleEntryLoadedAssets] {
        guard !entryIDs.isEmpty else {
            return [:]
        }

        do {
            let values: [any PostgrestFilterValue] = entryIDs.map { $0 as any PostgrestFilterValue }
            let rows: [SampleEntryAssetRow] = try await client
                .from("sample_entry_assets")
                .select()
                .in("sample_entry_id", values: values)
                .order("sort_order", ascending: true)
                .execute()
                .value

            var assetsByEntryID: [UUID: SampleEntryLoadedAssets] = [:]
            var loadedAssetFingerprints: Set<String> = []
            for row in rows.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let data: Data
                if let cachedData = SupabaseStorageImageCache.data(bucketName: bucketName, storagePath: row.storagePath) {
                    data = cachedData
                } else {
                    data = try await client.storage
                        .from(bucketName)
                        .download(path: row.storagePath)
                    SupabaseStorageImageCache.store(data, bucketName: bucketName, storagePath: row.storagePath)
                }

                guard let image = UIImage(data: data) else {
                    continue
                }

                let assetFingerprint = "\(row.sampleEntryID.uuidString)|\(row.assetType)|\(data.hashValue)"
                guard loadedAssetFingerprints.insert(assetFingerprint).inserted else {
                    continue
                }

                switch row.assetType {
                case "reference_photo":
                    assetsByEntryID[row.sampleEntryID, default: .empty].photos.append(
                        CreateEntryReferencePhoto(id: row.id, image: image)
                    )
                case "character", "character_photo":
                    let characterName = row.caption.flatMap(trimmedOrNil) ?? "Character"
                    assetsByEntryID[row.sampleEntryID, default: .empty].characters.append(
                        EntryCharacter(
                            id: row.id,
                            name: characterName,
                            role: row.characterRole ?? .other,
                            sourcePhotoID: row.sourcePhotoID,
                            image: image,
                            createdAt: row.createdAt,
                            updatedAt: row.updatedAt
                        )
                    )
                default:
                    continue
                }
            }

            return assetsByEntryID.mapValues { assets in
                SampleEntryLoadedAssets(
                    photos: assets.photos,
                    characters: EntryCharacterRules.orderedCharacters(assets.characters)
                )
            }
        } catch {
            print("[Storytopia] Sample entry asset load failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private func loadStoryboards(
        pages: [SampleStoryboardPageRow],
        entries: [SampleEntryRow]
    ) async -> [UUID: [GeneratedStoryboard]] {
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var storyboardsByEntryID: [UUID: [GeneratedStoryboard]] = [:]

        for page in pages {
            guard let entry = entryByID[page.sampleEntryID] else {
                continue
            }

            let data: Data
            if let cachedData = SupabaseStorageImageCache.data(bucketName: bucketName, storagePath: page.storagePath) {
                data = cachedData
            } else {
                do {
                    data = try await client.storage
                        .from(bucketName)
                        .download(path: page.storagePath)
                    SupabaseStorageImageCache.store(data, bucketName: bucketName, storagePath: page.storagePath)
                } catch {
                    continue
                }
            }

            guard let image = UIImage(data: data) else {
                continue
            }

            storyboardsByEntryID[page.sampleEntryID, default: []].append(
                GeneratedStoryboard(
                    id: page.id,
                    clientEntryID: page.sampleEntryID,
                    image: image,
                    promptText: entry.bodyText,
                    artStyle: page.artStyle ?? entry.artStyle ?? "Cozy Storybook",
                    generationQuality: sampleGenerationQuality(from: page.generationQuality),
                    panelLayout: page.panelLayout,
                    sourcePhotoCount: 0,
                    createdAt: page.createdAt,
                    storagePath: page.storagePath,
                    cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                    isPrimary: page.isPrimary || page.pageIndex == 0,
                    isSampleContent: true
                )
            )
        }

        return storyboardsByEntryID.mapValues { storyboards in
            storyboards.sorted { left, right in
                if left.isPrimary != right.isPrimary {
                    return left.isPrimary
                }

                return left.createdAt < right.createdAt
            }
        }
    }

    private func displayOrderForSampleEntry(id: UUID, packID: UUID) async throws -> Int {
        let existingRows: [SampleEntryOrderRow] = try await client
            .from("sample_entries")
            .select("id,display_order")
            .eq("pack_id", value: packID)
            .order("display_order", ascending: false)
            .execute()
            .value

        if let existing = existingRows.first(where: { $0.id == id }) {
            return existing.displayOrder
        }

        return (existingRows.map(\.displayOrder).max() ?? -1) + 1
    }

    private func ensureDefaultJournal(packID: UUID) async throws {
        let existingJournals = try await loadJournalRows(packID: packID)
        guard existingJournals.isEmpty else {
            return
        }

        try await client
            .from("sample_journals")
            .insert(
                SampleJournalUpsert(
                    id: UUID(),
                    packID: packID,
                    title: "Sample Stories",
                    subtitle: "Public onboarding collection",
                    colorHex: "#3D2678",
                    symbol: "sparkles",
                    coverImageName: nil,
                    remoteCover: nil,
                    kind: "journal",
                    isFavorite: true,
                    displayOrder: 0
                )
            )
            .execute()
    }

    private func nextSampleJournalDisplayOrder(packID: UUID) async throws -> Int {
        let journals = try await loadJournalRows(packID: packID)
        return (journals.map(\.displayOrder).max() ?? -1) + 1
    }

    private func syncSampleJournalMemberships(entryID: UUID, packID: UUID) async throws {
        let journalTitles = EntryJournalLinkStore.loadJournalTitles(for: entryID)
        let journalRows = try await loadJournalRows(packID: packID)
        let selectedJournals: [SampleJournalRow]

        if journalTitles.isEmpty {
            selectedJournals = Array(journalRows.prefix(1))
        } else {
            let titleSet = Set(journalTitles)
            selectedJournals = journalRows.filter { titleSet.contains($0.title) }
        }

        for journal in selectedJournals {
            let existingMemberships = try await loadJournalMembershipRows(journalIDs: [journal.id])
            if existingMemberships.contains(where: { $0.sampleEntryID == entryID }) {
                continue
            }

            let nextPosition = (existingMemberships.map(\.position).max() ?? -1) + 1
            try await client
                .from("sample_journal_entries")
                .insert(
                    SampleJournalEntryUpsert(
                        id: UUID(),
                        sampleJournalID: journal.id,
                        sampleEntryID: entryID,
                        position: nextPosition
                    )
                )
                .execute()
        }
    }

    private func nextStoryboardPageIndex(for sampleEntryID: UUID) async throws -> Int {
        let rows: [SampleStoryboardPageIndexRow] = try await client
            .from("sample_storyboard_pages")
            .select("page_index")
            .eq("sample_entry_id", value: sampleEntryID)
            .order("page_index", ascending: false)
            .limit(1)
            .execute()
            .value

        return (rows.first?.pageIndex ?? -1) + 1
    }

    private func uploadEntryThumbnail(_ thumbnail: UIImage?, sampleEntryID: UUID) async throws {
        guard
            let thumbnail,
            let imageData = thumbnail.storytopiaPreparedJPEGData(compressionQuality: 0.85)
        else {
            return
        }

        let storagePath = [
            authoringPackSlug,
            sampleEntryID.uuidString.lowercased(),
            "entry-thumbnail.jpg"
        ].joined(separator: "/")

        try await client.storage
            .from(bucketName)
            .upload(
                storagePath,
                data: imageData,
                options: FileOptions(
                    cacheControl: "31536000",
                    contentType: CreateEntryReferencePhoto.mimeType,
                    upsert: true
                )
            )

        try await client
            .from("sample_entry_assets")
            .upsert(
                SampleEntryAssetUpsert(
                    id: sampleEntryID,
                    sampleEntryID: sampleEntryID,
                    storagePath: storagePath,
                    assetType: "thumbnail",
                    caption: nil,
                    displayOrder: 0,
                    characterRole: nil,
                    sourcePhotoID: nil
                ),
                onConflict: "storage_path"
            )
            .execute()
    }

    private func syncSampleAssets(
        entryID: UUID,
        photos: [CreateEntryReferencePhoto],
        characters: [EntryCharacter]
    ) async throws {
        let photos = deduplicatedSamplePhotos(photos)
        let characters = deduplicatedSampleCharacters(characters)
        let deletedMediaRows = try await deleteExistingSampleMediaRows(entryID: entryID)

        var displayOrder = 1
        var retainedStoragePaths: Set<String> = []

        for photo in photos {
            let storagePath = [
                authoringPackSlug,
                entryID.uuidString.lowercased(),
                "reference-photos",
                "\(photo.id.uuidString.lowercased()).jpg"
            ].joined(separator: "/")
            try await uploadSampleImage(photo.image, storagePath: storagePath)
            try await upsertSampleAsset(
                id: photo.id,
                entryID: entryID,
                storagePath: storagePath,
                assetType: "reference_photo",
                caption: nil,
                displayOrder: displayOrder,
                characterRole: nil,
                sourcePhotoID: nil
            )
            retainedStoragePaths.insert(storagePath)
            displayOrder += 1
        }

        for character in characters {
            let storagePath = [
                authoringPackSlug,
                entryID.uuidString.lowercased(),
                "characters",
                "\(character.id.uuidString.lowercased()).jpg"
            ].joined(separator: "/")
            try await uploadSampleImage(character.image, storagePath: storagePath)
            try await upsertSampleAsset(
                id: character.id,
                entryID: entryID,
                storagePath: storagePath,
                assetType: "character_photo",
                caption: character.name,
                displayOrder: displayOrder,
                characterRole: character.role.rawValue,
                sourcePhotoID: character.sourcePhotoID
            )
            retainedStoragePaths.insert(storagePath)
            displayOrder += 1
        }

        for row in deletedMediaRows where !retainedStoragePaths.contains(row.storagePath) {
            try? await client.storage
                .from(bucketName)
                .remove(paths: [row.storagePath])
        }
    }

    private func deleteExistingSampleMediaRows(entryID: UUID) async throws -> [SampleEntryAssetRow] {
        let deletedRows: [SampleEntryAssetDeleteRow] = try await client
            .rpc(
                "delete_sample_entry_media_assets",
                params: SampleEntryAssetDeletePayload(sampleEntryID: entryID)
            )
            .execute()
            .value
        guard !deletedRows.isEmpty else {
            return []
        }

        let remainingRows = try await loadSampleAssetRows(entryID: entryID)
            .filter { $0.assetType != "thumbnail" }
        guard remainingRows.isEmpty else {
            let remainingDescription = remainingRows.map { row in
                "\(row.id.uuidString) type=\(row.assetType) path=\(row.storagePath)"
            }.joined(separator: ", ")
            print("[Storytopia] Sample asset delete verification failed for entry \(entryID); remaining rows: \(remainingDescription)")
            throw JournalEntryRepositoryError.operationFailed
        }

        for row in deletedRows {
            SupabaseStorageImageCache.remove(bucketName: bucketName, storagePath: row.storagePath)
        }
        return deletedRows.map(\.assetRow)
    }

    private func deduplicatedSamplePhotos(_ photos: [CreateEntryReferencePhoto]) -> [CreateEntryReferencePhoto] {
        var seenFingerprints: Set<Int> = []
        return photos.filter { photo in
            guard let data = photo.image.storytopiaPreparedJPEGData(compressionQuality: 0.9) else {
                return true
            }

            return seenFingerprints.insert(data.hashValue).inserted
        }
    }

    private func deduplicatedSampleCharacters(_ characters: [EntryCharacter]) -> [EntryCharacter] {
        var seenFingerprints: Set<String> = []
        return characters.filter { character in
            guard let data = character.image.storytopiaPreparedJPEGData(compressionQuality: 0.9) else {
                return true
            }

            let fingerprint = "\(character.name)|\(character.role.rawValue)|\(data.hashValue)"
            return seenFingerprints.insert(fingerprint).inserted
        }
    }

    private func uploadSampleImage(_ image: UIImage, storagePath: String) async throws {
        guard let imageData = image.storytopiaPreparedJPEGData(compressionQuality: 0.9) else {
            throw SupabaseStoryboardError.invalidImage
        }

        try await client.storage
            .from(bucketName)
            .upload(
                storagePath,
                data: imageData,
                options: FileOptions(
                    cacheControl: "31536000",
                    contentType: CreateEntryReferencePhoto.mimeType,
                    upsert: true
                )
            )
        SupabaseStorageImageCache.store(imageData, bucketName: bucketName, storagePath: storagePath)
    }

    private func upsertSampleAsset(
        id: UUID,
        entryID: UUID,
        storagePath: String,
        assetType: String,
        caption: String?,
        displayOrder: Int,
        characterRole: String?,
        sourcePhotoID: UUID?
    ) async throws {
        try await client
            .from("sample_entry_assets")
            .upsert(
                SampleEntryAssetUpsert(
                    id: id,
                    sampleEntryID: entryID,
                    storagePath: storagePath,
                    assetType: assetType,
                    caption: caption,
                    displayOrder: displayOrder,
                    characterRole: characterRole,
                    sourcePhotoID: sourcePhotoID
                ),
                onConflict: "storage_path"
            )
            .execute()
    }

    private func loadSampleAssetRows(entryID: UUID) async throws -> [SampleEntryAssetRow] {
        try await client
            .from("sample_entry_assets")
            .select()
            .eq("sample_entry_id", value: entryID)
            .execute()
            .value
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func trimmedOrFallback(_ value: String, fallback: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? fallback : trimmedValue
    }

    private func sampleGenerationQuality(from value: String?) -> OpenAIImageGenerationQuality? {
        guard let value else {
            return nil
        }

        switch value {
        case "standard":
            return .standard
        case "hd":
            return .highDefinition
        default:
            return OpenAIImageGenerationQuality(rawValue: value)
        }
    }
}

private enum SampleStoryServiceError: Error {
    case noSamplePackAvailable
}

private extension EntryDraftSavePayload {
    func withoutMedia() -> EntryDraftSavePayload {
        EntryDraftSavePayload(
            id: id,
            title: title,
            text: text,
            richText: richText,
            photos: [],
            characters: [],
            artStyle: artStyle,
            location: location,
            date: date,
            datePrecision: datePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivate,
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: textAlignmentRawValue
        )
    }
}

private struct SampleStoryPackRow: Codable {
    let id: UUID
    let slug: String
    let title: String
    let version: Int
    let locale: String
    let isActive: Bool
    let createdAt: Date
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case slug
        case title
        case version
        case locale
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct SampleEntryRow: Codable {
    let id: UUID
    let packID: UUID
    let title: String
    let bodyText: String
    let richText: NotebookRichTextDocument?
    let status: String
    let location: String?
    let entryDate: Date?
    let datePrecision: String
    let displayOrder: Int
    let paperStyleRawValue: String?
    let paperColorIndex: Int?
    let textColorIndex: Int?
    let textSize: Double?
    let fontChoiceRawValue: String?
    let textAlignmentRawValue: String?
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let artStyle: String?
    let isPrivate: Bool
    let onboardingCallouts: [SampleStoryCallout]?
    let createdAt: Date
    let updatedAt: Date

    func draft(assets: SampleEntryLoadedAssets = .empty) -> CreateEntryDraft {
        let richTextDocument = richText ?? NotebookRichTextDocument(text: bodyText)
        let resolvedTextAlignment = textAlignmentRawValue ?? "leading"
        let thumbnail = DraftThumbnailRenderer.render(
            title: title,
            text: bodyText,
            richText: richTextDocument,
            photos: assets.photos.map(\.image),
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: resolvedTextAlignment
        )

        return CreateEntryDraft(
            id: id,
            title: title,
            text: bodyText,
            richText: richTextDocument,
            photos: assets.photos,
            characters: assets.characters,
            artStyle: artStyle ?? "Cozy Storybook",
            location: location ?? "",
            date: entryDate ?? createdAt,
            datePrecision: EntryDatePrecision(rawValue: datePrecision) ?? .exact,
            savesDraft: true,
            isPrivate: isPrivate,
            status: status,
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: resolvedTextAlignment,
            thumbnail: thumbnail,
            createdAt: createdAt,
            updatedAt: updatedAt,
            displayOrder: displayOrder
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case title
        case bodyText = "body_text"
        case richText = "rich_text"
        case status
        case location
        case entryDate = "entry_date"
        case datePrecision = "date_precision"
        case displayOrder = "display_order"
        case paperStyleRawValue = "paper_style_raw_value"
        case paperColorIndex = "paper_color_index"
        case textColorIndex = "text_color_index"
        case textSize = "text_size"
        case fontChoiceRawValue = "font_choice_raw_value"
        case textAlignmentRawValue = "text_alignment_raw_value"
        case isBold = "is_bold"
        case isItalic = "is_italic"
        case isUnderlined = "is_underlined"
        case isStrikethrough = "is_strikethrough"
        case isHighlighted = "is_highlighted"
        case artStyle = "art_style"
        case isPrivate = "is_private"
        case onboardingCallouts = "onboarding_callouts"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct SampleStoryboardPageRow: Codable {
    let id: UUID
    let sampleEntryID: UUID
    let storagePath: String
    let pageIndex: Int
    let isPrimary: Bool
    let caption: String?
    let artStyle: String?
    let generationQuality: String?
    let panelLayout: String?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleEntryID = "sample_entry_id"
        case storagePath = "storage_path"
        case pageIndex = "page_index"
        case isPrimary = "is_primary"
        case caption
        case artStyle = "art_style"
        case generationQuality = "generation_quality"
        case panelLayout = "panel_layout"
        case createdAt = "created_at"
    }
}

private struct SampleJournalRow: Codable {
    let id: UUID
    let packID: UUID
    let title: String
    let subtitle: String?
    let colorHex: String?
    let symbol: String?
    let coverImageName: String?
    let remoteCover: JournalRemoteCover?
    let kind: String
    let isFavorite: Bool
    let displayOrder: Int
    let createdAt: Date
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case title
        case subtitle
        case colorHex = "color_hex"
        case symbol
        case coverImageName = "cover_image_name"
        case remoteCover = "remote_cover"
        case kind
        case isFavorite = "is_favorite"
        case displayOrder = "display_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct SampleJournalEntryRow: Codable {
    let id: UUID
    let sampleJournalID: UUID
    let sampleEntryID: UUID
    let position: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleJournalID = "sample_journal_id"
        case sampleEntryID = "sample_entry_id"
        case position
    }
}

private struct SampleEntryLoadedAssets {
    var photos: [CreateEntryReferencePhoto]
    var characters: [EntryCharacter]

    static let empty = SampleEntryLoadedAssets(photos: [], characters: [])
}

private struct SampleEntryAssetRow: Codable {
    let id: UUID
    let sampleEntryID: UUID
    let storagePath: String
    let assetType: String
    let caption: String?
    let sortOrder: Int
    let characterRole: CharacterRole?
    let sourcePhotoID: UUID?
    let createdAt: Date
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleEntryID = "sample_entry_id"
        case storagePath = "storage_path"
        case assetType = "asset_type"
        case caption
        case sortOrder = "sort_order"
        case characterRole = "character_role"
        case sourcePhotoID = "source_photo_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct SampleEntryAssetDeletePayload: Encodable {
    let sampleEntryID: UUID

    private enum CodingKeys: String, CodingKey {
        case sampleEntryID = "p_sample_entry_id"
    }
}

private struct SampleEntryAssetDeleteRow: Codable {
    let id: UUID
    let storagePath: String
    let assetType: String

    var assetRow: SampleEntryAssetRow {
        SampleEntryAssetRow(
            id: id,
            sampleEntryID: UUID(),
            storagePath: storagePath,
            assetType: assetType,
            caption: nil,
            sortOrder: 0,
            characterRole: nil,
            sourcePhotoID: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case assetType = "asset_type"
    }
}

private struct SampleStoryPackUpsert: Encodable {
    let id: UUID
    let slug: String
    let title: String
    let version: Int
    let locale: String
    let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case slug
        case title
        case version
        case locale
        case isActive = "is_active"
    }
}

private struct SampleEntryUpsert: Encodable {
    let id: UUID
    let packID: UUID
    let title: String
    let bodyText: String
    let richText: NotebookRichTextDocument?
    let status: String
    let location: String?
    let entryDate: Date?
    let datePrecision: String
    let displayOrder: Int
    let paperStyleRawValue: String
    let paperColorIndex: Int
    let textColorIndex: Int
    let textSize: Double
    let fontChoiceRawValue: String
    let textAlignmentRawValue: String
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let artStyle: String?
    let isPrivate: Bool
    let onboardingCallouts: [SampleStoryCallout]

    private enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case title
        case bodyText = "body_text"
        case richText = "rich_text"
        case status
        case location
        case entryDate = "entry_date"
        case datePrecision = "date_precision"
        case displayOrder = "display_order"
        case paperStyleRawValue = "paper_style_raw_value"
        case paperColorIndex = "paper_color_index"
        case textColorIndex = "text_color_index"
        case textSize = "text_size"
        case fontChoiceRawValue = "font_choice_raw_value"
        case textAlignmentRawValue = "text_alignment_raw_value"
        case isBold = "is_bold"
        case isItalic = "is_italic"
        case isUnderlined = "is_underlined"
        case isStrikethrough = "is_strikethrough"
        case isHighlighted = "is_highlighted"
        case artStyle = "art_style"
        case isPrivate = "is_private"
        case onboardingCallouts = "onboarding_callouts"
    }
}

private struct SampleStoryboardPageUpsert: Encodable {
    let id: UUID
    let sampleEntryID: UUID
    let storagePath: String
    let pageIndex: Int
    let isPrimary: Bool
    let caption: String?
    let artStyle: String?
    let generationQuality: String?
    let panelLayout: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleEntryID = "sample_entry_id"
        case storagePath = "storage_path"
        case pageIndex = "page_index"
        case isPrimary = "is_primary"
        case caption
        case artStyle = "art_style"
        case generationQuality = "generation_quality"
        case panelLayout = "panel_layout"
    }
}

private struct SampleEntryAssetUpsert: Encodable {
    let id: UUID
    let sampleEntryID: UUID
    let storagePath: String
    let assetType: String
    let caption: String?
    let displayOrder: Int
    let characterRole: String?
    let sourcePhotoID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleEntryID = "sample_entry_id"
        case storagePath = "storage_path"
        case assetType = "asset_type"
        case caption
        case displayOrder = "sort_order"
        case characterRole = "character_role"
        case sourcePhotoID = "source_photo_id"
    }
}

private struct SampleEntryDisplayOrderUpdate: Encodable, Sendable {
    let displayOrder: Int

    private enum CodingKeys: String, CodingKey {
        case displayOrder = "display_order"
    }
}

private struct SampleJournalUpsert: Encodable {
    let id: UUID
    let packID: UUID
    let title: String
    let subtitle: String?
    let colorHex: String?
    let symbol: String?
    let coverImageName: String?
    let remoteCover: JournalRemoteCover?
    let kind: String
    let isFavorite: Bool
    let displayOrder: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case title
        case subtitle
        case colorHex = "color_hex"
        case symbol
        case coverImageName = "cover_image_name"
        case remoteCover = "remote_cover"
        case kind
        case isFavorite = "is_favorite"
        case displayOrder = "display_order"
    }
}

private struct SampleJournalEntryUpsert: Encodable {
    let id: UUID
    let sampleJournalID: UUID
    let sampleEntryID: UUID
    let position: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleJournalID = "sample_journal_id"
        case sampleEntryID = "sample_entry_id"
        case position
    }
}

private struct SampleEntryOrderRow: Codable {
    let id: UUID
    let displayOrder: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case displayOrder = "display_order"
    }
}

private struct SampleStoryboardPageIndexRow: Codable {
    let pageIndex: Int

    private enum CodingKeys: String, CodingKey {
        case pageIndex = "page_index"
    }
}

private struct SampleStoryCallout: Codable {
    let icon: String?
    let text: String
}

private enum SampleStoryPackCache {
    private static let storageKey = "StorytopiaActiveSampleStoryPack"

    static func store(_ pack: SampleStoryPack) {
        let payload = CachedSampleStoryPack(
            id: pack.id,
            slug: pack.slug,
            version: pack.version,
            locale: pack.locale,
            entries: pack.entries.map(CachedSampleEntry.init(entry:)),
            journals: pack.journals.map(CachedSampleJournal.init(journal:)),
            storyboards: pack.storyboardsByEntryID
                .flatMap { entryID, storyboards in
                    storyboards.map { storyboard in
                        CachedSampleStoryboard(
                            id: storyboard.id,
                            clientEntryID: entryID,
                            promptText: storyboard.promptText,
                            artStyle: storyboard.artStyle,
                            generationQuality: storyboard.generationQuality,
                            panelLayout: storyboard.panelLayout,
                            sourcePhotoCount: storyboard.sourcePhotoCount,
                            createdAt: storyboard.createdAt,
                            storagePath: storyboard.storagePath,
                            cloudSyncState: storyboard.cloudSyncState,
                            isPrimary: storyboard.isPrimary
                        )
                    }
                }
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func load() -> SampleStoryPack? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let payload = try? JSONDecoder().decode(CachedSampleStoryPack.self, from: data)
        else {
            return nil
        }

        var storyboardsByEntryID: [UUID: [GeneratedStoryboard]] = [:]
        for cachedStoryboard in payload.storyboards {
            guard
                let storagePath = cachedStoryboard.storagePath,
                let imageData = SupabaseStorageImageCache.data(
                    bucketName: "sample-story-assets",
                    storagePath: storagePath
                ),
                let image = UIImage(data: imageData)
            else {
                continue
            }

            storyboardsByEntryID[cachedStoryboard.clientEntryID, default: []].append(
                GeneratedStoryboard(
                    id: cachedStoryboard.id,
                    clientEntryID: cachedStoryboard.clientEntryID,
                    image: image,
                    promptText: cachedStoryboard.promptText,
                    artStyle: cachedStoryboard.artStyle,
                    generationQuality: cachedStoryboard.generationQuality,
                    panelLayout: cachedStoryboard.panelLayout,
                    sourcePhotoCount: cachedStoryboard.sourcePhotoCount,
                    createdAt: cachedStoryboard.createdAt ?? .distantPast,
                    storagePath: storagePath,
                    cloudSyncState: cachedStoryboard.cloudSyncState,
                    isPrimary: cachedStoryboard.isPrimary,
                    isSampleContent: true
                )
            )
        }

        return SampleStoryPack(
            id: payload.id,
            slug: payload.slug,
            version: payload.version,
            locale: payload.locale,
            entries: payload.entries.map(\.draft),
            journals: (payload.journals ?? []).map { cachedJournal in
                cachedJournal.journal(entries: payload.entries.map(\.draft))
            },
            storyboardsByEntryID: storyboardsByEntryID
        )
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

private struct CachedSampleStoryPack: Codable {
    let id: UUID
    let slug: String
    let version: Int
    let locale: String
    let entries: [CachedSampleEntry]
    let journals: [CachedSampleJournal]?
    let storyboards: [CachedSampleStoryboard]
}

private struct CachedSampleJournal: Codable {
    let id: UUID
    let packID: UUID
    let title: String
    let subtitle: String?
    let colorHex: String?
    let symbol: String?
    let coverImageName: String?
    let remoteCover: JournalRemoteCover?
    let kind: String
    let isFavorite: Bool
    let displayOrder: Int
    let entryIDs: [UUID]
    let createdAt: Date
    let updatedAt: Date

    init(journal: SampleJournal) {
        id = journal.id
        packID = journal.packID
        title = journal.title
        subtitle = journal.subtitle
        colorHex = journal.colorHex
        symbol = journal.symbol
        coverImageName = journal.coverImageName
        remoteCover = journal.remoteCover
        kind = journal.kind
        isFavorite = journal.isFavorite
        displayOrder = journal.displayOrder
        entryIDs = journal.entries.map(\.id)
        createdAt = journal.createdAt
        updatedAt = journal.updatedAt
    }

    func journal(entries: [CreateEntryDraft]) -> SampleJournal {
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return SampleJournal(
            id: id,
            packID: packID,
            title: title,
            subtitle: subtitle,
            colorHex: colorHex,
            symbol: symbol,
            coverImageName: coverImageName,
            remoteCover: remoteCover,
            kind: kind,
            isFavorite: isFavorite,
            displayOrder: displayOrder,
            entries: entryIDs.compactMap { entriesByID[$0] },
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct CachedSampleEntry: Codable {
    let id: UUID
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let artStyle: String
    let location: String
    let date: Date
    let datePrecision: EntryDatePrecision
    let savesDraft: Bool
    let isPrivate: Bool
    let status: String
    let fontChoiceRawValue: String?
    let textColorIndex: Int?
    let textSize: Double?
    let paperStyleRawValue: String?
    let paperColorIndex: Int?
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let textAlignmentRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let displayOrder: Int?

    init(entry: CreateEntryDraft) {
        id = entry.id
        title = entry.title
        text = entry.text
        richText = entry.richText
        artStyle = entry.artStyle
        location = entry.location
        date = entry.date
        datePrecision = entry.datePrecision
        savesDraft = entry.savesDraft
        isPrivate = entry.isPrivate
        status = entry.status
        fontChoiceRawValue = entry.fontChoiceRawValue
        textColorIndex = entry.textColorIndex
        textSize = entry.textSize
        paperStyleRawValue = entry.paperStyleRawValue
        paperColorIndex = entry.paperColorIndex
        isBold = entry.isBold
        isItalic = entry.isItalic
        isUnderlined = entry.isUnderlined
        isStrikethrough = entry.isStrikethrough
        isHighlighted = entry.isHighlighted
        textAlignmentRawValue = entry.textAlignmentRawValue
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        displayOrder = entry.displayOrder
    }

    var draft: CreateEntryDraft {
        let richTextDocument = richText ?? NotebookRichTextDocument(text: text)
        let thumbnail = DraftThumbnailRenderer.render(
            title: title,
            text: text,
            richText: richTextDocument,
            photos: [],
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: textAlignmentRawValue
        )

        return CreateEntryDraft(
            id: id,
            title: title,
            text: text,
            richText: richTextDocument,
            photos: [],
            artStyle: artStyle,
            location: location,
            date: date,
            datePrecision: datePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivate,
            status: status,
            fontChoiceRawValue: fontChoiceRawValue,
            textColorIndex: textColorIndex,
            textSize: textSize,
            paperStyleRawValue: paperStyleRawValue,
            paperColorIndex: paperColorIndex,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignmentRawValue: textAlignmentRawValue,
            thumbnail: thumbnail,
            createdAt: createdAt,
            updatedAt: updatedAt,
            displayOrder: displayOrder
        )
    }
}

private struct CachedSampleStoryboard: Codable {
    let id: UUID
    let clientEntryID: UUID
    let promptText: String
    let artStyle: String
    let generationQuality: OpenAIImageGenerationQuality?
    let panelLayout: String?
    let sourcePhotoCount: Int
    let createdAt: Date?
    let storagePath: String?
    let cloudSyncState: String?
    let isPrimary: Bool
}
