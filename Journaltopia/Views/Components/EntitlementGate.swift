import Combine
import SwiftUI

/// Why an action that needs Journaltopia+ was turned away.
///
/// Two outcomes, kept apart because they lead somewhere different: one to the paywall, one to buying
/// credits. The server draws the same distinction — `subscription_required` and
/// `insufficient_generation_credits` are separate errors — and collapsing them here would put a
/// subscriber who ran out of credits in front of a "Start Journaltopia+" button they have already
/// pressed.
enum EntitlementRequirement: Equatable {
    case subscription
    case credits(needed: Int, balance: Int?)
}

/// An action a signed-in user can reach but cannot complete without Journaltopia+.
///
/// Named after what the user was trying to do rather than after the thing that blocked it, for the
/// same reason ``AccountRequiredAction`` is: the gate's job is to explain the refusal in the user's
/// terms.
enum JournaltopiaPlusRequiredAction: String, Equatable {
    case generateStoryboard
    case generateHDStoryboard
    case customizePaper
    case buyCredits

    var subscriptionTitle: String {
        switch self {
        case .generateStoryboard, .generateHDStoryboard:
            return "Generate with Journaltopia+"
        case .customizePaper:
            return "Unlock Paper Styles"
        case .buyCredits:
            return "Journaltopia+ Required"
        }
    }

    var subscriptionMessage: String {
        switch self {
        case .generateStoryboard:
            return "Turning an entry into a graphic novel page runs on Journaltopia's servers. Journaltopia+ includes 25 credits every month — your journal itself stays free."
        case .generateHDStoryboard:
            return "HD pages are sharper and cost 2 credits. Journaltopia+ includes 25 credits every month — your journal itself stays free."
        case .customizePaper:
            return "Paper image styles are included with Journaltopia+. Start Journaltopia+ to use textured pages in your entries."
        case .buyCredits:
            return "Extra credit packs are for Journaltopia+ members. Start Journaltopia+ to get 25 credits a month, then top up whenever you need more."
        }
    }

    var creditsTitle: String {
        "Not Enough Credits"
    }

    func creditsMessage(needed: Int, balance: Int?) -> String {
        let have = balance.map(String.init) ?? "no"
        let cost = needed == 1 ? "1 credit" : "\(needed) credits"

        switch self {
        case .generateHDStoryboard:
            return "An HD page costs \(cost) and you have \(have) left. Switch to Standard, or add more credits to keep going."
        case .generateStoryboard, .customizePaper, .buyCredits:
            return "This page costs \(cost) and you have \(have) left. Your next 25 arrive with your renewal, or you can add more now."
        }
    }
}

/// One request to the gate, carrying the action it should resume.
struct EntitlementGateRequest: Identifiable {
    let id = UUID()
    let action: JournaltopiaPlusRequiredAction
    let requirement: EntitlementRequirement
    let retry: (() -> Void)?
}

/// The one place a Journaltopia+ action is turned away.
///
/// Deliberately the same shape as ``SignInGate``: every screen asks the same question and gets back a
/// plain `Bool`, so a call site reads as a guard rather than as a presentation.
///
/// ```swift
/// guard entitlementGate.requireJournaltopiaPlus(for: .generateStoryboard, retry: { generate() }) else { return }
/// ```
///
/// The three-way answer matters more here than it does for signing in, because one of the three is
/// "not yet". Entitlement arrives asynchronously from the server, and a gate that treated an
/// unresolved answer as "not subscribed" would show the paywall to a paying subscriber on every cold
/// launch. `.unresolved` therefore refuses the action *without* presenting anything, and the caller
/// shows a waiting state.
///
/// This gate never consults StoreKit. It reads ``SubscriptionStore/state``, which is the server's
/// answer, because that is the answer `generate-storyboard` will enforce.
@MainActor
final class EntitlementGate: ObservableObject {
    @Published private(set) var pendingRequest: EntitlementGateRequest?
    @Published private(set) var state: JournaltopiaPlusState = .unresolved

    /// The retry belonging to a request that is waiting for the server to confirm entitlement.
    /// Held separately from `pendingRequest` so the sheet can dismiss while the resume still happens.
    private var awaitingEntitlementRetry: (() -> Void)?

    func update(state: JournaltopiaPlusState) {
        guard self.state != state else {
            return
        }

        self.state = state

        // Entitlement arriving is what resolves an outstanding subscription request. The retry is
        // handed forward rather than discarded with the request: dropping it here is how someone
        // subscribes from the generate button and then finds nothing happened, because the state
        // change that dismissed the paywall also threw away the action it was blocking.
        //
        // A pending request for credits is left alone — becoming subscribed does not add credits to
        // an account that already had a subscription.
        if state.isSubscribed, pendingRequest?.requirement == .subscription {
            awaitingEntitlementRetry = pendingRequest?.retry ?? awaitingEntitlementRetry
            pendingRequest = nil
        }

        if !state.isSubscribed {
            awaitingEntitlementRetry = nil
        }

        // Signing out ends the request outright. A pending paywall carries a retry closure that
        // would resume the previous account's generation, and leaving it up would show the next
        // person to sign in a sheet raised by somebody else.
        if state == .signedOut {
            pendingRequest = nil
        }
    }

    /// Whether this action may go ahead, presenting the paywall if it may not.
    ///
    /// Returns `false` for `.unresolved` and `.signedOut` without presenting anything: the first is
    /// not an answer yet, and the second is ``SignInGate``'s to handle.
    @discardableResult
    func requireJournaltopiaPlus(
        for action: JournaltopiaPlusRequiredAction,
        retry: (() -> Void)? = nil
    ) -> Bool {
        switch state {
        case .subscribed:
            return true
        case .unresolved, .signedOut:
            return false
        case .notSubscribed:
            pendingRequest = EntitlementGateRequest(
                action: action,
                requirement: .subscription,
                retry: retry
            )
            return false
        }
    }

