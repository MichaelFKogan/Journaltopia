import Combine
import Foundation
import StoreKit

/// Journaltopia+ on the client: the App Store product, the purchase and restore operations, and the
/// listener that keeps the server told about what Apple has done.
///
/// The division of responsibility this type exists to hold:
///
///   StoreKit   knows what this device's Apple ID bought, and hands over signed transactions
///   this type  forwards those signatures to the server and asks the server what it concluded
///   Supabase   verifies them with Apple, records entitlement, and authorises generation
///
/// `state` is the server's answer, never StoreKit's. A device can hold a perfectly valid transaction
/// that the server has not seen — first launch after reinstall, a sync that failed while offline —
/// and during that window the honest answer is "not yet entitled", because that is exactly what
/// `generate-storyboard` would say. Publishing StoreKit's optimism instead would produce a UI that
/// promises something the server refuses.
///
/// Owned once, at the app root. The transaction listener has to outlive every screen: Apple can
/// complete a purchase while the paywall is gone, while the app is backgrounded, or between launches.
@MainActor
final class SubscriptionStore: ObservableObject {
    enum PurchasePhase: Equatable {
        case idle
        case purchasing
        /// Apple has the purchase but it is not finished — Ask to Buy, or a payment method that
        /// needs action outside the app. The entitlement will arrive through the listener, not
        /// through the purchase call's return value.
        case awaitingApproval
    }

    /// The server's answer about this account. See ``JournaltopiaPlusState``.
    @Published private(set) var state: JournaltopiaPlusState = .unresolved
    @Published private(set) var product: Product?
    /// Consumable credit packs, loaded for display only. See ``creditPackPurchasing`` — there is no
    /// verified server path to redeem one yet, so nothing here can be bought.
    @Published private(set) var creditPackProducts: [Product] = []
    @Published private(set) var purchasePhase: PurchasePhase = .idle
    @Published private(set) var isReconciling = false
    @Published var errorMessage: String?

    /// The App Store's own localized price string. Never a hardcoded "$14.99": App Store Connect
    /// owns the price, in every currency and territory, and a literal in the app would be wrong for
    /// most of the world and stale for the rest.
    var localizedPrice: String? {
        product?.displayPrice
    }

    var localizedTitle: String? {
        product?.displayName
    }

    private let syncService: AppleSubscriptionSyncService
    private let entitlementService: JournaltopiaPlusEntitlementService
    private var listenerTask: Task<Void, Never>?
    private weak var creditStore: GenerationCreditStore?

    init(
        syncService: AppleSubscriptionSyncService = AppleSubscriptionSyncService(),
        entitlementService: JournaltopiaPlusEntitlementService = JournaltopiaPlusEntitlementService()
    ) {
        self.syncService = syncService
        self.entitlementService = entitlementService
    }

    deinit {
        listenerTask?.cancel()
    }

    /// Lets a completed purchase or renewal refresh the balance it just changed. A read: credits are
    /// granted server-side by the same call that recorded the subscription.
    func attach(creditStore: GenerationCreditStore) {
        self.creditStore = creditStore
    }

    // MARK: - Lifecycle

