import Foundation

/// The App Store products Journaltopia sells.
///
/// One definition, so the identifier exists in exactly two places that have to agree — here and App
/// Store Connect — rather than being retyped wherever a purchase or a StoreKit lookup happens.
enum JournaltopiaProducts {
    /// Journaltopia+, the monthly auto-renewable subscription that unlocks AI storyboard generation.
    ///
    /// Must match the product identifier in App Store Connect and in `Journaltopia.storekit` exactly.
    static let journaltopiaPlusMonthly = "com.journaltopia.plus.monthly"

    /// Everything the app asks StoreKit to load at launch. Credit packs join this list in a later
    /// phase; the shape is already plural so that adding one is not a refactor.
    static let subscriptionIdentifiers: [String] = [journaltopiaPlusMonthly]

    /// The subscription group Journaltopia+ belongs to. Kept here because restore and status lookups
    /// are group-scoped, and a mismatch between this and App Store Connect is otherwise silent.
    static let journaltopiaPlusGroupName = "Journaltopia Plus"
}

/// What the server says about this account's plan.
///
/// Deliberately the *server's* answer, not StoreKit's. StoreKit knows what this device's Apple ID
/// bought; Supabase knows what Journaltopia has independently verified and recorded, and generation is
/// authorised against the second. Keeping the published state on the server's side of that line is
/// what stops a screen from showing "subscribed" while the server refuses to generate.
enum JournaltopiaPlusState: Equatable {
    /// Not asked yet, or asked and the answer has not come back. Not the same as "not subscribed":
    /// a screen that treats it that way flashes a paywall at a paying subscriber on every launch.
    case unresolved
    /// Signed out. There is no account for an entitlement to belong to.
    case signedOut
    case notSubscribed
    case subscribed(productID: String?, currentPeriodEnd: Date?)

    var isSubscribed: Bool {
        if case .subscribed = self {
            return true
        }

        return false
    }

    /// Whether an answer has actually been obtained. Gating should treat `false` as "wait", never as
    /// "refuse".
    var isResolved: Bool {
        self != .unresolved
    }

    var currentPeriodEnd: Date? {
        if case .subscribed(_, let periodEnd) = self {
            return periodEnd
        }

        return nil
    }
}
