import Foundation
import Supabase
import UIKit

enum EntryCloudSaveState: Equatable {
    case idle
    case saving
    case saved
    case savedLocally
    case uploadingPhotos
    case photosUploaded
    case failed(String)
    case photoUploadFailed(String)

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .saving:
            return "Saving..."
        case .saved:
            return "Saved."
        case .savedLocally:
            return "Saved locally."
        case .uploadingPhotos:
            return "Uploading photos..."
        case .photosUploaded:
            return "Saved."
        case .failed(let message):
            return message
        case .photoUploadFailed(let message):
            return message
        }
    }

    var shouldDismissAutomatically: Bool {
        switch self {
        case .saved, .savedLocally, .photosUploaded:
            return true
        case .idle, .saving, .uploadingPhotos, .failed, .photoUploadFailed:
            return false
        }
    }

    var isConfirmedSave: Bool {
        switch self {
        case .saved, .savedLocally, .photosUploaded:
            return true
        case .idle, .saving, .uploadingPhotos, .failed, .photoUploadFailed:
            return false
        }
    }
}

struct EntryDraftSavePayload {
    let id: UUID?
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let photos: [CreateEntryReferencePhoto]
    let characters: [EntryCharacter]
    let artStyle: String
    let location: String
    let date: Date
    let datePrecision: EntryDatePrecision
    let savesDraft: Bool
    let isPrivate: Bool
    let fontChoiceRawValue: String
    let textColorIndex: Int
    let textSize: Double
    let paperStyleRawValue: String
    let paperColorIndex: Int
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let textAlignmentRawValue: String
}

struct EntrySaveResult {
    let localDraftID: UUID
    let cloudEntry: JournalEntry?
    let state: EntryCloudSaveState
}

enum StoryboardCloudSyncState: String {
    case pending
    case synced
    case failed
}

struct EntryStoryboard: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let clientEntryID: UUID
    let storagePath: String
    let createdAt: Date
    let updatedAt: Date
    let artStyle: String?
    let generationQuality: OpenAIImageGenerationQuality?
    let panelLayout: String?
    let prompt: String?
    let isPrimary: Bool
    let generationStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case clientEntryID = "client_entry_id"
        case storagePath = "storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case artStyle = "art_style"
        case generationQuality = "generation_quality"
        case panelLayout = "panel_layout"
        case prompt
        case isPrimary = "is_primary"
        case generationStatus = "generation_status"
    }
}

private struct EntryStoryboardPayload: Encodable, Sendable {
    let id: UUID
    let userID: UUID
    let clientEntryID: UUID
    let storagePath: String
    let artStyle: String?
    let generationQuality: OpenAIImageGenerationQuality?
    let panelLayout: String?
    let prompt: String?
    let isPrimary: Bool
    let generationStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case clientEntryID = "client_entry_id"
        case storagePath = "storage_path"
        case artStyle = "art_style"
        case generationQuality = "generation_quality"
        case panelLayout = "panel_layout"
        case prompt
        case isPrimary = "is_primary"
        case generationStatus = "generation_status"
    }
}

private struct EntryStoryboardPrimaryUpdate: Encodable, Sendable {
    let isPrimary: Bool

    enum CodingKeys: String, CodingKey {
        case isPrimary = "is_primary"
    }
}

private struct CompletedEntryReference: Decodable, Sendable {
    let clientEntryID: UUID

    enum CodingKeys: String, CodingKey {
        case clientEntryID = "client_entry_id"
    }
}

enum SupabaseStoryboardError: LocalizedError {
    case invalidImage
    case notAuthenticated
    case syncFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The generated storyboard could not be prepared for upload."
        case .notAuthenticated:
            return "Sign in before saving a storyboard to Storytopia cloud."
        case .syncFailed:
            return "Storyboard cloud sync failed. Please try again."
        case .downloadFailed:
            return "Could not download this storyboard."
        }
    }
}

enum SupabaseEntryThumbnailError: LocalizedError {
    case invalidImage
    case syncFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The entry thumbnail could not be prepared for upload."
        case .syncFailed:
            return "Entry thumbnail sync failed. Please try again."
        case .downloadFailed:
            return "Could not download this entry thumbnail."
        }
    }
}

struct SupabaseEntryThumbnailService {
    private let client: SupabaseClient
    private let repository: SupabaseEntryRepository
    private let bucketName = "storytopia-media"

