import { z } from "zod";

/**
 * A Web Push endpoint (RFC 8030) for native apps: Apron servers deliver encrypted pushes here as they do to a
 * browser's push service, and the relay forwards the ciphertext to APNs, where the app's Notification Service
 * Extension decrypts it. Endpoints keep no state: an endpoint's ID is the APNs device token, its environment and
 * the one VAPID key allowed to push to it, sealed with RELAY_SECRET.
 *
 * Scheduled pushes are the one stored thing: the app's chat reminders, which one of the user's devices encrypts for
 * the others and leaves here until they're due. Each is a Durable Object named by the sender's VAPID key and the
 * reminder, which sends its pushes when its alarm fires and then deletes itself.
 */
export type Env = {
  RELAY_SECRET: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_PRIVATE_KEY: string;
  APNS_TOPIC: string;
  SCHEDULED_PUSHES: DurableObjectNamespace;
};

const environments = ["sandbox", "production"] as const;
type ApnsEnvironment = (typeof environments)[number];

const registerSchema = z.object({
  token: z.string().regex(/^(?:[0-9a-f]{2}){32,100}$/i),
  environment: z.enum(environments),
  vapidKey: z.string().regex(/^[A-Za-z0-9_-]{87}$/),
});

/** A payload is at most 2048 bytes (§4.9.3), plus the aes128gcm header, padding delimiter and tag. */
const maxBodyBytes = 4096 - 1024;
const maxVapidLifetimeSeconds = 24 * 60 * 60;
const maxScheduleSeconds = 400 * 24 * 60 * 60;
/** How long APNs keeps trying to reach a device that is off when a scheduled push is sent. */
const scheduledExpirationSeconds = 24 * 60 * 60;

const scheduleSchema = z.object({
  deliverAt: z.number().int(),
  alert: z.object({ title: z.string().max(100), body: z.string().max(200) }),
  pushes: z
    .array(
      z.object({
        endpoint: z
          .string()
          .regex(/^[A-Za-z0-9_-]+$/)
          .max(512),
        payload: z
          .string()
          .regex(/^[A-Za-z0-9_-]+$/)
          .max(Math.ceil((maxBodyBytes * 4) / 3)),
      }),
    )
    .min(1)
    .max(20),
});
type Schedule = z.infer<typeof scheduleSchema>;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/register") {
      return register(request, env, url);
    }
    const match = url.pathname.match(/^\/apron\/([A-Za-z0-9_-]+)$/);
    if (request.method === "POST" && match?.[1]) {
      return deliver(request, env, url, match[1]);
    }
    const scheduled = url.pathname.match(/^\/scheduled\/([A-Za-z0-9_-]{1,64})$/);
    if ((request.method === "PUT" || request.method === "DELETE") && scheduled?.[1]) {
      return schedule(request, env, url, scheduled[1]);
    }
    return new Response("Not Found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;

/**
 * `PUT /scheduled/<name>` stores pushes to send at `deliverAt` (seconds since 1970), replacing any under that name;
 * `DELETE` cancels them. Both need a `vapid` `Authorization`, the name is scoped to its key, and every endpoint must
 * be one that key may push to, so only the devices sharing it can schedule or cancel pushes to each other.
 */
async function schedule(request: Request, env: Env, url: URL, name: string): Promise<Response> {
  const vapid = await verifyVapid(request.headers.get("Authorization"), url.origin);
  if (!vapid) {
    return new Response("Forbidden", { status: 403 });
  }
  const keyHash = base64UrlEncode(new Uint8Array(await crypto.subtle.digest("SHA-256", vapid)));
  const stub = env.SCHEDULED_PUSHES.get(env.SCHEDULED_PUSHES.idFromName(`${keyHash}:${name}`));
  if (request.method === "DELETE") {
    await stub.fetch("https://scheduled/", { method: "DELETE" });
    return new Response(null, { status: 204 });
  }

  const parsed = scheduleSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return Response.json({ error: "invalid schedule" }, { status: 400 });
  }
  const now = Math.floor(Date.now() / 1000);
  if (parsed.data.deliverAt > now + maxScheduleSeconds) {
    return Response.json({ error: "deliverAt is too far ahead" }, { status: 400 });
  }
  for (const push of parsed.data.pushes) {
    const endpoint = await openEndpoint(env, push.endpoint);
    if (!endpoint || !equalBytes(endpoint.vapidKey, vapid)) {
      return Response.json({ error: "unknown endpoint", endpoint: push.endpoint }, { status: 403 });
    }
    const length = base64UrlDecode(push.payload).length;
    if (length === 0 || length > maxBodyBytes) {
      return new Response("Payload Too Large", { status: 413 });
    }
  }
  await stub.fetch("https://scheduled/", { method: "PUT", body: JSON.stringify(parsed.data) });
  return new Response(null, { status: 204 });
}

