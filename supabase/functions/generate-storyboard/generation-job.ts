// The half of generate-storyboard that runs after the HTTP response has been sent. It is kept apart
// from the request handler because it has different rules: nothing here can talk to the caller, so
// every outcome has to land in the row instead, and every step has to be safe to run twice.
//
// The row is the state machine. This job claims it (pending -> processing), does the expensive work,
// and hands it to one of the two terminal transitions. Both transitions are database functions that
// re-check the row under a lock, so a duplicated execution of this job cannot double-complete or
// double-refund anything.
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  requestStoryboardImage,
  StoryboardFailure,
  uploadGeneratedImage,
  type ReferenceImage,
} from "../_shared/storyboard-generation.ts";

export const STORYBOARD_BUCKET = "generated-storyboards";
export const REFERENCE_BUCKET = "journaltopia-media";

/// Everything the background work needs, captured before the response goes out. The reference image
/// bytes are already in memory by then, so the job never depends on staged files still being there.
///
/// There is no caller client and no user id here. The job runs on the row, and the row already
/// records who owns it — a user id passed in from the request would be an authorization decision
/// travelling as a parameter.
export type StoryboardGenerationJob = {
  apiKey: string;
  storyboardID: string;
  storagePath: string;
  prompt: string;
  quality: string;
  references: ReferenceImage[];
  referenceImagePaths: string[];
};

export type StoryboardGenerationJobResult =
  | { status: "completed" }
  | { status: "failed"; message: string; refundedCredits: number | null }
  | { status: "skipped"; reason: string };

/// Injected so the job can be tested without OpenAI, Storage, or a database.
export type StoryboardGenerationJobDependencies = {
  createServiceClient: () => SupabaseClient;
  generateImage: typeof requestStoryboardImage;
  uploadImage: typeof uploadGeneratedImage;
};

const defaultDependencies: StoryboardGenerationJobDependencies = {
  createServiceClient: serviceRoleClient,
  generateImage: requestStoryboardImage,
  uploadImage: uploadGeneratedImage,
};

/// The service-role key is scoped to this file: the request handler authenticates, validates, and
/// reserves as the caller under RLS, and only the work that happens after the response — which has
/// no session behind it and must outlive the caller's token — runs with server authority.
export function serviceRoleKey(): string {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key) {
    throw new StoryboardFailure("Storyboard generation is not configured.", 500);
  }

  return key;
}

