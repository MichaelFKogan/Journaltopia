// Turns a verified Apple consumable purchase into purchased credits.
//
// The same two-fact rule the subscription sync uses, for the same reason:
//
//   who is asking      the caller's Supabase JWT, verified here
//   what they bought   Apple's signature over the transaction, verified against Apple's root
//
// The client sends one thing — the JWS StoreKit handed it — and nothing else. Not a user id, not a
// product id, and above all not an amount. The product comes out of the payload Apple signed, and
// the number of credits it is worth is decided in the database by
// `credit_pack_credit_amount`. There is no path by which a client names its own price.
import {
  AppleSubscriptionFailure,
  serviceRoleClient,
  verifySignedTransaction,
} from "../_shared/apple-subscription.ts";
import { authenticateCaller, jsonResponse } from "../_shared/storyboard-generation.ts";

type RedeemRequest = {
  signedTransactionInfo?: string;
};

type RedeemOutcome = {
  credits_granted: number;
  monthly_balance: number;
  purchased_balance: number;
  already_redeemed: boolean;
  conflict: string | null;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const { userID } = await authenticateCaller(request);

    let payload: RedeemRequest;
    try {
      payload = await request.json();
    } catch {
      throw new AppleSubscriptionFailure("Invalid JSON body.", 400, "invalid_body");
    }

    // Verified by exactly the same code path as a subscription transaction: certificate chain to
    // Apple's root, signature over the payload, bundle id checked. A consumable is not a lesser
    // kind of purchase.
    const verified = await verifySignedTransaction(payload.signedTransactionInfo ?? "", null);

    const client = serviceRoleClient();
    const { data, error } = await client.rpc("redeem_credit_pack", {
      account: userID,
      apple_transaction_id: verified.latestTransactionID ?? verified.originalTransactionID,
      apple_product_id: verified.productID,
    });

    if (error) {
      console.error("[redeem-credit-purchase] redeem_credit_pack failed:", error.message);
      throw new AppleSubscriptionFailure(
        "Your credits could not be added. Please try again.",
        500,
        "redemption_failed",
      );
    }

    const outcome = (Array.isArray(data) ? data[0] : data) as RedeemOutcome | null;
    if (!outcome) {
      throw new AppleSubscriptionFailure(
        "Your credits could not be added. Please try again.",
        500,
        "redemption_failed",
      );
    }

    // Packs are a subscriber benefit, and the database is where that is decided. 403 rather than a
    // generic failure so the app can raise the paywall instead of an apology.
    if (outcome.conflict === "subscription_required") {
      return jsonResponse(
        {
          error: "Credit packs are available to Journaltopia+ members.",
          code: "subscription_required",
          creditsGranted: 0,
        },
        403,
      );
    }

    // Bought on another Journaltopia account. Nothing was credited, and retrying will never help —
    // reported as a settled outcome so the client finishes the transaction rather than looping.
    if (outcome.conflict === "already_redeemed_by_another_account") {
      return jsonResponse(
        {
          error: "This purchase has already been added to a different Journaltopia account.",
          code: outcome.conflict,
          creditsGranted: 0,
        },
        409,
      );
    }

    // A product this server does not sell. Also settled: nothing to retry.
    if (outcome.conflict === "unknown_product") {
      return jsonResponse(
        {
          error: "This purchase is not a Journaltopia credit pack.",
          code: outcome.conflict,
          creditsGranted: 0,
        },
        422,
      );
    }

    return jsonResponse({
      creditsGranted: outcome.credits_granted,
      alreadyRedeemed: outcome.already_redeemed,
      monthlyCredits: outcome.monthly_balance,
      purchasedCredits: outcome.purchased_balance,
      totalCredits: outcome.monthly_balance + outcome.purchased_balance,
      productID: verified.productID,
    });
  } catch (error) {
    if (error instanceof AppleSubscriptionFailure) {
      return jsonResponse({ error: error.message, code: error.code }, error.status);
    }

    const status = (error as { status?: number })?.status;
    if (typeof status === "number") {
      return jsonResponse({ error: (error as Error).message, code: "unauthorized" }, status);
    }

    console.error("[redeem-credit-purchase] unexpected failure:", error);
    return jsonResponse({ error: "Your credits could not be added.", code: "unexpected" }, 500);
  }
});
