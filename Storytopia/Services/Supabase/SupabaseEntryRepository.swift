import Foundation
import Supabase
import UIKit

struct JournalEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let clientEntryID: UUID
    let title: String?
    let content: String?
    let status: String
    let richText: NotebookRichTextDocument?
    let artStyle: String?
    let location: String?
    let entryDate: Date?
    let datePrecision: String?
    let savesDraft: Bool?
    let isPrivate: Bool?
    let fontChoiceRawValue: String?
    let textColorIndex: Int?
    let textSize: Double?
    let paperStyleRawValue: String?
    let paperColorIndex: Int?
    let isBold: Bool?
    let isItalic: Bool?
    let isUnderlined: Bool?
    let isStrikethrough: Bool?
    let isHighlighted: Bool?
    let textAlignmentRawValue: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case clientEntryID = "client_entry_id"
        case title
        case content
        case status
        case richText = "rich_text"
        case artStyle = "art_style"
        case location
        case entryDate = "entry_date"
        case datePrecision = "date_precision"
        case savesDraft = "saves_draft"
        case isPrivate = "is_private"
        case fontChoiceRawValue = "font_choice_raw_value"
        case textColorIndex = "text_color_index"
        case textSize = "text_size"
        case paperStyleRawValue = "paper_style_raw_value"
        case paperColorIndex = "paper_color_index"
        case isBold = "is_bold"
        case isItalic = "is_italic"
        case isUnderlined = "is_underlined"
        case isStrikethrough = "is_strikethrough"
        case isHighlighted = "is_highlighted"
        case textAlignmentRawValue = "text_alignment_raw_value"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct JournalEntrySummaryCounts: Equatable, Sendable {
    let all: Int
    let drafts: Int
    let completed: Int
}

struct JournalEntryPayload: Encodable, Sendable {
    let userID: UUID
    let clientEntryID: UUID
    let title: String?
    let content: String?
    let status: String
    let richText: NotebookRichTextDocument?
    let artStyle: String?
    let location: String?
    let entryDate: Date?
    let datePrecision: String?
    let savesDraft: Bool?
    let isPrivate: Bool?
    let fontChoiceRawValue: String?
    let textColorIndex: Int?
    let textSize: Double?
    let paperStyleRawValue: String?
    let paperColorIndex: Int?
    let isBold: Bool?
    let isItalic: Bool?
    let isUnderlined: Bool?
    let isStrikethrough: Bool?
    let isHighlighted: Bool?
    let textAlignmentRawValue: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case clientEntryID = "client_entry_id"
        case title
        case content
        case status
        case richText = "rich_text"
        case artStyle = "art_style"
        case location
        case entryDate = "entry_date"
        case datePrecision = "date_precision"
        case savesDraft = "saves_draft"
        case isPrivate = "is_private"
        case fontChoiceRawValue = "font_choice_raw_value"
        case textColorIndex = "text_color_index"
        case textSize = "text_size"
        case paperStyleRawValue = "paper_style_raw_value"
        case paperColorIndex = "paper_color_index"
        case isBold = "is_bold"
        case isItalic = "is_italic"
        case isUnderlined = "is_underlined"
        case isStrikethrough = "is_strikethrough"
        case isHighlighted = "is_highlighted"
        case textAlignmentRawValue = "text_alignment_raw_value"
    }
}

struct JournalEntryUpdate: Encodable, Sendable {
    let title: String?
    let content: String?
    let status: String?
}

enum JournalCoverSource: String, Codable, Sendable {
    case color
    case asset
    case local
    case unsplash
}

struct JournalRemoteCover: Codable, Equatable, Sendable {
    let source: JournalCoverSource
    let imageURL: String
    let thumbnailURL: String?
    let attributionName: String?
    let attributionURL: String?
    let downloadLocation: String?

    var imageNSURL: URL? {
        URL(string: imageURL)
    }

    var thumbnailNSURL: URL? {
        thumbnailURL.flatMap(URL.init(string:))
    }
}

struct UnsplashCoverPhoto: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let colorHex: String?
    let imageURL: String
    let thumbnailURL: String
    let attributionName: String
    let attributionURL: String
    let downloadLocation: String
}

enum UnsplashCoverServiceError: LocalizedError {
    case misconfigured
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .misconfigured:
            return "Unsplash covers are not configured yet."
        case .invalidResponse:
            return "Unsplash covers could not be loaded."
        case .requestFailed(let message):
            return message
        }
    }
}

struct UnsplashCoverService {
    private struct CoverFunctionRequest: Encodable {
        let action: String
        let query: String?
        let page: Int?
        let perPage: Int?
        let downloadLocation: String?