    init(
        client: SupabaseClient = SupabaseService.shared,
        repository: SupabaseEntryRepository = SupabaseEntryRepository()
    ) {
        self.client = client
        self.repository = repository
    }

    func uploadThumbnail(_ image: UIImage, for entry: JournalEntry) async throws -> JournalEntry {
        guard let data = image.storytopiaPreparedJPEGData(compressionQuality: 0.86) else {
            throw SupabaseEntryThumbnailError.invalidImage
        }

        let storagePath = Self.storagePath(userID: entry.userID, clientEntryID: entry.clientEntryID)

        do {
            try await client.storage
                .from(bucketName)
                .upload(
                    storagePath,
                    data: data,
                    options: FileOptions(
                        cacheControl: "31536000",
                        contentType: CreateEntryReferencePhoto.mimeType,
                        upsert: true
                    )
                )
            SupabaseStorageImageCache.store(data, bucketName: bucketName, storagePath: storagePath)
            return try await repository.updateEntryThumbnail(
                clientEntryID: entry.clientEntryID,
                storagePath: storagePath,
                updatedAt: Date()
            )
        } catch let error as SupabaseEntryThumbnailError {
            throw error
        } catch {
            throw SupabaseEntryThumbnailError.syncFailed
        }
    }

    func downloadThumbnail(storagePath: String, bypassCache: Bool = false) async throws -> UIImage {
        do {
            let data: Data
            if !bypassCache, let cachedData = SupabaseStorageImageCache.data(bucketName: bucketName, storagePath: storagePath) {
                data = cachedData
            } else {
                data = try await client.storage
                    .from(bucketName)
                    .download(path: storagePath)
                SupabaseStorageImageCache.store(data, bucketName: bucketName, storagePath: storagePath)
            }

            guard let image = UIImage(data: data) else {
                throw SupabaseEntryThumbnailError.downloadFailed
            }
            return image
        } catch let error as SupabaseEntryThumbnailError {
            throw error
        } catch {
            throw SupabaseEntryThumbnailError.downloadFailed
        }
    }

    func deleteThumbnail(storagePath: String?) async {
        guard let storagePath else {
            return
        }

        do {
            try await client.storage
                .from(bucketName)
                .remove(paths: [storagePath])
        } catch {
            print("[Storytopia] Entry thumbnail delete skipped: \(error.localizedDescription)")
        }
    }

    static func storagePath(userID: UUID, clientEntryID: UUID) -> String {
        [
            userID.uuidString.lowercased(),
            "entries",
            clientEntryID.uuidString.lowercased(),
            "preview-thumbnail.jpg"
        ].joined(separator: "/")
    }
}

struct SupabaseStoryboardService {
    private let client: SupabaseClient
    private let bucketName = "generated-storyboards"

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func persistPrimaryStoryboard(_ storyboard: GeneratedStoryboard) async throws -> EntryStoryboard {
        guard let clientEntryID = storyboard.clientEntryID else {
            throw SupabaseStoryboardError.syncFailed
        }

        let userID = try await authenticatedUserID()
        let storagePath = storyboard.storagePath ?? [
            userID.uuidString.lowercased(),
            clientEntryID.uuidString.lowercased(),
            "\(storyboard.id.uuidString.lowercased()).jpg"
        ].joined(separator: "/")

        guard let imageData = storyboard.image.storytopiaPreparedJPEGData(compressionQuality: 0.9) else {
            throw SupabaseStoryboardError.invalidImage
        }

        print("[Storytopia] Cloud storyboard upload started.")
        do {
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
            print("[Storytopia] Storage upload succeeded.")

            try await markPriorStoryboardsNonPrimary(
                userID: userID,
                clientEntryID: clientEntryID,
                excluding: storyboard.id
            )

            print("[Storytopia] Storyboard metadata insert started.")
            let row: EntryStoryboard = try await client
                .from("entry_storyboards")
                .upsert(
                    EntryStoryboardPayload(
                        id: storyboard.id,
                        userID: userID,
                        clientEntryID: clientEntryID,
                        storagePath: storagePath,
                        artStyle: trimmedOrNil(storyboard.artStyle),
                        generationQuality: storyboard.generationQuality,
                        panelLayout: storyboard.panelLayout.flatMap { trimmedOrNil($0) },
                        prompt: nil,
                        isPrimary: true,
                        generationStatus: "completed"
                    ),
                    onConflict: "id"
                )
                .select()
                .single()
                .execute()
                .value
            print("[Storytopia] Storyboard metadata insert succeeded.")
            return row
        } catch let error as SupabaseStoryboardError {
            print("[Storytopia] Storyboard cloud sync failed: \(error.localizedDescription)")
            throw error
        } catch {
            print("[Storytopia] Storyboard cloud sync failed: \(error.localizedDescription)")
            throw SupabaseStoryboardError.syncFailed
        }
    }

