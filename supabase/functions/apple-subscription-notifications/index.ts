// App Store Server Notifications V2.
//
// Apple posts here when something changes without the app being involved: a renewal charged at 3am,
// a card that failed, a refund granted days later, a subscription revoked. Without this endpoint the
// server only learns about any of it when the app next opens — so a renewal's credits arrive late, a
// lapsed subscriber keeps generating until they relaunch, and a refunded credit pack is never
// clawed back at all.
//
// There is no Supabase session on this request and there cannot be one: the caller is Apple. The
// authentication is the signature. The notification is a JWS whose certificate chain is validated to
// Apple's root, the transaction inside it is verified separately on its own terms, and every value
// acted on below comes out of those verified payloads — never from the URL, the headers, or an
// unverified body field.
//
// The endpoint carries two unrelated kinds of traffic, and the first thing it does is tell them
// apart:
//
//   subscription   Journaltopia+ — entitlement, periods, the monthly credit grant
//   credit pack    a consumable — the purchased bucket, and refunds against it
//   unknown        acknowledged and ignored; it must never reach a balance
//
// Mixing those up is the failure this routing exists to prevent. A consumable refund must not cancel
// anyone's subscription, and a subscription refund must not delete credits somebody bought
// separately.
import {
  AppleSubscriptionFailure,
  applyVerifiedSubscription,
  classifyProduct,
  environmentFromName,
  reverseCreditPackPurchase,
  serviceRoleClient,
  toVerifiedSubscription,
  verifierFor,
} from "../_shared/apple-subscription.ts";
import { jsonResponse } from "../_shared/storyboard-generation.ts";
import type {
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
  ResponseBodyV2DecodedPayload,
} from "npm:@apple/app-store-server-library@1.6.0";
import { Environment } from "npm:@apple/app-store-server-library@1.6.0";

type NotificationRequest = {
  signedPayload?: string;
};

/// The notification types that mean money went back to the customer. `REFUND` is the ordinary case;
/// `REVOKE` is Family Sharing access being withdrawn. Both should take back what they granted.
///
/// `REFUND_REVERSED` — Apple undoing a refund it previously granted — is deliberately *not* here.
/// Re-granting credits automatically would need its own idempotency story, and getting it wrong
/// hands out free credits; it is logged for a human instead.
const REVERSAL_NOTIFICATION_TYPES = new Set(["REFUND", "REVOKE"]);

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  let signedPayload: string;
  try {
    const body = (await request.json()) as NotificationRequest;
    signedPayload = body.signedPayload ?? "";
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400);
  }

  if (!signedPayload) {
    return jsonResponse({ error: "Missing signedPayload." }, 400);
  }

  try {
    const verified = await verifyNotification(signedPayload);
    const { notification, transaction, renewal, environment } = verified;
    const label = `${notification.notificationType ?? "?"}/${notification.subtype ?? "-"}`;

    // Notifications that carry no transaction — Apple's TEST ping, consumption requests — are
    // acknowledged rather than treated as failures, or Apple retries them for days.
    if (!transaction) {
      console.log(`[apple-subscription-notifications] ${label}: nothing to apply.`);
      return jsonResponse({ received: true, applied: false, reason: "no-transaction" });
    }

    const kind = classifyProduct(transaction.productId);
    const client = serviceRoleClient();

    if (kind === "unknown") {
      // Not one of our products. Acknowledged so Apple stops, and pointedly not acted on: there is
      // no balance or entitlement this could correctly touch.
      console.log(
        `[apple-subscription-notifications] ${label}: ignoring unknown product ${transaction.productId}.`,
      );
      return jsonResponse({ received: true, applied: false, reason: "unknown-product" });
    }

    if (kind === "credit_pack") {
      return await handleCreditPackNotification(client, notification, transaction, label);
    }

    return await handleSubscriptionNotification(client, transaction, renewal, environment, label);
  } catch (error) {
    if (error instanceof AppleSubscriptionFailure) {
      // 401 for a signature that did not verify: Apple should not retry something it cannot sign
      // acceptably, and a 5xx would have it retrying for days.
      const status = error.code === "not_configured" ? 500 : 401;
      return jsonResponse({ error: error.message, code: error.code }, status);
    }

    // Anything else may be transient — a database blip, a cold start — and Apple's retry schedule is
    // the right recovery, so this deliberately answers 500.
    console.error("[apple-subscription-notifications] unexpected failure:", error);
    return jsonResponse({ error: "Notification could not be processed." }, 500);
  }
});

