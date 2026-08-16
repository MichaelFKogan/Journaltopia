import AVFoundation
import AudioToolbox
import Combine
import MapKit
import PhotosUI
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum CreateEntryPresentation {
    case compose
    case composeInJournal(title: String, initialDate: Date, locksEntryDate: Bool)
    case editDraft
    case editDraftInJournal(title: String)

    var showsNextButton: Bool {
        switch self {
        case .compose, .composeInJournal, .editDraft, .editDraftInJournal:
            return true
        }
    }

    var showsEntryOptionsFlow: Bool {
        switch self {
        case .compose, .composeInJournal, .editDraft, .editDraftInJournal:
            return true
        }
    }

    var savesDirectlyToJournal: Bool {
        if case .composeInJournal = self {
            return true
        }

        return false
    }

    var isEditDraft: Bool {
        switch self {
        case .editDraft, .editDraftInJournal:
            return true
        default:
            return false
        }
    }

    var directJournalTitle: String? {
        if case .composeInJournal(let title, _, _) = self {
            return title
        }

        return nil
    }

    var initialJournalTitle: String? {
        switch self {
        case .composeInJournal(let title, _, _), .editDraftInJournal(let title):
            return title
        case .compose, .editDraft:
            return nil
        }
    }

    var directJournalInitialDate: Date? {
        if case .composeInJournal(_, let initialDate, _) = self {
            return initialDate
        }

        return nil
    }

    var editorToolbarTitle: String {
        switch self {
        case .compose, .composeInJournal:
            return "Write Entry"
        case .editDraft, .editDraftInJournal:
            return "Edit Entry"
        }
    }

    var closeButtonSystemName: String {
        switch self {
        case .compose, .composeInJournal:
            return "chevron.left"
        case .editDraft, .editDraftInJournal:
            return "chevron.left"
        }
    }

    var closeButtonAccessibilityLabel: String {
        switch self {
        case .compose, .composeInJournal:
            return "Close"
        case .editDraft, .editDraftInJournal:
            return "Back"
        }
    }

    var exitConfirmationTitle: String {
        switch self {
        case .compose, .composeInJournal:
            return "Save this entry?"
        case .editDraft, .editDraftInJournal:
            return "Save changes?"
        }
    }

    var exitConfirmationMessage: String {
        switch self {
        case .compose, .composeInJournal:
            return "You've started an entry. Would you like to save it before leaving?"
        case .editDraft, .editDraftInJournal:
            return "You've made changes to this entry. Would you like to save them before leaving?"
        }
    }

    var exitConfirmationSaveButtonTitle: String {
        switch self {
        case .compose, .composeInJournal:
            return "Save Entry"
        case .editDraft, .editDraftInJournal:
            return "Save Changes"
        }
    }

    var exitConfirmationDiscardButtonTitle: String {
        switch self {
        case .compose, .composeInJournal:
            return "Discard"
        case .editDraft, .editDraftInJournal:
            return "Discard Changes"
        }
    }
}

enum CreateEntryAuthoringMode: Equatable {
    case user
    case sampleStudio

    var isSampleStudio: Bool {
        self == .sampleStudio
    }
}

private extension SampleJournal {
    func createEntryPrototypeChapter() -> PrototypeChapter {
        PrototypeChapter(
            id: id,
            title: title,
            subtitle: subtitle ?? "Sample journal",
            color: colorHex.flatMap(Color.init(hex:)) ?? Color.storyPurple,
            symbol: symbol ?? "book.closed.fill",
            coverImageName: coverImageName,
            remoteCover: remoteCover,
            kind: kind == "storyboard" ? .storyboard : .journal,
            isFavorite: isFavorite,
            createdAt: createdAt,
            updatedAt: updatedAt,
            entries: entries.map { $0.createEntryPrototypeEntry() }
        )
    }
}

private extension CreateEntryDraft {
    func createEntryPrototypeEntry() -> PrototypeEntry {
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d"

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        let displayDate = datePrecision == .noDate ? createdAt : date
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)

        return PrototypeEntry(
            id: id,
            weekday: weekdayFormatter.string(from: displayDate).uppercased(),
            day: dayFormatter.string(from: displayDate),
            title: trimmedTitle.isEmpty ? "Untitled Entry" : trimmedTitle,
            body: text,
            richText: richText,
            time: timeFormatter.string(from: displayDate),
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            imageNames: [],
            createdAt: createdAt
        )
    }
}

@MainActor
private final class EntrySpeechTranscriber: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case listening
        case unavailable(String)

        var isListening: Bool {
            if case .listening = self {
                return true
            }

            return false
        }
    }

    @Published private(set) var state: RecordingState = .idle

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastTranscript = ""
    private var didInstallAudioTap = false
    private var onTranscript: ((String) -> Void)?

    func toggle(onTranscript: @escaping (String) -> Void) {
        if state.isListening {
            stop()
            return
        }

        Task {
            await start(onTranscript: onTranscript)
        }
    }

    func stop() {
        guard state.isListening || audioEngine.isRunning || recognitionTask != nil else {
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if didInstallAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallAudioTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        onTranscript = nil
        lastTranscript = ""

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])

        if state.isListening {
            state = .idle
        }
    }

    private func start(onTranscript: @escaping (String) -> Void) async {
        state = .idle

        guard let speechRecognizer else {
            state = .unavailable("Speech recognition is not available on this device.")
            return
        }

        guard speechRecognizer.isAvailable else {
            state = .unavailable("Speech recognition is temporarily unavailable.")
            return
        }

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            state = .unavailable("Allow speech recognition in Settings to dictate journal entries.")
            return
        }

        let canRecord = await requestMicrophoneAuthorization()
        guard canRecord else {
            state = .unavailable("Allow microphone access in Settings to dictate journal entries.")
            return
        }

        stop()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .unavailable("Could not start the microphone. Please try again.")
            return
        }

        lastTranscript = ""
        self.onTranscript = onTranscript

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        didInstallAudioTap = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result, error: error)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
        } catch {
            stop()
            state = .unavailable("Could not start the microphone. Please try again.")
        }
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let transcript = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty, transcript != lastTranscript {
                lastTranscript = transcript
                onTranscript?(transcript)
            }
            if result.isFinal {
                stop()
            }
        }

        if error != nil, state.isListening {
            stop()
            state = .unavailable("Dictation stopped. Please try again.")
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }
}

private struct EntrySpeechMicButton: View {
    let isListening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                if isListening {
                    EntrySpeechMicPulse()
                }

                Image(systemName: isListening ? "mic.fill" : "mic")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(isListening ? Color.storyPurple : Color.white)
                    .frame(width: 58, height: 58)
                    .background(
                        Circle()
                            .fill(isListening ? Color.white : Color.storyPurple)
                    )
                    .overlay(
                        Circle()
                            .stroke(isListening ? Color.storyPurple.opacity(0.22) : Color.white.opacity(0.86), lineWidth: 1.4)
                    )
                    .shadow(color: Color.storyInk.opacity(isListening ? 0.22 : 0.16), radius: 14, y: 7)
                    .overlay(alignment: .topTrailing) {
                        if isListening {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 13, height: 13)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                )
                                .offset(x: -5, y: 5)
                        }
                    }
                    .scaleEffect(isListening ? 1.04 : 1)
                    .animation(.easeInOut(duration: 0.45), value: isListening)
            }
            .frame(width: 86, height: 86)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isListening ? "Stop dictation" : "Start dictation")
        .accessibilityHint("Adds spoken words to the journal entry")
    }

    private func handleTap() {
        let startAction = action

        if isListening {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            AudioServicesPlaySystemSound(1114)
            startAction()
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.86)
        prepareMicStartFeedbackAudioSession()
        // Wait for the begin-record sound to finish before starting capture,
        // otherwise playAndRecord session setup cuts it off.
        AudioServicesPlaySystemSoundWithCompletion(1113) {
            DispatchQueue.main.async {
                startAction()
            }
        }
    }

    private func prepareMicStartFeedbackAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

private struct EntrySpeechMicPulse: View {
    private let cycleDuration: TimeInterval = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            let delayedProgress = (progress + 0.5).truncatingRemainder(dividingBy: 1)

            ZStack {
                pulseRing(progress: progress)
                pulseRing(progress: delayedProgress)
            }
        }
        .frame(width: 86, height: 86)
        .allowsHitTesting(false)
    }

    private func pulseRing(progress: Double) -> some View {
        Circle()
            .stroke(Color.storyPurple.opacity(0.34), lineWidth: 2.5)
            .frame(width: 58, height: 58)
            .scaleEffect(1 + (0.48 * progress))
            .opacity(0.58 * (1 - progress))
    }
}

private struct JournalEntryPrompt: Identifiable {
    let title: String
    let text: String
    let systemName: String

    var id: String { title }
}

private enum JournalPromptCategory: String, CaseIterable, Identifiable {
    case today
    case past
    case future

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            "Life Now"
        case .past:
            "Past"
        case .future:
            "Future"
        }
    }
}

/// Every user-editable field the editor persists into a `CreateEntryDraft`, in one Equatable value.
///
/// Autosave watches this rather than a handful of individual bindings, for two reasons. Formatting
/// is persisted too — a font, a paper style, a text colour, an art style, a date — and losing an
/// hour of styling to a kill is no better than losing the words. And a single UI action usually
/// moves several of these at once; comparing one normalized value means that action produces one
/// change to react to instead of four.
///
/// Deliberately excluded: the thumbnail and the rich-text formatting flags, which are derived from
/// what is already here, and `createdAt`/`id`, which are identity rather than content.
struct CreateEntryAutosaveSignature: Equatable {
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let photoIDs: [UUID]
    let characters: [LoadedCreateEntryDraftSnapshot.CharacterSnapshot]
    let artStyle: String
    let location: String
    let date: Date
    let datePrecision: EntryDatePrecision
    let savesDraft: Bool
    let isPrivate: Bool
    let statusRawValue: String
    let fontChoiceRawValue: String
    let textColorIndex: Int
    let textSize: Double
    let paperStyleRawValue: String
    let paperColorIndex: Int
}

struct LoadedCreateEntryDraftSnapshot: Equatable {
    struct CharacterSnapshot: Equatable {
        let id: UUID
        let name: String
        let role: CharacterRole
        let sourcePhotoID: UUID?
        let updatedAt: Date
    }

    let id: UUID
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let photoIDs: [UUID]
    let characters: [CharacterSnapshot]
    let artStyle: String
    let location: String
    let date: Date
    let datePrecision: EntryDatePrecision
    let createdAt: Date
    let savesDraft: Bool
    let isPrivate: Bool
    let fontChoiceRawValue: String?
    let textColorIndex: Int
    let textSize: Double
    let paperStyleRawValue: String
    let paperColorIndex: Int

    init(
        id: UUID,
        title: String,
        text: String,
        richText: NotebookRichTextDocument?,
        photos: [CreateEntryReferencePhoto],
        characters: [EntryCharacter],
        artStyle: String,
        location: String,
        date: Date,
        datePrecision: EntryDatePrecision,
        createdAt: Date,
        savesDraft: Bool,
        isPrivate: Bool,
        fontChoiceRawValue: String?,
        textColorIndex: Int,
        textSize: Double,
        paperStyleRawValue: String,
        paperColorIndex: Int
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.richText = richText?.normalized(for: text)
        self.photoIDs = photos.map(\.id)
        self.characters = characters.map {
            CharacterSnapshot(
                id: $0.id,
                name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                role: $0.role,
                sourcePhotoID: $0.sourcePhotoID,
                updatedAt: $0.updatedAt
            )
        }
        self.artStyle = artStyle
        self.location = location
        self.date = date
        self.datePrecision = datePrecision
        self.createdAt = createdAt
        self.savesDraft = savesDraft
        self.isPrivate = isPrivate
        self.fontChoiceRawValue = fontChoiceRawValue
        self.textColorIndex = textColorIndex
        self.textSize = textSize
        self.paperStyleRawValue = paperStyleRawValue
        self.paperColorIndex = paperColorIndex
    }
}

private struct PendingCreateEntryDraftSave {
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

private struct EntryPreviewFormattingSummary {
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let textAlignmentRawValue: String
}

private enum CharacterEditorDestination {
    case entry
    case library
}

private struct CharacterEditorSession: Identifiable {
    let id = UUID()
    let character: EntryCharacter?
    var initialPhotoSource: CharacterInitialPhotoSource? = nil
    var destination: CharacterEditorDestination = .entry
}

private enum CharacterInitialPhotoSource {
    case camera
    case photoLibrary
}

private enum StoryboardGenerationPhase: Equatable {
    case ready
    case preparingEntry
    case uploadingReferencePhotos
    case generating
    case savingResult
    case completed
    case failed

    var buttonTitle: String {
        switch self {
        case .ready, .failed:
            return "Generate Storyboard"
        case .preparingEntry:
            return "Preparing Entry..."
        case .uploadingReferencePhotos:
            return "Uploading Photos..."
        case .generating:
            return "Generating..."
        case .savingResult:
            return "Saving Result..."
        case .completed:
            return "Completed"
        }
    }

    var progressTitle: String {
        switch self {
        case .ready:
            return "Getting ready..."
        case .preparingEntry:
            return "Preparing your entry..."
        case .uploadingReferencePhotos:
            return "Uploading your photos..."
        case .generating:
            return "Generating your storyboard..."
        case .savingResult:
            return "Saving your storyboard..."
        case .completed:
            return "Storyboard ready"
        case .failed:
            return "Generation stopped"
        }
    }
}

private struct EntryLocationSuggestion: Identifiable, Equatable {
    let title: String
    let subtitle: String

    var id: String {
        "\(title)|\(subtitle)"
    }

    var displayText: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}

private final class EntryLocationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [EntryLocationSuggestion] = []
    @Published var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateQuery(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            clear()
            return
        }

        isSearching = true
        completer.queryFragment = trimmedQuery
    }

    func clear() {
        completer.queryFragment = ""
        suggestions = []
        isSearching = false
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let suggestions = completer.results
            .prefix(6)
            .map { EntryLocationSuggestion(title: $0.title, subtitle: $0.subtitle) }

        DispatchQueue.main.async {
            self.suggestions = suggestions
            self.isSearching = false
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.suggestions = []
            self.isSearching = false
        }
    }
}

struct EntryLocationRecentsList: View {
    let locations: [String]
    let accentColor: Color
    let onSelect: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Recent Locations")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.storyGray.opacity(0.58))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear recent locations")
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(locations, id: \.self) { location in
                    Button {
                        onSelect(location)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accentColor)
                                .frame(width: 24)

                            Text(location)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.storyInk)
                                .lineLimit(1)

                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if location != locations.last {
                        Divider()
                            .padding(.leading, 48)
                    }
                }
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
            )
        }
    }
}

enum EntryJournalLinkStore {
    private static let storageKey = "StorytopiaEntryJournalLinks"
    private static let entryIDStorageKey = "StorytopiaEntryJournalEntryIDs"
    private static let multiStorageKey = "StorytopiaEntryJournalLinkLists"
    private static let multiEntryIDStorageKey = "StorytopiaEntryJournalEntryIDLists"

    static func loadJournalTitle(for draftID: UUID) -> String? {
        loadJournalTitles(for: draftID).first
    }

    static func loadJournalTitles(for draftID: UUID) -> Set<String> {
        let draftKey = draftID.uuidString
        var titles = Set(multiLinks[draftKey] ?? [])
        if let legacyTitle = links[draftKey] {
            titles.insert(legacyTitle)
        }
        return titles
    }

    static func loadJournalTitles(for draftIDs: [UUID]) -> [UUID: Set<String>] {
        let links = links
        let multiLinks = multiLinks

        return draftIDs.reduce(into: [:]) { titlesByDraftID, draftID in
            let draftKey = draftID.uuidString
            var titles = Set(multiLinks[draftKey] ?? [])
            if let legacyTitle = links[draftKey] {
                titles.insert(legacyTitle)
            }
            titlesByDraftID[draftID] = titles
        }
    }

    /// Returns draft IDs linked to `journalTitle` without loading draft payloads.
    static func draftIDs(linkedTo journalTitle: String) -> Set<UUID> {
        let links = links
        let multiLinks = multiLinks
        var draftIDs = Set<UUID>()

        for (draftKey, titles) in multiLinks where titles.contains(journalTitle) {
            if let draftID = UUID(uuidString: draftKey) {
                draftIDs.insert(draftID)
            }
        }

        for (draftKey, title) in links where title == journalTitle {
            if let draftID = UUID(uuidString: draftKey) {
                draftIDs.insert(draftID)
            }
        }

        return draftIDs
    }

    static func loadJournalEntryID(for draftID: UUID) -> UUID? {
        loadJournalEntryIDs(for: draftID).first
    }

    static func loadJournalEntryIDs(for draftID: UUID) -> Set<UUID> {
        let draftKey = draftID.uuidString
        var ids = Set((multiEntryIDs[draftKey] ?? []).compactMap(UUID.init(uuidString:)))
        guard let rawID = entryIDs[draftID.uuidString] else {
            return ids
        }

        if let legacyID = UUID(uuidString: rawID) {
            ids.insert(legacyID)
        }
        return ids
    }

    static func save(journalTitle: String, journalEntryID: UUID, for draftID: UUID) {
        var links = links
        var entryIDs = entryIDs
        var multiLinks = multiLinks
        var multiEntryIDs = multiEntryIDs
        var titles = Set(multiLinks[draftID.uuidString] ?? [])
        var ids = Set(multiEntryIDs[draftID.uuidString] ?? [])
        links[draftID.uuidString] = journalTitle
        entryIDs[draftID.uuidString] = journalEntryID.uuidString
        titles.insert(journalTitle)
        ids.insert(journalEntryID.uuidString)
        multiLinks[draftID.uuidString] = Array(titles).sorted()
        multiEntryIDs[draftID.uuidString] = Array(ids).sorted()
        UserDefaults.standard.set(links, forKey: storageKey)
        UserDefaults.standard.set(entryIDs, forKey: entryIDStorageKey)
        UserDefaults.standard.set(multiLinks, forKey: multiStorageKey)
        UserDefaults.standard.set(multiEntryIDs, forKey: multiEntryIDStorageKey)
    }

    static func remove(journalTitle: String, for draftID: UUID) {
        var links = links
        var entryIDs = entryIDs
        var multiLinks = multiLinks
        var multiEntryIDs = multiEntryIDs
        var titles = Set(multiLinks[draftID.uuidString] ?? [])

        titles.remove(journalTitle)
        if links[draftID.uuidString] == journalTitle {
            links[draftID.uuidString] = titles.sorted().first
            if links[draftID.uuidString] == nil {
                entryIDs.removeValue(forKey: draftID.uuidString)
            }
        }

        if titles.isEmpty {
            multiLinks.removeValue(forKey: draftID.uuidString)
            multiEntryIDs.removeValue(forKey: draftID.uuidString)
        } else {
            multiLinks[draftID.uuidString] = Array(titles).sorted()
        }

        UserDefaults.standard.set(links, forKey: storageKey)
        UserDefaults.standard.set(entryIDs, forKey: entryIDStorageKey)
        UserDefaults.standard.set(multiLinks, forKey: multiStorageKey)
        UserDefaults.standard.set(multiEntryIDs, forKey: multiEntryIDStorageKey)
    }

    static func remove(for draftID: UUID) {
        var links = links
        var entryIDs = entryIDs
        var multiLinks = multiLinks
        var multiEntryIDs = multiEntryIDs
        links.removeValue(forKey: draftID.uuidString)
        entryIDs.removeValue(forKey: draftID.uuidString)
        multiLinks.removeValue(forKey: draftID.uuidString)
        multiEntryIDs.removeValue(forKey: draftID.uuidString)
        UserDefaults.standard.set(links, forKey: storageKey)
        UserDefaults.standard.set(entryIDs, forKey: entryIDStorageKey)
        UserDefaults.standard.set(multiLinks, forKey: multiStorageKey)
        UserDefaults.standard.set(multiEntryIDs, forKey: multiEntryIDStorageKey)
    }

    private static var links: [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    private static var entryIDs: [String: String] {
        UserDefaults.standard.dictionary(forKey: entryIDStorageKey) as? [String: String] ?? [:]
    }

    private static var multiLinks: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: multiStorageKey) as? [String: [String]] ?? [:]
    }

    private static var multiEntryIDs: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: multiEntryIDStorageKey) as? [String: [String]] ?? [:]
    }
}

private enum CreateTextAlignmentChoice: String, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var textAlignment: NSTextAlignment {
        switch self {
        case .leading:
            .left
        case .center:
            .center
        case .trailing:
            .right
        }
    }

    var systemName: String {
        switch self {
        case .leading:
            "text.alignleft"
        case .center:
            "text.aligncenter"
        case .trailing:
            "text.alignright"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .leading:
            "Align text left"
        case .center:
            "Align text center"
        case .trailing:
            "Align text right"
        }
    }

    var next: CreateTextAlignmentChoice {
        switch self {
        case .leading:
            .center
        case .center:
            .trailing
        case .trailing:
            .leading
        }
    }
}

private enum CreateFormattingTab: String, CaseIterable, Identifiable {
    case fontStyle
    case paperStyle

    var id: String { rawValue }

    var sheetTitle: String {
        switch self {
        case .fontStyle:
            "Font"
        case .paperStyle:
            "Paper"
        }
    }

    var sheetSymbol: String {
        switch self {
        case .fontStyle:
            "textformat"
        case .paperStyle:
            "doc.text"
        }
    }
}

private typealias CreateKeyboardFormattingMode = NotebookKeyboardFormattingMode

private enum CreateKeyboardTextType: String, CaseIterable, Identifiable {
    case body
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .body:
            "Body"
        case .heading1:
            "Heading 1"
        case .heading2:
            "Heading 2"
        case .heading3:
            "Heading 3"
        case .heading4:
            "Heading 4"
        case .heading5:
            "Heading 5"
        case .heading6:
            "Heading 6"
        }
    }

    var primaryToolbarTitle: String {
        switch self {
        case .body:
            "Body"
        case .heading1:
            "H1"
        case .heading2:
            "H2"
        case .heading3:
            "H3"
        case .heading4:
            "H4"
        case .heading5:
            "H5"
        case .heading6:
            "H6"
        }
    }

    var textRunStyle: NotebookTextRunStyle {
        switch self {
        case .body:
            .body
        case .heading1:
            .heading1
        case .heading2:
            .heading2
        case .heading3:
            .heading3
        case .heading4:
            .heading4
        case .heading5:
            .heading5
        case .heading6:
            .heading6
        }
    }

    var sampleSize: CGFloat {
        switch self {
        case .body:
            16
        case .heading1:
            23
        case .heading2:
            21
        case .heading3:
            20
        case .heading4:
            18
        case .heading5:
            17
        case .heading6:
            16
        }
    }
}

private enum CreateFontChoice: String, CaseIterable, Identifiable {
    case sans
    case serif
    case nunito
    case lora
    case caveat
    case patrickHand
    case gloriaHallelujah
    case permanentMarker
    case specialElite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sans:
            "Sans"
        case .serif:
            "Serif"
        case .nunito:
            "Nunito"
        case .lora:
            "Lora"
        case .caveat:
            "Caveat"
        case .patrickHand:
            "Patrick Hand"
        case .gloriaHallelujah:
            "Gloria"
        case .permanentMarker:
            "Marker"
        case .specialElite:
            "Typewriter"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif, .lora:
            .serif
        case .sans, .nunito:
            .default
        case .caveat, .patrickHand, .gloriaHallelujah, .permanentMarker:
            .rounded
        case .specialElite:
            .monospaced
        }
    }

    var uiKitDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .serif, .lora:
            .serif
        case .sans, .nunito:
            .default
        case .caveat, .patrickHand, .gloriaHallelujah, .permanentMarker:
            .rounded
        case .specialElite:
            .monospaced
        }
    }

    var fontName: String? {
        switch self {
        case .sans, .serif:
            nil
        case .nunito:
            "Nunito"
        case .lora:
            "Lora-Regular"
        case .caveat:
            "Caveat-Regular"
        case .patrickHand:
            "PatrickHand-Regular"
        case .gloriaHallelujah:
            "GloriaHallelujah"
        case .permanentMarker:
            "PermanentMarker-Regular"
        case .specialElite:
            "SpecialElite-Regular"
        }
    }

    var boldFontName: String? {
        nil
    }

    var usesVariableWeight: Bool {
        switch self {
        case .nunito, .lora, .caveat:
            true
        default:
            false
        }
    }

    var bodyWeight: Font.Weight {
        switch self {
        case .sans, .serif:
            .medium
        case .nunito, .lora:
            .regular
        case .caveat:
            .medium
        case .patrickHand, .gloriaHallelujah, .permanentMarker, .specialElite:
            .regular
        default:
            .regular
        }
    }

    /// Direct wght-axis values for variable fonts that need tuning beyond `bodyWeight`.
    var bodyWght: CGFloat? {
        switch self {
        case .nunito:
            600
        case .lora:
            450
        case .caveat:
            500
        default:
            nil
        }
    }

    var bodyBoldWeight: Font.Weight {
        .bold
    }

    var bodyBoldWght: CGFloat? {
        switch self {
        case .nunito, .lora, .caveat:
            700
        default:
            nil
        }
    }

    /// Compensates for fonts that render smaller at the same point size.
    var bodySizeScale: CGFloat {
        switch self {
        case .patrickHand:
            1.18
        case .caveat:
            1.28
        default:
            1
        }
    }

    static func savedValue(_ rawValue: String?) -> CreateFontChoice {
        guard let rawValue else {
            return .sans
        }

        switch rawValue {
        case "crimsonPro":
            return .lora
        case "handwritten":
            return .patrickHand
        case "typewriter":
            return .specialElite
        default:
            return CreateFontChoice(rawValue: rawValue) ?? .nunito
        }
    }

    func swiftUIFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let fontName else {
            return .system(size: size, weight: weight, design: design)
        }

        return VariableFont.font(
            name: fontName,
            size: size,
            weight: weight,
            usesWeightAxis: usesVariableWeight
        )
    }

    func swiftUIBodyFont(size: CGFloat) -> Font {
        guard let fontName else {
            return .system(size: size * bodySizeScale, weight: bodyWeight, design: design)
        }

        return VariableFont.font(
            name: fontName,
            size: size * bodySizeScale,
            weight: bodyWeight,
            usesWeightAxis: usesVariableWeight,
            wghtOverride: bodyWght
        )
    }
}

fileprivate enum CreatePaperStyleChoice: String, CaseIterable, Identifiable {
    case collegeRuled
    case blank
    case watercolorPaper
    case cottonPaper
    case recycledPaper

    static let defaultChoice: CreatePaperStyleChoice = .collegeRuled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collegeRuled:
            "Notebook"
        case .blank:
            "Blank"
        case .watercolorPaper:
            "Watercolor Paper"
        case .cottonPaper:
            "Cotton Paper"
        case .recycledPaper:
            "Recycled Paper"
        }
    }

    var showsRuledLines: Bool {
        self == .collegeRuled
    }

    var showsNotebookChrome: Bool {
        self == .collegeRuled
    }

    var showsPaperColorOptions: Bool {
        backgroundImageName == nil
    }

    var usesTexturedPaperTextEffect: Bool {
        backgroundImageName != nil
    }

    var backgroundImageName: String? {
        switch self {
        case .watercolorPaper:
            "watercolor-paper"
        case .cottonPaper:
            "cotton-paper"
        case .recycledPaper:
            "recycled-paper"
        case .collegeRuled, .blank:
            nil
        }
    }

    var leadingContentPadding: CGFloat {
        switch self {
        case .collegeRuled:
            NotebookMetrics.marginLeading
        case .blank, .watercolorPaper, .cottonPaper, .recycledPaper:
            18
        }
    }

    var leadingTextPadding: CGFloat {
        switch self {
        case .collegeRuled:
            NotebookMetrics.textLeadingInset
        case .blank, .watercolorPaper, .cottonPaper, .recycledPaper:
            0
        }
    }

    var bodyLineHeight: CGFloat? {
        showsRuledLines ? NotebookMetrics.ruleSpacing : nil
    }
}

private struct CreateColorOption {
    let color: Color
    let uiColor: UIColor
}

private enum CreateFormattingPalette {
    static let textColors: [CreateColorOption] = [
        CreateColorOption(color: .black, uiColor: .black),
        CreateColorOption(color: Color(red: 0.27, green: 0.31, blue: 0.42), uiColor: UIColor(red: 0.27, green: 0.31, blue: 0.42, alpha: 1)),
        CreateColorOption(color: Color(red: 0.08, green: 0.19, blue: 0.34), uiColor: UIColor(red: 0.08, green: 0.19, blue: 0.34, alpha: 1)),
        CreateColorOption(color: Color(red: 0.20, green: 0.45, blue: 0.72), uiColor: UIColor(red: 0.20, green: 0.45, blue: 0.72, alpha: 1)),
        CreateColorOption(color: Color(red: 0.10, green: 0.30, blue: 0.28), uiColor: UIColor(red: 0.10, green: 0.30, blue: 0.28, alpha: 1)),
        CreateColorOption(color: Color(red: 0.29, green: 0.18, blue: 0.47), uiColor: UIColor(red: 0.29, green: 0.18, blue: 0.47, alpha: 1)),
        CreateColorOption(color: Color(red: 0.46, green: 0.16, blue: 0.27), uiColor: UIColor(red: 0.46, green: 0.16, blue: 0.27, alpha: 1)),
        CreateColorOption(color: Color(red: 0.34, green: 0.20, blue: 0.17), uiColor: UIColor(red: 0.34, green: 0.20, blue: 0.17, alpha: 1)),
        CreateColorOption(color: Color(red: 0.55, green: 0.34, blue: 0.10), uiColor: UIColor(red: 0.55, green: 0.34, blue: 0.10, alpha: 1)),
        CreateColorOption(color: Color(red: 0.42, green: 0.42, blue: 0.49), uiColor: UIColor(red: 0.42, green: 0.42, blue: 0.49, alpha: 1))
    ]

    static let paperColors: [Color] = [
        Color.white,
        .homePageBackground,
        Color(red: 0.98, green: 0.93, blue: 0.86),
        Color(red: 1.0, green: 0.95, blue: 0.75),
        Color(red: 0.86, green: 0.93, blue: 0.97),
        Color(red: 0.86, green: 0.94, blue: 0.86),
        Color(red: 0.88, green: 0.83, blue: 0.95)
    ]
}

private enum CreateEntryTextSize {
    static let defaultSliderValue: Double = 0.5
    static let legacyDefaultSliderValue: Double = 0.25
    static let minimumFontSize: CGFloat = 14
    static let defaultFontSize: CGFloat = 16
    static let maximumFontSize: CGFloat = 22
    static let snapThreshold: Double = 0.035

    static func fontSize(for sliderValue: Double) -> CGFloat {
        let normalizedValue = normalizedSliderValue(for: sliderValue)
        if normalizedValue <= defaultSliderValue {
            let progress = CGFloat(normalizedValue / defaultSliderValue)
            return minimumFontSize + progress * (defaultFontSize - minimumFontSize)
        }

        let progress = CGFloat((normalizedValue - defaultSliderValue) / (1 - defaultSliderValue))
        return defaultFontSize + progress * (maximumFontSize - defaultFontSize)
    }

    static func normalizedSliderValue(for sliderValue: Double?) -> Double {
        guard let sliderValue else {
            return defaultSliderValue
        }

        if abs(sliderValue - legacyDefaultSliderValue) < 0.0001 {
            return defaultSliderValue
        }

        return min(max(sliderValue, 0), 1)
    }

    static func snappedSliderValue(for sliderValue: Double) -> Double {
        abs(sliderValue - defaultSliderValue) <= snapThreshold
            ? defaultSliderValue
            : min(max(sliderValue, 0), 1)
    }
}

@MainActor
enum DraftThumbnailRenderer {
    static func render(
        title: String,
        text: String,
        richText: NotebookRichTextDocument? = nil,
        photos: [UIImage],
        fontChoiceRawValue: String?,
        textColorIndex: Int?,
        textSize: Double?,
        paperStyleRawValue: String?,
        paperColorIndex: Int?,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false,
        isHighlighted: Bool = false,
        textAlignmentRawValue: String = CreateTextAlignmentChoice.leading.rawValue
    ) -> UIImage? {
        let fontChoice = CreateFontChoice.savedValue(fontChoiceRawValue)
        let normalizedTextColorIndex = min(max(textColorIndex ?? 0, 0), CreateFormattingPalette.textColors.count - 1)
        let normalizedTextSize = CreateEntryTextSize.normalizedSliderValue(for: textSize)
        let paperStyle = paperStyleRawValue.flatMap(CreatePaperStyleChoice.init(rawValue:)) ?? .defaultChoice
        let normalizedPaperColorIndex = min(max(paperColorIndex ?? 0, 0), CreateFormattingPalette.paperColors.count - 1)
        let paperColor = CreateFormattingPalette.paperColors[normalizedPaperColorIndex]
        let textColor = CreateFormattingPalette.textColors[normalizedTextColorIndex].color
        let textAlignment = CreateTextAlignmentChoice(rawValue: textAlignmentRawValue) ?? .leading

        let thumbnailSize = CGSize(width: 260, height: 340)
        let thumbnail = DraftPageThumbnail(
            title: title,
            text: text,
            richText: richText?.normalized(for: text),
            photos: [],
            fontChoice: fontChoice,
            textColor: textColor,
            textUIColor: CreateFormattingPalette.textColors[normalizedTextColorIndex].uiColor,
            textSize: CreateEntryTextSize.fontSize(for: normalizedTextSize),
            paperStyle: paperStyle,
            paperColor: paperStyle.showsPaperColorOptions ? paperColor : .homePageBackground,
            isBold: isBold,
            isItalic: isItalic,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isHighlighted: isHighlighted,
            textAlignment: textAlignment
        )
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)

        let renderer = ImageRenderer(content: thumbnail)
        renderer.proposedSize = ProposedViewSize(width: thumbnailSize.width, height: thumbnailSize.height)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }
}

private struct DraftPageThumbnail: View {
    let title: String
    let text: String
    let richText: NotebookRichTextDocument?
    let photos: [UIImage]
    let fontChoice: CreateFontChoice
    let textColor: Color
    let textUIColor: UIColor
    let textSize: CGFloat
    let paperStyle: CreatePaperStyleChoice
    let paperColor: Color
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isStrikethrough: Bool
    let isHighlighted: Bool
    let textAlignment: CreateTextAlignmentChoice

    private let filmstripItemWidth: CGFloat = 50
    private let filmstripItemHeight: CGFloat = 56
    private let filmstripImageHeight: CGFloat = 40
    private let filmstripSpacing: CGFloat = 6

    private var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Untitled Entry" : trimmedTitle
    }

    private var displayText: String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? "Start writing..." : trimmedText
    }

    private var thumbnailTextStyle: NotebookTextStyle {
        NotebookTextStyle(
            swiftUIDesign: fontChoice.design,
            uiKitDesign: fontChoice.uiKitDesign,
            customFontName: fontChoice.fontName,
            customFontBoldName: fontChoice.boldFontName,
            customFontWeight: fontChoice.bodyWeight,
            customFontWght: fontChoice.bodyWght,
            customFontBoldWeight: fontChoice.bodyBoldWeight,
            customFontBoldWght: fontChoice.bodyBoldWght,
            customFontUsesVariableWeight: fontChoice.usesVariableWeight,
            customFontSizeScale: fontChoice.bodySizeScale,
            bodyFontWeight: fontChoice.bodyWeight,
            bodyFontSize: min(textSize, 19),
            bodyLineHeight: paperStyle.bodyLineHeight,
            color: textColor,
            uiColor: textUIColor
        )
    }

    private var displayRichText: AttributedString {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? displayText : text
        let document = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? NotebookRichTextDocument(text: sourceText)
            : richText?.normalized(for: text) ?? NotebookRichTextDocument(text: sourceText)

        let attributedText = NSMutableAttributedString(
            attributedString: document.attributedString(textStyle: thumbnailTextStyle)
        )
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(
            .paragraphStyle,
            value: thumbnailParagraphStyle,
            range: fullRange
        )

        if isUnderlined {
            attributedText.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: fullRange
            )
        }

        if isStrikethrough {
            attributedText.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: fullRange
            )
        }

        return AttributedString(attributedText)
    }

    private var thumbnailParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.lineBreakMode = .byWordWrapping
        style.alignment = textAlignment == .center ? .center : textAlignment == .trailing ? .right : .left
        return style
    }

    private var visibleFilmstripPhotos: [UIImage] {
        Array(photos.prefix(photos.count > 4 ? 3 : 4))
    }

    private var overflowPhotoCount: Int {
        max(photos.count - visibleFilmstripPhotos.count, 0)
    }

    var body: some View {
        ZStack {
            Color.homePageBackground

            ZStack(alignment: .bottom) {
                NotebookPaperBackground(
                    paperColor: paperStyle.backgroundImageName == nil ? paperColor : .homePageBackground,
                    paperImageName: paperStyle.backgroundImageName,
                    showsPaperWash: false,
                    showsRuledLines: paperStyle.showsRuledLines,
                    showsNotebookChrome: paperStyle.showsNotebookChrome,
                    firstRuledLineY: 84
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text(displayTitle)
                        .font(NotebookMetrics.titleFont(for: thumbnailTextStyle))
                        .foregroundStyle(thumbnailTextStyle.color)
                        .lineLimit(2)

                    Text(displayRichText)
                        .foregroundStyle(textColor)
                        .padding(.horizontal, isHighlighted ? 3 : 0)
                        .background(isHighlighted ? Color.yellow.opacity(0.26) : Color.clear)
                        .multilineTextAlignment(textAlignment == .center ? .center : textAlignment == .trailing ? .trailing : .leading)
                        .lineSpacing(4)
                        .lineLimit(photos.isEmpty ? 10 : 8)
                }
                .padding(.top, 28)
                .padding(.trailing, 18)
                .padding(.bottom, photos.isEmpty ? 20 : 88)
                .padding(.leading, paperStyle.leadingContentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if !photos.isEmpty {
                    photoFilmstrip
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                }
            }
            .background(paperStyle.backgroundImageName == nil ? paperColor : Color.homePageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var photoFilmstrip: some View {
        HStack(spacing: filmstripSpacing) {
            ForEach(Array(visibleFilmstripPhotos.enumerated()), id: \.offset) { index, photo in
                polaroidThumbnail(photo, index: index)
            }

            if overflowPhotoCount > 0 {
                overflowBadge
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.9))
                .shadow(color: Color.storyInk.opacity(0.12), radius: 5, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.storyInk.opacity(0.08), lineWidth: 0.7)
        )
    }

    private func polaroidThumbnail(_ photo: UIImage, index: Int) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: filmstripItemWidth - 6, height: filmstripImageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.storyInk.opacity(0.08), lineWidth: 0.6)
                )

            Spacer(minLength: 0)
        }
        .padding(.top, 3)
        .padding(.horizontal, 3)
        .padding(.bottom, 10)
        .frame(width: filmstripItemWidth, height: filmstripItemHeight)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.storyInk.opacity(0.14), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.storyInk.opacity(0.08), lineWidth: 0.6)
        )
        .overlay(alignment: .top) {
            StoryPhotoTape(width: 30, height: 10, rotation: -2)
                .offset(y: -4)
        }
        .rotationEffect(.degrees(polaroidRotation(for: index)))
    }

    private func polaroidRotation(for index: Int) -> Double {
        switch index % 3 {
        case 0:
            return -2
        case 1:
            return 1.5
        default:
            return -0.8
        }
    }

    private var overflowBadge: some View {
        Text("+\(overflowPhotoCount)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.storyInk)
            .frame(width: filmstripItemWidth, height: filmstripItemHeight)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.storyInk.opacity(0.12), radius: 2, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.storyInk.opacity(0.1), lineWidth: 0.7)
            )
    }
}

struct CreateEntryView: View {
    private static let defaultArtStyle = "Anime"
    private let artStyles = ["Anime", "Graphic Novel", "Pixel Art", "Manga", "Pop Art"]
    let presentation: CreateEntryPresentation

    @Binding var entryText: String
    @Binding var storyTitle: String
    @Binding var storyboardPhotos: [CreateEntryReferencePhoto?]
    @Binding var isDraftSaved: Bool
    @Binding var activeDraftID: UUID?
    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    @Binding var completedEntryOpenedStoryboardImage: UIImage?
    var isOpeningEntryFromEntries = false
    @Binding var isOpeningCompletedEntryFromEntries: Bool
    @Binding var storyboardGenerationStatus: StoryboardGenerationGlobalStatus?
    var contentMode: StorytopiaContentMode = .user
    var existingEntryStartsReadOnly = false
    let dismissCreate: () -> Void
    var onJournalEntryCreated: (String, PrototypeEntry) -> Void = { _, _ in }
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore
    @EnvironmentObject private var pendingStoryboardMonitor: PendingStoryboardGenerationMonitor
    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.scenePhase) private var scenePhase

    /// Which set of tables a save belongs to. Sample Studio authors into the sample tables; everyone
    /// else into their own account.
    private var authoringMode: CreateEntryAuthoringMode {
        contentMode.authoringMode
    }

    /// Signed out, the editor opens and types normally — the gate stops the writes, not the writing.
    /// Everything that would put this entry somewhere permanent asks here first.
    private var canPersistEntry: Bool {
        contentMode.canPersistUserContent || contentMode.isSampleAuthoring
    }

    /// Whether an entry opened here came from the in-memory sample pack rather than from disk.
    ///
    /// Opening a sample entry used to mean writing a "temporary" copy of it into
    /// `CreateEntryDraftStore` so this screen could read it back. Signed out that copy lands in the
    /// anonymous scope, and it only gets cleaned up if the reader comes back — quit the app with a
    /// sample entry open and it stayed there for the next account to inherit.
    private var readsEntryFromSamplePack: Bool {
        contentMode.showsSampleContent && !contentMode.isSampleAuthoring
    }

    private func loadedDraft(id: UUID) -> CreateEntryDraft? {
        readsEntryFromSamplePack
            ? SampleContentStore.entry(id: id)
            : CreateEntryDraftStore.load(id: id)
    }

    private func loadedStoryboards(clientEntryID: UUID) -> [GeneratedStoryboard] {
        readsEntryFromSamplePack
            ? SampleContentStore.storyboards(clientEntryID: clientEntryID)
            : GeneratedStoryboardStore.load(clientEntryIDs: [clientEntryID])
    }

    @State private var selectedArtStyle = CreateEntryView.defaultArtStyle
    @AppStorage("StorytopiaImageGenerationQuality") private var selectedImageGenerationQualityRawValue = OpenAIImageGenerationQuality.standard.rawValue

    @State private var selectedPhotoSlot: Int?
    @State private var isShowingPhotoSourceSheet = false
    @State private var isShowingPhotoLibrary = false
    @State private var isShowingCamera = false
    @State private var isShowingExitConfirmation = false
    @State private var isGeneratingStoryboard = false
    @State private var isShowingStoryboardGenerationProgress = false
    @State private var storyboardGenerationPhase: StoryboardGenerationPhase = .ready
    @State private var generationErrorMessage: String?
    @State private var isFullScreenEditorVisible = false
    @State private var isShowingJournalPromptsSheet = false
    @State private var isShowingCustomizeSheet = false
    @State private var activeCustomizeTab: CreateFormattingTab = .fontStyle
    @State private var isShowingEntryDateSheet = false
    @State private var isShowingEntryLocationSheet = false
    @State private var isShowingJournalDestinationSheet = false
    @State private var selectedFontChoice: CreateFontChoice = .sans
    @State private var selectedPaperStyleChoice: CreatePaperStyleChoice = .defaultChoice
    @State private var selectedTextColorIndex = 0
    @State private var selectedPaperColorIndex = 0
    @State private var entryRichText: NotebookRichTextDocument?
    @State private var previewTextSize: Double = CreateEntryTextSize.defaultSliderValue
    @State private var textFormattingRequestID = 0
    @State private var textFormattingRequest: NotebookTextFormattingRequest?
    @State private var selectedCustomJournalTitle: String?
    @State private var selectedCustomJournalTitles: Set<String> = []
    @State private var addedJournalTitle: String?
    @State private var sampleAuthorJournals: [PrototypeChapter] = []
    @State private var isShowingAddToJournalPage = false
    @State private var linkedJournalTitle: String?
    @State private var linkedJournalTitles: Set<String> = []
    @State private var storyLocation = ""
    @State private var recentEntryLocations = EntryLocationRecentStore.all
    @StateObject private var locationSearch = EntryLocationSearchModel()
    @State private var storyDate = Date()
    @State private var storyDatePrecision: EntryDatePrecision = .noDate
    @State private var didEditEntryDate = false
    @State private var didEditEntryLocation = false
    @State private var savesDraft = true
    @State private var isPrivateEntry = false
    @State private var selectedPhotoPickerItems: [PhotosPickerItem] = []
    @State private var draggedStoryboardPhotoIndex: Int?
    @State private var previewedStoryboardPhoto: UIImage?
    @State private var entryCharacters: [EntryCharacter] = []
    @State private var characterEditorSession: CharacterEditorSession?
    @State private var isShowingReusableCharactersSheet = false
    @State private var reusableCharacters: [EntryCharacter] = []
    @State private var isLoadingReusableCharacters = false
    @State private var reusableCharactersErrorMessage: String?
    @State private var deletingReusableCharacterID: UUID?
    @State private var reusableCharacterOrigins: [UUID: UUID] = [:]
    @State private var draggingReusableCharacterID: UUID?
    @State private var isPreviewingCompletedStoryboard = false
    @State private var selectedEntryStoryboardIndex: Int?
    @State private var completedEntryStoryboardDragOffset: CGSize = .zero
    @State private var completedEntryStoryboardDragStartOffset: CGSize?
    @State private var completedEntryStoryboardScale: CGFloat = 1
    @State private var completedEntryStoryboardScaleStart: CGFloat?
    @State private var isPhotosPanelVisible = false
    @State private var isShowingReferencePhotosSheet = false
    @State private var isShowingEntryCharactersSheet = false
    @State private var isEntryCharacterAddChoicesVisible = false
    @State private var isPhotoTabCollapsed = true
    @State private var isCharacterTabCollapsed = true
    @State private var isStoryDetailsTabCollapsed = true
    @State private var isShowingEntryOptionsPage = false
    @State private var loadedDraftSnapshot: LoadedCreateEntryDraftSnapshot?
    @State private var didResetForFreshCreatePresentation = false
    @FocusState private var isTitleFocused: Bool
    @State private var editorFocusRequestID = 0
    @State private var dictationTranscriptRequest: NotebookDictationTranscriptRequest?
    @State private var dictationTranscriptRequestID = 0
    @State private var speechRecognitionAlertMessage: String?
    @StateObject private var speechTranscriber = EntrySpeechTranscriber()
    @State private var editorBlurRequestID = 0
    @State private var isKeyboardVisible = false
    @State private var isBodyEditorEditing = false
    @State private var isKeyboardMoreToolbarVisible = false
    @State private var toolbarSavedSnapshot: LoadedCreateEntryDraftSnapshot?
    @State private var toolbarSavedJournalEntryID: UUID?
    @State private var showsToolbarSavedFeedback = false
    @State private var isToolbarSaveInProgress = false
    @State private var toolbarSaveFeedbackVersion = 0
    @State private var savedConfirmationRevealProgress: CGFloat = 0
    @State private var cloudSaveState: EntryCloudSaveState = .idle
    @State private var cloudSaveDismissVersion = 0
    @State private var currentEntryStatus: JournalEntryStatus = .draft
    @State private var storyboardPendingDeletion: GeneratedStoryboard?
    @State private var isDeletingStoryboard = false
    @State private var isConfirmingEntryDeletion = false
    @State private var isDeletingEntry = false
    @State private var entryDeletionErrorMessage: String?
    @State private var activeKeyboardFormattingMode: CreateKeyboardFormattingMode?
    @State private var lastKeyboardHeight: CGFloat = 300
    @State private var selectedKeyboardTextType: CreateKeyboardTextType = .body
    @State private var editorSelectionState = NotebookTextSelectionState()
    @State private var isKeyboardDismissInProgress = false
    @State private var autosaveScheduler = LocalDraftAutosaveScheduler()
    /// Set the moment the session decides how it ends — discard, delete, or an exit that has
    /// already saved. Everything after that point, including the editor's own teardown and the
    /// `onDisappear` flush, must not put content back on disk.
    @State private var isAutosaveSuspended = false
    /// What local autosave last wrote to disk. Deliberately separate from `loadedDraftSnapshot`,
    /// which stays pinned to the last *cloud* commit so the Save/Discard/Cancel prompt keeps
    /// appearing for work that only exists on this device.
    @State private var autosavedDraftSnapshot: LoadedCreateEntryDraftSnapshot?
    /// True when the draft on disk is ahead of Supabase. Read back from the draft on open, so an
    /// entry restored after a relaunch still knows it has uncommitted work.
    @State private var hasUncommittedLocalEdits = false
    /// The id an autosave just minted for this compose session. Adopting it must not be mistaken
    /// for the user switching entries, which would tear the editor down mid-sentence.
    @State private var autosaveAdoptedDraftID: UUID?

    private func dismissKeyboard() {
        isKeyboardDismissInProgress = true
        isTitleFocused = false
        editorBlurRequestID += 1
        endWindowEditing()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isKeyboardDismissInProgress = false
            isBodyEditorEditing = false
            resetKeyboardFormattingState()
            endWindowEditing()
        }
    }

    private func endWindowEditing() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .endEditing(true)
    }

    private func showEntryOptionsPage() {
        guard canShowEntryOptionsPage else {
            return
        }

        dismissKeyboard()
        isShowingEntryOptionsPage = true
    }

    private func advanceToEntryOptionsPage() {
        guard canShowEntryOptionsPage else {
            return
        }

        showEntryOptionsPage()
    }

    private var selectedTextStyle: NotebookTextStyle {
        let textColor = CreateFormattingPalette.textColors[
            min(max(selectedTextColorIndex, 0), CreateFormattingPalette.textColors.count - 1)
        ]

        return NotebookTextStyle(
            swiftUIDesign: selectedFontChoice.design,
            uiKitDesign: selectedFontChoice.uiKitDesign,
            customFontName: selectedFontChoice.fontName,
            customFontBoldName: selectedFontChoice.boldFontName,
            customFontWeight: selectedFontChoice.bodyWeight,
            customFontWght: selectedFontChoice.bodyWght,
            customFontBoldWeight: selectedFontChoice.bodyBoldWeight,
            customFontBoldWght: selectedFontChoice.bodyBoldWght,
            customFontUsesVariableWeight: selectedFontChoice.usesVariableWeight,
            customFontSizeScale: selectedFontChoice.bodySizeScale,
            bodyFontWeight: selectedFontChoice.bodyWeight,
            bodyFontSize: CreateEntryTextSize.fontSize(for: previewTextSize),
            bodyLineHeight: selectedPaperStyleChoice.bodyLineHeight,
            color: textColor.color,
            uiColor: textColor.uiColor
        )
    }

    private var selectedPaperColor: Color {
        CreateFormattingPalette.paperColors[
            min(max(selectedPaperColorIndex, 0), CreateFormattingPalette.paperColors.count - 1)
        ]
    }

    private var selectedPageBackgroundColor: Color {
        selectedPaperStyleChoice.showsPaperColorOptions ? selectedPaperColor : .homePageBackground
    }

    private var selectedKeyboardTextColor: Color {
        CreateFormattingPalette.textColors[
            min(max(selectedTextColorIndex, 0), CreateFormattingPalette.textColors.count - 1)
        ].color
    }

    private func applyKeyboardTextColor(_ index: Int) {
        let clampedIndex = min(max(index, 0), CreateFormattingPalette.textColors.count - 1)
        guard editorSelectionState.hasSelection else {
            selectedTextColorIndex = clampedIndex
            return
        }

        guard let hexString = CreateFormattingPalette.textColors[clampedIndex].uiColor.storytopiaHexString else {
            return
        }

        sendTextFormattingCommand(.textColor(hexString))
    }

    private var selectedPaperSurfaceColor: Color {
        usesPaperImageBackground ? .clear : selectedPageBackgroundColor
    }

    private var usesPaperImageBackground: Bool {
        selectedPaperStyleChoice.backgroundImageName != nil
    }

    private var opensExistingEntryReadMode: Bool {
        isOpeningCompletedEntryFromEntries || existingEntryStartsReadOnly
    }

    private var showsComposeFlowControls: Bool {
        canShowEntryOptionsPage
    }

    private var canShowEntryOptionsPage: Bool {
        presentation.showsEntryOptionsFlow
    }

    private var editorToolbarTitle: String {
        if opensExistingEntryReadMode {
            return "Entry"
        }

        return presentation.editorToolbarTitle
    }

    var body: some View {
        editorWithLifecycle
    }

    @ViewBuilder
    private var editorCore: some View {
        if presentation.showsEntryOptionsFlow {
            editorNavigationRoot
                .navigationDestination(isPresented: $isShowingEntryOptionsPage) {
                    entryOptionsPage
                }
        } else {
            editorNavigationRoot
        }
    }

    private var editorNavigationRoot: some View {
        ZStack {
            pageBackground
                .ignoresSafeArea()
                .onTapGesture {
                    dismissKeyboard()
                }

            layoutPage
        }
    }

    private var editorWithOverlays: some View {
        editorCore
        .disabled(isBlockingSaveInProgress)
        .overlay {
            if isBlockingSaveInProgress {
                saveProgressOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .overlay(alignment: .bottom) {
            if let addedJournalTitle {
                addedToJournalToast(journalTitle: addedJournalTitle)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let cloudSaveMessage = cloudSaveBannerMessage {
                cloudSaveStatusBanner(message: cloudSaveMessage)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            completedEntryStoryboardFloatingOverlay
        }
        .overlay(alignment: .bottomTrailing) {
            if showsSpeechMicButton {
                speechMicButton
                    .padding(.trailing, 18)
                    .padding(.bottom, speechMicBottomPadding)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
        }
        .overlay {
            if showsSavedConfirmationCard {
                savedConfirmationCard
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
    }

    private var editorWithPrimarySheets: some View {
        editorWithOverlays
        .onDisappear {
            // The editor can also leave without an explicit decision — a swipe back, a navigation
            // from elsewhere. Those still deserve their pending write. Exits that already decided
            // (save, discard, delete) suspended autosave first, so this is a no-op for them.
            flushLocalAutosave()
            speechTranscriber.stop()
            dismissKeyboard()
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .endEditing(true)
        }
        .onChange(of: isShowingEntryOptionsPage) { isShowing in
            if isShowing {
                speechTranscriber.stop()
            }
        }
        .onChange(of: speechTranscriber.state) { state in
            if case .unavailable(let message) = state {
                speechRecognitionAlertMessage = message
            }
        }
        // The generation this page started is finished by the server and reconciled by the monitor,
        // whether or not the page is still open. These two keep the page in step when it is.
        .onReceive(pendingStoryboardMonitor.$restoredStoryboard.compactMap { $0 }) { storyboard in
            adoptReconciledStoryboard(storyboard)
        }
        .onReceive(pendingStoryboardMonitor.$status.compactMap { $0 }) { status in
            guard status.kind == .failed else {
                return
            }

            adoptReconciledFailure(status)
        }
        .alert(
            "Dictation Unavailable",
            isPresented: Binding(
                get: { speechRecognitionAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        speechRecognitionAlertMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                speechRecognitionAlertMessage = nil
            }
        } message: {
            Text(speechRecognitionAlertMessage ?? "")
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraPhotoPicker { image in
                setStoryboardPhoto(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { previewedStoryboardPhoto != nil },
                set: { isPresented in
                    if !isPresented {
                        previewedStoryboardPhoto = nil
                    }
                }
            )
        ) {
            if let previewedStoryboardPhoto {
                ReferencePhotoViewer(image: previewedStoryboardPhoto) {
                    self.previewedStoryboardPhoto = nil
                }
                .presentationBackground(.clear)
            }
        }
        .fullScreenCover(isPresented: $isPreviewingCompletedStoryboard) {
            let storyboards = currentEntryStoryboards
            if !storyboards.isEmpty {
                StoryboardImageViewer(
                    storyboards: storyboards,
                    initialIndex: min(selectedEntryStoryboardIndex ?? 0, storyboards.count - 1),
                    onSelectPrimary: { storyboard in
                        setPrimaryStoryboard(storyboard)
                    },
                    deleteAction: StoryboardViewerDeleteAction(
                        message: { _ in storyboardDeletionMessage },
                        perform: { storyboard in
                            deleteStoryboard(storyboard)
                        }
                    )
                )
            }
        }
        .alert(
            "Delete Storyboard?",
            isPresented: Binding(
                get: { storyboardPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        storyboardPendingDeletion = nil
                    }
                }
            ),
            presenting: storyboardPendingDeletion
        ) { storyboard in
            Button("Cancel", role: .cancel) {
                storyboardPendingDeletion = nil
            }

            Button("Delete", role: .destructive) {
                deleteStoryboard(storyboard)
            }
        } message: { _ in
            Text(storyboardDeletionMessage)
        }
        .alert("Delete Entry?", isPresented: $isConfirmingEntryDeletion) {
            Button("Cancel", role: .cancel) {
                isConfirmingEntryDeletion = false
            }

            Button("Delete Entry", role: .destructive) {
                deleteCurrentEntry()
            }
        } message: {
            Text(entryDeletionMessage)
        }
        .alert(
            "Could Not Delete Entry",
            isPresented: Binding(
                get: { entryDeletionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        entryDeletionErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                entryDeletionErrorMessage = nil
            }
        } message: {
            Text(entryDeletionErrorMessage ?? "Could not delete this entry.")
        }
    }

    private var editorWithFormattingSheets: some View {
        editorWithPrimarySheets
        .sheet(isPresented: $isShowingEntryDateSheet) {
            entryDateSheet
                .presentationDetents([.height(520), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.homePageBackground)
        }
        .sheet(isPresented: $isShowingEntryLocationSheet) {
            entryLocationSheet
                .presentationDetents([.height(560), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.homePageBackground)
        }
        .sheet(isPresented: $isShowingAddToJournalPage) {
            NavigationStack {
                AddEntryToJournalPage(
                    selectedJournalTitle: $selectedCustomJournalTitle,
                    selectedJournalTitles: $selectedCustomJournalTitles,
                    contentMode: contentMode,
                    onSelect: addEditedEntryToJournal,
                    onSaveSelection: saveEditedEntryJournalSelection
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingJournalDestinationSheet) {
            AddToJournalSheet(
                selectedJournalTitle: $selectedCustomJournalTitle,
                contentMode: contentMode
            ) { journalTitle in
                selectedCustomJournalTitle = journalTitle
                isShowingJournalDestinationSheet = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var remainingReferencePhotoSlotCount: Int {
        max(1, storyboardPhotos.filter { $0 == nil }.count)
    }

    private var isCharacterEditorSheetPresented: Binding<Bool> {
        Binding(
            get: {
                characterEditorSession != nil && !isShowingEntryCharactersSheet
            },
            set: { isPresented in
                if !isPresented {
                    characterEditorSession = nil
                }
            }
        )
    }

    private var isNestedCharacterEditorSheetPresented: Binding<Bool> {
        Binding(
            get: {
                characterEditorSession != nil
            },
            set: { isPresented in
                if !isPresented {
                    characterEditorSession = nil
                }
            }
        )
    }

    private var editorWithPhotoPicker: some View {
        editorWithFormattingSheets
        .photosPicker(
            isPresented: $isShowingPhotoLibrary,
            selection: $selectedPhotoPickerItems,
            maxSelectionCount: remainingReferencePhotoSlotCount,
            selectionBehavior: .ordered,
            matching: .images
        )
    }

    private var editorWithPhotoSourceSheet: some View {
        editorWithPhotoPicker
        .sheet(isPresented: $isShowingPhotoSourceSheet) {
            photoSourceSheetContent()
        }
        .sheet(isPresented: $isShowingReferencePhotosSheet) {
            referencePhotosSheetContent()
        }
        .sheet(isPresented: $isShowingEntryCharactersSheet) {
            entryCharactersSheetContent()
        }
    }

    private var editorWithCharacterSheet: some View {
        editorWithPhotoSourceSheet
            .sheet(isPresented: isCharacterEditorSheetPresented) {
                characterEditorSheetContent()
            }
            .sheet(isPresented: $isShowingReusableCharactersSheet) {
                ReusableCharactersSheet(
                    characters: $reusableCharacters,
                    draggingCharacterID: $draggingReusableCharacterID,
                    attachedCharacterIDs: attachedReusableCharacterIDs,
                    isLoading: isLoadingReusableCharacters,
                    errorMessage: reusableCharactersErrorMessage,
                    deletingCharacterID: deletingReusableCharacterID,
                    onSelect: addReusableCharacter,
                    onEdit: editReusableCharacter,
                    onDelete: deleteReusableCharacter,
                    onRefresh: refreshReusableCharacters,
                    onReorder: persistReusableCharacterOrder,
                    dragProvider: beginReusableCharacterDrag
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.homePageBackground)
            }
    }

    private var editorWithPhotoAndGenerationSheets: some View {
        editorWithCharacterSheet
        .sheet(isPresented: $isShowingStoryboardGenerationProgress) {
            storyboardGenerationProgressSheetContent()
        }
    }

    private func photoSourceSheetContent() -> AnyView {
        AnyView(
            PhotoSourceSheet(
                showsCamera: UIImagePickerController.isSourceTypeAvailable(.camera),
                onCamera: presentCameraFromPhotoSourceSheet,
                onPhotoLibrary: presentPhotoLibraryFromPhotoSourceSheet
            )
            .presentationDetents([.height(280), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.homePageBackground)
        )
    }

    private func referencePhotosSheetContent() -> AnyView {
        AnyView(
            NavigationStack {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Add photos of people, places, objects, or scenery you want the storyboard to reference. Any person in these photos will be added to your storyboard. To isolate a specific person or pet, use Characters instead.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.storyInk.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)

                        if hasStoryboardPhotos {
                            referencePhotoFanPreview
                                .frame(maxWidth: .infinity)

                            referencePhotosSheetStripRow

                            Text("\(storyboardPhotos.compactMap { $0 }.count) of \(storyboardPhotos.count) photos")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.storyInk.opacity(0.58))
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        if nextAvailablePhotoSlot != nil {
                            referencePhotoSourceChoices
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .background(Color.homePageBackground.ignoresSafeArea())
                .navigationTitle("Reference Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isShowingReferencePhotosSheet = false
                        }
                        .foregroundStyle(Color.storyPurple)
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.homePageBackground)
        )
    }

    private func entryCharactersSheetContent() -> AnyView {
        AnyView(
            NavigationStack {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Add people or pets who appear in this story. Character references help keep them recognizable throughout your storyboard.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.storyInk.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)

                        if entryCharacters.isEmpty {
                            characterPhotoSourceSection
                        } else {
                            VStack(alignment: .leading, spacing: 11) {
                                Text("Characters in this Entry")
                                    .font(.system(size: 16, weight: .bold, design: .serif))
                                    .foregroundStyle(Color.storyInk)

                                entryCharactersSheetStripRow
                            }

                            if isEntryCharacterAddChoicesVisible {
                                characterPhotoSourceSection
                            }
                        }

                        entryCharactersReusableLibrarySection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .background(Color.homePageBackground.ignoresSafeArea())
                .navigationTitle("Characters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isShowingEntryCharactersSheet = false
                        }
                        .foregroundStyle(Color.storyPurple)
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.homePageBackground)
            .sheet(isPresented: isNestedCharacterEditorSheetPresented) {
                characterEditorSheetContent()
            }
            .onAppear {
                reusableCharacters = authoringMode.isSampleStudio
                    ? mergedReusableCharacters(reusableCharacters)
                    : mergedReusableCharacters(localReusableCharacters(), reusableCharacters)
                refreshReusableCharacters()
            }
        )
    }

    private func storyboardGenerationProgressSheetContent() -> AnyView {
        AnyView(
            StoryboardGenerationProgressScreen(phase: storyboardGenerationPhase) {
                isShowingStoryboardGenerationProgress = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(0)
            .presentationBackground(.clear)
        )
    }

    private func characterEditorSheet(for session: CharacterEditorSession) -> AnyView {
        let isLibraryEdit = session.destination == .library
        let deleteAction: ((EntryCharacter) -> Void)?
        if isLibraryEdit {
            deleteAction = { character in
                characterEditorSession = nil
                deleteReusableCharacter(character)
            }
        } else {
            deleteAction = characterDeleteAction(for: session.character)
        }

        return AnyView(
            CharacterEditorSheet(
                editingCharacter: session.character,
                initialPhotoSource: session.initialPhotoSource,
                deletesFromLibrary: isLibraryEdit,
                onSave: { character in
                    if isLibraryEdit {
                        saveLibraryCharacter(character)
                    } else {
                        saveCharacter(character)
                    }
                },
                onDelete: deleteAction
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.homePageBackground)
        )
    }

    private func characterEditorSheetContent() -> AnyView {
        guard let characterEditorSession else {
            return AnyView(EmptyView())
        }

        return characterEditorSheet(for: characterEditorSession)
    }

    private func characterDeleteAction(for character: EntryCharacter?) -> ((EntryCharacter) -> Void)? {
        guard character != nil else {
            return nil
        }

        return { characterToDelete in
            deleteCharacter(characterToDelete)
        }
    }

    private var editorWithAlerts: some View {
        editorWithPhotoAndGenerationSheets
        .alert(presentation.exitConfirmationTitle, isPresented: $isShowingExitConfirmation) {
            Button(presentation.exitConfirmationSaveButtonTitle) {
                saveFromExitConfirmation()
            }

            Button(presentation.exitConfirmationDiscardButtonTitle, role: .destructive) {
                discardDraftAndExit()
            }

            Button("Cancel", role: .cancel) {
            }
        } message: {
            Text(presentation.exitConfirmationMessage)
        }
        .alert(
            "Storyboard generation failed",
            isPresented: Binding(
                get: { generationErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        generationErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
            }
        } message: {
            Text(generationErrorMessage ?? "")
        }
    }

    private var editorWithLifecycle: some View {
        editorWithAlerts
        .onChange(of: selectedPhotoPickerItems) { items in
            guard !items.isEmpty else {
                return
            }

            Task {
                await loadPhotoLibraryImages(from: items)
            }
        }
        .onAppear {
            // Appearing is the start of an editing session, whatever ended the last one.
            isAutosaveSuspended = false
            resetForFreshCreateIfNeeded()
            configureDirectJournalEntryIfNeeded()
            if !canShowEntryOptionsPage {
                isShowingEntryOptionsPage = false
            }
            loadLinkedJournalTitle(for: activeDraftID)
            loadSavedDraftIfNeeded()
            currentEntryStatus = resolvedCurrentEntryStatus()
            refreshSampleAuthorJournalsIfNeeded()
        }
        .onChange(of: activeDraftID) { newDraftID in
            handleActiveDraftChange(newDraftID)
        }
        .onChange(of: selectedPage) { newPage in
            if newPage == .create {
                resetForFreshCreateIfNeeded()
            } else {
                didResetForFreshCreatePresentation = false
            }
        }
        .onChange(of: canShowEntryOptionsPage) { canShowOptions in
            if !canShowOptions {
                isShowingEntryOptionsPage = false
            }
        }
        .onChange(of: cloudSaveState) { newState in
            updateSavedConfirmationReveal(for: newState)
        }
        .onChange(of: currentAutosaveSignature) { _ in
            handleEditorContentChange()
        }
        .onChange(of: scenePhase) { phase in
            // Backgrounding is the last moment the app is guaranteed to run code before it can be
            // killed, so the debounce is skipped and the write happens now.
            guard phase != .active else {
                return
            }

            flushLocalAutosave()
        }
    }

    private func configureDirectJournalEntryIfNeeded() {
        if let initialDate = presentation.directJournalInitialDate, !hasDraftContent {
            storyDate = initialDate
        }

        seedInitialJournalSelectionIfNeeded()
    }

    private func seedInitialJournalSelectionIfNeeded() {
        guard let initialJournalTitle = presentation.initialJournalTitle else {
            return
        }

        if selectedCustomJournalTitles.isEmpty {
            selectedCustomJournalTitles = [initialJournalTitle]
        } else {
            selectedCustomJournalTitles.insert(initialJournalTitle)
        }

        if selectedCustomJournalTitle == nil {
            selectedCustomJournalTitle = initialJournalTitle
        }
    }

    private func resetForFreshCreateIfNeeded() {
        guard activeDraftID == nil, !isOpeningEntryFromEntries, !existingEntryStartsReadOnly else {
            didResetForFreshCreatePresentation = false
            return
        }

        guard !didResetForFreshCreatePresentation else {
            return
        }

        clearEditor()
        completedEntryOpenedStoryboardImage = nil
        isOpeningCompletedEntryFromEntries = false
        isPreviewingCompletedStoryboard = false
        selectedEntryStoryboardIndex = nil
        resetCompletedEntryStoryboardDrag()
        didResetForFreshCreatePresentation = true
        // A fresh editing session re-arms autosave after whatever ended the last one.
        isAutosaveSuspended = false
        restoreUnfinishedComposeIfNeeded()
    }

    private func handleActiveDraftChange(_ draftID: UUID?) {
        guard selectedPage == .create else {
            return
        }

        // The compose session just adopted the id its own autosave minted. Nothing about what the
        // user is looking at changed, so the editor must not be torn down and reloaded.
        if let draftID, draftID == autosaveAdoptedDraftID {
            autosaveAdoptedDraftID = nil
            return
        }

        autosaveAdoptedDraftID = nil
        // Whatever was queued belongs to the entry being left behind.
        cancelPendingLocalAutosave()
        autosavedDraftSnapshot = nil
        isAutosaveSuspended = false
        resetCompletedEntryStoryboardDrag()
        dismissKeyboard()
        isFullScreenEditorVisible = false
        isShowingEntryOptionsPage = false

        guard draftID != nil else {
            clearEditor()
            completedEntryOpenedStoryboardImage = nil
            isOpeningCompletedEntryFromEntries = false
            isPreviewingCompletedStoryboard = false
            selectedEntryStoryboardIndex = nil
            didResetForFreshCreatePresentation = activeDraftID == nil && !isOpeningEntryFromEntries && !existingEntryStartsReadOnly
            return
        }

        didResetForFreshCreatePresentation = false
        loadLinkedJournalTitle(for: draftID)
        loadSavedDraftIfNeeded()
        currentEntryStatus = resolvedCurrentEntryStatus()
    }

    private func resolvedCurrentEntryStatus() -> JournalEntryStatus {
        if let activeDraftID,
           let draft = loadedDraft(id: activeDraftID),
           let status = JournalEntryStatus(rawValue: draft.status) {
            return status
        }

        return isOpeningCompletedEntryFromEntries ? .completed : .draft
    }

    private func startStoryboardGeneration() {
        guard !isGeneratingStoryboard else {
            return
        }

        guard canPersistEntry else {
            // Signing out is not a failed generation. This used to set `generationErrorMessage` and
            // raise the red failure banner, which read as "something went wrong" rather than as
            // "this needs an account".
            signInGate.requireAccount(for: .generateStoryboard, retry: { startStoryboardGeneration() })
            return
        }

        // A generation that survived a relaunch is still running even though this page is new. Show
        // it rather than starting — and paying for — a second one for the same entry.
        if let activeDraftID, pendingStoryboardMonitor.hasPendingGeneration(for: activeDraftID) {
            isGeneratingStoryboard = true
            storyboardGenerationPhase = .generating
            isShowingStoryboardGenerationProgress = true
            return
        }

        let journalTitle = selectedEntryJournalTitle

        guard let generationPayload = makeEntryDraftSavePayload(forceSave: true) else {
            generationErrorMessage = StoryboardGenerationError.invalidRequest.localizedDescription
            setStoryboardGenerationGlobalStatus(
                kind: .failed,
                message: generationErrorMessage ?? StoryboardGenerationError.invalidRequest.localizedDescription
            )
            return
        }

        guard authoringMode.isSampleStudio || authStore.userID != nil else {
            return
        }

        let photos = storyboardPhotos.compactMap { $0 }
        let photoImages = photos.map(\.image)
        let generationQuality = selectedImageGenerationQuality
        let creditCost = generationQuality.creditCost
        // Only a balance we have actually read can turn the generation away here. When it is
        // unknown, the generate-storyboard function decides, since it owns the reservation. Sample
        // Studio authoring spends no credits, so a low balance must not block sample content.
        if isShortOnGenerationCredits, !authoringMode.isSampleStudio {
            generationErrorMessage = "You need \(formattedCreditCount(creditCost)) to generate this storyboard."
            setStoryboardGenerationGlobalStatus(
                kind: .failed,
                message: generationErrorMessage ?? "You need \(formattedCreditCount(creditCost)) to generate this storyboard."
            )
            return
        }

        let requiresEntrySave = activeDraftID == nil || hasUnsavedDraftChanges
        let requiresReferencePhotoSync = requiresEntrySave && hasUnsavedEntryMediaChanges
        isGeneratingStoryboard = true
        isShowingStoryboardGenerationProgress = true
        storyboardGenerationPhase = requiresReferencePhotoSync ? .uploadingReferencePhotos : .preparingEntry
        setStoryboardGenerationGlobalStatus(
            kind: .running,
            entryID: activeDraftID,
            phase: storyboardGenerationPhase
        )

        Task {
            // The generate-storyboard function reserves and refunds the credit as part of the same
            // request that calls OpenAI, so this flow only reads the balance back afterwards.
            do {
                let prepareResult: EntrySaveResult
                if authoringMode.isSampleStudio {
                    prepareResult = try await SupabaseSampleStoryService().prepareSampleEntryForGeneration(
                        payload: generationPayload,
                        currentStatus: currentEntryStatus,
                        requiresSave: requiresEntrySave,
                        syncReferencePhotos: requiresReferencePhotoSync
                    )
                } else {
                    prepareResult = try await EntrySaveService().prepareEntryForGeneration(
                        payload: generationPayload,
                        isSignedIn: authStore.userID != nil,
                        currentStatus: currentEntryStatus,
                        requiresSave: requiresEntrySave,
                        syncReferencePhotos: requiresReferencePhotoSync
                    )
                }
                activeDraftID = prepareResult.localDraftID
                setStoryboardGenerationGlobalStatus(
                    kind: .running,
                    entryID: prepareResult.localDraftID,
                    phase: storyboardGenerationPhase
                )
                setCloudSaveState(prepareResult.state)
                // Generation still force-saves exactly as it did before. That save is a real cloud
                // commit, so the entry stops being an unfinished compose here rather than waiting
                // for artwork that may not arrive until a later session.
                if prepareResult.state.isConfirmedSave {
                    markLocalDraftCommitted(
                        id: prepareResult.localDraftID,
                        snapshot: currentDraftSnapshot(id: prepareResult.localDraftID)
                    )
                }
                if case .failed(let message) = prepareResult.state {
                    throw StoryboardGenerationError.openAIMessage(message)
                }
                if case .photoUploadFailed(let message) = prepareResult.state {
                    throw StoryboardGenerationError.openAIMessage(message)
                }
                if !authoringMode.isSampleStudio,
                   authStore.userID != nil,
                   requiresEntrySave,
                   prepareResult.cloudEntry == nil {
                    throw StoryboardGenerationError.openAIMessage("Could not prepare this entry in Journaltopia cloud.")
                }

                await MainActor.run {
                    storyboardGenerationPhase = .generating
                    setStoryboardGenerationGlobalStatus(
                        kind: .running,
                        entryID: prepareResult.localDraftID,
                        phase: .generating
                    )
                }

                print("[Storytopia] Requesting storyboard generation.")
                // Minted once for this entry and reused until the server reaches a terminal answer,
                // so a retry after a dropped response reserves nothing new. Read here rather than
                // above because the entry's id is only settled by the save above.
                let generationRequestID = StoryboardGenerationRequestStore.requestID(
                    for: prepareResult.localDraftID
                )
                let dispatch = try await OpenAIImageGenerationService().generateStoryboard(
                    clientEntryID: prepareResult.localDraftID,
                    generationRequestID: generationRequestID,
                    target: authoringMode.isSampleStudio ? .sampleStudio : .userEntry,
                    title: storyTitle,
                    text: entryText,
                    richText: currentEntryRichText(),
                    artStyle: selectedArtStyle,
                    quality: generationQuality,
                    images: photoImages,
                    characters: entryCharacters
                )

                // A real entry's generation now belongs to the server. Nothing below is awaited for
                // it: the pending id is written to disk, the monitor takes over, and this page is
                // free to be closed, backgrounded, or killed.
                if case .pending(let pendingGeneration) = dispatch {
                    print("[Storytopia] Storyboard generation accepted: \(pendingGeneration.id).")

                    await MainActor.run {
                        // The journal link does not depend on the image, so it is written now rather
                        // than at completion, which may happen in a different session entirely.
                        linkEntryToJournalIfNeeded(
                            journalTitle: journalTitle,
                            clientEntryID: prepareResult.localDraftID
                        )
                        pendingStoryboardMonitor.track(pendingGeneration)
                        storyboardGenerationPhase = .generating
                    }

                    await refreshGenerationCreditBalance()
                    return
                }

                guard case .completed(let generation) = dispatch else {
                    return
                }

                print("[Storytopia] Storyboard generation completed in-session.")

                await MainActor.run {
                    storyboardGenerationPhase = .savingResult
                    setStoryboardGenerationGlobalStatus(
                        kind: .running,
                        entryID: prepareResult.localDraftID,
                        phase: .savingResult
                    )
                }

                print("[Storytopia] Saving generated storyboard.")
                // The function already uploaded the image and inserted the primary row, so the local
                // copy adopts that identity instead of creating a second storyboard.
                let storyboard = try GeneratedStoryboardStore.persistedStoryboard(
                    image: generation.image,
                    clientEntryID: prepareResult.localDraftID,
                    promptText: entryText,
                    artStyle: generation.artStyle,
                    generationQuality: generation.quality,
                    panelLayout: generation.panelLayout,
                    sourcePhotoCount: min(photoImages.count + entryCharacters.count, EntryCharacterRules.maxGenerationImageCount),
                    createdAt: generation.createdAt,
                    id: generation.storyboardID,
                    storagePath: generation.storagePath,
                    cloudSyncState: StoryboardCloudSyncState.synced.rawValue,
                    isPrimary: generation.isPrimary,
                    isSampleContent: authoringMode.isSampleStudio
                )
                print("[Storytopia] Storyboard saved.")

                var storyboardsAfterLocalSave = GeneratedStoryboardStore.merging(storyboard, into: GeneratedStoryboardStore.load())
                GeneratedStoryboardStore.save(storyboardsAfterLocalSave)

                // Nothing left to sync in either mode: the storyboard already exists in its bucket
                // and its table, written by the function that generated it. Sample Studio only has
                // to drop the cached pack so the studio reloads the new page.
                if authoringMode.isSampleStudio {
                    SupabaseSampleStoryService().invalidateSamplePackCache()
                }
                let storyboardForCompletion = storyboard
                storyboardsAfterLocalSave = GeneratedStoryboardStore.merging(storyboardForCompletion, into: storyboardsAfterLocalSave)
                GeneratedStoryboardStore.save(storyboardsAfterLocalSave)

                print("[Storytopia] Entry completion started.")
                print("[Storytopia] Marking entry completed.")
                let completionPayload = EntryDraftSavePayload(
                    id: prepareResult.localDraftID,
                    createdAt: generationPayload.createdAt,
                    title: generationPayload.title,
                    text: generationPayload.text,
                    richText: generationPayload.richText,
                    photos: generationPayload.photos,
                    characters: generationPayload.characters,
                    artStyle: generationPayload.artStyle,
                    location: generationPayload.location,
                    date: generationPayload.date,
                    datePrecision: generationPayload.datePrecision,
                    savesDraft: generationPayload.savesDraft,
                    isPrivate: generationPayload.isPrivate,
                    fontChoiceRawValue: generationPayload.fontChoiceRawValue,
                    textColorIndex: generationPayload.textColorIndex,
                    textSize: generationPayload.textSize,
                    paperStyleRawValue: generationPayload.paperStyleRawValue,
                    paperColorIndex: generationPayload.paperColorIndex,
                    isBold: generationPayload.isBold,
                    isItalic: generationPayload.isItalic,
                    isUnderlined: generationPayload.isUnderlined,
                    isStrikethrough: generationPayload.isStrikethrough,
                    isHighlighted: generationPayload.isHighlighted,
                    textAlignmentRawValue: generationPayload.textAlignmentRawValue
                )

                linkEntryToJournalIfNeeded(
                    journalTitle: journalTitle,
                    clientEntryID: prepareResult.localDraftID
                )

                let completionResult: EntrySaveResult
                if authoringMode.isSampleStudio {
                    completionResult = try await SupabaseSampleStoryService().markSampleEntryCompletedAfterStoryboardSaved(
                        payload: completionPayload
                    )
                    if case .failed(let message) = completionResult.state {
                        throw StoryboardGenerationError.openAIMessage(message)
                    }
                    if case .photoUploadFailed(let message) = completionResult.state {
                        throw StoryboardGenerationError.openAIMessage(message)
                    }
                } else {
                    completionResult = try await EntrySaveService().markEntryCompletedAfterStoryboardSaved(
                        payload: completionPayload,
                        isSignedIn: authStore.userID != nil
                    )
                }
                print("[Storytopia] Entry completion succeeded.")

                await MainActor.run {
                    activeDraftID = completionResult.localDraftID
                    setCloudSaveState(completionResult.state)
                    let completedSnapshot = currentDraftSnapshot(id: completionResult.localDraftID)
                    loadedDraftSnapshot = completedSnapshot
                    toolbarSavedSnapshot = completedSnapshot
                    markLocalDraftCommitted(id: completionResult.localDraftID, snapshot: completedSnapshot)
                    generatedStoryboards = storyboardsAfterLocalSave
                    GeneratedStoryboardStore.save(generatedStoryboards)
                    currentEntryStatus = .completed
                    isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
                    storyboardGenerationPhase = .completed
                    isGeneratingStoryboard = false
                    isShowingStoryboardGenerationProgress = false
                    addedJournalTitle = journalTitle
                    isOpeningCompletedEntryFromEntries = true
                    completedEntryOpenedStoryboardImage = storyboardForCompletion.image
                    selectedEntryStoryboardIndex = 0
                    isShowingEntryOptionsPage = true
                    setStoryboardGenerationGlobalStatus(
                        kind: .completed,
                        entryID: completionResult.localDraftID,
                        storyboard: storyboardForCompletion
                    )
                    NotificationCenter.default.post(name: .storytopiaGeneratedStoryboardsChanged, object: nil)
                    print("[Storytopia] Storyboard completion refreshed on Create page.")
                }

                await refreshGenerationCreditBalance()
            } catch {
                // Any charge and any refund happened inside the function, so the balance is read
                // back rather than adjusted locally.
                await refreshGenerationCreditBalance()

                await MainActor.run {
                    generationErrorMessage = error.localizedDescription
                    storyboardGenerationPhase = .failed
                    isGeneratingStoryboard = false
                    isShowingStoryboardGenerationProgress = false
                    setStoryboardGenerationGlobalStatus(
                        kind: .failed,
                        entryID: activeDraftID,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func refreshGenerationCreditBalance() async {
        await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
    }

    /// Paperclips the entry into its journal. Called at request time for fire-and-poll generations,
    /// because it depends on the entry rather than on the artwork, and the artwork may not arrive
    /// until a later session.
    private func linkEntryToJournalIfNeeded(journalTitle: String?, clientEntryID: UUID) {
        guard
            let journalTitle,
            let journalEntry = currentJournalEntry(id: clientEntryID)
        else {
            return
        }

        StoryEntryStore.upsert(journalEntry, to: journalTitle, syncsToCloud: false)
        onJournalEntryCreated(journalTitle, journalEntry)
        EntryJournalLinkStore.save(
            journalTitle: journalTitle,
            journalEntryID: journalEntry.id,
            for: clientEntryID
        )
    }

    /// A storyboard the monitor reconciled. The image, the local store, and the entry's completed
    /// status were all written by the pending-generation service; what is left is this page catching
    /// up to them — but only when the generation belongs to the entry currently open.
    private func adoptReconciledStoryboard(_ storyboard: GeneratedStoryboard) {
        guard
            let clientEntryID = storyboard.clientEntryID,
            clientEntryID == activeDraftID
        else {
            return
        }

        generatedStoryboards = GeneratedStoryboardStore.merging(storyboard, into: generatedStoryboards)
        currentEntryStatus = .completed
        isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
        loadedDraftSnapshot = currentDraftSnapshot(id: clientEntryID)
        toolbarSavedSnapshot = loadedDraftSnapshot
        storyboardGenerationPhase = .completed
        isGeneratingStoryboard = false
        isShowingStoryboardGenerationProgress = false
        addedJournalTitle = selectedEntryJournalTitle
        isOpeningCompletedEntryFromEntries = true
        completedEntryOpenedStoryboardImage = storyboard.image
        selectedEntryStoryboardIndex = 0
        isShowingEntryOptionsPage = true
    }

    /// The server declared this generation failed and settled its credits. The page stops waiting and
    /// shows the reason; the banner carries the refund wording.
    private func adoptReconciledFailure(_ failedStatus: StoryboardGenerationGlobalStatus) {
        guard failedStatus.entryID == activeDraftID else {
            return
        }

        generationErrorMessage = failedStatus.message
        storyboardGenerationPhase = .failed
        isGeneratingStoryboard = false
        isShowingStoryboardGenerationProgress = false
    }

    private func setStoryboardGenerationGlobalStatus(
        kind: StoryboardGenerationGlobalStatusKind,
        entryID: UUID? = nil,
        phase: StoryboardGenerationPhase? = nil,
        storyboard: GeneratedStoryboard? = nil,
        message: String? = nil
    ) {
        let statusID = storyboardGenerationStatus?.id ?? UUID()
        let resolvedEntryID = entryID ?? storyboard?.clientEntryID ?? storyboardGenerationStatus?.entryID ?? activeDraftID
        let resolvedJournalTitle = selectedEntryJournalTitle ?? storyboardGenerationStatus?.journalTitle
        let resolvedTitle: String
        let resolvedMessage: String

        switch kind {
        case .running:
            resolvedTitle = "Generating storyboard"
            resolvedMessage = phase?.progressTitle ?? "Your storyboard image is still in progress."
        case .completed:
            resolvedTitle = "Storyboard ready"
            if let resolvedJournalTitle {
                resolvedMessage = "Paperclipped to \(resolvedJournalTitle). Tap to view."
            } else {
                resolvedMessage = "Saved to this entry. Tap to view."
            }
        case .failed:
            resolvedTitle = "Storyboard failed"
            resolvedMessage = message ?? "Open the generator to try again."
        }

        withAnimation(.snappy(duration: 0.24)) {
            storyboardGenerationStatus = StoryboardGenerationGlobalStatus(
                id: statusID,
                entryID: resolvedEntryID,
                storyboardID: storyboard?.id ?? storyboardGenerationStatus?.storyboardID,
                title: resolvedTitle,
                message: resolvedMessage,
                journalTitle: resolvedJournalTitle,
                kind: kind,
                image: storyboard?.image ?? storyboardGenerationStatus?.image
            )
        }
    }

    private func showStoryboardGenerationProgressPreview() {
        dismissKeyboard()

        if !isGeneratingStoryboard {
            storyboardGenerationPhase = .generating
        }

        isShowingStoryboardGenerationProgress = true
    }

    private var layoutPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFullScreenEditorVisible {
                fullScreenEditorContent
            } else {
                createEntryContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(pageTapBackground)
            }
        }
        .background(selectedPaperSurfaceColor)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if !isFullScreenEditorVisible {
                createToolbarItems(
                    title: editorToolbarTitle,
                    showsCloseButton: true,
                    showsJournalDestinationButton: true
                )
            }
        }
        .toolbar(isFullScreenEditorVisible ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(usesPaperImageBackground ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(selectedPageBackgroundColor, for: .navigationBar)
        .guardedInteractivePopGesture(
            shouldAllowPop: { canExitWithoutConfirmation },
            onBlockedPop: { requestExit() }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            KeyboardCornerRadiusRemover.removeKeyboardCornerRadius()
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                let keyboardHeight = keyboardFrame.height
                if keyboardHeight > 120 {
                    lastKeyboardHeight = keyboardHeight
                }
            }
            withAnimation(.snappy(duration: 0.22)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy(duration: 0.22)) {
                isKeyboardVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .storytopiaGeneratedStoryboardsChanged)) { _ in
            refreshCurrentEntryStoryboardsFromStore()
        }
    }

    private var entryOptionsPage: some View {
        ScrollView(showsIndicators: false) {
            entryOptionsStepContent
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(pageTapBackground)
        .background(Color.homePageBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            createToolbarItems(title: "Entry Details", showsCloseButton: false)
        }
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .enableInteractivePopGesture()
        .task {
            // This screen quotes the balance and spends against it, so it reads its own copy
            // instead of trusting whatever Home or Settings last cached.
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
    }

    private var fullScreenEditorContent: some View {
        GeometryReader { proxy in
            let scrollContentHeight = editorScrollContentHeight(for: proxy.size.height)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    NotebookPaperBackground(
                        paperColor: selectedPaperSurfaceColor,
                        paperImageName: selectedPaperStyleChoice.backgroundImageName,
                        showsPaperWash: false,
                        showsRuledLines: selectedPaperStyleChoice.showsRuledLines,
                        showsNotebookChrome: selectedPaperStyleChoice.showsNotebookChrome,
                        firstRuledLineY: NotebookMetrics.firstNotebookRuleY
                    )
                    .frame(maxWidth: .infinity, minHeight: scrollContentHeight, maxHeight: .infinity)

                    NotebookEditorContent(
                        storyTitle: $storyTitle,
                        entryText: $entryText,
                        entryRichText: $entryRichText,
                        isTitleFocused: $isTitleFocused,
                        editorFocusRequestID: editorFocusRequestID,
                        editorBlurRequestID: editorBlurRequestID,
                        formattingRequest: textFormattingRequest,
                        isDictating: speechTranscriber.state.isListening,
                        dictationTranscriptRequest: dictationTranscriptRequest,
                        bodyPlaceholder: "Start writing...",
                        scrollsInternally: false,
                        pageHeight: scrollContentHeight,
                        textStyle: selectedTextStyle,
                        showsTitleRule: selectedPaperStyleChoice.showsNotebookChrome,
                        leadingContentPadding: selectedPaperStyleChoice.leadingContentPadding,
                        leadingTextPadding: selectedPaperStyleChoice.leadingTextPadding,
                        usesTexturedPaperEffect: selectedPaperStyleChoice.usesTexturedPaperTextEffect,
                        onBodyTap: {
                            isTitleFocused = false
                            editorFocusRequestID += 1
                        },
                        onSelectionStateChange: updateEditorSelectionState,
                        onTitleSubmit: {
                            editorFocusRequestID += 1
                        }
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: scrollContentHeight)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(selectedPaperSurfaceColor)
            .notebookPageChrome()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isKeyboardVisible {
                    fullScreenKeyboardBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: isKeyboardVisible)
        }
        .background(selectedPaperSurfaceColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullScreenKeyboardBar: some View {
        HStack {
            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    isFullScreenEditorVisible = false
                }
            } label: {
                editorFloatingToolIcon {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Create controls")
        }
        .padding(.horizontal, 31)
        .padding(.vertical, 8)
    }

    private var pageTapBackground: some View {
        Color.homePageBackground.opacity(usesPaperImageBackground ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                handleEditorPageTap()
            }
    }

    @ViewBuilder
    private var pageBackground: some View {
        if let paperImageName = selectedPaperStyleChoice.backgroundImageName {
            GeometryReader { proxy in
                Image(paperImageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        } else {
            Color.homePageBackground
        }
    }

    @ToolbarContentBuilder
    private func createToolbarItems(
        title: String,
        showsCloseButton: Bool,
        showsEntryDateButton: Bool = false,
        showsJournalDestinationButton: Bool = false
    ) -> some ToolbarContent {
        if showsCloseButton {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    requestExit()
                } label: {
                    Image(systemName: presentation.closeButtonSystemName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.72))
                        .frame(width: 40, height: 38)
                        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.homeBorder.opacity(0.95), lineWidth: 1)
                        )
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .frame(width: showsTrailingToolbarAction ? 94 : 48, alignment: .leading)
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.closeButtonAccessibilityLabel)
                .disabled(isBlockingSaveInProgress)
            }
            .hideSharedBackgroundIfAvailable()
        }

        ToolbarItem(placement: .principal) {
            if showsJournalDestinationButton {
                createToolbarJournalButton
            } else if showsEntryDateButton {
                Button {
                    openEntryDateSheet()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.homeAccent)

                        Text(entryDateMetadataText)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .foregroundStyle(Color.storyInk.opacity(0.62))

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.storyInk.opacity(0.62))
                    }
                    .frame(maxWidth: 210)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Entry date, \(entryDateMetadataText)")
            } else {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundColor(Color.storyGray.opacity(0.46))
            }
        }

        if showsToolbarSaveButton {
            ToolbarItem(placement: .topBarTrailing) {
                toolbarSaveActionButton
            }
            .hideSharedBackgroundIfAvailable()
        }
    }

    private var createToolbarJournalButton: some View {
        Button {
            dismissKeyboard()
            isShowingAddToJournalPage = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.storyGray.opacity(0.46))

                Text(selectedEntryJournalTitle ?? "Add To Journal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.storyGray.opacity(0.46))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            .frame(maxWidth: 210)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedEntryJournalTitle.map { "Journal, \($0)" } ?? "Add To Journal")
    }

    private var toolbarSaveActionButton: some View {
        Button {
            performToolbarSave()
        } label: {
            HStack(spacing: 4) {
                if isToolbarSaveInProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.storyPurple)
                }

                Text(toolbarSaveButtonTitle)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)

            }
            .frame(width: 82, height: 38)
            .foregroundStyle(toolbarSaveButtonColor)
            .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.95), lineWidth: 1)
            )
            .frame(width: 94, height: 48)
            .contentShape(Rectangle())
            .opacity(canUseToolbarSaveButton || isToolbarSaveInProgress ? 1 : 0.52)
            .animation(.snappy(duration: 0.18), value: isToolbarSaveInProgress)
        }
        .buttonStyle(.plain)
        .disabled(!canUseToolbarSaveButton || isToolbarSaveInProgress)
    }

    private var showsTrailingToolbarAction: Bool {
        showsToolbarSaveButton
    }

    private var showsToolbarSaveButton: Bool {
        presentation.showsNextButton
            || presentation.isEditDraft
            || presentation.savesDirectlyToJournal
    }

    private func handleEditorPageTap() {
        dismissKeyboard()
    }

    private func handleBodyEditorTap() {
        isTitleFocused = false
        editorFocusRequestID += 1
    }

    private var canUseToolbarSaveButton: Bool {
        if isToolbarSaveInProgress {
            return false
        }

        if isToolbarContentSaved {
            return false
        }

        if presentation.isEditDraft {
            return hasUnsavedDraftChanges
        }

        return hasDraftContent
    }

    private var toolbarSaveButtonColor: Color {
        if isToolbarSaveInProgress {
            return Color.storyPurple
        }

        return canUseToolbarSaveButton ? Color.storyPurple : Color.storyGray.opacity(0.42)
    }

    private var toolbarSaveButtonTitle: String {
        if isToolbarSaveInProgress {
            return "Saving"
        }

        return "Save"
    }

    private var isBlockingSaveInProgress: Bool {
        switch cloudSaveState {
        case .saving, .uploadingPhotos:
            return true
        case .idle, .saved, .savedLocally, .photosUploaded, .failed, .photoUploadFailed, .notSaved:
            return false
        }
    }

    private var hasUnconfirmedCloudSave: Bool {
        switch cloudSaveState {
        case .failed, .photoUploadFailed, .notSaved:
            return true
        case .idle, .saving, .saved, .savedLocally, .uploadingPhotos, .photosUploaded:
            return false
        }
    }

    private var saveProgressTitle: String {
        switch cloudSaveState {
        case .uploadingPhotos:
            return "Uploading photos..."
        default:
            return "Saving..."
        }
    }

    private var saveProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 13) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.storyPurple)

                Text(saveProgressTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.storyPurple.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(saveProgressTitle)
    }

    private var showsToolbarSavedState: Bool {
        showsToolbarSavedFeedback && isToolbarContentSaved
    }

    private var isToolbarContentSaved: Bool {
        guard let toolbarSavedSnapshot else {
            return false
        }

        return currentDraftSnapshot(id: toolbarSavedSnapshot.id) == toolbarSavedSnapshot
    }

    private func performToolbarSave() {
        guard !isToolbarSaveInProgress else {
            return
        }

        if presentation.isEditDraft {
            saveEditedDraftChanges()
        } else if presentation.savesDirectlyToJournal {
            beginToolbarSavedFeedback()
            saveDirectJournalEntryInPlace()
        } else {
            saveDraftInPlace()
        }
    }

    private var hasDraftContent: Bool {
        !storyTitle.isEmpty
            || !entryText.isEmpty
            || storyboardPhotos.contains { $0 != nil }
            || !entryCharacters.isEmpty
            || hasUnsavedEntryMetadata
            || hasUnsavedEntryOptions
    }

    private var hasUnsavedEntryMetadata: Bool {
        didEditEntryDate
            || !storyLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUnsavedEntryOptions: Bool {
        selectedArtStyle != Self.defaultArtStyle
            || savesDraft != true
            || isPrivateEntry
            || selectedFontChoice != .sans
            || selectedTextColorIndex != 0
            || previewTextSize != CreateEntryTextSize.defaultSliderValue
            || selectedPaperStyleChoice != .defaultChoice
            || selectedPaperColorIndex != 0
    }

    private var hasUnsavedDraftChanges: Bool {
        // An entry reopened after a relaunch matches the copy on disk, but that copy may itself be
        // an autosave that never reached Supabase. The draft's own flag is the only thing that
        // still remembers, so it has to count as unsaved here — otherwise the Save prompt would
        // stay silent over work the cloud has never seen.
        if hasUncommittedLocalEdits {
            return true
        }

        guard let loadedDraftSnapshot else {
            return hasDraftContent
        }

        return currentDraftSnapshot(id: loadedDraftSnapshot.id) != loadedDraftSnapshot
    }

    private var hasUnsavedReferencePhotoChanges: Bool {
        guard let loadedDraftSnapshot else {
            return storyboardPhotos.contains { $0 != nil }
        }

        return currentReferencePhotoIDs != loadedDraftSnapshot.photoIDs
    }

    private var hasUnsavedCharacterChanges: Bool {
        guard let loadedDraftSnapshot else {
            return !entryCharacters.isEmpty
        }

        return currentCharacterSnapshots != loadedDraftSnapshot.characters
    }

    private var hasUnsavedEntryMediaChanges: Bool {
        hasUnsavedReferencePhotoChanges || hasUnsavedCharacterChanges
    }

    private var canExitWithoutConfirmation: Bool {
        !isBlockingSaveInProgress
            && !hasUnsavedDraftChanges
            && !hasUnconfirmedCloudSave
    }

    private var currentReferencePhotoIDs: [UUID] {
        storyboardPhotos.compactMap { $0?.id }
    }

    private var currentCharacterSnapshots: [LoadedCreateEntryDraftSnapshot.CharacterSnapshot] {
        entryCharacters.map {
            LoadedCreateEntryDraftSnapshot.CharacterSnapshot(
                id: $0.id,
                name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                role: $0.role,
                sourcePhotoID: $0.sourcePhotoID,
                updatedAt: $0.updatedAt
            )
        }
    }

    private func requestExit() {
        dismissKeyboard()

        guard !isBlockingSaveInProgress else {
            return
        }

        if hasUnsavedDraftChanges || hasUnconfirmedCloudSave {
            isShowingExitConfirmation = true
        } else {
            closeEditorWithoutSaving()
        }
    }

    private func closeEditorWithoutSaving() {
        isAutosaveSuspended = true
        cancelPendingLocalAutosave()
        dismissKeyboard()
        withAnimation(.snappy(duration: 0.32)) {
            dismissCreate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if selectedPage != .create {
                clearEditor()
                activeDraftID = nil
                isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
            }
        }
    }

    private func saveDraftAndExit() {
        saveDraftAndExit(forceSave: false)
    }

    private func saveEditedDraftChanges() {
        dismissKeyboard()
        beginToolbarSavedFeedback()
        setCloudSaveState((storyboardPhotos.compactMap { $0 }).isEmpty ? .saving : .uploadingPhotos)

        Task {
            await saveDraftToLocalAndCloud(forceSave: true, navigatesToOptions: false)
        }
    }

    private func saveDraftInPlace() {
        dismissKeyboard()
        beginToolbarSavedFeedback()
        setCloudSaveState((storyboardPhotos.compactMap { $0 }).isEmpty ? .saving : .uploadingPhotos)

        Task {
            await saveDraftToLocalAndCloud(forceSave: false, navigatesToOptions: false)
        }
    }

    private func beginToolbarSavedFeedback() {
        toolbarSaveFeedbackVersion += 1
        isToolbarSaveInProgress = true
        showsToolbarSavedFeedback = false
    }

    private func completeToolbarSavedFeedback(for snapshot: LoadedCreateEntryDraftSnapshot) {
        let feedbackVersion = toolbarSaveFeedbackVersion

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard toolbarSaveFeedbackVersion == feedbackVersion, toolbarSavedSnapshot == snapshot else {
                return
            }

            isToolbarSaveInProgress = false
            showsToolbarSavedFeedback = isToolbarContentSaved

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                guard toolbarSaveFeedbackVersion == feedbackVersion, toolbarSavedSnapshot == snapshot else {
                    return
                }

                showsToolbarSavedFeedback = false
            }
        }
    }

    private func cancelToolbarSavedFeedback() {
        toolbarSaveFeedbackVersion += 1
        isToolbarSaveInProgress = false
        showsToolbarSavedFeedback = false
    }

    private func setCloudSaveState(_ state: EntryCloudSaveState) {
        cloudSaveDismissVersion += 1
        let dismissVersion = cloudSaveDismissVersion

        withAnimation(.snappy(duration: 0.22)) {
            cloudSaveState = state
        }

        guard state.shouldDismissAutomatically else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard cloudSaveDismissVersion == dismissVersion, cloudSaveState == state else {
                return
            }

            withAnimation(.snappy(duration: 0.24)) {
                cloudSaveState = .idle
            }
        }
    }

    private func saveFromExitConfirmation() {
        if presentation.savesDirectlyToJournal {
            saveDirectJournalEntryAndExit()
            return
        }

        saveDraftAndExit(forceSave: presentation.isEditDraft)
    }

    private func saveDraftAndExit(forceSave: Bool) {
        dismissKeyboard()
        // The cloud save below is about to write the same content this would have written, so the
        // queued autosave is redundant at best and stale by the time it fires at worst.
        cancelPendingLocalAutosave()

        Task {
            if hasDraftContent || forceSave {
                let saveState = await saveDraftToLocalAndCloud(forceSave: forceSave, navigatesToOptions: false)
                guard saveState?.isConfirmedSave == true else {
                    return
                }
            }

            isAutosaveSuspended = true
            withAnimation(.snappy(duration: 0.32)) {
                dismissCreate()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if selectedPage != .create {
                    clearEditor()
                    activeDraftID = nil
                }
            }
        }
    }

    // MARK: - Local autosave
    //
    // Local autosave is data-loss protection, not synchronization. It writes the editor's current
    // state into the same `CreateEntryDraftStore` everything else reads and never touches Supabase,
    // so the user can write for an hour at the cost of a few small local writes. Committing to the
    // cloud stays the explicit Save button's job.

    /// Sample Studio authors against cloud sample rows in a mode of its own, and a read-only
    /// completed entry has no edits to protect, so neither takes part.
    private var supportsLocalAutosave: Bool {
        // Signed out there is nowhere for an autosave to go: the draft store resolves to the
        // anonymous scope, and data-loss protection that hands the writing to a different account
        // is worse than none.
        contentMode.canPersistUserContent && !opensExistingEntryReadMode
    }

    /// The editor's persisted state as one value, cheap enough to rebuild on every body pass: it
    /// touches only editor state, never the draft on disk.
    private var currentAutosaveSignature: CreateEntryAutosaveSignature {
        CreateEntryAutosaveSignature(
            title: storyTitle,
            text: entryText,
            richText: entryRichText,
            photoIDs: currentReferencePhotoIDs,
            characters: currentCharacterSnapshots,
            artStyle: selectedArtStyle,
            location: storyLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            date: storyDate,
            datePrecision: storyDatePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivateEntry,
            statusRawValue: currentEntryStatus.rawValue,
            fontChoiceRawValue: selectedFontChoice.rawValue,
            textColorIndex: selectedTextColorIndex,
            textSize: previewTextSize,
            paperStyleRawValue: selectedPaperStyleChoice.rawValue,
            paperColorIndex: selectedPaperColorIndex
        )
    }

    /// Called whenever the persisted editor state changes. Programmatic changes — hydration,
    /// `clearEditor`, adopting a saved snapshot — reach this too, which is why the write itself
    /// re-checks whether anything actually differs rather than trusting the trigger.
    private func handleEditorContentChange() {
        guard supportsLocalAutosave, !isAutosaveSuspended else {
            return
        }

        autosaveScheduler.schedule {
            performLocalAutosave()
        }
    }

    private func cancelPendingLocalAutosave() {
        autosaveScheduler.cancelPending()
    }

    /// Writes now instead of waiting out the debounce, for the moments where the wait may never
    /// finish: the app going to the background, and the editor going away.
    private func flushLocalAutosave() {
        autosaveScheduler.flush {
            performLocalAutosave()
        }
    }

    private func performLocalAutosave() {
        guard supportsLocalAutosave, !isAutosaveSuspended else {
            return
        }

        // A cloud save in flight owns this draft. Letting an autosave interleave would re-flag
        // content as uncommitted that Supabase is in the middle of confirming.
        guard !isBlockingSaveInProgress, !isToolbarSaveInProgress, !isGeneratingStoryboard else {
            return
        }

        guard hasDraftContent, hasUnsavedDraftChanges else {
            return
        }

        // Nothing has changed since the last local write, so there is nothing to protect.
        if let autosavedDraftSnapshot,
           currentDraftSnapshot(id: autosavedDraftSnapshot.id) == autosavedDraftSnapshot {
            return
        }

        let isNewComposeSession = activeDraftID == nil

        if let draftID = activeDraftID,
           !hasMediaChangesSinceLastAutosave,
           CreateEntryDraftStore.exists(id: draftID) {
            let richText = currentEntryRichText()
            let formatting = currentEntryPreviewFormatting(from: richText)
            let didWrite = CreateEntryDraftStore.autosaveEditorState(
                id: draftID,
                title: storyTitle,
                text: entryText,
                richText: richText,
                artStyle: selectedArtStyle,
                location: storyLocation.trimmingCharacters(in: .whitespacesAndNewlines),
                date: storyDate,
                datePrecision: storyDatePrecision,
                savesDraft: savesDraft,
                isPrivate: isPrivateEntry,
                fontChoiceRawValue: selectedFontChoice.rawValue,
                textColorIndex: selectedTextColorIndex,
                textSize: previewTextSize,
                paperStyleRawValue: selectedPaperStyleChoice.rawValue,
                paperColorIndex: selectedPaperColorIndex,
                isBold: formatting.isBold,
                isItalic: formatting.isItalic,
                isUnderlined: formatting.isUnderlined,
                isStrikethrough: formatting.isStrikethrough,
                isHighlighted: formatting.isHighlighted,
                textAlignmentRawValue: formatting.textAlignmentRawValue
            )

            if didWrite {
                finishLocalAutosave(id: draftID, isNewComposeSession: false)
                return
            }
        }

        // Either the draft has no directory yet or its photos and characters moved, so the full
        // write — the one that re-encodes media — is the only one that captures the truth.
        guard
            let pendingSave = makePendingDraftSave(forceSave: false),
            let savedDraftID = persistDraftSave(pendingSave, cloudSyncState: .uncommitted)
        else {
            return
        }

        finishLocalAutosave(id: savedDraftID, isNewComposeSession: isNewComposeSession)
    }

    private var hasMediaChangesSinceLastAutosave: Bool {
        guard let autosavedDraftSnapshot else {
            return true
        }

        return currentReferencePhotoIDs != autosavedDraftSnapshot.photoIDs
            || currentCharacterSnapshots != autosavedDraftSnapshot.characters
    }

    private func finishLocalAutosave(id: UUID, isNewComposeSession: Bool) {
        if isNewComposeSession {
            // A brand-new entry now has the local identity it will keep all the way into Supabase:
            // `client_entry_id` is the same id on both sides, so committing it later updates this
            // draft rather than creating a second one.
            autosaveAdoptedDraftID = id
            activeDraftID = id
            UnfinishedCreateSessionStore.setDraftID(id)
        }

        hasUncommittedLocalEdits = true
        autosavedDraftSnapshot = currentDraftSnapshot(id: id)
    }

    /// Retires everything that says "this draft is ahead of the cloud", in one place so the flag,
    /// the snapshot, and the recovery pointer cannot drift apart. Called only once Supabase has
    /// confirmed the entry.
    private func markLocalDraftCommitted(id: UUID, snapshot: LoadedCreateEntryDraftSnapshot) {
        cancelPendingLocalAutosave()
        hasUncommittedLocalEdits = false
        autosavedDraftSnapshot = snapshot
        UnfinishedCreateSessionStore.clearIfMatches(draftID: id)
    }

    /// Picks the unfinished compose back up when the user returns to a fresh Create page, instead
    /// of handing them an empty editor and leaving their writing stranded on disk.
    private func restoreUnfinishedComposeIfNeeded() {
        guard
            supportsLocalAutosave,
            activeDraftID == nil,
            !presentation.isEditDraft,
            !presentation.savesDirectlyToJournal,
            !isOpeningEntryFromEntries
        else {
            return
        }

        guard let recoveredDraftID = UnfinishedCreateSessionStore.draftID else {
            return
        }

        guard CreateEntryDraftStore.exists(id: recoveredDraftID) else {
            UnfinishedCreateSessionStore.clear()
            return
        }

        activeDraftID = recoveredDraftID
        loadLinkedJournalTitle(for: recoveredDraftID)
        loadSavedDraftIfNeeded()
        currentEntryStatus = resolvedCurrentEntryStatus()
    }

    private func makePendingDraftSave(forceSave: Bool) -> PendingCreateEntryDraftSave? {
        guard hasDraftContent || forceSave else {
            return nil
        }

        let normalizedLocation = storyLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let richText = currentEntryRichText()
        let richTextFormatting = currentEntryPreviewFormatting(from: richText)

        return PendingCreateEntryDraftSave(
            id: activeDraftID,
            createdAt: activeDraftID.flatMap { CreateEntryDraftStore.createdAt(id: $0) }
                ?? loadedDraftSnapshot?.createdAt,
            title: storyTitle,
            text: entryText,
            richText: richText,
            photos: storyboardPhotos.compactMap { $0 },
            characters: entryCharacters,
            artStyle: selectedArtStyle,
            location: normalizedLocation,
            date: storyDate,
            datePrecision: storyDatePrecision,
            savesDraft: savesDraft,
            isPrivate: isPrivateEntry,
            fontChoiceRawValue: selectedFontChoice.rawValue,
            textColorIndex: selectedTextColorIndex,
            textSize: previewTextSize,
            paperStyleRawValue: selectedPaperStyleChoice.rawValue,
            paperColorIndex: selectedPaperColorIndex,
            isBold: richTextFormatting.isBold,
            isItalic: richTextFormatting.isItalic,
            isUnderlined: richTextFormatting.isUnderlined,
            isStrikethrough: richTextFormatting.isStrikethrough,
            isHighlighted: richTextFormatting.isHighlighted,
            textAlignmentRawValue: richTextFormatting.textAlignmentRawValue
        )
    }

    private func currentEntryPreviewFormatting(from richText: NotebookRichTextDocument?) -> EntryPreviewFormattingSummary {
        let runs = richText?.formattingRuns ?? []
        return EntryPreviewFormattingSummary(
            isBold: runs.contains { $0.isBold },
            isItalic: runs.contains { $0.isItalic },
            isUnderlined: runs.contains { $0.isUnderlined },
            isStrikethrough: runs.contains { $0.isStrikethrough },
            isHighlighted: false,
            textAlignmentRawValue: "leading"
        )
    }

    @discardableResult
    private func persistDraftSave(
        _ pendingSave: PendingCreateEntryDraftSave,
        cloudSyncState: CreateEntryDraftCloudSyncState = .unchanged
    ) -> UUID? {
        let draftThumbnail = DraftThumbnailRenderer.render(
            title: pendingSave.title,
            text: pendingSave.text,
            richText: pendingSave.richText,
            photos: [],
            fontChoiceRawValue: pendingSave.fontChoiceRawValue,
            textColorIndex: pendingSave.textColorIndex,
            textSize: pendingSave.textSize,
            paperStyleRawValue: pendingSave.paperStyleRawValue,
            paperColorIndex: pendingSave.paperColorIndex,
            isBold: pendingSave.isBold,
            isItalic: pendingSave.isItalic,
            isUnderlined: pendingSave.isUnderlined,
            isStrikethrough: pendingSave.isStrikethrough,
            isHighlighted: pendingSave.isHighlighted,
            textAlignmentRawValue: pendingSave.textAlignmentRawValue
        )

        if let savedDraftID = CreateEntryDraftStore.save(
            id: pendingSave.id,
            title: pendingSave.title,
            text: pendingSave.text,
            richText: pendingSave.richText,
            referencePhotos: pendingSave.photos,
            characters: pendingSave.characters,
            artStyle: pendingSave.artStyle,
            location: pendingSave.location,
            date: pendingSave.date,
            datePrecision: pendingSave.datePrecision,
            savesDraft: pendingSave.savesDraft,
            isPrivate: pendingSave.isPrivate,
            status: currentEntryStatus,
            fontChoiceRawValue: pendingSave.fontChoiceRawValue,
            textColorIndex: pendingSave.textColorIndex,
            textSize: pendingSave.textSize,
            paperStyleRawValue: pendingSave.paperStyleRawValue,
            paperColorIndex: pendingSave.paperColorIndex,
            isBold: pendingSave.isBold,
            isItalic: pendingSave.isItalic,
            isUnderlined: pendingSave.isUnderlined,
            isStrikethrough: pendingSave.isStrikethrough,
            isHighlighted: pendingSave.isHighlighted,
            textAlignmentRawValue: pendingSave.textAlignmentRawValue,
            thumbnail: draftThumbnail,
            createdAt: pendingSave.createdAt,
            cloudSyncState: cloudSyncState
        ) {
            EntryLocationRecentStore.add(pendingSave.location)
            recentEntryLocations = EntryLocationRecentStore.all
            return savedDraftID
        }

        return nil
    }

    private func makeEntryDraftSavePayload(forceSave: Bool) -> EntryDraftSavePayload? {
        guard let pendingSave = makePendingDraftSave(forceSave: forceSave) else {
            return nil
        }

        return EntryDraftSavePayload(
            id: pendingSave.id ?? UUID(),
            createdAt: pendingSave.createdAt,
            title: pendingSave.title,
            text: pendingSave.text,
            richText: pendingSave.richText,
            photos: pendingSave.photos,
            characters: pendingSave.characters,
            artStyle: pendingSave.artStyle,
            location: pendingSave.location,
            date: pendingSave.date,
            datePrecision: pendingSave.datePrecision,
            savesDraft: pendingSave.savesDraft,
            isPrivate: pendingSave.isPrivate,
            fontChoiceRawValue: pendingSave.fontChoiceRawValue,
            textColorIndex: pendingSave.textColorIndex,
            textSize: pendingSave.textSize,
            paperStyleRawValue: pendingSave.paperStyleRawValue,
            paperColorIndex: pendingSave.paperColorIndex,
            isBold: pendingSave.isBold,
            isItalic: pendingSave.isItalic,
            isUnderlined: pendingSave.isUnderlined,
            isStrikethrough: pendingSave.isStrikethrough,
            isHighlighted: pendingSave.isHighlighted,
            textAlignmentRawValue: pendingSave.textAlignmentRawValue
        )
    }

    @discardableResult
    private func saveDraftToLocalAndCloud(forceSave: Bool, navigatesToOptions: Bool) async -> EntryCloudSaveState? {
        guard canPersistEntry else {
            // Saving signed out used to succeed: `EntrySaveService` wrote a local draft into the
            // anonymous scope and marked it cloud-synchronized, so the toolbar reported "Saved" for
            // an entry no account would ever hold — and which the next account to sign in inherited.
            cancelToolbarSavedFeedback()
            signInGate.requireAccount(for: .saveEntry, retry: {
                Task {
                    await saveDraftToLocalAndCloud(forceSave: forceSave, navigatesToOptions: navigatesToOptions)
                }
            })
            return nil
        }

        guard let payload = makeEntryDraftSavePayload(forceSave: forceSave) else {
            cancelToolbarSavedFeedback()
            if navigatesToOptions && canShowEntryOptionsPage {
                isShowingEntryOptionsPage = true
            }
            return nil
        }

        stageSelectedJournalMemberships(for: payload.id)
        // The explicit save is the cloud checkpoint. Nothing local should still be waiting to write
        // behind it.
        cancelPendingLocalAutosave()
        setCloudSaveState(payload.photos.isEmpty ? .saving : .uploadingPhotos)

        do {
            let result: EntrySaveResult
            if authoringMode.isSampleStudio {
                result = try await SupabaseSampleStoryService().saveSampleEntry(
                    payload: payload,
                    status: currentEntryStatus
                )
            } else {
                result = try await EntrySaveService().saveEntryPreservingStatus(
                    payload: payload,
                    isSignedIn: authStore.userID != nil,
                    status: currentEntryStatus
                )
            }
            activeDraftID = result.localDraftID
            isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
            recentEntryLocations = EntryLocationRecentStore.all
            setCloudSaveState(result.state)

            if result.state.isConfirmedSave {
                let savedSnapshot = currentDraftSnapshot(id: result.localDraftID)
                loadedDraftSnapshot = savedSnapshot
                toolbarSavedSnapshot = savedSnapshot
                if editorMatchesCommittedPayload(payload) {
                    markLocalDraftCommitted(id: result.localDraftID, snapshot: savedSnapshot)
                } else {
                    // The user kept typing while the save was in flight, so what reached Supabase is
                    // already behind the editor. Keep the draft flagged as ahead of the cloud and
                    // give the newer text an autosave of its own rather than declaring it committed.
                    hasUncommittedLocalEdits = true
                    autosavedDraftSnapshot = nil
                    handleEditorContentChange()
                }
                completeToolbarSavedFeedback(for: savedSnapshot)
            } else {
                cancelToolbarSavedFeedback()
            }

            if result.state.isConfirmedSave && navigatesToOptions && canShowEntryOptionsPage {
                isShowingEntryOptionsPage = true
            }

            return result.state
        } catch {
            setCloudSaveState(.failed("Could not save this entry locally."))
            cancelToolbarSavedFeedback()
            return .failed("Could not save this entry locally.")
        }
    }

    /// Whether the editor still holds exactly the writing that was sent to Supabase. A cloud save
    /// takes real time, and anything typed during it is not in the payload that landed.
    private func editorMatchesCommittedPayload(_ payload: EntryDraftSavePayload) -> Bool {
        payload.title == storyTitle
            && payload.text == entryText
            && payload.richText == currentEntryRichText()
    }

    private func retryCloudSave() {
        guard !isToolbarSaveInProgress else {
            return
        }

        beginToolbarSavedFeedback()
        Task {
            await saveDraftToLocalAndCloud(forceSave: true, navigatesToOptions: false)
        }
    }

    private func discardDraftAndExit() {
        // Suspending and cancelling first is what makes the rest of this deterministic: no queued
        // write can land between here and the moment the local draft is removed, and the flush in
        // `onDisappear` will find autosave suspended.
        isAutosaveSuspended = true
        cancelPendingLocalAutosave()

        var discardOutcome: DiscardLocalEditsPolicy.Outcome?
        if let activeDraftID {
            // A compose session that never reached Supabase is identified by the recovery pointer,
            // not by the presentation: adopting an autosaved id flips this page to "edit" even
            // though nothing has been saved anywhere.
            let outcome = DiscardLocalEditsPolicy.outcome(
                isUnfinishedCompose: UnfinishedCreateSessionStore.draftID == activeDraftID,
                hasUncommittedLocalEdits: hasUncommittedLocalEdits
                    || CreateEntryDraftStore.hasUncommittedLocalEdits(id: activeDraftID),
                hasCommittedCloudVersion: hasCommittedCloudVersion(of: activeDraftID)
            )
            applyDiscardOutcome(outcome, for: activeDraftID)
            discardOutcome = outcome
        }

        if discardOutcome == .deleteUnfinishedCompose {
            clearEditor()
            activeDraftID = nil
            isDraftSaved = CreateEntryDraftStore.hasSavedDrafts()
            withAnimation(.snappy(duration: 0.32)) {
                dismissCreate()
            }
            return
        }

        if presentation.isEditDraft {
            closeEditorWithoutSaving()
            return
        }

        clearEditor()
        activeDraftID = nil
        isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
        withAnimation(.snappy(duration: 0.32)) {
            dismissCreate()
        }
    }

    /// Whether Supabase holds a committed version of this entry for a discard to fall back to.
    /// Sample Studio entries live in their own tables and never autosave, and an entry whose save
    /// gave up is on this device only — neither has a committed copy to restore.
    private func hasCommittedCloudVersion(of draftID: UUID) -> Bool {
        authStore.userID != nil
            && !authoringMode.isSampleStudio
            && !EntryCloudSyncFailureStore.isNotSaved(clientEntryID: draftID)
    }

    private func applyDiscardOutcome(_ outcome: DiscardLocalEditsPolicy.Outcome, for draftID: UUID) {
        hasUncommittedLocalEdits = false
        autosavedDraftSnapshot = nil

        switch outcome {
        case .deleteUnfinishedCompose:
            CreateEntryDraftStore.delete(id: draftID)
            UnfinishedCreateSessionStore.clear()
            EntryCloudSyncFailureStore.clear(clientEntryID: draftID)
        case .deleteLocalCache:
            // The committed version is in Supabase, so the local draft is a cache of it and the
            // discarded writing is the only thing in that cache that is not. Deleting it is what
            // makes the discard immediate and total: nothing is left to reappear offline, and the
            // next open has to rematerialize the committed entry. Storyboards and journal links
            // are keyed by client entry id in their own stores and are deliberately untouched.
            CreateEntryDraftStore.delete(id: draftID)
            loadedDraftSnapshot = nil
        case .keepLocalCopy:
            // Nothing committed anywhere to restore, so the user's only copy stays put. It stops
            // claiming to be ahead of the cloud so a later download may still refresh it.
            CreateEntryDraftStore.markCloudSynchronized(id: draftID)
        }
    }

    private func clearEditor() {
        // The reset is about to blank every binding autosave watches. Dropping the pending write
        // first is what stops an empty editor from being written over the draft it just left.
        cancelPendingLocalAutosave()
        autosavedDraftSnapshot = nil
        hasUncommittedLocalEdits = false
        autosaveAdoptedDraftID = nil
        storyTitle = ""
        entryText = ""
        entryRichText = nil
        storyboardPhotos = Array(repeating: nil, count: 5)
        entryCharacters = []
        characterEditorSession = nil
        toolbarSavedSnapshot = nil
        toolbarSavedJournalEntryID = nil
        setCloudSaveState(.idle)
        storyboardGenerationPhase = .ready
        showsToolbarSavedFeedback = false
        isToolbarSaveInProgress = false
        toolbarSaveFeedbackVersion += 1
        selectedArtStyle = Self.defaultArtStyle
        storyLocation = ""
        storyDate = Date()
        storyDatePrecision = .noDate
        didEditEntryDate = false
        didEditEntryLocation = false
        savesDraft = true
        isPrivateEntry = false
        currentEntryStatus = .draft
        selectedFontChoice = .sans
        selectedTextColorIndex = 0
        previewTextSize = CreateEntryTextSize.defaultSliderValue
        textFormattingRequest = nil
        selectedPaperStyleChoice = .defaultChoice
        selectedPaperColorIndex = 0
        isShowingEntryOptionsPage = false
        selectedCustomJournalTitle = nil
        selectedCustomJournalTitles = []
        loadedDraftSnapshot = nil
        linkedJournalTitle = nil
        linkedJournalTitles = []
        resetKeyboardFormattingState()
        isBodyEditorEditing = false
        isKeyboardVisible = false
    }

    private func loadLinkedJournalTitle(for draftID: UUID?) {
        guard let draftID else {
            linkedJournalTitle = nil
            linkedJournalTitles = []
            selectedCustomJournalTitle = nil
            selectedCustomJournalTitles = []
            seedInitialJournalSelectionIfNeeded()
            return
        }

        let journalTitles = EntryJournalLinkStore.loadJournalTitles(for: draftID)
        var hydratedJournalTitles = journalTitles
        if let initialJournalTitle = presentation.initialJournalTitle {
            hydratedJournalTitles.insert(initialJournalTitle)
        }
        linkedJournalTitles = hydratedJournalTitles
        linkedJournalTitle = hydratedJournalTitles.sorted().first
        selectedCustomJournalTitles = hydratedJournalTitles
        selectedCustomJournalTitle = hydratedJournalTitles.sorted().first
    }

    private func loadSavedDraftIfNeeded() {
        guard let activeDraftID else {
            return
        }

        if loadedDraftSnapshot?.id == activeDraftID {
            // The editor already holds this draft. Re-arm the autosave baseline, which switching
            // drafts clears, so the next write can still take the cheap metadata-only path.
            if autosavedDraftSnapshot == nil {
                autosavedDraftSnapshot = loadedDraftSnapshot
            }
            return
        }

        guard let draft = loadedDraft(id: activeDraftID) else {
            self.activeDraftID = nil
            isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
            clearEditor()
            return
        }

        storyTitle = draft.title
        entryText = draft.text
        entryRichText = draft.richText?.normalized(for: draft.text)
        let photos = Array(draft.photos.prefix(5))
        storyboardPhotos = photos.map(Optional.some)
            + Array(repeating: nil, count: max(0, 5 - photos.count))
        entryCharacters = EntryCharacterRules.orderedCharacters(draft.characters)
        selectedArtStyle = artStyles.contains(draft.artStyle) ? draft.artStyle : Self.defaultArtStyle
        storyLocation = draft.location
        storyDate = draft.date
        storyDatePrecision = draft.datePrecision
        currentEntryStatus = JournalEntryStatus(rawValue: draft.status) ?? .draft
        didEditEntryDate = false
        didEditEntryLocation = false
        savesDraft = draft.savesDraft
        isPrivateEntry = draft.isPrivate
        selectedFontChoice = CreateFontChoice.savedValue(draft.fontChoiceRawValue)
        selectedTextColorIndex = min(max(draft.textColorIndex ?? 0, 0), CreateFormattingPalette.textColors.count - 1)
        previewTextSize = CreateEntryTextSize.normalizedSliderValue(for: draft.textSize)
        selectedPaperStyleChoice = draft.paperStyleRawValue.flatMap(CreatePaperStyleChoice.init(rawValue:)) ?? .defaultChoice
        selectedPaperColorIndex = min(max(draft.paperColorIndex ?? 0, 0), CreateFormattingPalette.paperColors.count - 1)
        loadedDraftSnapshot = currentDraftSnapshot(id: draft.id)
        // The editor now matches disk, so there is nothing for autosave to write until the user
        // types. Whether *disk* matches Supabase is a separate question, and the draft knows.
        autosavedDraftSnapshot = loadedDraftSnapshot
        hasUncommittedLocalEdits = CreateEntryDraftStore.hasUncommittedLocalEdits(id: draft.id)

        // A save that exhausted its retries left a marker behind. Re-raise it so reopening the
        // entry still says "not in the cloud" instead of looking like a clean, synced draft.
        if let unsyncedReason = EntryCloudSyncFailureStore.reason(for: draft.id) {
            setCloudSaveState(.notSaved(unsyncedReason))
        }
    }

    private func currentEntryRichText() -> NotebookRichTextDocument? {
        guard !entryText.isEmpty else {
            return nil
        }

        return (entryRichText ?? NotebookRichTextDocument(text: entryText))
            .normalized(for: entryText)
    }

    private func currentDraftSnapshot(id: UUID) -> LoadedCreateEntryDraftSnapshot {
        LoadedCreateEntryDraftSnapshot(
            id: id,
            title: storyTitle,
            text: entryText,
            richText: currentEntryRichText(),
            photos: storyboardPhotos.compactMap { $0 },
            characters: entryCharacters,
            artStyle: selectedArtStyle,
            location: storyLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            date: storyDate,
            datePrecision: storyDatePrecision,
            createdAt: CreateEntryDraftStore.createdAt(id: id) ?? loadedDraftSnapshot?.createdAt ?? Date(),
            savesDraft: savesDraft,
            isPrivate: isPrivateEntry,
            fontChoiceRawValue: selectedFontChoice.rawValue,
            textColorIndex: selectedTextColorIndex,
            textSize: previewTextSize,
            paperStyleRawValue: selectedPaperStyleChoice.rawValue,
            paperColorIndex: selectedPaperColorIndex
        )
    }

    private var createEntryContent: some View {
        return VStack(alignment: .leading, spacing: 14) {
            entryDraftStepContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            handleEditorPageTap()
        }
    }

    private var entryDraftStepContent: some View {
        GeometryReader { proxy in
            let scrollContentHeight = editorScrollContentHeight(for: proxy.size.height)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    NotebookPaperBackground(
                        paperColor: selectedPaperSurfaceColor,
                        paperImageName: selectedPaperStyleChoice.backgroundImageName,
                        showsPaperWash: false,
                        showsRuledLines: selectedPaperStyleChoice.showsRuledLines,
                        showsNotebookChrome: selectedPaperStyleChoice.showsNotebookChrome,
                        firstRuledLineY: NotebookMetrics.firstNotebookRuleY
                    )
                    .frame(maxWidth: .infinity, minHeight: scrollContentHeight, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 0) {
                        NotebookEditorContent(
                            storyTitle: $storyTitle,
                            entryText: $entryText,
                            entryRichText: $entryRichText,
                            isTitleFocused: $isTitleFocused,
                            editorFocusRequestID: editorFocusRequestID,
                            editorBlurRequestID: editorBlurRequestID,
                            formattingRequest: textFormattingRequest,
                            isDictating: speechTranscriber.state.isListening,
                            dictationTranscriptRequest: dictationTranscriptRequest,
                            bodyPlaceholder: "Start writing...",
                            scrollsInternally: false,
                            pageHeight: scrollContentHeight,
                            textStyle: selectedTextStyle,
                            showsTitleRule: selectedPaperStyleChoice.showsNotebookChrome,
                            leadingContentPadding: selectedPaperStyleChoice.leadingContentPadding,
                            leadingTextPadding: selectedPaperStyleChoice.leadingTextPadding,
                            showsKeyboardAccessory: showsDraftKeyboardAccessory,
                            keyboardInputMode: draftKeyboardInputMode,
                            keyboardAccessoryContent: AnyView(entryDraftKeyboardAccessory),
                            keyboardPanelContent: AnyView(keyboardFormattingPanelContent),
                            usesTexturedPaperEffect: selectedPaperStyleChoice.usesTexturedPaperTextEffect,
                            onBodyTap: {
                                handleBodyEditorTap()
                            },
                            onSelectionStateChange: updateEditorSelectionState,
                            onEditingEnded: {
                                guard !isKeyboardDismissInProgress else {
                                    return
                                }

                                isBodyEditorEditing = false
                                resetKeyboardFormattingState()
                            },
                            onEditingBegan: {
                                isBodyEditorEditing = true
                            },
                            onTitleSubmit: {
                                editorFocusRequestID += 1
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                }
                .frame(maxWidth: .infinity, minHeight: scrollContentHeight)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isKeyboardVisible
                    && !isBodyEditorEditing
                    && activeKeyboardFormattingMode == nil {
                    existingEntryModeBottomControls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: isKeyboardVisible)
            .animation(.snappy(duration: 0.22), value: activeKeyboardFormattingMode)
            .animation(.snappy(duration: 0.22), value: hasStoryboardPhotos)
            .animation(.snappy(duration: 0.22), value: isPhotosPanelVisible)
            .animation(.snappy(duration: 0.22), value: isShowingCustomizeSheet)
            .animation(.snappy(duration: 0.22), value: isShowingJournalPromptsSheet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var draftKeyboardInputMode: NotebookEditorInputMode {
        if let activeKeyboardFormattingMode {
            return .formattingPanel(activeKeyboardFormattingMode)
        }
        return .systemKeyboard
    }

    @ViewBuilder
    private var completedEntryStoryboardFloatingOverlay: some View {
        GeometryReader { proxy in
            completedEntryStoryboardClip(containerSize: proxy.size)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 20)
                .padding(.bottom, completedEntryStoryboardBottomPadding)
                .offset(completedEntryStoryboardDragOffset)
        }
        .allowsHitTesting(completedEntryOpenedStoryboardImage != nil)
    }

    private var completedEntryStoryboardBottomPadding: CGFloat {
        speechMicBottomPadding + (showsSpeechMicButton ? 110 : 18)
    }

    @ViewBuilder
    private func completedEntryStoryboardClip(containerSize: CGSize) -> some View {
        if let completedEntryOpenedStoryboardImage {
            let storyboards = currentEntryStoryboards
            let primaryImage = storyboards.first(where: \.isPrimary)?.image ?? storyboards.first?.image ?? completedEntryOpenedStoryboardImage
            let storyboardCount = max(storyboards.count, 1)
            let imageWidth = min(containerSize.width * 0.34, 180)
            let aspectRatio = max(primaryImage.size.width / primaryImage.size.height, 0.1)
            let imageHeight = imageWidth / aspectRatio

            ZStack(alignment: .topTrailing) {
                if storyboardCount > 1 {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: imageWidth, height: imageHeight)
                        .offset(x: -8, y: 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.storyInk.opacity(0.08), lineWidth: 1)
                                .offset(x: -8, y: 8)
                        )
                }

                Image(uiImage: primaryImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageWidth, height: imageHeight)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 1)
                    )
                    .shadow(color: Color.storyInk.opacity(0.08), radius: 3, y: 1)
                    .zIndex(1)

                Image(systemName: "paperclip")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color(red: 0.74, green: 0.76, blue: 0.82))
                    .rotationEffect(.degrees(-34))
                    .shadow(color: Color.white.opacity(0.75), radius: 1, y: 1)
                    .shadow(color: Color.storyInk.opacity(0.12), radius: 1, y: 1)
                    .offset(x: 1, y: -13)
                    .zIndex(2)

                if storyboardCount > 1 {
                    Text("\(storyboardCount)")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.storyPurple, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .shadow(color: Color.storyInk.opacity(0.18), radius: 5, y: 2)
                        .offset(x: 12, y: imageHeight - 16)
                        .zIndex(3)
                }
            }
            .frame(width: imageWidth, height: imageHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedEntryStoryboardIndex = 0
                isPreviewingCompletedStoryboard = true
            }
            .simultaneousGesture(
                completedEntryStoryboardDragGesture(
                    clipSize: completedEntryStoryboardScaledClipSize(
                        CGSize(width: imageWidth, height: imageHeight)
                    ),
                    containerSize: containerSize
                )
            )
            .simultaneousGesture(
                completedEntryStoryboardMagnificationGesture(
                    baseClipSize: CGSize(width: imageWidth, height: imageHeight),
                    containerSize: containerSize
                )
            )
            .rotationEffect(.degrees(2))
            .scaleEffect(completedEntryStoryboardScale)
            .shadow(color: Color.storyInk.opacity(0.16), radius: 7, y: 4)
            .zIndex(3)
            .accessibilityLabel("Open storyboard full screen")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func completedEntryStoryboardDragGesture(clipSize: CGSize, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let startOffset = completedEntryStoryboardDragStartOffset ?? completedEntryStoryboardDragOffset
                completedEntryStoryboardDragStartOffset = startOffset

                let proposedOffset = CGSize(
                    width: startOffset.width + value.translation.width,
                    height: startOffset.height + value.translation.height
                )
                completedEntryStoryboardDragOffset = clampedCompletedEntryStoryboardDragOffset(
                    proposedOffset,
                    clipSize: clipSize,
                    containerSize: containerSize
                )
            }
            .onEnded { value in
                let startOffset = completedEntryStoryboardDragStartOffset ?? completedEntryStoryboardDragOffset
                let proposedOffset = CGSize(
                    width: startOffset.width + value.translation.width,
                    height: startOffset.height + value.translation.height
                )
                completedEntryStoryboardDragOffset = clampedCompletedEntryStoryboardDragOffset(
                    proposedOffset,
                    clipSize: clipSize,
                    containerSize: containerSize
                )
                completedEntryStoryboardDragStartOffset = nil
            }
    }

    private func completedEntryStoryboardMagnificationGesture(
        baseClipSize: CGSize,
        containerSize: CGSize
    ) -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let startScale = completedEntryStoryboardScaleStart ?? completedEntryStoryboardScale
                completedEntryStoryboardScaleStart = startScale
                completedEntryStoryboardScale = clampedCompletedEntryStoryboardScale(startScale * value)
                completedEntryStoryboardDragOffset = clampedCompletedEntryStoryboardDragOffset(
                    completedEntryStoryboardDragOffset,
                    clipSize: completedEntryStoryboardScaledClipSize(baseClipSize),
                    containerSize: containerSize
                )
            }
            .onEnded { value in
                let startScale = completedEntryStoryboardScaleStart ?? completedEntryStoryboardScale
                completedEntryStoryboardScale = clampedCompletedEntryStoryboardScale(startScale * value)
                completedEntryStoryboardDragOffset = clampedCompletedEntryStoryboardDragOffset(
                    completedEntryStoryboardDragOffset,
                    clipSize: completedEntryStoryboardScaledClipSize(baseClipSize),
                    containerSize: containerSize
                )
                completedEntryStoryboardScaleStart = nil
            }
    }

    private func clampedCompletedEntryStoryboardDragOffset(
        _ proposedOffset: CGSize,
        clipSize: CGSize,
        containerSize: CGSize
    ) -> CGSize {
        let edgeInset: CGFloat = 18
        let anchorTrailingPadding: CGFloat = 20
        let anchorBottomPadding = completedEntryStoryboardBottomPadding

        let minX = -(containerSize.width - clipSize.width - anchorTrailingPadding - edgeInset)
        let maxX = anchorTrailingPadding - edgeInset
        let minY = -(containerSize.height - clipSize.height - anchorBottomPadding - edgeInset)
        let maxY = max(anchorBottomPadding - edgeInset, 0)

        return CGSize(
            width: min(max(proposedOffset.width, minX), maxX),
            height: min(max(proposedOffset.height, minY), maxY)
        )
    }

    private func completedEntryStoryboardScaledClipSize(_ baseSize: CGSize) -> CGSize {
        CGSize(
            width: baseSize.width * completedEntryStoryboardScale,
            height: baseSize.height * completedEntryStoryboardScale
        )
    }

    private func clampedCompletedEntryStoryboardScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 0.55), 2.15)
    }

    private func resetCompletedEntryStoryboardDrag() {
        completedEntryStoryboardDragOffset = .zero
        completedEntryStoryboardDragStartOffset = nil
        completedEntryStoryboardScale = 1
        completedEntryStoryboardScaleStart = nil
    }

    private var showsDraftKeyboardAccessory: Bool {
        isKeyboardDismissInProgress || isBodyEditorEditing || isTitleFocused
    }

    private func editorScrollContentHeight(for visibleHeight: CGFloat) -> CGFloat {
        max(visibleHeight, UIScreen.main.bounds.height) * 2
    }

    private var showsSpeechMicButton: Bool {
        !isShowingEntryOptionsPage
            && !isBlockingSaveInProgress
            && !isPhotosPanelVisible
            && !isShowingCustomizeSheet
            && !isShowingJournalPromptsSheet
    }

    private var speechMicBottomPadding: CGFloat {
        if isFullScreenEditorVisible {
            return isKeyboardVisible ? 82 : 24
        }

        if isKeyboardVisible || isBodyEditorEditing || activeKeyboardFormattingMode != nil {
            return 22
        }

        return 84
    }

    private var speechMicButton: some View {
        EntrySpeechMicButton(isListening: speechTranscriber.state.isListening) {
            toggleSpeechTranscription()
        }
    }

    private func toggleSpeechTranscription() {
        if !speechTranscriber.state.isListening {
            isTitleFocused = false
            isBodyEditorEditing = true
            editorFocusRequestID += 1
        }

        speechTranscriber.toggle { transcript in
            dictationTranscriptRequestID += 1
            dictationTranscriptRequest = NotebookDictationTranscriptRequest(
                id: dictationTranscriptRequestID,
                transcript: transcript
            )
        }
    }

    private var entryDraftBottomBar: some View {
        VStack(spacing: 0) {
            if isPhotosPanelVisible {
                photosAndCharactersPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isShowingCustomizeSheet {
                customizeOptionsPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isShowingJournalPromptsSheet {
                promptsOptionsPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !isPhotosPanelVisible {
                entryReferencesShelf
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            floatingEditorMenu
                .overlay(alignment: .bottom) {
                    editorBottomDateLabel
                        .offset(y: 15)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorBottomDateLabel: some View {
        Text(editorToolbarDateText)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.storyInk.opacity(0.48))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            .accessibilityLabel("Entry date, \(editorToolbarDateText)")
    }

    @ViewBuilder
    private var existingEntryModeBottomControls: some View {
        entryDraftBottomBar
    }

    private var storyDetailsTab: some View {
        Group {
            if isStoryDetailsTabCollapsed {
                Button {
                    toggleStoryDetailsTabCollapsed()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: hasStoryDetailsMetadata ? "calendar.badge.clock" : "calendar")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.storyPurple)
                            .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Story Details")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.storyInk)

                            if hasStoryDetailsMetadata {
                                collapsedStoryDetailsValues
                            } else {
                                Text("Add date, time, or location")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.storyInk.opacity(0.62))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.76)
                            }
                        }

                        Spacer(minLength: 8)

                        photoCollapseChevron(systemName: "chevron.up")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Story Details, expand")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        storyDetailsHeader

                        Spacer(minLength: 8)

                        Button {
                            toggleStoryDetailsTabCollapsed()
                        } label: {
                            photoCollapseChevron(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Collapse story details")
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 8) {
                        storyDetailButton(
                            title: "Date",
                            value: entryDateMetadataText,
                            systemName: hasEntryDateValue ? "calendar.badge.clock" : "calendar",
                            isSelected: hasEntryDateValue,
                            action: openEntryDateSheet
                        )

                        storyDetailButton(
                            title: "Location",
                            value: entryPlaceMetadataText,
                            systemName: hasEntryLocationValue ? "location.fill" : "location",
                            isSelected: hasEntryLocationValue,
                            action: openEntryLocationSheet
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var photosAttachedTab: some View {
        Group {
            if isPhotoTabCollapsed {
                Button {
                    togglePhotoTabCollapsed()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: hasStoryboardPhotos ? "photo.stack" : "camera")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.storyPurple)
                            .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(collapsedPhotoTitleText)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.storyInk)

                            if !hasStoryboardPhotos {
                                Text("Photos help create better comics")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.storyInk.opacity(0.62))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.76)
                            }
                        }

                        Spacer(minLength: 8)

                        photoCollapseChevron(systemName: "chevron.up")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(collapsedPhotoTitleText), expand photos")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        photoStripHeader

                        Spacer(minLength: 8)

                        Button {
                            togglePhotoTabCollapsed()
                        } label: {
                            photoCollapseChevron(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Collapse photos")
                    }
                    .padding(.horizontal, 16)

                    referencePhotoExplainerText
                        .padding(.horizontal, 16)

                    referencePhotoStripRow
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var charactersAttachedTab: some View {
        Group {
            if isCharacterTabCollapsed {
                Button {
                    toggleCharacterTabCollapsed()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entryCharacters.isEmpty ? "person.crop.circle.badge.plus" : "person.2.crop.square.stack")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.storyPurple)
                            .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(collapsedCharacterTitleText)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.storyInk)

                            if entryCharacters.isEmpty {
                                Text("Single out people from your photos")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.storyInk.opacity(0.62))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.76)
                            }
                        }

                        Spacer(minLength: 8)

                        photoCollapseChevron(systemName: "chevron.up")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(collapsedCharacterTitleText), expand characters")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        characterStripHeader

                        Spacer(minLength: 8)

                        Button {
                            toggleCharacterTabCollapsed()
                        } label: {
                            photoCollapseChevron(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Collapse characters")
                    }
                    .padding(.horizontal, 16)

                    characterPhotoExplainerText
                        .padding(.horizontal, 16)

                    characterPhotoStripRow
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var entryPlaceMetadataText: String {
        let trimmedLocation = storyLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLocation.isEmpty ? "Location" : trimmedLocation
    }

    private var entryDateMetadataText: String {
        switch storyDatePrecision {
        case .noDate:
            "Date"
        case .exact:
            storyDate.formatted(.dateTime.month(.wide).day().year().hour().minute())
        case .dateOnly:
            storyDate.formatted(.dateTime.month(.wide).day().year())
        case .monthAndYear:
            storyDate.formatted(.dateTime.month(.wide).year())
        case .yearOnly:
            storyDate.formatted(.dateTime.year())
        }
    }

    private var editorToolbarDateText: String {
        if let createdAt = loadedDraftSnapshot?.createdAt, activeDraftID != nil || presentation.isEditDraft || opensExistingEntryReadMode {
            return createdAt.formatted(.dateTime.month(.wide).day().year())
        }

        return Date().formatted(.dateTime.month(.wide).day().year())
    }

    private var floatingEditorMenu: some View {
        HStack(spacing: 8) {
            floatingMenuActionButton(
                title: "Font",
                systemName: CreateFormattingTab.fontStyle.sheetSymbol,
                foregroundColor: isFormattingSheetActive(.fontStyle) ? Color.storyPurple : Color.storyInk.opacity(0.82),
                accessibilityLabel: isFormattingSheetActive(.fontStyle) ? "Close font panel" : "Open font panel"
            ) {
                openCustomizeOptions(.fontStyle)
            }

            floatingMenuActionButton(
                title: "Paper",
                systemName: CreateFormattingTab.paperStyle.sheetSymbol,
                foregroundColor: isFormattingSheetActive(.paperStyle) ? Color.storyPurple : Color.storyInk.opacity(0.82),
                accessibilityLabel: isFormattingSheetActive(.paperStyle) ? "Close paper panel" : "Open paper panel"
            ) {
                openCustomizeOptions(.paperStyle)
            }

            floatingMenuActionButton(
                title: "Prompts",
                systemName: isShowingJournalPromptsSheet ? "lightbulb.fill" : "lightbulb",
                foregroundColor: isShowingJournalPromptsSheet ? Color.storyPurple : Color.storyInk.opacity(0.82),
                accessibilityLabel: isShowingJournalPromptsSheet ? "Close prompts panel" : "Open prompts panel"
            ) {
                openJournalPromptsSheet()
            }

            if showsComposeFlowControls {
                bottomToolbarNextButton
                    .padding(.leading, 4)
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.14), radius: 12, y: 5)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    private func isFormattingSheetActive(_ tab: CreateFormattingTab) -> Bool {
        isShowingCustomizeSheet && activeCustomizeTab == tab
    }

    private var entryReferencesShelf: some View {
        HStack(alignment: .bottom, spacing: 13) {
            referencePhotosShelfButton

            charactersShelfButton
                .padding(.leading, -8)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
        .accessibilityElement(children: .contain)
    }

    private func shelfButtonCaption(title: String, summary: String?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk.opacity(0.88))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)

            if let summary {
                Text(summary)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.storyInk.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var referencePhotosShelfButton: some View {
        Button {
            openReferencesPanel(expandPhotos: true)
        } label: {
            VStack(spacing: 5) {
                referencePhotoShelfStack

                shelfButtonCaption(
                    title: "Reference",
                    summary: hasStoryboardPhotos ? referencePhotoShelfSummary : nil
                )
            }
            .frame(width: 82, height: 114, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasStoryboardPhotos ? "\(referencePhotoShelfSummary), open reference photos" : "Add reference photos")
    }

    private var referencePhotoShelfStack: some View {
        let photos = storyboardPhotos.compactMap { $0 }

        return ZStack(alignment: .topTrailing) {
            if photos.isEmpty {
                referencePolaroidPlaceholder
                    .rotationEffect(.degrees(-2.5))
            } else {
                ForEach(Array(photos.prefix(3).enumerated()), id: \.element.id) { index, photo in
                    referencePolaroidImage(photo.image, size: 62)
                        .offset(x: referenceShelfOffset(for: index).width, y: referenceShelfOffset(for: index).height)
                        .rotationEffect(.degrees(referenceShelfRotation(for: index)))
                        .zIndex(Double(index))
                }

                if photos.count > 1 {
                    Text("\(photos.count)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Color.storyPurple, in: Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.6))
                        .shadow(color: Color.storyInk.opacity(0.14), radius: 4, y: 2)
                        .offset(x: 9, y: -6)
                        .zIndex(5)
                }
            }
        }
        .frame(width: 78, height: 74)
    }

    private var referencePolaroidPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.88))
                .frame(width: 62, height: 72)
                .shadow(color: Color.storyInk.opacity(0.12), radius: 6, y: 3)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.storyPurple.opacity(0.06))
                .frame(width: 50, height: 45)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.storyPurple.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .overlay {
                    Image(systemName: "camera")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.storyPurple.opacity(0.76))
                }
                .frame(width: 62, height: 72)
        }
        .overlay(alignment: .top) {
            StoryPhotoTape(width: 31, height: 10, rotation: 4)
                .offset(y: -5)
        }
    }

    private func referencePolaroidImage(_ image: UIImage, size: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size - 10, height: size - 14)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.storyInk.opacity(0.28), lineWidth: 0.7)
                )
                .padding(.top, 5)

            Spacer(minLength: 0)
        }
        .frame(width: size, height: size + 10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.14), radius: 5, y: 3)
        .overlay(alignment: .top) {
            StoryPhotoTape(width: 29, height: 9, rotation: -3)
                .offset(y: -4)
        }
    }

    private func referenceShelfOffset(for index: Int) -> CGSize {
        switch index {
        case 0:
            return CGSize(width: -8, height: 6)
        case 1:
            return CGSize(width: 0, height: 1)
        default:
            return CGSize(width: 8, height: -3)
        }
    }

    private func referenceShelfRotation(for index: Int) -> Double {
        switch index {
        case 0:
            return -8
        case 1:
            return -1.5
        default:
            return 6
        }
    }

    private var referencePhotoShelfSummary: String {
        let count = storyboardPhotos.compactMap { $0 }.count
        return "\(count) photo\(count == 1 ? "" : "s")"
    }

    private var charactersShelfButton: some View {
        Button {
            openCharactersFromShelf()
        } label: {
            VStack(spacing: 5) {
                characterShelfAvatars

                shelfButtonCaption(
                    title: entryCharacters.count == 1 ? "Character" : "Characters",
                    summary: entryCharacters.isEmpty ? nil : characterShelfSummary
                )
            }
            .frame(width: 82, height: 111, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entryCharacters.isEmpty ? "Add character" : "\(characterShelfSummary), open characters")
    }

    private var characterShelfAvatars: some View {
        ZStack(alignment: .bottomTrailing) {
            if entryCharacters.isEmpty {
                StoryboardPhotoStripAddButton(
                    systemName: "person.crop.circle.badge.plus",
                    iconColor: Color.storyPurple,
                    size: 56,
                    iconWeight: .semibold,
                    shape: .circle
                )
                .background(Color.white, in: Circle())
                .shadow(color: Color.storyInk.opacity(0.08), radius: 5, y: 2)
            } else {
                ZStack {
                    ForEach(Array(entryCharacters.prefix(3).enumerated()), id: \.element.id) { index, character in
                        Image(uiImage: character.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(index == 0 ? Color.storyPurple.opacity(0.76) : Color.white.opacity(0.94), lineWidth: index == 0 ? 1.6 : 2)
                            )
                            .shadow(color: Color.storyInk.opacity(0.12), radius: 5, y: 3)
                            .offset(x: CGFloat(index) * 14 - CGFloat(min(entryCharacters.count, 3) - 1) * 7, y: CGFloat(index % 2) * -3)
                            .zIndex(Double(index))
                    }
                }
                .frame(width: 76, height: 60)

                if entryCharacters.count > 1 {
                    Text("\(entryCharacters.count)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 19, height: 19)
                        .background(Color.storyPurple, in: Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.4))
                        .offset(x: 0, y: -2)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                        .background(Color.white, in: Circle())
                        .offset(x: 0, y: -1)
                }
            }
        }
        .frame(width: 78, height: 65)
    }

    private var characterShelfSummary: String {
        guard let firstCharacter = entryCharacters.first else {
            return "Add"
        }

        if entryCharacters.count == 1 {
            return firstCharacter.name
        }

        return "\(entryCharacters.count) added"
    }

    private var journalsShelfButton: some View {
        Button {
            openJournalsFromShelf()
        } label: {
            VStack(spacing: 5) {
                journalShelfCovers

                Text(selectedJournalShelfTitles.count == 1 ? "Journal" : "Journals")
                    .font(.system(size: 10, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                if !selectedJournalShelfTitles.isEmpty {
                    Text(journalShelfSummary)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.storyInk.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .frame(width: 82, height: 103, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedJournalShelfTitles.isEmpty ? "Add to journal" : "\(journalShelfSummary), change journals")
    }

    private var journalShelfCovers: some View {
        ZStack(alignment: .bottomTrailing) {
            if selectedJournalShelfTitles.isEmpty {
                journalShelfSymbol(systemName: "book.closed.fill")
                .shadow(color: Color.storyInk.opacity(0.08), radius: 5, y: 2)
            } else if selectedJournalShelfJournals.isEmpty {
                journalShelfSymbol(systemName: "book.closed.fill")
                .shadow(color: Color.storyInk.opacity(0.08), radius: 5, y: 2)
            } else {
                ZStack {
                    ForEach(Array(selectedJournalShelfJournals.prefix(3).enumerated()), id: \.element.id) { index, journal in
                        SelectedJournalCoverThumbnail(journal: journal)
                            .scaleEffect(1.2)
                            .offset(x: CGFloat(index) * 14 - CGFloat(min(selectedJournalShelfJournals.count, 3) - 1) * 7, y: CGFloat(index % 2) * -3)
                            .zIndex(Double(index))
                    }
                }
                .frame(width: 76, height: 60)

                if selectedJournalShelfTitles.count > 1 {
                    Text("\(selectedJournalShelfTitles.count)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .frame(width: 19, height: 19)
                        .background(Color.storyPurple, in: Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.4))
                        .offset(x: 0, y: -2)
                } else {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                        .background(Color.white, in: Circle())
                        .offset(x: 0, y: -1)
                }
            }
        }
        .frame(width: 78, height: 65)
    }

    private func journalShelfSymbol(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 31, weight: .semibold))
            .foregroundStyle(Color.storyPurple.opacity(0.88))
            .frame(width: 60, height: 60)
            .background(Color.white.opacity(0.54), in: Circle())
    }

    private var selectedJournalShelfTitles: [String] {
        var titles = linkedJournalTitles.union(selectedCustomJournalTitles)

        if let linkedJournalTitle {
            titles.insert(linkedJournalTitle)
        }
        if let selectedCustomJournalTitle {
            titles.insert(selectedCustomJournalTitle)
        }
        if let initialJournalTitle = presentation.initialJournalTitle {
            titles.insert(initialJournalTitle)
        }

        return titles.sorted()
    }

    private var selectedJournalShelfJournals: [PrototypeChapter] {
        let titles = Set(selectedJournalShelfTitles)
        return availableJournalChapters.filter { titles.contains($0.title) }
    }

    private var availableJournalChapters: [PrototypeChapter] {
        authoringMode.isSampleStudio ? sampleAuthorJournals : DailyJournalData.allChapters()
    }

    private func refreshSampleAuthorJournalsIfNeeded() {
        guard authoringMode.isSampleStudio else {
            return
        }

        Task {
            do {
                let journals = try await SupabaseSampleStoryService().loadAuthoringJournals()
                let chapters = journals.map { $0.createEntryPrototypeChapter() }
                await MainActor.run {
                    sampleAuthorJournals = chapters
                }
            } catch {
                await MainActor.run {
                    sampleAuthorJournals = []
                }
            }
        }
    }

    private var journalShelfSummary: String {
        guard let firstTitle = selectedJournalShelfTitles.first else {
            return "Add"
        }

        if selectedJournalShelfTitles.count == 1 {
            return firstTitle
        }

        return "\(selectedJournalShelfTitles.count) selected"
    }

    private var photosAndCharactersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.storyInk.opacity(0.84))
                        .frame(width: 20, height: 20)

                    Text("Photos")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                }

                Spacer(minLength: 8)

                Button {
                    closePhotosPanel()
                } label: {
                    photoCollapseChevron(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close photos panel")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 8) {
                photoStripHeader

                referencePhotoExplainerText

                if hasStoryboardPhotos {
                    referencePhotoFanPreview
                }

                referencePhotoStripRow
                    .padding(.horizontal, -16)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()
                .background(Color.storyBorder.opacity(0.55))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                characterStripHeader

                characterPhotoExplainerText

                characterPhotoStripRow
                    .padding(.horizontal, -16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var customizeOptionsPanel: some View {
        CreateFormattingSheet(
            initialTab: activeCustomizeTab,
            selectedFont: $selectedFontChoice,
            selectedPaperStyle: $selectedPaperStyleChoice,
            selectedTextColorIndex: $selectedTextColorIndex,
            selectedPaperColorIndex: $selectedPaperColorIndex,
            previewTextSize: $previewTextSize,
            onClose: closeCustomizePanel
        )
        .id(activeCustomizeTab)
        .frame(maxHeight: customizePanelMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var promptsOptionsPanel: some View {
        JournalEntryPromptsSheet(
            onSelect: { prompt in
                applyJournalPrompt(prompt)
            },
            onClose: closePromptsPanel,
            showsNavigationChrome: false
        )
        .frame(maxHeight: promptsPanelMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var customizePanelMaxHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.62, 560)
    }

    private var promptsPanelMaxHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.72, 650)
    }

    private var referencePhotoFanPreview: some View {
        let photos = storyboardPhotos.compactMap { $0 }

        return ZStack {
            ForEach(Array(photos.prefix(5).enumerated()), id: \.element.id) { index, photo in
                Button {
                    dismissKeyboard()
                    previewedStoryboardPhoto = photo.image
                } label: {
                    referencePolaroidImage(photo.image, size: 104)
                }
                .buttonStyle(.plain)
                .rotationEffect(.degrees(referenceFanRotation(for: index, count: photos.count)))
                .offset(referenceFanOffset(for: index, count: photos.count))
                .zIndex(Double(index))
                .accessibilityLabel("View reference photo \(index + 1)")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: photos.count > 1 ? 156 : 124)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private func referenceFanRotation(for index: Int, count: Int) -> Double {
        guard count > 1 else {
            return -2
        }

        let visibleCount = min(count, 5)
        let center = Double(visibleCount - 1) / 2
        return (Double(index) - center) * 7
    }

    private func referenceFanOffset(for index: Int, count: Int) -> CGSize {
        guard count > 1 else {
            return .zero
        }

        let visibleCount = min(count, 5)
        let center = CGFloat(visibleCount - 1) / 2
        let distance = CGFloat(index) - center
        return CGSize(width: distance * 54, height: abs(distance) * 12)
    }

    private func floatingMenuActionButton(
        title: String,
        systemName: String,
        foregroundColor: Color = Color.storyInk.opacity(0.82),
        badgeCount: Int? = nil,
        accessibilityLabel: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(foregroundColor.opacity(0.92))
                        .frame(width: 22, height: 22)

                    if let badgeCount, badgeCount > 0 {
                        Text(badgeCount > 9 ? "9+" : "\(badgeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .minimumScaleFactor(0.75)
                            .frame(minWidth: 16, minHeight: 16)
                            .padding(.horizontal, badgeCount > 9 ? 2 : 0)
                            .background(Color.storyPurple, in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white, lineWidth: 1.5)
                            )
                            .offset(x: 9, y: -7)
                    }
                }
                .frame(width: 28, height: 22)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: 58, maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    private var bottomToolbarNextButton: some View {
        Button {
            advanceToEntryOptionsPage()
        } label: {
            HStack(spacing: 5) {
                Text("Next")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(width: 92, height: 44)
            .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Color.storyPurple.opacity(0.28), radius: 7, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isToolbarSaveInProgress)
        .opacity(isToolbarSaveInProgress ? 0.58 : 1)
        .accessibilityLabel("Next")
    }

    private func openPhotoSourceSheet() {
        guard let nextAvailablePhotoSlot else {
            return
        }

        selectedPhotoSlot = nextAvailablePhotoSlot
        isShowingPhotoSourceSheet = true
    }

    private func presentCameraFromPhotoSourceSheet() {
        isShowingPhotoSourceSheet = false
        DispatchQueue.main.async {
            isShowingCamera = true
        }
    }

    private func presentPhotoLibraryFromPhotoSourceSheet() {
        isShowingPhotoSourceSheet = false
        DispatchQueue.main.async {
            isShowingPhotoLibrary = true
        }
    }

    private func openReferencesPanel(expandPhotos: Bool) {
        dismissKeyboard()
        withAnimation(.snappy(duration: 0.2)) {
            isShowingReferencePhotosSheet = true
            isShowingCustomizeSheet = false
            isShowingJournalPromptsSheet = false
            isPhotosPanelVisible = false
        }
    }

    private func openCharactersFromShelf() {
        dismissKeyboard()
        withAnimation(.snappy(duration: 0.2)) {
            isShowingEntryCharactersSheet = true
            isEntryCharacterAddChoicesVisible = entryCharacters.isEmpty
            isShowingCustomizeSheet = false
            isShowingJournalPromptsSheet = false
            isPhotosPanelVisible = false
        }
    }

    private func openJournalsFromShelf() {
        withAnimation(.snappy(duration: 0.2)) {
            isShowingCustomizeSheet = false
            isShowingJournalPromptsSheet = false
            isPhotosPanelVisible = false
        }
        openAddToJournalPage()
    }

    private func presentCameraFromReferencePhotosSheet() {
        guard let nextAvailablePhotoSlot else {
            return
        }

        selectedPhotoSlot = nextAvailablePhotoSlot
        isShowingReferencePhotosSheet = false
        DispatchQueue.main.async {
            isShowingCamera = true
        }
    }

    private func presentPhotoLibraryFromReferencePhotosSheet() {
        guard let nextAvailablePhotoSlot else {
            return
        }

        selectedPhotoSlot = nextAvailablePhotoSlot
        isShowingReferencePhotosSheet = false
        DispatchQueue.main.async {
            isShowingPhotoLibrary = true
        }
    }

    private func presentCreateCharacterFromEntryCharactersSheet(source: CharacterInitialPhotoSource) {
        characterEditorSession = CharacterEditorSession(character: nil, initialPhotoSource: source)
    }

    private func openJournalPromptsSheet() {
        dismissKeyboard()
        withAnimation(.snappy(duration: 0.2)) {
            isShowingJournalPromptsSheet.toggle()
            isShowingCustomizeSheet = false
            isPhotosPanelVisible = false
        }
    }

    private func applyJournalPrompt(_ prompt: JournalEntryPrompt) {
        let trimmedTitle = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        if storyTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storyTitle = trimmedTitle
        }

        let trimmedEntryText = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        entryText = trimmedEntryText.isEmpty ? trimmedText : "\(trimmedEntryText)\n\n\(trimmedText)"
        entryRichText = NotebookRichTextDocument(text: entryText)
        closePromptsPanel()
    }

    private var entryDraftKeyboardAccessory: some View {
        Group {
            if isKeyboardMoreToolbarVisible {
                moreKeyboardToolbar
            } else {
                normalKeyboardToolbar
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotebookAnyViewInputHost.toolbarHeight)
        .background(Color.homePageBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.storyBorder.opacity(0.45))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var keyboardFormattingPanelContent: some View {
        if activeKeyboardFormattingMode != nil {
            keyboardFormattingPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .background(Color.homePageBackground)
        } else {
            Color.clear
        }
    }

    private var normalKeyboardToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    keyboardFormattingButton(
                        title: "Aa",
                        accessibilityLabel: "Font options",
                        isSelected: activeKeyboardFormattingMode == .font
                    ) {
                        toggleKeyboardFormattingPanel(.font)
                    }

                    keyboardToolbarDivider

                    keyboardPrimaryTextTypeButton

                    keyboardToolbarDivider

                    keyboardInlineStyleButtons
                }
            }

            Spacer(minLength: 0)

            keyboardToolButton(
                systemName: "keyboard.chevron.compact.down",
                accessibilityLabel: "Close keyboard",
                isSelected: false,
                action: dismissKeyboard
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var moreKeyboardToolbar: some View {
        HStack(spacing: 8) {
            Button {
                closeKeyboardMoreToolbar()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.86))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to keyboard")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var keyboardInlineStyleButtons: some View {
        HStack(spacing: 4) {
            keyboardFormattingButton(
                title: "B",
                accessibilityLabel: "Bold",
                isSelected: isKeyboardInlineStyleSelected(.bold)
            ) {
                sendTextFormattingCommand(.bold)
            }

            keyboardFormattingButton(
                title: "I",
                accessibilityLabel: "Italic",
                isSelected: isKeyboardInlineStyleSelected(.italic),
                isItalic: true
            ) {
                sendTextFormattingCommand(.italic)
            }

            keyboardFormattingButton(
                title: "U",
                accessibilityLabel: "Underline",
                isSelected: isKeyboardInlineStyleSelected(.underline),
                isUnderlined: true
            ) {
                sendTextFormattingCommand(.underline)
            }

            keyboardFormattingButton(
                title: "S",
                accessibilityLabel: "Strikethrough",
                isSelected: isKeyboardInlineStyleSelected(.strikethrough),
                isStrikethrough: true
            ) {
                sendTextFormattingCommand(.strikethrough)
            }

            keyboardToolbarDivider

            keyboardColorButton

            keyboardToolButton(
                systemName: "list.bullet",
                accessibilityLabel: "Bullet list",
                isSelected: false
            ) {
                sendTextFormattingCommand(.bulletList)
            }

            keyboardToolButton(
                systemName: "increase.indent",
                accessibilityLabel: "Indent",
                isSelected: false
            ) {
                sendTextFormattingCommand(.indent)
            }

            keyboardToolButton(
                systemName: "decrease.indent",
                accessibilityLabel: "Outdent",
                isSelected: false
            ) {
                sendTextFormattingCommand(.outdent)
            }

            keyboardToolButton(
                systemName: "ellipsis",
                accessibilityLabel: "More",
                isSelected: false
            ) {
                showKeyboardMoreToolbar()
            }
        }
    }

    private var keyboardPrimaryTextTypeButton: some View {
        Button {
            togglePrimaryKeyboardTextTypePanel()
        } label: {
            HStack(spacing: 0) {
                Text(selectedKeyboardTextType.primaryToolbarTitle)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(Color.storyInk.opacity(0.72))
            .frame(width: 44, height: 34)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Headings")
        .accessibilityValue(selectedKeyboardTextType.title)
        .accessibilityAddTraits(selectedKeyboardTextType == .body ? [] : .isSelected)
    }

    private func updateEditorSelectionState(_ state: NotebookTextSelectionState) {
        editorSelectionState = state
        if let textType = CreateKeyboardTextType.allCases.first(where: { $0.textRunStyle == state.textRunStyle }) {
            selectedKeyboardTextType = textType
        }
    }

    private func isKeyboardInlineStyleSelected(_ command: NotebookTextFormattingCommand) -> Bool {
        switch command {
        case .bold:
            return editorSelectionState.hasSelection && editorSelectionState.isBold
        case .italic:
            return editorSelectionState.hasSelection && editorSelectionState.isItalic
        case .underline:
            return editorSelectionState.hasSelection && editorSelectionState.isUnderlined
        case .strikethrough:
            return editorSelectionState.hasSelection && editorSelectionState.isStrikethrough
        case .bulletList, .indent, .outdent, .textColor, .textStyle:
            return false
        }
    }

    private func sendTextFormattingCommand(_ command: NotebookTextFormattingCommand) {
        isTitleFocused = false
        textFormattingRequestID += 1
        textFormattingRequest = NotebookTextFormattingRequest(
            id: textFormattingRequestID,
            command: command
        )
    }

    private func showKeyboardFormattingPanel(_ mode: CreateKeyboardFormattingMode) {
        isTitleFocused = false
        isKeyboardMoreToolbarVisible = false
        activeKeyboardFormattingMode = mode
    }

    private func toggleKeyboardFormattingPanel(_ mode: CreateKeyboardFormattingMode) {
        isTitleFocused = false
        isKeyboardMoreToolbarVisible = false
        activeKeyboardFormattingMode = activeKeyboardFormattingMode == mode ? nil : mode
    }

    private func showKeyboardMoreToolbar() {
        isTitleFocused = false
        isKeyboardMoreToolbarVisible = true
        activeKeyboardFormattingMode = nil
    }

    private func togglePrimaryKeyboardTextTypePanel() {
        isTitleFocused = false
        if activeKeyboardFormattingMode == .textType {
            activeKeyboardFormattingMode = nil
        } else {
            isKeyboardMoreToolbarVisible = false
            activeKeyboardFormattingMode = .textType
        }
    }

    private func closeKeyboardMoreToolbar() {
        isKeyboardMoreToolbarVisible = false
    }

    private func resetKeyboardFormattingState() {
        isKeyboardMoreToolbarVisible = false
        activeKeyboardFormattingMode = nil
    }

    private func keyboardPanelChip(
        title: String,
        mode: CreateKeyboardFormattingMode,
        width: CGFloat,
        font: Font = .system(size: 14, weight: .bold)
    ) -> some View {
        Button {
            showKeyboardFormattingPanel(mode)
        } label: {
            Text(title)
                .font(font)
                .foregroundStyle(Color.storyInk.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(width: width, height: 39)
                .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(activeKeyboardFormattingMode == mode ? Color.storyPurple : Color.storyBorder.opacity(0.46), lineWidth: activeKeyboardFormattingMode == mode ? 1.8 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(activeKeyboardFormattingMode == mode ? .isSelected : [])
    }

    private var keyboardColorButton: some View {
        Button {
            toggleKeyboardFormattingPanel(.color)
        } label: {
            keyboardColorCircleChip
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Text color")
        .accessibilityAddTraits(activeKeyboardFormattingMode == .color ? .isSelected : [])
    }

    private var keyboardTextSizeButton: some View {
        Button {
            showKeyboardFormattingPanel(.textSize)
        } label: {
            keyboardSizeChip
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Text size")
        .accessibilityAddTraits(activeKeyboardFormattingMode == .textSize ? .isSelected : [])
    }

    private var keyboardColorCircleChip: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        .red,
                        .orange,
                        .yellow,
                        .green,
                        .cyan,
                        .blue,
                        .purple,
                        .pink,
                        .red
                    ],
                    center: .center
                )
            )
            .frame(width: 21, height: 21)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.82), lineWidth: 1)
            )
            .overlay(
                Circle()
                    .stroke(Color.storyInk.opacity(0.12), lineWidth: 0.7)
            )
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
    }

    private var keyboardSizeChip: some View {
        Text("Size")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.storyInk.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 50, height: 39)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(activeKeyboardFormattingMode == .textSize ? Color.storyPurple : Color.storyBorder.opacity(0.46), lineWidth: activeKeyboardFormattingMode == .textSize ? 1.8 : 1)
            )
    }

    @ViewBuilder
    private var keyboardFormattingPanel: some View {
        switch activeKeyboardFormattingMode {
        case .font:
            keyboardFontPanel
        case .textType:
            keyboardTextTypePanel
        case .color:
            keyboardColorPanel
        case .textSize:
            keyboardTextSizePanel
        case nil:
            EmptyView()
        }
    }

    private var keyboardFontPanel: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: keyboardPanelColumns, spacing: 12) {
                ForEach(CreateFontChoice.allCases) { font in
                    Button {
                        selectedFontChoice = font
                    } label: {
                        keyboardPanelTile(isSelected: selectedFontChoice == font) {
                            Text(font.title)
                                .font(font.swiftUIBodyFont(size: 16))
                                .foregroundStyle(Color.storyInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(font.title)
                    .accessibilityAddTraits(selectedFontChoice == font ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var keyboardTextTypePanel: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: keyboardPanelColumns, spacing: 12) {
                ForEach(CreateKeyboardTextType.allCases) { textType in
                    Button {
                        selectedKeyboardTextType = textType
                        sendTextFormattingCommand(.textStyle(textType.textRunStyle))
                    } label: {
                        keyboardPanelTile(isSelected: selectedKeyboardTextType == textType) {
                            Text(textType.title)
                                .font(selectedFontChoice.swiftUIBodyFont(size: textType.sampleSize))
                                .foregroundStyle(Color.storyInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(textType.title)
                    .accessibilityAddTraits(selectedKeyboardTextType == textType ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var keyboardColorPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                keyboardPanelSectionTitle("Text color")

                LazyVGrid(columns: keyboardColorColumns, spacing: 14) {
                    ForEach(CreateFormattingPalette.textColors.indices, id: \.self) { index in
                        keyboardColorSwatch(
                            color: CreateFormattingPalette.textColors[index].color,
                            isSelected: selectedTextColorIndex == index
                        ) {
                            applyKeyboardTextColor(index)
                        }
                    }
                }

                if selectedPaperStyleChoice.showsPaperColorOptions {
                    keyboardPanelSectionTitle("Background color")

                    LazyVGrid(columns: keyboardColorColumns, spacing: 14) {
                        ForEach(CreateFormattingPalette.paperColors.indices, id: \.self) { index in
                            keyboardColorSwatch(
                                color: CreateFormattingPalette.paperColors[index],
                                isSelected: selectedPaperColorIndex == index
                            ) {
                                selectedPaperColorIndex = index
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 30)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var keyboardTextSizePanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            keyboardPanelSectionTitle("Text size")

            HStack(spacing: 14) {
                Text("A")
                    .font(selectedFontChoice.swiftUIFont(size: 17, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.72))

                Slider(value: $previewTextSize, in: 0...1)
                    .tint(Color.storyPurple)

                Text("A")
                    .font(selectedFontChoice.swiftUIFont(size: 31, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.82))
            }

            Text("The little story found its voice.")
                .font(selectedFontChoice.swiftUIBodyFont(size: CreateEntryTextSize.fontSize(for: previewTextSize)))
                .foregroundStyle(selectedKeyboardTextColor)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                .padding(16)
                .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.storyBorder.opacity(0.46), lineWidth: 1)
                )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 30)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var keyboardPanelColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var keyboardColorColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 58), spacing: 13)
        ]
    }

    private func keyboardPanelTile<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.storyPurple.opacity(0.12) : Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.storyPurple : Color.storyBorder.opacity(0.46), lineWidth: isSelected ? 1.8 : 1)
            )
    }

    private func keyboardPanelSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.storyInk.opacity(0.48))
    }

    private func keyboardColorSwatch(
        color: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .frame(width: 58, height: 58)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color)
                        .padding(10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.storyPurple : Color.storyBorder.opacity(0.46), lineWidth: isSelected ? 1.8 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var keyboardToolbarDivider: some View {
        Rectangle()
            .fill(Color.storyInk.opacity(0.32))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    private func keyboardToolButton(
        systemName: String,
        accessibilityLabel: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.storyPurple.opacity(0.12))
                        .frame(width: 34, height: 34)
                }

                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.storyPurple : Color.storyInk.opacity(0.72))
                    .frame(width: 34, height: 34)
            }
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func keyboardFormattingButton(
        title: String,
        accessibilityLabel: String,
        isSelected: Bool,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.storyPurple.opacity(0.12))
                        .frame(width: 34, height: 34)
                }

                Text(title)
                    .font(isItalic ? .system(size: 17, weight: .bold, design: .serif).italic() : .system(size: 17, weight: .bold, design: .serif))
                    .underline(isUnderlined)
                    .strikethrough(isStrikethrough)
                    .foregroundStyle(isSelected ? Color.storyPurple : Color.storyInk.opacity(0.72))
                    .frame(width: 34, height: 34)
            }
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openCustomizeOptions(_ tab: CreateFormattingTab) {
        dismissKeyboard()
        withAnimation(.snappy(duration: 0.2)) {
            if isShowingCustomizeSheet && activeCustomizeTab == tab {
                isShowingCustomizeSheet = false
            } else {
                activeCustomizeTab = tab
                isShowingCustomizeSheet = true
            }
            isShowingJournalPromptsSheet = false
            isPhotosPanelVisible = false
        }
    }

    private func openAddToJournalPage() {
        dismissKeyboard()
        var journalTitles = linkedJournalTitles.union(selectedCustomJournalTitles)
        if let currentEntry = currentJournalEntry() {
            journalTitles.formUnion(StoryEntryStore.journalTitles(containing: currentEntry))
        }

        if let linkedJournalTitle {
            journalTitles.insert(linkedJournalTitle)
        }
        if let selectedCustomJournalTitle {
            journalTitles.insert(selectedCustomJournalTitle)
        }

        selectedCustomJournalTitles = journalTitles
        selectedCustomJournalTitle = journalTitles.sorted().first
        isShowingAddToJournalPage = true
    }

    private func openEntryDateSheet() {
        dismissKeyboard()
        isShowingEntryDateSheet = true
    }

    private func openEntryLocationSheet() {
        dismissKeyboard()
        isShowingEntryLocationSheet = true
    }

    private func editorFloatingToolIcon<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(Color.storyInk.opacity(0.76))
            .frame(width: 48, height: 48)
            .background(Color.white.opacity(0.82), in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            .contentShape(Circle())
    }

    private var entryOptionsStepContent: some View {
        return VStack(alignment: .leading, spacing: 14) {
            if let completedEntryOpenedStoryboardImage {
                currentStoryboardVersionPrompt
                currentStoryboardsCard(fallbackImage: completedEntryOpenedStoryboardImage)
            } else {
                entryDetailsInfoBanner
            }

            artStylePickerSection
            // journalDestinationCard — Journal destination picker (kept for later reuse)
            // storyDetailsCard — Date and location (kept for later reuse)
            imageGenerationQualityCard
            generationCreditsStatusCard
            // entryPrivacyCard — Save Entry / Private Entry toggles (kept for later reuse)
            generateStoryboardButton

            if canDeleteCurrentEntry {
                deleteEntryCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Deleting the whole entry only makes sense once it exists on disk, and sample studio
    /// entries are removed through their own authoring service instead.
    private var canDeleteCurrentEntry: Bool {
        activeDraftID != nil && !authoringMode.isSampleStudio && contentMode.canPersistUserContent
    }

    private var deleteEntryCard: some View {
        VStack(spacing: 0) {
            Button(role: .destructive) {
                dismissKeyboard()
                isConfirmingEntryDeletion = true
            } label: {
                HStack(spacing: 7) {
                    if isDeletingEntry {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.red)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                    }

                    Text(isDeletingEntry ? "Deleting Entry" : "Delete Entry")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isDeletingEntry || isBlockingSaveInProgress)
            .opacity(isDeletingEntry || isBlockingSaveInProgress ? 0.55 : 1)
            .accessibilityLabel("Delete this entry")
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.28), lineWidth: 1)
        )
        .padding(.top, 4)
    }

    private var entryDeletionMessage: String {
        let title = storyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = title.isEmpty ? "this entry" : "\"\(title)\""
        let storyboardCount = currentEntryStoryboards.count

        guard storyboardCount > 0 else {
            return "Are you sure you want to delete \(subject)? This can't be undone."
        }

        let storyboardText = storyboardCount == 1
            ? "its storyboard"
            : "all \(storyboardCount) of its storyboards"

        return "Deleting \(subject) also deletes \(storyboardText) and removes it from every journal. This can't be undone."
    }

    private var selectedEntryJournalTitle: String? {
        if let selectedJournalTitle = selectedCustomJournalTitle ?? selectedCustomJournalTitles.sorted().first {
            return selectedJournalTitle
        }

        if presentation.initialJournalTitle != nil {
            return nil
        }

        return presentation.directJournalTitle
    }

    private var selectedImageGenerationQuality: OpenAIImageGenerationQuality {
        OpenAIImageGenerationQuality(rawValue: selectedImageGenerationQualityRawValue) ?? .standard
    }

    private func stageSelectedJournalMemberships(for draftID: UUID?) {
        guard let draftID, !selectedCustomJournalTitles.isEmpty,
              let entry = currentJournalEntry(id: draftID) else {
            return
        }

        selectedCustomJournalTitles.sorted().forEach { journalTitle in
            StoryEntryStore.upsert(entry, to: journalTitle, syncsToCloud: false)
            onJournalEntryCreated(journalTitle, entry)
            EntryJournalLinkStore.save(
                journalTitle: journalTitle,
                journalEntryID: entry.id,
                for: draftID
            )
        }

        linkedJournalTitles = selectedCustomJournalTitles
        linkedJournalTitle = selectedCustomJournalTitles.sorted().first
    }

    private var hasStoryboardPhotos: Bool {
        storyboardPhotos.contains { $0 != nil }
    }

    private var storyboardGenerationButtonTitle: String {
        if completedEntryOpenedStoryboardImage != nil {
            switch storyboardGenerationPhase {
            case .ready, .failed:
                return "Generate New Version"
            case .preparingEntry, .uploadingReferencePhotos, .generating, .savingResult, .completed:
                return storyboardGenerationPhase.buttonTitle
            }
        }

        return storyboardGenerationPhase.buttonTitle
    }

    /// A balance we have never read is unknown, not empty, so it does not block generation — only a
    /// balance Supabase confirmed is too small does.
    private var isShortOnGenerationCredits: Bool {
        generationCreditStore.hasKnownBalance
            && !generationCreditStore.canSpend(selectedImageGenerationQuality.creditCost)
    }

    private var isStoryboardGenerationButtonDisabled: Bool {
        isGeneratingStoryboard
            || storyboardGenerationPhase == .completed
            || isShortOnGenerationCredits
    }

    private var photosMenuBadgeCount: Int {
        storyboardPhotos.compactMap { $0 }.count + entryCharacters.count
    }

    @discardableResult
    private func addCurrentEntry(to journalTitle: String, id: UUID = UUID()) -> PrototypeEntry? {
        guard let entry = currentJournalEntry(id: id) else {
            return nil
        }

        guard canPersistEntry else {
            signInGate.requireAccount(for: .saveEntry)
            return nil
        }

        StoryEntryStore.add(entry, to: journalTitle)
        onJournalEntryCreated(journalTitle, entry)
        return entry
    }

    private func currentJournalEntry(id: UUID = UUID()) -> PrototypeEntry? {
        let trimmedTitle = storyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            return nil
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEE"

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d"

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short

        let trimmedLocation = storyLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        EntryLocationRecentStore.add(trimmedLocation)
        recentEntryLocations = EntryLocationRecentStore.all
        let trimmedRichText = currentEntryRichText()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PrototypeEntry(
            id: id,
            weekday: weekdayFormatter.string(from: storyDate).uppercased(),
            day: dayFormatter.string(from: storyDate),
            title: trimmedTitle.isEmpty ? "Untitled Entry" : trimmedTitle,
            body: trimmedBody,
            richText: trimmedRichText,
            time: timeFormatter.string(from: storyDate),
            location: trimmedLocation.isEmpty ? nil : trimmedLocation,
            imageNames: []
        )
    }

    private func addEditedEntryToJournal(_ journalTitle: String) {
        dismissKeyboard()

        var linkedDraftID = activeDraftID
        if presentation.isEditDraft {
            saveEditedDraftChanges()
            linkedDraftID = activeDraftID ?? linkedDraftID
        }

        guard let entry = addCurrentEntry(to: journalTitle) else {
            return
        }
        selectedCustomJournalTitle = journalTitle
        selectedCustomJournalTitles.insert(journalTitle)
        linkedJournalTitle = journalTitle
        linkedJournalTitles.insert(journalTitle)
        if let linkedDraftID {
            EntryJournalLinkStore.save(journalTitle: journalTitle, journalEntryID: entry.id, for: linkedDraftID)
        }
        isShowingAddToJournalPage = false

        withAnimation(.snappy(duration: 0.24)) {
            addedJournalTitle = journalTitle
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard addedJournalTitle == journalTitle else {
                return
            }

            withAnimation(.snappy(duration: 0.24)) {
                addedJournalTitle = nil
            }
        }
    }

    private func removeEditedEntryFromJournal(_ journalTitle: String) {
        dismissKeyboard()

        if let activeDraftID {
            if let currentEntry = currentJournalEntry() {
                StoryEntryStore.delete(
                    entryIDs: EntryJournalLinkStore.loadJournalEntryIDs(for: activeDraftID),
                    matching: currentEntry,
                    from: journalTitle
                )
            }

            EntryJournalLinkStore.remove(journalTitle: journalTitle, for: activeDraftID)
        } else if let currentEntry = currentJournalEntry() {
            StoryEntryStore.deleteFirstMatchingContent(currentEntry, from: journalTitle)
        }

        selectedCustomJournalTitles.remove(journalTitle)
        linkedJournalTitles.remove(journalTitle)
        selectedCustomJournalTitle = selectedCustomJournalTitles.sorted().first
        linkedJournalTitle = linkedJournalTitles.sorted().first
        addedJournalTitle = nil
        isShowingAddToJournalPage = false
    }

    private func saveEditedEntryJournalSelection(_ journalTitles: Set<String>) {
        dismissKeyboard()

        var linkedDraftID = activeDraftID
        if presentation.isEditDraft {
            saveEditedDraftChanges()
            linkedDraftID = activeDraftID ?? linkedDraftID
        }

        let previousJournalTitles = selectedCustomJournalTitles
        let addedJournalTitles = journalTitles.subtracting(previousJournalTitles)
        let removedJournalTitles = previousJournalTitles.subtracting(journalTitles)

        if !addedJournalTitles.isEmpty,
           let entry = currentJournalEntry(id: linkedDraftID ?? UUID()) {
            addedJournalTitles.sorted().forEach { journalTitle in
                StoryEntryStore.add(entry, to: journalTitle)
                onJournalEntryCreated(journalTitle, entry)
                if let linkedDraftID {
                    EntryJournalLinkStore.save(journalTitle: journalTitle, journalEntryID: entry.id, for: linkedDraftID)
                }
            }
        }

        removedJournalTitles.sorted().forEach { journalTitle in
            if let linkedDraftID,
               let currentEntry = currentJournalEntry() {
                StoryEntryStore.delete(
                    entryIDs: EntryJournalLinkStore.loadJournalEntryIDs(for: linkedDraftID),
                    matching: currentEntry,
                    from: journalTitle
                )
                EntryJournalLinkStore.remove(journalTitle: journalTitle, for: linkedDraftID)
            } else if let currentEntry = currentJournalEntry() {
                StoryEntryStore.deleteFirstMatchingContent(currentEntry, from: journalTitle)
            }
        }

        selectedCustomJournalTitles = journalTitles
        selectedCustomJournalTitle = journalTitles.sorted().first
        linkedJournalTitles = journalTitles
        linkedJournalTitle = journalTitles.sorted().first

        if let addedJournalTitle = addedJournalTitles.sorted().first {
            withAnimation(.snappy(duration: 0.24)) {
                self.addedJournalTitle = addedJournalTitle
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.addedJournalTitle == addedJournalTitle else {
                    return
                }

                withAnimation(.snappy(duration: 0.24)) {
                    self.addedJournalTitle = nil
                }
            }
        } else {
            self.addedJournalTitle = nil
        }

        isShowingAddToJournalPage = false
    }

    private func addedToJournalToast(journalTitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "book.closed")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 30, height: 30)
                .background(Color.storyPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Added to Journal")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(journalTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button("View") {
                withAnimation(.snappy(duration: 0.18)) {
                    addedJournalTitle = nil
                }
                selectedPage = .journal
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.storyPurple)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private var cloudSaveBannerMessage: String? {
        switch cloudSaveState {
        case .failed, .photoUploadFailed, .notSaved:
            return cloudSaveState.message
        case .idle, .saving, .saved, .savedLocally, .uploadingPhotos, .photosUploaded:
            return nil
        }
    }

    private var showsSavedConfirmationCard: Bool {
        switch cloudSaveState {
        case .saved, .savedLocally, .photosUploaded:
            return true
        default:
            return false
        }
    }

    private func updateSavedConfirmationReveal(for state: EntryCloudSaveState) {
        guard state == .saved || state == .savedLocally || state == .photosUploaded else {
            savedConfirmationRevealProgress = 0
            return
        }

        savedConfirmationRevealProgress = 0

        withAnimation(.easeInOut(duration: 1.05).delay(0.08)) {
            savedConfirmationRevealProgress = 1
        }
    }

    private var savedConfirmationCard: some View {
        VStack(spacing: 6) {
            // SwiftUI Text clips Caveat flourishes; UILabel draws with expanded insets.
            // Left-to-right mask wipe reads as an invisible pen writing the word.
            NonClippingScriptText(
                text: "Saved!",
                fontName: "Caveat-Regular",
                fontSize: 76,
                color: UIColor(Color.storyPurple),
                clipPadding: 20
            )
            .fixedSize()
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    let revealWidth = proxy.size.width * savedConfirmationRevealProgress
                    let softEdge: CGFloat = 16
                    HStack(spacing: 0) {
                        Rectangle()
                            .frame(width: max(0, revealWidth - softEdge))
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: min(softEdge, revealWidth))
                        Spacer(minLength: 0)
                    }
                }
            }

            Capsule()
                .fill(Color.storyPurple.opacity(0.28))
                .frame(width: 158 * savedConfirmationRevealProgress, height: 4)
        }
        .padding(.horizontal, 36)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(width: 340)
        .background(Color.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.storyPurple.opacity(0.16), radius: 22, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        .allowsHitTesting(false)
        .accessibilityLabel("Saved")
    }

    private func cloudSaveStatusBanner(message: String) -> some View {
        HStack(spacing: 11) {
            cloudSaveStatusIcon

            Text(message)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(cloudSaveStatusTextColor)
                .lineLimit(2)

            Spacer(minLength: 10)

            if case .failed = cloudSaveState {
                Button("Retry") {
                    retryCloudSave()
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .buttonStyle(.plain)
                .disabled(isToolbarSaveInProgress)
            } else if case .notSaved = cloudSaveState {
                Button("Retry") {
                    retryCloudSave()
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .buttonStyle(.plain)
                .disabled(isToolbarSaveInProgress)
            } else if case .photoUploadFailed = cloudSaveState {
                Button("Retry") {
                    retryCloudSave()
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .buttonStyle(.plain)
                .disabled(isToolbarSaveInProgress)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    @ViewBuilder
    private var cloudSaveStatusIcon: some View {
        switch cloudSaveState {
        case .saving, .uploadingPhotos:
            ProgressView()
                .controlSize(.small)
                .tint(Color.storyPurple)
                .frame(width: 30, height: 30)
        case .saved, .photosUploaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 30, height: 30)
                .background(Color.storyPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .savedLocally:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 30, height: 30)
                .background(Color.storyPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .failed, .photoUploadFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 30, height: 30)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .notSaved:
            Image(systemName: "icloud.slash.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 30, height: 30)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .idle:
            EmptyView()
        }
    }

    private var cloudSaveStatusTextColor: Color {
        switch cloudSaveState {
        case .saved, .photosUploaded:
            return Color.storyPurple
        default:
            return Color.storyInk
        }
    }

    private func saveDirectJournalEntryAndExit() {
        guard let journalTitle = presentation.directJournalTitle, hasDraftContent else {
            return
        }

        dismissKeyboard()
        cancelPendingLocalAutosave()
        setCloudSaveState((storyboardPhotos.compactMap { $0 }).isEmpty ? .saving : .uploadingPhotos)

        let entryID = activeDraftID ?? UUID()
        let createdAt = activeDraftID.flatMap { loadedDraft(id: $0)?.createdAt }
            ?? loadedDraftSnapshot?.createdAt
            ?? Date()
        Task {
            let payload = EntryDraftSavePayload(
                id: entryID,
                createdAt: createdAt,
                title: storyTitle,
                text: entryText,
                richText: currentEntryRichText(),
                photos: storyboardPhotos.compactMap { $0 },
                characters: entryCharacters,
                artStyle: selectedArtStyle,
                location: storyLocation.trimmingCharacters(in: .whitespacesAndNewlines),
                date: storyDate,
                datePrecision: storyDatePrecision,
                savesDraft: savesDraft,
                isPrivate: isPrivateEntry,
                fontChoiceRawValue: selectedFontChoice.rawValue,
                textColorIndex: selectedTextColorIndex,
                textSize: previewTextSize,
                paperStyleRawValue: selectedPaperStyleChoice.rawValue,
                paperColorIndex: selectedPaperColorIndex,
                isBold: false,
                isItalic: false,
                isUnderlined: false,
                isStrikethrough: false,
                isHighlighted: false,
                textAlignmentRawValue: "leading"
            )

            if let journalEntry = currentJournalEntry(id: entryID) {
                StoryEntryStore.upsert(journalEntry, to: journalTitle, syncsToCloud: false)
                onJournalEntryCreated(journalTitle, journalEntry)
                EntryJournalLinkStore.save(
                    journalTitle: journalTitle,
                    journalEntryID: journalEntry.id,
                    for: entryID
                )
            }

            let result: EntrySaveResult?
            if authoringMode.isSampleStudio {
                result = try? await SupabaseSampleStoryService().saveSampleEntry(
                    payload: payload,
                    status: currentEntryStatus
                )
            } else {
                result = try? await EntrySaveService().saveEntryPreservingStatus(
                    payload: payload,
                    isSignedIn: authStore.userID != nil,
                    status: currentEntryStatus
                )
            }

            guard let result else {
                setCloudSaveState(.failed("Could not save this entry locally."))
                return
            }

            activeDraftID = result.localDraftID
            isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty
            setCloudSaveState(result.state)

            guard result.state.isConfirmedSave,
                  let savedEntry = currentJournalEntry(id: result.localDraftID) else {
                return
            }

            StoryEntryStore.upsert(savedEntry, to: journalTitle)
            onJournalEntryCreated(journalTitle, savedEntry)
            EntryJournalLinkStore.save(
                journalTitle: journalTitle,
                journalEntryID: savedEntry.id,
                for: result.localDraftID
            )
            markLocalDraftCommitted(
                id: result.localDraftID,
                snapshot: currentDraftSnapshot(id: result.localDraftID)
            )
            isAutosaveSuspended = true
            clearEditor()
            activeDraftID = nil
            dismissCreate()
        }
    }

    private func saveDirectJournalEntryInPlace() {
        guard let journalTitle = presentation.directJournalTitle, hasDraftContent else {
            cancelToolbarSavedFeedback()
            return
        }

        dismissKeyboard()

        let entryID = toolbarSavedJournalEntryID ?? UUID()
        guard let entry = currentJournalEntry(id: entryID) else {
            cancelToolbarSavedFeedback()
            return
        }

        cancelPendingLocalAutosave()
        setCloudSaveState((storyboardPhotos.compactMap { $0 }).isEmpty ? .saving : .uploadingPhotos)

        Task {
            let payload = EntryDraftSavePayload(
                id: entry.id,
                createdAt: loadedDraft(id: entry.id)?.createdAt ?? entry.createdAt,
                title: storyTitle,
                text: entryText,
                richText: currentEntryRichText(),
                photos: storyboardPhotos.compactMap { $0 },
                characters: entryCharacters,
                artStyle: selectedArtStyle,
                location: storyLocation.trimmingCharacters(in: .whitespacesAndNewlines),
                date: storyDate,
                datePrecision: storyDatePrecision,
                savesDraft: savesDraft,
                isPrivate: isPrivateEntry,
                fontChoiceRawValue: selectedFontChoice.rawValue,
                textColorIndex: selectedTextColorIndex,
                textSize: previewTextSize,
                paperStyleRawValue: selectedPaperStyleChoice.rawValue,
                paperColorIndex: selectedPaperColorIndex,
                isBold: false,
                isItalic: false,
                isUnderlined: false,
                isStrikethrough: false,
                isHighlighted: false,
                textAlignmentRawValue: "leading"
            )
            StoryEntryStore.upsert(entry, to: journalTitle, syncsToCloud: false)
            onJournalEntryCreated(journalTitle, entry)
            EntryJournalLinkStore.save(
                journalTitle: journalTitle,
                journalEntryID: entry.id,
                for: entry.id
            )

            let result: EntrySaveResult?
            if authoringMode.isSampleStudio {
                result = try? await SupabaseSampleStoryService().saveSampleEntry(
                    payload: payload,
                    status: currentEntryStatus
                )
            } else {
                result = try? await EntrySaveService().saveEntryPreservingStatus(
                    payload: payload,
                    isSignedIn: authStore.userID != nil,
                    status: currentEntryStatus
                )
            }
            if let result {
                setCloudSaveState(result.state)
                activeDraftID = result.localDraftID
                isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty

                if result.state.isConfirmedSave,
                   let savedEntry = currentJournalEntry(id: result.localDraftID) {
                    StoryEntryStore.upsert(savedEntry, to: journalTitle)
                    onJournalEntryCreated(journalTitle, savedEntry)
                    EntryJournalLinkStore.save(
                        journalTitle: journalTitle,
                        journalEntryID: savedEntry.id,
                        for: result.localDraftID
                    )
                    toolbarSavedJournalEntryID = result.localDraftID
                    let savedSnapshot = currentDraftSnapshot(id: result.localDraftID)
                    loadedDraftSnapshot = savedSnapshot
                    toolbarSavedSnapshot = savedSnapshot
                    markLocalDraftCommitted(id: result.localDraftID, snapshot: savedSnapshot)
                    completeToolbarSavedFeedback(for: savedSnapshot)
                } else {
                    cancelToolbarSavedFeedback()
                }
            } else {
                setCloudSaveState(.failed("Could not save this entry locally."))
                cancelToolbarSavedFeedback()
            }
        }
    }

    private var journalDestinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Journal")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text("Choose where to add this entry")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()
            }

            VStack(spacing: 8) {
                journalDestinationButton(
                    title: selectedCustomJournalTitle ?? "Add to Journal",
                    subtitle: selectedCustomJournalTitle == nil ? "Choose an existing journal or create a new one" : "Tap to change journal",
                    journal: selectedCustomJournal
                ) {
                    isShowingJournalDestinationSheet = true
                    dismissKeyboard()
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 9, y: 3)
    }

    private var storyDetailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Story Details")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text("Add when and where this happened")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()
            }

            VStack(spacing: 8) {
                storyDetailButton(
                    title: "Date",
                    value: entryDateMetadataText,
                    systemName: hasEntryDateValue ? "calendar.badge.clock" : "calendar",
                    isSelected: hasEntryDateValue,
                    action: openEntryDateSheet
                )

                storyDetailButton(
                    title: "Location",
                    value: entryPlaceMetadataText,
                    systemName: hasEntryLocationValue ? "location.fill" : "location",
                    isSelected: hasEntryLocationValue,
                    action: openEntryLocationSheet
                )
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 9, y: 3)
    }

    private var imageGenerationQualityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Image Quality")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)

                    Text("Choose Standard or HD")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(OpenAIImageGenerationQuality.allCases) { quality in
                    imageQualityOptionButton(quality)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 9, y: 3)
    }

    private func imageQualityOptionButton(_ quality: OpenAIImageGenerationQuality) -> some View {
        let isSelected = selectedImageGenerationQuality == quality

        return Button {
            selectedImageGenerationQualityRawValue = quality.rawValue
            dismissKeyboard()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: imageQualityOptionIcon(for: quality))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(quality.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text(quality.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }

                Spacer()

                if isSelected {
                    Text("Selected")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Color.storyPurple.opacity(0.1), in: Capsule())
                }

                generationCostChip(cost: quality.creditCost)
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .background(Color.white.opacity(isSelected ? 0.96 : 0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.storyPurple.opacity(0.34) : Color.storyBorder.opacity(0.62), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(quality.title), \(quality.subtitle), \(formattedCreditCount(quality.creditCost))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func imageQualityOptionIcon(for quality: OpenAIImageGenerationQuality) -> String {
        switch quality {
        case .standard:
            return "photo"
        case .highDefinition:
            return "sparkles"
        }
    }

    private var generationCreditsStatusCard: some View {
        HStack(spacing: 11) {
            CreditBalanceBadge(
                balance: generationCreditStore.balance,
                isRefreshing: generationCreditStore.isRefreshing
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Generation Credits")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(generationCreditsStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isShortOnGenerationCredits ? Color.red.opacity(0.82) : Color.homeMutedText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 9, y: 3)
    }

    private var generationCreditsStatusText: String {
        let cost = selectedImageGenerationQuality.creditCost

        guard authStore.userID != nil else {
            return "Sign in to use credits across devices."
        }

        guard let balance = generationCreditStore.balance else {
            return "Checking your balance."
        }

        if balance < cost {
            return "You need \(formattedCreditCount(cost)) to generate."
        }

        return "\(formattedCreditCount(cost)) will be used after a successful image."
    }

    private func generationCostChip(cost: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))

            Text("\(cost)")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(Color.storyPurple)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.storyPurple.opacity(0.1), in: Capsule())
        .accessibilityLabel("\(formattedCreditCount(cost)) generation cost")
    }

    private func formattedCreditCount(_ count: Int) -> String {
        count == 1 ? "1 credit" : "\(count) credits"
    }

    private func journalDestinationButton(
        title: String,
        subtitle: String,
        journal: PrototypeChapter?,
        action: @escaping () -> Void
    ) -> some View {
        let hasSelectedJournal = selectedCustomJournalTitle != nil

        return Button(action: action) {
            HStack(spacing: 12) {
                if let journal {
                    SelectedJournalCoverThumbnail(journal: journal)
                } else {
                    Image(systemName: "book")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Color.storyPurple)
                        .frame(width: 34, height: 42)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }

                Spacer()

                if hasSelectedJournal {
                    Text("Selected")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Color.storyPurple.opacity(0.1), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.homeMutedText.opacity(0.72))
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .background(Color.white.opacity(hasSelectedJournal ? 0.96 : 0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hasSelectedJournal ? Color.storyPurple.opacity(0.34) : Color.storyBorder.opacity(0.62), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedCustomJournal: PrototypeChapter? {
        guard let selectedCustomJournalTitle else {
            return nil
        }

        return availableJournalChapters.first {
            $0.title == selectedCustomJournalTitle
        }
    }

    private var photoStripHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Color.storyInk.opacity(0.86))
                .rotationEffect(.degrees(-18))
                .frame(width: 20, height: 20)

            Text("Reference Photos")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Color.storyInk)
        }
    }

    private var characterStripHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.storyInk.opacity(0.84))
                    .frame(width: 20, height: 20)

                Text("Characters")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.storyInk)
            }

            Spacer(minLength: 8)

            myCharactersButton
        }
    }

    private var myCharactersButton: some View {
        Button {
            openReusableCharactersSheet()
        } label: {
            Text("My Characters")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyPurple)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("My Characters")
    }

    private var referencePhotoExplainerText: some View {
        Text("Use this to add reference photos: scenery, objects, or people. These help build your storyboard image.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.storyInk.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var storyDetailsHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.84))
                .frame(width: 20, height: 20)

            Text("Story Details")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Color.storyInk)
        }
    }

    private var hasEntryLocationValue: Bool {
        !storyLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasStoryDetailsMetadata: Bool {
        hasEntryDateValue || hasEntryLocationValue
    }

    private var collapsedStoryDetailsValues: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasEntryDateValue {
                collapsedStoryDetailValue(systemName: "calendar", text: entryDateMetadataText)
            }

            if hasEntryLocationValue {
                collapsedStoryDetailValue(systemName: "location.fill", text: entryPlaceMetadataText)
            }
        }
    }

    private func collapsedStoryDetailValue(systemName: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.storyPurple.opacity(0.88))
                .frame(width: 11)

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.68))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func storyDetailButton(
        title: String,
        value: String,
        systemName: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.52))

                    Text(value)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isSelected ? Color.storyInk : Color.storyInk.opacity(0.72))
                        .lineLimit(isSelected ? 2 : 1)
                        .minimumScaleFactor(0.9)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.36))
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                isSelected ? Color.storyPurple.opacity(0.08) : Color.homeCardGray.opacity(0.86),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.storyPurple.opacity(0.26) : Color.storyBorder.opacity(0.58), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value)")
    }

    private var attachedPhotoSummaryText: String {
        let count = storyboardPhotos.compactMap { $0 }.count
        return "\(count) photo\(count == 1 ? "" : "s") attached"
    }

    private var collapsedPhotoTitleText: String {
        hasStoryboardPhotos ? attachedPhotoSummaryText : "Add reference photos"
    }

    private var attachedCharacterSummaryText: String {
        let count = entryCharacters.count
        return "\(count) character\(count == 1 ? "" : "s") added"
    }

    private var collapsedCharacterTitleText: String {
        entryCharacters.isEmpty ? "Add characters" : attachedCharacterSummaryText
    }

    private func photoCollapseChevron(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.storyInk.opacity(0.7))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }

    private var photoStripContent: some View {
        HStack(spacing: 9) {
            if hasStoryboardPhotos {
                ForEach(Array(storyboardPhotos.compactMap { $0 }.enumerated()), id: \.element.id) { index, photo in
                    StoryboardPhotoStripThumbnail(
                        image: photo.image,
                        removeAction: {
                            removeStoryboardPhoto(at: index)
                        },
                        tapAction: {
                            dismissKeyboard()
                            previewedStoryboardPhoto = photo.image
                        }
                    )
                        .onDrag {
                            draggedStoryboardPhotoIndex = index
                            return NSItemProvider(object: String(index) as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: StoryboardPhotoDropDelegate(
                                photos: $storyboardPhotos,
                                draggedIndex: $draggedStoryboardPhotoIndex,
                                destinationIndex: index
                            )
                        )
                }
            }

            if hasStoryboardPhotos, nextAvailablePhotoSlot != nil {
                addPhotoStripButton
            }
        }
    }

    private var referencePhotosSheetStripRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(Array(storyboardPhotos.compactMap { $0 }.enumerated()), id: \.element.id) { index, photo in
                    StoryboardPhotoStripThumbnail(
                        image: photo.image,
                        size: 78,
                        bottomPadding: 16,
                        overflow: 12,
                        removeAction: {
                            removeStoryboardPhoto(at: index)
                        },
                        tapAction: {
                            dismissKeyboard()
                            previewedStoryboardPhoto = photo.image
                        }
                    )
                    .onDrag {
                        draggedStoryboardPhotoIndex = index
                        return NSItemProvider(object: String(index) as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: StoryboardPhotoDropDelegate(
                            photos: $storyboardPhotos,
                            draggedIndex: $draggedStoryboardPhotoIndex,
                            destinationIndex: index
                        )
                    )
                }

            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .frame(height: 110)
    }

    private var referencePhotoSourceChoices: some View {
        HStack(spacing: 12) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                entryInputActionCard(
                    title: "Camera",
                    subtitle: "Take a photo",
                    systemName: "camera.fill"
                ) {
                    presentCameraFromReferencePhotosSheet()
                }
            }

            entryInputActionCard(
                title: "Photo Library",
                subtitle: "Choose an existing photo",
                systemName: "photo.on.rectangle.angled"
            ) {
                presentPhotoLibraryFromReferencePhotosSheet()
            }
        }
    }

    private var entryCharactersSheetStripRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(entryCharacters) { character in
                    CharacterStripThumbnail(
                        character: character,
                        tapAction: {
                            characterEditorSession = CharacterEditorSession(character: character)
                        },
                        removeAction: {
                            deleteCharacter(character)
                        }
                    )
                }

                Button {
                    isEntryCharacterAddChoicesVisible = true
                } label: {
                    StoryboardPhotoStripAddButton(
                        systemName: "plus",
                        iconColor: Color.storyInk.opacity(0.82),
                        size: 58,
                        iconWeight: .light,
                        shape: .circle
                    )
                    .padding(.top, 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add character")
                .frame(width: 68, height: 88, alignment: .top)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(height: 92)
    }

    private var characterPhotoSourceSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Add Character")
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            HStack(spacing: 12) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    entryInputActionCard(
                        title: "Camera",
                        subtitle: "Take a portrait",
                        systemName: "camera.fill"
                    ) {
                        presentCreateCharacterFromEntryCharactersSheet(source: .camera)
                    }
                }

                entryInputActionCard(
                    title: "Photo Library",
                    subtitle: "Choose a portrait",
                    systemName: "photo.on.rectangle.angled"
                ) {
                    presentCreateCharacterFromEntryCharactersSheet(source: .photoLibrary)
                }
            }
        }
    }

    private var entryCharactersReusableLibrarySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("My Characters")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer(minLength: 8)

                Button {
                    refreshReusableCharacters()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.storyPurple)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingReusableCharacters)
                .accessibilityLabel("Refresh My Characters")
            }

            Text("Drag the handle to reorder. Tap Edit to update a saved character, tap + to add them to this entry, or delete them from My Characters.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            if isLoadingReusableCharacters {
                reusableCharacterStatusRow(systemName: nil, text: "Loading characters", showsProgress: true)
            }

            if let reusableCharactersErrorMessage {
                reusableCharacterStatusRow(systemName: "exclamationmark.triangle", text: reusableCharactersErrorMessage, showsProgress: false)
            }

            if reusableCharacters.isEmpty && !isLoadingReusableCharacters {
                reusableCharacterStatusRow(
                    systemName: "person.crop.circle.badge.questionmark",
                    text: "No saved characters yet.",
                    showsProgress: false
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(reusableCharacters) { character in
                        ReusableCharacterLibraryRow(
                            character: character,
                            canAdd: canAddReusableCharacter(character),
                            isDeleting: deletingReusableCharacterID == character.id,
                            isDragging: draggingReusableCharacterID == character.id,
                            onAdd: {
                                addReusableCharacter(character)
                            },
                            onEdit: {
                                editReusableCharacter(character)
                            },
                            onDelete: {
                                deleteReusableCharacter(character)
                            },
                            dragProvider: {
                                beginReusableCharacterDrag(character)
                            }
                        )
                        .onDrop(
                            of: [.text],
                            delegate: ReusableCharacterDropDelegate(
                                character: character,
                                characters: $reusableCharacters,
                                draggingCharacterID: $draggingReusableCharacterID,
                                onReorder: persistReusableCharacterOrder
                            )
                        )
                    }
                }
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    finishReusableCharacterDragInGap()
                }
            }
        }
    }

    private func reusableCharacterStatusRow(systemName: String?, text: String, showsProgress: Bool) -> some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(Color.storyPurple)
            } else if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.storyPurple.opacity(0.82))
                    .frame(width: 20)
            }

            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.66))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func entryInputActionCard(
        title: String,
        subtitle: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.9))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.storyInk.opacity(0.62))
                        .lineLimit(3)
                        .minimumScaleFactor(0.76)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 122)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var referencePhotoStripRow: some View {
        if hasStoryboardPhotos {
            ScrollView(.horizontal, showsIndicators: false) {
                photoStripContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            .frame(height: 76)
        } else {
            Button {
                dismissKeyboard()
                openPhotoSourceSheet()
            } label: {
                addReferencePhotoTileLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .frame(height: 76, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add reference photos")
        }
    }

    @ViewBuilder
    private var characterPhotoStripRow: some View {
        if entryCharacters.isEmpty {
            Button {
                dismissKeyboard()
                characterEditorSession = CharacterEditorSession(character: nil)
            } label: {
                addCharacterTileLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                    .frame(height: 92, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add character")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(entryCharacters) { character in
                        CharacterStripThumbnail(
                            character: character,
                            tapAction: {
                                dismissKeyboard()
                                characterEditorSession = CharacterEditorSession(character: character)
                            },
                            removeAction: {
                                deleteCharacter(character)
                            }
                        )
                    }

                    addCharacterTile
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .frame(height: 92)
        }
    }

    private var characterPhotoExplainerText: some View {
        Text("Use this to add character references, and single out people from group photos. If your story has more than one character, reference them here.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.storyInk.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var addCharacterTile: some View {
        Button {
            dismissKeyboard()
            characterEditorSession = CharacterEditorSession(character: nil)
        } label: {
            addCharacterTileLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add character")
        .frame(height: 76)
    }

    private var addCharacterTileLabel: some View {
        HStack(spacing: 8) {
            StoryboardPhotoStripAddButton(
                systemName: entryCharacters.isEmpty ? "person.crop.circle.badge.plus" : "plus",
                iconColor: entryCharacters.isEmpty ? Color.storyPurple : Color.storyInk.opacity(0.82),
                size: 58,
                iconWeight: entryCharacters.isEmpty ? .semibold : .light,
                shape: .circle
            )

            if entryCharacters.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Character")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyPurple)

                    Text("Choose a portrait")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.storyInk.opacity(0.66))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }
        }
    }

    private var addReferencePhotoTileLabel: some View {
        HStack(spacing: 9) {
            StoryboardPhotoStripAddButton(
                systemName: "camera",
                iconColor: Color.storyPurple,
                iconWeight: .semibold
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Add Reference Photos")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyPurple)

                Text("Up to 5 photos")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
    }

    private var addPhotoStripButton: some View {
        Button {
            dismissKeyboard()
            openPhotoSourceSheet()
        } label: {
            StoryboardPhotoStripAddButton(
                systemName: hasStoryboardPhotos ? "plus" : "camera",
                iconColor: hasStoryboardPhotos ? Color.storyInk.opacity(0.82) : Color.storyPurple,
                iconWeight: hasStoryboardPhotos ? .light : .semibold
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add reference photos")
    }

    private func togglePhotosPanel() {
        withAnimation(.snappy(duration: 0.2)) {
            isPhotosPanelVisible.toggle()
            isShowingCustomizeSheet = false
            isShowingJournalPromptsSheet = false
        }
    }

    private func closePhotosPanel() {
        withAnimation(.snappy(duration: 0.2)) {
            isPhotosPanelVisible = false
        }
    }

    private func closeCustomizePanel() {
        withAnimation(.snappy(duration: 0.2)) {
            isShowingCustomizeSheet = false
        }
    }

    private func closePromptsPanel() {
        withAnimation(.snappy(duration: 0.2)) {
            isShowingJournalPromptsSheet = false
        }
    }

    private func togglePhotoTabCollapsed() {
        withAnimation(.snappy(duration: 0.2)) {
            isPhotoTabCollapsed.toggle()
        }
    }

    private func toggleCharacterTabCollapsed() {
        withAnimation(.snappy(duration: 0.2)) {
            isCharacterTabCollapsed.toggle()
        }
    }

    private func toggleStoryDetailsTabCollapsed() {
        withAnimation(.snappy(duration: 0.2)) {
            isStoryDetailsTabCollapsed.toggle()
        }
    }

    private func photoSourceButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button {
            dismissKeyboard()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.storyPurple)
                    .frame(height: 26)

                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 76, height: 82)
            .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.storyPurple.opacity(0.32), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var entryDetailsInfoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your memories become a graphic novel.")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Choose the style, story details, and journal before generating your storyboard.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.75))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.58), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
    }

    private var currentEntryStoryboards: [GeneratedStoryboard] {
        let entryID = activeDraftID
        var seen = Set<UUID>()
        var storyboards: [GeneratedStoryboard] = []

        for storyboard in generatedStoryboards + (entryID.map(loadedStoryboards(clientEntryID:)) ?? []) {
            guard
                let clientEntryID = storyboard.clientEntryID,
                clientEntryID == entryID,
                seen.insert(storyboard.id).inserted
            else {
                continue
            }

            storyboards.append(storyboard)
        }

        if storyboards.isEmpty,
           let entryID,
           let completedEntryOpenedStoryboardImage {
            storyboards.append(
                GeneratedStoryboard(
                    clientEntryID: entryID,
                    image: completedEntryOpenedStoryboardImage,
                    promptText: entryText,
                    artStyle: selectedArtStyle,
                    sourcePhotoCount: 0,
                    isPrimary: true,
                    isSampleContent: authoringMode.isSampleStudio
                )
            )
        }

        // Creation order only — marking a storyboard primary must not move it.
        return storyboards.sorted { left, right in
            left.createdAt < right.createdAt
        }
    }

    private func refreshCurrentEntryStoryboardsFromStore() {
        guard let activeDraftID else {
            return
        }

        generatedStoryboards = loadedStoryboards(clientEntryID: activeDraftID)
    }

    private func currentStoryboardsCard(fallbackImage: UIImage) -> some View {
        let storyboards = currentEntryStoryboards
        let displayStoryboards = storyboards.isEmpty
            ? [
                GeneratedStoryboard(
                    clientEntryID: activeDraftID,
                    image: fallbackImage,
                    promptText: entryText,
                    artStyle: selectedArtStyle,
                    sourcePhotoCount: 0,
                    isPrimary: true,
                    isSampleContent: authoringMode.isSampleStudio
                )
            ]
            : storyboards

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Text("Current Storyboards for this Entry")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text("\(displayStoryboards.count)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.storyPurple.opacity(0.72), in: Circle())

                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(displayStoryboards.enumerated()), id: \.element.id) { index, storyboard in
                        let thumbnail = currentStoryboardThumbnail(
                            image: storyboard.image,
                            isPrimary: storyboard.isPrimary
                        )
                        .onTapGesture {
                            openStoryboardViewer(for: storyboard)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(storyboard.isPrimary ? "Primary storyboard, open full screen" : "Open storyboard version \(index + 1) full screen")

                        // Placeholder and sample storyboards have nothing to act on, and an
                        // empty context menu would still open on long press.
                        if storyboard.isDeletable, !storyboard.isPrimary {
                            thumbnail.contextMenu {
                                storyboardThumbnailMenu(for: storyboard)
                            }
                        } else {
                            thumbnail
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.54), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    /// Deletion lives on the thumbnail's own trash badge, so the long-press menu is left with
    /// the one action that has nowhere else to go.
    @ViewBuilder
    private func storyboardThumbnailMenu(for storyboard: GeneratedStoryboard) -> some View {
        Button {
            setPrimaryStoryboard(storyboard)
        } label: {
            Label("Set as Primary", systemImage: "star")
        }
    }

    private var deletableEntryStoryboards: [GeneratedStoryboard] {
        currentEntryStoryboards.filter(\.isDeletable)
    }

    private var storyboardDeletionMessage: String {
        let creditNote = "This can't be undone."
        let storyboardCount = deletableEntryStoryboards.count

        guard storyboardCount > 1 else {
            return "This is the only storyboard for this entry. Deleting it moves the entry back to Drafts. \(creditNote)"
        }

        let keptCount = storyboardCount - 1
        let keptText = keptCount == 1
            ? "The other storyboard is kept"
            : "The other \(keptCount) storyboards are kept"

        return "Only this one is deleted. \(keptText) and the entry stays completed. \(creditNote)"
    }

    private func requestStoryboardDeletion(_ storyboard: GeneratedStoryboard) {
        guard storyboard.isDeletable else {
            return
        }

        storyboardPendingDeletion = storyboard
    }

    private func deleteStoryboard(_ storyboard: GeneratedStoryboard) {
        guard storyboard.isDeletable, !isDeletingStoryboard else {
            return
        }

        storyboardPendingDeletion = nil
        isDeletingStoryboard = true
        setCloudSaveState(.saving)
        let isSignedIn = authStore.userID != nil

        Task {
            do {
                let outcome = try await StoryboardDeletionService().delete(
                    [storyboard],
                    isSignedIn: isSignedIn
                )
                await MainActor.run {
                    applyStoryboardDeletion(outcome)
                    setCloudSaveState(.saved)
                    isDeletingStoryboard = false
                }
            } catch let error as StoryboardDeletionError {
                await MainActor.run {
                    applyStoryboardDeletion(error.outcome)
                    setCloudSaveState(.failed(error.localizedDescription))
                    isDeletingStoryboard = false
                }
            } catch {
                await MainActor.run {
                    setCloudSaveState(.failed("Could not delete this storyboard. Check your connection and try again."))
                    isDeletingStoryboard = false
                }
            }
        }
    }

    private func deleteCurrentEntry() {
        guard let entryID = activeDraftID, !isDeletingEntry else {
            return
        }

        isConfirmingEntryDeletion = false
        isDeletingEntry = true
        // The entry is on its way out; nothing may write it back while the delete is in flight.
        isAutosaveSuspended = true
        cancelPendingLocalAutosave()
        dismissKeyboard()
        let isSignedIn = authStore.userID != nil

        Task {
            do {
                // A nil cloudEntry still clears the cloud rows by client entry ID, so the editor
                // does not need to carry a JournalEntry of its own.
                try await EntrySaveService().deleteEntry(
                    localDraftID: entryID,
                    cloudEntry: nil,
                    isSignedIn: isSignedIn
                )

                await MainActor.run {
                    StoryEntryStore.delete(entryID: entryID)
                    EntryJournalLinkStore.remove(for: entryID)
                    generatedStoryboards.removeAll { $0.clientEntryID == entryID }
                    if storyboardGenerationStatus?.entryID == entryID {
                        storyboardGenerationStatus = nil
                    }
                    isDeletingEntry = false
                    NotificationCenter.default.post(name: .storytopiaGeneratedStoryboardsChanged, object: nil)
                    closeEditorAfterDeletion()
                }
            } catch {
                await MainActor.run {
                    isDeletingEntry = false
                    // The entry survived, and so does the editing session it belongs to.
                    isAutosaveSuspended = false
                    entryDeletionErrorMessage = "Could not delete this entry. Check your connection and try again."
                }
            }
        }
    }

    /// The editor is only torn down once the delete has actually landed, so a failure leaves the
    /// entry on screen instead of dismissing into a view whose entry no longer exists.
    private func closeEditorAfterDeletion() {
        completedEntryOpenedStoryboardImage = nil
        isOpeningCompletedEntryFromEntries = false
        isPreviewingCompletedStoryboard = false
        selectedEntryStoryboardIndex = nil
        // clearEditor() also leaves the Entry Details page, so the push unwinds before the
        // editor itself is dismissed.
        clearEditor()
        activeDraftID = nil
        isDraftSaved = !CreateEntryDraftStore.loadAll().isEmpty

        withAnimation(.snappy(duration: 0.32)) {
            dismissCreate()
        }
    }

    private func applyStoryboardDeletion(_ outcome: StoryboardDeletionOutcome) {
        guard let activeDraftID, !outcome.isEmpty else {
            return
        }

        refreshCurrentEntryStoryboardsFromStore()

        guard !outcome.entriesReturnedToDrafts.contains(activeDraftID) else {
            currentEntryStatus = .draft
            completedEntryOpenedStoryboardImage = nil
            // Nothing left to show, so the viewer would otherwise sit on a blank screen.
            isPreviewingCompletedStoryboard = false
            selectedEntryStoryboardIndex = nil
            return
        }

        let remainingStoryboards = generatedStoryboards.filter { $0.clientEntryID == activeDraftID }
        guard !remainingStoryboards.isEmpty else {
            isPreviewingCompletedStoryboard = false
            selectedEntryStoryboardIndex = nil
            return
        }

        completedEntryOpenedStoryboardImage = remainingStoryboards.first(where: \.isPrimary)?.image
            ?? remainingStoryboards.max(by: { $0.createdAt < $1.createdAt })?.image
    }

    private func openStoryboardViewer(for storyboard: GeneratedStoryboard) {
        let storyboards = currentEntryStoryboards
        guard !storyboards.isEmpty else {
            return
        }

        selectedEntryStoryboardIndex = storyboards.firstIndex(where: { $0.id == storyboard.id }) ?? 0
        isPreviewingCompletedStoryboard = true
    }

    private func setPrimaryStoryboard(_ storyboard: GeneratedStoryboard) {
        guard let clientEntryID = storyboard.clientEntryID else {
            return
        }

        selectedEntryStoryboardIndex = nil
        let updatedStore = GeneratedStoryboardStore.markPrimary(
            storyboardID: storyboard.id,
            clientEntryID: clientEntryID
        )
        generatedStoryboards = updatedStore
        completedEntryOpenedStoryboardImage = storyboard.image

        guard authStore.userID != nil else {
            return
        }

        Task {
            do {
                try await SupabaseStoryboardService().setPrimaryStoryboard(storyboard)
                await MainActor.run {
                    setCloudSaveState(.saved)
                }
            } catch {
                await MainActor.run {
                    setCloudSaveState(.failed("Could not save the primary storyboard. Check your connection and try again."))
                }
            }
        }
    }

    private func currentStoryboardThumbnail(image: UIImage, isPrimary: Bool) -> some View {
        let aspectRatio = max(image.size.width, 1) / max(image.size.height, 1)
        let thumbnailHeight: CGFloat = 200

        return VStack(alignment: .leading, spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: min(max(thumbnailHeight * aspectRatio, 150), 318), height: thumbnailHeight)
                .background(Color.storyInk.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isPrimary ? Color.storyPurple : Color.storyBorder.opacity(0.58), lineWidth: isPrimary ? 2 : 1)
                )
                .overlay(alignment: .bottomLeading) {
                    if isPrimary {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .black))

                            Text("Primary")
                                .font(.system(size: 10, weight: .heavy))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Color.storyPurple, in: UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 7,
                            bottomTrailingRadius: 6,
                            topTrailingRadius: 6,
                            style: .continuous
                        ))
                    }
                }
        }
        .accessibilityLabel(isPrimary ? "Primary storyboard" : "Storyboard")
    }

    private var currentStoryboardVersionPrompt: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Create another version")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.storyPurple)

                Text("Try a different art style or settings without replacing your current storyboard.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.64))
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.storyPurple.opacity(0.54), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    private var nextAvailablePhotoSlot: Int? {
        storyboardPhotos.firstIndex(where: { $0 == nil })
    }

    private func setStoryboardPhoto(_ image: UIImage) {
        guard let slot = selectedPhotoSlot ?? nextAvailablePhotoSlot else {
            return
        }

        storyboardPhotos[slot] = CreateEntryReferencePhoto(image: image)
        selectedPhotoSlot = nil
    }

    private func setStoryboardPhotos(_ images: [UIImage]) {
        guard
            !images.isEmpty,
            let firstSlot = selectedPhotoSlot ?? nextAvailablePhotoSlot
        else {
            selectedPhotoSlot = nil
            return
        }

        var updatedPhotos = storyboardPhotos
        var slot = firstSlot

        for image in images {
            guard updatedPhotos.indices.contains(slot) else {
                break
            }

            updatedPhotos[slot] = CreateEntryReferencePhoto(image: image)
            slot += 1
        }

        storyboardPhotos = updatedPhotos
        selectedPhotoSlot = nil
    }

    @MainActor
    private func loadPhotoLibraryImages(from items: [PhotosPickerItem]) async {
        defer {
            selectedPhotoPickerItems = []
        }

        var images: [UIImage] = []

        for item in items {
            guard
                let data = try? await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                continue
            }

            images.append(image)
        }

        setStoryboardPhotos(images)
    }

    private func removeStoryboardPhoto(at index: Int) {
        var existingPhotos = storyboardPhotos.compactMap { $0 }
        guard existingPhotos.indices.contains(index) else {
            return
        }

        existingPhotos.remove(at: index)
        storyboardPhotos = paddedStoryboardPhotos(existingPhotos)
    }

    private func saveCharacter(_ character: EntryCharacter) {
        entryCharacters = EntryCharacterRules.applyingSingleMainCharacter(character, to: entryCharacters)
        characterEditorSession = nil
    }

    private func saveLibraryCharacter(_ character: EntryCharacter) {
        guard canPersistEntry else {
            signInGate.requireAccount(for: .saveCharacter)
            return
        }

        if let index = reusableCharacters.firstIndex(where: { $0.id == character.id }) {
            reusableCharacters[index] = character
        } else {
            reusableCharacters.insert(character, at: 0)
        }
        reusableCharacters = mergedReusableCharacters(reusableCharacters)

        if entryCharacters.contains(where: { $0.id == character.id }) {
            entryCharacters = EntryCharacterRules.applyingSingleMainCharacter(character, to: entryCharacters)
        }

        if !authoringMode.isSampleStudio {
            CreateEntryDraftStore.updateCharacter(character, excludingDraftID: activeDraftID)
        }
        characterEditorSession = nil
        reusableCharactersErrorMessage = nil

        Task {
            do {
                guard !authoringMode.isSampleStudio else {
                    return
                }

                try await SupabaseEntryCharacterService().updateCharacter(character)
            } catch {
                await MainActor.run {
                    reusableCharactersErrorMessage = "Could not save changes to \(character.name) in the cloud."
                }
            }
        }
    }

    private var attachedReusableCharacterIDs: Set<UUID> {
        // A library character counts as attached when the entry holds it directly or holds a copy made from it.
        var attachedIDs = Set(entryCharacters.map(\.id))
        for character in entryCharacters {
            if let originID = reusableCharacterOrigins[character.id] {
                attachedIDs.insert(originID)
            }
        }

        return attachedIDs
    }

    private func canAddReusableCharacter(_ character: EntryCharacter) -> Bool {
        !attachedReusableCharacterIDs.contains(character.id)
    }

    private func editReusableCharacter(_ character: EntryCharacter) {
        isShowingReusableCharactersSheet = false
        characterEditorSession = CharacterEditorSession(character: character, destination: .library)
    }

    private func deleteReusableCharacter(_ character: EntryCharacter) {
        deletingReusableCharacterID = character.id
        reusableCharactersErrorMessage = nil

        Task {
            var cloudDeleteFailed = false
            if authStore.userID != nil, !authoringMode.isSampleStudio {
                do {
                    try await SupabaseEntryCharacterService().deleteCharacter(id: character.id)
                } catch {
                    cloudDeleteFailed = true
                }
            }

            await MainActor.run {
                deletingReusableCharacterID = nil

                if cloudDeleteFailed {
                    reusableCharactersErrorMessage = "Could not delete \(character.name) from the cloud."
                    return
                }

                reusableCharacters.removeAll { $0.id == character.id }
                if entryCharacters.contains(where: { $0.id == character.id }) {
                    deleteCharacter(character)
                }
                if !authoringMode.isSampleStudio {
                    CreateEntryDraftStore.removeCharacter(id: character.id, excludingDraftID: activeDraftID)
                }
            }
        }
    }

    private func openReusableCharactersSheet() {
        dismissKeyboard()
        isShowingReusableCharactersSheet = true
        reusableCharacters = authoringMode.isSampleStudio
            ? mergedReusableCharacters(reusableCharacters)
            : mergedReusableCharacters(localReusableCharacters(), reusableCharacters)
        refreshReusableCharacters()
    }

    private func refreshReusableCharacters() {
        let localCharacters = localReusableCharacters()
        reusableCharacters = authoringMode.isSampleStudio
            ? mergedReusableCharacters(reusableCharacters)
            : mergedReusableCharacters(localCharacters, reusableCharacters)
        reusableCharactersErrorMessage = nil

        if authoringMode.isSampleStudio {
            isLoadingReusableCharacters = true
            Task {
                do {
                    let sampleCharacters = try await SupabaseSampleStoryService().loadAuthoringCharacters()
                    await MainActor.run {
                        reusableCharacters = mergedReusableCharacters(sampleCharacters)
                        isLoadingReusableCharacters = false
                    }
                } catch {
                    await MainActor.run {
                        reusableCharacters = []
                        reusableCharactersErrorMessage = "Could not load sample characters."
                        isLoadingReusableCharacters = false
                    }
                }
            }
            return
        }

        guard let userID = authStore.userID else {
            isLoadingReusableCharacters = false
            return
        }

        isLoadingReusableCharacters = true
        Task {
            do {
                let cloudCharacters = try await SupabaseEntryCharacterService().loadAllCharacters(userID: userID)
                await MainActor.run {
                    reusableCharacters = mergedReusableCharacters(cloudCharacters, localCharacters)
                    isLoadingReusableCharacters = false
                }
            } catch {
                await MainActor.run {
                    reusableCharacters = localCharacters
                    reusableCharactersErrorMessage = localCharacters.isEmpty ? "Could not load your saved characters." : nil
                    isLoadingReusableCharacters = false
                }
            }
        }
    }

    private func addReusableCharacter(_ character: EntryCharacter) {
        let now = Date()
        let reusableCharacter = EntryCharacter(
            name: character.name,
            role: character.role,
            image: character.image,
            createdAt: now,
            updatedAt: now
        )
        reusableCharacterOrigins[reusableCharacter.id] = character.id
        saveCharacter(reusableCharacter)
        isShowingReusableCharactersSheet = false
    }

    private func beginReusableCharacterDrag(_ character: EntryCharacter) -> NSItemProvider {
        draggingReusableCharacterID = character.id
        return NSItemProvider(object: character.id.uuidString as NSString)
    }

    /// Catches drops that land between rows so the list still commits the order it is showing.
    private func finishReusableCharacterDragInGap() -> Bool {
        guard draggingReusableCharacterID != nil else {
            return false
        }

        draggingReusableCharacterID = nil
        persistReusableCharacterOrder()
        return true
    }

    /// Stamps the current list positions onto the characters and saves them locally and in the cloud.
    private func persistReusableCharacterOrder() {
        let orderedCharacters = reusableCharacters.enumerated().map { index, character -> EntryCharacter in
            var updated = character
            updated.librarySortOrder = index
            return updated
        }

        reusableCharacters = orderedCharacters
        reusableCharactersErrorMessage = nil

        let librarySortOrders = Dictionary(
            orderedCharacters.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        entryCharacters = entryCharacters.map { character in
            guard let librarySortOrder = librarySortOrders[character.id] else {
                return character
            }

            var updated = character
            updated.librarySortOrder = librarySortOrder
            return updated
        }

        if !authoringMode.isSampleStudio {
            CreateEntryDraftStore.updateLibraryOrder(librarySortOrders)
        }

        guard authStore.userID != nil, !authoringMode.isSampleStudio else {
            return
        }

        Task {
            do {
                try await SupabaseEntryCharacterService().updateLibraryOrder(orderedCharacters)
            } catch {
                await MainActor.run {
                    reusableCharactersErrorMessage = "Could not save the new character order to the cloud."
                }
            }
        }
    }

    private func localReusableCharacters() -> [EntryCharacter] {
        CreateEntryDraftStore.loadAll().flatMap(\.characters)
    }

    private func mergedReusableCharacters(_ characterGroups: [EntryCharacter]...) -> [EntryCharacter] {
        // Merge by identity, not by name, so several characters can share a name.
        var seenIDs: Set<UUID> = []
        var mergedCharacters: [EntryCharacter] = []

        for character in characterGroups.flatMap({ $0 }) {
            guard !character.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seenIDs.contains(character.id) else {
                continue
            }

            seenIDs.insert(character.id)
            mergedCharacters.append(character)
        }

        // Manually ordered characters hold their place; never-dragged ones stay newest-first above them.
        return mergedCharacters.sorted { lhs, rhs in
            switch (lhs.librarySortOrder, rhs.librarySortOrder) {
            case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
                return lhsOrder < rhsOrder
            case (.none, .some):
                return true
            case (.some, .none):
                return false
            default:
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }

                return lhs.createdAt > rhs.createdAt
            }
        }
    }

    private func deleteCharacter(_ character: EntryCharacter) {
        entryCharacters.removeAll { $0.id == character.id }
        characterEditorSession = nil
    }

    private func paddedStoryboardPhotos(_ photos: [CreateEntryReferencePhoto]) -> [CreateEntryReferencePhoto?] {
        let trimmedPhotos = Array(photos.prefix(storyboardPhotos.count))
        return trimmedPhotos.map(Optional.some) + Array(repeating: nil, count: max(0, storyboardPhotos.count - trimmedPhotos.count))
    }

    private var entryDateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            entryDateSheetHeader

            Text(entryDateMetadataText)
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            currentEntryDateButton

            entryDatePrecisionPicker

            if hasEntryDateValue {
                entryDateFieldsCard
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
    }

    private var entryDateSheetHeader: some View {
        HStack(spacing: 10) {
            sheetHeader(title: "Entry Date", systemName: "calendar")

            Spacer()

            if hasEntryDateValue {
                Button("Clear") {
                    clearEntryDate()
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .buttonStyle(.plain)
                .accessibilityLabel("Clear entry date")
            }
        }
    }

    private var entryDateFieldsCard: some View {
        VStack(spacing: 0) {
            if selectedEntryIncludesTime {
                entryDateTimeRow
            }

            if entryDatePrecisionIncludesDay {
                entryDateDividerIfNeeded(after: selectedEntryIncludesTime)

                entryDateMenuRow(
                    title: "Day",
                    value: String(selectedEntryDay)
                ) {
                    entryDayMenu
                }
            }

            if entryDatePrecisionIncludesMonth {
                entryDateDividerIfNeeded(after: selectedEntryIncludesTime || entryDatePrecisionIncludesDay)

                entryDateMenuRow(
                    title: "Month",
                    value: monthName(for: selectedEntryMonth)
                ) {
                    entryMonthMenu
                }
            }

            entryDateDividerIfNeeded(after: selectedEntryIncludesTime || entryDatePrecisionIncludesDay || entryDatePrecisionIncludesMonth)

            entryDateMenuRow(
                title: "Year",
                value: String(selectedEntryYear)
            ) {
                entryYearMenu
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
        )
    }

    private var currentEntryDateButton: some View {
        Button {
            setEntryDateToCurrentDateTime()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))

                Text("Current")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Color.storyPurple)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset to current date and time")
    }

    @ViewBuilder
    private func entryDateDividerIfNeeded(after previousRowIsVisible: Bool) -> some View {
        if previousRowIsVisible {
            Divider()
                .padding(.leading, 16)
        }
    }

    private var entryDatePrecisionPicker: some View {
        HStack(spacing: 8) {
            ForEach(entryDatePrecisionOptions, id: \.self) { precision in
                Button {
                    setEntryDatePrecision(precision)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: entryDatePrecisionIcon(for: precision))
                            .font(.system(size: 15, weight: .semibold))

                        Text(entryDatePrecisionLabel(for: precision))
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .foregroundStyle(storyDatePrecision == precision ? Color.white : Color.storyInk.opacity(0.68))
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background(
                        storyDatePrecision == precision ? Color.storyPurple : Color.white,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                storyDatePrecision == precision ? Color.storyPurple : Color.storyBorder.opacity(0.7),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entryDatePrecisionAccessibilityLabel(for: precision))
            }
        }
    }

    private func entryDateMenuRow<MenuContent: View>(
        title: String,
        value: String,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        Menu {
            menuContent()
        } label: {
            entryDateRowLabel(title: title, value: value)
        }
        .buttonStyle(.plain)
    }

    private func entryDateRowLabel(title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.storyInk)

            Spacer()

            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.62))

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.storyGray.opacity(0.54))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    @ViewBuilder
    private var entryMonthMenu: some View {
        ForEach(1...12, id: \.self) { month in
            Button(monthName(for: month)) {
                updateStoryDate(month: month)
            }
        }
    }

    @ViewBuilder
    private var entryDayMenu: some View {
        ForEach(entryDayOptions, id: \.self) { day in
            Button(String(day)) {
                updateStoryDate(day: day)
            }
        }
    }

    @ViewBuilder
    private var entryYearMenu: some View {
        ForEach(entryYearOptions, id: \.self) { year in
            Button(String(year)) {
                updateStoryDate(year: year)
            }
        }
    }

    private var entryDateTimeRow: some View {
        HStack {
            DatePicker(
                "Time",
                selection: $storyDate,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(.system(size: 15, weight: .semibold))
            .tint(Color.storyPurple)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var entryDatePrecisionOptions: [EntryDatePrecision] {
        [.exact, .dateOnly, .monthAndYear, .yearOnly]
    }

    private var selectedEntryMonth: Int {
        Calendar.current.component(.month, from: storyDate)
    }

    private var selectedEntryDay: Int {
        Calendar.current.component(.day, from: storyDate)
    }

    private var selectedEntryYear: Int {
        Calendar.current.component(.year, from: storyDate)
    }

    private var selectedEntryIncludesTime: Bool {
        storyDatePrecision == .exact
    }

    private var hasEntryDateValue: Bool {
        storyDatePrecision != .noDate
    }

    private var entryDatePrecisionIncludesMonth: Bool {
        storyDatePrecision == .monthAndYear || storyDatePrecision == .dateOnly || storyDatePrecision == .exact
    }

    private var entryDatePrecisionIncludesDay: Bool {
        storyDatePrecision == .dateOnly || storyDatePrecision == .exact
    }

    private var entryYearOptions: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array(stride(from: currentYear + 1, through: currentYear - 125, by: -1))
    }

    private var entryDayOptions: [Int] {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = selectedEntryYear
        components.month = selectedEntryMonth
        components.day = 1

        guard
            let date = calendar.date(from: components),
            let range = calendar.range(of: .day, in: .month, for: date)
        else {
            return Array(1...31)
        }

        return Array(range)
    }

    private func monthName(for month: Int) -> String {
        let formatter = DateFormatter()
        return formatter.monthSymbols[min(max(month - 1, 0), 11)]
    }

    private func entryDatePrecisionLabel(for precision: EntryDatePrecision) -> String {
        switch precision {
        case .yearOnly:
            "Year"
        case .monthAndYear:
            "Month"
        case .dateOnly:
            "Day"
        case .exact:
            "Time"
        case .noDate:
            "Date"
        }
    }

    private func entryDatePrecisionAccessibilityLabel(for precision: EntryDatePrecision) -> String {
        switch precision {
        case .yearOnly:
            "Year only"
        case .monthAndYear:
            "Year and month"
        case .dateOnly:
            "Year, month, and day"
        case .exact:
            "Year, month, day, and time"
        case .noDate:
            "Date"
        }
    }

    private func entryDatePrecisionIcon(for precision: EntryDatePrecision) -> String {
        switch precision {
        case .yearOnly:
            "calendar"
        case .monthAndYear:
            "calendar.badge.plus"
        case .dateOnly:
            "calendar.circle"
        case .exact:
            "clock"
        case .noDate:
            "calendar"
        }
    }

    private func setEntryDatePrecision(_ precision: EntryDatePrecision) {
        didEditEntryDate = true
        ensureEntryDateDefaultsToNow()
        storyDatePrecision = precision == .noDate ? .exact : precision
        updateStoryDate()
    }

    private func setEntryDateToCurrentDateTime() {
        didEditEntryDate = true
        storyDate = Date()
        storyDatePrecision = .exact
    }

    private func clearEntryDate() {
        didEditEntryDate = true
        storyDatePrecision = .noDate
        isShowingEntryDateSheet = false
    }

    private func ensureEntryDateDefaultsToNow() {
        guard storyDatePrecision == .noDate else {
            return
        }

        storyDate = Date()
        storyDatePrecision = .exact
    }

    private func updateStoryDate(year: Int? = nil, month: Int? = nil, day: Int? = nil) {
        didEditEntryDate = true
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: storyDate)
        components.year = year ?? components.year
        components.month = month ?? components.month
        components.day = day ?? components.day

        let firstOfMonth = DateComponents(year: components.year, month: components.month, day: 1)
        if let date = calendar.date(from: firstOfMonth),
           let dayRange = calendar.range(of: .day, in: .month, for: date),
           let day = components.day {
            components.day = min(day, dayRange.upperBound - 1)
        }

        storyDate = calendar.date(from: components) ?? storyDate
    }

    private var entryLocationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                entryLocationSheetHeader

                HStack(spacing: 12) {
                    Image(systemName: "location")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.storyPurple)
                        .frame(width: 22)

                    TextField(
                        "",
                        text: $storyLocation,
                        prompt: Text("Add a location")
                            .foregroundColor(Color.homeMutedText.opacity(0.72))
                    )
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.storyInk)
                        .tint(Color.storyPurple)
                        .textInputAutocapitalization(.words)
                        .onChange(of: storyLocation) { newValue in
                            didEditEntryLocation = true
                            locationSearch.updateQuery(newValue)
                        }

                }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
                )

                if !recentEntryLocations.isEmpty {
                    EntryLocationRecentsList(
                        locations: recentEntryLocations,
                        accentColor: Color.storyPurple,
                        onSelect: { location in
                            didEditEntryLocation = true
                            storyLocation = location
                            locationSearch.clear()
                            isShowingEntryLocationSheet = false
                        },
                        onClear: {
                            EntryLocationRecentStore.clear()
                            recentEntryLocations = []
                        }
                    )
                }

                if locationSearch.isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.74)

                        Text("Finding places...")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.homeMutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }

                if !locationSearch.suggestions.isEmpty {
                    locationSuggestionList
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            recentEntryLocations = EntryLocationRecentStore.all
            locationSearch.updateQuery(storyLocation)
        }
        .onDisappear {
            locationSearch.clear()
        }
    }

    private var entryLocationSheetHeader: some View {
        HStack(spacing: 10) {
            sheetHeader(title: "Entry Location", systemName: "location")

            Spacer()

            if !storyLocation.isEmpty {
                Button("Clear") {
                    clearEntryLocation()
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .buttonStyle(.plain)
                .accessibilityLabel("Clear entry location")
            }
        }
    }

    private func clearEntryLocation() {
        didEditEntryLocation = true
        storyLocation = ""
        locationSearch.clear()
    }

    private var locationSuggestionList: some View {
        VStack(spacing: 0) {
            ForEach(locationSearch.suggestions) { suggestion in
                Button {
                    didEditEntryLocation = true
                    storyLocation = suggestion.displayText
                    EntryLocationRecentStore.add(storyLocation)
                    recentEntryLocations = EntryLocationRecentStore.all
                    locationSearch.clear()
                    isShowingEntryLocationSheet = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.storyPurple)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.storyInk)
                                .lineLimit(1)

                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.homeMutedText)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion.id != locationSearch.suggestions.last?.id {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
        )
    }

    private func sheetHeader(title: String, systemName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 30, height: 30)
                .background(Color.storyPurple.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
        }
    }

    private func storyTextFieldRow(
        icon: String,
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.9))
                .frame(width: 72, alignment: .leading)

            TextField(placeholder, text: text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.storyInk)
                .tint(Color.storyPurple)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var entryPrivacyCard: some View {
        VStack(spacing: 0) {
            entrySwitchRow(
                icon: "tray.and.arrow.down",
                title: "Save Entry",
                subtitle: "Save progress and come back later",
                isOn: $savesDraft
            )

            Divider()
                .padding(.leading, 44)

            entrySwitchRow(
                icon: "lock.shield",
                title: "Private Entry",
                subtitle: "Only you can see this entry",
                isOn: $isPrivateEntry
            )
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private func entrySwitchRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.storyPurple))
        .padding(.horizontal, 12)
        .frame(height: 58)
    }

    private var artStylePickerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)

                Text("Choose Art Style")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(artStyles, id: \.self) { style in
                        Button {
                            selectedArtStyle = style
                            dismissKeyboard()
                        } label: {
                            InlineArtStyleOption(
                                title: style,
                                isSelected: selectedArtStyle == style
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.54), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }

    private var generateStoryboardButton: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 22, height: 22)

                Text("The AI will analyze your entry and photos to create a comic storyboard. Most users get the best results using Auto settings.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.storyPurple.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.storyPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                dismissKeyboard()
                startStoryboardGeneration()
            } label: {
                HStack(spacing: 7) {
                    if isGeneratingStoryboard {
                        ProgressView()
                            .tint(.white)

                        Text(storyboardGenerationButtonTitle)
                    } else {
                        Text(storyboardGenerationButtonTitle)
                        if storyboardGenerationPhase != .completed {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 12, weight: .semibold))

                                Text("\(selectedImageGenerationQuality.creditCost)")
                                    .font(.system(size: 13, weight: .bold))
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(Color.white.opacity(0.18), in: Capsule())
                        }
                    }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    LinearGradient(
                        colors: [Color.storyPurple.opacity(0.95), Color.storyPurple],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .shadow(color: Color.storyPurple.opacity(0.18), radius: 10, y: 5)
            }
            .disabled(isStoryboardGenerationButtonDisabled)
            .opacity(isStoryboardGenerationButtonDisabled ? 0.76 : 1)

            Text(generationButtonFootnote)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isShortOnGenerationCredits ? Color.red.opacity(0.82) : Color.storyInk.opacity(0.46))

            Button {
                showStoryboardGenerationProgressPreview()
            } label: {
                Text("Preview generation progress screen")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private var generationButtonFootnote: String {
        if isShortOnGenerationCredits {
            return "Add credits before generating another storyboard."
        }

        return completedEntryOpenedStoryboardImage == nil ? "Estimated time: around 2 minutes" : "This will be saved as a new version."
    }
}

private struct StoryboardGenerationProgressScreen: View {
    let phase: StoryboardGenerationPhase
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Image("generate-storyboard-bg")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.24).ignoresSafeArea())

            Color.storyPurple.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                AnimatedStoryboardSparkleIcon()

                VStack(spacing: 8) {
                    Text("Generating your storyboard...")
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                        .multilineTextAlignment(.center)

                    StoryboardGenerationStatusRotator(phase: phase)
                }

                StoryboardGenerationProgressBar(phase: phase)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 34)
            .frame(width: 280)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.82), lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.18), radius: 24, y: 14)

            VStack {
                HStack {
                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.storyInk.opacity(0.68))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.88), in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
                            )
                            .shadow(color: Color.storyInk.opacity(0.12), radius: 10, y: 5)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss generation progress")
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
        }
        .statusBarHidden()
    }
}

private struct AnimatedStoryboardSparkleIcon: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.storyPurple.opacity(0.1))
                .scaleEffect(isAnimating ? 1.08 : 0.94)

            Circle()
                .stroke(Color.storyPurple.opacity(isAnimating ? 0.04 : 0.18), lineWidth: 1.5)
                .scaleEffect(isAnimating ? 1.24 : 0.82)

            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .scaleEffect(isAnimating ? 1.08 : 0.94)
                .rotationEffect(.degrees(isAnimating ? 8 : -8))
        }
        .frame(width: 64, height: 64)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

}

private struct StoryboardGenerationStatusRotator: View {
    let phase: StoryboardGenerationPhase

    @State private var statusIndex = 0

    private let statusMessages = [
        "Sending your image details...",
        "Generating your image...",
        "Building storyboard panels...",
        "Adding finishing touches...",
        "Still in progress..."
    ]

    private var statusText: String {
        switch phase {
        case .completed, .failed:
            return phase.progressTitle
        default:
            return statusMessages[statusIndex % statusMessages.count]
        }
    }

    var body: some View {
        Text(statusText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.homeMutedText)
            .multilineTextAlignment(.center)
            .frame(minHeight: 18)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.28), value: statusText)
            .onReceive(Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()) { _ in
                guard phase != .completed, phase != .failed else {
                    return
                }

                statusIndex = (statusIndex + 1) % statusMessages.count
            }
    }
}

private struct StoryboardGenerationProgressBar: View {
    let phase: StoryboardGenerationPhase

    private var isComplete: Bool {
        phase == .completed
    }

    private var isFailed: Bool {
        phase == .failed
    }

    var body: some View {
        Group {
            if isComplete {
                StoryboardGenerationCompleteBar()
            } else {
                StoryboardGenerationProgressFillBar(phase: phase, isActive: !isFailed)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storyboard generation progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isComplete {
            return "Complete"
        }

        if isFailed {
            return "Stopped"
        }

        return "In progress"
    }
}

private struct StoryboardGenerationCompleteBar: View {
    var body: some View {
        Capsule()
            .fill(Color.storyPurple)
    }
}

private struct StoryboardGenerationProgressFillBar: View {
    let phase: StoryboardGenerationPhase
    let isActive: Bool

    @State private var isAnimating = false
    @State private var startedAt = Date()

    private func progress(at date: Date) -> CGFloat {
        guard isActive else {
            return 0.18
        }

        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let estimatedDuration: TimeInterval = 110
        let normalizedProgress = min(elapsed / estimatedDuration, 1)
        return 0.08 + (0.88 * CGFloat(normalizedProgress))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let width = proxy.size.width
                let progress = progress(at: timeline.date)
                let fillWidth = max(width * progress, 12)
                let highlightWidth = max(fillWidth * 0.28, 22)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.storyPurple.opacity(0.14))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.storyPurple.opacity(0.78),
                                    Color.storyPurple,
                                    Color.storyPurple.opacity(0.86)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0),
                                                Color.white.opacity(0.48),
                                                Color.white.opacity(0)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: highlightWidth)
                                    .offset(x: isAnimating ? fillWidth : -highlightWidth)
                                    .mask(Capsule().frame(width: fillWidth))
                            }
                        }

                    if phase == .failed {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.storyPurple.opacity(0.44),
                                        Color.storyPurple.opacity(0.24)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: width)
                    }
                }
                .clipShape(Capsule())
                .onAppear {
                    startedAt = Date()
                    guard isActive else {
                        return
                    }

                    isAnimating = false
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        isAnimating = true
                    }
                }
                .onChange(of: isActive) { newValue in
                    guard newValue else {
                        isAnimating = false
                        return
                    }

                    isAnimating = false
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        isAnimating = true
                    }
                }
            }
        }
    }
}

private struct JournalEntryPromptsSheet: View {
    let onSelect: (JournalEntryPrompt) -> Void
    let onClose: (() -> Void)?
    let showsNavigationChrome: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: JournalPromptCategory = .today

    init(
        onSelect: @escaping (JournalEntryPrompt) -> Void,
        onClose: (() -> Void)? = nil,
        showsNavigationChrome: Bool = true
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.showsNavigationChrome = showsNavigationChrome
    }

    private var prompts: [JournalEntryPrompt] {
        switch selectedCategory {
        case .today:
            todayPrompts
        case .past:
            pastPrompts
        case .future:
            futurePrompts
        }
    }

    var body: some View {
        Group {
            if showsNavigationChrome {
                promptContent
                    .background(Color.homePageBackground)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") {
                                dismiss()
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.storyPurple)
                        }
                        .hideSharedBackgroundIfAvailable()

                        ToolbarItem(placement: .principal) {
                            promptsTitle
                        }
                    }
                    .toolbarBackground(Color.homePageBackground, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        promptsTitle

                        Spacer(minLength: 8)

                        Button {
                            onClose?()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Color.storyInk.opacity(0.62))
                                .frame(width: 34, height: 34)
                                .background(Color.homeInputGray.opacity(0.7), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close prompts panel")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    promptContent
                }
                .background(Color.white)
            }
        }
    }

    private var promptContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(JournalPromptCategory.allCases) { category in
                    promptCategoryTab(category)
                }
            }
            .padding(4)
            .background(Color.homeInputGray, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(prompts) { prompt in
                        Button {
                            onSelect(prompt)
                        } label: {
                            promptRow(prompt)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
    }

    private var promptsTitle: some View {
        HStack(spacing: 7) {
            Image(systemName: "lightbulb")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.storyPurple)

            Text("Journal Suggestions")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
        }
    }

    private func promptCategoryTab(_ category: JournalPromptCategory) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            selectedCategory = category
        } label: {
            Text(category.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : Color.storyInk.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    isSelected ? Color.storyPurple : Color.white.opacity(0.62),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var todayPrompts: [JournalEntryPrompt] {
        [
            JournalEntryPrompt(
                title: "A Moment I Want to Remember",
                text: "What happened today that felt worth holding onto, even if it was small?",
                systemName: "sparkle"
            ),
            JournalEntryPrompt(
                title: "How I Really Feel",
                text: "What have I been feeling lately, and what might be underneath it?",
                systemName: "heart.text.square"
            ),
            JournalEntryPrompt(
                title: "Someone on My Mind",
                text: "Who has been on my mind recently, and why do they matter to me right now?",
                systemName: "person.crop.circle"
            ),
            JournalEntryPrompt(
                title: "Something I Appreciated",
                text: "What made my life feel a little warmer, easier, or more beautiful today?",
                systemName: "sun.max"
            ),
            JournalEntryPrompt(
                title: "Things I Am Grateful For",
                text: "What people, places, moments, or comforts am I grateful for in my life right now?",
                systemName: "heart.circle"
            ),
            JournalEntryPrompt(
                title: "Where My Energy Went",
                text: "What took most of my energy today, and did it feel worth it?",
                systemName: "bolt"
            ),
            JournalEntryPrompt(
                title: "A Change I Noticed",
                text: "What feels different in my life lately, even in a subtle way?",
                systemName: "arrow.triangle.2.circlepath"
            ),
            JournalEntryPrompt(
                title: "A Conversation That Stayed",
                text: "What conversation, message, or quiet exchange has stayed with me?",
                systemName: "bubble.left.and.bubble.right"
            ),
            JournalEntryPrompt(
                title: "What I Need to Let Go",
                text: "What am I carrying that I might be ready to set down?",
                systemName: "leaf"
            ),
            JournalEntryPrompt(
                title: "What I Need Next",
                text: "What would help me feel more grounded, connected, or alive tomorrow?",
                systemName: "arrow.forward.circle"
            )
        ]
    }

    private var pastPrompts: [JournalEntryPrompt] {
        [
            JournalEntryPrompt(
                title: "The Best Day of My Life",
                text: "What day still feels like one of the best days of my life, and what made it so alive?",
                systemName: "star.circle"
            ),
            JournalEntryPrompt(
                title: "A Childhood Place",
                text: "What place from my childhood can I still picture clearly, and what did it feel like to be there?",
                systemName: "house"
            ),
            JournalEntryPrompt(
                title: "A Person Who Shaped Me",
                text: "Who from my past helped shape who I am, and what part of them do I still carry?",
                systemName: "person.2"
            ),
            JournalEntryPrompt(
                title: "A Memory That Changed Me",
                text: "What past experience changed the way I see myself, other people, or the world?",
                systemName: "arrow.left.and.right"
            ),
            JournalEntryPrompt(
                title: "Something I Miss",
                text: "What do I miss from an earlier season of my life, and what did it give me?",
                systemName: "clock.arrow.circlepath"
            ),
            JournalEntryPrompt(
                title: "A Hard Thing I Survived",
                text: "What difficult chapter did I make it through, and what strength did it reveal in me?",
                systemName: "mountain.2"
            ),
            JournalEntryPrompt(
                title: "A Version of Me",
                text: "What would I want to say to a younger version of myself today?",
                systemName: "figure.wave"
            ),
            JournalEntryPrompt(
                title: "An Ordinary Day Back Then",
                text: "What ordinary day from the past do I wish I could visit again for a few minutes?",
                systemName: "calendar"
            )
        ]
    }

    private var futurePrompts: [JournalEntryPrompt] {
        [
            JournalEntryPrompt(
                title: "A Future I Want",
                text: "What future would make me proud to say I built it with care?",
                systemName: "sparkles"
            ),
            JournalEntryPrompt(
                title: "My Life One Year From Now",
                text: "If life feels better one year from now, what has changed in my days, relationships, and habits?",
                systemName: "calendar.badge.clock"
            ),
            JournalEntryPrompt(
                title: "A Dream Day Ahead",
                text: "What would a truly beautiful day in my future look like from morning to night?",
                systemName: "sunrise"
            ),
            JournalEntryPrompt(
                title: "Who I Am Becoming",
                text: "What kind of person am I slowly becoming, and what do I hope people feel around me?",
                systemName: "person.crop.circle.badge.plus"
            ),
            JournalEntryPrompt(
                title: "Something I Want to Create",
                text: "What do I want to create, build, learn, or experience that would make my life feel larger?",
                systemName: "paintbrush"
            ),
            JournalEntryPrompt(
                title: "A Place I Want to Go",
                text: "Where do I want to go someday, and what am I hoping to find or feel there?",
                systemName: "map"
            ),
            JournalEntryPrompt(
                title: "Future Relationships",
                text: "What do I want my relationships to feel like in the future, and how can I move toward that now?",
                systemName: "heart.circle"
            ),
            JournalEntryPrompt(
                title: "A Promise to Myself",
                text: "What promise do I want to make to my future self, even if I start small?",
                systemName: "checkmark.seal"
            )
        ]
    }

    private func promptRow(_ prompt: JournalEntryPrompt) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: prompt.systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 38, height: 38)
                .background(Color.storyPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(prompt.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "plus.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.storyPurple.opacity(0.88))
                .padding(.top, 8)
        }
        .padding(14)
        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.62), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        .contentShape(Rectangle())
    }
}

struct AddEntryToJournalPage: View {
    @Binding var selectedJournalTitle: String?
    @Binding var selectedJournalTitles: Set<String>

    let contentMode: StorytopiaContentMode
    let onSelect: (String) -> Void
    let onSaveSelection: (Set<String>) -> Void

    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.dismiss) private var dismiss
    @State private var pendingJournalTitles: Set<String> = []
    @State private var isCreateJournalAlertPresented = false
    @State private var newJournalName = ""
    @State private var sampleJournals: [PrototypeChapter] = []

    init(
        selectedJournalTitle: Binding<String?>,
        selectedJournalTitles: Binding<Set<String>>,
        contentMode: StorytopiaContentMode = .user,
        onSelect: @escaping (String) -> Void,
        onSaveSelection: @escaping (Set<String>) -> Void
    ) {
        _selectedJournalTitle = selectedJournalTitle
        _selectedJournalTitles = selectedJournalTitles
        self.contentMode = contentMode
        self.onSelect = onSelect
        self.onSaveSelection = onSaveSelection
    }

    private var authoringMode: CreateEntryAuthoringMode {
        contentMode.authoringMode
    }

    /// Signed-out browsing lists the sample journals rather than `UserChapterStore`, which resolves
    /// to an empty anonymous scope and made this page look broken.
    private var journals: [PrototypeChapter] {
        contentMode.showsSampleContent ? sampleJournals : DailyJournalData.allChapters()
    }

    private var trimmedNewJournalName: String {
        newJournalName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(journals) { journal in
                        Button {
                            if pendingJournalTitles.contains(journal.title) {
                                pendingJournalTitles.remove(journal.title)
                            } else {
                                pendingJournalTitles.insert(journal.title)
                            }
                        } label: {
                            journalRow(journal)
                        }
                        .buttonStyle(.plain)

                        if journal.id != journals.last?.id {
                            Divider()
                                .padding(.leading, 90)
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
            }
        }
        .background(Color.homePageBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyPurple)
            }
            .hideSharedBackgroundIfAvailable()

            ToolbarItem(placement: .principal) {
                Text("Add to Journal")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    onSaveSelection(pendingJournalTitles)
                    selectedJournalTitles = pendingJournalTitles
                    selectedJournalTitle = pendingJournalTitles.sorted().first
                    dismiss()
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(canUseDoneButton ? Color.storyPurple : Color.storyGray.opacity(0.42))
                .disabled(!canUseDoneButton)
            }
            .hideSharedBackgroundIfAvailable()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            createNewJournalButton
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .background(Color.homePageBackground)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.homeBorder.opacity(0.7))
                        .frame(height: 0.5)
                }
        }
        .alert("Create New Journal", isPresented: $isCreateJournalAlertPresented) {
            TextField("Journal name", text: $newJournalName)
                .textInputAutocapitalization(.words)

            Button("Cancel", role: .cancel) {
                newJournalName = ""
            }

            Button("Create") {
                createJournalAndAddEntry()
            }
            .disabled(trimmedNewJournalName.isEmpty)
        } message: {
            Text("Name the journal where this entry should be added.")
        }
        .onAppear {
            pendingJournalTitles = selectedJournalTitles
            if let selectedJournalTitle {
                pendingJournalTitles.insert(selectedJournalTitle)
            }
            refreshSampleJournalsIfNeeded()
        }
    }

    private var canUseDoneButton: Bool {
        pendingJournalTitles != selectedJournalTitles
    }

    private func journalRow(_ journal: PrototypeChapter) -> some View {
        let isSelected = pendingJournalTitles.contains(journal.title)

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? Color.storyPurple : Color.homeBorder)
                .frame(width: 22, height: 22)

            AddEntryJournalNotebookCover(
                journal: journal,
                isSelected: isSelected
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text(journal.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyInk)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 8)

            Text("\(journal.entries.count) \(journal.entries.count == 1 ? "entry" : "entries")")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .frame(height: 58)
        .contentShape(Rectangle())
        .accessibilityLabel(journal.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var createNewJournalButton: some View {
        Button {
            guard signInGate.requireAccount(for: .createJournal, retry: { isCreateJournalAlertPresented = true }) else {
                return
            }

            isCreateJournalAlertPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))

                Text("Create New Journal")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Color.storyPurple)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createJournalAndAddEntry() {
        guard !trimmedNewJournalName.isEmpty else {
            return
        }

        guard contentMode.canPersistUserContent || contentMode.isSampleAuthoring else {
            signInGate.requireAccount(for: .createJournal)
            return
        }

        if authoringMode.isSampleStudio {
            createSampleJournalAndAddEntry()
            return
        }

        let journal = PrototypeChapter(
            title: trimmedNewJournalName,
            subtitle: "Personal journal",
            color: Color.storyPurple,
            symbol: "book.closed.fill",
            coverImageName: nil,
            kind: .journal,
            isFavorite: false,
            entries: []
        )

        UserChapterStore.add(journal)
        selectedJournalTitle = journal.title
        selectedJournalTitles.insert(journal.title)
        pendingJournalTitles.insert(journal.title)
        newJournalName = ""
        onSelect(journal.title)
        dismiss()
    }

    private func createSampleJournalAndAddEntry() {
        let title = trimmedNewJournalName
        Task {
            do {
                try await SupabaseSampleStoryService().createSampleJournal(title: title)
                let journals = try await SupabaseSampleStoryService().loadAuthoringJournals()
                let chapters = journals.map { $0.createEntryPrototypeChapter() }
                await MainActor.run {
                    sampleJournals = chapters
                    selectedJournalTitle = title
                    selectedJournalTitles.insert(title)
                    pendingJournalTitles.insert(title)
                    newJournalName = ""
                    onSelect(title)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    newJournalName = ""
                }
            }
        }
    }

    private func refreshSampleJournalsIfNeeded() {
        guard contentMode.showsSampleContent else {
            return
        }

        let loadsAuthoringPack = contentMode.isSampleAuthoring

        Task {
            do {
                // Authoring edits the pack it is signed in to administer; browsing reads the public
                // one everybody sees.
                let journals = loadsAuthoringPack
                    ? try await SupabaseSampleStoryService().loadAuthoringJournals()
                    : try await SupabaseSampleStoryService().loadActivePack().journals
                let chapters = journals.map { $0.createEntryPrototypeChapter() }
                await MainActor.run {
                    sampleJournals = chapters
                }
            } catch {
                await MainActor.run {
                    sampleJournals = []
                }
            }
        }
    }

}

private struct AddEntryJournalNotebookCover: View {
    let journal: PrototypeChapter
    var isSelected = false

    private var storedCoverImage: UIImage? {
        guard journal.remoteCover == nil else {
            return nil
        }

        return CreateJournalCoverImageStore.image(for: journal)
    }

    private var remoteCoverURL: URL? {
        journal.remoteCover?.thumbnailNSURL ?? journal.remoteCover?.imageNSURL
    }

    var body: some View {
        ZStack {
            notebookShape
                .fill(journal.color)

            coverContent
                .frame(width: 36, height: 48)
                .clipped()

            HStack {
                Rectangle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 5)

                Spacer()

                Rectangle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 1.5)
            }

            HStack {
                Rectangle()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: 1)
                    .padding(.leading, 3)

                Spacer()
            }
        }
        .frame(width: 36, height: 48)
        .clipShape(notebookShape)
        .overlay(
            notebookShape
                .stroke(
                    isSelected ? Color.storyPurple : Color.black.opacity(0.16),
                    lineWidth: isSelected ? 1.4 : 0.8
                )
        )
    }

    private var notebookShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 3,
            bottomLeadingRadius: 3,
            bottomTrailingRadius: 5,
            topTrailingRadius: 5,
            style: .continuous
        )
    }

    @ViewBuilder
    private var coverContent: some View {
        if let storedCoverImage {
            Image(uiImage: storedCoverImage)
                .resizable()
                .scaledToFill()
                .overlay(Color.black.opacity(0.12))
        } else if let remoteCoverURL {
            AsyncImage(url: remoteCoverURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .overlay(Color.black.opacity(0.12))
                }
            }
        } else if let coverImageName = journal.coverImageName {
            Image(coverImageName)
                .resizable()
                .scaledToFill()
                .overlay(Color.black.opacity(0.12))
        }
    }
}

private struct AddToJournalSheet: View {
    @Binding var selectedJournalTitle: String?

    let contentMode: StorytopiaContentMode
    let onSelect: (String) -> Void

    @EnvironmentObject private var signInGate: SignInGate
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: AddToJournalTab = .existing
    @State private var searchText = ""
    @State private var newJournalName = ""
    @State private var selectedSymbol = "book.closed.fill"
    @State private var sampleJournals: [PrototypeChapter] = []

    private let coverSymbols = [
        "book.closed.fill",
        "sun.max.fill",
        "moon.stars.fill",
        "heart.fill",
        "leaf.fill",
        "building.2.fill"
    ]

    private var authoringMode: CreateEntryAuthoringMode {
        contentMode.authoringMode
    }

    private var journals: [PrototypeChapter] {
        contentMode.showsSampleContent ? sampleJournals : DailyJournalData.allChapters()
    }

    private var filteredJournals: [PrototypeChapter] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return journals
        }

        return journals.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedNewJournalName: String {
        newJournalName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar

            Group {
                switch selectedTab {
                case .existing:
                    existingJournalList
                case .new:
                    newJournalForm
                }
            }
        }
        .padding(.top, 18)
        .background(Color.homePageBackground)
        .onAppear {
            refreshSampleJournalsIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.storyPurple)

            Spacer()

            Text("Add to Journal")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            Color.clear
                .frame(width: 52, height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AddToJournalTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 9) {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selectedTab == tab ? Color.storyPurple : Color.storyInk.opacity(0.72))

                        Capsule()
                            .fill(selectedTab == tab ? Color.storyPurple : Color.clear)
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var existingJournalList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                TextField("Search journals...", text: $searchText)
                    .font(.system(size: 13, weight: .medium))
                    .textInputAutocapitalization(.words)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filteredJournals) { journal in
                        Button {
                            onSelect(journal.title)
                        } label: {
                            existingJournalRow(journal)
                        }
                        .buttonStyle(.plain)

                        if journal.id != filteredJournals.last?.id {
                            Divider()
                                .padding(.leading, 62)
                        }
                    }
                }
            }

            Button {
                if let selectedJournalTitle {
                    onSelect(selectedJournalTitle)
                }
            } label: {
                Text("Continue")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(
                            colors: [Color.storyPurple.opacity(0.94), Color.storyPurple],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedJournalTitle == nil)
            .opacity(selectedJournalTitle == nil ? 0.48 : 1)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
    }

    private func existingJournalRow(_ journal: PrototypeChapter) -> some View {
        HStack(spacing: 12) {
            AddEntryJournalNotebookCover(
                journal: journal,
                isSelected: selectedJournalTitle == journal.title
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(journal.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text("\(journal.entries.count) \(journal.entries.count == 1 ? "entry" : "entries")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
            }

            Spacer()

            Image(systemName: selectedJournalTitle == journal.title ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(selectedJournalTitle == journal.title ? Color.storyPurple : Color.storyBorder)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var newJournalForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 9) {
                Image(systemName: "book.closed.badge.plus")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.storyPurple)
                    .frame(width: 72, height: 72)
                    .background(Color.storyPurple.opacity(0.11), in: Circle())

                Text("Create New Journal")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Text("Give your journal a name and cover to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 8) {
                Text("Journal Name")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                TextField("e.g., My Thoughts, Adventures...", text: $newJournalName)
                    .font(.system(size: 14, weight: .medium))
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.storyPurple.opacity(0.52), lineWidth: 1.2)
                    )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Cover")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                HStack(spacing: 10) {
                    ForEach(coverSymbols, id: \.self) { symbol in
                        Button {
                            selectedSymbol = symbol
                        } label: {
                            AddToJournalCoverIcon(
                                symbol: symbol,
                                color: Color.storyPurple,
                                isSelected: selectedSymbol == symbol
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                createJournal()
            } label: {
                Text("Create Journal")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(
                            colors: [Color.storyPurple.opacity(0.94), Color.storyPurple],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(trimmedNewJournalName.isEmpty)
            .opacity(trimmedNewJournalName.isEmpty ? 0.48 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private func createJournal() {
        guard !trimmedNewJournalName.isEmpty else {
            return
        }

        guard contentMode.canPersistUserContent || contentMode.isSampleAuthoring else {
            signInGate.requireAccount(for: .createJournal)
            return
        }

        if authoringMode.isSampleStudio {
            createSampleJournal()
            return
        }

        let journal = PrototypeChapter(
            title: trimmedNewJournalName,
            subtitle: "Personal journal",
            color: Color.storyPurple,
            symbol: selectedSymbol,
            coverImageName: nil,
            kind: .journal,
            isFavorite: false,
            entries: []
        )

        UserChapterStore.add(journal)
        onSelect(journal.title)
    }

    private func createSampleJournal() {
        let title = trimmedNewJournalName
        Task {
            do {
                try await SupabaseSampleStoryService().createSampleJournal(title: title)
                let journals = try await SupabaseSampleStoryService().loadAuthoringJournals()
                let chapters = journals.map { $0.createEntryPrototypeChapter() }
                await MainActor.run {
                    sampleJournals = chapters
                    selectedJournalTitle = title
                    newJournalName = ""
                    onSelect(title)
                }
            } catch {
                await MainActor.run {
                    newJournalName = ""
                }
            }
        }
    }

    private func refreshSampleJournalsIfNeeded() {
        guard contentMode.showsSampleContent else {
            return
        }

        let loadsAuthoringPack = contentMode.isSampleAuthoring

        Task {
            do {
                let journals = loadsAuthoringPack
                    ? try await SupabaseSampleStoryService().loadAuthoringJournals()
                    : try await SupabaseSampleStoryService().loadActivePack().journals
                let chapters = journals.map { $0.createEntryPrototypeChapter() }
                await MainActor.run {
                    sampleJournals = chapters
                }
            } catch {
                await MainActor.run {
                    sampleJournals = []
                }
            }
        }
    }

}

private struct PhotoSourceSheet: View {
    var title: String = "Add Photo"
    var dismissesBeforeSelection = true
    let showsCamera: Bool
    let onCamera: () -> Void
    let onPhotoLibrary: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.storyPurple)

                Spacer()

                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Color.clear
                    .frame(width: 52, height: 20)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)

            HStack(spacing: 12) {
                if showsCamera {
                    photoSourceOptionButton(title: "Camera", systemName: "camera.fill") {
                        onCamera()
                    }
                }

                photoSourceOptionButton(title: "Photo Library", systemName: "photo.on.rectangle.angled") {
                    onPhotoLibrary()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.homePageBackground)
    }

    private func photoSourceOptionButton(
        title: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if dismissesBeforeSelection {
                dismiss()
                DispatchQueue.main.async {
                    action()
                }
            } else {
                action()
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.storyPurple)
                    .frame(height: 28)

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.86))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct AddToJournalCoverIcon: View {
    let symbol: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(isSelected ? 0.94 : 0.28),
                            color.opacity(isSelected ? 0.76 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 42, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? color.opacity(0.65) : color.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)

            Rectangle()
                .fill(Color.white.opacity(isSelected ? 0.34 : 0.56))
                .frame(width: 4, height: 48)
                .padding(.leading, 5)

            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSelected ? .white : color)
                .frame(width: 42, height: 54)
        }
        .frame(width: 48, height: 58)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white, color)
                    .background(Color.white, in: Circle())
                    .offset(x: -1, y: -1)
            }
        }
    }
}

private struct SelectedJournalCoverThumbnail: View {
    let journal: PrototypeChapter

    private var storedCoverImage: UIImage? {
        guard journal.remoteCover == nil else {
            return nil
        }

        return CreateJournalCoverImageStore.image(for: journal)
    }

    private var remoteCoverURL: URL? {
        journal.remoteCover?.thumbnailNSURL ?? journal.remoteCover?.imageNSURL
    }

    var body: some View {
        ZStack(alignment: .leading) {
            coverContent
                .frame(width: 34, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Rectangle()
                .fill(Color.white.opacity(hasImageCover ? 0.28 : 0.36))
                .frame(width: 3, height: 38)
                .padding(.leading, 4)
        }
        .frame(width: 34, height: 42)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.storyInk.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.12), radius: 4, y: 2)
    }

    @ViewBuilder
    private var coverContent: some View {
        if let storedCoverImage {
            Image(uiImage: storedCoverImage)
                .resizable()
                .scaledToFill()
        } else if let remoteCoverURL {
            AsyncImage(url: remoteCoverURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    fallbackCover
                }
            }
        } else if let coverImageName = journal.coverImageName {
            Image(coverImageName)
                .resizable()
                .scaledToFill()
        } else {
            fallbackCover
        }
    }

    private var fallbackCover: some View {
        ZStack {
            LinearGradient(
                colors: [journal.color.opacity(0.92), journal.color.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: journal.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    private var hasImageCover: Bool {
        storedCoverImage != nil || remoteCoverURL != nil || journal.coverImageName != nil
    }
}

private enum CreateJournalCoverImageStore {
    private static let folderName = "JournalCovers"

    static func image(for journal: PrototypeChapter) -> UIImage? {
        image(for: journal.coverStorageKey) ?? image(for: journal.title)
    }

    static func image(for title: String) -> UIImage? {
        guard
            let data = try? Data(contentsOf: fileURL(for: title)),
            let image = UIImage(data: data)
        else {
            return nil
        }

        return image
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func fileURL(for title: String) -> URL {
        directoryURL.appendingPathComponent(fileName(for: title))
    }

    private static func fileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return "\(sanitized.isEmpty ? "journal" : sanitized).jpg"
    }
}

private enum AddToJournalTab: CaseIterable, Identifiable {
    case existing
    case new

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .existing:
            return "Existing"
        case .new:
            return "New Journal"
        }
    }
}

private enum KeyboardCornerRadiusRemover {
    static func removeKeyboardCornerRadius() {
        DispatchQueue.main.async {
            removeKeyboardCornerRadius(in: UIApplication.shared.connectedScenes)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            removeKeyboardCornerRadius(in: UIApplication.shared.connectedScenes)
        }
    }

    private static func removeKeyboardCornerRadius(in scenes: Set<UIScene>) {
        scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { window in
                removeKeyboardCornerRadius(from: window)
            }
    }

    private static func removeKeyboardCornerRadius(from view: UIView) {
        let className = NSStringFromClass(type(of: view))

        if className.contains("UIInputSet") || className.contains("UIKeyboard") {
            view.layer.cornerRadius = 0
            view.layer.maskedCorners = []
        }

        view.subviews.forEach(removeKeyboardCornerRadius(from:))
    }
}

struct ExpandedEntryEditor: View {
    @Binding var entryText: String
    var entryRichText: Binding<NotebookRichTextDocument?>? = nil
    @Binding var storyTitle: String
    var textStyle: NotebookTextStyle = .default
    var paperColor: Color = .homePageBackground
    private var paperImageName: String?
    private var showsRuledLines = true
    private var showsNotebookChrome = true
    private var leadingContentPadding = NotebookMetrics.marginLeading
    private var leadingTextPadding = NotebookMetrics.textLeadingInset

    @FocusState private var isTitleFocused: Bool
    @State private var editorFocusRequestID = 0
    @State private var dictationTranscriptRequest: NotebookDictationTranscriptRequest?
    @State private var dictationTranscriptRequestID = 0
    @State private var speechRecognitionAlertMessage: String?
    @StateObject private var speechTranscriber = EntrySpeechTranscriber()

    init(
        entryText: Binding<String>,
        entryRichText: Binding<NotebookRichTextDocument?>? = nil,
        storyTitle: Binding<String>,
        textStyle: NotebookTextStyle = .default,
        paperColor: Color = .homePageBackground
    ) {
        self._entryText = entryText
        self.entryRichText = entryRichText
        self._storyTitle = storyTitle
        self.textStyle = textStyle
        self.paperColor = paperColor
    }

    fileprivate init(
        entryText: Binding<String>,
        entryRichText: Binding<NotebookRichTextDocument?>? = nil,
        storyTitle: Binding<String>,
        textStyle: NotebookTextStyle = .default,
        paperColor: Color = .homePageBackground,
        paperStyle: CreatePaperStyleChoice
    ) {
        self._entryText = entryText
        self.entryRichText = entryRichText
        self._storyTitle = storyTitle
        self.textStyle = textStyle
        self.paperColor = paperColor
        self.paperImageName = paperStyle.backgroundImageName
        self.showsRuledLines = paperStyle.showsRuledLines
        self.showsNotebookChrome = paperStyle.showsNotebookChrome
        self.leadingContentPadding = paperStyle.leadingContentPadding
        self.leadingTextPadding = paperStyle.leadingTextPadding
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    NotebookPaperBackground(
                        paperColor: paperColor,
                        paperImageName: paperImageName,
                        showsPaperWash: false,
                        showsRuledLines: showsRuledLines,
                        showsNotebookChrome: showsNotebookChrome,
                        firstRuledLineY: NotebookMetrics.firstNotebookRuleY
                    )
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: .infinity)

                    NotebookEditorContent(
                        storyTitle: $storyTitle,
                        entryText: $entryText,
                        entryRichText: entryRichText,
                        isTitleFocused: $isTitleFocused,
                        editorFocusRequestID: editorFocusRequestID,
                        isDictating: speechTranscriber.state.isListening,
                        dictationTranscriptRequest: dictationTranscriptRequest,
                        bodyPlaceholder: "Start writing...",
                        scrollsInternally: false,
                        pageHeight: proxy.size.height,
                        textStyle: textStyle,
                        showsTitleRule: showsNotebookChrome,
                        leadingContentPadding: leadingContentPadding,
                        leadingTextPadding: leadingTextPadding,
                        usesTexturedPaperEffect: paperImageName != nil,
                        onBodyTap: {
                            isTitleFocused = false
                            editorFocusRequestID += 1
                        },
                        onTitleSubmit: {
                            editorFocusRequestID += 1
                        }
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(paperColor)
            .notebookPageChrome()
            .overlay(alignment: .bottomTrailing) {
                expandedEditorSpeechMicButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 24)
            }
        }
        .background(paperColor)
        .navigationTitle("Write")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(paperColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()

                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .font(.system(size: 14, weight: .bold))
            }
        }
        .onDisappear {
            speechTranscriber.stop()
        }
        .onChange(of: speechTranscriber.state) { state in
            if case .unavailable(let message) = state {
                speechRecognitionAlertMessage = message
            }
        }
        .alert(
            "Dictation Unavailable",
            isPresented: Binding(
                get: { speechRecognitionAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        speechRecognitionAlertMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                speechRecognitionAlertMessage = nil
            }
        } message: {
            Text(speechRecognitionAlertMessage ?? "")
        }
    }

    private var expandedEditorSpeechMicButton: some View {
        EntrySpeechMicButton(isListening: speechTranscriber.state.isListening) {
            toggleSpeechTranscription()
        }
    }

    private func toggleSpeechTranscription() {
        if !speechTranscriber.state.isListening {
            isTitleFocused = false
            editorFocusRequestID += 1
        }

        speechTranscriber.toggle { transcript in
            dictationTranscriptRequestID += 1
            dictationTranscriptRequest = NotebookDictationTranscriptRequest(
                id: dictationTranscriptRequestID,
                transcript: transcript
            )
        }
    }
}

struct NotebookPaperBackground: View {
    var paperColor = Color.homePageBackground
    var paperImageName: String?
    var showsPaperWash = true
    var showsRuledLines = true
    var showsNotebookChrome = true
    var firstRuledLineY: CGFloat = 135

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let paperImageName {
                    Image(paperImageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    paperColor
                }

                if showsPaperWash {
                    LinearGradient(
                        colors: [
                            .white.opacity(0.34),
                            .clear,
                            Color.storyGold.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                if showsRuledLines {
                    ruledLines(in: proxy.size)
                }

                if showsNotebookChrome {
                    Rectangle()
                        .fill(Color.storyRose.opacity(0.52))
                        .frame(width: 1.2)
                        .padding(.leading, NotebookMetrics.marginLeading)

                    pageHoles
                        .padding(.leading, 10)
                        .padding(.top, 92)
                }
            }
        }
    }

    private func ruledLines(in size: CGSize) -> some View {
        Path { path in
            var y = firstRuledLineY
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += NotebookMetrics.ruleSpacing
            }
        }
        .stroke(NotebookMetrics.ruleColor, lineWidth: 1)
    }

    private var pageHoles: some View {
        VStack(spacing: 96) {
            ForEach(0..<5, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(0.82))
                    .frame(width: 13, height: 13)
                    .overlay(
                        Circle()
                            .stroke(Color.storyBorder.opacity(0.32), lineWidth: 1)
                    )
            }
        }
    }
}

private struct CreateFormattingSheet: View {
    @State private var selectedTab: CreateFormattingTab
    @Binding var selectedFont: CreateFontChoice
    @Binding var selectedPaperStyle: CreatePaperStyleChoice
    @Binding var selectedTextColorIndex: Int
    @Binding var selectedPaperColorIndex: Int
    @Binding var previewTextSize: Double
    let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        initialTab: CreateFormattingTab,
        selectedFont: Binding<CreateFontChoice>,
        selectedPaperStyle: Binding<CreatePaperStyleChoice>,
        selectedTextColorIndex: Binding<Int>,
        selectedPaperColorIndex: Binding<Int>,
        previewTextSize: Binding<Double>,
        onClose: (() -> Void)? = nil
    ) {
        _selectedTab = State(initialValue: initialTab)
        _selectedFont = selectedFont
        _selectedPaperStyle = selectedPaperStyle
        _selectedTextColorIndex = selectedTextColorIndex
        _selectedPaperColorIndex = selectedPaperColorIndex
        _previewTextSize = previewTextSize
        self.onClose = onClose
    }

    private var selectedTextColor: Color {
        CreateFormattingPalette.textColors[
            min(max(selectedTextColorIndex, 0), CreateFormattingPalette.textColors.count - 1)
        ].color
    }

    private var selectedPaperColor: Color {
        CreateFormattingPalette.paperColors[
            min(max(selectedPaperColorIndex, 0), CreateFormattingPalette.paperColors.count - 1)
        ]
    }

    private var selectedPreviewFontSize: CGFloat {
        CreateEntryTextSize.fontSize(for: previewTextSize)
    }

    private var snappingPreviewTextSize: Binding<Double> {
        Binding(
            get: { previewTextSize },
            set: { previewTextSize = CreateEntryTextSize.snappedSliderValue(for: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()

                Button {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.58))
                        .frame(width: 44, height: 44)
                        .background(Color.homeInputGray.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close formatting options")
            }
            .overlay {
                HStack(spacing: 7) {
                    Image(systemName: selectedTab.sheetSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.storyPurple)

                    Text(selectedTab.sheetTitle)
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(Color.storyInk)
                }
            }

            ScrollView(showsIndicators: false) {
                Group {
                    switch selectedTab {
                    case .fontStyle:
                        fontStyleContent
                    case .paperStyle:
                        paperStyleContent
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .background(Color.white)
    }

    private var fontStyleContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            fontSizeControl

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                spacing: 12
            ) {
                ForEach(CreateFontChoice.allCases) { font in
                    Button {
                        selectedFont = font
                    } label: {
                        CreateFontOptionCard(font: font, isSelected: selectedFont == font)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(font.title)
                    .accessibilityAddTraits(selectedFont == font ? .isSelected : [])
                }
            }
            .padding(.top, 1)
        }
    }

    private var fontSizeControl: some View {
        VStack(alignment: .leading, spacing: 12) {
            sheetSectionTitle("Font Size")

            HStack(spacing: 14) {
                Text("A")
                    .font(selectedFont.swiftUIFont(size: 17, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.68))
                    .frame(width: 18, alignment: .center)

                ZStack {
                    Slider(value: snappingPreviewTextSize, in: 0...1)
                        .tint(Color.storyPurple)
                        .accessibilityLabel("Font Size")

                    Rectangle()
                        .fill(Color.storyPurple.opacity(0.52))
                        .frame(width: 2, height: 18)
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                }

                Text("A")
                    .font(selectedFont.swiftUIFont(size: 31, weight: .bold))
                    .foregroundStyle(Color.storyInk.opacity(0.82))
                    .frame(width: 28, alignment: .center)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(Color.homeInputGray.opacity(0.56), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.46), lineWidth: 1)
            )
        }
    }

    private var formattingTabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(CreateFormattingTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.sheetSymbol)
                            .font(.system(size: 13, weight: .semibold))

                        Text(tab.sheetTitle)
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.storyInk : Color.storyInk.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        Group {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: Color.storyInk.opacity(0.08), radius: 2, y: 1)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.sheetTitle)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.homeInputGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var paperStyleContent: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            alignment: .center,
            spacing: 24
        ) {
            ForEach(CreatePaperStyleChoice.allCases) { paperStyle in
                Button {
                    selectedPaperStyle = paperStyle
                } label: {
                    CreatePaperStyleOption(
                        style: paperStyle,
                        paperColor: CreateFormattingPalette.paperColors[selectedPaperColorIndex],
                        isSelected: selectedPaperStyle == paperStyle
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var formattingPreview: some View {
        Text("The little story found its voice on the page, one careful sentence at a time.")
            .font(selectedFont.swiftUIBodyFont(size: selectedPreviewFontSize))
            .foregroundStyle(selectedTextColor)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .padding(16)
            .background {
                CreatePaperPreview(style: selectedPaperStyle, paperColor: selectedPaperColor, ruledLineCount: 5)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.56), lineWidth: 1)
            )
    }

    private func sheetSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.storyInk.opacity(0.92))
    }
}

private struct CreateFontOptionCard: View {
    let font: CreateFontChoice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(font.title)
                .font(font.swiftUIBodyFont(size: 16))
                .foregroundStyle(Color.storyInk)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.storyPurple.opacity(0.12) : Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.storyPurple : Color.storyBorder.opacity(0.46), lineWidth: isSelected ? 1.8 : 1)
        )
    }
}

private struct CreatePaperStyleOption: View {
    let style: CreatePaperStyleChoice
    let paperColor: Color
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            CreatePaperPreview(style: style, paperColor: paperColor)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.storyPurple : Color.storyBorder.opacity(0.45), lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.storyPurple, in: Circle())
                            .offset(x: 5, y: 5)
                    }
                }

            Text(style.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CreatePaperPreview: View {
    let style: CreatePaperStyleChoice
    let paperColor: Color
    var ruledLineCount = 7

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                paperColor

                switch style {
                case .collegeRuled:
                    ruledLines(count: ruledLineCount, in: proxy.size)
                    marginLine(in: proxy.size)
                case .blank:
                    EmptyView()
                case .watercolorPaper, .cottonPaper, .recycledPaper:
                    if let backgroundImageName = style.backgroundImageName {
                        Image(backgroundImageName)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                }
            }
        }
    }

    private func ruledLines(count: Int, in size: CGSize) -> some View {
        ForEach(1...count, id: \.self) { index in
            Rectangle()
                .fill(Color.blue.opacity(0.16))
                .frame(height: 1)
                .offset(y: CGFloat(index) * size.height / CGFloat(count + 1))
        }
    }

    private func marginLine(in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.storyRose.opacity(0.6))
            .frame(width: 1)
            .offset(x: size.width * 0.10)
    }

}

private struct CreateColorSwatchRow: View {
    let colors: [Color]
    @Binding var selectedIndex: Int
    let selectedCheckColor: Color
    let emphasizedBorderIndex: Int?
    let showsMoreButton: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        selectedIndex = index
                    } label: {
                        Circle()
                            .fill(colors[index])
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle()
                                    .stroke(
                                        emphasizedBorderIndex == index ? Color.storyInk.opacity(0.26) : Color.storyBorder.opacity(0.34),
                                        lineWidth: emphasizedBorderIndex == index ? 1.3 : 1
                                    )
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.86), lineWidth: selectedIndex == index ? 6 : 0)
                            )
                            .overlay {
                                if selectedIndex == index {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(selectedCheckColor)
                                }
                            }
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                if showsMoreButton {
                    Button {
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.storyInk.opacity(0.58))
                            .frame(width: 50, height: 40)
                            .background(Color.homeInputGray.opacity(0.86), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More colors")
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct StoryboardPhotoStripThumbnail: View {
    let image: UIImage
    var size: CGFloat = 56
    var bottomPadding: CGFloat = 12
    var overflow: CGFloat = 10
    let removeAction: () -> Void
    let tapAction: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
                .frame(width: size, height: size + bottomPadding)
                .shadow(color: .black.opacity(0.13), radius: 5, x: 0, y: 3)
                .padding(.top, overflow)
                .padding(.trailing, overflow)

            VStack(spacing: 0) {
                Button {
                    tapAction()
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size - 10, height: size - 10)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.storyInk.opacity(0.45), lineWidth: 0.8)
                        )
                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View reference photo")
                .padding(.top, 5)

                Spacer(minLength: 0)
            }
            .frame(width: size, height: size + bottomPadding)
            .padding(.top, overflow)
            .padding(.trailing, overflow)

            Button {
                removeAction()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.58), in: Circle())
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove reference photo")
        }
        .frame(width: size + overflow, height: size + bottomPadding + overflow)
        .overlay(alignment: .top) {
            StoryPhotoTape(width: 34, height: 11, rotation: -2)
                .offset(x: -(overflow / 2), y: overflow - 4.5)
        }
    }
}

struct CharacterStripThumbnail: View {
    let character: EntryCharacter
    let tapAction: () -> Void
    let removeAction: () -> Void

    private let imageSize: CGFloat = 58
    private let badgeOverflow: CGFloat = 10

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Button(action: tapAction) {
                    Image(uiImage: character.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: imageSize, height: imageSize)
                        .clipped()
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(character.role == .mainCharacter ? Color.storyPurple.opacity(0.76) : Color.storyInk.opacity(0.32), lineWidth: character.role == .mainCharacter ? 1.5 : 0.8)
                        )
                        .shadow(color: .black.opacity(0.11), radius: 5, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(character.name)")

                Button(action: removeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.58), in: Circle())
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(character.name)")
                .offset(x: badgeOverflow, y: -badgeOverflow)

                if character.role == .mainCharacter {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.storyPurple.opacity(0.95), in: Circle())
                        .offset(x: -39, y: -badgeOverflow)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: imageSize + (badgeOverflow * 2), height: imageSize + badgeOverflow)
            .padding(.top, badgeOverflow)

            Text(character.name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.storyInk.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 66)
        }
        .frame(width: 68, height: 88, alignment: .top)
    }
}

private struct EntryDetailsCharactersCard: View {
    let characters: [EntryCharacter]
    let onAddCharacter: () -> Void
    let onMyCharacters: () -> Void
    let onEditCharacter: (EntryCharacter) -> Void
    let onDeleteCharacter: (EntryCharacter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            Text("Use this to add character references, and single out people from group photos. If your story has more than one character, reference them here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            characterRow
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.storyBorder.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 18, height: 18)

            Text("Characters")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer(minLength: 0)

            Button(action: onMyCharacters) {
                Text("My Characters")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("My Characters")
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var characterRow: some View {
        if characters.isEmpty {
            Button(action: onAddCharacter) {
                addCharacterTileLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                    .frame(height: 92, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add character")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(characters) { character in
                        CharacterStripThumbnail(
                            character: character,
                            tapAction: {
                                onEditCharacter(character)
                            },
                            removeAction: {
                                onDeleteCharacter(character)
                            }
                        )
                    }

                    addCharacterTile
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .frame(height: 92)
        }
    }

    private var addCharacterTile: some View {
        Button(action: onAddCharacter) {
            addCharacterTileLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add character")
        .frame(height: 76)
    }

    private var addCharacterTileLabel: some View {
        HStack(spacing: 8) {
            StoryboardPhotoStripAddButton(
                systemName: characters.isEmpty ? "person.crop.circle.badge.plus" : "plus",
                iconColor: characters.isEmpty ? Color.storyPurple : Color.storyInk.opacity(0.82),
                size: 58,
                iconWeight: characters.isEmpty ? .semibold : .light,
                shape: .circle
            )

            if characters.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Character")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyPurple)

                    Text("Choose a portrait")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.storyInk.opacity(0.66))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }
        }
    }
}

private struct ReusableCharacterLibraryRow: View {
    let character: EntryCharacter
    let canAdd: Bool
    let isDeleting: Bool
    let isDragging: Bool
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let dragProvider: () -> NSItemProvider

    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            dragHandle

            Button(action: onEdit) {
                Image(uiImage: character.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.storyPurple.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(character.name)")

            VStack(alignment: .leading, spacing: 6) {
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(character.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.storyInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Text(character.role.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.storyInk.opacity(0.58))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(character.name)")

                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("Edit Character")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.storyPurple)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(character.name)")
            }

            HStack(spacing: 10) {
                if canAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.storyPurple)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(character.name) to this entry")
                } else {
                    Text("Added")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.48))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: 36)
                }

                if isDeleting {
                    ProgressView()
                        .tint(Color.storyPurple)
                        .frame(width: 28, height: 28)
                } else {
                    Button {
                        isConfirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.red.opacity(0.82))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(character.name)")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 76)
        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isDragging ? Color.storyPurple.opacity(0.5) : Color.storyBorder.opacity(0.58), lineWidth: isDragging ? 1.5 : 1)
        )
        .opacity(isDeleting ? 0.64 : (isDragging ? 0.5 : 1))
        .disabled(isDeleting)
        .alert("Delete Character?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(character.name) from My Characters and deletes them from the cloud. This cannot be undone.")
        }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.storyInk.opacity(0.34))
            .frame(width: 22, height: 44)
            .contentShape(Rectangle())
            .onDrag(dragProvider)
            .accessibilityLabel("Reorder \(character.name)")
            .accessibilityHint("Drag to change the order of your characters.")
    }
}

/// Reorders the My Characters list as a dragged row passes over its neighbours.
private struct ReusableCharacterDropDelegate: DropDelegate {
    let character: EntryCharacter
    @Binding var characters: [EntryCharacter]
    @Binding var draggingCharacterID: UUID?
    let onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingCharacterID,
              draggingCharacterID != character.id,
              let fromIndex = characters.firstIndex(where: { $0.id == draggingCharacterID }),
              let toIndex = characters.firstIndex(where: { $0.id == character.id })
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            characters.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingCharacterID != nil else {
            return false
        }

        draggingCharacterID = nil
        onReorder()
        return true
    }
}

private struct ReusableCharactersSheet: View {
    @Binding var characters: [EntryCharacter]
    @Binding var draggingCharacterID: UUID?
    let attachedCharacterIDs: Set<UUID>
    let isLoading: Bool
    let errorMessage: String?
    let deletingCharacterID: UUID?
    let onSelect: (EntryCharacter) -> Void
    let onEdit: (EntryCharacter) -> Void
    let onDelete: (EntryCharacter) -> Void
    let onRefresh: () -> Void
    let onReorder: () -> Void
    let dragProvider: (EntryCharacter) -> NSItemProvider

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if characters.isEmpty && !isLoading {
                    emptyState
                } else {
                    characterList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.homePageBackground.ignoresSafeArea())
            .navigationTitle("My Characters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(Color.storyPurple)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundStyle(Color.storyPurple)
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh characters")
                }
            }
        }
    }

    private var characterList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if isLoading {
                    loadingRow
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Drag the handle to reorder. Tap Edit to update a saved character, tap + to add them to this entry, or delete them from My Characters.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(characters) { character in
                    ReusableCharacterLibraryRow(
                        character: character,
                        canAdd: canAdd(character),
                        isDeleting: deletingCharacterID == character.id,
                        isDragging: draggingCharacterID == character.id,
                        onAdd: {
                            onSelect(character)
                        },
                        onEdit: {
                            onEdit(character)
                        },
                        onDelete: {
                            onDelete(character)
                        },
                        dragProvider: {
                            dragProvider(character)
                        }
                    )
                    .onDrop(
                        of: [.text],
                        delegate: ReusableCharacterDropDelegate(
                            character: character,
                            characters: $characters,
                            draggingCharacterID: $draggingCharacterID,
                            onReorder: onReorder
                        )
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .onDrop(of: [.text], isTargeted: nil) { _ in
                guard draggingCharacterID != nil else {
                    return false
                }

                draggingCharacterID = nil
                onReorder()
                return true
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Color.storyPurple)

            Text("Loading characters")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.storyInk.opacity(0.68))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.storyPurple.opacity(0.9))

            Text("No saved characters yet")
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.86))
                    .multilineTextAlignment(.center)
            } else {
                Text("Characters you add to entries will appear here. You can edit or delete them anytime.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.storyInk.opacity(0.62))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 30)
    }

    private func canAdd(_ character: EntryCharacter) -> Bool {
        !attachedCharacterIDs.contains(character.id)
    }
}

private struct CharacterEditorSheet: View {
    private enum Step {
        case choosePhoto
        case crop
        case details
    }

    let editingCharacter: EntryCharacter?
    let initialPhotoSource: CharacterInitialPhotoSource?
    let deletesFromLibrary: Bool
    let onSave: (EntryCharacter) -> Void
    let onDelete: ((EntryCharacter) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var selectedCharacterPhotoItem: PhotosPickerItem?
    @State private var isShowingCharacterCamera = false
    @State private var isShowingCharacterPhotoLibrary = false
    @State private var cropSourceImage: UIImage?
    @State private var croppedImage: UIImage?
    @State private var name: String
    @State private var role: CharacterRole
    @State private var validationMessage: String?
    @State private var didPresentInitialPhotoSource = false
    @State private var isConfirmingDelete = false

    init(
        editingCharacter: EntryCharacter?,
        initialPhotoSource: CharacterInitialPhotoSource? = nil,
        deletesFromLibrary: Bool = false,
        onSave: @escaping (EntryCharacter) -> Void,
        onDelete: ((EntryCharacter) -> Void)?
    ) {
        self.editingCharacter = editingCharacter
        self.initialPhotoSource = initialPhotoSource
        self.deletesFromLibrary = deletesFromLibrary
        self.onSave = onSave
        self.onDelete = onDelete
        _step = State(initialValue: editingCharacter == nil ? .choosePhoto : .details)
        _selectedCharacterPhotoItem = State(initialValue: nil)
        _isShowingCharacterCamera = State(initialValue: false)
        _isShowingCharacterPhotoLibrary = State(initialValue: false)
        _cropSourceImage = State(initialValue: nil)
        _croppedImage = State(initialValue: editingCharacter?.image)
        _name = State(initialValue: editingCharacter?.name ?? "")
        _role = State(initialValue: editingCharacter?.role ?? .supportingCharacter)
        _isConfirmingDelete = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .choosePhoto:
                    choosePhotoContent
                case .crop:
                    cropContent
                case .details:
                    detailsContent
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.homePageBackground.ignoresSafeArea())
            .navigationTitle(editingCharacter == nil ? "Add Character" : "Edit Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(Color.storyPurple)
                }

                if editingCharacter != nil, onDelete != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .alert("Delete Character?", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    guard let editingCharacter, let onDelete else {
                        return
                    }
                    onDelete(editingCharacter)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let editingCharacter, deletesFromLibrary {
                    Text("This removes \(editingCharacter.name) from My Characters and deletes them from the cloud. This cannot be undone.")
                } else if let editingCharacter {
                    Text("This removes \(editingCharacter.name) from this entry.")
                } else {
                    Text("This permanently deletes this character.")
                }
            }
            .onChange(of: selectedCharacterPhotoItem) { item in
                guard let item else {
                    return
                }

                Task {
                    await loadCharacterPhoto(from: item)
                }
            }
            .photosPicker(
                isPresented: $isShowingCharacterPhotoLibrary,
                selection: $selectedCharacterPhotoItem,
                matching: .images
            )
            .sheet(isPresented: $isShowingCharacterCamera) {
                CameraPhotoPicker { image in
                    setCharacterCropSourceImage(image)
                }
                .ignoresSafeArea()
            }
            .onAppear {
                presentInitialPhotoSourceIfNeeded()
            }
        }
    }

    private func presentInitialPhotoSourceIfNeeded() {
        guard !didPresentInitialPhotoSource, editingCharacter == nil, let initialPhotoSource else {
            return
        }

        didPresentInitialPhotoSource = true
        DispatchQueue.main.async {
            switch initialPhotoSource {
            case .camera:
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    isShowingCharacterCamera = true
                } else {
                    isShowingCharacterPhotoLibrary = true
                }
            case .photoLibrary:
                isShowingCharacterPhotoLibrary = true
            }
        }
    }

    private var choosePhotoContent: some View {
        PhotoSourceSheet(
            title: "Add Character",
            dismissesBeforeSelection: false,
            showsCamera: UIImagePickerController.isSourceTypeAvailable(.camera),
            onCamera: {
                isShowingCharacterCamera = true
            },
            onPhotoLibrary: {
                isShowingCharacterPhotoLibrary = true
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var cropContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sheetHeader(title: "Frame Portrait", systemName: "person.crop.circle")

            if let cropSourceImage {
                CharacterCropEditor(image: cropSourceImage) { image in
                    croppedImage = image
                    validationMessage = nil
                    step = .details
                }
            }
        }
    }

    @MainActor
    private func loadCharacterPhoto(from item: PhotosPickerItem) async {
        defer {
            selectedCharacterPhotoItem = nil
        }

        guard
            let data = try? await item.loadTransferable(type: Data.self),
            let image = UIImage(data: data)
        else {
            validationMessage = "Could not load that photo."
            return
        }

        setCharacterCropSourceImage(image)
    }

    private func setCharacterCropSourceImage(_ image: UIImage) {
        cropSourceImage = image
        validationMessage = nil
        step = .crop
    }

    private var detailsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sheetHeader(title: "Character Details", systemName: "person.text.rectangle")

                if let croppedImage {
                    HStack(alignment: .center, spacing: 12) {
                        Image(uiImage: croppedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 94, height: 94)
                            .clipped()
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.storyPurple.opacity(0.28), lineWidth: 1)
                            )

                        Button {
                            step = .choosePhoto
                        } label: {
                            Label("Change Photo", systemImage: "camera")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.storyPurple)
                                .padding(.horizontal, 11)
                                .frame(height: 36)
                                .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(Color.storyPurple.opacity(0.2), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Name")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.58))

                    TextField("Character name", text: $name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.storyInk)
                        .tint(Color.storyPurple)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.storyBorder.opacity(0.66), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Role")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.storyInk.opacity(0.58))

                    VStack(spacing: 7) {
                        ForEach(CharacterRole.allCases) { option in
                            characterRoleButton(option)
                        }
                    }
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.88))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveCharacterButton
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Color.homePageBackground)
        }
    }

    private var saveCharacterButton: some View {
        Button {
            save()
        } label: {
            Text("Save Character")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func characterRoleButton(_ option: CharacterRole) -> some View {
        let isSelected = role == option

        return Button {
            role = option
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.storyPurple : Color.storyInk.opacity(0.38))
                    .frame(width: 20)

                Text(option.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.storyPurple : Color.storyInk.opacity(0.84))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            .background(
                isSelected ? Color.storyPurple.opacity(0.08) : Color.white.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.storyPurple.opacity(0.34) : Color.storyBorder.opacity(0.58), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sheetHeader(title: String, systemName: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Name is required."
            return
        }

        guard let croppedImage else {
            validationMessage = "Crop a character image first."
            return
        }

        let now = Date()
        let character = EntryCharacter(
            id: editingCharacter?.id ?? UUID(),
            name: trimmedName,
            role: role,
            sourcePhotoID: nil,
            image: croppedImage,
            createdAt: editingCharacter?.createdAt ?? now,
            updatedAt: now
        )
        onSave(character)
        dismiss()
    }
}

private struct CharacterCropEditor: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { proxy in
                let cropSize = min(proxy.size.width, 330)

                ZStack {
                    Color.storyInk.opacity(0.9)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cropSize, height: cropSize)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .clipped()

	                    Rectangle()
	                        .fill(Color.black.opacity(0.34))
	                        .mask {
	                            Rectangle()
	                                .overlay(
	                                    Circle()
	                                        .frame(width: cropSize, height: cropSize)
	                                        .blendMode(.destinationOut)
	                                )
	                        }
	                        .compositingGroup()
	                        .allowsHitTesting(false)

	                    Circle()
	                        .stroke(Color.white.opacity(0.95), lineWidth: 2)
	                        .frame(width: cropSize, height: cropSize)
	                        .allowsHitTesting(false)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = min(max(lastZoom * value, 1), 4)
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                        }
                )
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.storyBorder.opacity(0.72), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button {
                    offset = .zero
                    lastOffset = .zero
                    zoom = 1
                    lastZoom = 1
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.storyPurple)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    onCrop(renderCrop())
                } label: {
	                    Label("Use Portrait", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.storyPurple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func renderCrop() -> UIImage {
        let outputSize = CGSize(width: 768, height: 768)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: outputSize)).fill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: outputSize)).addClip()

            let baseScale = max(outputSize.width / image.size.width, outputSize.height / image.size.height)
            let drawSize = CGSize(
                width: image.size.width * baseScale * zoom,
                height: image.size.height * baseScale * zoom
            )
            let scaledOffset = CGSize(
                width: offset.width * (outputSize.width / 330),
                height: offset.height * (outputSize.height / 330)
            )
            let origin = CGPoint(
                x: (outputSize.width - drawSize.width) / 2 + scaledOffset.width,
                y: (outputSize.height - drawSize.height) / 2 + scaledOffset.height
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

struct StoryPhotoTape: View {
    let width: CGFloat
    let height: CGFloat
    let rotation: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color(red: 0.83, green: 0.76, blue: 0.62).opacity(0.72))
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
            )
            .shadow(color: Color.storyInk.opacity(0.11), radius: 1.5, x: 0, y: 1)
            .rotationEffect(.degrees(rotation))
            .allowsHitTesting(false)
    }
}

struct ReferencePhotoViewer: View {
    let image: UIImage
    let closeAction: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            ZoomableReferenceImageView(image: image)
                .ignoresSafeArea()

            Button {
                closeAction()
            } label: {
                ZStack {
                    Circle()
                        .fill(.gray.opacity(0.62))
                        .frame(width: 40, height: 40)

                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close photo viewer")
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

/// UILabel that expands its drawing bounds so script-font flourishes aren't clipped.
private struct NonClippingScriptText: UIViewRepresentable {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var color: UIColor
    var clipPadding: CGFloat = 24

    func makeUIView(context: Context) -> NonClippingScriptLabel {
        let label = NonClippingScriptLabel()
        label.backgroundColor = .clear
        label.textAlignment = .center
        label.numberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: NonClippingScriptLabel, context: Context) {
        label.text = text
        label.font = UIFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        label.textColor = color
        label.clipPadding = clipPadding
        label.invalidateIntrinsicContentSize()
    }
}

private final class NonClippingScriptLabel: UILabel {
    var clipPadding: CGFloat = 24 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        guard size.width < CGFloat.greatestFiniteMagnitude / 2,
              size.height < CGFloat.greatestFiniteMagnitude / 2 else {
            return size
        }
        return CGSize(
            width: size.width + clipPadding * 2,
            height: size.height + clipPadding * 2
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(
            CGSize(
                width: max(0, size.width - clipPadding * 2),
                height: max(0, size.height - clipPadding * 2)
            )
        )
        return CGSize(
            width: fitted.width + clipPadding * 2,
            height: fitted.height + clipPadding * 2
        )
    }

    override func drawText(in rect: CGRect) {
        let insets = UIEdgeInsets(
            top: clipPadding,
            left: clipPadding,
            bottom: clipPadding,
            right: clipPadding
        )
        super.drawText(in: rect.inset(by: insets))
    }

    override var alignmentRectInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: clipPadding,
            left: clipPadding,
            bottom: clipPadding,
            right: clipPadding
        )
    }
}

private struct ZoomableReferenceImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let doubleTapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapRecognizer.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapRecognizer)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scrollView.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else {
                return
            }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let tapPoint = recognizer.location(in: imageView)
            let targetScale = min(scrollView.maximumZoomScale, 2.35)
            let zoomSize = CGSize(
                width: scrollView.bounds.width / targetScale,
                height: scrollView.bounds.height / targetScale
            )
            let zoomOrigin = CGPoint(
                x: tapPoint.x - (zoomSize.width / 2),
                y: tapPoint.y - (zoomSize.height / 2)
            )
            scrollView.zoom(to: CGRect(origin: zoomOrigin, size: zoomSize), animated: true)
        }
    }
}

struct StoryboardPhotoStripAddButton: View {
    enum ShapeStyle {
        case roundedRectangle
        case circle
    }

    var systemName: String = "plus"
    var iconColor: Color = Color.storyInk.opacity(0.82)
    var size: CGFloat = 52
    var iconWeight: Font.Weight = .light
    var showsDashedBorder: Bool = true
    var shape: ShapeStyle = .roundedRectangle

    var body: some View {
        VStack {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: iconWeight))
                .foregroundStyle(iconColor)
        }
        .frame(width: size, height: size)
        .background(addButtonBackground)
        .overlay(addButtonBorder)
        .accessibilityLabel("Add Reference photos")
    }

    @ViewBuilder
    private var addButtonBackground: some View {
        switch shape {
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.48))
        case .circle:
            Circle()
                .fill(Color.white.opacity(0.48))
        }
    }

    @ViewBuilder
    private var addButtonBorder: some View {
        let strokeColor = showsDashedBorder ? Color.storyPurple.opacity(0.34) : Color.clear
        let strokeStyle = StrokeStyle(lineWidth: 1.1, dash: [4, 3])

        switch shape {
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(strokeColor, style: strokeStyle)
        case .circle:
            Circle()
                .stroke(strokeColor, style: strokeStyle)
        }
    }
}

struct KeyboardPhotoThumbnail: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 34, height: 34)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.storyInk.opacity(0.34), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .frame(width: 38, height: 44)
            .contentShape(Rectangle())
    }
}

struct KeyboardPhotoAddButton: View {
    let hasPhotos: Bool

    var body: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.storyInk.opacity(0.72))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

struct KeyboardPhotoOverflowBadge: View {
    let count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.storyPurple)
            .frame(width: 34, height: 34)
            .background(Color.storyPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.storyPurple.opacity(0.26), lineWidth: 1)
            )
            .frame(width: 38, height: 44)
            .accessibilityLabel("\(count) more reference photos")
    }
}

struct StoryboardPhotoDropDelegate: DropDelegate {
    @Binding var photos: [CreateEntryReferencePhoto?]
    @Binding var draggedIndex: Int?

    let destinationIndex: Int

    func dropEntered(info: DropInfo) {
        guard
            let draggedIndex,
            draggedIndex != destinationIndex
        else {
            return
        }

        var compactPhotos = photos.compactMap { $0 }
        guard
            compactPhotos.indices.contains(draggedIndex),
            compactPhotos.indices.contains(destinationIndex)
        else {
            return
        }

        let photo = compactPhotos.remove(at: draggedIndex)
        compactPhotos.insert(photo, at: destinationIndex)
        photos = compactPhotos.map(Optional.some) + Array(repeating: nil, count: max(0, photos.count - compactPhotos.count))
        self.draggedIndex = destinationIndex
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedIndex = nil
        return true
    }
}

struct StoryboardPhotoPanel: View {
    let image: UIImage?
    let placeholderImageName: String
    let number: Int

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)

            GeometryReader { proxy in
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                    } else {
                        Image(placeholderImageName)
                            .resizable()
                    }
                }
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            }

            if image == nil {
                Rectangle()
                    .fill(Color.white.opacity(0.34))
            }

            Text("\(number)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyPurple)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.82), in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.storyPurple.opacity(0.22), lineWidth: 1)
                )
        }
        .overlay(
            Rectangle()
                .stroke(Color.storyInk.opacity(0.88), lineWidth: 1.5)
        )
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

struct CameraPhotoPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            dismiss: dismiss,
            onImagePicked: onImagePicked
        )
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let dismiss: DismissAction
        private let onImagePicked: (UIImage) -> Void

        init(
            dismiss: DismissAction,
            onImagePicked: @escaping (UIImage) -> Void
        ) {
            self.dismiss = dismiss
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }

            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

struct InlineArtStyleOption: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Image(inlineArtStyleAssetName(for: title))
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.storyPurple : Color.storyBorder.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white, Color.storyPurple)
                            .padding(5)
                    }
                }

            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isSelected ? Color.storyPurple : Color.storyInk.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 76)
        }
    }
}

func inlineArtStyleAssetName(for title: String) -> String {
    switch title {
    case "Anime":
        return "inline_art_style_anime"
    case "Graphic Novel":
        return "inline_art_style_graphic_novel"
    case "Pixel Art":
        return "inline_art_style_pixel_art"
    case "Manga":
        return "inline_art_style_manga"
    case "Pop Art":
        return "inline_art_style_pop_art"
    default:
        return "inline_art_style_anime"
    }
}

func artStylePromptDescription(for title: String) -> String {
switch title {

    case "Anime":
        return """
        Authentic modern anime artwork. Strongly stylized anime characters with large expressive eyes, simplified facial features, clean cel shading, vibrant colors, dramatic lighting, and dynamic poses.
        NOT photorealistic.
        Preserve identity but reinterpret all people as anime characters. Do not preserve realistic skin textures, facial proportions, or photographic details.
        The final result should look like a frame from a high-budget anime series, not a photograph with anime effects applied.
        """

    case "Graphic Novel":
        return """
        Premium western graphic novel artwork. Bold ink outlines, dramatic shadows, cinematic composition, painterly rendering, graphic shapes, and highly stylized comic-book storytelling.
        NOT photorealistic.
        Characters should look illustrated and artist-rendered rather than realistic. Use strong visual stylization, dramatic contrast, and graphic novel energy.
        The final result should look like published graphic novel artwork, not a painted photograph.
        """

    case "Pixel Art":
        return """
        Authentic 16-bit pixel art video game artwork. Large visible pixels, pixel-perfect edges, limited color palette, sprite-like characters, retro RPG environments, and deliberate pixel construction throughout.
        ABSOLUTELY NO smooth illustration or photorealistic rendering.
        Every object, character, and background element must be visibly pixelated.
        The final image should look like a premium SNES-era RPG screenshot, not a normal illustration with a pixel filter.
        """

    case "Manga":
        return """
        Authentic Japanese manga artwork. Highly stylized manga characters with expressive eyes, exaggerated expressions, bold black inks, screentones, cross-hatching, speed lines, dramatic camera angles, and dynamic manga storytelling.
        NOT photorealistic.
        Preserve identity but transform all people into manga characters. Simplify facial features and strongly stylize proportions.
        The final result should look like pages from a published manga series, not a realistic black-and-white photograph.
        """

    case "Pop Art":
        return """
        Bold pop art comic artwork inspired by classic comic books and gallery pop art. Thick black outlines, flat saturated colors, strong graphic shapes, Ben-Day dots, poster-like composition, and exaggerated visual impact.
        NOT photorealistic.
        Simplify forms into graphic comic-book shapes and bold color blocks.
        The final result should look like authentic pop art illustration, not a photo with color effects.
        """

    default:
        return """
        Fully commit to the selected art style.
        Preserve identity but not realism.
        Reinterpret everything as stylized artwork rather than photography.
        """
    }   
}

func artStyleAssetName(for title: String) -> String {
    switch title {
    case "Anime":
        return "art_style_anime"
    case "Graphic Novel":
        return "art_style_graphic_novel"
    case "Pixel Art":
        return "art_style_pixel_art"
    case "Manga":
        return "art_style_manga"
    case "Pop Art":
        return "art_style_pop_art"
    default:
        return "art_style_anime"
    }
}