    func setPrimaryStoryboard(_ storyboard: GeneratedStoryboard) async throws {
        guard let clientEntryID = storyboard.clientEntryID else {
            throw SupabaseStoryboardError.syncFailed
        }

        let userID = try await authenticatedUserID()

        do {
            try await markPriorStoryboardsNonPrimary(
                userID: userID,
                clientEntryID: clientEntryID,
                excluding: storyboard.id
            )

            try await client
                .from("entry_storyboards")
                .update(EntryStoryboardPrimaryUpdate(isPrimary: true))
                .eq("user_id", value: userID)
                .eq("client_entry_id", value: clientEntryID)
                .eq("id", value: storyboard.id)
                .execute()
            print("[Storytopia] Primary storyboard selection updated.")
        } catch let error as SupabaseStoryboardError {
            throw error
        } catch {
            print("[Storytopia] Primary storyboard update failed: \(error.localizedDescription)")
            throw SupabaseStoryboardError.syncFailed
        }
    }

    func loadStoryboards() async throws -> [EntryStoryboard] {
        do {
            return try await client
                .from("entry_storyboards")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw SupabaseStoryboardError.syncFailed
        }
    }

    func loadPrimaryCompletedStoryboards() async throws -> [EntryStoryboard] {
        do {
            return try await client
                .from("entry_storyboards")
                .select("id,user_id,client_entry_id,storage_path,created_at,updated_at,art_style,generation_quality,panel_layout,prompt,is_primary,generation_status")
                .eq("is_primary", value: true)
                .eq("generation_status", value: "completed")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw SupabaseStoryboardError.syncFailed
        }
    }

    func loadCompletedJournalStoryboards(limit: Int = 9, offset: Int = 0) async throws -> [EntryStoryboard] {
        do {
            let completedEntries: [CompletedEntryReference] = try await client
                .from("entries")
                .select("client_entry_id")
                .eq("status", value: JournalEntryStatus.completed.rawValue)
                .order("created_at", ascending: false)
                .execute()
                .value

            let completedClientEntryIDs = Set(completedEntries.map(\.clientEntryID))

            guard !completedClientEntryIDs.isEmpty else {
                return []
            }

            let rows = try await loadStoryboards()

            return Array(
                rows
                    .filter {
                        completedClientEntryIDs.contains($0.clientEntryID)
                            && $0.generationStatus == "completed"
                    }
                    .sorted { $0.createdAt > $1.createdAt }
                    .dropFirst(offset)
                    .prefix(limit)
            )
        } catch {
            print("[Storytopia] Completed profile storyboards metadata load failed: \(error.localizedDescription)")
            throw SupabaseStoryboardError.syncFailed
        }
    }

    func loadCompletedJournalStoryboardImages(limit: Int = 9, offset: Int = 0) async throws -> [GeneratedStoryboard] {
        let rows = try await loadCompletedJournalStoryboards(limit: limit, offset: offset)
        return await downloadStoryboardImages(from: rows)
    }

    func loadStoryboardImages(for clientEntryIDs: Set<UUID>) async throws -> [GeneratedStoryboard] {
        guard !clientEntryIDs.isEmpty else {
            return []
        }

        let rows = try await loadCompletedStoryboardRows(for: clientEntryIDs)

        return await downloadStoryboardImages(from: rows)
    }