        enum CodingKeys: String, CodingKey {
            case action
            case query
            case page
            case perPage = "per_page"
            case downloadLocation = "download_location"
        }
    }

    private struct SearchResponse: Decodable {
        let results: [UnsplashCoverPhoto]
    }

    private struct ErrorResponse: Decodable {
        let error: String?
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, page: Int = 1, perPage: Int = 18) async throws -> [UnsplashCoverPhoto] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let request = CoverFunctionRequest(
            action: "search",
            query: trimmedQuery,
            page: page,
            perPage: perPage,
            downloadLocation: nil
        )

        return try await perform(request, responseType: SearchResponse.self).results
    }

    func trackDownload(for photo: UnsplashCoverPhoto) async throws {
        try await trackDownload(downloadLocation: photo.downloadLocation)
    }

    func trackDownload(downloadLocation: String) async throws {
        let request = CoverFunctionRequest(
            action: "track_download",
            query: nil,
            page: nil,
            perPage: nil,
            downloadLocation: downloadLocation
        )

        _ = try await perform(request, responseType: EmptyResponse.self)
    }

    private func perform<Response: Decodable>(
        _ payload: CoverFunctionRequest,
        responseType: Response.Type
    ) async throws -> Response {
        let request = try coverFunctionRequest(payload)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UnsplashCoverServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? UnsplashCoverServiceError.invalidResponse.localizedDescription
            throw UnsplashCoverServiceError.requestFailed(message)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UnsplashCoverServiceError.invalidResponse
        }
    }

    private func coverFunctionRequest(_ payload: CoverFunctionRequest) throws -> URLRequest {
        let projectURL = try StorytopiaSupabaseConfig.projectURL
        let anonKey = try StorytopiaSupabaseConfig.anonKey
        let functionURL = projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("unsplash-cover")

        var request = URLRequest(url: functionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }
}

private struct EmptyResponse: Decodable {}

struct StoryJournal: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let title: String
    let subtitle: String?
    let colorHex: String?
    let symbol: String?
    let coverStoragePath: String?
    let coverSource: String?
    let coverImageURL: String?
    let coverThumbURL: String?
    let coverAttributionName: String?
    let coverAttributionURL: String?
    let coverDownloadLocation: String?
    let kind: String
    let isFavorite: Bool
    let displayOrder: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case subtitle
        case colorHex = "color_hex"
        case symbol
        case coverStoragePath = "cover_storage_path"
        case coverSource = "cover_source"
        case coverImageURL = "cover_image_url"
        case coverThumbURL = "cover_thumb_url"
        case coverAttributionName = "cover_attribution_name"
        case coverAttributionURL = "cover_attribution_url"
        case coverDownloadLocation = "cover_download_location"
        case kind
        case isFavorite = "is_favorite"
        case displayOrder = "display_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct StoryJournalPayload: Encodable, Sendable {
    let id: UUID
    let userID: UUID
    let title: String
    let subtitle: String?
    let colorHex: String?
    let symbol: String?
    let coverSource: String?
    let coverImageURL: String?
    let coverThumbURL: String?
    let coverAttributionName: String?
    let coverAttributionURL: String?
    let coverDownloadLocation: String?
    let kind: String
    let isFavorite: Bool
    let displayOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case subtitle
        case colorHex = "color_hex"
        case symbol
        case coverSource = "cover_source"
        case coverImageURL = "cover_image_url"
        case coverThumbURL = "cover_thumb_url"
        case coverAttributionName = "cover_attribution_name"
        case coverAttributionURL = "cover_attribution_url"
        case coverDownloadLocation = "cover_download_location"
        case kind
        case isFavorite = "is_favorite"
        case displayOrder = "display_order"
    }
}

private struct JournalCoverUpdate: Encodable, Sendable {
    let coverStoragePath: String

    enum CodingKeys: String, CodingKey {
        case coverStoragePath = "cover_storage_path"
    }
}

private struct JournalEntryMembershipPayload: Encodable, Sendable {
    let userID: UUID
    let journalID: UUID
    let clientEntryID: UUID
    let position: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case journalID = "journal_id"
        case clientEntryID = "client_entry_id"
        case position
    }
}

struct JournalEntryMembership: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let journalID: UUID
    let clientEntryID: UUID
    let position: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case journalID = "journal_id"
        case clientEntryID = "client_entry_id"
        case position
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum JournalEntryStatus: String, Codable, Sendable {
    case draft
    case completed
    case archived
}

