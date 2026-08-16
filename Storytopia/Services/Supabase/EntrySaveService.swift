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
    /// The entry never reached the cloud, and retrying did not help. Unlike `.failed`, this one is
    /// also written to `EntryCloudSyncFailureStore`, so the warning survives the view being torn
    /// down or the app being relaunched instead of vanishing with the screen that produced it.
    case notSaved(String)

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
        case .notSaved(let message):
            return message
        }
    }

    var shouldDismissAutomatically: Bool {
        switch self {
        case .saved, .savedLocally, .photosUploaded:
            return true
        case .idle, .saving, .uploadingPhotos, .failed, .photoUploadFailed, .notSaved:
            return false
        }
    }

    var isConfirmedSave: Bool {
        switch self {
        case .saved, .savedLocally, .photosUploaded:
            return true
        case .idle, .saving, .uploadingPhotos, .failed, .photoUploadFailed, .notSaved:
            return false
        }
    }

    /// True when the entry exists only on this device and the UI should keep saying so.
    var isUnsyncedToCloud: Bool {
        switch self {
        case .notSaved:
            return true
        case .idle, .saving, .saved, .savedLocally, .uploadingPhotos, .photosUploaded, .failed, .photoUploadFailed:
            return false
        }
    }
}

/// Remembers which local drafts failed to reach Supabase.
///
/// `EntryCloudSaveState` lives on a SwiftUI view and dies with it, so on its own it cannot answer
/// "is this entry actually backed up?" the next time the entry is opened. This store is the durable
/// half: written when a save exhausts its retries, cleared the moment the entry lands in the cloud.
enum EntryCloudSyncFailureStore {
    private static let storageKey = "StorytopiaEntryCloudSyncFailures"

    static func markNotSaved(clientEntryID: UUID, reason: String) {
        var failures = reasonsByEntryKey
        failures[clientEntryID.uuidString] = reason
        UserDefaults.standard.set(failures, forKey: storageKey)
    }

    static func clear(clientEntryID: UUID) {
        var failures = reasonsByEntryKey
        guard failures.removeValue(forKey: clientEntryID.uuidString) != nil else {
            return
        }

        UserDefaults.standard.set(failures, forKey: storageKey)
    }

    static func reason(for clientEntryID: UUID) -> String? {
        reasonsByEntryKey[clientEntryID.uuidString]
    }

    static func isNotSaved(clientEntryID: UUID) -> Bool {
        reason(for: clientEntryID) != nil
    }

    static var unsyncedEntryIDs: Set<UUID> {
        Set(reasonsByEntryKey.keys.compactMap(UUID.init(uuidString:)))
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static var reasonsByEntryKey: [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}

/// Lets an error that has already been mapped to a domain type still report whether the failure
/// underneath it was transient.
///
/// Every Supabase service here collapses the raw error into its own `LocalizedError` before it
/// reaches a caller, so without this `SupabaseRetry` would only ever see `syncFailed` and could not
/// tell a dropped connection from a row the server refused.
protocol TransientCloudFailure {
    var isTransientCloudFailure: Bool { get }
}

/// Bounded retry with exponential backoff for Supabase writes.
///
/// Only failures a second attempt could plausibly fix are retried: lost connections, timeouts, 5xx
/// responses, and Postgres connection errors. Auth failures, validation errors, and every other 4xx
/// are the server saying the request itself is wrong, so they fail on the first attempt — retrying
/// them just makes the user wait longer for the same answer.
///
/// Every write wrapped in this helper must be idempotent, because attempt *n + 1* cannot know
/// whether attempt *n* reached the server before the connection dropped.
enum SupabaseRetry {
    /// Backoff before each retry — one entry per retry, every entry used. A save that never
    /// succeeds spends ~6s retrying before it gives up.
    static let backoffSeconds: [Double] = [0.5, 1.5, 4]

    /// The initial attempt plus one per backoff entry. Derived rather than written out so the two
    /// cannot drift into an unused delay or a retry with no schedule behind it.
    static let defaultMaxAttempts = backoffSeconds.count + 1

    /// Each delay is jittered ±25% so devices that all lost the same network do not come back in
    /// lockstep and re-create the stampede that knocked them offline.
    static let jitterMultiplier: ClosedRange<Double> = 0.75...1.25

    /// Waits out one backoff step. Injectable so tests can assert the schedule without spending the
    /// ~6s that actually sleeping through it would cost.
    static func defaultSleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func withRetry<T>(
        _ context: String,
        maxAttempts: Int = defaultMaxAttempts,
        sleep: (Double) async throws -> Void = defaultSleep(seconds:),
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1

        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, isTransient(error) else {
                    if attempt > 1 {
                        print("[Storytopia] \(context) failed after \(attempt) attempt(s): \(error.localizedDescription)")
                    }
                    throw error
                }

                let delay = backoffSeconds[min(attempt - 1, backoffSeconds.count - 1)]
                    * Double.random(in: jitterMultiplier)
                print("[Storytopia] \(context) attempt \(attempt) hit a transient failure, retrying in \(String(format: "%.2f", delay))s: \(error.localizedDescription)")

                // A cancelled sleep means the caller walked away; that is a reason to stop, not to
                // retry, so the CancellationError is allowed to propagate.
                try await sleep(delay)
                attempt += 1
            }
        }
    }

