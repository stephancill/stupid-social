import { afterEach, describe, expect, mock, test } from "bun:test";
import relay, { base64UrlDecode, base64UrlEncode, type Env, ScheduledPushes } from "./index";

const origin = "https://push.stupidtech.net";
const deviceToken = "ab".repeat(32);
const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** An in-memory Durable Object namespace: one `ScheduledPushes` per name, with its pending alarm. */
function makeNamespace(getEnv: () => Env) {
  const objects = new Map<string, { object: ScheduledPushes; data: Map<string, unknown> }>();
  const alarms = new Map<string, number>();
  const instance = (name: string) => {
    let entry = objects.get(name);
    if (!entry) {
      const data = new Map<string, unknown>();
      const storage = {
        get: async (key: string) => data.get(key),
        put: async (key: string, value: unknown) => void data.set(key, structuredClone(value)),
        deleteAll: async () => data.clear(),
        setAlarm: async (time: number) => void alarms.set(name, time),
        deleteAlarm: async () => void alarms.delete(name),
      };
      entry = {
        object: new ScheduledPushes({ storage } as unknown as DurableObjectState, getEnv()),
        data,
      };
      objects.set(name, entry);
    }
    return entry;
  };
  const namespace = {
    idFromName: (name: string) => name,
    get: (name: string) => ({
      fetch: (input: string, init?: RequestInit) =>
        instance(name).object.fetch(new Request(input, init)),
    }),
  } as unknown as DurableObjectNamespace;
  /** Fires every pending alarm, as the runtime would at its time. */
  const fireAlarms = async () => {
    for (const name of [...alarms.keys()]) {
      alarms.delete(name);
      await instance(name).object.alarm();
    }
  };
  return { namespace, alarms, objects, fireAlarms };
}

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
    SCHEDULED_PUSHES: {} as DurableObjectNamespace,
  };
}

async function makeScheduledEnv() {
  const env = await makeEnv();
  const namespace = makeNamespace(() => env);
  env.SCHEDULED_PUSHES = namespace.namespace;
  return { env, ...namespace };
}

function scheduleRequest(name: string, authorization: string, body?: object) {
  return new Request(`${origin}/scheduled/${name}`, {
    method: body ? "PUT" : "DELETE",
    headers: { Authorization: authorization },
    body: body ? JSON.stringify(body) : undefined,
  });
}

const endpointId = (endpoint: string) => endpoint.split("/").pop()!;

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

  test("sends scheduled pushes when their alarm fires", async () => {
    const { env, alarms, fireAlarms } = await makeScheduledEnv();
    const vapid = await makeVapid();
    const endpoint = await registerEndpoint(env, vapid.publicKey);
    const sent: Request[] = [];
    globalThis.fetch = mock(async (input: RequestInfo | URL, init?: RequestInit) => {
      sent.push(new Request(input, init));
      return new Response(null, { status: 200 });
    }) as unknown as typeof fetch;

    const deliverAt = Math.floor(Date.now() / 1000) + 600;
    const payload = base64UrlEncode(new Uint8Array(120).fill(3));
    const response = await relay.fetch(
      scheduleRequest("reminder-1", await vapid.authorization({ aud: origin, exp: exp() }), {
        deliverAt,
        alert: { title: "Reminder", body: "A chat reminder is due" },
        pushes: [{ endpoint: endpointId(endpoint), payload }],
      }),
      env,
    );
    expect(response.status).toBe(204);
    expect([...alarms.values()]).toEqual([deliverAt * 1000]);
    expect(sent).toHaveLength(0);

    await fireAlarms();
    expect(sent).toHaveLength(1);
    const apns = (await sent[0]!.json()) as {
      aps: { alert: { title: string }; "mutable-content": number };
      webpush: string;
    };
    expect(apns.aps.alert.title).toBe("Reminder");
    expect(apns.aps["mutable-content"]).toBe(1);
    expect(apns.webpush).toBe(payload);
  });

  test("cancels scheduled pushes, scoped to the sender's key", async () => {
    const { env, alarms, objects } = await makeScheduledEnv();
    const vapid = await makeVapid();
    const other = await makeVapid();
    const endpoint = await registerEndpoint(env, vapid.publicKey);
    const body = {
      deliverAt: Math.floor(Date.now() / 1000) + 600,
      alert: { title: "Reminder", body: "Due" },
      pushes: [{ endpoint: endpointId(endpoint), payload: base64UrlEncode(new Uint8Array(50)) }],
    };
    const authorization = await vapid.authorization({ aud: origin, exp: exp() });
    expect((await relay.fetch(scheduleRequest("r", authorization, body), env)).status).toBe(204);

    const otherAuthorization = await other.authorization({ aud: origin, exp: exp() });
    expect((await relay.fetch(scheduleRequest("r", otherAuthorization, body), env)).status).toBe(
      403,
    );
    await relay.fetch(scheduleRequest("r", otherAuthorization), env);
    expect(alarms.size).toBe(1);

    expect((await relay.fetch(scheduleRequest("r", authorization), env)).status).toBe(204);
    expect(alarms.size).toBe(0);
    expect([...objects.values()].every((entry) => entry.data.size === 0)).toBe(true);
  });

  test("keeps scheduled pushes APNs couldn't take for the alarm's retry", async () => {
    const { env, objects, fireAlarms } = await makeScheduledEnv();
    const vapid = await makeVapid();
    const endpoint = await registerEndpoint(env, vapid.publicKey);
    globalThis.fetch = mock(
      async () => new Response(null, { status: 503 }),
    ) as unknown as typeof fetch;
    await relay.fetch(
      scheduleRequest("r", await vapid.authorization({ aud: origin, exp: exp() }), {
        deliverAt: Math.floor(Date.now() / 1000),
        alert: { title: "Reminder", body: "Due" },
        pushes: [{ endpoint: endpointId(endpoint), payload: base64UrlEncode(new Uint8Array(50)) }],
      }),
      env,
    );
    await expect(fireAlarms()).rejects.toThrow();
    expect([...objects.values()][0]!.data.size).toBe(1);
  });
});