    /// Starts the one long-lived transaction listener. Called once, at app start.
    ///
    /// `Transaction.updates` delivers everything that happened while nothing was listening,
    /// including purchases completed after the app was killed and renewals processed on Apple's
    /// schedule. This is why a purchase is never considered done on the strength of the purchase
    /// call returning: that call is one delivery route, and the unreliable one.
    func startListeningForTransactions() {
        guard listenerTask == nil else {
            return
        }

        listenerTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else {
                    return
                }

                await self.handle(update)
            }
        }
    }

    /// Loads the product and reconciles whatever Apple already considers current.
    ///
    /// Runs at launch and whenever the account changes. Signed out, there is no account to bind a
    /// subscription to, so the local presentation is reset and nothing is sent — the server's record
    /// is left exactly as it is, because the subscription still exists and still belongs to that
    /// account.
    func refresh(isSignedIn: Bool) async {
        await loadProduct()

        guard isSignedIn else {
            resetLocalState()
            return
        }

        await reconcileCurrentEntitlements()
        await refreshServerEntitlement()
    }

    /// Clears this device's presentation of a subscription without touching the server's record.
    ///
    /// Called on sign-out. The subscription belongs to the Journaltopia account, not to the device, so
    /// signing out forgets what was on screen and nothing else — and the next account to sign in
    /// starts from `.unresolved` rather than inheriting the previous one's entitlement.
    func resetLocalState() {
        state = .signedOut
        purchasePhase = .idle
        isReconciling = false
        errorMessage = nil
    }

    // MARK: - Purchasing

    /// Buys Journaltopia+.
    ///
    /// Returns once Apple has answered. Entitlement itself is *not* established by the return value:
    /// a successful purchase is verified, sent to the server, and only then reflected in `state`,
    /// and a purchase that Apple defers resolves later through the listener.
    @discardableResult
    func purchaseJournaltopiaPlus(isSignedIn: Bool) async -> Bool {
        errorMessage = nil

        // Binding needs an account. Purchasing first and signing in afterwards would leave a paid
        // subscription attached to nothing, which is recoverable only by a restore the user has no
        // reason to know about.
        guard isSignedIn else {
            errorMessage = AppleSubscriptionSyncError.notAuthenticated.localizedDescription
            return false
        }

        guard let product = await resolvedProduct() else {
            errorMessage = "Journaltopia+ is unavailable right now. Please try again."
            return false
        }

        purchasePhase = .purchasing
        defer {
            if purchasePhase == .purchasing {
                purchasePhase = .idle
            }
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                // Verified before it is used, and only ever through StoreKit's own check. An
                // unverified result is discarded rather than sent onward: the server would reject it
                // anyway, and treating it as a purchase here would show a subscribed UI over a
                // signature nobody trusts.
                guard let transaction = verifiedTransaction(from: verification) else {
                    errorMessage = "This purchase could not be verified with Apple."
                    return false
                }

                let synced = await syncAndFinish(transaction, jws: verification.jwsRepresentation)
                await refreshServerEntitlement()
                await creditStore?.refresh(isSignedIn: true)
                return synced

            case .pending:
                // Ask to Buy and similar. Nothing has been bought yet; the listener picks it up if
                // and when it is approved.
                purchasePhase = .awaitingApproval
                return false

            case .userCancelled:
                return false

            @unknown default:
                return false
            }
        } catch {
            print("[Journaltopia] Journaltopia+ purchase failed: \(error)")
            errorMessage = "The purchase could not be completed. Please try again."
            return false
        }
    }

    /// Restores an existing subscription onto this device and re-binds it to the signed-in account.
    ///
    /// `AppStore.sync()` asks Apple to refresh what this Apple ID owns; the reconciliation that
    /// follows is what actually re-establishes entitlement, and it is the same code path launch uses.
    /// Restoring twice is therefore as safe as launching twice — the credit grant behind it is
    /// idempotent per subscription period, so nothing is granted a second time.
    /// Reports which of the three things actually happened, rather than a bare `Bool`. "Nothing to
    /// restore" and "the restore failed" are different messages to show, and collapsing them into
    /// one produces the generic apology this flow is most often criticised for.
    @discardableResult
    func restorePurchases(isSignedIn: Bool) async -> SubscriptionRestoreOutcome {
        errorMessage = nil

        guard isSignedIn else {
            errorMessage = AppleSubscriptionSyncError.notAuthenticated.localizedDescription
            return .notSignedIn
        }

        var syncFailure: Error?
        do {
            try await AppStore.sync()
        } catch {
            // Keep it: a genuine failure and a cancelled authentication prompt both land here, and
            // only the outcome below can tell them apart — if entitlement turns up anyway, the
            // failure did not matter.
            print("[Journaltopia] AppStore.sync() did not complete: \(error)")
            syncFailure = error
        }

        await reconcileCurrentEntitlements()
        await refreshServerEntitlement()
        await creditStore?.refresh(isSignedIn: true)

        if state.isSubscribed {
            return .restored
        }

        // A sync error that left no entitlement behind is worth reporting as a failure; the more
        // specific message from the server sync, if there is one, beats anything invented here.
        if let syncFailure {
            return .failed(errorMessage ?? (syncFailure as? LocalizedError)?.errorDescription
                ?? "Journaltopia could not reach the App Store. Please try again.")
        }

        if let errorMessage {
            return .failed(errorMessage)
        }

        return .nothingToRestore
    }

    // MARK: - Reconciliation

    /// Sends everything Apple currently considers active for this Apple ID to the server.
    ///
    /// This is the recovery path for every case where the purchase callback was not the thing that
    /// delivered the news: the app was killed mid-purchase, the sync failed while offline, the user
    /// signed in on a second device, or the subscription renewed while the app was not running.
    func reconcileCurrentEntitlements() async {
        isReconciling = true
        defer { isReconciling = false }

        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = verifiedTransaction(from: entitlement) else {
                continue
            }

            guard JournaltopiaProducts.subscriptionIdentifiers.contains(transaction.productID) else {
                continue
            }

            _ = await syncAndFinish(transaction, jws: entitlement.jwsRepresentation)
        }
    }

    /// Marks the local entitlement as no longer trustworthy.
    ///
    /// Called when the server refuses a generation with `subscription_required` while this client
    /// still believes it is subscribed — a subscription that lapsed mid-session, or a device that
    /// has not reconciled. Dropping to `.notSubscribed` rather than `.unresolved` on purpose: the
    /// server has given a definite answer, and `.unresolved` would read as "still waiting" and let
    /// the gate wave the next attempt through.
    func markEntitlementStale() {
        guard state.isSubscribed else {
            return
        }

        state = .notSubscribed
    }

    /// Reads the server's answer, which is the only one that governs generation.
    func refreshServerEntitlement() async {
        do {
            state = try await entitlementService.fetchEntitlement()
        } catch {
            // An unreadable answer is not evidence of no subscription. Leaving the previous state in
            // place — including `.unresolved` — keeps a network blip from presenting a paywall to a
            // paying subscriber.
            print("[Journaltopia] Journaltopia+ entitlement refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard let transaction = verifiedTransaction(from: update) else {
            print("[Journaltopia] Ignoring an unverified StoreKit transaction.")
            return
        }

        guard JournaltopiaProducts.subscriptionIdentifiers.contains(transaction.productID) else {
            // Not ours, but still Apple's to be told about, or it is redelivered forever.
            await transaction.finish()
            return
        }

        _ = await syncAndFinish(transaction, jws: update.jwsRepresentation)
        await refreshServerEntitlement()
        await creditStore?.refresh(isSignedIn: true)
    }

    /// Sends a verified transaction to the server and finishes it only if the server accepted it.
    ///
    /// The ordering is the point. `finish()` tells Apple to stop redelivering, so finishing before
    /// the server has recorded the subscription would throw away the only reliable reminder that the
    /// work is outstanding. A sync that fails leaves the transaction unfinished, and Apple hands it
    /// back on the next launch — which is precisely the behaviour wanted when the failure was a dead
    /// network.
    ///
    /// The one exception is a transaction the server rejects for a reason that will never change:
    /// re-delivering a subscription bound to somebody else's account forever helps nobody.
    private func syncAndFinish(_ transaction: Transaction, jws: String) async -> Bool {
        do {
            let result = try await syncService.sync(
                signedTransactionInfo: jws,
                signedRenewalInfo: await renewalInfoJWS(for: transaction)
            )

            await transaction.finish()

            if result.grantedCredits > 0 {
                print("[Journaltopia] Journaltopia+ period granted \(result.grantedCredits) credits.")
            }

            return result.isEntitled
        } catch AppleSubscriptionSyncError.alreadyBoundToAnotherAccount {
            errorMessage = AppleSubscriptionSyncError.alreadyBoundToAnotherAccount.localizedDescription
            await transaction.finish()
            return false
        } catch {
            // Deliberately unfinished. The next launch, foreground, or listener delivery tries again.
            print("[Journaltopia] Journaltopia+ sync deferred: \(error.localizedDescription)")
            errorMessage = (error as? LocalizedError)?.errorDescription
            return false
        }
    }

    /// The signed renewal info for this subscription, when StoreKit has it.
    ///
    /// Optional by design: it only refines the answer — auto-renew state, why something expired — and
    /// the server treats a transaction that verifies without it as fully trustworthy.
    private func renewalInfoJWS(for transaction: Transaction) async -> String? {
        // Resolved in two steps rather than with `??`: the operator takes an autoclosure, which
        // cannot carry an `await`.
        var subscriptionProduct = product
        if subscriptionProduct == nil {
            subscriptionProduct = try? await Product.products(for: [transaction.productID]).first
        }

        guard
            let subscriptionProduct,
            let statuses = try? await subscriptionProduct.subscription?.status
        else {
            return nil
        }

        let matching = statuses.first { status in
            guard case .verified(let renewal) = status.renewalInfo else {
                return false
            }

            return renewal.currentProductID == transaction.productID
        }

        guard let renewalInfo = matching?.renewalInfo else {
            return nil
        }

        return renewalInfo.jwsRepresentation
    }

    private func resolvedProduct() async -> Product? {
        if let product {
            return product
        }

        await loadProduct()
        return product
    }

    private func loadProduct() async {
        guard product == nil || creditPackProducts.isEmpty else {
            return
        }

        do {
            let products = try await Product.products(
                for: JournaltopiaProducts.subscriptionIdentifiers + JournaltopiaProducts.creditPackIdentifiers
            )
            product = products.first { $0.id == JournaltopiaProducts.journaltopiaPlusMonthly }

            // Ordered by the pack list rather than by whatever StoreKit returns, so the screen does
            // not reshuffle between launches.
            creditPackProducts = JournaltopiaProducts.creditPackIdentifiers.compactMap { identifier in
                products.first { $0.id == identifier }
            }
        } catch {
            print("[Journaltopia] Journaltopia+ product load failed: \(error.localizedDescription)")
        }
    }

    /// StoreKit's verification result, reduced to "trustworthy or not".
    ///
    /// `.unverified` is never unwrapped for use. It is the case where a transaction failed Apple's
    /// own signature check, and the only correct response is to behave as though it is not there.
    private func verifiedTransaction(from result: VerificationResult<Transaction>) -> Transaction? {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            print("[Journaltopia] StoreKit verification failed: \(error.localizedDescription)")
            return nil
        }
    }
}