    func loadCompletedStoryboardRows(for clientEntryIDs: Set<UUID>) async throws -> [EntryStoryboard] {
        guard !clientEntryIDs.isEmpty else {
            return []
        }

        return try await loadStoryboardRows(for: clientEntryIDs)
            .filter { $0.generationStatus == JournalEntryStatus.completed.rawValue }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func downloadStoryboards(from rows: [EntryStoryboard]) async -> [GeneratedStoryboard] {
        await downloadStoryboardImages(from: rows)
    }

    /// Loads journal-detail card assets: metadata for all matching storyboards, full images
    /// persisted for primaries, and downsampled card images for UI cells.
    func loadJournalDetailStoryboardCards(
        for clientEntryIDs: Set<UUID>,
        cardMaxDimension: CGFloat = 640
    ) async throws -> (cardImages: [GeneratedStoryboard], countsByClientEntryID: [UUID: Int]) {
        guard !clientEntryIDs.isEmpty else {
            return ([], [:])
        }

        let rows = try await loadStoryboardRows(for: clientEntryIDs)
            .filter { $0.generationStatus == JournalEntryStatus.completed.rawValue }
            .sorted { $0.createdAt > $1.createdAt }

        var countsByClientEntryID: [UUID: Int] = [:]
        for row in rows {
            countsByClientEntryID[row.clientEntryID, default: 0] += 1
        }

        var primaryRowsByClientEntryID: [UUID: EntryStoryboard] = [:]
        for row in rows {
            if row.isPrimary {
                primaryRowsByClientEntryID[row.clientEntryID] = row
            } else if primaryRowsByClientEntryID[row.clientEntryID] == nil {
                primaryRowsByClientEntryID[row.clientEntryID] = row
            }
        }

        let primaryRows = Array(primaryRowsByClientEntryID.values).sorted { $0.createdAt > $1.createdAt }
        var cardImages: [GeneratedStoryboard] = []
        var persistedBatch: [GeneratedStoryboard] = []

        for row in primaryRows {
            do {
                let fullImage = try await downloadStoryboardImage(storagePath: row.storagePath)
                let fullStoryboard = GeneratedStoryboard(
                    id: row.id,
                    clientEntryID: row.clientEntryID,
                    image: fullImage,
                    promptText: row.prompt ?? "",
                    artStyle: row.artStyle ?? "Anime",
                    generationQuality: row.generationQuality,
                    panelLayout: row.panelLayout,
                    sourcePhotoCount: 0,
                    createdAt: row.createdAt,
                    storagePath: row.storagePath,
                    cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                    isPrimary: row.isPrimary
                )
                persistedBatch.append(fullStoryboard)

                let cardImage = fullImage.storytopiaDownsampled(maxDimension: cardMaxDimension)
                cardImages.append(
                    GeneratedStoryboard(
                        id: row.id,
                        clientEntryID: row.clientEntryID,
                        image: cardImage,
                        promptText: row.prompt ?? "",
                        artStyle: row.artStyle ?? "Anime",
                        generationQuality: row.generationQuality,
                        panelLayout: row.panelLayout,
                        sourcePhotoCount: 0,
                        createdAt: row.createdAt,
                        storagePath: row.storagePath,
                        cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                        isPrimary: row.isPrimary
                    )
                )
            } catch {
                print("[Storytopia] Journal detail storyboard card download skipped: \(row.id) \(error.localizedDescription)")
            }
        }

        if !persistedBatch.isEmpty {
            let cached = GeneratedStoryboardStore.cachedStoryboards(persistedBatch)
            var persisted = GeneratedStoryboardStore.load()
            for storyboard in cached {
                persisted = GeneratedStoryboardStore.merging(storyboard, into: persisted)
            }
            GeneratedStoryboardStore.save(persisted)
        }

        return (cardImages, countsByClientEntryID)
    }

    private func loadStoryboardRows(for clientEntryIDs: Set<UUID>) async throws -> [EntryStoryboard] {
        guard !clientEntryIDs.isEmpty else {
            return []
        }

        let userID = try await authenticatedUserID()
        var aggregated: [EntryStoryboard] = []
        var seen = Set<UUID>()
        let orderedIDs = Array(clientEntryIDs)

        for start in stride(from: 0, to: orderedIDs.count, by: 80) {
            let chunk = Array(orderedIDs[start..<min(start + 80, orderedIDs.count)])
            let values: [any PostgrestFilterValue] = chunk.map { $0 as any PostgrestFilterValue }
            let page: [EntryStoryboard] = try await client
                .from("entry_storyboards")
                .select()
                .eq("user_id", value: userID)
                .in("client_entry_id", values: values)
                .order("created_at", ascending: false)
                .execute()
                .value

            for row in page where seen.insert(row.id).inserted {
                aggregated.append(row)
            }
        }

        return aggregated
    }

    private func downloadStoryboardImages(from rows: [EntryStoryboard]) async -> [GeneratedStoryboard] {
        var storyboards: [GeneratedStoryboard] = []

        for row in rows {
            do {
                let image = try await downloadStoryboardImage(storagePath: row.storagePath)
                storyboards.append(
                    GeneratedStoryboard(
                        id: row.id,
                        clientEntryID: row.clientEntryID,
                        image: image,
                        promptText: row.prompt ?? "",
                        artStyle: row.artStyle ?? "Anime",
                        generationQuality: row.generationQuality,
                        panelLayout: row.panelLayout,
                        sourcePhotoCount: 0,
                        createdAt: row.createdAt,
                        storagePath: row.storagePath,
                        cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                        isPrimary: row.isPrimary
                    )
                )
            } catch {
                print("[Storytopia] Profile storyboard image download skipped: \(row.id) \(error.localizedDescription)")
            }
        }

        return storyboards
    }

    func downloadStoryboardImage(storagePath: String) async throws -> UIImage {
        do {
            let data: Data
            if let cachedData = SupabaseStorageImageCache.data(bucketName: bucketName, storagePath: storagePath) {
                data = cachedData
            } else {
                print("[Storytopia] Cloud image download/cache miss.")
                data = try await client.storage
                    .from(bucketName)
                    .download(path: storagePath)
                SupabaseStorageImageCache.store(data, bucketName: bucketName, storagePath: storagePath)
            }
            guard let image = UIImage(data: data) else {
                throw SupabaseStoryboardError.downloadFailed
            }
            return image
        } catch let error as SupabaseStoryboardError {
            throw error
        } catch {
            throw SupabaseStoryboardError.downloadFailed
        }
    }

    private func markPriorStoryboardsNonPrimary(
        userID: UUID,
        clientEntryID: UUID,
        excluding storyboardID: UUID
    ) async throws {
        try await client
            .from("entry_storyboards")
            .update(EntryStoryboardPrimaryUpdate(isPrimary: false))
            .eq("user_id", value: userID)
            .eq("client_entry_id", value: clientEntryID)
            .eq("is_primary", value: true)
            .neq("id", value: storyboardID)
            .execute()
        print("[Storytopia] Prior primary versions updated.")
    }

    private func authenticatedUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw SupabaseStoryboardError.notAuthenticated
        }
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

@MainActor
struct EntrySaveService {
    private let repository: SupabaseEntryRepository
    private let journalRepository: SupabaseJournalRepository
    private let referencePhotoService: SupabaseReferencePhotoService
    private let characterService: SupabaseEntryCharacterService
    private let thumbnailService: SupabaseEntryThumbnailService

