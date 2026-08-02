import Foundation
import UIKit

enum StoryPage {
    case home
    case today
    case explore
    case create
    case entries
    case journal
    case profile
    case settings
}

enum EntryDatePrecision: String, CaseIterable, Identifiable, Codable {
    case noDate
    case exact
    case dateOnly
    case monthAndYear
    case yearOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noDate:
            "No Date"
        case .exact:
            "Date & Time"
        case .dateOnly:
            "Date Only"
        case .monthAndYear:
            "Month & Year"
        case .yearOnly:
            "Year Only"
        }
    }
}

enum StoryboardLayoutOption: String, CaseIterable, Identifiable {
    case twoRectangles
    case threeHorizontalPanels
    case threePanels
    case threeVerticalPanels
    case fourSquares
    case fourVerticalPanels
    case fourHorizontalRectangles
    case fiveHorizontalPanels
    case fiveClassic
    case sixSquares

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .twoRectangles:
            return "2 Rectangles"
        case .threeHorizontalPanels:
            return "3 Horiz."
        case .threePanels:
            return "3 Panels"
        case .threeVerticalPanels:
            return "3 Vertical"
        case .fourSquares:
            return "4 Squares"
        case .fourVerticalPanels:
            return "4 Vertical"
        case .fourHorizontalRectangles:
            return "4 Horiz."
        case .fiveHorizontalPanels:
            return "5 Horiz."
        case .fiveClassic:
            return "5 Panels"
        case .sixSquares:
            return "6 Squares"
        }
    }

    var panelCount: Int {
        switch self {
        case .twoRectangles:
            return 2
        case .threeHorizontalPanels, .threePanels, .threeVerticalPanels:
            return 3
        case .fourSquares, .fourVerticalPanels, .fourHorizontalRectangles:
            return 4
        case .fiveHorizontalPanels, .fiveClassic:
            return 5
        case .sixSquares:
            return 6
        }
    }

    var promptDescription: String {
        switch self {
        case .twoRectangles:
            return "two full-width horizontal rectangle panels stacked evenly from top to bottom."
        case .threeHorizontalPanels:
            return "three full-width horizontal rectangle panels stacked evenly from top to bottom."
        case .threePanels:
            return "one large full-width horizontal rectangle panel on top, with two equal rectangle panels side by side underneath."
        case .threeVerticalPanels:
            return "three equal tall vertical rectangle panels side by side in a single row."
        case .fourSquares:
            return "four equal square panels in a clean 2 by 2 grid."
        case .fourVerticalPanels:
            return "four equal tall vertical rectangle panels side by side in a single row."
        case .fourHorizontalRectangles:
            return "four full-width horizontal rectangle panels stacked evenly from top to bottom."
        case .fiveHorizontalPanels:
            return "five full-width horizontal rectangle panels stacked evenly from top to bottom."
        case .fiveClassic:
            return "row 1 has two equal 50-50 rectangle panels side by side; row 2 has one centered wide horizontal rectangle panel; row 3 has two equal 50-50 rectangle panels side by side."
        case .sixSquares:
            return "six equal square panels in a clean 2-column by 3-row grid."
        }
    }

    static func random(for imageCount: Int) -> StoryboardLayoutOption {
        let panelCount = storyboardPanelCount(for: imageCount)
        let matchingLayouts = allCases.filter { $0.panelCount == panelCount }
        return matchingLayouts.randomElement() ?? .fourSquares
    }
}

struct GeneratedStoryboard: Identifiable {
    let id: UUID
    let clientEntryID: UUID?
    let image: UIImage
    let promptText: String
    let artStyle: String
    let panelLayout: String?
    let sourcePhotoCount: Int
    let createdAt: Date
    let imageFileName: String?
    let storagePath: String?
    let cloudSyncState: String?
    let isPrimary: Bool

    init(
        id: UUID = UUID(),
        clientEntryID: UUID? = nil,
        image: UIImage,
        promptText: String,
        artStyle: String,
        panelLayout: String? = nil,
        sourcePhotoCount: Int,
        createdAt: Date = Date(),
        imageFileName: String? = nil,
        storagePath: String? = nil,
        cloudSyncState: String? = nil,
        isPrimary: Bool = true
    ) {
        self.id = id
        self.clientEntryID = clientEntryID
        self.image = image
        self.promptText = promptText
        self.artStyle = artStyle
        self.panelLayout = panelLayout
        self.sourcePhotoCount = sourcePhotoCount
        self.createdAt = createdAt
        self.imageFileName = imageFileName
        self.storagePath = storagePath
        self.cloudSyncState = cloudSyncState
        self.isPrimary = isPrimary
    }

    func withPrimaryStatus(_ isPrimary: Bool) -> GeneratedStoryboard {
        GeneratedStoryboard(
            id: id,
            clientEntryID: clientEntryID,
            image: image,
            promptText: promptText,
            artStyle: artStyle,
            panelLayout: panelLayout,
            sourcePhotoCount: sourcePhotoCount,
            createdAt: createdAt,
            imageFileName: imageFileName,
            storagePath: storagePath,
            cloudSyncState: cloudSyncState,
            isPrimary: isPrimary
        )
    }
}

