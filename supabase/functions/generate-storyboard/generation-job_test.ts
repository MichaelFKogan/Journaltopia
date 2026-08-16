// Tests for the background half of generate-storyboard. The database transitions are covered by
// supabase/tests/storyboard_generation_lifecycle_test.sql; what matters here is that the job calls
// them in the right order, stands down when it does not own the row, and never invents a refund.
//
// Run with: deno test --allow-net supabase/functions/generate-storyboard/generation-job_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { StoryboardFailure, type ReferenceImage } from "../_shared/storyboard-generation.ts";
import {
  runStoryboardGeneration,
  safeGenerationErrorMessage,
  STORYBOARD_BUCKET,
  type StoryboardGenerationJob,
} from "./generation-job.ts";

type RpcCall = { name: string; params: Record<string, unknown> };
type UploadCall = { bucket: string; storagePath: string; byteLength: number };

type FakeClientOptions = {
  rpcResults?: Record<string, { data?: unknown; error?: { message: string } }>;
};

function fakeClient(options: FakeClientOptions = {}) {
  const rpcCalls: RpcCall[] = [];
  const removedPaths: string[][] = [];

  const client = {
    rpc(name: string, params: Record<string, unknown>) {
      rpcCalls.push({ name, params });
      const result = options.rpcResults?.[name] ?? { data: null };
      return Promise.resolve({ data: result.data ?? null, error: result.error ?? null });
    },
    storage: {
      from(_bucket: string) {
        return {
          remove(paths: string[]) {
            removedPaths.push(paths);
            return Promise.resolve({ data: null, error: null });
          },
        };
      },
    },
  };

  return { client: client as unknown as SupabaseClient, rpcCalls, removedPaths };
}

function makeJob(client: SupabaseClient, overrides: Partial<StoryboardGenerationJob> = {}): StoryboardGenerationJob {
  const references: ReferenceImage[] = [{ fileName: "1-main.jpg", blob: new Blob([new Uint8Array([1, 2])]) }];

  return {
    client,
    apiKey: "test-key",
    storyboardID: "11111111-1111-4111-8111-111111111111",
    storagePath: "user/entry/storyboard.jpg",
    prompt: "a quiet afternoon",
    quality: "low",
    references,
    referenceImagePaths: ["user/entries/entry/generation-inputs/req/1-main.jpg"],
    ...overrides,
  };
}

function stubDependencies(options: {
  generate?: () => Promise<Uint8Array>;
  uploads?: UploadCall[];
} = {}) {
  const uploads = options.uploads ?? [];
  const generateCalls: Array<{ prompt: string; quality: string; referenceCount: number }> = [];

  return {
    uploads,
    generateCalls,
    dependencies: {
      generateImage: (input: { prompt: string; quality: string; references: ReferenceImage[] }) => {
        generateCalls.push({
          prompt: input.prompt,
          quality: input.quality,
          referenceCount: input.references.length,
        });
        return options.generate ? options.generate() : Promise.resolve(new Uint8Array([9, 9, 9]));
      },
      uploadImage: (
        _client: SupabaseClient,
        bucket: string,
        storagePath: string,
        imageBytes: Uint8Array,
      ) => {
        uploads.push({ bucket, storagePath, byteLength: imageBytes.byteLength });
        return Promise.resolve();
      },
    },
  };
}

Deno.test("a claimed job generates, uploads, and completes the row", async () => {
  const { client, rpcCalls, removedPaths } = fakeClient({
    rpcResults: {
      start_storyboard_generation: { data: true },
      complete_storyboard_generation: { data: { id: "row", generation_status: "completed" } },
    },
  });
  const { dependencies, uploads, generateCalls } = stubDependencies();
  const job = makeJob(client);

  const result = await runStoryboardGeneration(job, dependencies);

  assertEquals(result.status, "completed");
  assertEquals(rpcCalls.map((call) => call.name), [
    "start_storyboard_generation",
    "complete_storyboard_generation",
  ]);
  assertEquals(generateCalls, [{ prompt: "a quiet afternoon", quality: "low", referenceCount: 1 }]);
  assertEquals(uploads, [{
    bucket: STORYBOARD_BUCKET,
    storagePath: "user/entry/storyboard.jpg",
    byteLength: 3,
  }]);
  assertEquals(rpcCalls[1].params, {
    storyboard_id: job.storyboardID,
    storage_path: job.storagePath,
    panel_layout: null,
  });
  // Staged reference images are the job's to clean up, since the client is long gone by now.
  assertEquals(removedPaths, [job.referenceImagePaths]);
});

