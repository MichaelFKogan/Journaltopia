import Foundation
import Supabase
import UIKit

struct EntryReferencePhoto: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let entryID: UUID
    let clientEntryID: UUID
    let storagePath: String
    let mimeType: String
    let byteSize: Int
    let width: Int
    let height: Int
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case entryID = "entry_id"
        case clientEntryID = "client_entry_id"
        case storagePath = "storage_path"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case width
        case height
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct ReferencePhotoUpsert: Encodable, Sendable {
    let id: UUID
    let userID: UUID
    let entryID: UUID
    let clientEntryID: UUID
    let storagePath: String
    let mimeType: String
    let byteSize: Int
    let width: Int
    let height: Int
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case entryID = "entry_id"
        case clientEntryID = "client_entry_id"
        case storagePath = "storage_path"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case width
        case height
        case sortOrder = "sort_order"
    }
}

enum SupabaseReferencePhotoError: LocalizedError {
    case invalidImage
    case syncFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "One of the reference photos could not be prepared for upload."
        case .syncFailed:
            return "Reference photos could not be synced. Please try again."
        }
    }
}

enum SupabaseStorageImageCache {
    static func data(bucketName: String, storagePath: String) -> Data? {
        try? Data(contentsOf: fileURL(bucketName: bucketName, storagePath: storagePath))
    }

    static func store(_ data: Data, bucketName: String, storagePath: String) {
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try data.write(
                to: fileURL(bucketName: bucketName, storagePath: storagePath),
                options: [.atomic]
            )
        } catch {
            print("[Storytopia] Supabase storage image cache write failed: \(error.localizedDescription)")
        }
    }

    static func remove(bucketName: String, storagePath: String) {
        try? FileManager.default.removeItem(at: fileURL(bucketName: bucketName, storagePath: storagePath))
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorytopiaSupabaseImageCache", isDirectory: true)
    }

    private static func fileURL(bucketName: String, storagePath: String) -> URL {
        cacheDirectory.appendingPathComponent(cacheKey(bucketName: bucketName, storagePath: storagePath))
    }

    private static func cacheKey(bucketName: String, storagePath: String) -> String {
        "\(bucketName)__\(storagePath)"
            .map { character in
                character.isLetter || character.isNumber || character == "." ? character : "_"
            }
            .reduce(into: "") { $0.append($1) }
    }
}

struct SupabaseReferencePhotoService {
    private let client: SupabaseClient
    private let bucketName = "storytopia-media"

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func syncReferencePhotos(
        entry: JournalEntry,
        photos: [CreateEntryReferencePhoto]
    ) async throws {
        do {
            let existingPhotos = try await existingReferencePhotos(entryID: entry.id)
            let existingPhotoByID = Dictionary(uniqueKeysWithValues: existingPhotos.map { ($0.id, $0) })
            let localPhotoIDs = Set(photos.map(\.id))
            let photosToDelete = existingPhotos.filter { !localPhotoIDs.contains($0.id) }

            for photo in photosToDelete {
                try await deleteCloudPhoto(photo)
            }

            for (index, photo) in photos.enumerated() {
                if let existingPhoto = existingPhotoByID[photo.id] {
                    guard existingPhoto.sortOrder != index else {
                        continue
                    }

                    try await client
                        .from("entry_reference_photos")
                        .upsert(
                            ReferencePhotoUpsert(
                                id: existingPhoto.id,
                                userID: existingPhoto.userID,
                                entryID: existingPhoto.entryID,
                                clientEntryID: existingPhoto.clientEntryID,
                                storagePath: existingPhoto.storagePath,
                                mimeType: existingPhoto.mimeType,
                                byteSize: existingPhoto.byteSize,
                                width: existingPhoto.width,
                                height: existingPhoto.height,
                                sortOrder: index
                            ),
                            onConflict: "id"
                        )
                        .execute()
                    continue
                }

                let upload = try makeUpload(
                    photo: photo,
                    userID: entry.userID,
                    clientEntryID: entry.clientEntryID,
                    sortOrder: index
                )

                try await client.storage
                    .from(bucketName)
                    .upload(
                        upload.storagePath,
                        data: upload.data,
                        options: FileOptions(
                            cacheControl: "31536000",
                            contentType: CreateEntryReferencePhoto.mimeType,
                            upsert: true
                        )
                    )

                try await client
                    .from("entry_reference_photos")
                    .upsert(
                        ReferencePhotoUpsert(
                            id: photo.id,
                            userID: entry.userID,
                            entryID: entry.id,
                            clientEntryID: entry.clientEntryID,
                            storagePath: upload.storagePath,
                            mimeType: CreateEntryReferencePhoto.mimeType,
                            byteSize: upload.data.count,
                            width: upload.width,
                            height: upload.height,
                            sortOrder: index
                        ),
                        onConflict: "id"
                    )
                    .execute()
            }
        } catch let error as SupabaseReferencePhotoError {
            throw error
        } catch {
            throw SupabaseReferencePhotoError.syncFailed
        }
    }