extension Notification.Name {
    static let storytopiaGeneratedStoryboardsChanged = Notification.Name("StorytopiaGeneratedStoryboardsChanged")
    static let storytopiaGeneratedStoryboardPrimaryChanged = Notification.Name("StorytopiaGeneratedStoryboardPrimaryChanged")
}

struct CreateEntryReferencePhoto: Identifiable {
    static let fileExtension = "jpg"
    static let mimeType = "image/jpeg"

    let id: UUID
    let image: UIImage

    init(id: UUID = UUID(), image: UIImage) {
        self.id = id
        self.image = image
    }
}

enum CharacterRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case mainCharacter
    case supportingCharacter
    case pet
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainCharacter:
            return "Main Character"
        case .supportingCharacter:
            return "Supporting Character"
        case .pet:
            return "Pet"
        case .other:
            return "Other"
        }
    }

    var promptGroupTitle: String {
        switch self {
        case .mainCharacter:
            return "Main character"
        case .supportingCharacter:
            return "Supporting characters"
        case .pet:
            return "Pets"
        case .other:
            return "Other references"
        }
    }

    var sortPriority: Int {
        switch self {
        case .mainCharacter:
            return 0
        case .supportingCharacter:
            return 1
        case .pet:
            return 2
        case .other:
            return 3
        }
    }
}

struct EntryCharacter: Identifiable {
    static let fileExtension = "jpg"
    static let mimeType = "image/jpeg"

    let id: UUID
    var name: String
    var role: CharacterRole
    var sourcePhotoID: UUID?
    var image: UIImage
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        role: CharacterRole,
        sourcePhotoID: UUID? = nil,
        image: UIImage,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.sourcePhotoID = sourcePhotoID
        self.image = image
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum EntryCharacterRules {
    static let maxGenerationImageCount = 5

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func hasDuplicateName(_ name: String, in characters: [EntryCharacter], excluding excludedID: UUID? = nil) -> Bool {
        let normalized = normalizedName(name)
        guard !normalized.isEmpty else {
            return false
        }

        return characters.contains {
            $0.id != excludedID && normalizedName($0.name) == normalized
        }
    }

    static func applyingSingleMainCharacter(_ character: EntryCharacter, to characters: [EntryCharacter]) -> [EntryCharacter] {
        var updatedCharacters = characters.map { existing -> EntryCharacter in
            var updated = existing
            if character.role == .mainCharacter, updated.id != character.id, updated.role == .mainCharacter {
                updated.role = .supportingCharacter
                updated.updatedAt = Date()
            }
            return updated
        }

        if let index = updatedCharacters.firstIndex(where: { $0.id == character.id }) {
            updatedCharacters[index] = character
        } else {
            updatedCharacters.append(character)
        }

        return orderedCharacters(updatedCharacters)
    }

    static func orderedCharacters(_ characters: [EntryCharacter]) -> [EntryCharacter] {
        characters.sorted {
            if $0.role.sortPriority != $1.role.sortPriority {
                return $0.role.sortPriority < $1.role.sortPriority
            }

            return $0.createdAt < $1.createdAt
        }
    }
}

enum OpenAITestConfig {
    // Prototype-only client key. Move image generation server-side before shipping.
    static var apiKey: String {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String,
            !value.isEmpty,
            !value.hasPrefix("$(")
        else {
            return ""
        }

        return value
    }

