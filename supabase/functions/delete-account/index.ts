// Permanent deletion of the calling account, and everything Journaltopia holds for it.
//
// The client sends no body. There is nothing it could usefully say: the account being deleted is the
// account whose JWT is on the request, verified here, and a `user_id` in a request body would be a
// field a modified client could set to somebody else's. That is the whole authorization model, and
// it is why this function accepts no input at all.
//
// Order is the part that matters, and it is deliberate:
//
//   1. Apple authorization  revoked at Apple, for accounts with a Sign in with Apple identity
//   2. storage objects      removed through the Storage API, which drops the bytes as well as the row
//   3. auth user            deleted with the service role, which cascades every table
//
// Apple goes first because it is the only step that cannot be finished afterwards. Once the auth user
// is gone, the identity linking this account to an Apple id is gone with it, and there is no longer
// any way to know whose authorization to revoke — an account deleted without revocation is one App
// Store Review Guideline 5.1.1(v) says should not exist, and it cannot be repaired later. Everything
// else here can be retried; this cannot, so it happens while nothing has been destroyed yet.
//
// Storage first, because `storage.objects` has no foreign key to `auth.users` — see
// 20260824090000. Delete the user first and the object rows survive with nothing left to connect
// them to a person: private photos, permanently, and invisibly. So the storage sweep is a
// precondition, not a cleanup, and if it fails this function fails with it and deletes nothing. The
// account still exists at that point, the caller is still signed in, and pressing the button again
// resumes from wherever the sweep stopped.
//
// Which makes retry the other half of the design. Every step here is idempotent: removing an object
// that is already gone is a no-op, and deleting a user that is already deleted reports success. A
// half-finished deletion is always safe to run again, and always converges.
import {
  appleBundleID,
  AppleSubscriptionFailure,
  serviceRoleClient,
} from "../_shared/apple-subscription.ts";
import {
  AppleAuthorizationFailure,
  revokeAppleAuthorization,
} from "../_shared/apple-authorization.ts";
import {
  StoryboardFailure,
  authenticateCaller,
  jsonResponse,
} from "../_shared/storyboard-generation.ts";

const CONTEXT = "delete-account";
const SIGN_IN_REQUIRED = "Sign in before deleting your account.";

/// Storage `remove` takes a list of paths; this is how many go in one call. Large enough that an
/// ordinary account is a single request, small enough that no request grows unbounded for the
/// account with a thousand storyboards.
const REMOVE_BATCH_SIZE = 100;

type StorageObject = { bucket_id: string; name: string };

/// The only field this function accepts, and it is a credential rather than a claim.
///
/// A fresh Sign in with Apple authorization code, obtained by the app re-authenticating the user with
/// Apple immediately before the request. It says nothing about *which* account to delete — that is
/// still read from the JWT — and it is checked against the Apple identity already linked to that
/// account before it is used for anything.
type DeleteAccountRequest = {
  appleAuthorizationCode?: string;
};

async function readRequest(request: Request): Promise<DeleteAccountRequest> {
  // A non-Apple account sends nothing at all, so an absent or empty body is the ordinary case.
  try {
    const text = await request.text();
    if (text.trim().length === 0) {
      return {};
    }

    return JSON.parse(text) as DeleteAccountRequest;
  } catch {
    throw new StoryboardFailure("Invalid request body.", 400, "invalid_body");
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    // The only statement of identity this function will accept.
    const { userID } = await authenticateCaller(request, SIGN_IN_REQUIRED);
    const payload = await readRequest(request);

    const admin = serviceRoleClient();

    const appleRevoked = await revokeAppleAuthorizationIfLinked(admin, userID, payload);
    const filesRemoved = await removeStorageObjects(admin, userID);
    await deleteAuthUser(admin, userID);

    // Reported only once the auth user is actually gone. Anything short of that has thrown.
    return jsonResponse({ deleted: true, filesRemoved, appleRevoked });
  } catch (error) {
    if (error instanceof StoryboardFailure) {
      return jsonResponse(
        error.code ? { error: error.message, code: error.code } : { error: error.message },
        error.status,
      );
    }

    // `serviceRoleClient` reports a missing service role key in the vocabulary of the function it was
    // written for. Its status is worth keeping; its message is about subscriptions and would be
    // nonsense here, so this one is reworded rather than passed through.
    // Apple refused, or could not be reached. The account is untouched: nothing has been deleted at
    // the point this can throw, and the code is specific enough for the app to either re-prompt for
    // Apple or show a retry.
    if (error instanceof AppleAuthorizationFailure) {
      return jsonResponse({ error: error.message, code: error.code }, error.status);
    }

    if (error instanceof AppleSubscriptionFailure) {
      console.error(`[${CONTEXT}] not configured:`, error.message);
      return jsonResponse(
        { error: "Account deletion is unavailable right now. Please try again.", code: "not_configured" },
        error.status,
      );
    }

    console.error(`[${CONTEXT}] unexpected failure:`, error);
    return jsonResponse({ error: "Your account could not be deleted. Please try again." }, 500);
  }
});

