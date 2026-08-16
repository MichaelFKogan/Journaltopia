// Apple subscription verification and mapping.
//
// Run with: deno test --allow-env supabase/functions/_shared/apple-subscription_test.ts
//
// Two kinds of assertion live here, and the difference matters:
//
//   the mapping    Apple's vocabulary reduced to Journaltopia's four statuses. Pure logic, fully
//                  tested, and the place a subtle mistake would silently entitle the wrong people.
//
//   the rejection  that forged or malformed data is refused. Testable in the true direction only:
//                  producing a transaction Apple would accept requires Apple's signing key, so the
//                  positive path is provable in the sandbox and nowhere else. What is proved here is
//                  that nothing which is *not* signed by Apple gets through, which is the direction
//                  that carries the risk.
//
// The root certificate below is a throwaway self-signed EC certificate generated for this file. It
// is a public certificate with no private key committed, and it is deliberately *not* Apple's: its
// only job is to let the verifier construct so that verification can then be observed to fail.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { Environment } from "npm:@apple/app-store-server-library@1.6.0";
import type { JWSTransactionDecodedPayload } from "npm:@apple/app-store-server-library@1.6.0";
import {
  appleBundleID,
  AppleSubscriptionFailure,
  appleRootCertificates,
  environmentFromName,
  toVerifiedSubscription,
  verifySignedTransaction,
} from "./apple-subscription.ts";

const TEST_ROOT_CA_BASE64 =
  "MIIBrjCCAVOgAwIBAgIUBQhBUIX6g1okwvGGls8fTUgEjoIwCgYIKoZIzj0EAwIwKzEpMCcGA1UEAwwgU3Rvcnl0" +
  "b3BpYSBUZXN0IFJvb3QgKG5vdCBBcHBsZSkwIBcNMjYwODE2MTkxMDUyWhgPMjEyNjA3MjMxOTEwNTJaMCsxKTAn" +
  "BgNVBAMMIFN0b3J5dG9waWEgVGVzdCBSb290IChub3QgQXBwbGUpMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE" +
  "areVPv4SnaQheAYTv8KbeHkJhxzkhpzTRmSw20Y9v5Jveyo4LxK9hLpyFkWqYSR6vBvAQ77QEEC3IuSvjeX4E6NT" +
  "MFEwHQYDVR0OBBYEFLs8d0NvW8+uzCSqhJcwarpSZwDuMB8GA1UdIwQYMBaAFLs8d0NvW8+uzCSqhJcwarpSZwDu" +
  "MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhAPYXPvVpj5ff+Aq2hwlBwwwulW/TCT6YPN8PuVVK" +
  "XMi9AiEA6kyPyO2UWQeHLGB0U8N4ze16+0Yt/PO6IaUwTDRDhYs=";

function withAppleConfig(run: () => Promise<void> | void): () => Promise<void> {
  return async () => {
    const previous = {
      root: Deno.env.get("APPLE_ROOT_CA_G3_BASE64"),
      bundle: Deno.env.get("APPLE_BUNDLE_ID"),
      appID: Deno.env.get("APPLE_APP_APPLE_ID"),
      online: Deno.env.get("APPLE_VERIFICATION_ONLINE_CHECKS"),
    };

    Deno.env.set("APPLE_ROOT_CA_G3_BASE64", TEST_ROOT_CA_BASE64);
    Deno.env.set("APPLE_BUNDLE_ID", "com.michaelkogan.Journaltopia");
    Deno.env.set("APPLE_APP_APPLE_ID", "1234567890");
    Deno.env.set("APPLE_VERIFICATION_ONLINE_CHECKS", "false");

    try {
      await run();
    } finally {
      for (const [key, value] of Object.entries({
        APPLE_ROOT_CA_G3_BASE64: previous.root,
        APPLE_BUNDLE_ID: previous.bundle,
        APPLE_APP_APPLE_ID: previous.appID,
        APPLE_VERIFICATION_ONLINE_CHECKS: previous.online,
      })) {
        if (value === undefined) {
          Deno.env.delete(key);
        } else {
          Deno.env.set(key, value);
        }
      }
    }
  };
}

const HOUR = 60 * 60 * 1000;

