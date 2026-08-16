const UNSPLASH_API_URL = "https://api.unsplash.com";
const UTM_SOURCE = Deno.env.get("UNSPLASH_UTM_SOURCE") ?? "journaltopia";

type CoverRequest = {
  action?: "search" | "track_download";
  query?: string;
  page?: number;
  per_page?: number;
  download_location?: string;
};

type UnsplashPhoto = {
  id: string;
  color?: string | null;
  urls: {
    regular: string;
    small: string;
    thumb: string;
  };
  links: {
    download_location: string;
  };
  user: {
    name: string;
    links: {
      html: string;
    };
  };
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return jsonResponse({}, 204);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  const accessKey = Deno.env.get("UNSPLASH_ACCESS_KEY");
  if (!accessKey) {
    return jsonResponse({ error: "Unsplash is not configured." }, 500);
  }

  let payload: CoverRequest;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400);
  }

  if (payload.action === "track_download") {
    return trackDownload(payload, accessKey);
  }

  return searchPhotos(payload, accessKey);
});

async function searchPhotos(payload: CoverRequest, accessKey: string): Promise<Response> {
  const query = payload.query?.trim();
  if (!query) {
    return jsonResponse({ results: [] });
  }

  const searchURL = new URL(`${UNSPLASH_API_URL}/search/photos`);
  searchURL.searchParams.set("query", query);
  searchURL.searchParams.set("page", String(Math.max(payload.page ?? 1, 1)));
  searchURL.searchParams.set("per_page", String(Math.min(Math.max(payload.per_page ?? 18, 1), 30)));
  searchURL.searchParams.set("orientation", "portrait");
  searchURL.searchParams.set("content_filter", "high");

  const response = await fetch(searchURL, {
    headers: unsplashHeaders(accessKey),
  });

  if (!response.ok) {
    return jsonResponse({ error: "Unsplash search failed." }, response.status);
  }

  const body = await response.json();
  const results = (body.results ?? []).map((photo: UnsplashPhoto) => ({
    id: photo.id,
    colorHex: photo.color ?? null,
    imageURL: photo.urls.regular,
    thumbnailURL: photo.urls.small ?? photo.urls.thumb,
    attributionName: photo.user.name,
    attributionURL: attributionURL(photo.user.links.html),
    downloadLocation: photo.links.download_location,
  }));

  return jsonResponse({ results });
}

async function trackDownload(payload: CoverRequest, accessKey: string): Promise<Response> {
  const rawLocation = payload.download_location?.trim();
  if (!rawLocation) {
    return jsonResponse({ error: "Missing download location." }, 400);
  }

  const downloadURL = new URL(rawLocation);
  if (downloadURL.hostname !== "api.unsplash.com") {
    return jsonResponse({ error: "Invalid download location." }, 400);
  }

  const response = await fetch(downloadURL, {
    headers: unsplashHeaders(accessKey),
  });

  if (!response.ok) {
    return jsonResponse({ error: "Unsplash download tracking failed." }, response.status);
  }

  return jsonResponse({});
}

function unsplashHeaders(accessKey: string): HeadersInit {
  return {
    "Accept-Version": "v1",
    Authorization: `Client-ID ${accessKey}`,
  };
}

function attributionURL(url: string): string {
  const attribution = new URL(url);
  attribution.searchParams.set("utm_source", UTM_SOURCE);
  attribution.searchParams.set("utm_medium", "referral");
  return attribution.toString();
}

function jsonResponse(body: unknown, status = 200): Response {
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
