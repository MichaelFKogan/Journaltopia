import Foundation
import Supabase
import UIKit

struct SampleStoryPack {
    let id: UUID
    let slug: String
    let version: Int
    let locale: String
    let entries: [CreateEntryDraft]
    let storyboardsByEntryID: [UUID: [GeneratedStoryboard]]
}

struct SupabaseSampleStoryService {
    private let client: SupabaseClient
    private let bucketName = "sample-story-assets"

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

        let entries = try await loadEntries(packID: pack.id)
        guard !entries.isEmpty else {
            throw SampleStoryServiceError.noSamplePackAvailable
        }

        let entryIDs = entries.map(\.id)
        let pages = try await loadStoryboardPages(entryIDs: entryIDs)
        let storyboardsByEntryID = await loadStoryboards(pages: pages, entries: entries)

        return SampleStoryPack(
            id: pack.id,
            slug: pack.slug,
            version: pack.version,
            locale: pack.locale,
            entries: entries.map(\.draft),
            storyboardsByEntryID: storyboardsByEntryID
        )
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

    private func loadEntries(packID: UUID) async throws -> [SampleEntryRow] {
        try await client
            .from("sample_entries")
            .select()
            .eq("pack_id", value: packID)
            .order("display_order", ascending: true)
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
                    generationQuality: page.generationQuality.flatMap(OpenAIImageGenerationQuality.init(rawValue:)),
                    panelLayout: page.panelLayout,
                    sourcePhotoCount: 0,
                    storagePath: page.storagePath,
                    cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                    isPrimary: page.isPrimary || page.pageIndex == 0
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
}

private enum SampleStoryServiceError: Error {
    case noSamplePackAvailable
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

    var draft: CreateEntryDraft {
        let richTextDocument = richText ?? NotebookRichTextDocument(text: bodyText)
        let resolvedTextAlignment = textAlignmentRawValue ?? "leading"
        let thumbnail = DraftThumbnailRenderer.render(
            title: title,
            text: bodyText,
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
            textAlignmentRawValue: resolvedTextAlignment
        )

        return CreateEntryDraft(
            id: id,
            title: title,
            text: bodyText,
            richText: richTextDocument,
            photos: [],
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
                    storagePath: storagePath,
                    cloudSyncState: cachedStoryboard.cloudSyncState,
                    isPrimary: cachedStoryboard.isPrimary
                )
            )
        }

        return SampleStoryPack(
            id: payload.id,
            slug: payload.slug,
            version: payload.version,
            locale: payload.locale,
            entries: payload.entries.map(\.draft),
            storyboardsByEntryID: storyboardsByEntryID
        )
    }
}

private struct CachedSampleStoryPack: Codable {
    let id: UUID
    let slug: String
    let version: Int
    let locale: String
    let entries: [CachedSampleEntry]
    let storyboards: [CachedSampleStoryboard]
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
    let storagePath: String?
    let cloudSyncState: String?
    let isPrimary: Bool
}
