import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, mkdir, open, rename, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import {
  configureClientRuntime,
  type ClientRuntime,
  type Credentials,
} from "../../src/clientRuntime";
import { parseCookies } from "../../src/app/cookies";

export const probeNetworkSchema = z.enum(["x", "instagram", "github", "spotify", "bluesky"]);
export type ProbeNetwork = z.infer<typeof probeNetworkSchema>;
const exec = promisify(execFile);
const secretField =
  /token|cookie|authorization|csrf|^ct0$|^sessionid$|user.?session|^sp_?(dc|t|key)$|private.?key|^key$|fb_dtsg|^lsd$|nonce|^rur$|^mid$|^igDid$/i;
const cookieFields: Partial<Record<ProbeNetwork, Record<string, string>>> = {
  x: { auth_token: "authToken", ct0: "ct0" },
  instagram: {
    sessionid: "sessionId",
    csrftoken: "csrfToken",
    ds_user_id: "dsUserId",
    mid: "mid",
    rur: "rur",
    ig_did: "igDid",
  },
  github: { user_session: "userSession", "__Host-user_session_same_site": "sameSiteUserSession" },
  spotify: { sp_dc: "spDC", sp_t: "spT", sp_key: "spKey" },
};
function nativeDate(value: unknown) {
  if (typeof value === "number") return String((value + 978307200) * 1000);
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return String(parsed);
  }
  throw new Error("Invalid native credential expiry date");
}
export function normalizeCredentials({
  network,
  value,
}: {
  network: ProbeNetwork;
  value: unknown;
}): Credentials {
  const raw = z.record(z.string(), z.union([z.string(), z.number(), z.null()])).parse(value);
  const result: Credentials = Object.fromEntries(
    Object.entries(raw).flatMap(([key, value]) => (value === null ? [] : [[key, String(value)]])),
  );
  for (const [cookie, field] of Object.entries(cookieFields[network] ?? {})) {
    if (result[cookie] && !result[field]) result[field] = result[cookie]!;
    if (cookie !== field) delete result[cookie];
  }
  if (network === "spotify") {
    if (raw.accessTokenExpiresAt != null) result.expiresAt = nativeDate(raw.accessTokenExpiresAt);
    if (raw.initialBearerTokenExpiresAt != null)
      result.initialExpiresAt = nativeDate(raw.initialBearerTokenExpiresAt);
    delete result.accessTokenExpiresAt;
    delete result.initialBearerTokenExpiresAt;
  }
  if (network === "bluesky" && raw.dpopPrivateKey) {
    result.key = Buffer.from(z.string().parse(raw.dpopPrivateKey), "base64").toString("base64url");
    result.pds = z.url().parse(raw.pdsURL).replace(/\/$/, "");
    if (raw.expiresAt != null) result.expiresAt = nativeDate(raw.expiresAt);
    delete result.dpopPrivateKey;
    delete result.pdsURL;
  }
  return result;
}
export async function simulatorCredentials({
  network,
  udid = "6552DF1D-95CE-48E3-801F-8F80F0AA8D29",
}: {
  network: ProbeNetwork;
  udid?: string;
}) {
  const bundle = "tech.stupid.StupidSocial";
  try {
    const { stdout: container } = await exec("xcrun", [
      "simctl",
      "get_app_container",
      udid,
      bundle,
      "data",
    ]);
    const key = `${bundle}.credentials.${network}.localFallback`.replaceAll(".", "\\.");
    const { stdout } = await exec("plutil", [
      "-extract",
      key,
      "raw",
      "-o",
      "-",
      join(container.trim(), "Library/Preferences", `${bundle}.plist`),
    ]);
    const serialized = stdout.trim();
    return normalizeCredentials({
      network,
      value: JSON.parse(
        serialized.startsWith("{")
          ? serialized
          : Buffer.from(serialized, "base64").toString("utf8"),
      ),
    });
  } catch {
    throw new Error(
      "Could not read the selected simulator session. Boot the native app's simulator or supply --credentials-file.",
    );
  }
}
export async function inputText({ path }: { path: string }) {
  return path === "-" ? Bun.stdin.text() : readFile(path, "utf8");
}
export function credentialsJSON({ network, input }: { network: ProbeNetwork; input: string }) {
  let value: unknown;
  try {
    value = JSON.parse(input);
  } catch {
    throw new Error("Invalid credentials JSON.");
  }
  return normalizeCredentials({ network, value });
}
export function cookieCredentials({ network, header }: { network: ProbeNetwork; header: string }) {
  const fields = cookieFields[network];
  if (!fields) throw new Error("Bluesky requires OAuth credentials, not a Cookie header.");
  const cookies = parseCookies({ header });
  return Object.fromEntries(
    Object.entries(fields).flatMap(([name, field]) =>
      cookies[name] ? [[field, cookies[name]!]] : [],
    ),
  );
}
export function credentialPresence({ value }: { value: Credentials | null }) {
  return Object.fromEntries(Object.entries(value ?? {}).map(([key, value]) => [key, !!value]));
}
let nextGeneration = 0;
export function createProbeRuntime({
  network,
  initial,
  fetch: fetchImpl = globalThis.fetch,
  headers = {},
}: {
  network: ProbeNetwork;
  initial: Credentials | null;
  fetch?: ClientRuntime["fetch"];
  headers?: Record<string, string>;
}) {
  const version = ++nextGeneration;
  let session = initial ? { ...initial } : null;
  const knownSecrets = new Set<string>();
  const remember = () => {
    for (const [key, value] of Object.entries(session ?? {}))
      if (secretField.test(key) && value.length >= 6) knownSecrets.add(value);
  };
  remember();
  const requests: { host: string; path: string; status: number; retryAfter: string | null }[] = [];
  const runtime: ClientRuntime = {
    fetch: async (url, init) => {
      const outgoing = new Headers(init.headers);
      for (const [key, value] of Object.entries(headers)) outgoing.set(key, value);
      const response = await fetchImpl(url, { ...init, headers: outgoing });
      const parsed = new URL(url);
      requests.push({
        host: parsed.hostname,
        path: parsed.pathname,
        status: response.status,
        retryAfter: response.headers.get("retry-after"),
      });
      return response;
    },
    credentials: async ({ network: requested }) =>
      requested === network && session ? { ...session } : null,
    saveCredentials: async ({ network: requested, value, expectedGeneration }) => {
      if (requested !== network) throw new Error("Probe attempted to change a different account.");
      if (expectedGeneration !== undefined && expectedGeneration !== version) return;
      session = value ? { ...value } : null;
      remember();
    },
    generation: () => version,
    randomUUID: () => crypto.randomUUID(),
    randomBytes: (size) => crypto.getRandomValues(new Uint8Array(size)),
    readFile: async ({ uri }) =>
      new Uint8Array(await readFile(uri.startsWith("file:") ? fileURLToPath(uri) : uri)),
    openAuthSession: async () => {
      throw new Error(
        "Use the app to complete Bluesky OAuth, then supply its credentials to the probe.",
      );
    },
  };
  return { runtime, requests, knownSecrets, current: () => (session ? { ...session } : null) };
}
export function installProbeRuntime(params: Parameters<typeof createProbeRuntime>[0]) {
  const result = createProbeRuntime(params);
  configureClientRuntime({ runtime: result.runtime });
  return result;
}
export function redact({
  value,
  secrets = new Set<string>(),
}: {
  value: unknown;
  secrets?: Set<string>;
}): unknown {
  if (Array.isArray(value)) return value.map((item) => redact({ value: item, secrets }));
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => [
        key,
        secretField.test(key)
          ? typeof child === "boolean"
            ? child
            : child
              ? "[redacted]"
              : child
          : redact({ value: child, secrets }),
      ]),
    );
  if (typeof value === "string") {
    let text = value;
    for (const secret of secrets) text = text.replaceAll(secret, "[redacted]");
    return text.replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[redacted]");
  }
  return value;
}
export async function writePrivateJSON({ path, value }: { path: string; value: unknown }) {
  const target = resolve(path),
    temporary = `${target}.${crypto.randomUUID()}.tmp`;
  await mkdir(dirname(target), { recursive: true });
  const handle = await open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`);
    await handle.close();
    await rename(temporary, target);
  } finally {
    await handle.close();
    await rm(temporary, { force: true });
  }
}