/// Revokes the account's Sign in with Apple authorization, when it has one.
///
/// Returns `true` if an authorization was revoked and `false` if the account has no Apple identity —
/// a Google or email-only account never reaches Apple at all, which is why this is a lookup rather
/// than an attempt-and-ignore.
///
/// An account with several linked providers is handled by the same lookup: Apple is revoked because
/// an Apple identity is present, and the other providers are unaffected by it. Google has no
/// equivalent requirement, and the Google grant disappears with the account itself.
async function revokeAppleAuthorizationIfLinked(
  admin: ReturnType<typeof serviceRoleClient>,
  userID: string,
  payload: DeleteAccountRequest,
): Promise<boolean> {
  const { data, error } = await admin.auth.admin.getUserById(userID);

  if (error || !data?.user) {
    console.error(`[${CONTEXT}] could not read the account's identities:`, error?.message);
    throw new StoryboardFailure(
      "Your account could not be deleted. Please try again.",
      500,
      "identity_lookup_failed",
    );
  }

  const appleIdentity = (data.user.identities ?? []).find(
    (identity) => identity.provider === "apple",
  );

  if (!appleIdentity) {
    return false;
  }

  // The Apple user id (`sub`) this account is linked to. `identity_data.sub` and the identity's own
  // `id` are the same value in GoTrue; both are read so a missing one is not a silent skip.
  const expectedSubject =
    (appleIdentity.identity_data?.sub as string | undefined) ?? appleIdentity.id;

  if (!expectedSubject) {
    console.error(`[${CONTEXT}] apple identity has no subject to match against`);
    throw new AppleAuthorizationFailure(
      "Journaltopia could not remove its access to your Apple ID. Please try again.",
      500,
      "apple_revocation_failed",
    );
  }

  const authorizationCode = payload.appleAuthorizationCode?.trim();

  // The app is expected to have obtained this already. Answering with a distinct code rather than a
  // generic 400 is what lets an older build — or a request that lost the field — be told precisely
  // what is missing instead of showing the user an unexplained failure.
  if (!authorizationCode) {
    throw new AppleAuthorizationFailure(
      "Confirm with Apple to finish deleting your account.",
      400,
      "apple_reauthorization_required",
    );
  }

  // `appleBundleID` is shared with subscription verification and reports a missing APPLE_BUNDLE_ID in
  // that flow's vocabulary. Re-flavoured here so a misconfiguration on the Apple path is reported as
  // an Apple problem — the app routes on these codes, and "not_configured" would send it down the
  // generic retry instead of telling the truth about what failed.
  let clientID: string;
  try {
    clientID = appleBundleID();
  } catch (error) {
    console.error(`[${CONTEXT}] APPLE_BUNDLE_ID is not set; cannot revoke:`, error);
    throw new AppleAuthorizationFailure(
      "Sign in with Apple revocation is not configured.",
      500,
      "apple_not_configured",
    );
  }

  await revokeAppleAuthorization({
    clientID,
    authorizationCode,
    expectedSubject,
  });

  return true;
}

/// Removes every private Storage object under `<userID>/`, in every bucket that holds user files.
///
/// The paths come from `user_storage_object_names`, which is service-role only and scopes itself to
/// the account it is given — so there is no path here that the caller chose and none that belongs to
/// anyone else. Returns how many objects were removed, which is reported back for support purposes
/// and is 0 on a retry that finds the sweep already done.
async function removeStorageObjects(
  admin: ReturnType<typeof serviceRoleClient>,
  userID: string,
): Promise<number> {
  const { data, error } = await admin.rpc("user_storage_object_names", { account: userID });

  if (error) {
    console.error(`[${CONTEXT}] could not list storage objects:`, error.message);
    throw new StoryboardFailure(
      "Your account could not be deleted. Please try again.",
      500,
      "storage_cleanup_failed",
    );
  }

  const objects = (data ?? []) as StorageObject[];
  if (objects.length === 0) {
    return 0;
  }

  const pathsByBucket = new Map<string, string[]>();
  for (const object of objects) {
    const paths = pathsByBucket.get(object.bucket_id) ?? [];
    paths.push(object.name);
    pathsByBucket.set(object.bucket_id, paths);
  }

  let removed = 0;

  for (const [bucket, paths] of pathsByBucket) {
    for (let start = 0; start < paths.length; start += REMOVE_BATCH_SIZE) {
      const batch = paths.slice(start, start + REMOVE_BATCH_SIZE);
      const { error: removeError } = await admin.storage.from(bucket).remove(batch);

      if (removeError) {
        // Stop here and leave the account intact. Whatever this batch was, it is still owned by a
        // live user who can retry — which is a better place to be than an anonymous pile of private
        // images in a bucket. `remove` does not fail on paths that are already gone, so the retry
        // re-treads the finished batches harmlessly and resumes at this one.
        console.error(
          `[${CONTEXT}] could not remove ${batch.length} object(s) from ${bucket}:`,
          removeError.message,
        );
        throw new StoryboardFailure(
          "Your account could not be deleted. Please try again.",
          500,
          "storage_cleanup_failed",
        );
      }

      removed += batch.length;
    }
  }

  return removed;
}

/// Deletes the auth user, which is what cascades the database.
///
/// A user that is already absent is the success case, not an error: it means an earlier attempt got
/// this far, and the caller is asking about an account that no longer exists.
async function deleteAuthUser(
  admin: ReturnType<typeof serviceRoleClient>,
  userID: string,
): Promise<void> {
  const { error } = await admin.auth.admin.deleteUser(userID);
  if (!error) {
    return;
  }

  if (isUserAlreadyGone(error)) {
    return;
  }

  console.error(`[${CONTEXT}] could not delete auth user:`, error.message);
  throw new StoryboardFailure(
    "Your account could not be deleted. Please try again.",
    500,
    "auth_deletion_failed",
  );
}

function isUserAlreadyGone(error: { status?: number; message?: string }): boolean {
  if (error.status === 404) {
    return true;
  }

  return (error.message ?? "").toLowerCase().includes("user not found");
}