    init(
        repository: SupabaseEntryRepository = SupabaseEntryRepository(),
        journalRepository: SupabaseJournalRepository = SupabaseJournalRepository(),
        referencePhotoService: SupabaseReferencePhotoService = SupabaseReferencePhotoService(),
        characterService: SupabaseEntryCharacterService = SupabaseEntryCharacterService(),
        thumbnailService: SupabaseEntryThumbnailService = SupabaseEntryThumbnailService()
    ) {
        self.repository = repository
        self.journalRepository = journalRepository
        self.referencePhotoService = referencePhotoService
        self.characterService = characterService
        self.thumbnailService = thumbnailService
    }

    func saveEntryPreservingStatus(
        payload: EntryDraftSavePayload,
        isSignedIn: Bool,
        status: JournalEntryStatus = .draft,
        syncReferencePhotos: Bool = true
    ) async throws -> EntrySaveResult {
        guard let localDraftID = persistLocalDraft(payload, status: status) else {
            throw JournalEntryRepositoryError.operationFailed
        }

        if status == .completed {
            print("[Storytopia] Local entry marked completed.")
        }

        EntryLocationRecentStore.add(payload.location)
        let hasLocation = !payload.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cloudEntryDate = payload.datePrecision == .noDate ? nil : payload.date

        guard isSignedIn else {
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: nil,
                state: .savedLocally
            )
        }

        if status == .completed {
            print("[Storytopia] Supabase status update started.")
        }
        print("[Storytopia] Supabase entry save payload hasLocation=\(hasLocation), datePrecision=\(payload.datePrecision.rawValue), sendsEntryDate=\(cloudEntryDate != nil).")

