import XCTest
@testable import Journaltopia

/// The client half of the two-bucket credit model.
///
/// The database owns every balance movement; what is tested here is that Swift reads the two buckets
/// without collapsing them, spends against the total the way the server does, and retries a blocked
/// generation only when the server's own numbers say it can now be afforded.
@MainActor
final class CreditBucketTests: XCTestCase {

    // MARK: - The balance model

    func testTotalIsTheSumOfBothBuckets() {
        XCTAssertEqual(GenerationCreditBalance(monthly: 12, purchased: 20).total, 32)
        XCTAssertEqual(GenerationCreditBalance(monthly: 0, purchased: 0).total, 0)
        XCTAssertEqual(GenerationCreditBalance.empty.total, 0)
    }

    func testNegativeBalancesAreClampedRatherThanShown() {
        // A negative balance is a server bug, not something to render. Clamping keeps a bad row from
        // producing "-3 credits" on screen; the database's own check constraint is the real guard.
        let balance = GenerationCreditBalance(monthly: -5, purchased: -2)
        XCTAssertEqual(balance.monthly, 0)
        XCTAssertEqual(balance.purchased, 0)
    }

    func testBothBucketsDecodeFromTheProfileRow() throws {
        let json = #"{"monthly_generation_credits": 7, "purchased_generation_credits": 13}"#
        let balance = try JSONDecoder().decode(GenerationCreditBalance.self, from: Data(json.utf8))

        XCTAssertEqual(balance.monthly, 7)
        XCTAssertEqual(balance.purchased, 13)
        XCTAssertEqual(balance.total, 20)
    }

    // MARK: - The store

    func testAnUnreadBalanceIsNotZero() {
        // Fails closed. An unknown balance is a reason to refresh, never permission to spend.
        let store = GenerationCreditStore()

        XCTAssertNil(store.balance)
        XCTAssertFalse(store.hasKnownBalance)
        XCTAssertFalse(store.canSpend(1))
    }

    func testSpendingIsCheckedAgainstTheTotalBecauseTheServerSpendsAcrossBuckets() {
        // An HD page costs 2. One monthly credit plus one purchased credit covers it, and the server
        // will happily take one from each — so the client must not refuse it for having neither
        // bucket individually large enough.
        let store = GenerationCreditStore()
        store.apply(GenerationCreditBalance(monthly: 1, purchased: 1))

        XCTAssertTrue(store.canSpend(OpenAIImageGenerationQuality.highDefinition.creditCost))
        XCTAssertEqual(store.balance, 2)
        XCTAssertEqual(store.monthlyCredits, 1)
        XCTAssertEqual(store.purchasedCredits, 1)
    }

    func testInsufficientTotalIsRefused() {
        let store = GenerationCreditStore()
        store.apply(GenerationCreditBalance(monthly: 0, purchased: 1))

        XCTAssertTrue(store.canSpend(OpenAIImageGenerationQuality.standard.creditCost))
        XCTAssertFalse(store.canSpend(OpenAIImageGenerationQuality.highDefinition.creditCost))
    }

    func testResetForgetsTheBalanceRatherThanZeroingIt() {
        // Signing out must leave the balance *unknown*, not zero: zero would let a screen state
        // confidently that the next person to sign in has no credits.
        let store = GenerationCreditStore()
        store.apply(GenerationCreditBalance(monthly: 5, purchased: 5))
        store.reset()

        XCTAssertNil(store.balance)
        XCTAssertFalse(store.hasKnownBalance)
    }

    // MARK: - Presentation

    func testTheSplitIsShownOnlyWhenBothBucketsHoldSomething() {
        let store = GenerationCreditStore()

        store.apply(GenerationCreditBalance(monthly: 12, purchased: 20))
        XCTAssertEqual(CreditBucketFormatting.split(for: store), "12 monthly · 20 purchased")

        store.apply(GenerationCreditBalance(monthly: 12, purchased: 0))
        XCTAssertEqual(CreditBucketFormatting.split(for: store), "12 monthly")

        store.apply(GenerationCreditBalance(monthly: 0, purchased: 20))
        XCTAssertEqual(CreditBucketFormatting.split(for: store), "20 purchased")

        store.apply(.empty)
        XCTAssertNil(CreditBucketFormatting.split(for: store), "an empty balance has no split worth showing")
    }

