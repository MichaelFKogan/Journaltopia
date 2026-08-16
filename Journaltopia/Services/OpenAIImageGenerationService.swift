import Foundation
import Supabase
import UIKit

/// Which server-side generation path a request belongs to. Real user entries and Sample Studio
/// entries live in different tables and buckets, so they have separate Edge Functions.
enum StoryboardGenerationTarget {
    case userEntry
    case sampleStudio

    var functionName: String {
        switch self {
        case .userEntry:
            return "generate-storyboard"
        case .sampleStudio:
            return "generate-sample-storyboard"
        }
    }

    var storyboardBucketName: String {
        switch self {
        case .userEntry:
            return "generated-storyboards"
        case .sampleStudio:
            return "sample-story-assets"
        }
    }
}

/// What a generation request came back with. Real user entries are fire-and-poll now: the function
/// reserves the row and answers immediately, so there is no image to hand back yet — only the id of
/// the generation to reconcile later. Sample Studio still runs synchronously and returns its result.
enum StoryboardGenerationDispatch {
    case pending(PendingStoryboardGeneration)
    case completed(StoryboardGenerationResult)
}

/// The storyboard the Edge Function generated, stored, and recorded. Callers adopt this row instead
/// of uploading and inserting their own copy of the same image.
struct StoryboardGenerationResult {
    let storyboardID: UUID
    let clientEntryID: UUID
    let storagePath: String
    let artStyle: String
    let quality: OpenAIImageGenerationQuality
    let panelLayout: String?
    let isPrimary: Bool
    let createdAt: Date
    let image: UIImage
}