/** One scheduled set of pushes: stored until its alarm, then sent and deleted. */
export class ScheduledPushes {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    if (request.method === "DELETE") {
      await this.state.storage.deleteAlarm();
      await this.state.storage.deleteAll();
      return new Response(null, { status: 204 });
    }
    const scheduled = (await request.json()) as Schedule;
    await this.state.storage.put("schedule", scheduled);
    await this.state.storage.setAlarm(Math.max(scheduled.deliverAt * 1000, Date.now()));
    return new Response(null, { status: 204 });
  }

  /** Sends every push; ones APNs refuses for a moment stay for the alarm's automatic retry. */
  async alarm(): Promise<void> {
    const scheduled = await this.state.storage.get<Schedule>("schedule");
    if (!scheduled) {
      return;
    }
    const remaining: Schedule["pushes"] = [];
    for (const push of scheduled.pushes) {
      const endpoint = await openEndpoint(this.env, push.endpoint);
      if (!endpoint) {
        continue;
      }
      const apns = await sendToApns(this.env, endpoint, {
        ciphertext: push.payload,
        expiration: Math.floor(Date.now() / 1000) + scheduledExpirationSeconds,
        priority: 10,
        alert: scheduled.alert,
      });
      if (apns.status === 429 || apns.status >= 500) {
        remaining.push(push);
      } else if (apns.status !== 200) {
        console.error("apns rejected scheduled push", apns.status, apns.reason);
      }
    }
    if (remaining.length > 0) {
      await this.state.storage.put("schedule", { ...scheduled, pushes: remaining });
      throw new Error(`${remaining.length} scheduled pushes not sent`);
    }
    await this.state.storage.deleteAll();
  }
}

async function register(request: Request, env: Env, url: URL): Promise<Response> {
  const parsed = registerSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return Response.json({ error: "invalid registration" }, { status: 400 });
  }
  const vapidKey = base64UrlDecode(parsed.data.vapidKey);
  if (vapidKey.length !== 65 || vapidKey[0] !== 4) {
    return Response.json(
      { error: "vapidKey must be an uncompressed P-256 point" },
      { status: 400 },
    );
  }
  const id = await sealEndpoint(env, {
    environment: parsed.data.environment,
    vapidKey,
    token: hexDecode(parsed.data.token),
  });
  return Response.json({ endpoint: `${url.origin}/apron/${id}` });
}

async function deliver(request: Request, env: Env, url: URL, id: string): Promise<Response> {
  const endpoint = await openEndpoint(env, id);
  if (!endpoint) {
    return new Response("Gone", { status: 410 });
  }
  const vapid = await verifyVapid(request.headers.get("Authorization"), url.origin);
  if (!vapid || !equalBytes(vapid, endpoint.vapidKey)) {
    return new Response("Forbidden", { status: 403 });
  }
  if (request.headers.get("Content-Encoding") !== "aes128gcm") {
    return new Response("Unsupported Media Type", { status: 415 });
  }
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length === 0 || body.length > maxBodyBytes) {
    return new Response("Payload Too Large", { status: 413 });
  }

  const ttl = Number.parseInt(request.headers.get("TTL") ?? "0", 10);
  const urgency = request.headers.get("Urgency") ?? "normal";
  const apns = await sendToApns(env, endpoint, {
    ciphertext: base64UrlEncode(body),
    expiration: ttl > 0 ? Math.floor(Date.now() / 1000) + ttl : 0,
    priority: urgency === "low" || urgency === "very-low" ? 5 : 10,
    alert: { title: "Apron", body: "New message" },
  });
  if (apns.status === 200) {
    return new Response(null, { status: 201 });
  }
  // The device token is no longer valid: the Apron server removes registrations that answer 404 or 410 (§4.9.1).
  if (
    apns.status === 410 ||
    apns.reason === "BadDeviceToken" ||
    apns.reason === "DeviceTokenNotForTopic"
  ) {
    return new Response("Gone", { status: 410 });
  }
  console.error("apns rejected push", apns.status, apns.reason);
  if (apns.status === 429) {
    return new Response("Too Many Requests", { status: 429 });
  }
  return new Response("Bad Gateway", { status: 502 });
}

// MARK: Endpoint IDs

type Endpoint = { environment: ApnsEnvironment; vapidKey: Uint8Array; token: Uint8Array };

async function relayKey(env: Env): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", base64UrlDecode(env.RELAY_SECRET), "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

export async function sealEndpoint(env: Env, endpoint: Endpoint): Promise<string> {
  const plaintext = concat(
    Uint8Array.of(environments.indexOf(endpoint.environment)),
    endpoint.vapidKey,
    endpoint.token,
  );
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    await relayKey(env),
    plaintext,
  );
  return base64UrlEncode(concat(nonce, new Uint8Array(sealed)));
}

