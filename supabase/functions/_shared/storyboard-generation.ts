// Shared by generate-storyboard (real user entries) and generate-sample-storyboard (Sample Studio
// authoring). Only the pieces both flows genuinely have in common live here: caller authentication,
// request validation, reference image loading, and the OpenAI call. Ownership checks, credits, and
// persistence stay in each function because those are exactly what differ.
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_EDITS_ENDPOINT = "https://api.openai.com/v1/images/edits";
const OPENAI_GENERATIONS_ENDPOINT = "https://api.openai.com/v1/images/generations";

export const IMAGE_MODEL = Deno.env.get("OPENAI_IMAGE_MODEL") ?? "gpt-image-2";
export const IMAGE_SIZE = "1024x1536";
export const IMAGE_OUTPUT_FORMAT = "jpeg";
export const IMAGE_CONTENT_TYPE = "image/jpeg";
export const OPENAI_TIMEOUT_MS = 300_000;

// Generation inputs are staged in the caller's own media folder by the app, never in a shared or
// sample bucket, so both flows read references from the same place.
export const REFERENCE_BUCKET = "journaltopia-media";

// Mirrors EntryCharacterRules.maxGenerationImageCount and OpenAIImageGenerationQuality.creditCost.
export const MAX_REFERENCE_IMAGE_COUNT = 5;
export const CREDIT_COST_BY_QUALITY: Record<string, number> = {
  low: 1,
  medium: 2,
};

export type ReferenceImage = {
  fileName: string;
  blob: Blob;
};

export class StoryboardFailure extends Error {
  readonly status: number;
  /// A stable identifier for refusals the app has to *route* on rather than merely display.
  ///
  /// The message is written for a person and will be reworded; the code is a contract. Absent for
  /// the ordinary failures, which the app only ever shows.
  readonly code: string | null;

  constructor(message: string, status = 500, code: string | null = null) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/// Refusals the client routes on: one to the Journaltopia+ paywall, one to buying credits.
export const STORYBOARD_REFUSAL_SUBSCRIPTION_REQUIRED = "subscription_required";
export const STORYBOARD_REFUSAL_INSUFFICIENT_CREDITS = "insufficient_generation_credits";

export function openAIKey(): string {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) {
    throw new StoryboardFailure("Storyboard generation is not configured.", 500);
  }

  return key;
}

/// Builds a client that acts as the caller, so RLS and auth.uid() decide what the request can read,
/// write, and spend. The identity it returns comes from verifying the caller's own JWT — never from
/// anything the request body says — which is what makes it safe for callers whose whole purpose is
/// to act on "the account that is asking", `delete-account` above all.
///
/// `unauthenticatedMessage` exists because the 401 is read by a person in whichever screen they were
/// standing in; the storyboard wording is the default only because it came first.
export async function authenticateCaller(
  request: Request,
  unauthenticatedMessage = "Sign in before generating a storyboard.",
): Promise<{ client: SupabaseClient; userID: string }> {
  const projectURL = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!projectURL || !anonKey) {
    throw new StoryboardFailure("Storyboard generation is not configured.", 500);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    throw new StoryboardFailure(unauthenticatedMessage, 401);
  }

  const client = createClient(projectURL, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await client.auth.getUser();
  if (error || !data?.user) {
    throw new StoryboardFailure(unauthenticatedMessage, 401);
  }

  return { client, userID: data.user.id };
}

export function requireUUID(value: string | undefined, message: string): string {
  const candidate = value?.trim().toLowerCase();
  if (!candidate || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(candidate)) {
    throw new StoryboardFailure(message, 400);
  }

  return candidate;
}

export function requirePrompt(value: string | undefined): string {
  const prompt = value?.trim();
  if (!prompt) {
    throw new StoryboardFailure("Missing storyboard prompt.", 400);
  }

  return prompt;
}

export function requireQuality(value: string | undefined): string {
  const quality = value?.trim() ?? "";
  if (!Object.hasOwn(CREDIT_COST_BY_QUALITY, quality)) {
    throw new StoryboardFailure("Unsupported generation quality.", 400);
  }

  return quality;
}

export function optionalText(value: string | undefined): string | null {
  const text = value?.trim();
  return text && text.length > 0 ? text : null;
}