    func loadReferencePhotos(entryID: UUID) async throws -> [CreateEntryReferencePhoto] {
        do {
            let rows = try await existingReferencePhotos(entryID: entryID)
                .sorted { $0.sortOrder < $1.sortOrder }

            var photos: [CreateEntryReferencePhoto] = []
            for row in rows {
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
                photos.append(CreateEntryReferencePhoto(id: row.id, image: image))
            }

            return photos
        } catch {
            throw SupabaseReferencePhotoError.syncFailed
        }
    }

    func deleteReferencePhotos(entryID: UUID) async throws {
        do {
            let rows = try await existingReferencePhotos(entryID: entryID)
            for row in rows {
                try await deleteCloudPhoto(row)
            }
        } catch let error as SupabaseReferencePhotoError {
            throw error
        } catch {
            throw SupabaseReferencePhotoError.syncFailed
        }
    }

    func deleteReferencePhotos(clientEntryID: UUID) async throws {
        do {
            let rows = try await existingReferencePhotos(clientEntryID: clientEntryID)
            for row in rows {
                try await deleteCloudPhoto(row)
            }
        } catch let error as SupabaseReferencePhotoError {
            throw error
        } catch {
            throw SupabaseReferencePhotoError.syncFailed
        }
    }

    func existingReferencePhotos(entryID: UUID) async throws -> [EntryReferencePhoto] {
        try await client
            .from("entry_reference_photos")
            .select()
            .eq("entry_id", value: entryID)
            .execute()
            .value
    }

    func existingReferencePhotos(clientEntryID: UUID) async throws -> [EntryReferencePhoto] {
        try await client
            .from("entry_reference_photos")
            .select()
            .eq("client_entry_id", value: clientEntryID)
            .execute()
            .value
    }

    private func deleteCloudPhoto(_ photo: EntryReferencePhoto) async throws {
        do {
            try await client.storage
                .from(bucketName)
                .remove(paths: [photo.storagePath])
        } catch let error as StorageError where error.statusCode == "404" {
            // Missing objects are already deleted; continue so retries can heal partial work.
        }

        try await client
            .from("entry_reference_photos")
            .delete()
            .eq("id", value: photo.id)
            .execute()
    }

    private func makeUpload(
        photo: CreateEntryReferencePhoto,
        userID: UUID,
        clientEntryID: UUID,
        sortOrder: Int
    ) throws -> ReferencePhotoUpload {
        guard let data = photo.image.storytopiaPreparedJPEGData(compressionQuality: 0.88) else {
            throw SupabaseReferencePhotoError.invalidImage
        }
        guard let normalizedImage = UIImage(data: data) else {
            throw SupabaseReferencePhotoError.invalidImage
        }

        let storagePath = [
            userID.uuidString.lowercased(),
            "entries",
            clientEntryID.uuidString.lowercased(),
            "references",
            "\(photo.id.uuidString.lowercased()).\(CreateEntryReferencePhoto.fileExtension)"
        ].joined(separator: "/")

        return ReferencePhotoUpload(
            data: data,
            storagePath: storagePath,
            width: normalizedImage.cgImage?.width ?? Int(normalizedImage.size.width.rounded()),
            height: normalizedImage.cgImage?.height ?? Int(normalizedImage.size.height.rounded()),
            sortOrder: sortOrder
        )
    }
}

