// Sign in with Apple authorization revocation, for account deletion.
//
// App Store Review Guideline 5.1.1(v) requires that an app offering Sign in with Apple revoke the
// user's authorization through Apple's REST API when their account is deleted. Deleting the row in
// `auth.identities` is not that: it forgets Apple on our side while leaving Journaltopia listed under
// Settings > Apple ID > Sign in with Apple on the user's device, still authorized.
//
// Revocation needs a refresh token or access token, and Journaltopia has never held either — the app
// signs in with Apple's *identity token* and never reads `credential.authorizationCode`, so there is
// nothing stored to revoke with, for any user who exists today. Rather than start banking Apple
// refresh tokens (which would still leave every pre-existing account unrevocable, and would put a
// long-lived credential belonging to Apple in our database), the client re-authenticates with Apple
// at deletion time and hands over a fresh single-use authorization code. This module turns that code
// into a revocation:
//
//   1. exchange the code at /auth/token          -> refresh_token + id_token
//   2. check the id_token's `sub` is this account -> caller cannot revoke a stranger's authorization
//   3. revoke the refresh token at /auth/revoke
//
// Nothing here is ever reachable from the app: the private key that signs the client secret exists
// only in the Edge Function environment.
//
// Endpoint contracts below are from Apple's current documentation:
//   https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens
//   https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens
//   https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret

const APPLE_TOKEN_ENDPOINT = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_ENDPOINT = "https://appleid.apple.com/auth/revoke";

/// Apple rejects a client secret that expires more than six months out (15777000 seconds). Ours is
/// minted per request and lives for five minutes, because it is used immediately and a short-lived
/// credential is one less thing that matters if a log leaks.
const CLIENT_SECRET_LIFETIME_SECONDS = 300;

export class AppleAuthorizationFailure extends Error {
  readonly status: number;
  readonly code: string;