        var cloudEntry: JournalEntry
        do {
            cloudEntry = try await repository.upsertEntry(
                clientEntryID: localDraftID,
                title: payload.title,
                content: payload.text,
                richText: payload.richText,
                artStyle: payload.artStyle,
                location: payload.location,
                entryDate: cloudEntryDate,
                datePrecision: payload.datePrecision,
                savesDraft: payload.savesDraft,
                isPrivate: payload.isPrivate,
                fontChoiceRawValue: payload.fontChoiceRawValue,
                textColorIndex: payload.textColorIndex,
                textSize: payload.textSize,
                paperStyleRawValue: payload.paperStyleRawValue,
                paperColorIndex: payload.paperColorIndex,
                isBold: payload.isBold,
                isItalic: payload.isItalic,
                isUnderlined: payload.isUnderlined,
                isStrikethrough: payload.isStrikethrough,
                isHighlighted: payload.isHighlighted,
                textAlignmentRawValue: payload.textAlignmentRawValue,
                status: status
            )
        } catch {
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: nil,
                state: .failed("Saved locally. Cloud save failed.")
            )
        }

        if let thumbnail = CreateEntryDraftStore.load(id: localDraftID)?.thumbnail {
            do {
                cloudEntry = try await thumbnailService.uploadThumbnail(thumbnail, for: cloudEntry)
            } catch {
                print("[Storytopia] Entry thumbnail sync failed: \(error.localizedDescription)")
            }
        }