    /// Whether the balance covers this generation, presenting the credit screen if it does not.
    ///
    /// Only called once entitlement is established. A balance that has never been read is treated
    /// the same way ``GenerationCreditStore/canSpend(_:)`` treats it — not permission to spend — but
    /// it is *not* a reason to present the credit screen, because the server may well allow it. The
    /// authoritative 402 handles that case.
    @discardableResult
    func requireCredits(
        _ cost: Int,
        balance: Int?,
        for action: JournaltopiaPlusRequiredAction,
        retry: (() -> Void)? = nil
    ) -> Bool {
        guard let balance else {
            return true
        }

        guard balance < cost else {
            return true
        }

        pendingRequest = EntitlementGateRequest(
            action: action,
            requirement: .credits(needed: cost, balance: balance),
            retry: retry
        )
        return false
    }

    /// Raises the paywall because the *server* said so, overriding whatever this client believed.
    ///
    /// Reached when `generate-storyboard` answers 403. Local entitlement can be stale — a
    /// subscription that lapsed while the app was open, a device that has not reconciled — and the
    /// server's refusal is the one that counts.
    func presentSubscriptionRequired(
        for action: JournaltopiaPlusRequiredAction = .generateStoryboard,
        retry: (() -> Void)? = nil
    ) {
        pendingRequest = EntitlementGateRequest(
            action: action,
            requirement: .subscription,
            retry: retry
        )
    }

    /// Raises the credit screen because the server answered 402, for the same reason as above: the
    /// balance this client is showing may be older than the one that was just spent.
    func presentInsufficientCredits(
        needed: Int,
        balance: Int?,
        for action: JournaltopiaPlusRequiredAction = .generateStoryboard,
        retry: (() -> Void)? = nil
    ) {
        pendingRequest = EntitlementGateRequest(
            action: action,
            requirement: .credits(needed: needed, balance: balance),
            retry: retry
        )
    }

    func dismiss() {
        pendingRequest = nil
        awaitingEntitlementRetry = nil
    }

    /// Called when a purchase has completed *and* the server has confirmed entitlement.
    ///
    /// The confirmation is the point. Resuming on StoreKit's word alone would send the user straight
    /// back into a generation the server is still going to refuse, because Supabase has not yet
    /// recorded the subscription — so the retry runs only when `state` says subscribed, and is
    /// otherwise held until an entitlement refresh says so.
    func completePendingRequest() {
        // Either the request is still open, or `update(state:)` already closed it and parked the
        // retry. Both orderings happen — the state change and the sheet's callback race — so both
        // are read here rather than assuming one.
        let retry = pendingRequest?.retry ?? awaitingEntitlementRetry
        pendingRequest = nil

        guard state.isSubscribed else {
            awaitingEntitlementRetry = retry
            return
        }

        awaitingEntitlementRetry = nil
        retry?()
    }

    /// Resumes a generation that was blocked on credits, once the server says the balance covers it.
    ///
    /// The balance passed in is the one the server returned from the redemption, never a local
    /// guess, and it is compared against the cost that was actually blocked. Buying a 10-pack when
    /// an HD page needs 2 resumes; buying nothing, or a purchase whose redemption failed, does not.
    /// StoreKit reporting `.success` is not on its own a reason to retry anything.
    func completeCreditRequestIfAffordable(balance: Int?) {
        guard
            case .credits(let needed, _)? = pendingRequest?.requirement,
            let balance,
            balance >= needed
        else {
            return
        }

        let retry = pendingRequest?.retry
        pendingRequest = nil
        retry?()
    }

    /// Runs a retry that was held back waiting for the server. Called after an entitlement refresh.
    func resumeIfEntitlementArrived() {
        guard state.isSubscribed, let retry = awaitingEntitlementRetry else {
            return
        }

        awaitingEntitlementRetry = nil
        retry()
    }
}

/// The sheet the gate presents. Mounted once at the app root so every screen shares it.
struct EntitlementGateSheet: View {
    @EnvironmentObject private var entitlementGate: EntitlementGate
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore

    let request: EntitlementGateRequest

    var body: some View {
        Group {
            switch request.requirement {
            case .subscription:
                JournaltopiaPlusPaywallView(
                    presentation: .sheet,
                    promptTitle: request.action.subscriptionTitle,
                    promptSubtitle: request.action.subscriptionMessage,
                    onDismiss: { entitlementGate.dismiss() }
                )
            case .credits(let needed, let balance):
                BuyCreditsView(
                    promptTitle: request.action.creditsTitle,
                    promptSubtitle: request.action.creditsMessage(needed: needed, balance: balance),
                    onDismiss: { entitlementGate.dismiss() },
                    onPurchased: {
                        // The balance here is whatever the server last told this device, having just
                        // been refreshed by the purchase. The gate decides whether it is enough.
                        entitlementGate.completeCreditRequestIfAffordable(
                            balance: generationCreditStore.balance
                        )
                    }
                )
            }
        }
        .onChange(of: subscriptionStore.state) { state in
            entitlementGate.update(state: state)

            // The sheet closes on the server's word, not on StoreKit's. `completePendingRequest`
            // then resumes the original action, or holds it until an entitlement refresh lands.
            guard state.isSubscribed, request.requirement == .subscription else {
                return
            }

            entitlementGate.completePendingRequest()
        }
    }
}