private struct ReferencePhotoUpload {
    let data: Data
    let storagePath: String
    let width: Int
    let height: Int
    let sortOrder: Int
}

struct EntryCharacterPhoto: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let entryID: UUID
    let clientEntryID: UUID
    let name: String
    let role: CharacterRole
    let sourcePhotoID: UUID?
    let storagePath: String
    let mimeType: String
    let byteSize: Int
    let width: Int
    let height: Int
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case entryID = "entry_id"
        case clientEntryID = "client_entry_id"
        case name
        case role
        case sourcePhotoID = "source_photo_id"
        case storagePath = "storage_path"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case width
        case height
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct EntryCharacterUpsert: Encodable, Sendable {
    let id: UUID
    let userID: UUID
    let entryID: UUID
    let clientEntryID: UUID
    let name: String
    let role: CharacterRole
    let sourcePhotoID: UUID?
    let storagePath: String
    let mimeType: String
    let byteSize: Int
    let width: Int
    let height: Int
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case entryID = "entry_id"
        case clientEntryID = "client_entry_id"
        case name
        case role
        case sourcePhotoID = "source_photo_id"
        case storagePath = "storage_path"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case width
        case height
        case sortOrder = "sort_order"
    }
}

enum SupabaseEntryCharacterError: LocalizedError {
    case invalidImage
    case syncFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "One of the character photos could not be prepared for upload."
        case .syncFailed:
            return "Character photos could not be synced. Please try again."
        }
    }
}

struct SupabaseEntryCharacterService {
    private let client: SupabaseClient
    private let bucketName = "storytopia-media"

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    func syncCharacters(
        entry: JournalEntry,
        characters: [EntryCharacter]
    ) async throws {
        do {
            let orderedCharacters = EntryCharacterRules.orderedCharacters(characters)
            let existingCharacters = try await existingCharacters(entryID: entry.id)
            let localCharacterIDs = Set(orderedCharacters.map(\.id))
            let charactersToDelete = existingCharacters.filter { !localCharacterIDs.contains($0.id) }

            for character in charactersToDelete {
                try await deleteCloudCharacter(character)
            }

            for (index, character) in orderedCharacters.enumerated() {
                let upload = try makeUpload(
                    character: character,
                    userID: entry.userID,
                    clientEntryID: entry.clientEntryID,
                    sortOrder: index
                )

                try await client.storage
                    .from(bucketName)
                    .upload(
                        upload.storagePath,
                        data: upload.data,
                        options: FileOptions(
                            cacheControl: "31536000",
                            contentType: EntryCharacter.mimeType,
                            upsert: true
                        )
                    )

                try await client
                    .from("entry_characters")
                    .upsert(
                        EntryCharacterUpsert(
                            id: character.id,
                            userID: entry.userID,
                            entryID: entry.id,
                            clientEntryID: entry.clientEntryID,
                            name: character.name,
                            role: character.role,
                            sourcePhotoID: character.sourcePhotoID,
                            storagePath: upload.storagePath,
                            mimeType: EntryCharacter.mimeType,
                            byteSize: upload.data.count,
                            width: upload.width,
                            height: upload.height,
                            sortOrder: index
                        ),
                        onConflict: "id"
                    )
                    .execute()
            }
        } catch let error as SupabaseEntryCharacterError {
            throw error
        } catch {
            throw SupabaseEntryCharacterError.syncFailed
        }
    }