/// Image generation runs in the `generate-storyboard` Edge Function so the OpenAI key stays on the
/// server. This type still builds the prompt and picks the reference images; it hands both to the
/// function, which reserves the credit, calls OpenAI, and stores the result.
struct OpenAIImageGenerationService {
    private let referenceBucketName = "journaltopia-media"
    private let requestTimeout: TimeInterval = 600
    private let maxInputImageCount = EntryCharacterRules.maxGenerationImageCount
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseService.shared) {
        self.client = client
    }

    private struct StoryboardReferenceImage {
        let image: UIImage
        let promptLabel: String
        let fileName: String
        let characterName: String?
        let role: CharacterRole?
    }

    /// The two functions name the entry differently because they address different tables. Optional
    /// properties are omitted when nil, so each request carries only the id its function expects.
    private struct GenerateStoryboardRequest: Encodable {
        let clientEntryID: UUID?
        let sampleEntryID: UUID?
        /// Absent for Sample Studio, which spends no credits and so has nothing to make idempotent.
        let generationRequestID: UUID?
        let prompt: String
        let artStyle: String
        let quality: String
        let referenceImagePaths: [String]
    }

    private struct GenerateStoryboardResponse: Decodable {
        let storyboardID: UUID
        let clientEntryID: UUID?
        let sampleEntryID: UUID?
        let storagePath: String
        let artStyle: String?
        let quality: String?
        let panelLayout: String?
        let isPrimary: Bool
        let createdAt: String?
        /// Absent from the Sample Studio function, which still answers only when it has finished.
        let generationStatus: String?

        /// The image exists only once the row says so. Anything non-terminal means the server has
        /// accepted the job and will finish it after this response.
        var isStillGenerating: Bool {
            generationStatus == "pending" || generationStatus == "processing"
        }
    }

    private struct GenerateStoryboardErrorResponse: Decodable {
        let error: String
    }

    /// - Parameter generationRequestID: the identity of this logical generation, minted once when
    ///   the user asked for it and reused by every retry. The server treats a repeat as the same
    ///   reservation rather than a second one, which is what keeps a dropped response from costing
    ///   a second credit.
    func generateStoryboard(
        clientEntryID: UUID,
        generationRequestID: UUID,
        target: StoryboardGenerationTarget = .userEntry,
        title: String,
        text: String,
        richText: NotebookRichTextDocument?,
        artStyle: String,
        quality: OpenAIImageGenerationQuality,
        images: [UIImage],
        characters: [EntryCharacter] = []
    ) async throws -> StoryboardGenerationDispatch {
        let references = orderedGenerationReferences(characters: characters, originalImages: images)
        let prompt = makePrompt(
            title: title,
            text: text,
            richText: richText,
            artStyle: artStyle,
            originalImageCount: images.count,
            references: references,
            omittedCharacterCount: max(0, characters.count - references.filter { $0.characterName != nil }.count),
            omittedOriginalPhotoCount: max(0, images.count - references.filter { $0.characterName == nil }.count)
        )

        let session = try await authenticatedSession()

        // Reference images travel by storage path instead of inside the request body, so the
        // function never has to accept multi-megabyte base64 payloads.
        let referenceImagePaths = try await uploadReferenceImages(
            references,
            userID: session.user.id,
            clientEntryID: clientEntryID
        )

        do {
            let response = try await invokeGenerationFunction(
                GenerateStoryboardRequest(
                    clientEntryID: target == .userEntry ? clientEntryID : nil,
                    sampleEntryID: target == .sampleStudio ? clientEntryID : nil,
                    generationRequestID: target == .userEntry ? generationRequestID : nil,
                    prompt: prompt,
                    artStyle: artStyle,
                    quality: quality.rawValue,
                    referenceImagePaths: referenceImagePaths
                ),
                functionName: target.functionName,
                accessToken: session.accessToken
            )

            if response.isStillGenerating {
                // Nothing is awaited from here. The function read the reference images before it
                // answered and removes them itself once the job is done, so this path leaves both
                // the staging files and the generation to the server.
                return .pending(
                    PendingStoryboardGeneration(
                        id: response.storyboardID,
                        clientEntryID: response.clientEntryID ?? clientEntryID
                    )
                )
            }

            let image = try await downloadStoryboard(
                storagePath: response.storagePath,
                bucketName: target.storyboardBucketName
            )
            await removeReferenceImages(referenceImagePaths)

            return .completed(StoryboardGenerationResult(
                storyboardID: response.storyboardID,
                clientEntryID: response.clientEntryID ?? response.sampleEntryID ?? clientEntryID,
                storagePath: response.storagePath,
                artStyle: response.artStyle ?? artStyle,
                quality: response.quality.flatMap(OpenAIImageGenerationQuality.init(rawValue:)) ?? quality,
                panelLayout: response.panelLayout,
                isPrimary: response.isPrimary,
                createdAt: Self.timestamp(from: response.createdAt),
                image: image
            ))
        } catch {
            await removeReferenceImages(referenceImagePaths)
            throw error
        }
    }

    /// Postgres timestamps carry microsecond precision, which the fractional-seconds parser does not
    /// always accept. The stored row is the record of when this ran, so a parse miss falls back to
    /// now rather than failing a generation that already succeeded.
    private static func timestamp(from value: String?) -> Date {
        guard let value else {
            return Date()
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? Date()
    }

    private func authenticatedSession() async throws -> Session {
        do {
            return try await client.auth.session
        } catch {
            throw StoryboardGenerationError.openAIMessage("Sign in before generating a storyboard.")
        }
    }

    private func uploadReferenceImages(
        _ references: [StoryboardReferenceImage],
        userID: UUID,
        clientEntryID: UUID
    ) async throws -> [String] {
        guard !references.isEmpty else {
            return []
        }

        // One folder per request keeps concurrent or retried generations from overwriting each
        // other's inputs, and makes the cleanup below a single prefix to remove.
        let requestID = UUID().uuidString.lowercased()
        var uploadedPaths: [String] = []

        do {
            for (index, reference) in references.prefix(maxInputImageCount).enumerated() {
                guard let imageData = reference.image.journaltopiaPreparedJPEGData(maxDimension: 1536, compressionQuality: 0.76) else {
                    throw StoryboardGenerationError.invalidRequest
                }

                let storagePath = [
                    userID.uuidString.lowercased(),
                    "entries",
                    clientEntryID.uuidString.lowercased(),
                    "generation-inputs",
                    requestID,
                    "\(index + 1)-\(reference.fileName)"
                ].joined(separator: "/")

                try await client.storage
                    .from(referenceBucketName)
                    .upload(
                        storagePath,
                        data: imageData,
                        options: FileOptions(
                            cacheControl: "3600",
                            contentType: CreateEntryReferencePhoto.mimeType,
                            upsert: true
                        )
                    )

                uploadedPaths.append(storagePath)
            }

            return uploadedPaths
        } catch {
            await removeReferenceImages(uploadedPaths)

            if let generationError = error as? StoryboardGenerationError {
                throw generationError
            }

            print("[Journaltopia] Reference image upload failed: \(error.localizedDescription)")
            throw StoryboardGenerationError.openAIMessage("The reference photos could not be prepared for generation.")
        }
    }

    /// Generation inputs are a staging copy of images the entry already owns, so they are removed
    /// once the function has read them. A failure here only leaves stray files behind.
    private func removeReferenceImages(_ storagePaths: [String]) async {
        guard !storagePaths.isEmpty else {
            return
        }

        do {
            _ = try await client.storage
                .from(referenceBucketName)
                .remove(paths: storagePaths)
        } catch {
            print("[Journaltopia] Generation reference cleanup skipped: \(error.localizedDescription)")
        }
    }

    private func invokeGenerationFunction(
        _ payload: GenerateStoryboardRequest,
        functionName: String,
        accessToken: String
    ) async throws -> GenerateStoryboardResponse {
        let projectURL = try JournaltopiaSupabaseConfig.projectURL
        let anonKey = try JournaltopiaSupabaseConfig.anonKey
        let functionURL = projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(functionName)

        var request = URLRequest(url: functionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(payload)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoryboardGenerationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(GenerateStoryboardErrorResponse.self, from: data) {
                throw StoryboardGenerationError.openAIMessage(errorResponse.error)
            }

            throw StoryboardGenerationError.openAIMessage("Storyboard generation returned status \(httpResponse.statusCode).")
        }

        do {
            return try JSONDecoder().decode(GenerateStoryboardResponse.self, from: data)
        } catch {
            throw StoryboardGenerationError.invalidResponse
        }
    }

    private func downloadStoryboard(storagePath: String, bucketName: String) async throws -> UIImage {
        do {
            let data = try await client.storage
                .from(bucketName)
                .download(path: storagePath)
            SupabaseStorageImageCache.store(data, bucketName: bucketName, storagePath: storagePath)

            guard let image = UIImage(data: data) else {
                throw StoryboardGenerationError.noGeneratedImage
            }

            return image
        } catch let error as StoryboardGenerationError {
            throw error
        } catch {
            print("[Journaltopia] Generated storyboard download failed: \(error.localizedDescription)")
            throw StoryboardGenerationError.openAIMessage("The generated storyboard could not be downloaded.")
        }
    }

    private func makePrompt(
        title: String,
        text: String,
        richText: NotebookRichTextDocument?,
        artStyle: String,
        originalImageCount: Int,
        references: [StoryboardReferenceImage],
        omittedCharacterCount: Int,
        omittedOriginalPhotoCount: Int
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRichText = richText?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageCount = references.count
        let hasReferencePhotos = imageCount > 0
        let storyText: String

        if let trimmedRichText, !trimmedRichText.isEmpty {
            storyText = trimmedRichText
        } else if trimmedText.isEmpty {
            storyText = hasReferencePhotos
                ? """
                No written story was provided. Study the uploaded photos and create a \
                restrained, emotionally coherent interpretation of the moment. Do not \
                invent major events or relationships that are not supported by the photos.
                """
                : """
                No written story or reference photos were provided. Create a warm, \
                emotionally grounded everyday moment with a clear beginning, middle, \
                and end.
                """
        } else {
            storyText = trimmedText
        }

        let referencePhotoCount = min(imageCount, maxInputImageCount)

        let titleBlock = trimmedTitle.isEmpty
            ? "Untitled Entry"
            : trimmedTitle

        let creationSource = hasReferencePhotos
            ? "the user's written memory and \(referencePhotoCount) uploaded reference image(s)"
            : "the user's written memory"

        let identityInstruction = hasReferencePhotos
            ? """
            Preserve the recognizable identity of people, pets, locations, clothing, \
            and important objects shown in the reference photos. Preserve their defining \
            visual characteristics without preserving photographic realism.
            """
            : """
            Create appealing and visually consistent characters, locations, clothing, \
            and important objects that faithfully support the user's memory.
            """

        let referencePhotoInstructions = hasReferencePhotos
            ? """
            REFERENCE PHOTOS:
            - Use all uploaded reference images as visual evidence about the memory.
            - Do not ignore any uploaded reference image.
            - Use them to understand identity, appearance, relationships, pets, clothing,
            locations, objects, atmosphere, and emotional context.
            - Do not automatically map photo 1 to panel 1, photo 2 to panel 2, and so on.
            - Combine details from multiple photos when doing so creates a more coherent story.
            - Do not invent important people, actions, relationships, or events that are not
            supported by the written memory or photos.
            - Keep recurring characters and important visual details recognizable and
            consistent across every panel.
            - Reinterpret every scene as original artwork in the selected style.
            - Never reproduce the uploaded photos as photographs inside a collage.
            """
            : """
            REFERENCE PHOTOS:
            - No reference photos were provided.
            - Do not imply that a photographic reference exists.
            - Base the page on the written memory.
            - Fill minor visual gaps with restrained, believable details.
            - Do not invent major events, relationships, conflicts, or emotional conclusions
            that are not supported by the user's writing.
            - Keep recurring characters, clothing, locations, and important objects
            consistent across every panel.
            """

        return """
        CREATIVE ROLE:

        You are an award-winning graphic novelist and visual storyteller.

        Your job is not merely to generate a comic. Your job is to faithfully reinterpret
        a person's memory as a graphic novel page that allows them to see their own life
        from an outside perspective.

        The user is simultaneously the protagonist, the author, and the future reader of
        this memory.

        Treat the comic as a vehicle for perspective. Help the user notice the emotional
        meaning, relationships, behavior, atmosphere, or personal significance already
        present in the moment.

        Do not make the memory larger, more dramatic, or more profound than the source
        material supports. Make it more understandable.

        The finished page should feel as though a thoughtful graphic novelist studied the
        memory and selected the most meaningful visual moments.

        JOURNALTOPIA'S PURPOSE:

        Turn memories into graphic novel pages so people can see their own lives from a
        new perspective.

        The ideal emotional response is:

        "I never realized my life looked like that."

        SOURCE MATERIAL:

        Create one vertical graphic novel page based on \(creationSource).

        ENTRY TITLE:
        \(titleBlock)

        USER'S MEMORY:
        \(storyText)

        STORY INTERPRETATION:

        Before composing the page, silently determine:

        - What is literally happening?
        - What appears to matter most to the user?
        - What emotion or internal experience is supported by the memory?
        - What small details reveal that experience visually?
        - What changes, becomes clearer, or gains meaning by the final panel?
        - Which moments are necessary, and which details can be omitted?

        Do not include this analysis in the final image.

        Find the invisible story within the visible events, but remain faithful to the
        evidence provided by the user.

        Ordinary moments are allowed to remain quiet. Do not manufacture conflict,
        sentimentality, tragedy, romance, triumph, or revelation.

        VISUAL STORYTELLING PRINCIPLES:

        - Show rather than explain.
        - Use facial expressions, posture, distance, lighting, composition, environment,
        gestures, and meaningful objects to communicate emotion.
        - Avoid showing the same pose or scene repeatedly.
        - Each panel must contribute new information, emotion, or perspective.
        - Select distinct moments rather than slicing one instant into nearly identical images.
        - Let quiet details carry meaning when appropriate.
        - Use varied framing, such as establishing shots, medium shots, close-ups,
        over-the-shoulder views, and environmental details.
        - Keep the protagonist recognizable and visually consistent throughout the page.
        - Preserve ambiguity when the memory itself is ambiguous.
        - Do not diagnose, judge, moralize, or tell the user what their experience means.
        - Present the moment with empathy and emotional honesty.

        PANEL NARRATIVE:

        Analyze the story and choose the best panel count between 3 and 6.

        Use fewer panels for simple, quiet, single-moment memories. Use more panels for
        stories with clear progression, multiple beats, changes over time, a future vision,
        or a cinematic feeling.

        Then create one graphic novel page using exactly the number of panels you chose.

        Across the page, the panels should collectively establish:

        1. The setting and situation.
        2. The important action, relationship, or experience.
        3. The protagonist's observable emotional perspective.
        4. A meaningful progression, contrast, realization, or lingering final impression.

        Adapt this progression naturally to your chosen panel count. Do not force every
        memory into an artificial dramatic arc.

        The final panel should leave the reader with the emotional meaning or atmosphere
        of the memory rather than merely stopping the action.

        ART STYLE:

        Selected art style:
        \(artStyle)

        STYLE PRIORITY:
        \(artStylePromptDescription(for: artStyle))

        The final image must fully commit to the selected art style.

        \(identityInstruction)

        Strongly reinterpret all people, environments, objects, and reference material
        through the selected style.

        The result must look like authentic \(artStyle) artwork, not a photograph with an
        art filter applied.

        When photographic realism conflicts with the selected art style, prioritize the
        selected art style while preserving recognizable identity and story details.

        GENERATION SETTINGS:

        - The AI image model must choose the panel count and page layout from the story.
        - Choose exactly 3, 4, 5, or 6 panels.
        - Do not use fewer than 3 panels.
        - Do not use more than 6 panels.

        PAGE FORMAT:

        - Output one single tall image.
        - Divide the image into exactly the chosen number of distinct comic panels.
        - Use visible, intentional gutters or panel borders.
        - Choose a clear graphic novel page layout that fits the story's natural pacing.
        - Prefer balanced, readable arrangements such as stacked rows, a clean grid, or
        a classic comic-page composition with one larger establishing or emotional panel.
        - Create a cohesive graphic novel page, not a collection of unrelated illustrations.
        - Show a clear progression of moments.
        - Fully redraw every scene as original illustrated artwork.
        - Never create a photo collage, contact sheet, photomontage, scrapbook, mood board,
        or grid of separate photographs.
        - Do not display the reference photos as inset photographs.
        - Keep important characters, clothing, objects, and locations consistent across panels.
        - Maintain a clear visual hierarchy and readable panel flow.

        \(referencePhotoInstructions)

        \(characterReferenceInstructions(
            references: references,
            originalImageCount: originalImageCount,
            omittedCharacterCount: omittedCharacterCount,
            omittedOriginalPhotoCount: omittedOriginalPhotoCount
        ))

        CAPTIONS AND DIALOGUE:

        - Prioritize visual storytelling over written explanation.
        - Use captions or speech bubbles only when they add information the artwork cannot
        communicate clearly by itself.
        - Do not require text in every panel.
        - Keep all text concise, natural, and emotionally restrained.
        - Do not invent quotations unless the user's memory clearly provides or implies them.
        - Prefer narration based closely on the user's own language.
        - Do not summarize the entire journal entry inside captions.
        - Avoid generic inspirational statements, forced lessons, or sentimental conclusions.
        - Ensure any included text is large, readable, correctly spelled, and cleanly placed.
        - Never allow text to obscure faces or important visual details.

        FINAL STANDARD:

        The result should not feel like an image generator illustrated a journal entry.

        It should feel like a thoughtful graphic novelist interpreted a real person's memory
        with care, visual intelligence, restraint, and emotional honesty.
        """
    }

    private func orderedGenerationReferences(
        characters: [EntryCharacter],
        originalImages: [UIImage]
    ) -> [StoryboardReferenceImage] {
        let characterReferences = EntryCharacterRules.orderedCharacters(characters).enumerated().map { index, character in
            StoryboardReferenceImage(
                image: character.image,
                promptLabel: "\(character.role.title): \(character.name)",
                // Characters may share a name, so the index keeps upload file names distinct.
                fileName: "\(character.role.rawValue)-\(sanitizedFileComponent(character.name))-\(index + 1).jpg",
                characterName: character.name,
                role: character.role
            )
        }

        let originalReferences = originalImages.enumerated().map { index, image in
            StoryboardReferenceImage(
                image: image,
                promptLabel: "Original reference photo \(index + 1)",
                fileName: "original-reference-photo-\(index + 1).jpg",
                characterName: nil,
                role: nil
            )
        }

        return Array((characterReferences + originalReferences).prefix(maxInputImageCount))
    }

    private func characterReferenceInstructions(
        references: [StoryboardReferenceImage],
        originalImageCount: Int,
        omittedCharacterCount: Int,
        omittedOriginalPhotoCount: Int
    ) -> String {
        guard !references.isEmpty else {
            return ""
        }

        let characterReferences = references.enumerated().compactMap { index, reference -> (Int, StoryboardReferenceImage)? in
            guard reference.characterName != nil else {
                return nil
            }
            return (index + 1, reference)
        }
        let originalReferences = references.enumerated().compactMap { index, reference -> Int? in
            reference.characterName == nil ? index + 1 : nil
        }

        var sections: [String] = []
        for role in CharacterRole.allCases {
            let lines = characterReferences
                .filter { $0.1.role == role }
                .map { imageNumber, reference in
                    "- Image \(imageNumber): \(reference.promptLabel). Use this cropped portrait as the explicit identity reference."
                }

            if !lines.isEmpty {
                sections.append(([role.promptGroupTitle + ":"] + lines).joined(separator: "\n"))
            }
        }

        if !originalReferences.isEmpty {
            sections.append(
                """
                Original uncropped reference photos:
                - Images \(originalReferences.map(String.init).joined(separator: ", ")) are wider environmental, group, or context references.
                """
            )
        }

        if omittedCharacterCount > 0 || omittedOriginalPhotoCount > 0 {
            sections.append(
                """
                Reference limit handling:
                - The app prioritized named character crops before original reference photos because the request can include only \(maxInputImageCount) images.
                - Omitted named character crops: \(omittedCharacterCount).
                - Omitted original reference photos: \(omittedOriginalPhotoCount) of \(originalImageCount).
                """
            )
        }

        sections.append(
            """
            Character identity rules:
            - Treat named character crops as authoritative identity references.
            - Do not treat untagged people appearing incidentally in wider photos as story characters unless the written memory requires them.
            - Preserve the visual identity of each named character using their corresponding cropped reference.
            - The main character must not be replaced by another person appearing in a group photo.
            """
        )

        return (["CHARACTER REFERENCES:"] + sections).joined(separator: "\n\n")
    }

    private func sanitizedFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "character" : collapsed
    }
}

func storyboardPanelCount(for imageCount: Int) -> Int {
    switch imageCount {
    case ...0:
        return 0
    case 1...3:
        return 3
    case 4:
        return 4
    case 5:
        return 5
    default:
        return 6
    }
}
