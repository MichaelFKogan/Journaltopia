// Sample Studio authoring path. Sample entries live in the sample_* tables, not in `entries`, so
// they cannot go through generate-storyboard — that function deliberately refuses anything the
// caller does not own in the normal entries table. This function does the same OpenAI work against
// the Sample Studio tables and bucket instead, gated on sample_story_admins membership.
import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  authenticateCaller,
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

const SAMPLE_BUCKET = "sample-story-assets";

const SAMPLE_PAGE_COLUMNS =
  "id,sample_entry_id,storage_path,page_index,is_primary,caption,art_style,generation_quality,panel_layout,created_at,updated_at";

type GenerateSampleStoryboardRequest = {
  sampleEntryID?: string;
  prompt?: string;
  artStyle?: string;
  quality?: string;
  referenceImagePaths?: string[];
};

type SampleStoryboardPageRow = {
  id: string;
  sample_entry_id: string;
  storage_path: string;
  page_index: number;
  is_primary: boolean;
  art_style: string | null;
  generation_quality: string | null;
  panel_layout: string | null;
  created_at: string;
  updated_at: string;
};

type PreparedRequest = {
  apiKey: string;
  client: SupabaseClient;
  sampleEntryID: string;
  packSlug: string;
  prompt: string;
  artStyle: string | null;
  quality: string;
  references: ReferenceImage[];
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  let prepared: PreparedRequest;
  try {
    prepared = await prepareRequest(request);
  } catch (error) {
    return failureResponse(error, "generate-sample-storyboard");
  }

  const { apiKey, client, sampleEntryID, packSlug, prompt, artStyle, quality, references } = prepared;

  try {
    // Sample Studio spends no generation credits, so there is no reservation to protect and nothing
    // is written until the image exists. A failure leaves no row and no object behind.
    const imageBytes = await requestStoryboardImage({ apiKey, prompt, quality, references });

    const storyboardID = crypto.randomUUID();
    const storagePath = [packSlug, sampleEntryID, "storyboards", `${storyboardID}.jpg`].join("/");
    const pageIndex = await nextPageIndex(client, sampleEntryID);

    await uploadGeneratedImage(client, SAMPLE_BUCKET, storagePath, imageBytes);

    const row = await insertSamplePage(client, {
      storyboardID,
      sampleEntryID,
      storagePath,
      pageIndex,
      artStyle,
      quality,
    });

    return jsonResponse({
      storyboardID: row.id,
      sampleEntryID: row.sample_entry_id,
      storagePath: row.storage_path,
      artStyle: row.art_style,
      quality: row.generation_quality,
      panelLayout: row.panel_layout,
      isPrimary: row.is_primary,
      pageIndex: row.page_index,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });
  } catch (error) {
    return failureResponse(error, "generate-sample-storyboard");
  }
});

async function prepareRequest(request: Request): Promise<PreparedRequest> {
  const apiKey = openAIKey();
  const { client, userID } = await authenticateCaller(request);

  let payload: GenerateSampleStoryboardRequest;
  try {
    payload = await request.json();
  } catch {
    throw new StoryboardFailure("Invalid JSON body.", 400);
  }

  const sampleEntryID = requireUUID(payload.sampleEntryID, "Missing sample entry id.");
  const prompt = requirePrompt(payload.prompt);
  const artStyle = optionalText(payload.artStyle);
  const quality = requireQuality(payload.quality);
  const referenceImagePaths = parseReferenceImagePaths(payload.referenceImagePaths, userID);

  await assertSampleStoryAdmin(client, userID);
  const packSlug = await sampleEntryPackSlug(client, sampleEntryID);
  const references = await downloadReferenceImages(client, referenceImagePaths);

  return { apiKey, client, sampleEntryID, packSlug, prompt, artStyle, quality, references };
}

/// RLS on the sample tables already restricts writes to sample_story_admins. Checking membership up
/// front turns a non-admin into a clear 403 instead of an opaque policy failure after the OpenAI
/// call has already been paid for.
async function assertSampleStoryAdmin(client: SupabaseClient, userID: string): Promise<void> {
  const { data, error } = await client
    .from("sample_story_admins")
    .select("user_id")
    .eq("user_id", userID)
    .maybeSingle();

  if (error) {
    console.error("[generate-sample-storyboard] admin lookup failed:", error.message);
    throw new StoryboardFailure("Could not verify Sample Studio access.", 500);
  }

  if (!data) {
    throw new StoryboardFailure("Sample Studio is limited to sample story admins.", 403);
  }
}

/// Sample storyboards are stored under the pack slug, matching SupabaseSampleStoryService. Reading
/// the slug from the entry's own pack also confirms the sample entry exists.
async function sampleEntryPackSlug(client: SupabaseClient, sampleEntryID: string): Promise<string> {
  const { data: entry, error: entryError } = await client
    .from("sample_entries")
    .select("id,pack_id")
    .eq("id", sampleEntryID)
    .maybeSingle();

  if (entryError) {
    console.error("[generate-sample-storyboard] sample entry lookup failed:", entryError.message);
    throw new StoryboardFailure("Could not read this sample entry.", 500);
  }

  if (!entry) {
    throw new StoryboardFailure("This sample entry was not found.", 404);
  }

  const { data: pack, error: packError } = await client
    .from("sample_story_packs")
    .select("slug")
    .eq("id", entry.pack_id)
    .maybeSingle();

  if (packError) {
    console.error("[generate-sample-storyboard] sample pack lookup failed:", packError.message);
    throw new StoryboardFailure("Could not read this sample pack.", 500);
  }

  if (!pack?.slug) {
    throw new StoryboardFailure("This sample entry has no readable pack.", 404);
  }

  return pack.slug as string;
}

async function nextPageIndex(client: SupabaseClient, sampleEntryID: string): Promise<number> {
  const { data, error } = await client
    .from("sample_storyboard_pages")
    .select("page_index")
    .eq("sample_entry_id", sampleEntryID)
    .order("page_index", { ascending: false })
    .limit(1);

  if (error) {
    console.error("[generate-sample-storyboard] page index lookup failed:", error.message);
    throw new StoryboardFailure("Could not read existing sample storyboard pages.", 500);
  }

  return (data?.[0]?.page_index ?? -1) + 1;
}

async function insertSamplePage(
  client: SupabaseClient,
  row: {
    storyboardID: string;
    sampleEntryID: string;
    storagePath: string;
    pageIndex: number;
    artStyle: string | null;
    quality: string;
  },
): Promise<SampleStoryboardPageRow> {
  const { data, error } = await client
    .from("sample_storyboard_pages")
    .upsert(
      {
        id: row.storyboardID,
        sample_entry_id: row.sampleEntryID,
        storage_path: row.storagePath,
        page_index: row.pageIndex,
        // Matches SupabaseSampleStoryService: the first page of a sample entry is its primary one.
        is_primary: row.pageIndex === 0,
        caption: null,
        art_style: row.artStyle,
        generation_quality: row.quality,
        panel_layout: null,
      },
      { onConflict: "id" },
    )
    .select(SAMPLE_PAGE_COLUMNS)
    .single();

  if (error || !data) {
    console.error("[generate-sample-storyboard] sample page insert failed:", error?.message);
    throw new StoryboardFailure("The sample storyboard could not be recorded.", 500);
  }

  return data as SampleStoryboardPageRow;
}