  constructor(message: string, status = 500, code = "apple_revocation_failed") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/// The 10-character key identifier of the Sign in with Apple key (`kid` in the client secret header).
function appleKeyID(): string {
  const value = Deno.env.get("APPLE_SIGN_IN_KEY_ID")?.trim();
  if (!value) {
    throw new AppleAuthorizationFailure(
      "Sign in with Apple revocation is not configured.",
      500,
      "apple_not_configured",
    );
  }

  return value;
}

/// The 10-character Team ID (`iss` in the client secret).
function appleTeamID(): string {
  const value = Deno.env.get("APPLE_TEAM_ID")?.trim();
  if (!value) {
    throw new AppleAuthorizationFailure(
      "Sign in with Apple revocation is not configured.",
      500,
      "apple_not_configured",
    );
  }

  return value;
}

/// The contents of the `.p8` private key downloaded from Apple.
///
/// Accepts the file verbatim, and also the single-line form with escaped `\n` that shells and secret
/// managers tend to produce — the same key either way, and getting this wrong would otherwise surface
/// as an unexplained `invalid_client` from Apple.
function applePrivateKeyPEM(): string {
  const value = Deno.env.get("APPLE_SIGN_IN_PRIVATE_KEY");
  if (!value || value.trim().length === 0) {
    throw new AppleAuthorizationFailure(
      "Sign in with Apple revocation is not configured.",
      500,
      "apple_not_configured",
    );
  }

  return value.includes("\\n") ? value.replace(/\\n/g, "\n") : value;
}

function base64URL(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function base64URLFromString(value: string): string {
  return base64URL(new TextEncoder().encode(value));
}

/// Imports the `.p8` as an ECDSA P-256 signing key.
async function importSigningKey(): Promise<CryptoKey> {
  const pem = applePrivateKeyPEM();
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");

  let der: ArrayBuffer;
  try {
    const bytes = Uint8Array.from(atob(body), (character) => character.charCodeAt(0));
    der = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  } catch {
    throw new AppleAuthorizationFailure(
      "Sign in with Apple revocation is not configured.",
      500,
      "apple_not_configured",
    );
  }

  try {
    return await crypto.subtle.importKey(
      "pkcs8",
      der,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  } catch {
    throw new AppleAuthorizationFailure(
      "Sign in with Apple revocation is not configured.",
      500,
      "apple_not_configured",
    );
  }
}

/// Builds the `client_secret` JWT that authenticates Journaltopia to Apple.
///
/// ES256 over `iss`/`iat`/`exp`/`aud`/`sub`, exactly as Apple specifies. WebCrypto's ECDSA signature
/// is already the raw r‖s pair that JWS requires, so it needs no DER unwrapping.
export async function appleClientSecret(clientID: string): Promise<string> {
  const key = await importSigningKey();
  const issuedAt = Math.floor(Date.now() / 1000);

  const header = { alg: "ES256", kid: appleKeyID() };
  const payload = {
    iss: appleTeamID(),
    iat: issuedAt,
    exp: issuedAt + CLIENT_SECRET_LIFETIME_SECONDS,
    aud: "https://appleid.apple.com",
    sub: clientID,
  };

  const signingInput = `${base64URLFromString(JSON.stringify(header))}.${
    base64URLFromString(JSON.stringify(payload))
  }`;

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

type AppleTokenResponse = {
  access_token?: string;
  refresh_token?: string;
  id_token?: string;
};

async function appleErrorCode(response: Response): Promise<string> {
  try {
    const body = await response.json();
    return typeof body?.error === "string" ? body.error : "unknown_error";
  } catch {
    return "unknown_error";
  }
}

/// Reads the claims of a token that Apple just returned over TLS from its own token endpoint.
///
/// No signature check: this token did not come from the client, it came from Apple in the response to
/// a request authenticated with our client secret. The claim being read is only used to confirm the
/// code belongs to the account being deleted.
function decodeIDTokenSubject(idToken: string): string | null {
  const segments = idToken.split(".");
  if (segments.length < 2) {
    return null;
  }

  try {
    const padded = segments[1].replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="));
    const claims = JSON.parse(json);
    return typeof claims?.sub === "string" ? claims.sub : null;
  } catch {
    return null;
  }
}

/// Exchanges a fresh authorization code for Apple tokens.
///
/// `redirect_uri` is deliberately absent: Apple wants it only when the original authorization request
/// supplied one, and the native `ASAuthorizationController` flow does not. Sending it anyway is an
/// `invalid_client`.
export async function exchangeAuthorizationCode(
  clientID: string,
  authorizationCode: string,
): Promise<{ refreshToken: string | null; accessToken: string | null; subject: string | null }> {
  const clientSecret = await appleClientSecret(clientID);

  const body = new URLSearchParams({
    client_id: clientID,
    client_secret: clientSecret,
    code: authorizationCode,
    grant_type: "authorization_code",
  });

  let response: Response;
  try {
    response = await fetch(APPLE_TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
  } catch (error) {
    console.error("[apple-authorization] token endpoint unreachable:", error);
    throw new AppleAuthorizationFailure(
      "Apple could not be reached to remove Journaltopia's access. Please try again.",
      503,
      "apple_unreachable",
    );
  }

  if (!response.ok) {
    const code = await appleErrorCode(response);

    // The code was already used, or it expired — they are single-use and short-lived. The user has to
    // approve Apple again, which the app can do immediately, so this is a distinct, actionable code
    // rather than a generic failure.
    if (code === "invalid_grant") {
      throw new AppleAuthorizationFailure(
        "Your Apple confirmation expired. Please try deleting your account again.",
        400,
        "apple_reauthorization_required",
      );
    }

    // `invalid_client` here means our Team ID, Key ID, key or bundle id is wrong. Nothing the user
    // can do, and nothing that should be retried silently.
    console.error(`[apple-authorization] token exchange refused: ${code}`);
    throw new AppleAuthorizationFailure(
      "Journaltopia could not confirm your Apple sign-in. Please try again.",
      502,
      "apple_exchange_failed",
    );
  }

  const tokens = (await response.json()) as AppleTokenResponse;
  return {
    refreshToken: tokens.refresh_token ?? null,
    accessToken: tokens.access_token ?? null,
    subject: tokens.id_token ? decodeIDTokenSubject(tokens.id_token) : null,
  };
}

/// Revokes one Apple token, which ends the user's authorization for this app.
///
/// Apple answers 200 both when it revokes the token and when the token was already invalid, so this
/// is idempotent by Apple's own contract — a retried deletion revokes again without incident.
export async function revokeAppleToken(
  clientID: string,
  token: string,
  tokenTypeHint: "refresh_token" | "access_token",
): Promise<void> {
  const clientSecret = await appleClientSecret(clientID);

  const body = new URLSearchParams({
    client_id: clientID,
    client_secret: clientSecret,
    token,
    token_type_hint: tokenTypeHint,
  });

  let response: Response;
  try {
    response = await fetch(APPLE_REVOKE_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
  } catch (error) {
    console.error("[apple-authorization] revoke endpoint unreachable:", error);
    throw new AppleAuthorizationFailure(
      "Apple could not be reached to remove Journaltopia's access. Please try again.",
      503,
      "apple_unreachable",
    );
  }

  if (response.ok) {
    return;
  }

  const code = await appleErrorCode(response);

  // Apple documents 200 for an already-invalid token, so this is the belt-and-braces case: a token
  // Apple will not accept is a token that authorizes nothing, which is the state revocation exists to
  // reach. Logged rather than passed silently, because it is not the expected path.
  if (code === "invalid_grant") {
    console.warn("[apple-authorization] revoke reported invalid_grant; authorization already inactive");
    return;
  }

  console.error(`[apple-authorization] revoke refused: ${code}`);
  throw new AppleAuthorizationFailure(
    "Journaltopia could not remove its access to your Apple ID. Please try again.",
    502,
    "apple_revocation_failed",
  );
}

/// The whole revocation, from a fresh authorization code to a revoked authorization.
///
/// `expectedSubject` is the Apple user id already linked to the Journaltopia account. Checking it is
/// what stops a caller from approving a *different* Apple ID at the prompt and having us revoke a
/// stranger's authorization — the code is a credential, and this is what binds it to the account the
/// JWT identifies.
export async function revokeAppleAuthorization(options: {
  clientID: string;
  authorizationCode: string;
  expectedSubject: string;
}): Promise<void> {
  const { refreshToken, accessToken, subject } = await exchangeAuthorizationCode(
    options.clientID,
    options.authorizationCode,
  );

  if (subject && subject !== options.expectedSubject) {
    throw new AppleAuthorizationFailure(
      "That Apple ID is not the one linked to this Journaltopia account.",
      403,
      "apple_identity_mismatch",
    );
  }

  // Revoking the refresh token ends the authorization. The access token is the documented fallback
  // for the case where Apple returns no refresh token.
  if (refreshToken) {
    await revokeAppleToken(options.clientID, refreshToken, "refresh_token");
    return;
  }

  if (accessToken) {
    await revokeAppleToken(options.clientID, accessToken, "access_token");
    return;
  }

  throw new AppleAuthorizationFailure(
    "Journaltopia could not remove its access to your Apple ID. Please try again.",
    502,
    "apple_revocation_failed",
  );
}