    func testTheExplanationStatesTheActualPolicy() {
        // Guards against the wording drifting back to the old rollover promise.
        XCTAssertTrue(CreditBucketFormatting.explanation.contains("reset"))
        XCTAssertTrue(CreditBucketFormatting.explanation.contains("never expire"))
        XCTAssertFalse(CreditBucketFormatting.explanation.lowercased().contains("roll over"))
    }

    // MARK: - Redemption outcomes

    func testSettledRedemptionFailuresFinishTheTransactionAndTransientOnesDoNot() {
        // The retry contract. A transaction left unfinished is redelivered by Apple on the next
        // launch, which is what recovers a redemption that failed on a dead network — but doing that
        // to an outcome that can never change would redeliver it forever.
        XCTAssertTrue(CreditPackRedemptionError.alreadyRedeemedByAnotherAccount.isSettled)
        XCTAssertTrue(CreditPackRedemptionError.unknownProduct.isSettled)

        XCTAssertFalse(CreditPackRedemptionError.unavailable.isSettled)
        XCTAssertFalse(CreditPackRedemptionError.notAuthenticated.isSettled)
        XCTAssertFalse(CreditPackRedemptionError.subscriptionRequired.isSettled)
        XCTAssertFalse(CreditPackRedemptionError.verificationFailed("network").isSettled)
    }

    func testRedemptionResultCarriesBothBucketsBack() {
        let json = #"""
        {"creditsGranted": 25, "alreadyRedeemed": false, "monthlyCredits": 3, "purchasedCredits": 45}
        """#
        let result = try? JSONDecoder().decode(CreditPackRedemptionResult.self, from: Data(json.utf8))

        XCTAssertEqual(result?.creditsGranted, 25)
        XCTAssertEqual(result?.balance.monthly, 3)
        XCTAssertEqual(result?.balance.purchased, 45)
        XCTAssertEqual(result?.balance.total, 48)
    }

    // MARK: - Retry after buying credits

    func testABlockedGenerationResumesOnlyOnceTheServerBalanceCoversIt() {
        let gate = EntitlementGate()
        gate.update(state: .subscribed(productID: nil, currentPeriodEnd: nil))
        var resumed = 0

        let hdCost = OpenAIImageGenerationQuality.highDefinition.creditCost
        XCTAssertFalse(gate.requireCredits(hdCost, balance: 0, for: .generateHDStoryboard, retry: { resumed += 1 }))

        // A purchase that did not land, or one whose redemption failed: the balance has not moved.
        gate.completeCreditRequestIfAffordable(balance: 0)
        XCTAssertEqual(resumed, 0, "StoreKit success is not a reason to retry")
        XCTAssertNotNil(gate.pendingRequest)

        // Still short — a 1-credit balance does not cover an HD page.
        gate.completeCreditRequestIfAffordable(balance: 1)
        XCTAssertEqual(resumed, 0)

        // The server confirms the pack landed.
        gate.completeCreditRequestIfAffordable(balance: 10)
        XCTAssertEqual(resumed, 1)
        XCTAssertNil(gate.pendingRequest)

        // And exactly once.
        gate.completeCreditRequestIfAffordable(balance: 10)
        XCTAssertEqual(resumed, 1)
    }

    func testAnUnknownBalanceNeverResumesABlockedGeneration() {
        let gate = EntitlementGate()
        gate.update(state: .subscribed(productID: nil, currentPeriodEnd: nil))
        var resumed = 0

        XCTAssertFalse(gate.requireCredits(1, balance: 0, for: .generateStoryboard, retry: { resumed += 1 }))
        gate.completeCreditRequestIfAffordable(balance: nil)

        XCTAssertEqual(resumed, 0)
        XCTAssertNotNil(gate.pendingRequest)
    }

    func testBuyingCreditsDoesNotResumeASubscriptionPaywall() {
        // Different requirement, different resolution. A pack cannot satisfy "you need a plan".
        let gate = EntitlementGate()
        gate.update(state: .notSubscribed)
        var resumed = 0

        XCTAssertFalse(gate.requireJournaltopiaPlus(for: .generateStoryboard, retry: { resumed += 1 }))
        gate.completeCreditRequestIfAffordable(balance: 999)

        XCTAssertEqual(resumed, 0)
        XCTAssertNotNil(gate.pendingRequest)
    }
}
