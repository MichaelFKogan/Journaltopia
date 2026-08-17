// Apple subscription verification and the mapping from Apple's vocabulary to Journaltopia's.
//
// Shared by sync-apple-subscription (a signed-in client reporting its own purchase) and
// apple-subscription-notifications (Apple reporting a renewal, expiry or revocation with no client
// involved). Both arrive as JWS, both have to be verified the same way, and both end at the same
// database function — so the verification and the mapping live here rather than being written twice
// and drifting.
//
// Verification uses Apple's own library. A signed transaction is not a JWT to be decoded: it is a
// JWS whose x5c header carries a certificate chain that has to be validated up to Apple's root, with
// the leaf's signature checked over the payload. Reading the claims without doing that would accept
// anything a client cared to sign for itself, which is the whole attack this endpoint exists to
// stop.
import {
  AutoRenewStatus,
  Environment,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@1.6.0";
// The decoded payload shapes, used rather than a structural stand-in so the fields this file reads
// are the fields Apple actually documents — a renamed or mistyped one fails to compile instead of
// silently reading undefined and producing a subscription with no period.
import type {
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
} from "npm:@apple/app-store-server-library@1.6.0";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
// Apple's library is written against Node's Buffer. Deno provides it through the node compat
// specifier rather than as a global, so it is imported explicitly.
import { Buffer } from "node:buffer";

export class AppleSubscriptionFailure extends Error {
  readonly status: number;
  readonly code: string;

  constructor(message: string, status = 400, code = "apple_verification_failed") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/// Apple's root certificates, supplied as configuration rather than embedded.
///
/// These are public certificates, not secrets, but they are also the trust anchor for every
/// entitlement decision the server makes — so they are read from the environment where they can be
/// rotated and audited, instead of being pasted into source where a wrong byte would be invisible.
///
/// APPLE_ROOT_CA_G3_BASE64 holds the base64 DER of Apple Root CA - G3, downloaded from
/// https://www.apple.com/certificateauthority/. Multiple roots may be given, comma separated.
export function appleRootCertificates(): Uint8Array[] {
  const configured = Deno.env.get("APPLE_ROOT_CA_G3_BASE64");
  if (!configured) {
    throw new AppleSubscriptionFailure(
      "Apple subscription verification is not configured.",
      500,
      "not_configured",
    );
  }

  const roots = configured
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
    .map((value) => {
      try {
        return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
      } catch {
        throw new AppleSubscriptionFailure(
          "Apple root certificate configuration is not valid base64.",
          500,
          "not_configured",
        );
      }
    });

  if (roots.length === 0) {
    throw new AppleSubscriptionFailure(
      "Apple subscription verification is not configured.",
      500,
      "not_configured",
    );
  }

  return roots;
}

export function appleBundleID(): string {
  const bundleID = Deno.env.get("APPLE_BUNDLE_ID");
  if (!bundleID) {
    throw new AppleSubscriptionFailure(
      "Apple subscription verification is not configured.",
      500,
      "not_configured",
    );
  }

  return bundleID;
}

/// Apple's numeric app id. Required by the verifier for Production, which is why a misconfigured
/// deployment fails here rather than silently verifying sandbox data in production.
function appleAppID(environment: Environment): number | undefined {
  const raw = Deno.env.get("APPLE_APP_APPLE_ID");
  if (!raw) {
    if (environment === Environment.PRODUCTION) {
      throw new AppleSubscriptionFailure(
        "Apple subscription verification is not configured for production.",
        500,
        "not_configured",
      );
    }

    return undefined;
  }

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) {
    throw new AppleSubscriptionFailure(
      "APPLE_APP_APPLE_ID must be numeric.",
      500,
      "not_configured",
    );
  }

  return parsed;
}

/// Online checks ask Apple whether the signing certificates have been revoked. On by default and
/// switchable off only for local testing, where there is no route to Apple's OCSP responder.
function enableOnlineChecks(): boolean {
  return (Deno.env.get("APPLE_VERIFICATION_ONLINE_CHECKS") ?? "true").toLowerCase() !== "false";
}

export function environmentFromName(name: string | undefined): Environment {
  return (name ?? "").toLowerCase() === "production"
    ? Environment.PRODUCTION
    : Environment.SANDBOX;
}

export function verifierFor(environment: Environment): SignedDataVerifier {
  return new SignedDataVerifier(
    appleRootCertificates().map((root) => Buffer.from(root)),
    enableOnlineChecks(),
    environment,
    appleBundleID(),
    appleAppID(environment),
  );
}

/// The products this server sells, and what each one is.
///
/// Both endpoints classify before they act. A subscription transaction and a consumable transaction
/// look almost identical coming off the wire and mean entirely different things, and the notification
/// endpoint receives both — so "which of our products is this?" has one answer, here, rather than a
/// pair of divergent guesses.
export const JOURNALTOPIA_SUBSCRIPTION_PRODUCT_IDS = ["com.journaltopia.plus.monthly"];

export const JOURNALTOPIA_CREDIT_PACK_PRODUCT_IDS = [
  "com.journaltopia.credits.10",
  "com.journaltopia.credits.25",
  "com.journaltopia.credits.60",
];

export type JournaltopiaProductKind = "subscription" | "credit_pack" | "unknown";

export function classifyProduct(productID: string | undefined): JournaltopiaProductKind {
  if (!productID) {
    return "unknown";
  }

  if (JOURNALTOPIA_SUBSCRIPTION_PRODUCT_IDS.includes(productID)) {
    return "subscription";
  }

  if (JOURNALTOPIA_CREDIT_PACK_PRODUCT_IDS.includes(productID)) {
    return "credit_pack";
  }

  // Anything else — a product from a future build, a test transaction, something that is not ours at
  // all — is deliberately inert. It must never reach a balance or an entitlement.
  return "unknown";
}

export type VerifiedSubscription = {
  productID: string;
  originalTransactionID: string;
  latestTransactionID: string | null;
  status: "active" | "expired" | "revoked" | "billing_retry";
  periodStart: string;
  periodEnd: string;
  autoRenewStatus: boolean | null;
  environment: "sandbox" | "production";
};

/// Verifies a signed transaction and, optionally, its renewal info, and reduces the two to the row
/// Journaltopia stores.
///
/// A transaction is tried against both environments because a build can be pointed at either and the
/// caller does not get to tell us which — sandbox receipts presented as production is a standard
/// confusion, and the environment is taken from whichever verification actually succeeds rather than
/// from anything the caller said.
export async function verifySignedTransaction(
  signedTransactionInfo: string,
  signedRenewalInfo: string | null,
): Promise<VerifiedSubscription> {
  if (typeof signedTransactionInfo !== "string" || signedTransactionInfo.length === 0) {
    throw new AppleSubscriptionFailure("Missing signed transaction.", 400, "missing_transaction");
  }

  const attempts: Environment[] = [Environment.PRODUCTION, Environment.SANDBOX];
  let lastError: unknown;

  for (const environment of attempts) {
    try {
      const verifier = verifierFor(environment);
      const transaction = await verifier.verifyAndDecodeTransaction(signedTransactionInfo);

      let renewal = null;
      if (signedRenewalInfo) {
        try {
          renewal = await verifier.verifyAndDecodeRenewalInfo(signedRenewalInfo);
        } catch (error) {
          // Renewal info only refines the answer — auto-renew state, an expiry reason. A transaction
          // that verified is still trustworthy without it, so this is logged rather than fatal.
          console.warn("[apple-subscription] renewal info did not verify; continuing:", error);
        }
      }

      return toVerifiedSubscription(transaction, renewal, environment);
    } catch (error) {
      if (error instanceof AppleSubscriptionFailure) {
        throw error;
      }

      lastError = error;
    }
  }

  console.error("[apple-subscription] transaction verification failed:", lastError);
  throw new AppleSubscriptionFailure(
    "This purchase could not be verified with Apple.",
    401,
    "verification_failed",
  );
}

/// Maps Apple's state onto the four statuses Journaltopia stores. Only `active` entitles, and it is
/// deliberately the narrowest reading: an expiry date in the past, a revocation, or an upgrade that
/// superseded this transaction all fall out of it.
export function toVerifiedSubscription(
  transaction: JWSTransactionDecodedPayload,
  renewal: JWSRenewalInfoDecodedPayload | null,
  environment: Environment,
): VerifiedSubscription {
  const productID = transaction.productId;
  const originalTransactionID = transaction.originalTransactionId;

  if (!productID || !originalTransactionID) {
    throw new AppleSubscriptionFailure(
      "Apple returned a transaction Journaltopia could not read.",
      400,
      "unreadable_transaction",
    );
  }

  // Every date on the payload is optional in Apple's schema, so each is checked rather than assumed.
  const purchaseDate = transaction.purchaseDate;
  const expiresDate = transaction.expiresDate;
  const revocationDate = transaction.revocationDate;

  if (purchaseDate === undefined || expiresDate === undefined) {
    throw new AppleSubscriptionFailure(
      "Apple returned a subscription with no period.",
      400,
      "unreadable_transaction",
    );
  }

  // Absent means Apple did not tell us, which is different from "off" — a subscription with no
  // renewal info attached must not be read as one the user cancelled.
  const autoRenewStatus = renewal?.autoRenewStatus === undefined
    ? null
    : renewal.autoRenewStatus === AutoRenewStatus.ON;

  let status: VerifiedSubscription["status"];
  // `undefined`, not `null`: these come straight off Apple's optional payload fields. Comparing
  // against null here read every absent revocation date as a revocation, which marked every
  // subscription revoked and entitled nobody.
  if (revocationDate !== undefined) {
    status = "revoked";
  } else if (expiresDate <= Date.now()) {
    // Apple keeps retrying a failed renewal for a while. Distinguishing that from a clean lapse
    // changes nothing about entitlement — neither entitles — but it is the difference between "your
    // card was declined" and "you cancelled" when the app eventually explains itself.
    status = autoRenewStatus === true ? "billing_retry" : "expired";
  } else {
    status = "active";
  }

  return {
    productID,
    originalTransactionID,
    latestTransactionID: transaction.transactionId ?? null,
    status,
    periodStart: new Date(purchaseDate).toISOString(),
    periodEnd: new Date(expiresDate).toISOString(),
    autoRenewStatus,
    environment: environment === Environment.PRODUCTION ? "production" : "sandbox",
  };
}

export type SyncOutcome = {
  subscriptionID: string | null;
  isEntitled: boolean;
  status: string;
  granted: number;
  balance: number | null;
  alreadyGranted: boolean;
  conflict: string | null;
};

/// Hands verified Apple state to the database, which owns binding, status and the credit grant.
///
/// `account` is null for the notification path, where there is no signed-in caller and the owner is
/// taken from the subscription row Apple's identity already points at.
export async function applyVerifiedSubscription(
  client: SupabaseClient,
  account: string | null,
  subscription: VerifiedSubscription,
): Promise<SyncOutcome> {
  const { data, error } = await client.rpc("sync_apple_subscription", {
    account,
    apple_product_id: subscription.productID,
    apple_original_transaction_id: subscription.originalTransactionID,
    apple_latest_transaction_id: subscription.latestTransactionID,
    apple_status: subscription.status,
    period_start: subscription.periodStart,
    period_end: subscription.periodEnd,
    apple_auto_renew: subscription.autoRenewStatus,
    apple_environment: subscription.environment,
  });

  if (error) {
    console.error("[apple-subscription] sync_apple_subscription failed:", error.message);
    throw new AppleSubscriptionFailure(
      "Your subscription could not be recorded. Please try again.",
      500,
      "sync_failed",
    );
  }

  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | null;
  if (!row) {
    throw new AppleSubscriptionFailure(
      "Your subscription could not be recorded. Please try again.",
      500,
      "sync_failed",
    );
  }

  return {
    subscriptionID: (row.subscription_id as string | null) ?? null,
    isEntitled: row.is_entitled === true,
    status: (row.resulting_status as string) ?? "expired",
    granted: typeof row.granted === "number" ? row.granted : 0,
    balance: typeof row.balance === "number" ? row.balance : null,
    alreadyGranted: row.already_granted === true,
    conflict: (row.conflict as string | null) ?? null,
  };
}

export type ReversalOutcome = {
  reclaimed: number;
  originallyGranted: number;
  purchasedBalance: number | null;
  alreadyReversed: boolean;
  conflict: string | null;
};

/// Hands a refunded consumable to the database, which owns the clamping and the idempotency.
///
/// Nothing about how many credits to remove is decided here. The amount comes from the ledger entry
/// the original redemption wrote, clamped to what the balance still holds, inside one transaction.
export async function reverseCreditPackPurchase(
  client: SupabaseClient,
  appleTransactionID: string,
): Promise<ReversalOutcome> {
  const { data, error } = await client.rpc("reverse_credit_pack_purchase", {
    apple_transaction_id: appleTransactionID,
  });

  if (error) {
    console.error("[apple-subscription] reverse_credit_pack_purchase failed:", error.message);
    throw new AppleSubscriptionFailure(
      "The refund could not be recorded.",
      500,
      "reversal_failed",
    );
  }

  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | null;
  if (!row) {
    throw new AppleSubscriptionFailure("The refund could not be recorded.", 500, "reversal_failed");
  }

  return {
    reclaimed: typeof row.reclaimed === "number" ? row.reclaimed : 0,
    originallyGranted: typeof row.originally_granted === "number" ? row.originally_granted : 0,
    purchasedBalance: typeof row.purchased_balance === "number" ? row.purchased_balance : null,
    alreadyReversed: row.already_reversed === true,
    conflict: (row.conflict as string | null) ?? null,
  };
}

/// Writing entitlement is a server action, so it runs with server authority. The caller's own client
/// is used for authentication only, never for the write.
export function serviceRoleClient(): SupabaseClient {
  const projectURL = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!projectURL || !key) {
    throw new AppleSubscriptionFailure(
      "Subscription syncing is not configured.",
      500,
      "not_configured",
    );
  }

  return createClient(projectURL, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
