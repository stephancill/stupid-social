import { afterEach, describe, expect, mock, test } from "bun:test";
import relay, { base64UrlDecode, base64UrlEncode, type Env } from "./index";

const origin = "https://push.stupidtech.net";
const deviceToken = "ab".repeat(32);
const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

async function makeEnv(): Promise<Env> {
  const apnsKey = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
  ]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", apnsKey.privateKey));
  return {
    RELAY_SECRET: base64UrlEncode(crypto.getRandomValues(new Uint8Array(32))),
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: "TEAMID1234",
    APNS_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`,
    APNS_TOPIC: "tech.stupid.StupidSocial",
  };
}

async function makeVapid() {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
  ]);
  const publicKey = base64UrlEncode(
    new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)),
  );
  const authorization = async (claims: object) => {
    const encode = (value: object) =>
      base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
    const input = `${encode({ typ: "JWT", alg: "ES256" })}.${encode(claims)}`;
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      keys.privateKey,
      new TextEncoder().encode(input),
    );
    return `vapid t=${input}.${base64UrlEncode(new Uint8Array(signature))}, k=${publicKey}`;
  };
  return { publicKey, authorization };
}

async function registerEndpoint(
  env: Env,
  vapidKey: string,
  environment = "sandbox",
): Promise<string> {
  const response = await relay.fetch(
    new Request(`${origin}/register`, {
      method: "POST",
      body: JSON.stringify({ token: deviceToken, environment, vapidKey }),
    }),
    env,
  );
  expect(response.status).toBe(200);
  const { endpoint } = (await response.json()) as { endpoint: string };
  return endpoint;
}

function push(endpoint: string, authorization: string, body = new Uint8Array(200).fill(7)) {
  return new Request(endpoint, {
    method: "POST",
    headers: {
      Authorization: authorization,
      "Content-Encoding": "aes128gcm",
      TTL: "86400",
      Urgency: "high",
    },
    body,
  });
}

const exp = () => Math.floor(Date.now() / 1000) + 3600;

describe("push relay", () => {
  test("forwards an encrypted push to APNs", async () => {
    const env = await makeEnv();
    const vapid = await makeVapid();
    const endpoint = await registerEndpoint(env, vapid.publicKey);
    expect(endpoint.startsWith(`${origin}/apron/`)).toBe(true);
    expect(endpoint).not.toContain(deviceToken);

    const sent: Request[] = [];
    globalThis.fetch = mock(async (input: RequestInfo | URL, init?: RequestInit) => {
      sent.push(new Request(input, init));
      return new Response(null, { status: 200 });
    }) as unknown as typeof fetch;

    const body = new Uint8Array(200).fill(7);
    const response = await relay.fetch(
      push(endpoint, await vapid.authorization({ aud: origin, exp: exp() }), body),
      env,
    );
    expect(response.status).toBe(201);
    expect(sent).toHaveLength(1);
    const apns = sent[0]!;
    expect(apns.url).toBe(`https://api.sandbox.push.apple.com/3/device/${deviceToken}`);
    expect(apns.headers.get("apns-topic")).toBe("tech.stupid.StupidSocial");
    expect(apns.headers.get("apns-priority")).toBe("10");
    expect(apns.headers.get("authorization")?.startsWith("bearer ")).toBe(true);
    const payload = (await apns.json()) as { aps: { "mutable-content": number }; webpush: string };
    expect(payload.aps["mutable-content"]).toBe(1);
    expect(base64UrlDecode(payload.webpush)).toEqual(body);
  });

  test("refuses pushes not signed by the registered server", async () => {
    const env = await makeEnv();
    const registered = await makeVapid();
    const other = await makeVapid();
    const endpoint = await registerEndpoint(env, registered.publicKey);
    globalThis.fetch = mock(
      async () => new Response(null, { status: 200 }),
    ) as unknown as typeof fetch;

    const otherKey = await relay.fetch(
      push(endpoint, await other.authorization({ aud: origin, exp: exp() })),
      env,
    );
    expect(otherKey.status).toBe(403);
    const wrongAudience = await relay.fetch(
      push(
        endpoint,
        await registered.authorization({ aud: "https://elsewhere.example", exp: exp() }),
      ),
      env,
    );
    expect(wrongAudience.status).toBe(403);
    const expired = await relay.fetch(
      push(
        endpoint,
        await registered.authorization({ aud: origin, exp: Math.floor(Date.now() / 1000) - 1 }),
      ),
      env,
    );
    expect(expired.status).toBe(403);
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  test("answers 410 for unknown endpoints and tokens APNs rejects", async () => {
    const env = await makeEnv();
    const vapid = await makeVapid();
    const authorization = await vapid.authorization({ aud: origin, exp: exp() });

    const forged = await relay.fetch(
      push(`${origin}/apron/${"A".repeat(170)}`, authorization),
      env,
    );
    expect(forged.status).toBe(410);

    const endpoint = await registerEndpoint(env, vapid.publicKey, "production");
    globalThis.fetch = mock(async () =>
      Response.json({ reason: "BadDeviceToken" }, { status: 400 }),
    ) as unknown as typeof fetch;
    const rejected = await relay.fetch(push(endpoint, authorization), env);
    expect(rejected.status).toBe(410);
  });

  test("validates registrations", async () => {
    const env = await makeEnv();
    const response = await relay.fetch(
      new Request(`${origin}/register`, {
        method: "POST",
        body: JSON.stringify({ token: "nothex", environment: "sandbox", vapidKey: "x" }),
      }),
      env,
    );
    expect(response.status).toBe(400);
  });
});
