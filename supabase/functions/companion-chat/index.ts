import {
  authenticateCaller,
  jsonResponse,
  StoryboardFailure,
} from "../_shared/storyboard-generation.ts";

const OPENAI_RESPONSES_ENDPOINT = "https://api.openai.com/v1/responses";
const CHAT_MODEL = Deno.env.get("OPENAI_CHAT_MODEL") ?? "gpt-5.6-luna";
const OPENAI_TIMEOUT_MS = 45_000;
const MAX_MESSAGE_LENGTH = 2_000;
const MAX_ENTRY_CONTEXT_LENGTH = 6_000;
const MAX_RECENT_MESSAGES = 12;

type CompanionChatRequest = {
  message?: string;
  entryText?: string;
  characterName?: string;
  recentMessages?: CompanionChatHistoryMessage[];
};

type CompanionChatHistoryMessage = {
  role?: "writer" | "companion";
  text?: string;
};

type OpenAIResponse = {
  output_text?: string;
  output?: Array<{
    type?: string;
    content?: Array<{
      type?: string;
      text?: string;
    }>;
  }>;
  error?: {
    message?: string;
  };
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    await authenticateCaller(request, "Sign in before chatting with Luna.");
    const payload = await companionPayload(request);
    const reply = await createCompanionReply(payload);
    return jsonResponse({ reply });
  } catch (error) {
    if (error instanceof StoryboardFailure) {
      return jsonResponse({ error: error.message }, error.status);
    }

    console.error("[companion-chat] unexpected failure:", error);
    return jsonResponse({ error: "Luna could not reply right now." }, 500);
  }
});

async function companionPayload(request: Request): Promise<Required<CompanionChatRequest>> {
  let payload: CompanionChatRequest;
  try {
    payload = await request.json();
  } catch {
    throw new StoryboardFailure("Invalid JSON body.", 400);
  }

  const message = clippedText(payload.message, MAX_MESSAGE_LENGTH);
  if (!message) {
    throw new StoryboardFailure("Missing chat message.", 400);
  }

  return {
    message,
    entryText: clippedText(payload.entryText, MAX_ENTRY_CONTEXT_LENGTH),
    characterName: clippedText(payload.characterName, 80) || "Luna",
    recentMessages: sanitizedRecentMessages(payload.recentMessages),
  };
}

async function createCompanionReply(payload: Required<CompanionChatRequest>): Promise<string> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    throw new StoryboardFailure("Companion chat is not configured.", 500);
  }

  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), OPENAI_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(OPENAI_RESPONSES_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      signal: abortController.signal,
      body: JSON.stringify({
        model: CHAT_MODEL,
        instructions: companionInstructions(payload.characterName),
        max_output_tokens: 450,
        store: false,
        input: companionInput(payload),
      }),
    });
  } catch (error) {
    console.error("[companion-chat] OpenAI transport failed:", error);
    throw new StoryboardFailure("Luna could not reach OpenAI right now.", 502);
  } finally {
    clearTimeout(timeout);
  }

  const body = await openAIResponseBody(response);
  if (!response.ok) {
    console.error("[companion-chat] OpenAI request failed:", body.error?.message ?? response.status);
    throw new StoryboardFailure("Luna could not reply right now.", response.status);
  }

  const reply = responseText(body);
  if (!reply) {
    throw new StoryboardFailure("Luna sent an empty reply.", 500);
  }

  return reply;
}

async function openAIResponseBody(response: Response): Promise<OpenAIResponse> {
  const text = await response.text();
  if (!text) {
    return {};
  }

  try {
    return JSON.parse(text) as OpenAIResponse;
  } catch {
    console.error("[companion-chat] OpenAI returned non-JSON response:", text.slice(0, 400));
    throw new StoryboardFailure("Luna received an unreadable response from OpenAI.", 502);
  }
}

function companionInstructions(characterName: string): string {
  return [
    `You are ${characterName}, a warm journaling companion inside Journaltopia.`,
    "Speak directly to the writer in a calm, human, concise voice.",
    "Help them reflect, continue writing, notice feelings, and find one small next step.",
    "Do not claim to be a therapist or medical professional.",
    "If the writer may be in immediate danger, encourage them to contact local emergency services or a trusted person right away.",
    "Keep most replies to 2-4 short sentences unless the writer asks for more.",
    "Use plain text only. Do not use Markdown, asterisks, bold, italics, bullets, numbered lists, headings, or code formatting.",
  ].join("\n");
}

function companionInput(payload: Required<CompanionChatRequest>): string {
  const lines = [
    "CURRENT ENTRY CONTEXT:",
    payload.entryText || "(The entry is empty or was not shared.)",
    "",
    "RECENT CHAT:",
    ...payload.recentMessages.map((message) =>
      `${message.role === "writer" ? "Writer" : payload.characterName}: ${message.text}`
    ),
    "",
    `WRITER MESSAGE: ${payload.message}`,
  ];

  return lines.join("\n");
}

function responseText(body: OpenAIResponse): string {
  if (typeof body.output_text === "string") {
    return body.output_text.trim();
  }

  for (const item of body.output ?? []) {
    for (const content of item.content ?? []) {
      if (content.type === "output_text" && typeof content.text === "string") {
        return content.text.trim();
      }
    }
  }

  return "";
}

function sanitizedRecentMessages(
  messages: CompanionChatHistoryMessage[] | undefined,
): Array<Required<CompanionChatHistoryMessage>> {
  const sanitized: Array<Required<CompanionChatHistoryMessage>> = [];

  for (const message of (messages ?? []).slice(-MAX_RECENT_MESSAGES)) {
    const role = message.role === "writer" ? "writer" : "companion";
    const text = clippedText(message.text, MAX_MESSAGE_LENGTH);
    if (text) {
      sanitized.push({ role, text });
    }
  }

  return sanitized;
}

function clippedText(value: string | undefined, maxLength: number): string {
  const text = value?.trim() ?? "";
  return text.length > maxLength ? text.slice(0, maxLength).trim() : text;
}