    func loadCharacters(entryID: UUID) async throws -> [EntryCharacter] {
        do {
            let rows = try await existingCharacters(entryID: entryID)
                .sorted { $0.sortOrder < $1.sortOrder }

            let characters = try await loadCharacters(from: rows)

            return EntryCharacterRules.orderedCharacters(characters)
        } catch {
            throw SupabaseEntryCharacterError.syncFailed
        }
    }

    func loadAllCharacters(userID: UUID) async throws -> [EntryCharacter] {
        do {
            let rows: [EntryCharacterPhoto] = try await client
                .from("entry_characters")
                .select()
                .eq("user_id", value: userID)
                .order("updated_at", ascending: false)
                .execute()
                .value

            return try await loadCharacters(from: rows)
        } catch {
            throw SupabaseEntryCharacterError.syncFailed
        }
    }

    func deleteCharacters(clientEntryID: UUID) async throws {
        do {
            let rows = try await existingCharacters(clientEntryID: clientEntryID)
            for row in rows {
                try await deleteCloudCharacter(row)
            }
        } catch let error as SupabaseEntryCharacterError {
            throw error
        } catch {
            throw SupabaseEntryCharacterError.syncFailed
        }
    }

    func existingCharacters(entryID: UUID) async throws -> [EntryCharacterPhoto] {
        try await client
            .from("entry_characters")
            .select()
            .eq("entry_id", value: entryID)
            .execute()
            .value
    }

    func existingCharacters(clientEntryID: UUID) async throws -> [EntryCharacterPhoto] {
        try await client
            .from("entry_characters")
            .select()
            .eq("client_entry_id", value: clientEntryID)
            .execute()
            .value
    }

    private func loadCharacters(from rows: [EntryCharacterPhoto]) async throws -> [EntryCharacter] {
        var characters: [EntryCharacter] = []
        for row in rows {
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
            characters.append(
                EntryCharacter(
                    id: row.id,
                    name: row.name,
                    role: row.role,
                    sourcePhotoID: row.sourcePhotoID,
                    image: image,
                    createdAt: row.createdAt,
                    updatedAt: row.updatedAt
                )
            )
        }

        return characters
    }

    private func deleteCloudCharacter(_ character: EntryCharacterPhoto) async throws {
        do {
            try await client.storage
                .from(bucketName)
                .remove(paths: [character.storagePath])
        } catch let error as StorageError where error.statusCode == "404" {
            // Missing objects are already deleted; continue so retries can heal partial work.
        }

        try await client
            .from("entry_characters")
            .delete()
            .eq("id", value: character.id)
            .execute()
    }

    private func makeUpload(
        character: EntryCharacter,
        userID: UUID,
        clientEntryID: UUID,
        sortOrder: Int
    ) throws -> EntryCharacterUpload {
        guard let data = character.image.storytopiaPreparedJPEGData(maxDimension: 1024, compressionQuality: 0.88) else {
            throw SupabaseEntryCharacterError.invalidImage
        }
        guard let normalizedImage = UIImage(data: data) else {
            throw SupabaseEntryCharacterError.invalidImage
        }

        let storagePath = [
            userID.uuidString.lowercased(),
            "entries",
            clientEntryID.uuidString.lowercased(),
            "characters",
            "\(character.id.uuidString.lowercased()).\(EntryCharacter.fileExtension)"
        ].joined(separator: "/")

        return EntryCharacterUpload(
            data: data,
            storagePath: storagePath,
            width: normalizedImage.cgImage?.width ?? Int(normalizedImage.size.width.rounded()),
            height: normalizedImage.cgImage?.height ?? Int(normalizedImage.size.height.rounded()),
            sortOrder: sortOrder
        )
    }
}

private struct EntryCharacterUpload {
    let data: Data
    let storagePath: String
    let width: Int
    let height: Int
    let sortOrder: Int
}