    static let imageModel = "gpt-image-2"
}

struct CreateEntryDraft: Identifiable {
    let id: UUID
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let photos: [CreateEntryReferencePhoto]
    var characters: [EntryCharacter] = []
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
    let thumbnail: UIImage?
    let createdAt: Date
    let updatedAt: Date
    let displayOrder: Int?
}

enum EntryLocationRecentStore {
    private static let storageKey = "StorytopiaRecentEntryLocations"
    private static let limit = 8

    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    static func add(_ location: String) {
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocation.isEmpty else {
            return
        }

        let existingLocations = all.filter {
            $0.compare(trimmedLocation, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        let updatedLocations = Array(([trimmedLocation] + existingLocations).prefix(limit))
        UserDefaults.standard.set(updatedLocations, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

enum StorytopiaLocalAccountScope {
    private static let activeUserIDKey = "StorytopiaActiveLocalUserID"

    static var currentScopeID: String {
        UserDefaults.standard.string(forKey: activeUserIDKey) ?? "anonymous"
    }

    static var isAnonymous: Bool {
        currentScopeID == "anonymous"
    }

    static func setActiveUserID(_ userID: UUID?) {
        if let userID {
            UserDefaults.standard.set(userID.uuidString.lowercased(), forKey: activeUserIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeUserIDKey)
        }
    }

    static func scopedDirectory(named name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorytopiaAccounts", isDirectory: true)
            .appendingPathComponent(currentScopeID, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func anonymousDirectory(named name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorytopiaAccounts", isDirectory: true)
            .appendingPathComponent("anonymous", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func scopedUserDefaultsKey(_ baseKey: String) -> String {
        "\(baseKey).\(currentScopeID)"
    }

    static func anonymousUserDefaultsKey(_ baseKey: String) -> String {
        "\(baseKey).anonymous"
    }
}

enum CreateEntryDraftStore {
    private static let metadataFileName = "draft.json"
    private static let thumbnailFileName = "thumbnail.jpg"

    static func loadAll() -> [CreateEntryDraft] {
        migrateLegacyDraftIfNeeded()

        guard
            let draftURLs = try? FileManager.default.contentsOfDirectory(
                at: draftsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return draftURLs
            .compactMap { loadDraft(at: $0, includeMedia: true) }
            .sorted(by: sortDrafts)
    }

    /// Loads only the requested drafts. Pass `includeMedia: false` to skip reference
    /// photos and character images (thumbnail + metadata only) for list/grid surfaces.
    static func load(ids: [UUID], includeMedia: Bool = true) -> [CreateEntryDraft] {
        migrateLegacyDraftIfNeeded()

        let uniqueIDs = Array(Set(ids))
        return uniqueIDs
            .compactMap { loadDraft(at: directory(for: $0), includeMedia: includeMedia) }
            .sorted(by: sortDrafts)
    }

    static func hasSavedDrafts() -> Bool {
        if let draftURLs = try? FileManager.default.contentsOfDirectory(
            at: draftsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !draftURLs.isEmpty {
            return true
        }

        if !StorytopiaLocalAccountScope.isAnonymous,
           let anonymousDraftURLs = try? FileManager.default.contentsOfDirectory(
                at: anonymousDraftsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
           ),
           !anonymousDraftURLs.isEmpty {
            return true
        }

        if let legacyDraftURLs = try? FileManager.default.contentsOfDirectory(
            at: legacyDraftsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !legacyDraftURLs.isEmpty {
            return true
        }

        return FileManager.default.fileExists(atPath: legacyDraftDirectory.appendingPathComponent(metadataFileName).path)
    }

    static func load(id: UUID) -> CreateEntryDraft? {
        migrateLegacyDraftIfNeeded()
        return loadDraft(at: directory(for: id), includeMedia: true)
    }

    @discardableResult
    static func save(
        id: UUID?,
        title: String,
        text: String,
        richText: NotebookRichTextDocument? = nil,
        photos: [UIImage],
        characters: [EntryCharacter] = [],
        artStyle: String,
        location: String,
        date: Date,
        datePrecision: EntryDatePrecision = .exact,
        savesDraft: Bool,
        isPrivate: Bool,
        status: JournalEntryStatus = .draft,
        fontChoiceRawValue: String? = nil,
        textColorIndex: Int? = nil,
        textSize: Double? = nil,
        paperStyleRawValue: String? = nil,
        paperColorIndex: Int? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false,
        isHighlighted: Bool = false,
        textAlignmentRawValue: String = "leading",
        thumbnail: UIImage? = nil
    ) -> UUID? {
        save(
            id: id,
            title: title,
            text: text,
            richText: richText,
            referencePhotos: photos.map { CreateEntryReferencePhoto(image: $0) },
            characters: characters,
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
            thumbnail: thumbnail
        )
    }

    @discardableResult
    static func save(
        id: UUID?,
        title: String,
        text: String,
        richText: NotebookRichTextDocument? = nil,
        referencePhotos: [CreateEntryReferencePhoto],
        characters: [EntryCharacter] = [],
        artStyle: String,
        location: String,
        date: Date,
        datePrecision: EntryDatePrecision = .exact,
        savesDraft: Bool,
        isPrivate: Bool,
        status: JournalEntryStatus = .draft,
        fontChoiceRawValue: String? = nil,
        textColorIndex: Int? = nil,
        textSize: Double? = nil,
        paperStyleRawValue: String? = nil,
        paperColorIndex: Int? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false,
        isHighlighted: Bool = false,
        textAlignmentRawValue: String = "leading",
        thumbnail: UIImage? = nil
    ) -> UUID? {
        let draftID = id ?? UUID()
        let draftDirectory = directory(for: draftID)
        let existingDraft = id.flatMap { loadDraft(at: directory(for: $0), includeMedia: true) }

        try? FileManager.default.removeItem(at: draftDirectory)

        do {
            try FileManager.default.createDirectory(
                at: draftDirectory,
                withIntermediateDirectories: true
            )

            var photoMetadata: [CreateEntryDraftPhotoMetadata] = []
            for (index, photo) in referencePhotos.enumerated() {
                guard let data = photo.image.storytopiaPreparedJPEGData(compressionQuality: 0.88) else {
                    continue
                }

                let fileName = "photo-\(index)-\(photo.id.uuidString).jpg"
                try data.write(
                    to: draftDirectory.appendingPathComponent(fileName),
                    options: [.atomic]
                )
                photoMetadata.append(
                    CreateEntryDraftPhotoMetadata(
                        id: photo.id,
                        fileName: fileName,
                        mimeType: CreateEntryReferencePhoto.mimeType
                    )
                )
            }

            var characterMetadata: [CreateEntryDraftCharacterMetadata] = []
            for character in EntryCharacterRules.orderedCharacters(characters) {
                guard let data = character.image.storytopiaPreparedJPEGData(maxDimension: 1024, compressionQuality: 0.88) else {
                    continue
                }

                let fileName = "character-\(character.id.uuidString).jpg"
                try data.write(
                    to: draftDirectory.appendingPathComponent(fileName),
                    options: [.atomic]
                )
                characterMetadata.append(
                    CreateEntryDraftCharacterMetadata(
                        id: character.id,
                        name: character.name,
                        role: character.role,
                        sourcePhotoID: character.sourcePhotoID,
                        fileName: fileName,
                        mimeType: EntryCharacter.mimeType,
                        createdAt: character.createdAt,
                        updatedAt: character.updatedAt
                    )
                )
            }

            let thumbnailToSave = thumbnail ?? existingDraft?.thumbnail
            if let thumbnailData = thumbnailToSave?.storytopiaPreparedJPEGData(compressionQuality: 0.86) {
                try thumbnailData.write(
                    to: draftDirectory.appendingPathComponent(thumbnailFileName),
                    options: [.atomic]
                )
            }

            let now = Date()
            let metadata = CreateEntryDraftMetadata(
                id: draftID,
                title: title,
                text: text,
                richText: richText,
                photoFileNames: photoMetadata.map(\.fileName),
                referencePhotos: photoMetadata,
                characters: characterMetadata,
                artStyle: artStyle,
                location: location,
                date: date,
                datePrecision: datePrecision,
                savesDraft: savesDraft,
                isPrivate: isPrivate,
                status: status.rawValue,
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
                createdAt: existingDraft?.createdAt ?? now,
                updatedAt: now,
                displayOrder: existingDraft?.displayOrder ?? defaultDisplayOrder(for: now)
            )
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(
                to: draftDirectory.appendingPathComponent(metadataFileName),
                options: [.atomic]
            )
            return draftID
        } catch {
            try? FileManager.default.removeItem(at: draftDirectory)
            return nil
        }
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    static func saveThumbnail(_ thumbnail: UIImage, for id: UUID) {
        guard let thumbnailData = thumbnail.storytopiaPreparedJPEGData(compressionQuality: 0.86) else {
            return
        }

        try? thumbnailData.write(
            to: directory(for: id).appendingPathComponent(thumbnailFileName),
            options: [.atomic]
        )
    }

    static func saveOrder(_ orderedIDs: [UUID]) {
        for (displayOrder, id) in orderedIDs.enumerated() {
            let metadataURL = directory(for: id).appendingPathComponent(metadataFileName)
            guard
                let data = try? Data(contentsOf: metadataURL),
                var metadata = try? JSONDecoder().decode(CreateEntryDraftMetadata.self, from: data)
            else {
                continue
            }

            metadata.displayOrder = displayOrder

            guard let metadataData = try? JSONEncoder().encode(metadata) else {
                continue
            }

            try? metadataData.write(to: metadataURL, options: [.atomic])
        }
    }

    private static func loadDraft(at draftDirectory: URL, includeMedia: Bool = true) -> CreateEntryDraft? {
        let metadataURL = draftDirectory.appendingPathComponent(metadataFileName)
        guard
            let data = try? Data(contentsOf: metadataURL),
            var metadata = try? JSONDecoder().decode(CreateEntryDraftMetadata.self, from: data)
        else {
            return nil
        }

        let photoMetadata = metadata.normalizedPhotoMetadata()
        if metadata.referencePhotos == nil, !photoMetadata.isEmpty {
            metadata.referencePhotos = photoMetadata
            if let updatedData = try? JSONEncoder().encode(metadata) {
                try? updatedData.write(to: metadataURL, options: [.atomic])
            }
        }

        let photos: [CreateEntryReferencePhoto]
        let characters: [EntryCharacter]
        if includeMedia {
            photos = photoMetadata.compactMap { item -> CreateEntryReferencePhoto? in
                let fileName = item.fileName
                let photoURL = draftDirectory.appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: photoURL) else {
                    return nil
                }
                return UIImage(data: data).map {
                    CreateEntryReferencePhoto(id: item.id, image: $0)
                }
            }

            characters = (metadata.characters ?? []).compactMap { item -> EntryCharacter? in
                let imageURL = draftDirectory.appendingPathComponent(item.fileName)
                guard
                    let imageData = try? Data(contentsOf: imageURL),
                    let image = UIImage(data: imageData)
                else {
                    return nil
                }

                return EntryCharacter(
                    id: item.id,
                    name: item.name,
                    role: item.role,
                    sourcePhotoID: item.sourcePhotoID,
                    image: image,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt
                )
            }
        } else {
            photos = []
            characters = []
        }

        let thumbnailURL = draftDirectory.appendingPathComponent(thumbnailFileName)
        let thumbnail = (try? Data(contentsOf: thumbnailURL)).flatMap(UIImage.init(data:))

        return CreateEntryDraft(
            id: metadata.id ?? UUID(),
            title: metadata.title,
            text: metadata.text,
            richText: metadata.richText,
            photos: photos,
            characters: EntryCharacterRules.orderedCharacters(characters),
            artStyle: metadata.artStyle ?? "Anime",
            location: metadata.location ?? "",
            date: metadata.date ?? Date(),
            datePrecision: metadata.datePrecision ?? .exact,
            savesDraft: metadata.savesDraft ?? true,
            isPrivate: metadata.isPrivate ?? false,
            status: metadata.normalizedStatus,
            fontChoiceRawValue: metadata.fontChoiceRawValue,
            textColorIndex: metadata.textColorIndex,
            textSize: metadata.textSize,
            paperStyleRawValue: metadata.paperStyleRawValue,
            paperColorIndex: metadata.paperColorIndex,
            isBold: metadata.isBold ?? false,
            isItalic: metadata.isItalic ?? false,
            isUnderlined: metadata.isUnderlined ?? false,
            isStrikethrough: metadata.isStrikethrough ?? false,
            isHighlighted: metadata.isHighlighted ?? false,
            textAlignmentRawValue: metadata.textAlignmentRawValue ?? "leading",
            thumbnail: thumbnail,
            createdAt: metadata.createdAt ?? Date(),
            updatedAt: metadata.updatedAt ?? metadata.createdAt ?? Date(),
            displayOrder: metadata.displayOrder
        )
    }

    private static func sortDrafts(_ lhs: CreateEntryDraft, _ rhs: CreateEntryDraft) -> Bool {
        switch (lhs.displayOrder, rhs.displayOrder) {
        case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
            return lhsOrder < rhsOrder
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func defaultDisplayOrder(for date: Date) -> Int {
        -Int(date.timeIntervalSinceReferenceDate * 1000)
    }

    private static func migrateLegacyDraftIfNeeded() {
        if !StorytopiaLocalAccountScope.isAnonymous,
           let anonymousDraftURLs = try? FileManager.default.contentsOfDirectory(
                at: anonymousDraftsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
           ) {
            mergeLegacyDrafts(anonymousDraftURLs.compactMap { loadDraft(at: $0, includeMedia: true) })
        }

        if let legacyDraftURLs = try? FileManager.default.contentsOfDirectory(
            at: legacyDraftsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let legacyDrafts = legacyDraftURLs.compactMap { loadDraft(at: $0, includeMedia: true) }
            if !legacyDrafts.isEmpty {
                mergeLegacyDrafts(legacyDrafts)
            }
        }

        guard !FileManager.default.fileExists(atPath: draftsDirectory.path) else {
            return
        }

        guard
            let legacyDraft = loadDraft(at: legacyDraftDirectory, includeMedia: true)
        else {
            return
        }

        _ = save(
            id: nil,
            title: legacyDraft.title,
            text: legacyDraft.text,
            richText: legacyDraft.richText,
            referencePhotos: legacyDraft.photos,
            characters: legacyDraft.characters,
            artStyle: legacyDraft.artStyle,
            location: legacyDraft.location,
            date: legacyDraft.date,
            savesDraft: legacyDraft.savesDraft,
            isPrivate: legacyDraft.isPrivate,
            fontChoiceRawValue: legacyDraft.fontChoiceRawValue,
            textColorIndex: legacyDraft.textColorIndex,
            textSize: legacyDraft.textSize,
            paperStyleRawValue: legacyDraft.paperStyleRawValue,
            paperColorIndex: legacyDraft.paperColorIndex,
            isBold: legacyDraft.isBold,
            isItalic: legacyDraft.isItalic,
            isUnderlined: legacyDraft.isUnderlined,
            isStrikethrough: legacyDraft.isStrikethrough,
            isHighlighted: legacyDraft.isHighlighted,
            textAlignmentRawValue: legacyDraft.textAlignmentRawValue
        )
        try? FileManager.default.removeItem(at: legacyDraftDirectory)
    }

    private static func mergeLegacyDrafts(_ legacyDrafts: [CreateEntryDraft]) {
        for legacyDraft in legacyDrafts {
            guard !FileManager.default.fileExists(atPath: directory(for: legacyDraft.id).path) else {
                continue
            }

            _ = save(
                id: legacyDraft.id,
                title: legacyDraft.title,
                text: legacyDraft.text,
                richText: legacyDraft.richText,
                referencePhotos: legacyDraft.photos,
                characters: legacyDraft.characters,
                artStyle: legacyDraft.artStyle,
                location: legacyDraft.location,
                date: legacyDraft.date,
                datePrecision: legacyDraft.datePrecision,
                savesDraft: legacyDraft.savesDraft,
                isPrivate: legacyDraft.isPrivate,
                status: JournalEntryStatus(rawValue: legacyDraft.status) ?? .draft,
                fontChoiceRawValue: legacyDraft.fontChoiceRawValue,
                textColorIndex: legacyDraft.textColorIndex,
                textSize: legacyDraft.textSize,
                paperStyleRawValue: legacyDraft.paperStyleRawValue,
                paperColorIndex: legacyDraft.paperColorIndex,
                isBold: legacyDraft.isBold,
                isItalic: legacyDraft.isItalic,
                isUnderlined: legacyDraft.isUnderlined,
                isStrikethrough: legacyDraft.isStrikethrough,
                isHighlighted: legacyDraft.isHighlighted,
                textAlignmentRawValue: legacyDraft.textAlignmentRawValue,
                thumbnail: legacyDraft.thumbnail
            )
        }
    }

    private static func directory(for id: UUID) -> URL {
        draftsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static var draftsDirectory: URL {
        StorytopiaLocalAccountScope.scopedDirectory(named: "CreateEntryDrafts")
    }

    private static var legacyDraftDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CreateEntryDraft", isDirectory: true)
    }

    private static var legacyDraftsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CreateEntryDrafts", isDirectory: true)
    }

    private static var anonymousDraftsDirectory: URL {
        StorytopiaLocalAccountScope.anonymousDirectory(named: "CreateEntryDrafts")
    }
}

private struct CreateEntryDraftMetadata: Codable {
    var id: UUID?
    var title: String
    var text: String
    var richText: NotebookRichTextDocument?
    var photoFileNames: [String]
    var referencePhotos: [CreateEntryDraftPhotoMetadata]?
    var characters: [CreateEntryDraftCharacterMetadata]?
    var artStyle: String?
    var location: String?
    var date: Date?
    var datePrecision: EntryDatePrecision?
    var savesDraft: Bool?
    var isPrivate: Bool?
    var status: String?
    var fontChoiceRawValue: String?
    var textColorIndex: Int?
    var textSize: Double?
    var paperStyleRawValue: String?
    var paperColorIndex: Int?
    var isBold: Bool?
    var isItalic: Bool?
    var isUnderlined: Bool?
    var isStrikethrough: Bool?
    var isHighlighted: Bool?
    var textAlignmentRawValue: String?
    var createdAt: Date?
    var updatedAt: Date?
    var displayOrder: Int?

    func normalizedPhotoMetadata() -> [CreateEntryDraftPhotoMetadata] {
        if let referencePhotos {
            return referencePhotos
        }

        return photoFileNames.map {
            CreateEntryDraftPhotoMetadata(
                id: UUID(),
                fileName: $0,
                mimeType: CreateEntryReferencePhoto.mimeType
            )
        }
    }

    var normalizedStatus: String {
        guard
            let status,
            JournalEntryStatus(rawValue: status) != nil
        else {
            return JournalEntryStatus.draft.rawValue
        }

        return status
    }
}

private struct CreateEntryDraftPhotoMetadata: Codable {
    var id: UUID
    var fileName: String
    var mimeType: String
}

private struct CreateEntryDraftCharacterMetadata: Codable {
    var id: UUID
    var name: String
    var role: CharacterRole
    var sourcePhotoID: UUID?
    var fileName: String
    var mimeType: String
    var createdAt: Date
    var updatedAt: Date
}

enum GeneratedStoryboardStore {
    private static let metadataKey = "StorytopiaGeneratedStoryboardMetadata"

    static func load() -> [GeneratedStoryboard] {
        loadStoryboards(matching: nil)
    }

    /// Loads only storyboards whose `clientEntryID` is in `clientEntryIDs`.
    static func load(clientEntryIDs: Set<UUID>) -> [GeneratedStoryboard] {
        guard !clientEntryIDs.isEmpty else {
            return []
        }

        return loadStoryboards(matching: clientEntryIDs)
    }

    /// Counts matching storyboards from metadata without decoding images.
    static func count(clientEntryIDs: Set<UUID>) -> Int {
        guard !clientEntryIDs.isEmpty else {
            return 0
        }

        migrateLegacyStoryboardsIfNeeded()

        guard
            let metadataData = UserDefaults.standard.data(forKey: scopedMetadataKey),
            let metadata = try? JSONDecoder().decode([GeneratedStoryboardMetadata].self, from: metadataData)
        else {
            return 0
        }

        return metadata.reduce(into: 0) { count, item in
            guard let clientEntryID = item.clientEntryID, clientEntryIDs.contains(clientEntryID) else {
                return
            }
            count += 1
        }
    }

    private static func loadStoryboards(matching clientEntryIDs: Set<UUID>?) -> [GeneratedStoryboard] {
        migrateLegacyStoryboardsIfNeeded()

        guard
            let metadataData = UserDefaults.standard.data(forKey: scopedMetadataKey),
            let metadata = try? JSONDecoder().decode([GeneratedStoryboardMetadata].self, from: metadataData)
        else {
            return []
        }

        let filteredMetadata: [GeneratedStoryboardMetadata]
        if let clientEntryIDs {
            filteredMetadata = metadata.filter { item in
                guard let clientEntryID = item.clientEntryID else {
                    return false
                }
                return clientEntryIDs.contains(clientEntryID)
            }
        } else {
            filteredMetadata = metadata
        }

        return filteredMetadata.compactMap { item in
            let imageURL = imagesDirectory.appendingPathComponent(item.imageFileName)
            guard
                let imageData = try? Data(contentsOf: imageURL),
                let image = UIImage(data: imageData)
            else {
                return nil
            }

            return GeneratedStoryboard(
                id: item.id,
                clientEntryID: item.clientEntryID,
                image: image,
                promptText: item.promptText,
                artStyle: item.artStyle,
                panelLayout: item.panelLayout,
                sourcePhotoCount: item.sourcePhotoCount,
                createdAt: item.createdAt,
                imageFileName: item.imageFileName,
                storagePath: item.storagePath,
                cloudSyncState: item.cloudSyncState,
                isPrimary: item.isPrimary ?? true
            )
        }
    }

    static func save(_ storyboards: [GeneratedStoryboard]) {
        migrateLegacyStoryboardsIfNeeded()

        let metadata = storyboards.compactMap { storyboard -> GeneratedStoryboardMetadata? in
            guard let imageFileName = storyboard.imageFileName else {
                return nil
            }

            return GeneratedStoryboardMetadata(
                id: storyboard.id,
                clientEntryID: storyboard.clientEntryID,
                promptText: storyboard.promptText,
                artStyle: storyboard.artStyle,
                panelLayout: storyboard.panelLayout,
                sourcePhotoCount: storyboard.sourcePhotoCount,
                createdAt: storyboard.createdAt,
                imageFileName: imageFileName,
                storagePath: storyboard.storagePath,
                cloudSyncState: storyboard.cloudSyncState,
                isPrimary: storyboard.isPrimary
            )
        }

        guard let metadataData = try? JSONEncoder().encode(metadata) else {
            return
        }

        UserDefaults.standard.set(metadataData, forKey: scopedMetadataKey)
        NotificationCenter.default.post(name: .storytopiaGeneratedStoryboardsChanged, object: nil)
    }

    static func delete(_ storyboards: [GeneratedStoryboard]) {
        for storyboard in storyboards {
            guard let imageFileName = storyboard.imageFileName else {
                continue
            }

            let imageURL = imagesDirectory.appendingPathComponent(imageFileName)
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    static func persistedStoryboard(
        image: UIImage,
        clientEntryID: UUID,
        promptText: String,
        artStyle: String,
        panelLayout: String?,
        sourcePhotoCount: Int,
        id: UUID = UUID(),
        storagePath: String? = nil,
        cloudSyncState: String? = nil,
        isPrimary: Bool = true
    ) throws -> GeneratedStoryboard {
        try FileManager.default.createDirectory(
            at: imagesDirectory,
            withIntermediateDirectories: true
        )

        let imageFileName = "\(id.uuidString).jpg"
        let imageURL = imagesDirectory.appendingPathComponent(imageFileName)

        guard let imageData = image.storytopiaPreparedJPEGData(compressionQuality: 0.9) else {
            throw StoryboardGenerationError.invalidRequest
        }

        try imageData.write(to: imageURL, options: [.atomic])

        return GeneratedStoryboard(
            id: id,
            clientEntryID: clientEntryID,
            image: image,
            promptText: promptText,
            artStyle: artStyle,
            panelLayout: panelLayout,
            sourcePhotoCount: sourcePhotoCount,
            imageFileName: imageFileName,
            storagePath: storagePath,
            cloudSyncState: cloudSyncState,
            isPrimary: isPrimary
        )
    }

    static func cachedStoryboard(_ storyboard: GeneratedStoryboard) throws -> GeneratedStoryboard {
        guard storyboard.imageFileName == nil else {
            return storyboard
        }

        guard let clientEntryID = storyboard.clientEntryID else {
            return storyboard
        }

        return try persistedStoryboard(
            image: storyboard.image,
            clientEntryID: clientEntryID,
            promptText: storyboard.promptText,
            artStyle: storyboard.artStyle,
            panelLayout: storyboard.panelLayout,
            sourcePhotoCount: storyboard.sourcePhotoCount,
            id: storyboard.id,
            storagePath: storyboard.storagePath,
            cloudSyncState: storyboard.cloudSyncState,
            isPrimary: storyboard.isPrimary
        )
    }

    static func cachedStoryboards(_ storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        storyboards.compactMap { storyboard in
            do {
                return try cachedStoryboard(storyboard)
            } catch {
                return nil
            }
        }
    }

    static func merging(_ storyboard: GeneratedStoryboard, into storyboards: [GeneratedStoryboard]) -> [GeneratedStoryboard] {
        var merged = storyboards.map { existing in
            guard
                storyboard.isPrimary,
                existing.id != storyboard.id,
                existing.clientEntryID == storyboard.clientEntryID
            else {
                return existing
            }

            return GeneratedStoryboard(
                id: existing.id,
                clientEntryID: existing.clientEntryID,
                image: existing.image,
                promptText: existing.promptText,
                artStyle: existing.artStyle,
                panelLayout: existing.panelLayout,
                sourcePhotoCount: existing.sourcePhotoCount,
                createdAt: existing.createdAt,
                imageFileName: existing.imageFileName,
                storagePath: existing.storagePath,
                cloudSyncState: existing.cloudSyncState,
                isPrimary: false
            )
        }
        if let index = merged.firstIndex(where: { $0.id == storyboard.id }) {
            merged[index] = storyboard
        } else {
            merged.insert(storyboard, at: 0)
        }
        return merged
    }

    @discardableResult
    static func markPrimary(storyboardID: UUID, clientEntryID: UUID) -> [GeneratedStoryboard] {
        let updatedStoryboards = load().map { storyboard in
            guard storyboard.clientEntryID == clientEntryID else {
                return storyboard
            }

            return storyboard.withPrimaryStatus(storyboard.id == storyboardID)
        }

        save(updatedStoryboards)
        NotificationCenter.default.post(
            name: .storytopiaGeneratedStoryboardPrimaryChanged,
            object: nil,
            userInfo: [
                "storyboardID": storyboardID,
                "clientEntryID": clientEntryID
            ]
        )
        return updatedStoryboards
    }

    private static var imagesDirectory: URL {
        StorytopiaLocalAccountScope.scopedDirectory(named: "GeneratedStoryboards")
    }

    private static var legacyImagesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeneratedStoryboards", isDirectory: true)
    }

    private static var scopedMetadataKey: String {
        StorytopiaLocalAccountScope.scopedUserDefaultsKey(metadataKey)
    }

    private static func migrateLegacyStoryboardsIfNeeded() {
        if !StorytopiaLocalAccountScope.isAnonymous,
           let anonymousMetadataData = UserDefaults.standard.data(forKey: StorytopiaLocalAccountScope.anonymousUserDefaultsKey(metadataKey)) {
            copyImages(from: StorytopiaLocalAccountScope.anonymousDirectory(named: "GeneratedStoryboards"))
            mergeMetadataData(anonymousMetadataData)
        }

        if let legacyMetadataData = UserDefaults.standard.data(forKey: metadataKey) {
            copyImages(from: legacyImagesDirectory)
            mergeMetadataData(legacyMetadataData)
        }
    }

    private static func copyImages(from sourceDirectory: URL) {
        try? FileManager.default.createDirectory(
            at: imagesDirectory,
            withIntermediateDirectories: true
        )

        if let imageURLs = try? FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for imageURL in imageURLs {
                let destinationURL = imagesDirectory.appendingPathComponent(imageURL.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    continue
                }
                try? FileManager.default.copyItem(at: imageURL, to: destinationURL)
            }
        }
    }

    private static func mergeMetadataData(_ metadataData: Data) {
        guard let sourceMetadata = try? JSONDecoder().decode([GeneratedStoryboardMetadata].self, from: metadataData) else {
            return
        }

        let existingMetadata: [GeneratedStoryboardMetadata]
        if let existingMetadataData = UserDefaults.standard.data(forKey: scopedMetadataKey),
           let decodedMetadata = try? JSONDecoder().decode([GeneratedStoryboardMetadata].self, from: existingMetadataData) {
            existingMetadata = decodedMetadata
        } else {
            existingMetadata = []
        }

        let existingIDs = Set(existingMetadata.map(\.id))
        let metadataToAdd = sourceMetadata.filter { !existingIDs.contains($0.id) }
        guard !metadataToAdd.isEmpty else {
            return
        }

        let mergedMetadata = metadataToAdd + existingMetadata
        guard let mergedData = try? JSONEncoder().encode(mergedMetadata) else {
            return
        }

        UserDefaults.standard.set(mergedData, forKey: scopedMetadataKey)
    }
}

struct GeneratedStoryboardMetadata: Codable {
    let id: UUID
    let clientEntryID: UUID?
    let promptText: String
    let artStyle: String
    let panelLayout: String?
    let sourcePhotoCount: Int
    let createdAt: Date
    let imageFileName: String
    let storagePath: String?
    let cloudSyncState: String?
    let isPrimary: Bool?
}

enum StoryboardGenerationError: LocalizedError {
    case missingAPIKey
    case invalidRequest
    case invalidResponse
    case noGeneratedImage
    case openAIMessage(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key before generating a storyboard."
        case .invalidRequest:
            return "The storyboard request could not be prepared."
        case .invalidResponse:
            return "OpenAI returned a response Storytopia could not read."
        case .noGeneratedImage:
            return "OpenAI did not return a storyboard image."
        case .openAIMessage(let message):
            return message
        }
    }
}
