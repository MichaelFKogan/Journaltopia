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
  requestStoryboardImage,
  requirePrompt,
  requireQuality,
  requireUUID,
  StoryboardFailure,
  uploadGeneratedImage,
  type ReferenceImage,
} from "../_shared/storyboard-generation.ts";

const STORYBOARD_BUCKET = "generated-storyboards";

const STORYBOARD_ROW_COLUMNS =
  "id,client_entry_id,storage_path,art_style,generation_quality,panel_layout,is_primary,generation_status,created_at,updated_at";

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

  // Everything that can fail cheaply happens before the reservation so the common failures never
  // need a refund at all.
  let prepared: PreparedRequest;
  try {
    prepared = await prepareRequest(request);
  } catch (error) {
    return failureResponse(error, "generate-storyboard");
  }

  const { apiKey, client, userID, clientEntryID, prompt, artStyle, quality, references } = prepared;
  const creditCost = CREDIT_COST_BY_QUALITY[quality];

  try {
    await reserveCredit(client, creditCost);
  } catch (error) {
    return failureResponse(error, "generate-storyboard");
  }

  const storyboardID = crypto.randomUUID();
  const storagePath = `${userID}/${clientEntryID}/${storyboardID}.jpg`;

  try {
    await upsertStoryboardRow(client, {
      storyboardID,
      userID,
      clientEntryID,
      storagePath,
      artStyle,
      quality,
      prompt,
      isPrimary: false,
      generationStatus: "pending",
    });

    const imageBytes = await requestStoryboardImage({ apiKey, prompt, quality, references });

    await uploadGeneratedImage(client, STORYBOARD_BUCKET, storagePath, imageBytes);
    await markPriorStoryboardsNonPrimary(client, userID, clientEntryID, storyboardID);

    // The completed row is echoed back so the client can adopt this storyboard instead of
    // uploading and inserting a second copy of the same image.
    const completedRow = await upsertStoryboardRow(client, {
      storyboardID,
      userID,
      clientEntryID,
      storagePath,
      artStyle,
      quality,
      prompt,
      isPrimary: true,
      generationStatus: "completed",
    });

    return jsonResponse({
      storyboardID: completedRow.id,
      clientEntryID: completedRow.client_entry_id,
      storagePath: completedRow.storage_path,
      artStyle: completedRow.art_style,
      quality: completedRow.generation_quality,
      panelLayout: completedRow.panel_layout,
      isPrimary: completedRow.is_primary,
      generationStatus: completedRow.generation_status,
      createdAt: completedRow.created_at,
      updatedAt: completedRow.updated_at,
    });
  } catch (error) {
    // The reservation only buys an image that actually exists, so anything that goes wrong after
    // it has to hand the credit back before the caller sees the error.
    await markStoryboardFailed(client, storyboardID);
    await refundCredit(client, creditCost);
    return failureResponse(error, "generate-storyboard");
  }
});

async function prepareRequest(request: Request): Promise<PreparedRequest> {
  const apiKey = openAIKey();
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
  const references = await downloadReferenceImages(client, referenceImagePaths);

  return { apiKey, client, userID, clientEntryID, prompt, artStyle, quality, references };
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

async function reserveCredit(client: SupabaseClient, creditCost: number): Promise<void> {
  const { error } = await client.rpc("spend_generation_credit", { credit_cost: creditCost });
  if (!error) {
    return;
  }

  const message = error.message ?? "";
  if (message.includes("insufficient_generation_credits")) {
    throw new StoryboardFailure("You do not have enough credits to generate this storyboard.", 402);
  }

  if (message.includes("not_authenticated")) {
    throw new StoryboardFailure("Sign in before generating a storyboard.", 401);
  }

  console.error("[generate-storyboard] spend_generation_credit failed:", message);
  throw new StoryboardFailure("Credits are unavailable right now. Please try again.", 500);
}

async function refundCredit(client: SupabaseClient, creditCost: number): Promise<void> {
  const { error } = await client.rpc("refund_generation_credit", { credit_cost: creditCost });
  if (error) {
    // A failed refund must not replace the error that caused it, so it is logged and swallowed.
    console.error("[generate-storyboard] refund_generation_credit failed:", error.message);
  }
}

async function upsertStoryboardRow(
  client: SupabaseClient,
  row: {
    storyboardID: string;
    userID: string;
    clientEntryID: string;
    storagePath: string;
    artStyle: string | null;
    quality: string;
    prompt: string;
    isPrimary: boolean;
    generationStatus: string;
  },
): Promise<StoryboardRow> {
  const { data, error } = await client
    .from("entry_storyboards")
    .upsert(
      {
        id: row.storyboardID,
        user_id: row.userID,
        client_entry_id: row.clientEntryID,
        storage_path: row.storagePath,
        art_style: row.artStyle,
        generation_quality: row.quality,
        panel_layout: null,
        prompt: row.prompt,
        is_primary: row.isPrimary,
        generation_status: row.generationStatus,
      },
      { onConflict: "id" },
    )
    .select(STORYBOARD_ROW_COLUMNS)
    .single();

  if (error || !data) {
    console.error("[generate-storyboard] entry_storyboards upsert failed:", error?.message);
    throw new StoryboardFailure("The storyboard could not be recorded in Storytopia cloud.", 500);
  }

  return data as StoryboardRow;
}

async function markStoryboardFailed(client: SupabaseClient, storyboardID: string): Promise<void> {
  const { error } = await client
    .from("entry_storyboards")
    .update({ generation_status: "failed", is_primary: false })
    .eq("id", storyboardID);

  if (error) {
    console.error("[generate-storyboard] failed-status update skipped:", error.message);
  }
}

async function markPriorStoryboardsNonPrimary(
  client: SupabaseClient,
  userID: string,
  clientEntryID: string,
  storyboardID: string,
): Promise<void> {
  const { error } = await client
    .from("entry_storyboards")
    .update({ is_primary: false })
    .eq("user_id", userID)
    .eq("client_entry_id", clientEntryID)
    .eq("is_primary", true)
    .neq("id", storyboardID);

  if (error) {
    throw new StoryboardFailure("The storyboard could not be recorded in Storytopia cloud.", 500);
  }
}