/// Consumables: only refunds and revocations do anything.
///
/// A consumable has no period and no entitlement, so there is nothing to "sync" — the purchase was
/// already redeemed by `redeem-credit-purchase` when the app reported it. The only thing left for a
/// notification to say is that the money came back.
async function handleCreditPackNotification(
  client: ReturnType<typeof serviceRoleClient>,
  notification: ResponseBodyV2DecodedPayload,
  transaction: JWSTransactionDecodedPayload,
  label: string,
): Promise<Response> {
  const notificationType = notification.notificationType ?? "";

  if (!REVERSAL_NOTIFICATION_TYPES.has(notificationType)) {
    console.log(`[apple-subscription-notifications] ${label}: credit pack notification with nothing to do.`);
    return jsonResponse({ received: true, applied: false, reason: "not-a-reversal" });
  }

  // The same identity `redeem-credit-purchase` recorded the grant under, so the reversal finds its
  // own grant rather than searching by user and product and hoping.
  const transactionID = transaction.transactionId ?? transaction.originalTransactionId;
  if (!transactionID) {
    console.log(`[apple-subscription-notifications] ${label}: refund with no transaction id.`);
    return jsonResponse({ received: true, applied: false, reason: "no-transaction-id" });
  }

  const outcome = await reverseCreditPackPurchase(client, transactionID);

  // A refund for a pack this server never redeemed. Acknowledged: retrying cannot make a grant
  // appear, and the customer keeps nothing they were not given.
  if (outcome.conflict === "unknown_transaction") {
    console.log(`[apple-subscription-notifications] ${label}: no redemption found for ${transactionID}.`);
    return jsonResponse({ received: true, applied: false, reason: outcome.conflict });
  }

  console.log(
    `[apple-subscription-notifications] ${label}: reclaimed ${outcome.reclaimed} of ` +
      `${outcome.originallyGranted} credits for ${transactionID}` +
      (outcome.alreadyReversed ? " (already reversed)" : ""),
  );

  return jsonResponse({
    received: true,
    applied: !outcome.alreadyReversed,
    reclaimedCredits: outcome.reclaimed,
    originallyGranted: outcome.originallyGranted,
    alreadyReversed: outcome.alreadyReversed,
  });
}

/// Subscriptions: unchanged from before the split. Entitlement, periods and the idempotent monthly
/// grant, all decided by `sync_apple_subscription`.
async function handleSubscriptionNotification(
  client: ReturnType<typeof serviceRoleClient>,
  transaction: JWSTransactionDecodedPayload,
  renewal: JWSRenewalInfoDecodedPayload | null,
  environment: Environment,
  label: string,
): Promise<Response> {
  const verified = toVerifiedSubscription(transaction, renewal, environment);

  // `account` is null here: nobody is signed in, so the owner comes from the subscription row Apple's
  // identity already points at. A notification for a subscription no account has synced reports
  // `unknown_subscription` and is acknowledged — the client sync binds it when that user next opens
  // the app, and retrying would not change anything.
  const outcome = await applyVerifiedSubscription(client, null, verified);

  if (outcome.conflict) {
    console.log(`[apple-subscription-notifications] ${label}: ${outcome.conflict} for ${verified.originalTransactionID}.`);
    return jsonResponse({ received: true, applied: false, code: outcome.conflict });
  }

  console.log(
    `[apple-subscription-notifications] ${label} -> ${outcome.status}, granted ${outcome.granted}.`,
  );

  return jsonResponse({
    received: true,
    applied: true,
    status: outcome.status,
    grantedCredits: outcome.granted,
    alreadyGranted: outcome.alreadyGranted,
  });
}

/// Verifies the notification envelope and the signed transaction inside it, and hands back the
/// decoded payloads *unmapped*.
///
/// Deliberately does not reduce the transaction to a subscription shape: a consumable has no expiry
/// date, and forcing one through that mapping is how a credit-pack refund used to end up rejected as
/// "a subscription with no period" and retried by Apple forever. Classification happens after
/// verification, on the raw payload.
async function verifyNotification(signedPayload: string): Promise<{
  notification: ResponseBodyV2DecodedPayload;
  transaction: JWSTransactionDecodedPayload | null;
  renewal: JWSRenewalInfoDecodedPayload | null;
  environment: Environment;
}> {
  // Both environments are attempted for the same reason the client path attempts both: sandbox and
  // production notification URLs are configured separately in App Store Connect, and a
  // misconfiguration should surface as a verification failure rather than as silently trusted data.
  const environments = [environmentFromName("production"), environmentFromName("sandbox")];
  let lastError: unknown;

  for (const environment of environments) {
    try {
      const verifier = verifierFor(environment);
      const notification = await verifier.verifyAndDecodeNotification(signedPayload);

      const signedTransactionInfo = notification.data?.signedTransactionInfo;
      if (!signedTransactionInfo) {
        return { notification, transaction: null, renewal: null, environment };
      }

      // Verified again in its own right. The envelope being genuine does not make its contents
      // genuine, and Apple signs the transaction separately precisely so it can be checked alone.
      const transaction = await verifier.verifyAndDecodeTransaction(signedTransactionInfo);

      let renewal: JWSRenewalInfoDecodedPayload | null = null;
      if (notification.data?.signedRenewalInfo) {
        try {
          renewal = await verifier.verifyAndDecodeRenewalInfo(notification.data.signedRenewalInfo);
        } catch (error) {
          console.warn("[apple-subscription-notifications] renewal info did not verify:", error);
        }
      }

      return { notification, transaction, renewal, environment };
    } catch (error) {
      if (error instanceof AppleSubscriptionFailure && error.code === "not_configured") {
        throw error;
      }

      lastError = error;
    }
  }

  console.error("[apple-subscription-notifications] notification verification failed:", lastError);
  throw new AppleSubscriptionFailure(
    "The notification could not be verified with Apple.",
    401,
    "verification_failed",
  );
}
