// App Store Server Notifications V2.
//
// Apple posts here when a subscription changes without the app being involved: a renewal charged at
// 3am, a card that failed, a refund, a cancellation. Without this endpoint the server only learns
// about a subscription when the app next opens, which means a renewal's credits arrive late and an
// expiry is honoured late — and a lapsed subscriber keeps generating until they relaunch.
//
// There is no Supabase session on this request and there cannot be one: the caller is Apple. The
// authentication is the signature. The notification is a JWS whose certificate chain is validated to
// Apple's root exactly as a client-reported transaction is, and the subscription is located by the
// original transaction id inside the *verified* payload — never by anything in the URL or an
// unverified body field.
import {
  AppleSubscriptionFailure,
  applyVerifiedSubscription,
  environmentFromName,
  serviceRoleClient,
  toVerifiedSubscription,
  verifierFor,
} from "../_shared/apple-subscription.ts";
import { jsonResponse } from "../_shared/storyboard-generation.ts";
// Apple's own decoded-notification shape. Every field on it is optional, which is why the logging
// below tolerates a missing notificationType rather than asserting one.
import type { ResponseBodyV2DecodedPayload } from "npm:@apple/app-store-server-library@1.6.0";

type NotificationRequest = {
  signedPayload?: string;
};

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
    const { notification, verified } = await verifyNotification(signedPayload);

    // Notifications that carry no transaction — Apple's test ping, and the consumption request
    // family — are acknowledged rather than treated as failures, or Apple will retry them forever.
    if (!verified) {
      console.log(
        `[apple-subscription-notifications] ${notification.notificationType}/${notification.subtype ?? "-"}: nothing to apply.`,
      );
      return jsonResponse({ received: true, applied: false });
    }

    // `account` is null here: nobody is signed in, so the owner comes from the subscription row
    // Apple's identity already points at. A notification for a subscription no account has synced
    // reports `unknown_subscription` and is acknowledged — the client sync will bind it when that
    // user next opens the app, and retrying delivery would not change anything.
    const outcome = await applyVerifiedSubscription(serviceRoleClient(), null, verified);

    if (outcome.conflict) {
      console.log(
        `[apple-subscription-notifications] ${notification.notificationType}: ${outcome.conflict} for ${verified.originalTransactionID}.`,
      );
      return jsonResponse({ received: true, applied: false, code: outcome.conflict });
    }

    console.log(
      `[apple-subscription-notifications] ${notification.notificationType}/${notification.subtype ?? "-"}` +
        ` -> ${outcome.status}, granted ${outcome.granted}.`,
    );

    // The same idempotent grant path the client sync uses, so whichever observes a renewal first
    // wins and the other is a no-op.
    return jsonResponse({
      received: true,
      applied: true,
      status: outcome.status,
      grantedCredits: outcome.granted,
      alreadyGranted: outcome.alreadyGranted,
    });
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

/// Verifies the notification envelope and the signed transaction inside it.
///
/// Both environments are attempted for the same reason the client path attempts both: the sandbox
/// and production notification URLs are configured separately in App Store Connect, and a
/// misconfiguration should surface as a verification failure rather than as silently trusted data.
async function verifyNotification(signedPayload: string): Promise<{
  notification: ResponseBodyV2DecodedPayload;
  verified: ReturnType<typeof toVerifiedSubscription> | null;
}> {
  const environments = [
    environmentFromName("production"),
    environmentFromName("sandbox"),
  ];

  let lastError: unknown;

  for (const environment of environments) {
    try {
      const verifier = verifierFor(environment);
      const notification = await verifier.verifyAndDecodeNotification(signedPayload);

      const signedTransactionInfo = notification.data?.signedTransactionInfo;
      if (!signedTransactionInfo) {
        return { notification, verified: null };
      }

      // Verified again in its own right. The envelope being genuine does not make its contents
      // genuine, and Apple signs the transaction separately precisely so it can be checked on its
      // own terms.
      const transaction = await verifier.verifyAndDecodeTransaction(signedTransactionInfo);

      let renewal = null;
      if (notification.data?.signedRenewalInfo) {
        try {
          renewal = await verifier.verifyAndDecodeRenewalInfo(notification.data.signedRenewalInfo);
        } catch (error) {
          console.warn("[apple-subscription-notifications] renewal info did not verify:", error);
        }
      }

      return {
        notification,
        verified: toVerifiedSubscription(transaction, renewal, environment),
      };
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
