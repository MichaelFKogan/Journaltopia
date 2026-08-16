import Foundation

/// The identity of one logical generation request, from the moment the user asks for it until the
/// server has finished with it.
///
/// A storyboard generation costs real credits, so "did the user ask for one generation or two?" has
/// to survive things the in-memory `isGeneratingStoryboard` flag does not: a dropped response, a
/// backgrounded app, a process kill between the server reserving and the client hearing about it. In
/// all of those the user's intent was one generation, and the retry has to say so.
///
/// The id is minted once per intent and written to disk *before* the request goes out, so a
/// termination one instant later still leaves the next attempt something to identify itself with.
/// The server enforces the rest: a reservation carrying an id it has already seen returns the
/// storyboard it already made rather than reserving again.
///
/// Scoped to the signed-in account like every other local store, so one user's outstanding request
/// cannot be picked up by whoever signs in next.
enum StoryboardGenerationRequestStore {
    private static var storageKey: String {
        StorytopiaLocalAccountScope.scopedUserDefaultsKey("StorytopiaStoryboardGenerationRequests")
    }

    /// The id to send for this entry's generation: the one already outstanding, or a new one.
    ///
    /// Reusing rather than replacing is the whole point. A caller that cannot tell a retry from a
    /// fresh request — which is every caller, since the failure that lost the response also lost the
    /// knowledge of whether it landed — gets the safe answer by default.
    static func requestID(for clientEntryID: UUID) -> UUID {
        if let existing = outstandingRequests()[clientEntryID.uuidString.lowercased()] {
            return existing
        }

        let requestID = UUID()
        persist(requestID, for: clientEntryID)
        return requestID
    }

    /// The outstanding id for this entry, if there is one. Used to tell "this entry has a request in
    /// flight" from "this entry is idle" without minting an id as a side effect.
    static func outstandingRequestID(for clientEntryID: UUID) -> UUID? {
        outstandingRequests()[clientEntryID.uuidString.lowercased()]
    }

    /// Called once the server has reached a terminal answer for this entry's generation. Only then
    /// does the next tap become a genuinely new request that may reserve again.
    static func clearRequest(for clientEntryID: UUID) {
        var requests = outstandingRequests()
        requests.removeValue(forKey: clientEntryID.uuidString.lowercased())
        write(requests)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func persist(_ requestID: UUID, for clientEntryID: UUID) {
        var requests = outstandingRequests()
        requests[clientEntryID.uuidString.lowercased()] = requestID
        write(requests)
    }

    private static func outstandingRequests() -> [String: UUID] {
        guard
            let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]
        else {
            return [:]
        }

        return stored.reduce(into: [String: UUID]()) { result, element in
            if let requestID = UUID(uuidString: element.value) {
                result[element.key] = requestID
            }
        }
    }

    private static func write(_ requests: [String: UUID]) {
        let encoded = requests.mapValues { $0.uuidString }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
}
