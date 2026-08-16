// Binds a verified Apple subscription to the signed-in Journaltopia account.
//
// Called by the app after a purchase, after a restore, and on launch reconciliation. All three send
// the same thing — the signed transaction Apple gave StoreKit — and all three are safe to repeat:
// the credit grant behind this is idempotent per subscription period, so a listener, a relaunch and
// a server notification can all report the same renewal without granting it three times.
//
// Two independent facts are required before entitlement is written, and neither substitutes for the
// other:
//
//   who is asking      the caller's Supabase JWT, verified here
//   what they bought   Apple's signature over the transaction, verified against Apple's root
//
// The client never sends its own user id, a product id, an expiry date, or anything resembling
// "isSubscribed". Everything written to the subscriptions table is read out of the payload Apple
// signed.
import {
  AppleSubscriptionFailure,
  applyVerifiedSubscription,
  serviceRoleClient,
  verifySignedTransaction,
} from "../_shared/apple-subscription.ts";
import { authenticateCaller, jsonResponse } from "../_shared/storyboard-generation.ts";

type SyncRequest = {
  signedTransactionInfo?: string;
  signedRenewalInfo?: string;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    // Reuses the storyboard functions' authentication: an anon-key client carrying the caller's
    // bearer token, so the identity comes from a verified JWT rather than from the request body.
    const { userID } = await authenticateCaller(request);

    let payload: SyncRequest;
    try {
      payload = await request.json();
    } catch {
      throw new AppleSubscriptionFailure("Invalid JSON body.", 400, "invalid_body");
    }

    const verified = await verifySignedTransaction(
      payload.signedTransactionInfo ?? "",
      payload.signedRenewalInfo ?? null,
    );

    const outcome = await applyVerifiedSubscription(serviceRoleClient(), userID, verified);

    // The Apple subscription already belongs to a different Journaltopia account. Reported as a
    // structured 409 rather than an opaque failure, because the app has to say something specific
    // about it and there is no safe automatic resolution: re-pointing the row would take an active
    // subscription away from whoever is using it.
    if (outcome.conflict === "already_bound_to_another_account") {
      return jsonResponse(
        {
          error: "This Apple subscription is already linked to a different Journaltopia account.",
          code: outcome.conflict,
          isEntitled: false,
        },
        409,
      );
    }

    return jsonResponse({
      isEntitled: outcome.isEntitled,
      status: outcome.status,
      productID: verified.productID,
      currentPeriodEnd: verified.periodEnd,
      environment: verified.environment,
      grantedCredits: outcome.granted,
      creditBalance: outcome.balance,
      alreadyGranted: outcome.alreadyGranted,
    });
  } catch (error) {
    if (error instanceof AppleSubscriptionFailure) {
      return jsonResponse({ error: error.message, code: error.code }, error.status);
    }

    // authenticateCaller raises StoryboardFailure, which carries its own status and a message
    // already written for a reader.
    const status = (error as { status?: number })?.status;
    if (typeof status === "number") {
      return jsonResponse({ error: (error as Error).message, code: "unauthorized" }, status);
    }

    console.error("[sync-apple-subscription] unexpected failure:", error);
    return jsonResponse(
      { error: "Your subscription could not be synced.", code: "unexpected" },
      500,
    );
  }
});