function serviceRoleClient(): SupabaseClient {
  const projectURL = Deno.env.get("SUPABASE_URL");
  if (!projectURL) {
    throw new StoryboardFailure("Storyboard generation is not configured.", 500);
  }

  return createClient(projectURL, serviceRoleKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function runStoryboardGeneration(
  job: StoryboardGenerationJob,
  dependencies: StoryboardGenerationJobDependencies = defaultDependencies,
): Promise<StoryboardGenerationJobResult> {
  const { storyboardID } = job;

  let client: SupabaseClient;
  try {
    client = dependencies.createServiceClient();
  } catch (error) {
    // Nothing can be written without a client, not even a failure. The row stays pending and the
    // sweeper refunds it; the request path checks for this key up front so it should never happen.
    console.error(`[generate-storyboard] no service client for ${storyboardID}:`, error);
    return { status: "skipped", reason: "no-service-client" };
  }

  // Claiming is the guard against a second execution of the same job: only the run that moves the
  // row out of 'pending' owns it, and it is the only one that may spend the OpenAI call.
  let claimed: boolean;
  try {
    claimed = await claimGeneration(client, storyboardID);
  } catch (error) {
    console.error(`[generate-storyboard] could not claim ${storyboardID}:`, error);
    return { status: "skipped", reason: "claim-failed" };
  }

  if (!claimed) {
    console.log(`[generate-storyboard] ${storyboardID} was already claimed or finished; standing down.`);
    await removeReferenceImages(client, job);
    return { status: "skipped", reason: "already-claimed" };
  }

  try {
    const imageBytes = await dependencies.generateImage({
      apiKey: job.apiKey,
      prompt: job.prompt,
      quality: job.quality,
      references: job.references,
    });

    await dependencies.uploadImage(client, STORYBOARD_BUCKET, job.storagePath, imageBytes);
    const completion = await completeGeneration(client, storyboardID, job.storagePath);

    // Losing the race to the sweeper is the one case where the image just uploaded can never be
    // reached: the row is terminal-failed, the user has been refunded, and nothing will ever point
    // at this object again. It is removed here, where the outcome is known for certain.
    if (completion === "already_failed") {
      console.log(`[generate-storyboard] ${storyboardID} was already failed; discarding the uploaded image.`);
      await removeGeneratedImage(client, job.storagePath);
      return { status: "skipped", reason: "already-failed" };
    }

    console.log(`[generate-storyboard] ${storyboardID} ${completion}.`);
    return { status: "completed" };
  } catch (error) {
    console.error(`[generate-storyboard] ${storyboardID} failed:`, error);
    const message = safeGenerationErrorMessage(error);
    const refundedCredits = await failGeneration(client, storyboardID, message);
    return { status: "failed", message, refundedCredits };
  } finally {
    await removeReferenceImages(client, job);
  }
}

/// Only messages this function raised itself are shown to the user. Anything else — a thrown
/// Postgres error, a stray runtime failure — is replaced, because its text was never written with a
/// reader in mind and it lands in a column the app displays verbatim.
export function safeGenerationErrorMessage(error: unknown): string {
  const message = error instanceof StoryboardFailure ? error.message.trim() : "";
  if (message.length > 0) {
    return message.slice(0, 500);
  }

  return "The storyboard could not be generated. Please try again.";
}

async function claimGeneration(client: SupabaseClient, storyboardID: string): Promise<boolean> {
  const { data, error } = await client.rpc("start_storyboard_generation", {
    storyboard_id: storyboardID,
  });

  if (error) {
    throw new StoryboardFailure(error.message ?? "The storyboard job could not be claimed.", 500);
  }

  return data === true;
}

export type StoryboardCompletionStatus = "completed" | "already_completed" | "already_failed";

/// The completion outcome arrives as data, so the caller can tell "this generation is over" from
/// "this write did not land". A database or network error is the second kind and throws: the row
/// may still be completable, and nothing may be cleaned up on a guess.
async function completeGeneration(
  client: SupabaseClient,
  storyboardID: string,
  storagePath: string,
): Promise<StoryboardCompletionStatus> {
  // The panel layout is whatever the model chose; the current implementation never recorded one, so
  // null is passed and the RPC leaves the stored value alone.
  const { data, error } = await client.rpc("complete_storyboard_generation", {
    storyboard_id: storyboardID,
    storage_path: storagePath,
    panel_layout: null,
  });

  if (error) {
    throw new StoryboardFailure("The finished storyboard could not be recorded.", 500);
  }

  const rows = Array.isArray(data) ? data : [data];
  const completionStatus = rows[0]?.completion_status;

  if (
    completionStatus !== "completed" &&
    completionStatus !== "already_completed" &&
    completionStatus !== "already_failed"
  ) {
    // An answer this function cannot read is not an answer. Treated as a failed write, which leaves
    // the row and the uploaded image alone.
    throw new StoryboardFailure("The finished storyboard could not be recorded.", 500);
  }

  return completionStatus;
}

/// Compensating cleanup for the one case where an uploaded image provably has no future: the row is
/// already failed and refunded. Never called for transient or unknown errors, because those leave a
/// row that may still complete.
async function removeGeneratedImage(client: SupabaseClient, storagePath: string): Promise<void> {
  const { error } = await client.storage.from(STORYBOARD_BUCKET).remove([storagePath]);

  if (error) {
    console.error("[generate-storyboard] orphaned storyboard image cleanup skipped:", error.message);
  }
}

/// Hands the row to the one transition that is allowed to refund. The amount comes back from the
/// database rather than from anything this function believes, so a row that was already terminal
/// reports the refund it actually got — which may be none.
async function failGeneration(
  client: SupabaseClient,
  storyboardID: string,
  message: string,
): Promise<number | null> {
  const { data, error } = await client.rpc("fail_storyboard_generation", {
    storyboard_id: storyboardID,
    generation_error: message,
  });

  if (error) {
    // The row keeps its non-terminal status, which is exactly what the stale-generation sweeper
    // exists to resolve. Nothing is refunded here on a guess.
    console.error(`[generate-storyboard] could not fail ${storyboardID}; leaving it to the sweeper:`, error.message);
    return null;
  }

  const rows = Array.isArray(data) ? data : [data];
  const refunded = rows[0]?.refunded_credits;
  return typeof refunded === "number" ? refunded : null;
}

/// Generation inputs are a staging copy of images the entry already owns. The bytes were read before
/// the response went out, so removing them now cannot affect this job — and doing it here means the
/// files are cleaned up even when the client that uploaded them is long gone.
async function removeReferenceImages(
  client: SupabaseClient,
  job: StoryboardGenerationJob,
): Promise<void> {
  if (job.referenceImagePaths.length === 0) {
    return;
  }

  const { error } = await client.storage
    .from(REFERENCE_BUCKET)
    .remove(job.referenceImagePaths);

  if (error) {
    console.error("[generate-storyboard] generation reference cleanup skipped:", error.message);
  }
}
