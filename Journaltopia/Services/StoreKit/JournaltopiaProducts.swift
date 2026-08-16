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

    static let subscriptionIdentifiers: [String] = [journaltopiaPlusMonthly]

    /// The subscription group Journaltopia+ belongs to. Kept here because restore and status lookups
    /// are group-scoped, and a mismatch between this and App Store Connect is otherwise silent.
    static let journaltopiaPlusGroupName = "Journaltopia Plus"

    /// Consumable credit packs, for Journaltopia+ members who run out before their renewal.
    ///
    /// Defined and loaded so the screen can show real App Store prices, but **not purchasable yet**:
    /// see ``CreditPackPurchasing``. Granting credits on the strength of StoreKit reporting success
    /// would be the same mistake the whole subscription architecture was built to avoid, so the
    /// buttons stay disabled until the server can verify a consumable transaction.
    enum CreditPack: String, CaseIterable, Identifiable {
        case ten = "com.journaltopia.credits.10"
        case twentyFive = "com.journaltopia.credits.25"
        case sixty = "com.journaltopia.credits.60"

        var id: String { rawValue }

        var credits: Int {
            switch self {
            case .ten: return 10
            case .twentyFive: return 25
            case .sixty: return 60
            }
        }

        var title: String {
            "\(credits) Credits"
        }

        var detail: String {
            switch self {
            case .ten: return "A couple of extra pages"
            case .twentyFive: return "Another month's worth"
            case .sixty: return "Best value per credit"
            }
        }
    }

    static let creditPackIdentifiers: [String] = CreditPack.allCases.map(\.rawValue)
}

/// Whether a credit pack can actually be bought.
///
/// A single answer in one place, so the UI cannot drift out of step with what the backend can
/// honour. It is `.awaitingServerVerification` today because redeeming a consumable needs three
/// things that do not exist yet: an Edge Function that verifies the signed consumable transaction
/// with Apple, an RPC that writes a `purchased_credit_pack` ledger entry keyed by the transaction
/// id, and the products themselves in App Store Connect.
///
/// The ledger already reserves the `purchased_credit_pack` reason and the idempotency constraint it
/// would need, so this becomes a wiring job rather than a design one.
enum CreditPackPurchasing {
    enum Availability: Equatable {
        case available
        case awaitingServerVerification
        case requiresSubscription
    }

    /// Purchasing is deliberately not implemented. Flipping this to `.available` without the server
    /// path in place would mean granting credits on a client's say-so.
    static func availability(isSubscribed: Bool) -> Availability {
        guard isSubscribed else {
            return .requiresSubscription
        }

        return .awaitingServerVerification
    }

    static let unavailableExplanation =
        "Extra credit packs are not on sale yet. Your monthly 25 credits arrive with each renewal."
}

/// What a restore actually did. Three outcomes, because they are three different things to tell
/// someone, and "something went wrong" is the wrong answer to two of them.
enum SubscriptionRestoreOutcome: Equatable {
    case restored
    case nothingToRestore
    case notSignedIn
    case failed(String)

    var isSuccess: Bool {
        self == .restored
    }

    var message: String {
        switch self {
        case .restored:
            return "Journaltopia+ restored."
        case .nothingToRestore:
            return "No active Journaltopia+ subscription was found for this Apple ID."
        case .notSignedIn:
            return "Sign in first so Journaltopia knows which account to restore to."
        case .failed(let reason):
            return reason
        }
    }
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
