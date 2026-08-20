// Sign in with Apple revocation.
//
// Run with: deno test --allow-env --allow-net supabase/functions/_shared/apple-authorization_test.ts
//
// The client secret is the part worth testing hardest. It is a JWT signed with a key Apple holds the
// public half of, and every way of getting it wrong — the wrong claim, the wrong curve, a DER-wrapped
// signature — fails identically from our side: Apple answers `invalid_client` and says no more. So
// the assertions here verify the token the way Apple will, against a real P-256 key generated for
// the test, rather than trusting that it looks right.
//
// The network calls are exercised against a stubbed `fetch`, which is what makes the *policy*
// testable: which Apple error becomes which outcome, and — the one that matters for compliance —
// that a failed revocation throws rather than returning quietly.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  AppleAuthorizationFailure,
  appleClientSecret,
  revokeAppleAuthorization,
  revokeAppleToken,
} from "./apple-authorization.ts";

const CLIENT_ID = "com.michaelkogan.Journaltopia";
const TEAM_ID = "ABCDE12345";
const KEY_ID = "FGHIJ67890";

// MARK: - A real key, so the signature can actually be verified

async function generateKeyPair(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );

  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const base64 = btoa(String.fromCharCode(...pkcs8));
  const lines = base64.match(/.{1,64}/g)?.join("\n") ?? base64;
  const pem = `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;

  return { pem, publicKey: pair.publicKey };
}

function configure(pem: string) {
  Deno.env.set("APPLE_TEAM_ID", TEAM_ID);
  Deno.env.set("APPLE_SIGN_IN_KEY_ID", KEY_ID);
  Deno.env.set("APPLE_SIGN_IN_PRIVATE_KEY", pem);
}

function decodeSegment(segment: string): Record<string, unknown> {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "=")));
}

function base64URLToBytes(segment: string): ArrayBuffer {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="));
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer.slice(0, bytes.byteLength) as ArrayBuffer;
}

Deno.test("client secret carries the claims Apple requires", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  const secret = await appleClientSecret(CLIENT_ID);
  const [headerSegment, payloadSegment] = secret.split(".");

  const header = decodeSegment(headerSegment);
  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, KEY_ID);

  const payload = decodeSegment(payloadSegment) as Record<string, number | string>;
  assertEquals(payload.iss, TEAM_ID);
  assertEquals(payload.aud, "https://appleid.apple.com");
  // `sub` is the client_id, and Apple treats a mismatch as invalid_client.
  assertEquals(payload.sub, CLIENT_ID);
});

Deno.test("client secret expires well inside Apple's six-month ceiling", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  const payload = decodeSegment(
    (await appleClientSecret(CLIENT_ID)).split(".")[1],
  ) as Record<string, number>;

  const lifetime = payload.exp - payload.iat;
  assertEquals(lifetime > 0, true);
  // Apple rejects anything beyond 15777000 seconds.
  assertEquals(lifetime <= 15_777_000, true);
});

Deno.test("client secret verifies against the signing key as ES256", async () => {
  const { pem, publicKey } = await generateKeyPair();
  configure(pem);

  const secret = await appleClientSecret(CLIENT_ID);
  const segments = secret.split(".");
  assertEquals(segments.length, 3);

  // WebCrypto expects the raw r‖s pair, which is exactly what JWS ES256 specifies — 64 bytes for
  // P-256. A DER-wrapped signature would be the classic mistake here and would be a different length.
  const signature = base64URLToBytes(segments[2]);
  assertEquals(signature.byteLength, 64);

  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    signature,
    new TextEncoder().encode(`${segments[0]}.${segments[1]}`),
  );
  assertEquals(verified, true);
});

Deno.test("a key in escaped single-line form is the same key", async () => {
  const { pem, publicKey } = await generateKeyPair();
  configure(pem.replace(/\n/g, "\\n"));

  const segments = (await appleClientSecret(CLIENT_ID)).split(".");
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    base64URLToBytes(segments[2]),
    new TextEncoder().encode(`${segments[0]}.${segments[1]}`),
  );

  assertEquals(verified, true);
});

Deno.test("missing configuration is reported as configuration, not as a user failure", async () => {
  Deno.env.delete("APPLE_SIGN_IN_PRIVATE_KEY");
  Deno.env.set("APPLE_TEAM_ID", TEAM_ID);
  Deno.env.set("APPLE_SIGN_IN_KEY_ID", KEY_ID);

  const error = await assertRejects(
    () => appleClientSecret(CLIENT_ID),
    AppleAuthorizationFailure,
  );
  assertEquals(error.code, "apple_not_configured");
  assertEquals(error.status, 500);
});

// MARK: - What each Apple answer means

function stubFetch(handler: (url: string, body: URLSearchParams) => Response) {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const body = new URLSearchParams(String(init?.body ?? ""));
    return Promise.resolve(handler(url, body));
  }) as typeof fetch;
  return () => {
    globalThis.fetch = original;
  };
}

function appleError(code: string, status = 400): Response {
  return new Response(JSON.stringify({ error: code }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function idTokenFor(subject: string): string {
  const claims = btoa(JSON.stringify({ sub: subject }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `header.${claims}.signature`;
}

Deno.test("revocation sends the token and hint Apple documents", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  let seenURL = "";
  let seen: URLSearchParams | null = null;
  const restore = stubFetch((url, body) => {
    seenURL = url;
    seen = body;
    return new Response(null, { status: 200 });
  });

  try {
    await revokeAppleToken(CLIENT_ID, "the-refresh-token", "refresh_token");
  } finally {
    restore();
  }

  assertEquals(seenURL, "https://appleid.apple.com/auth/revoke");
  assertEquals(seen!.get("client_id"), CLIENT_ID);
  assertEquals(seen!.get("token"), "the-refresh-token");
  assertEquals(seen!.get("token_type_hint"), "refresh_token");
  // The client secret travels as a JWT, never the private key itself.
  assertEquals((seen!.get("client_secret") ?? "").split(".").length, 3);
});

Deno.test("an already-invalid token counts as revoked", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  const restore = stubFetch(() => appleError("invalid_grant"));
  try {
    // Apple answers 200 for a token it already invalidated; this is the belt-and-braces path, and it
    // must not fail a deletion whose revocation has effectively already happened.
    await revokeAppleToken(CLIENT_ID, "stale", "refresh_token");
  } finally {
    restore();
  }
});

Deno.test("a refused revocation throws rather than passing quietly", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  const restore = stubFetch(() => appleError("invalid_client"));
  try {
    const error = await assertRejects(
      () => revokeAppleToken(CLIENT_ID, "token", "refresh_token"),
      AppleAuthorizationFailure,
    );
    assertEquals(error.code, "apple_revocation_failed");
  } finally {
    restore();
  }
});

Deno.test("an expired authorization code asks for a fresh one", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  const restore = stubFetch(() => appleError("invalid_grant"));
  try {
    const error = await assertRejects(
      () =>
        revokeAppleAuthorization({
          clientID: CLIENT_ID,
          authorizationCode: "used-already",
          expectedSubject: "apple-sub-1",
        }),
      AppleAuthorizationFailure,
    );
    assertEquals(error.code, "apple_reauthorization_required");
  } finally {
    restore();
  }
});

Deno.test("a code belonging to a different Apple ID is refused and nothing is revoked", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  let revokeCalled = false;
  const restore = stubFetch((url) => {
    if (url.endsWith("/auth/revoke")) {
      revokeCalled = true;
      return new Response(null, { status: 200 });
    }

    return new Response(
      JSON.stringify({ refresh_token: "r", id_token: idTokenFor("somebody-else") }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  });

  try {
    const error = await assertRejects(
      () =>
        revokeAppleAuthorization({
          clientID: CLIENT_ID,
          authorizationCode: "fresh",
          expectedSubject: "apple-sub-1",
        }),
      AppleAuthorizationFailure,
    );
    assertEquals(error.code, "apple_identity_mismatch");
    assertEquals(error.status, 403);
  } finally {
    restore();
  }

  // The important half: we did not revoke a stranger's authorization on the way to finding out.
  assertEquals(revokeCalled, false);
});

Deno.test("the happy path exchanges then revokes the refresh token", async () => {
  const { pem } = await generateKeyPair();
  configure(pem);

  const calls: string[] = [];
  const restore = stubFetch((url, body) => {
    calls.push(url);
    if (url.endsWith("/auth/revoke")) {
      assertEquals(body.get("token"), "the-refresh-token");
      return new Response(null, { status: 200 });
    }

    assertEquals(body.get("grant_type"), "authorization_code");
    // Native ASAuthorization flows send no redirect_uri, and including one is an invalid_client.
    assertEquals(body.get("redirect_uri"), null);
    return new Response(
      JSON.stringify({ refresh_token: "the-refresh-token", id_token: idTokenFor("apple-sub-1") }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  });

  try {
    await revokeAppleAuthorization({
      clientID: CLIENT_ID,
      authorizationCode: "fresh",
      expectedSubject: "apple-sub-1",
    });
  } finally {
    restore();
  }

  assertEquals(calls, [
    "https://appleid.apple.com/auth/token",
    "https://appleid.apple.com/auth/revoke",
  ]);
});