export async function openEndpoint(env: Env, id: string): Promise<Endpoint | null> {
  const sealed = base64UrlDecode(id);
  if (sealed.length < 12 + 1 + 65 + 32 + 16) {
    return null;
  }
  try {
    const plaintext = new Uint8Array(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: sealed.subarray(0, 12) },
        await relayKey(env),
        sealed.subarray(12),
      ),
    );
    const environment = environments[plaintext[0] ?? -1];
    if (!environment) {
      return null;
    }
    return { environment, vapidKey: plaintext.subarray(1, 66), token: plaintext.subarray(66) };
  } catch {
    return null;
  }
}

// MARK: VAPID (RFC 8292)

/** The sender's public key when `Authorization` is a valid, unexpired `vapid` token for this origin. */
export async function verifyVapid(
  authorization: string | null,
  origin: string,
): Promise<Uint8Array | null> {
  const fields = authorization?.match(/^vapid\s+(.+)$/i)?.[1];
  if (!fields) {
    return null;
  }
  const params = new Map(
    fields.split(",").map((part) => {
      const [name, ...value] = part.trim().split("=");
      return [name?.toLowerCase(), value.join("=")] as const;
    }),
  );
  const token = params.get("t");
  const key = params.get("k");
  if (!token || !key) {
    return null;
  }
  const [header, claims, signature] = token.split(".");
  if (!header || !claims || !signature) {
    return null;
  }
  try {
    const publicKey = base64UrlDecode(key);
    const verifier = await crypto.subtle.importKey(
      "raw",
      publicKey,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      verifier,
      base64UrlDecode(signature),
      new TextEncoder().encode(`${header}.${claims}`),
    );
    const { aud, exp } = JSON.parse(new TextDecoder().decode(base64UrlDecode(claims)));
    const now = Math.floor(Date.now() / 1000);
    if (
      !valid ||
      aud !== origin ||
      typeof exp !== "number" ||
      exp <= now ||
      exp > now + maxVapidLifetimeSeconds
    ) {
      return null;
    }
    return publicKey;
  } catch {
    return null;
  }
}

// MARK: APNs

let cachedProviderToken: { token: string; issuedAt: number } | undefined;
const providerTokenLifetime = 50 * 60;

/**
 * APNs accepts a token for an hour and answers 429 `TooManyProviderTokenUpdates` to refreshes more often than every
 * 20 minutes. Sparse pushes often start a new isolate, so the token is also kept in the data center's cache. Requests
 * to the key's URL reach this Worker, which answers 404, so the cache never serves it.
 */
async function providerToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedProviderToken && now - cachedProviderToken.issuedAt < providerTokenLifetime) {
    return cachedProviderToken.token;
  }
  const cache = typeof caches === "undefined" ? undefined : caches.default;
  const cacheKey = `https://push.stupidtech.net/internal/apns-provider-token/${env.APNS_KEY_ID}`;
  const cached = await cache?.match(cacheKey);
  if (cached) {
    const stored = (await cached.json()) as { token: string; issuedAt: number };
    if (now - stored.issuedAt < providerTokenLifetime) {
      cachedProviderToken = stored;
      return stored.token;
    }
  }
  const pem = env.APNS_PRIVATE_KEY.replaceAll("\\n", "\n").replace(/-----[^-]+-----|\s/g, "");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(pem), (character) => character.charCodeAt(0)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const encode = (value: object) =>
    base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
  const input = `${encode({ alg: "ES256", kid: env.APNS_KEY_ID })}.${encode({ iss: env.APNS_TEAM_ID, iat: now })}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(input),
  );
  const token = `${input}.${base64UrlEncode(new Uint8Array(signature))}`;
  cachedProviderToken = { token, issuedAt: now };
  await cache?.put(
    cacheKey,
    Response.json(cachedProviderToken, {
      headers: { "Cache-Control": `max-age=${providerTokenLifetime - 60}` },
    }),
  );
  return token;
}

async function sendToApns(
  env: Env,
  endpoint: Endpoint,
  push: {
    ciphertext: string;
    expiration: number;
    priority: number;
    alert: { title: string; body: string };
  },
): Promise<{ status: number; reason?: string }> {
  const host =
    endpoint.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${hexEncode(endpoint.token)}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken(env)}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": String(push.priority),
      "apns-expiration": String(push.expiration),
      "content-type": "application/json",
    },
    // Shown as is only when the extension can't decrypt the push.
    body: JSON.stringify({
      aps: {
        alert: push.alert,
        sound: "default",
        "mutable-content": 1,
      },
      webpush: push.ciphertext,
    }),
  });
  if (response.status === 200) {
    return { status: 200 };
  }
  const error = (await response.json().catch(() => ({}))) as { reason?: string };
  return { status: response.status, reason: error.reason };
}

// MARK: Bytes

function concat(...parts: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, index) => byte === b[index]);
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function base64UrlDecode(text: string): Uint8Array {
  const base64 = text.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4)), (character) =>
    character.charCodeAt(0),
  );
}

function hexDecode(hex: string): Uint8Array {
  return Uint8Array.from(hex.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
}

function hexEncode(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