    /// Mirrors `GenerationCreditError.mapped`: inspect the concrete Supabase error types first and
    /// fall through to "not retryable" rather than guessing.
    static func isTransient(_ error: Error) -> Bool {
        if let mappedError = error as? TransientCloudFailure {
            return mappedError.isTransientCloudFailure
        }

        if error is CancellationError {
            return false
        }

        if let urlError = error as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
        }

        // PostgREST returns `HTTPError` whenever the body is not a Postgrest error payload, which is
        // how gateway 5xx and Supabase pooler failures arrive.
        if let httpError = error as? HTTPError {
            return isServerSide(statusCode: httpError.response.statusCode)
        }

        if let storageError = error as? StorageError {
            guard let statusCode = storageError.statusCode.flatMap(Int.init) else {
                return false
            }
            return isServerSide(statusCode: statusCode)
        }

        if let postgrestError = error as? PostgrestError {
            return isConnectionFailure(postgrestError)
        }

        return false
    }

    private static func isServerSide(statusCode: Int) -> Bool {
        (500...599).contains(statusCode)
    }

    /// A `PostgrestError` carries a SQLSTATE rather than an HTTP status. Only the codes that mean
    /// "the database was unreachable or overloaded" are worth another attempt — a constraint
    /// violation or an RLS denial will fail identically forever.
    private static func isConnectionFailure(_ error: PostgrestError) -> Bool {
        if let code = error.code?.uppercased() {
            // 08xxx connection exception, 53xxx insufficient resources, 57Pxx server shutdown or
            // startup, 40001/40P01 serialization failure and deadlock, 57014 statement timeout.
            if code.hasPrefix("08") || code.hasPrefix("53") || code.hasPrefix("57P")
                || code == "40001" || code == "40P01" || code == "57014" {
                return true
            }

            // PostgREST's own "could not connect to the database" / "schema cache unavailable".
            if code == "PGRST001" || code == "PGRST002" {
                return true
            }
        }

        let message = error.message.lowercased()
        return message.contains("connection")
            || message.contains("timeout")
            || message.contains("timed out")
            || message.contains("server closed")
            || message.contains("too many clients")
    }

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .badServerResponse,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed
    ]
}

struct EntryDraftSavePayload {
    let id: UUID?
    let createdAt: Date?
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

    // `generation_status` is deliberately absent. The generation lifecycle belongs to the server —
    // the app is not granted the column — and a storyboard written through this payload is an
    // already-finished image being recorded or duplicated, which is exactly the column default.
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
            return "Sign in before saving a storyboard to Journaltopia cloud."
        case .syncFailed:
            return "Storyboard cloud sync failed. Please try again."
        case .downloadFailed:
            return "Could not download this storyboard."
        }
    }
}