function transaction(overrides: Partial<JWSTransactionDecodedPayload> = {}): JWSTransactionDecodedPayload {
  return {
    productId: "com.journaltopia.plus.monthly",
    originalTransactionId: "2000000000000001",
    transactionId: "2000000000000002",
    purchaseDate: Date.now() - HOUR,
    expiresDate: Date.now() + 30 * 24 * HOUR,
    ...overrides,
  };
}

// The mapping ---------------------------------------------------------------------------------

Deno.test("a current subscription is active", () => {
  const verified = toVerifiedSubscription(transaction(), null, Environment.SANDBOX);

  assertEquals(verified.status, "active");
  assertEquals(verified.productID, "com.journaltopia.plus.monthly");
  assertEquals(verified.originalTransactionID, "2000000000000001");
  assertEquals(verified.latestTransactionID, "2000000000000002");
  assertEquals(verified.environment, "sandbox");
});

Deno.test("an expiry in the past is expired, not active", () => {
  const verified = toVerifiedSubscription(
    transaction({ expiresDate: Date.now() - HOUR }),
    null,
    Environment.PRODUCTION,
  );

  assertEquals(verified.status, "expired");
  assertEquals(verified.environment, "production");
});

Deno.test("an expired subscription still set to renew is in billing retry", () => {
  // Apple keeps retrying a failed renewal. Neither state entitles, but the difference is what lets
  // the app eventually say "your card was declined" rather than "you cancelled".
  const verified = toVerifiedSubscription(
    transaction({ expiresDate: Date.now() - HOUR }),
    { autoRenewStatus: 1 },
    Environment.SANDBOX,
  );

  assertEquals(verified.status, "billing_retry");
  assertEquals(verified.autoRenewStatus, true);
});

Deno.test("a revocation beats an unexpired period", () => {
  // A refunded subscription can still have a future expiry date. Reading the period alone would
  // keep entitling someone Apple has already refunded.
  const verified = toVerifiedSubscription(
    transaction({ revocationDate: Date.now() - HOUR }),
    { autoRenewStatus: 1 },
    Environment.SANDBOX,
  );

  assertEquals(verified.status, "revoked");
});

Deno.test("absent renewal info is not read as cancelled", () => {
  // null means Apple did not tell us, which must stay distinguishable from autoRenewStatus = off.
  assertEquals(toVerifiedSubscription(transaction(), null, Environment.SANDBOX).autoRenewStatus, null);
  assertEquals(
    toVerifiedSubscription(transaction(), { autoRenewStatus: 0 }, Environment.SANDBOX).autoRenewStatus,
    false,
  );
});

Deno.test("periods are emitted as ISO-8601 for the database", () => {
  const purchase = Date.UTC(2026, 7, 1, 12, 0, 0);
  const expires = Date.UTC(2026, 8, 1, 12, 0, 0);
  const verified = toVerifiedSubscription(
    transaction({ purchaseDate: purchase, expiresDate: expires }),
    null,
    Environment.SANDBOX,
  );

  assertEquals(verified.periodStart, "2026-08-01T12:00:00.000Z");
  assertEquals(verified.periodEnd, "2026-09-01T12:00:00.000Z");
});

Deno.test("a transaction with no identity is refused", () => {
  for (const broken of [{ productId: undefined }, { originalTransactionId: undefined }]) {
    let threw = false;
    try {
      toVerifiedSubscription(transaction(broken), null, Environment.SANDBOX);
    } catch (error) {
      threw = true;
      assert(error instanceof AppleSubscriptionFailure);
      assertEquals((error as AppleSubscriptionFailure).code, "unreadable_transaction");
    }
    assert(threw, "an unidentifiable transaction must not be mapped");
  }
});

Deno.test("a transaction with no period is refused", () => {
  // A subscription with no expiry would otherwise be written with a null period and entitle nobody
  // in a way that is hard to explain. Better to refuse it as unreadable.
  for (const broken of [{ purchaseDate: undefined }, { expiresDate: undefined }]) {
    let threw = false;
    try {
      toVerifiedSubscription(transaction(broken), null, Environment.SANDBOX);
    } catch (error) {
      threw = true;
      assertEquals((error as AppleSubscriptionFailure).code, "unreadable_transaction");
    }
    assert(threw, "a transaction with no period must not be mapped");
  }
});

