// The request path of storyboard generation. It does only what has to happen while the caller is
// waiting — authenticate, validate, read the reference images, reserve the credit, and write the
// pending row — then answers with the storyboard id and hands the expensive work to a background
// task. Nothing the client does after that point, including being backgrounded or killed, can
// affect the generation: the row is the job, and the row lives on the server.
import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  authenticateCaller,
  CREDIT_COST_BY_QUALITY,
  downloadReferenceImages,
  failureResponse,
  jsonResponse,
  openAIKey,
  optionalText,
  parseReferenceImagePaths,
  requirePrompt,
  requireQuality,
  requireUUID,
  StoryboardFailure,
  type ReferenceImage,
} from "../_shared/storyboard-generation.ts";
import { runStoryboardGeneration, serviceRoleKey } from "./generation-job.ts";

type GenerateStoryboardRequest = {
  clientEntryID?: string;
  prompt?: string;
  artStyle?: string;
  quality?: string;
  referenceImagePaths?: string[];
};

type PreparedRequest = {
  apiKey: string;
  client: SupabaseClient;
  userID: string;
  clientEntryID: string;
  prompt: string;
  artStyle: string | null;
  quality: string;
  references: ReferenceImage[];
  referenceImagePaths: string[];
};

type StoryboardRow = {
  id: string;
  client_entry_id: string;
  storage_path: string;
  art_style: string | null;
  generation_quality: string | null;
  panel_layout: string | null;
  is_primary: boolean;
  generation_status: string;
  created_at: string;
  updated_at: string;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  // Everything that can fail cheaply happens before the reservation, so the common failures never
  // need a refund at all.
  let prepared: PreparedRequest;
  try {
    prepared = await prepareRequest(request);
  } catch (error) {
    return failureResponse(error, "generate-storyboard");
  }

  const { apiKey, client, userID, clientEntryID, prompt, artStyle, quality, references, referenceImagePaths } =
    prepared;

  const storyboardID = crypto.randomUUID();
  const storagePath = `${userID}/${clientEntryID}/${storyboardID}.jpg`;

  // Spending the credit and writing the pending row are one transaction inside the RPC, so there is
  // no window where the user is charged for a job that does not exist.
  let reservedRow: StoryboardRow;
  try {
    reservedRow = await reserveGeneration(client, {
      storyboardID,
      clientEntryID,
      storagePath,
      artStyle,
      quality,
      prompt,
      creditCost: CREDIT_COST_BY_QUALITY[quality],
    });
  } catch (error) {
    return failureResponse(error, "generate-storyboard");
  }

  // The background job builds its own service-role client. The caller's client stops here: nothing
  // after the response depends on the caller's session still existing or its token still being
  // valid.
  runInBackground(
    runStoryboardGeneration({
      apiKey,
      storyboardID,
      storagePath,
      prompt,
      quality,
      references,
      referenceImagePaths,
    }),
  );

  // 202: the storyboard is accepted and reserved, not finished. The client stores this id and polls
  // the row; it must not expect an image at `storagePath` yet.
  return jsonResponse(
    {
      storyboardID: reservedRow.id,
      clientEntryID: reservedRow.client_entry_id,
      storagePath: reservedRow.storage_path,
      artStyle: reservedRow.art_style,
      quality: reservedRow.generation_quality,
      panelLayout: reservedRow.panel_layout,
      isPrimary: reservedRow.is_primary,
      generationStatus: reservedRow.generation_status,
      createdAt: reservedRow.created_at,
      updatedAt: reservedRow.updated_at,
    },
    202,
  );
});

/// `EdgeRuntime.waitUntil` is what keeps the isolate alive past the response. Outside the Edge
/// Runtime — a local `deno serve`, a test — there is no such guarantee, so the work is started
/// anyway and its failure logged rather than silently swallowed.
function runInBackground(work: Promise<unknown>): void {
  const runtime = (globalThis as {
    EdgeRuntime?: { waitUntil?: (promise: Promise<unknown>) => void };
  }).EdgeRuntime;

  if (typeof runtime?.waitUntil === "function") {
    runtime.waitUntil(work);
    return;
  }

  void work.catch((error) => {
    console.error("[generate-storyboard] background generation failed:", error);
  });
}

async function prepareRequest(request: Request): Promise<PreparedRequest> {
  const apiKey = openAIKey();

  // Checked here, before a credit is spent, because the background job cannot report its own
  // misconfiguration: without server credentials it can neither fail the row nor refund it, and the
  // generation would sit pending until the sweeper picked it up.
  serviceRoleKey();

  const { client, userID } = await authenticateCaller(request);

  let payload: GenerateStoryboardRequest;
  try {
    payload = await request.json();
  } catch {
    throw new StoryboardFailure("Invalid JSON body.", 400);
  }

  const clientEntryID = requireUUID(payload.clientEntryID, "Missing client entry id.");
  const prompt = requirePrompt(payload.prompt);
  const artStyle = optionalText(payload.artStyle);
  const quality = requireQuality(payload.quality);
  const referenceImagePaths = parseReferenceImagePaths(payload.referenceImagePaths, userID);

  await assertEntryExists(client, userID, clientEntryID);

  // Read while the caller is still waiting. The bytes belong to the background job from here on, so
  // the staged files can be cleaned up afterwards without racing the generation.
  const references = await downloadReferenceImages(client, referenceImagePaths);

  return { apiKey, client, userID, clientEntryID, prompt, artStyle, quality, references, referenceImagePaths };
}

async function assertEntryExists(
  client: SupabaseClient,
  userID: string,
  clientEntryID: string,
): Promise<void> {
  const { data, error } = await client
    .from("entries")
    .select("client_entry_id")
    .eq("user_id", userID)
    .eq("client_entry_id", clientEntryID)
    .maybeSingle();

  if (error) {
    throw new StoryboardFailure("Could not read this entry.", 500);
  }

  if (!data) {
    throw new StoryboardFailure("This entry was not found in Storytopia cloud.", 404);
  }
}

async function reserveGeneration(
  client: SupabaseClient,
  reservation: {
    storyboardID: string;
    clientEntryID: string;
    storagePath: string;
    artStyle: string | null;
    quality: string;
    prompt: string;
    creditCost: number;
  },
): Promise<StoryboardRow> {
  const { data, error } = await client.rpc("reserve_storyboard_generation", {
    storyboard_id: reservation.storyboardID,
    client_entry_id: reservation.clientEntryID,
    storage_path: reservation.storagePath,
    art_style: reservation.artStyle,
    generation_quality: reservation.quality,
    prompt: reservation.prompt,
    credit_cost: reservation.creditCost,
  });

  if (!error && data) {
    return (Array.isArray(data) ? data[0] : data) as StoryboardRow;
  }

  const message = error?.message ?? "";

  if (message.includes("insufficient_generation_credits")) {
    throw new StoryboardFailure("You do not have enough credits to generate this storyboard.", 402);
  }

  if (message.includes("not_authenticated")) {
    throw new StoryboardFailure("Sign in before generating a storyboard.", 401);
  }

  if (message.includes("entry_not_found")) {
    throw new StoryboardFailure("This entry was not found in Storytopia cloud.", 404);
  }

  console.error("[generate-storyboard] reserve_storyboard_generation failed:", message);
  throw new StoryboardFailure("The storyboard could not be started. Please try again.", 500);
}
