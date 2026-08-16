// The half of generate-storyboard that runs after the HTTP response has been sent. It is kept apart
// from the request handler because it has different rules: nothing here can talk to the caller, so
// every outcome has to land in the row instead, and every step has to be safe to run twice.
//
// The row is the state machine. This job claims it (pending -> processing), does the expensive work,
// and hands it to one of the two terminal transitions. Both transitions are database functions that
// re-check the row under a lock, so a duplicated execution of this job cannot double-complete or
// double-refund anything.
import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  requestStoryboardImage,
  StoryboardFailure,
  uploadGeneratedImage,
  type ReferenceImage,
} from "../_shared/storyboard-generation.ts";

export const STORYBOARD_BUCKET = "generated-storyboards";
export const REFERENCE_BUCKET = "storytopia-media";

/// Everything the background work needs, captured before the response goes out. The reference image
/// bytes are already in memory by then, so the job never depends on staged files still being there.
export type StoryboardGenerationJob = {
  client: SupabaseClient;
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

/// Injected so the job can be tested without OpenAI or Storage.
export type StoryboardGenerationJobDependencies = {
  generateImage: typeof requestStoryboardImage;
  uploadImage: typeof uploadGeneratedImage;
};

const defaultDependencies: StoryboardGenerationJobDependencies = {
  generateImage: requestStoryboardImage,
  uploadImage: uploadGeneratedImage,
};

export async function runStoryboardGeneration(
  job: StoryboardGenerationJob,
  dependencies: StoryboardGenerationJobDependencies = defaultDependencies,
): Promise<StoryboardGenerationJobResult> {
  const { client, storyboardID } = job;

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
    await removeReferenceImages(job);
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
    await completeGeneration(client, storyboardID, job.storagePath);

    console.log(`[generate-storyboard] ${storyboardID} completed.`);
    return { status: "completed" };
  } catch (error) {
    console.error(`[generate-storyboard] ${storyboardID} failed:`, error);
    const message = safeGenerationErrorMessage(error);
    const refundedCredits = await failGeneration(client, storyboardID, message);
    return { status: "failed", message, refundedCredits };
  } finally {
    await removeReferenceImages(job);
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

async function completeGeneration(
  client: SupabaseClient,
  storyboardID: string,
  storagePath: string,
): Promise<void> {
  // The panel layout is whatever the model chose; the current implementation never recorded one, so
  // null is passed and the RPC leaves the stored value alone.
  const { error } = await client.rpc("complete_storyboard_generation", {
    storyboard_id: storyboardID,
    storage_path: storagePath,
    panel_layout: null,
  });

  if (error) {
    throw new StoryboardFailure("The finished storyboard could not be recorded.", 500);
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
async function removeReferenceImages(job: StoryboardGenerationJob): Promise<void> {
  if (job.referenceImagePaths.length === 0) {
    return;
  }

  const { error } = await job.client.storage
    .from(REFERENCE_BUCKET)
    .remove(job.referenceImagePaths);

  if (error) {
    console.error("[generate-storyboard] generation reference cleanup skipped:", error.message);
  }
}