enum JournalEntryRepositoryError: LocalizedError {
    case notAuthenticated
    case emptyTitleAndContent
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in before editing entries."
        case .emptyTitleAndContent:
            return "Add a title or entry text first."
        case .operationFailed:
            return "The entry could not be saved. Please try again."
        }
    }
}

enum StoryJournalRepositoryError: LocalizedError {
    case notAuthenticated
    case operationFailed
    case invalidCover

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in before editing journals."
        case .operationFailed:
            return "The journal could not be saved. Please try again."
        case .invalidCover:
            return "The journal cover could not be prepared for upload."
        }
    }
}

struct SupabaseJournalRepository {
    private let client: SupabaseClient
    private let coverBucketName = "journal-covers"

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func getJournals() async throws -> [StoryJournal] {
        let userID = try await authenticatedUserID()

        do {
            return try await client
                .from("journals")
                .select()
                .eq("user_id", value: userID)
                .order("display_order", ascending: true)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    func getJournalEntryMemberships() async throws -> [JournalEntryMembership] {
        let userID = try await authenticatedUserID()

        do {
            return try await client
                .from("journal_entries")
                .select()
                .eq("user_id", value: userID)
                .order("position", ascending: true)
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    @discardableResult
    func upsertJournal(
        id: UUID,
        title: String,
        subtitle: String?,
        colorHex: String?,
        symbol: String?,
        remoteCover: JournalRemoteCover? = nil,
        kind: String,
        isFavorite: Bool,
        displayOrder: Int
    ) async throws -> StoryJournal {
        let userID = try await authenticatedUserID()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            return try await client
                .from("journals")
                .upsert(
                    StoryJournalPayload(
                        id: id,
                        userID: userID,
                        title: cleanTitle.isEmpty ? "Untitled Journal" : cleanTitle,
                        subtitle: subtitle?.trimmedOrNil,
                        colorHex: colorHex?.trimmedOrNil,
                        symbol: symbol?.trimmedOrNil,
                        coverSource: remoteCover?.source.rawValue,
                        coverImageURL: remoteCover?.imageURL.trimmedOrNil,
                        coverThumbURL: remoteCover?.thumbnailURL?.trimmedOrNil,
                        coverAttributionName: remoteCover?.attributionName?.trimmedOrNil,
                        coverAttributionURL: remoteCover?.attributionURL?.trimmedOrNil,
                        coverDownloadLocation: remoteCover?.downloadLocation?.trimmedOrNil,
                        kind: kind,
                        isFavorite: isFavorite,
                        displayOrder: displayOrder
                    ),
                    onConflict: "user_id,id"
                )
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    func deleteJournal(id: UUID) async throws {
        let userID = try await authenticatedUserID()

        do {
            try await client
                .from("journals")
                .delete()
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    func replaceJournalEntries(journalID: UUID, clientEntryIDs: [UUID]) async throws {
        let userID = try await authenticatedUserID()

        do {
            try await client
                .from("journal_entries")
                .delete()
                .eq("journal_id", value: journalID)
                .eq("user_id", value: userID)
                .execute()

            var seenEntryIDs = Set<UUID>()
            let uniqueIDs = clientEntryIDs.filter { clientEntryID in
                seenEntryIDs.insert(clientEntryID).inserted
            }
            guard !uniqueIDs.isEmpty else {
                return
            }

            let payloads = uniqueIDs.enumerated().map { index, clientEntryID in
                JournalEntryMembershipPayload(
                    userID: userID,
                    journalID: journalID,
                    clientEntryID: clientEntryID,
                    position: index
                )
            }

            try await client
                .from("journal_entries")
                .insert(payloads)
                .execute()
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    func deleteJournalEntryMemberships(clientEntryID: UUID) async throws {
        let userID = try await authenticatedUserID()

        do {
            try await client
                .from("journal_entries")
                .delete()
                .eq("client_entry_id", value: clientEntryID)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    @discardableResult
    func uploadCover(_ image: UIImage, journalID: UUID) async throws -> StoryJournal {
        let userID = try await authenticatedUserID()
        guard let imageData = image.storytopiaPreparedJPEGData(compressionQuality: 0.86) else {
            throw StoryJournalRepositoryError.invalidCover
        }

        let storagePath = [
            userID.uuidString.lowercased(),
            journalID.uuidString.lowercased(),
            "cover.jpg"
        ].joined(separator: "/")

        do {
            try await client.storage
                .from(coverBucketName)
                .upload(
                    storagePath,
                    data: imageData,
                    options: FileOptions(
                        cacheControl: "31536000",
                        contentType: CreateEntryReferencePhoto.mimeType,
                        upsert: true
                    )
                )

            return try await client
                .from("journals")
                .update(JournalCoverUpdate(coverStoragePath: storagePath))
                .eq("id", value: journalID)
                .eq("user_id", value: userID)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw StoryJournalRepositoryError.operationFailed
        }
    }

    private func authenticatedUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw StoryJournalRepositoryError.notAuthenticated
        }
    }
}

struct SupabaseEntryRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func getEntries() async throws -> [JournalEntry] {
        let userID = try await authenticatedUserID()

        do {
            return try await client
                .from("entries")
                .select()
                .eq("user_id", value: userID)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func getEntrySummaries() async throws -> [JournalEntry] {
        let userID = try await authenticatedUserID()

        do {
            return try await client
                .from("entries")
                .select("id,user_id,client_entry_id,title,content,status,art_style,location,entry_date,date_precision,saves_draft,is_private,font_choice_raw_value,text_color_index,text_size,paper_style_raw_value,paper_color_index,is_bold,is_italic,is_underlined,is_strikethrough,is_highlighted,text_alignment_raw_value,created_at,updated_at")
                .eq("user_id", value: userID)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func getEntrySummariesPage(
        limit: Int,
        offset: Int,
        sort: EntrySummarySort,
        statusFilter: EntrySummaryStatusFilter
    ) async throws -> [JournalEntry] {
        let userID = try await authenticatedUserID()
        let rangeEnd = max(offset, offset + limit - 1)

        do {
            var query = client
                .from("entries")
                .select("id,user_id,client_entry_id,title,content,status,art_style,location,entry_date,date_precision,saves_draft,is_private,font_choice_raw_value,text_color_index,text_size,paper_style_raw_value,paper_color_index,is_bold,is_italic,is_underlined,is_strikethrough,is_highlighted,text_alignment_raw_value,created_at,updated_at")
                .eq("user_id", value: userID)
                .neq("status", value: JournalEntryStatus.archived.rawValue)

            switch statusFilter {
            case .all:
                break
            case .drafts:
                query = query.neq("status", value: JournalEntryStatus.completed.rawValue)
            case .completed:
                query = query.eq("status", value: JournalEntryStatus.completed.rawValue)
            }

            switch sort {
            case .entryDate:
                return try await query
                    .order("entry_date", ascending: false)
                    .order("created_at", ascending: false)
                    .range(from: offset, to: rangeEnd)
                    .execute()
                    .value
            case .createdAt:
                return try await query
                    .order("created_at", ascending: false)
                    .range(from: offset, to: rangeEnd)
                    .execute()
                    .value
            case .updatedAt:
                return try await query
                    .order("updated_at", ascending: false)
                    .range(from: offset, to: rangeEnd)
                    .execute()
                    .value
            }
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func getEntrySummaryCounts() async throws -> JournalEntrySummaryCounts {
        async let all = getEntrySummaryCount(statusFilter: .all)
        async let drafts = getEntrySummaryCount(statusFilter: .drafts)
        async let completed = getEntrySummaryCount(statusFilter: .completed)

        do {
            let (allCount, draftCount, completedCount) = try await (all, drafts, completed)
            return JournalEntrySummaryCounts(
                all: allCount,
                drafts: draftCount,
                completed: completedCount
            )
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func getEntry(id: UUID) async throws -> JournalEntry {
        let userID = try await authenticatedUserID()

        do {
            return try await client
                .from("entries")
                .select()
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .limit(1)
                .single()
                .execute()
                .value
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func createEntry(title: String, content: String) async throws -> JournalEntry {
        let userID = try await authenticatedUserID()
        let cleanTitle = title.trimmedOrNil
        let cleanContent = content.trimmedOrNil

        guard cleanTitle != nil || cleanContent != nil else {
            throw JournalEntryRepositoryError.emptyTitleAndContent
        }

        do {
            return try await client
                .from("entries")
                .insert(
                    JournalEntryPayload(
                        userID: userID,
                        clientEntryID: UUID(),
                        title: cleanTitle,
                        content: cleanContent,
                        status: "draft",
                        richText: nil,
                        artStyle: nil,
                        location: nil,
                        entryDate: nil,
                        datePrecision: nil,
                        savesDraft: nil,
                        isPrivate: nil,
                        fontChoiceRawValue: nil,
                        textColorIndex: nil,
                        textSize: nil,
                        paperStyleRawValue: nil,
                        paperColorIndex: nil,
                        isBold: nil,
                        isItalic: nil,
                        isUnderlined: nil,
                        isStrikethrough: nil,
                        isHighlighted: nil,
                        textAlignmentRawValue: nil
                    )
                )
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func updateEntry(id: UUID, title: String, content: String, status: JournalEntryStatus = .draft) async throws -> JournalEntry {
        let userID = try await authenticatedUserID()
        let cleanTitle = title.trimmedOrNil
        let cleanContent = content.trimmedOrNil

        guard cleanTitle != nil || cleanContent != nil else {
            throw JournalEntryRepositoryError.emptyTitleAndContent
        }

        do {
            return try await client
                .from("entries")
                .update(
                    JournalEntryUpdate(
                        title: cleanTitle,
                        content: cleanContent,
                        status: status.rawValue
                    )
                )
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func upsertEntry(
        clientEntryID: UUID,
        title: String,
        content: String,
        richText: NotebookRichTextDocument? = nil,
        artStyle: String? = nil,
        location: String? = nil,
        entryDate: Date? = nil,
        datePrecision: EntryDatePrecision? = nil,
        savesDraft: Bool? = nil,
        isPrivate: Bool? = nil,
        fontChoiceRawValue: String? = nil,
        textColorIndex: Int? = nil,
        textSize: Double? = nil,
        paperStyleRawValue: String? = nil,
        paperColorIndex: Int? = nil,
        isBold: Bool? = nil,
        isItalic: Bool? = nil,
        isUnderlined: Bool? = nil,
        isStrikethrough: Bool? = nil,
        isHighlighted: Bool? = nil,
        textAlignmentRawValue: String? = nil,
        status: JournalEntryStatus = .draft
    ) async throws -> JournalEntry {
        let userID = try await authenticatedUserID()
        let cleanTitle = title.trimmedOrNil
        let cleanContent = content.trimmedOrNil

        guard cleanTitle != nil || cleanContent != nil else {
            throw JournalEntryRepositoryError.emptyTitleAndContent
        }

        do {
            return try await client
                .from("entries")
                .upsert(
                    JournalEntryPayload(
                        userID: userID,
                        clientEntryID: clientEntryID,
                        title: cleanTitle,
                        content: cleanContent,
                        status: status.rawValue,
                        richText: richText,
                        artStyle: artStyle?.trimmedOrNil,
                        location: location?.trimmedOrNil,
                        entryDate: entryDate,
                        datePrecision: datePrecision?.rawValue,
                        savesDraft: savesDraft,
                        isPrivate: isPrivate,
                        fontChoiceRawValue: fontChoiceRawValue?.trimmedOrNil,
                        textColorIndex: textColorIndex,
                        textSize: textSize,
                        paperStyleRawValue: paperStyleRawValue?.trimmedOrNil,
                        paperColorIndex: paperColorIndex,
                        isBold: isBold,
                        isItalic: isItalic,
                        isUnderlined: isUnderlined,
                        isStrikethrough: isStrikethrough,
                        isHighlighted: isHighlighted,
                        textAlignmentRawValue: textAlignmentRawValue?.trimmedOrNil
                    ),
                    onConflict: "user_id,client_entry_id"
                )
                .select()
                .single()
                .execute()
                .value
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func deleteEntry(clientEntryID: UUID) async throws {
        let userID = try await authenticatedUserID()

        do {
            try await client
                .from("entries")
                .delete()
                .eq("client_entry_id", value: clientEntryID)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    func deleteEntry(id: UUID) async throws {
        let userID = try await authenticatedUserID()

        do {
            try await client
                .from("entries")
                .delete()
                .eq("id", value: id)
                .eq("user_id", value: userID)
                .execute()
        } catch {
            throw JournalEntryRepositoryError.operationFailed
        }
    }

    private func authenticatedUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw JournalEntryRepositoryError.notAuthenticated
        }
    }

    private func getEntrySummaryCount(statusFilter: EntrySummaryStatusFilter) async throws -> Int {
        let userID = try await authenticatedUserID()

        var query = client
            .from("entries")
            .select("id")
            .eq("user_id", value: userID)
            .neq("status", value: JournalEntryStatus.archived.rawValue)

        switch statusFilter {
        case .all:
            break
        case .drafts:
            query = query.neq("status", value: JournalEntryStatus.completed.rawValue)
        case .completed:
            query = query.eq("status", value: JournalEntryStatus.completed.rawValue)
        }

        let response = try await query
            .execute(options: FetchOptions(head: true, count: .exact))
        return response.count ?? 0
    }
}

enum EntrySummarySort: Sendable, Hashable {
    case entryDate
    case createdAt
    case updatedAt
}

enum EntrySummaryStatusFilter: Sendable, Hashable {
    case all
    case drafts
    case completed
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