enum SupabaseEntryThumbnailError: LocalizedError, TransientCloudFailure {
    case invalidImage
    case syncFailed
    case temporarilyUnavailable
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The entry thumbnail could not be prepared for upload."
        case .syncFailed:
            return "Entry thumbnail sync failed. Please try again."
        case .temporarilyUnavailable:
            return "Entry thumbnail sync could not reach Journaltopia cloud."
        case .downloadFailed:
            return "Could not download this entry thumbnail."
        }
    }

    var isTransientCloudFailure: Bool {
        self == .temporarilyUnavailable
    }

    /// Keeps the "was this worth retrying?" answer alive across the mapping, the way
    /// `GenerationCreditError.mapped` keeps "was this really an empty balance?" alive.
    static func mapped(from error: Error, context: String) -> SupabaseEntryThumbnailError {
        print("[Storytopia] \(context) failed: \(error.localizedDescription)")

        if let thumbnailError = error as? SupabaseEntryThumbnailError {
            return thumbnailError
        }

        return SupabaseRetry.isTransient(error) ? .temporarilyUnavailable : .syncFailed
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
        } catch {
            throw SupabaseEntryThumbnailError.mapped(from: error, context: "entry thumbnail upload")
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
        try await persistStoryboard(storyboard.withPrimaryStatus(true))
    }

    func persistStoryboard(_ storyboard: GeneratedStoryboard) async throws -> EntryStoryboard {
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

            if storyboard.isPrimary {
                try await markPriorStoryboardsNonPrimary(
                    userID: userID,
                    clientEntryID: clientEntryID,
                    excluding: storyboard.id
                )
            }

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
                        isPrimary: storyboard.isPrimary
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

        try await setPrimaryStoryboard(id: storyboard.id, clientEntryID: clientEntryID)
    }

    func setPrimaryStoryboard(id storyboardID: UUID, clientEntryID: UUID) async throws {
        let userID = try await authenticatedUserID()

        do {
            try await markPriorStoryboardsNonPrimary(
                userID: userID,
                clientEntryID: clientEntryID,
                excluding: storyboardID
            )

            try await client
                .from("entry_storyboards")
                .update(EntryStoryboardPrimaryUpdate(isPrimary: true))
                .eq("user_id", value: userID)
                .eq("client_entry_id", value: clientEntryID)
                .eq("id", value: storyboardID)
                .execute()
            print("[Storytopia] Primary storyboard selection updated.")
        } catch let error as SupabaseStoryboardError {
            throw error
        } catch {
            print("[Storytopia] Primary storyboard update failed: \(error.localizedDescription)")
            throw SupabaseStoryboardError.syncFailed
        }
    }

    /// Deletes the given storyboards for one entry and returns the rows that survive.
    /// The surviving rows are what the caller needs to decide whether the entry still has
    /// artwork and whether a new primary has to be promoted.
    func deleteStoryboards(ids: Set<UUID>, clientEntryID: UUID) async throws -> [EntryStoryboard] {
        guard !ids.isEmpty else {
            return try await storyboardRows(for: clientEntryID)
        }

        let userID = try await authenticatedUserID()

        do {
            let rows = try await storyboardRows(for: clientEntryID)
            let doomedRows = rows.filter { ids.contains($0.id) }

            guard !doomedRows.isEmpty else {
                return rows
            }

            let storagePaths = doomedRows.map(\.storagePath)
            do {
                try await client.storage
                    .from(bucketName)
                    .remove(paths: storagePaths)
            } catch let error as StorageError where error.statusCode == "404" {
                // Missing objects are already gone; continue so the rows still get cleaned up.
            }

            for storagePath in storagePaths {
                SupabaseStorageImageCache.remove(bucketName: bucketName, storagePath: storagePath)
            }

            let doomedIDs: [any PostgrestFilterValue] = doomedRows.map { $0.id as any PostgrestFilterValue }
            try await client
                .from("entry_storyboards")
                .delete()
                .eq("user_id", value: userID)
                .eq("client_entry_id", value: clientEntryID)
                .in("id", values: doomedIDs)
                .execute()

            print("[Storytopia] Storyboard delete succeeded for \(doomedRows.count) storyboard(s).")
            return rows.filter { !ids.contains($0.id) }
        } catch let error as SupabaseStoryboardError {
            throw error
        } catch {
            print("[Storytopia] Storyboard delete failed: \(error.localizedDescription)")
            throw SupabaseStoryboardError.syncFailed
        }
    }

    /// Removes every storyboard belonging to an entry. Used when the entry itself is deleted.
    func deleteStoryboards(clientEntryID: UUID) async throws {
        let rows = try await storyboardRows(for: clientEntryID)
        guard !rows.isEmpty else {
            return
        }

        _ = try await deleteStoryboards(ids: Set(rows.map(\.id)), clientEntryID: clientEntryID)
    }

    func storyboardRows(for clientEntryID: UUID) async throws -> [EntryStoryboard] {
        try await loadStoryboardRows(for: [clientEntryID])
    }

    func storyboardRows(for clientEntryIDs: Set<UUID>) async throws -> [EntryStoryboard] {
        try await loadStoryboardRows(for: clientEntryIDs)
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
    private let storyboardService: SupabaseStoryboardService

    init(
        repository: SupabaseEntryRepository = SupabaseEntryRepository(),
        journalRepository: SupabaseJournalRepository = SupabaseJournalRepository(),
        referencePhotoService: SupabaseReferencePhotoService = SupabaseReferencePhotoService(),
        characterService: SupabaseEntryCharacterService = SupabaseEntryCharacterService(),
        thumbnailService: SupabaseEntryThumbnailService = SupabaseEntryThumbnailService(),
        storyboardService: SupabaseStoryboardService = SupabaseStoryboardService()
    ) {
        self.repository = repository
        self.journalRepository = journalRepository
        self.referencePhotoService = referencePhotoService
        self.characterService = characterService
        self.thumbnailService = thumbnailService
        self.storyboardService = storyboardService
    }

    func saveEntryPreservingStatus(
        payload: EntryDraftSavePayload,
        isSignedIn: Bool,
        status: JournalEntryStatus = .draft,
        syncReferencePhotos: Bool = true
    ) async throws -> EntrySaveResult {
        // The user's writing is committed to disk before a single byte goes to Supabase. Every exit
        // below this line — including a total cloud failure after every retry — still leaves a
        // complete local draft behind, so nothing the user typed can be lost to a bad network.
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
            // Nothing to be out of step with: a signed-out save has no cloud row that could later
            // be downloaded over this draft, so leaving it flagged as uncommitted would only make
            // the editor keep insisting there are unsaved changes.
            CreateEntryDraftStore.markCloudSynchronized(id: localDraftID)
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
            // Safe to retry: the write is an upsert keyed on (user_id, client_entry_id), so a
            // request that actually landed before the connection dropped is simply overwritten
            // with the same values on the next attempt.
            cloudEntry = try await SupabaseRetry.withRetry("Supabase entry upsert") {
                try await repository.upsertEntry(
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
                    displayOrder: nil,
                    createdAt: payload.createdAt,
                    status: status
                )
            }
        } catch {
            // Retries are spent. The entry exists only on this device, so say so in a way that
            // outlives this screen instead of flashing a message that the next state change wipes.
            return notSavedResult(
                localDraftID: localDraftID,
                reason: "Saved on this device only. Journaltopia cloud could not be reached.",
                error: error
            )
        }

        EntryCloudSyncFailureStore.clear(clientEntryID: localDraftID)
        // The entry row landed, so the local copy is no longer ahead of Supabase. Media sync below
        // can still fail, but the writing the user would hate to lose is committed.
        CreateEntryDraftStore.markCloudSynchronized(id: localDraftID)

        if let thumbnail = CreateEntryDraftStore.load(id: localDraftID)?.thumbnail {
            do {
                // Safe to retry: the storage upload is `upsert: true` at a deterministic path and
                // the row update writes fixed values.
                cloudEntry = try await SupabaseRetry.withRetry("Entry thumbnail sync") {
                    try await thumbnailService.uploadThumbnail(thumbnail, for: cloudEntry)
                }
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
            // Safe to retry: both syncs re-read the cloud state and re-derive the diff, so a partly
            // applied attempt is finished rather than duplicated by the next one.
            try await SupabaseRetry.withRetry("Reference photo sync") {
                try await referencePhotoService.syncReferencePhotos(entry: cloudEntry, photos: payload.photos)
            }
            try await SupabaseRetry.withRetry("Entry character sync") {
                try await characterService.syncCharacters(entry: cloudEntry, characters: payload.characters)
            }

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

    /// Records the failure durably and returns the matching state, so "not saved" is one fact with
    /// one owner rather than a banner string and a store that can drift apart.
    private func notSavedResult(
        localDraftID: UUID,
        reason: String,
        error: Error
    ) -> EntrySaveResult {
        print("[Storytopia] Cloud entry save gave up, entry is local only: \(error.localizedDescription)")
        EntryCloudSyncFailureStore.markNotSaved(clientEntryID: localDraftID, reason: reason)

        return EntrySaveResult(
            localDraftID: localDraftID,
            cloudEntry: nil,
            state: .notSaved(reason)
        )
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
        } else if case .notSaved = result.state {
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

        let cloudEntry = try await SupabaseRetry.withRetry("Supabase entry rename") {
            try await repository.upsertEntry(
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
                displayOrder: entry.displayOrder,
                createdAt: entry.createdAt,
                status: status
            )
        }

        guard let thumbnail = entry.thumbnail else {
            return cloudEntry
        }

        do {
            return try await SupabaseRetry.withRetry("Entry thumbnail sync") {
                try await thumbnailService.uploadThumbnail(thumbnail, for: cloudEntry)
            }
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
                try await storyboardService.deleteStoryboards(clientEntryID: localDraftID)
                try await repository.deleteEntry(clientEntryID: localDraftID)
            }

            removeLocalStoryboards(clientEntryID: localDraftID)
            EntryCloudSyncFailureStore.clear(clientEntryID: localDraftID)
            UnfinishedCreateSessionStore.clearIfMatches(draftID: localDraftID)
            CreateEntryDraftStore.delete(id: localDraftID)
            return
        }

        guard isSignedIn else {
            throw JournalEntryRepositoryError.notAuthenticated
        }

        await thumbnailService.deleteThumbnail(storagePath: cloudEntry.thumbnailStoragePath)
        try await referencePhotoService.deleteReferencePhotos(clientEntryID: cloudEntry.clientEntryID)
        try await characterService.deleteCharacters(clientEntryID: cloudEntry.clientEntryID)
        try await storyboardService.deleteStoryboards(clientEntryID: cloudEntry.clientEntryID)
        try await journalRepository.deleteJournalEntryMemberships(clientEntryID: cloudEntry.clientEntryID)
        try await repository.deleteEntry(clientEntryID: cloudEntry.clientEntryID)
        removeLocalStoryboards(clientEntryID: cloudEntry.clientEntryID)
        EntryCloudSyncFailureStore.clear(clientEntryID: localDraftID)
        UnfinishedCreateSessionStore.clearIfMatches(draftID: localDraftID)
        CreateEntryDraftStore.delete(id: localDraftID)
    }

    private func removeLocalStoryboards(clientEntryID: UUID) {
        let summaries = GeneratedStoryboardStore.summaries(clientEntryID: clientEntryID)
        guard !summaries.isEmpty else {
            return
        }

        GeneratedStoryboardStore.remove(ids: Set(summaries.map(\.id)))
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
            thumbnail: draftThumbnail,
            createdAt: payload.createdAt
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
            // Safe to retry: the membership write clears the journal and re-inserts the full list,
            // so a repeat attempt converges on the same rows rather than duplicating them.
            try await SupabaseRetry.withRetry("Journal membership sync") {
                try await journalRepository.replaceJournalEntries(
                    journalID: journalID,
                    clientEntryIDs: linkedEntryIDs
                )
            }
        }
    }
}
