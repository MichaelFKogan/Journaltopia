import XCTest
@testable import Journaltopia

/// What the Create screen does in each account state, and what it does when the server contradicts
/// it.
///
/// These exercise ``EntitlementGate`` directly rather than through SwiftUI, because the gate is
/// where the decision actually lives — the views only render its answer. The interesting cases are
/// the ones where "no" has to mean two different things, and the one where "not yet" must not be
/// mistaken for "no".
@MainActor
final class EntitlementGatingTests: XCTestCase {
    private func gate(_ state: JournaltopiaPlusState) -> EntitlementGate {
        let gate = EntitlementGate()
        gate.update(state: state)
        return gate
    }

    private var standardCost: Int { OpenAIImageGenerationQuality.standard.creditCost }
    private var hdCost: Int { OpenAIImageGenerationQuality.highDefinition.creditCost }

    // MARK: - A. Signed out

    func testSignedOutDoesNotRaiseThePaywall() {
        // Signing in is SignInGate's job. A signed-out visitor who taps Generate should be asked to
        // sign in, not sold a subscription for an account that does not exist yet.
        let gate = gate(.signedOut)

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard))
        XCTAssertNil(gate.pendingRequest)
    }

    // MARK: - B. Signed in, free

    func testFreeAccountRaisesTheSubscriptionPaywall() {
        let gate = gate(.notSubscribed)

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard))
        XCTAssertEqual(gate.pendingRequest?.requirement, .subscription)
        XCTAssertEqual(gate.pendingRequest?.action, .generateStoryboard)
    }

    func testHDSelectionCarriesItsOwnWording() {
        let gate = gate(.notSubscribed)

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateHDStoryboard))
        XCTAssertEqual(gate.pendingRequest?.action, .generateHDStoryboard)
        XCTAssertTrue(gate.pendingRequest?.action.subscriptionMessage.contains("2 credits") ?? false)
    }

    // MARK: - C. Unresolved

    func testUnresolvedEntitlementRefusesWithoutPresentingAnything() {
        // The regression this exists to prevent: a paying subscriber opening the app and being told
        // to subscribe, because the server had not answered yet.
        let gate = gate(.unresolved)

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard))
        XCTAssertNil(gate.pendingRequest, "an unanswered question is not a refusal")
    }

    func testUnresolvedIsNotReportedAsResolved() {
        XCTAssertFalse(JournaltopiaPlusState.unresolved.isResolved)
        XCTAssertTrue(JournaltopiaPlusState.notSubscribed.isResolved)
        XCTAssertTrue(JournaltopiaPlusState.subscribed(productID: nil, currentPeriodEnd: nil).isResolved)
    }

    // MARK: - D. Subscriber with credits

    func testSubscriberWithEnoughCreditsMayGenerate() {
        let gate = gate(.subscribed(productID: JournaltopiaProducts.journaltopiaPlusMonthly, currentPeriodEnd: nil))

        XCTAssertTrue(gate.requireJournaltopiaPlus(for: .generateStoryboard))
        XCTAssertTrue(gate.requireCredits(hdCost, balance: 18, for: .generateHDStoryboard))
        XCTAssertNil(gate.pendingRequest)
    }

    func testAnUnknownBalanceIsLeftToTheServer() {
        // The balance has not been read yet. Blocking here would refuse a generation the server
        // would have allowed; the authoritative 402 covers the case where it would not.
        let gate = gate(.subscribed(productID: nil, currentPeriodEnd: nil))

        XCTAssertTrue(gate.requireCredits(hdCost, balance: nil, for: .generateHDStoryboard))
        XCTAssertNil(gate.pendingRequest)
    }

    // MARK: - E. Subscriber without credits

    func testSubscriberShortOnCreditsGetsTheCreditScreenNotThePaywall() {
        let gate = gate(.subscribed(productID: nil, currentPeriodEnd: nil))

        XCTAssertTrue(gate.requireJournaltopiaPlus(for: .generateHDStoryboard))
        XCTAssertFalse(gate.requireCredits(hdCost, balance: 1, for: .generateHDStoryboard))
        XCTAssertEqual(gate.pendingRequest?.requirement, .credits(needed: hdCost, balance: 1))
    }

    func testOneCreditShortOfHDStillAffordsStandard() {
        let gate = gate(.subscribed(productID: nil, currentPeriodEnd: nil))

        XCTAssertTrue(gate.requireCredits(standardCost, balance: 1, for: .generateStoryboard))
        XCTAssertNil(gate.pendingRequest)
    }

    // MARK: - F/G. The server overrides stale local state

    func testServerSubscriptionRequiredOpensThePaywallDespiteLocalEntitlement() {
        // The client believes it is subscribed; the server has just said otherwise. The server wins.
        let gate = gate(.subscribed(productID: nil, currentPeriodEnd: nil))
        XCTAssertTrue(gate.requireJournaltopiaPlus(for: .generateStoryboard))

        gate.presentSubscriptionRequired(for: .generateStoryboard)

        XCTAssertEqual(gate.pendingRequest?.requirement, .subscription)
    }

    func testServerInsufficientCreditsOpensTheCreditScreen() {
        let gate = gate(.subscribed(productID: nil, currentPeriodEnd: nil))

        gate.presentInsufficientCredits(needed: hdCost, balance: 0, for: .generateHDStoryboard)

        XCTAssertEqual(gate.pendingRequest?.requirement, .credits(needed: hdCost, balance: 0))
    }

    func testGenerationErrorsAreClassifiedByTypeNotByMessage() {
        // The routing contract. Wording changes; these cases must not.
        XCTAssertEqual(
            StoryboardGenerationRefusal(error: StoryboardGenerationError.subscriptionRequired("anything at all")),
            .subscriptionRequired
        )
        XCTAssertEqual(
            StoryboardGenerationRefusal(error: StoryboardGenerationError.insufficientCredits("anything at all")),
            .insufficientCredits
        )
        XCTAssertEqual(
            StoryboardGenerationRefusal(error: StoryboardGenerationError.openAIMessage("Storyboard generation requires Journaltopia+.")),
            .other,
            "a plain message that happens to mention the subscription is not a typed refusal"
        )
        XCTAssertEqual(StoryboardGenerationRefusal(error: StoryboardGenerationError.noGeneratedImage), .other)
    }

    // MARK: - H. Resuming only after the server agrees

    func testPurchaseDoesNotResumeTheActionUntilTheServerConfirms() {
        let gate = gate(.notSubscribed)
        var resumed = 0

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard, retry: { resumed += 1 }))

        // StoreKit has reported success, but the server has not been heard from. Resuming now would
        // send the user straight into a generation Supabase is still going to refuse.
        gate.completePendingRequest()
        XCTAssertEqual(resumed, 0, "the action must not resume on StoreKit's word alone")
        XCTAssertNil(gate.pendingRequest)

        // The server agrees, and only now does the original action run.
        gate.update(state: .subscribed(productID: nil, currentPeriodEnd: nil))
        gate.resumeIfEntitlementArrived()
        XCTAssertEqual(resumed, 1)

        // And exactly once.
        gate.resumeIfEntitlementArrived()
        XCTAssertEqual(resumed, 1)
    }

    func testResumeRunsImmediatelyWhenEntitlementIsAlreadyConfirmed() {
        let gate = gate(.notSubscribed)
        var resumed = 0

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard, retry: { resumed += 1 }))

        gate.update(state: .subscribed(productID: nil, currentPeriodEnd: nil))
        gate.completePendingRequest()

        XCTAssertEqual(resumed, 1)
    }

    func testAFailedPurchaseDoesNotStrandAResumeThatLaterFires() {
        // The sync failed, entitlement never arrived, and the user gave up. The held retry must not
        // fire later when an unrelated refresh happens to land.
        let gate = gate(.notSubscribed)
        var resumed = 0

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard, retry: { resumed += 1 }))
        gate.completePendingRequest()
        gate.dismiss()

        gate.update(state: .subscribed(productID: nil, currentPeriodEnd: nil))
        gate.resumeIfEntitlementArrived()

        XCTAssertEqual(resumed, 0, "a dismissed gate must not resume later")
    }

    // MARK: - J. Expiry

    func testExpiryBlocksGenerationAndNothingElse() {
        // Losing a subscription is not losing an account. The gate only ever guards generation;
        // there is no path in it that touches entries, journals or existing storyboards.
        let gate = gate(.subscribed(productID: nil, currentPeriodEnd: Date().addingTimeInterval(-3600)))
        XCTAssertTrue(gate.requireJournaltopiaPlus(for: .generateStoryboard))

        gate.update(state: .notSubscribed)

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard))
        XCTAssertEqual(gate.pendingRequest?.requirement, .subscription)
    }

    func testBecomingSubscribedClearsAPendingPaywallButNotAPendingCreditRequest() {
        // Subscribing answers "you need a plan". It does not answer "you need more credits" — an
        // existing subscriber short on credits is not helped by being told they are subscribed.
        let paywallGate = gate(.notSubscribed)
        XCTAssertFalse(paywallGate.requireJournaltopiaPlus(for: .generateStoryboard))
        paywallGate.update(state: .subscribed(productID: nil, currentPeriodEnd: nil))
        XCTAssertNil(paywallGate.pendingRequest)

        let creditGate = gate(.subscribed(productID: nil, currentPeriodEnd: nil))
        XCTAssertFalse(creditGate.requireCredits(hdCost, balance: 0, for: .generateHDStoryboard))
        creditGate.update(state: .subscribed(productID: "other", currentPeriodEnd: Date()))
        XCTAssertNotNil(creditGate.pendingRequest)
    }

    // MARK: - Credit packs

    func testCreditPacksAreNotPurchasableWithoutAVerifiedServerPath() {
        // The guard against the shortcut this whole architecture exists to avoid: granting credits
        // because StoreKit said a purchase succeeded. Flipping this to `.available` requires the
        // server-side consumable verification that does not exist yet.
        XCTAssertEqual(CreditPackPurchasing.availability(isSubscribed: true), .awaitingServerVerification)
        XCTAssertEqual(CreditPackPurchasing.availability(isSubscribed: false), .requiresSubscription)
    }

    func testCreditPackIdentifiersAreDefinedOnceAndMatchTheirCreditCounts() {
        XCTAssertEqual(JournaltopiaProducts.CreditPack.ten.credits, 10)
        XCTAssertEqual(JournaltopiaProducts.CreditPack.twentyFive.credits, 25)
        XCTAssertEqual(JournaltopiaProducts.CreditPack.sixty.credits, 60)
        XCTAssertEqual(
            JournaltopiaProducts.creditPackIdentifiers,
            ["com.journaltopia.credits.10", "com.journaltopia.credits.25", "com.journaltopia.credits.60"]
        )
    }

    // MARK: - I. Restore outcomes

    func testRestoreOutcomesReadDistinctly() {
        // "No subscription found" and "the restore failed" are different facts, and the generic
        // apology that used to cover both is what this replaces.
        XCTAssertTrue(SubscriptionRestoreOutcome.restored.isSuccess)
        XCTAssertFalse(SubscriptionRestoreOutcome.nothingToRestore.isSuccess)
        XCTAssertFalse(SubscriptionRestoreOutcome.failed("network").isSuccess)

        XCTAssertNotEqual(
            SubscriptionRestoreOutcome.nothingToRestore.message,
            SubscriptionRestoreOutcome.failed("network").message
        )
        XCTAssertEqual(SubscriptionRestoreOutcome.failed("Specific reason.").message, "Specific reason.")
    }
}