Deno.test("an unclaimed job does no work and spends nothing", async () => {
  const { client, rpcCalls, removedPaths } = fakeClient({
    rpcResults: { start_storyboard_generation: { data: false } },
  });
  const { dependencies, uploads, generateCalls } = stubDependencies();

  const result = await runStoryboardGeneration(makeJob(client), dependencies);

  assertEquals(result, { status: "skipped", reason: "already-claimed" });
  assertEquals(generateCalls.length, 0);
  assertEquals(uploads.length, 0);
  assertEquals(rpcCalls.map((call) => call.name), ["start_storyboard_generation"]);
  assertEquals(removedPaths.length, 1);
});

Deno.test("a generation failure fails the row and reports the refund the database made", async () => {
  const { client, rpcCalls } = fakeClient({
    rpcResults: {
      start_storyboard_generation: { data: true },
      fail_storyboard_generation: {
        data: [{ id: "row", generation_status: "failed", refunded_credits: 2 }],
      },
    },
  });
  const { dependencies } = stubDependencies({
    generate: () => Promise.reject(new StoryboardFailure("OpenAI is rate limiting requests.", 429)),
  });

  const result = await runStoryboardGeneration(makeJob(client), dependencies);

  assertEquals(result, {
    status: "failed",
    message: "OpenAI is rate limiting requests.",
    refundedCredits: 2,
  });
  assertEquals(rpcCalls.map((call) => call.name), [
    "start_storyboard_generation",
    "fail_storyboard_generation",
  ]);
  assertEquals(rpcCalls[1].params.generation_error, "OpenAI is rate limiting requests.");
});

Deno.test("a row the database already settled reports no second refund", async () => {
  // The sweeper got there first: the transition returns the refund that was already made, not a new
  // one. The job reports zero rather than assuming it just refunded something.
  const { client } = fakeClient({
    rpcResults: {
      start_storyboard_generation: { data: true },
      fail_storyboard_generation: {
        data: [{ id: "row", generation_status: "failed", refunded_credits: 0 }],
      },
    },
  });
  const { dependencies } = stubDependencies({
    generate: () => Promise.reject(new StoryboardFailure("OpenAI did not return a storyboard image.", 502)),
  });

  const result = await runStoryboardGeneration(makeJob(client), dependencies);

  assertEquals(result, {
    status: "failed",
    message: "OpenAI did not return a storyboard image.",
    refundedCredits: 0,
  });
});

Deno.test("a failing transition that cannot be written is left to the sweeper", async () => {
  const { client } = fakeClient({
    rpcResults: {
      start_storyboard_generation: { data: true },
      fail_storyboard_generation: { error: { message: "connection reset" } },
    },
  });
  const { dependencies } = stubDependencies({
    generate: () => Promise.reject(new StoryboardFailure("The storyboard request timed out.", 504)),
  });

  const result = await runStoryboardGeneration(makeJob(client), dependencies);

  // No refund is claimed and no status is invented: the row stays non-terminal on purpose.
  assertEquals(result, {
    status: "failed",
    message: "The storyboard request timed out.",
    refundedCredits: null,
  });
});

Deno.test("an upload failure fails the generation rather than completing it", async () => {
  const { client, rpcCalls } = fakeClient({
    rpcResults: {
      start_storyboard_generation: { data: true },
      fail_storyboard_generation: {
        data: [{ id: "row", generation_status: "failed", refunded_credits: 1 }],
      },
    },
  });
  const { dependencies } = stubDependencies();
  dependencies.uploadImage = () =>
    Promise.reject(new StoryboardFailure("The generated storyboard could not be saved.", 500));

  const result = await runStoryboardGeneration(makeJob(client), dependencies);

  assertEquals(result.status, "failed");
  assertEquals(rpcCalls.map((call) => call.name), [
    "start_storyboard_generation",
    "fail_storyboard_generation",
  ]);
});

Deno.test("only messages this function raised reach the user", () => {
  assertEquals(
    safeGenerationErrorMessage(new StoryboardFailure("You do not have enough credits.", 402)),
    "You do not have enough credits.",
  );
  assertEquals(
    safeGenerationErrorMessage(new Error('relation "entry_storyboards" does not exist')),
    "The storyboard could not be generated. Please try again.",
  );
  assertEquals(
    safeGenerationErrorMessage("something threw a string"),
    "The storyboard could not be generated. Please try again.",
  );
  assertEquals(safeGenerationErrorMessage(new StoryboardFailure("x".repeat(900), 500)).length, 500);
});