        do {
            try await syncJournalMemberships(for: localDraftID)
        } catch {
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: cloudEntry,
                state: .failed("Saved locally. Journal sync failed.")
            )
        }

        guard syncReferencePhotos else {
            print("[Storytopia] Reference photos unchanged, sync skipped.")
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: cloudEntry,
                state: .saved
            )
        }

        do {
            try await referencePhotoService.syncReferencePhotos(entry: cloudEntry, photos: payload.photos)
            try await characterService.syncCharacters(entry: cloudEntry, characters: payload.characters)

            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: cloudEntry,
                state: payload.photos.isEmpty && payload.characters.isEmpty ? .saved : .photosUploaded
            )
        } catch {
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: cloudEntry,
                state: .photoUploadFailed("Saved locally. Media sync failed.")
            )
        }
    }

    func prepareEntryForGeneration(
        payload: EntryDraftSavePayload,
        isSignedIn: Bool,
        currentStatus: JournalEntryStatus,
        requiresSave: Bool,
        syncReferencePhotos: Bool
    ) async throws -> EntrySaveResult {
        print("[Storytopia] Generation preparation started.")

        guard requiresSave else {
            guard let localDraftID = payload.id else {
                throw JournalEntryRepositoryError.operationFailed
            }

            print("[Storytopia] Entry was clean, cloud save skipped.")
            print("[Storytopia] Reference photos unchanged, sync skipped.")
            return EntrySaveResult(
                localDraftID: localDraftID,
                cloudEntry: nil,
                state: .saved
            )
        }

        print("[Storytopia] Entry was dirty, cloud save started.")
        return try await saveEntryPreservingStatus(
            payload: payload,
            isSignedIn: isSignedIn,
            status: currentStatus == .completed ? .completed : .draft,
            syncReferencePhotos: syncReferencePhotos
        )
    }

    func markEntryCompletedAfterStoryboardSaved(
        payload: EntryDraftSavePayload,
        isSignedIn: Bool
    ) async throws -> EntrySaveResult {
        let result = try await saveEntryPreservingStatus(
            payload: payload,
            isSignedIn: isSignedIn,
            status: .completed,
            syncReferencePhotos: false
        )
        if case .failed = result.state {
            print("[Storytopia] Supabase status update failed.")
        } else if isSignedIn {
            print("[Storytopia] Supabase status update succeeded.")
        }
        return result
    }

    func renameEntry(
        entry: CreateEntryDraft,
        title: String,
        status: JournalEntryStatus,
        isSignedIn: Bool
    ) async throws -> JournalEntry? {
        guard isSignedIn else {
            return nil
        }

        let cloudEntry = try await repository.upsertEntry(
            clientEntryID: entry.id,
            title: title,
            content: entry.text,
            richText: entry.richText,
            artStyle: entry.artStyle,
            location: entry.location,
            entryDate: entry.datePrecision == .noDate ? nil : entry.date,
            datePrecision: entry.datePrecision,
            savesDraft: entry.savesDraft,
            isPrivate: entry.isPrivate,
            fontChoiceRawValue: entry.fontChoiceRawValue,
            textColorIndex: entry.textColorIndex,
            textSize: entry.textSize,
            paperStyleRawValue: entry.paperStyleRawValue,
            paperColorIndex: entry.paperColorIndex,
            isBold: entry.isBold,
            isItalic: entry.isItalic,
            isUnderlined: entry.isUnderlined,
            isStrikethrough: entry.isStrikethrough,
            isHighlighted: entry.isHighlighted,
            textAlignmentRawValue: entry.textAlignmentRawValue,
            status: status
        )

        guard let thumbnail = entry.thumbnail else {
            return cloudEntry
        }

        do {
            return try await thumbnailService.uploadThumbnail(thumbnail, for: cloudEntry)
        } catch {
            print("[Storytopia] Entry thumbnail sync failed: \(error.localizedDescription)")
            return cloudEntry
        }
    }

    func deleteEntry(localDraftID: UUID, cloudEntry: JournalEntry?, isSignedIn: Bool) async throws {
        guard let cloudEntry else {
            if isSignedIn {
                try await journalRepository.deleteJournalEntryMemberships(clientEntryID: localDraftID)
                try await referencePhotoService.deleteReferencePhotos(clientEntryID: localDraftID)
                try await characterService.deleteCharacters(clientEntryID: localDraftID)
                try await repository.deleteEntry(clientEntryID: localDraftID)
            }

            CreateEntryDraftStore.delete(id: localDraftID)
            return
        }

        guard isSignedIn else {
            throw JournalEntryRepositoryError.notAuthenticated
        }

        await thumbnailService.deleteThumbnail(storagePath: cloudEntry.thumbnailStoragePath)
        try await referencePhotoService.deleteReferencePhotos(clientEntryID: cloudEntry.clientEntryID)
        try await characterService.deleteCharacters(clientEntryID: cloudEntry.clientEntryID)
        try await journalRepository.deleteJournalEntryMemberships(clientEntryID: cloudEntry.clientEntryID)
        try await repository.deleteEntry(clientEntryID: cloudEntry.clientEntryID)
        CreateEntryDraftStore.delete(id: localDraftID)
    }

    func persistLocalDraft(_ payload: EntryDraftSavePayload, status: JournalEntryStatus = .draft) -> UUID? {
        let draftThumbnail = DraftThumbnailRenderer.render(
            title: payload.title,
            text: payload.text,
            richText: payload.richText,
            photos: [],
            fontChoiceRawValue: payload.fontChoiceRawValue,
            textColorIndex: payload.textColorIndex,
            textSize: payload.textSize,
            paperStyleRawValue: payload.paperStyleRawValue,
            paperColorIndex: payload.paperColorIndex,
            isBold: payload.isBold,
            isItalic: payload.isItalic,
            isUnderlined: payload.isUnderlined,
            isStrikethrough: payload.isStrikethrough,
            isHighlighted: payload.isHighlighted,
            textAlignmentRawValue: payload.textAlignmentRawValue
        )

        return CreateEntryDraftStore.save(
            id: payload.id,
            title: payload.title,
            text: payload.text,
            richText: payload.richText,
            referencePhotos: payload.photos,
            characters: payload.characters,
            artStyle: payload.artStyle,
            location: payload.location,
            date: payload.date,
            datePrecision: payload.datePrecision,
            savesDraft: payload.savesDraft,
            isPrivate: payload.isPrivate,
            status: status,
            fontChoiceRawValue: payload.fontChoiceRawValue,
            textColorIndex: payload.textColorIndex,
            textSize: payload.textSize,
            paperStyleRawValue: payload.paperStyleRawValue,
            paperColorIndex: payload.paperColorIndex,
            isBold: payload.isBold,
            isItalic: payload.isItalic,
            isUnderlined: payload.isUnderlined,
            isStrikethrough: payload.isStrikethrough,
            isHighlighted: payload.isHighlighted,
            textAlignmentRawValue: payload.textAlignmentRawValue,
            thumbnail: draftThumbnail
        )
    }

    private func syncJournalMemberships(for clientEntryID: UUID) async throws {
        let journalTitles = EntryJournalLinkStore.loadJournalTitles(for: clientEntryID)
        guard !journalTitles.isEmpty else {
            return
        }

        for journalTitle in journalTitles {
            guard let journalID = UserChapterStore.id(for: journalTitle) else {
                continue
            }

            let linkedEntryIDs = StoryEntryStore.clientEntryIDs(for: journalTitle)
            try await journalRepository.replaceJournalEntries(
                journalID: journalID,
                clientEntryIDs: linkedEntryIDs
            )
        }
    }
}
