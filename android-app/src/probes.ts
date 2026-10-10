import { fetch } from "expo/fetch";
import * as Crypto from "expo-crypto";
import * as SecureStore from "expo-secure-store";
import { hmac } from "@noble/hashes/hmac.js";
import { sha1 } from "@noble/hashes/legacy.js";
import { z } from "zod";
import { bridge } from "./bridge";
import {
  loadCredentials,
  parseCookies,
  saveCredentials,
  type Credentials,
  type Provider,
} from "./storage";

export type Result = {
  id: string;
  status: "pass" | "fail" | "blocked";
  detail: string;
  at: string;
};
export const fixtureURL = "http://127.0.0.1:8789";
export const resultSchema = z.object({
  id: z.string(),
  status: z.enum(["pass", "fail", "blocked"]),
  detail: z.string(),
  at: z.string(),
});
export function result({ id, status, detail }: Omit<Result, "at">): Result {
  return { id, status, detail, at: new Date().toISOString() };
}
export function safeError({ error }: { error: unknown }) {
  if (
    error instanceof Error &&
    /^(HTTP \d{3}|Reconnect required|Missing credentials|Response shape|OAuth |Fixture |Spotify |Instagram )/.test(
      error.message,
    )
  )
    return error.message.slice(0, 180);
  return "Request or validation failed; no response or credentials logged.";
}
export async function request({
  url,
  headers = {},
  method = "GET",
  body,
  redirect = "follow",
}: {
  url: string;
  headers?: Record<string, string>;
  method?: string;
  body?: string | Uint8Array;
  redirect?: "follow" | "manual";
}) {
  const response = await fetch(url, {
    method,
    headers,
    body: body instanceof Uint8Array ? new Uint8Array(body).buffer : body,
    redirect,
    // Android's shared WebView cookie jar can overwrite an explicit Cookie header.
    credentials: "omit",
    signal: AbortSignal.timeout(30000),
  });
  return response;
}
export async function jsonResponse({
  response,
}: {
  response: Awaited<ReturnType<typeof request>>;
}) {
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const text = await response.text();
  try {
    return z.record(z.string(), z.unknown()).parse(JSON.parse(text));
  } catch {
    throw new Error(
      `Response shape: expected JSON; HTTP ${response.status}; HTML=${/^\s*</.test(text)}; redirected=${response.redirected}`,
    );
  }
}
export async function localProbes(): Promise<Result[]> {
  const tests: [string, () => Promise<string>][] = [
    [
      "secure-storage",
      async () => {
        const previous = await SecureStore.getItemAsync("validation.persistence");
        if (!previous)
          await SecureStore.setItemAsync("validation.persistence", Crypto.randomUUID());
        const current = await SecureStore.getItemAsync("validation.persistence");
        if (!current || (previous && previous !== current))
          throw new Error("Fixture secure storage mismatch");
        return previous
          ? "Previously stored value is readable; force-stop/relaunch verifies restart persistence."
          : "Write/read passed; restart still needs verification.";
      },
    ],
    [
      "manual-redirect",
      async () => {
        const response = await request({ url: `${fixtureURL}/redirect`, redirect: "manual" });
        if (response.status !== 302 || !response.headers.get("location"))
          throw new Error("Fixture manual redirect was not preserved");
        return "HTTP 302 and Location are accessible without following the redirect.";
      },
    ],
    [
      "multiple-set-cookie",
      async () => {
        const response = await request({ url: `${fixtureURL}/cookies` });
        const headers = response.headers as Headers & { getSetCookie?: () => string[] };
        const cookies = headers.getSetCookie?.() ?? [headers.get("set-cookie") ?? ""];
        if (
          !cookies.join("\n").includes("probe_a=one") ||
          !cookies.join("\n").includes("probe_b=two")
        )
          throw new Error("Fixture cookies missing");
        return "Both Set-Cookie values are accessible for explicit session renewal.";
      },
    ],
    [
      "explicit-cookie-header",
      async () => {
        await bridge.seedCookie(`${fixtureURL}/`, "probe_a=stale; Path=/");
        await bridge.seedCookie(`${fixtureURL}/`, "probe_b=stale; Path=/");
        const response = await jsonResponse({
          response: await request({
            url: `${fixtureURL}/echo`,
            headers: { Cookie: "probe_a=one; probe_b=two", "X-CSRFToken": "fixture-csrf" },
          }),
        });
        if (response.cookiesCorrect !== true || response.csrfCorrect !== true)
          throw new Error("Fixture auth headers changed in transit");
        return "Explicit Cookie and CSRF headers arrived unchanged despite conflicting WebView cookies.";
      },
    ],
    [
      "binary-image-upload",
      async () => {
        const bytes = Uint8Array.from(atob(await bridge.testImage()), (c) => c.charCodeAt(0));
        const hash = await Crypto.digestStringAsync(
          Crypto.CryptoDigestAlgorithm.SHA256,
          Array.from(bytes).join(","),
        );
        const response = await jsonResponse({
          response: await request({
            url: `${fixtureURL}/upload`,
            method: "POST",
            headers: { "Content-Type": "application/octet-stream" },
            body: bytes,
          }),
        });
        if (response.hash !== hash || response.bytes !== bytes.length)
          throw new Error("Fixture binary upload corrupted");
        return `1080×1920 JPEG upload preserved all ${bytes.length} bytes.`;
      },
    ],
    [
      "httponly-native-access",
      async () => {
        await bridge.seedCookie(`${fixtureURL}/`, "probe_http_only=native; Path=/; HttpOnly");
        const cookies = parseCookies({ header: await bridge.cookies(`${fixtureURL}/`) });
        if (cookies.probe_http_only !== "native")
          throw new Error("Fixture HttpOnly cookie missing");
        return "Native CookieManager can read the HttpOnly cookie.";
      },
    ],
  ];
  const results: Result[] = [];
  for (const [id, run] of tests) {
    try {
      results.push(result({ id, status: "pass", detail: await run() }));
    } catch (error) {
      results.push(result({ id, status: "fail", detail: safeError({ error }) }));
    }
  }
  return results;
}
const instagramUA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";
function instagramCookies({ credentials: c }: { credentials: Credentials }) {
  return [
    ["sessionid", c.sessionId],
    ["csrftoken", c.csrfToken],
    ["ds_user_id", c.dsUserId],
    ["mid", c.mid],
    ["rur", c.rur],
    ["ig_did", c.igDid],
  ]
    .filter(([, value]) => value)
    .map(([key, value]) => `${key}=${value}`)
    .join("; ");
}
async function instagramHeaders({ credentials }: { credentials: Credentials }) {
  const cookie = instagramCookies({ credentials });
  const response = await request({
    url: "https://www.instagram.com/",
    headers: { Cookie: cookie, "User-Agent": instagramUA },
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const html = (await response.text()).replaceAll('\\"', '"');
  const csrf = /"csrf_token"\s*:\s*"([^"]+)"/.exec(html)?.[1] ?? credentials.csrfToken;
  const lsd = /"LSD",\[\],\{"token":"([^"]+)"/.exec(html)?.[1];
  if (!csrf) throw new Error("Reconnect required: Instagram");
  return {
    Cookie: cookie,
    "User-Agent": instagramUA,
    "X-CSRFToken": csrf,
    "X-IG-App-ID": "1217981644879628",
    "X-ASBD-ID": "359341",
    Origin: "https://www.instagram.com",
    Referer: "https://www.instagram.com/",
    "X-Web-Session-ID": Crypto.randomUUID().slice(0, 6),
    ...(lsd ? { "X-FB-LSD": lsd } : {}),
  };
}
export function spotifyTOTP({ timestamp }: { timestamp: number }) {
  const secret = ',7/*F("rLJ2oxaKL^f+E1xvP@N';
  const transformed = Array.from(secret)
    .map((char, i) => char.charCodeAt(0) ^ ((i % 33) + 9))
    .join("");
  const counter = new Uint8Array(8);
  new DataView(counter.buffer).setBigUint64(0, BigInt(Math.floor(timestamp / 30)));
  const digest = hmac(sha1, new TextEncoder().encode(transformed), counter);
  const offset = digest[digest.length - 1]! & 15;
  return String(
    (new DataView(digest.buffer, digest.byteOffset).getUint32(offset) & 0x7fffffff) % 1000000,
  ).padStart(6, "0");
}
async function probeProvider({
  provider,
  credentials: c,
}: {
  provider: Provider;
  credentials: Credentials;
}): Promise<string> {
  if (provider === "x") {
    const data = await jsonResponse({
      response: await request({
        url: "https://x.com/i/api/2/notifications/all/unread_count.json",
        headers: {
          Cookie: `auth_token=${c.authToken}; ct0=${c.ct0}`,
          "X-Csrf-Token": c.ct0!,
          "User-Agent": "NoFeedSocial/1",
          Authorization:
            "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA",
        },
      }),
    });
    if (!z.object({ unreadCount: z.number() }).safeParse(data).success)
      throw new Error("Response shape: X unread count missing");
    return "Authenticated unread-count request succeeded without marking notifications read.";
  }
  if (provider === "github") {
    const response = await request({
      url: "https://github.com/conduit/for_you_feed",
      redirect: "manual",
      headers: {
        Cookie: `user_session=${c.userSession}; __Host-user_session_same_site=${c.sameSiteUserSession}`,
        Accept: "text/html",
        "User-Agent": "NoFeedSocial/1",
        "X-Requested-With": "XMLHttpRequest",
      },
    });
    if (response.status === 302 || response.status === 401 || response.url.includes("/login"))
      throw new Error("Reconnect required: GitHub session expired");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const html = await response.text();
    if (!html.includes("data-hydro-"))
      throw new Error("Response shape: GitHub feed metadata missing");
    return "Authenticated HTML feed returned structured Hydro activity metadata.";
  }
  if (provider === "instagram") {
    const headers = await instagramHeaders({ credentials: c });
    const data = await jsonResponse({
      response: await request({
        url: "https://www.instagram.com/api/v1/direct_v2/inbox/?visual_message_return_type=unseen&thread_message_limit=10&persistentBadging=true&limit=20",
        headers,
      }),
    });
    if (data.status !== "ok" || !data.viewer)
      throw new Error("Response shape: Instagram viewer missing");
    return "Web bootstrap and authenticated Direct inbox succeeded; threads remain unread.";
  }
  const cookie = `sp_dc=${c.spDC}; sp_t=${c.spT}${c.spKey ? `; sp_key=${c.spKey}` : ""}`;
  const clock = await jsonResponse({
    response: await request({ url: "https://open.spotify.com/api/server-time" }),
  });
  const serverTime = z.number().parse(clock.serverTime);
  const params = new URLSearchParams({
    reason: "transport",
    productType: "web-player",
    totp: spotifyTOTP({ timestamp: Date.now() / 1000 }),
    totpServer: spotifyTOTP({ timestamp: serverTime }),
    totpVer: "61",
  });
  const token = await jsonResponse({
    response: await request({
      url: `https://open.spotify.com/api/token?${params}`,
      headers: {
        Cookie: cookie,
        "App-Platform": "WebPlayer",
        "User-Agent": "Mozilla/5.0",
        Accept: "application/json",
      },
    }),
  });
  const bearerToken = z.string().min(1).parse(token.accessToken);
  const updated = { ...c, bearerToken };
  await saveCredentials({ provider, credentials: updated });
  const activity = await jsonResponse({
    response: await request({
      url: "https://spclient.wg.spotify.com/presence-view/v1/buddylist",
      headers: {
        Authorization: `Bearer ${bearerToken}`,
        "App-Platform": "WebPlayer",
        "Spotify-App-Version": "1.2.90.229.g33aad738",
      },
    }),
  });
  if (!Array.isArray(activity.friends)) throw new Error("Response shape: Spotify friends missing");
  return "Cookie-based token refresh and authenticated friend activity succeeded.";
}
export async function liveProbe({ provider }: { provider: Provider }): Promise<Result> {
  const credentials = await loadCredentials({ provider });
  if (!credentials)
    return result({
      id: provider,
      status: "blocked",
      detail: "Sign in on Android to test this provider.",
    });
  try {
    return result({
      id: provider,
      status: "pass",
      detail: await probeProvider({ provider, credentials }),
    });
  } catch (error) {
    return result({ id: provider, status: "fail", detail: safeError({ error }) });
  }
}
export async function uploadInstagramImage(): Promise<Result> {
  const c = await loadCredentials({ provider: "instagram" });
  if (!c) throw new Error("Missing credentials: Instagram");
  const headers = await instagramHeaders({ credentials: c });
  const image = Uint8Array.from(atob(await bridge.testImage()), (char) => char.charCodeAt(0));
  const uploadId = String(Date.now());
  const entityName = `fb_uploader_${uploadId}`;
  const response = await jsonResponse({
    response: await request({
      url: `https://i.instagram.com/rupload_igphoto/${entityName}`,
      method: "POST",
      headers: {
        ...headers,
        "Content-Type": "application/octet-stream",
        Offset: "0",
        "X-Entity-Length": String(image.length),
        "X-Entity-Name": entityName,
        "X-Entity-Type": "image/jpeg",
        "X-Instagram-Rupload-Params": JSON.stringify({
          media_type: 1,
          upload_id: uploadId,
          upload_media_height: 1920,
          upload_media_width: 1080,
        }),
      },
      body: image,
    }),
  });
  if (response.status !== "ok") throw new Error("Instagram upload rejected");
  return result({
    id: "instagram-upload",
    status: "pass",
    detail: "Instagram accepted the 1080×1920 JPEG. Upload only; no story was published.",
  });
}