// Configuration --------------------------------------------------------------------------------

Deno.test("verification refuses to run unconfigured", () => {
  const previous = Deno.env.get("APPLE_ROOT_CA_G3_BASE64");
  Deno.env.delete("APPLE_ROOT_CA_G3_BASE64");

  try {
    let threw = false;
    try {
      appleRootCertificates();
    } catch (error) {
      threw = true;
      assertEquals((error as AppleSubscriptionFailure).code, "not_configured");
      assertEquals((error as AppleSubscriptionFailure).status, 500);
    }
    assert(threw, "a missing root certificate must fail closed, not verify nothing");
  } finally {
    if (previous !== undefined) {
      Deno.env.set("APPLE_ROOT_CA_G3_BASE64", previous);
    }
  }
});

Deno.test("a malformed root certificate is refused rather than ignored", () => {
  const previous = Deno.env.get("APPLE_ROOT_CA_G3_BASE64");
  Deno.env.set("APPLE_ROOT_CA_G3_BASE64", "!!!not base64!!!");

  try {
    let threw = false;
    try {
      appleRootCertificates();
    } catch (error) {
      threw = true;
      assertEquals((error as AppleSubscriptionFailure).code, "not_configured");
    }
    assert(threw, "an unreadable trust anchor must stop verification");
  } finally {
    if (previous === undefined) {
      Deno.env.delete("APPLE_ROOT_CA_G3_BASE64");
    } else {
      Deno.env.set("APPLE_ROOT_CA_G3_BASE64", previous);
    }
  }
});

Deno.test("configured roots decode", withAppleConfig(() => {
  const roots = appleRootCertificates();
  assertEquals(roots.length, 1);
  assert(roots[0].length > 100, "a decoded certificate should be a few hundred bytes");
  assertEquals(appleBundleID(), "com.michaelkogan.Journaltopia");
}));

Deno.test("environment names map to Apple's enum", () => {
  assertEquals(environmentFromName("production"), Environment.PRODUCTION);
  assertEquals(environmentFromName("Production"), Environment.PRODUCTION);
  assertEquals(environmentFromName("sandbox"), Environment.SANDBOX);
  // Anything unrecognised is treated as sandbox: the safer of the two, since production data that
  // fails to verify is rejected rather than trusted.
  assertEquals(environmentFromName(undefined), Environment.SANDBOX);
  assertEquals(environmentFromName("nonsense"), Environment.SANDBOX);
});

// Rejection ------------------------------------------------------------------------------------

Deno.test("an empty transaction is refused before any verification", withAppleConfig(async () => {
  await assertRejects(
    () => verifySignedTransaction("", null),
    AppleSubscriptionFailure,
  );
}));

Deno.test("a forged transaction is rejected", withAppleConfig(async () => {
  // Well-formed JWS, plausible claims, signed by nobody Apple trusts. This is precisely what a
  // modified client would send, and the payload's contents must never be read.
  const forged = [
    btoa(JSON.stringify({ alg: "ES256", x5c: [TEST_ROOT_CA_BASE64] })).replaceAll("=", ""),
    btoa(JSON.stringify({
      productId: "com.journaltopia.plus.monthly",
      originalTransactionId: "forged-1",
      purchaseDate: Date.now(),
      expiresDate: Date.now() + 30 * 24 * HOUR,
    })).replaceAll("=", ""),
    "AAAA",
  ].join(".");

  const error = await assertRejects(
    () => verifySignedTransaction(forged, null),
    AppleSubscriptionFailure,
  );

  assertEquals(error.code, "verification_failed");
  assertEquals(error.status, 401);
}));

Deno.test("garbage is rejected", withAppleConfig(async () => {
  for (const garbage of ["not-a-jws", "a.b.c", "...", "eyJhbGciOiJub25lIn0.."]) {
    const error = await assertRejects(
      () => verifySignedTransaction(garbage, null),
      AppleSubscriptionFailure,
    );
    assertEquals(error.status, 401);
  }
}));