export function parseReferenceImagePaths(value: unknown, userID: string): string[] {
  const rawPaths = value ?? [];
  if (!Array.isArray(rawPaths)) {
    throw new StoryboardFailure("Reference image paths must be an array.", 400);
  }

  const paths = rawPaths
    .slice(0, MAX_REFERENCE_IMAGE_COUNT)
    .map((path) => (typeof path === "string" ? path.trim() : ""));

  for (const path of paths) {
    // Storage RLS already scopes reads to the caller's folder; this keeps a malformed or hostile
    // path from turning into a confusing storage error instead of a clear rejection.
    if (!path || !path.startsWith(`${userID}/`) || path.includes("..")) {
      throw new StoryboardFailure("Invalid reference image path.", 400);
    }
  }

  return paths;
}

export async function downloadReferenceImages(
  client: SupabaseClient,
  paths: string[],
): Promise<ReferenceImage[]> {
  const references: ReferenceImage[] = [];

  for (const path of paths) {
    const { data, error } = await client.storage.from(REFERENCE_BUCKET).download(path);
    if (error || !data) {
      throw new StoryboardFailure("A reference image could not be read.", 400);
    }

    references.push({
      fileName: path.split("/").pop() || "reference.jpg",
      blob: data,
    });
  }

  return references;
}

export async function requestStoryboardImage(options: {
  apiKey: string;
  prompt: string;
  quality: string;
  references: ReferenceImage[];
}): Promise<Uint8Array> {
  const { apiKey, prompt, quality, references } = options;

  let response: Response;
  try {
    response = references.length > 0
      ? await fetch(OPENAI_EDITS_ENDPOINT, {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
        body: editsFormData({ prompt, quality, references }),
        signal: AbortSignal.timeout(OPENAI_TIMEOUT_MS),
      })
      : await fetch(OPENAI_GENERATIONS_ENDPOINT, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: IMAGE_MODEL,
          prompt,
          size: IMAGE_SIZE,
          quality,
          output_format: IMAGE_OUTPUT_FORMAT,
        }),
        signal: AbortSignal.timeout(OPENAI_TIMEOUT_MS),
      });
  } catch (error) {
    console.error("[storyboard-generation] OpenAI request failed:", error);
    throw new StoryboardFailure("The storyboard request timed out. Please try again.", 504);
  }

  if (!response.ok) {
    const message = await openAIErrorMessage(response);
    throw new StoryboardFailure(message, response.status === 429 ? 429 : 502);
  }

  let body: { data?: Array<{ b64_json?: string }> };
  try {
    body = await response.json();
  } catch {
    throw new StoryboardFailure("OpenAI returned a response Journaltopia could not read.", 502);
  }

  const base64Image = body.data?.[0]?.b64_json;
  if (!base64Image) {
    throw new StoryboardFailure("OpenAI did not return a storyboard image.", 502);
  }

  return decodeBase64(base64Image);
}

export async function uploadGeneratedImage(
  client: SupabaseClient,
  bucket: string,
  storagePath: string,
  imageBytes: Uint8Array,
): Promise<void> {
  const { error } = await client.storage
    .from(bucket)
    .upload(storagePath, imageBytes, {
      cacheControl: "31536000",
      contentType: IMAGE_CONTENT_TYPE,
      upsert: true,
    });

  if (error) {
    console.error("[storyboard-generation] storyboard upload failed:", error.message);
    throw new StoryboardFailure("The generated storyboard could not be saved.", 500);
  }
}

export function failureResponse(error: unknown, context: string): Response {
  if (error instanceof StoryboardFailure) {
    return jsonResponse(
      error.code ? { error: error.message, code: error.code } : { error: error.message },
      error.status,
    );
  }

  console.error(`[${context}] unexpected failure:`, error);
  return jsonResponse({ error: "The storyboard could not be generated." }, 500);
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(status === 204 ? null : JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    },
  });
}

function editsFormData(options: {
  prompt: string;
  quality: string;
  references: ReferenceImage[];
}): FormData {
  const form = new FormData();
  form.append("model", IMAGE_MODEL);
  form.append("prompt", options.prompt);
  form.append("size", IMAGE_SIZE);
  form.append("quality", options.quality);
  form.append("output_format", IMAGE_OUTPUT_FORMAT);

  // The prompt numbers its reference images, so upload order has to match the order the caller sent.
  options.references.forEach((reference, index) => {
    form.append("image[]", reference.blob, `${index + 1}-${reference.fileName}`);
  });

  return form;
}

async function openAIErrorMessage(response: Response): Promise<string> {
  try {
    const body = await response.json();
    const message = body?.error?.message;
    if (typeof message === "string" && message.length > 0) {
      return message;
    }
  } catch {
    // Fall through to the status-only message.
  }

  return `OpenAI returned status ${response.status}.`;
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}
