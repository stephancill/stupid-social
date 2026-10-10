import { p256 } from "@noble/curves/nist.js";
import { sha256 } from "@noble/hashes/sha2.js";
import * as Crypto from "expo-crypto";
import * as WebBrowser from "expo-web-browser";
import { z } from "zod";
import { request, result, type Result } from "./probes";
import { saveCredentials, loadCredentials } from "./storage";

const clientId = "https://stupidtech.net/stupid-social/oauth/client-metadata.json";
const redirectURI = "net.stupidtech:/oauth/bluesky/callback";
const jsonObject = z.record(z.string(), z.unknown());
const httpsURL = z.url().refine((value) => new URL(value).protocol === "https:");
const authMetadata = z.object({
  issuer: httpsURL,
  pushed_authorization_request_endpoint: httpsURL,
  authorization_endpoint: httpsURL,
  token_endpoint: httpsURL,
});
export function base64url({ bytes }: { bytes: Uint8Array }) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}
function decoded({ value }: { value: string }) {
  return Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), (c) =>
    c.charCodeAt(0),
  );
}
function encodedJSON({ value }: { value: unknown }) {
  return base64url({ bytes: new TextEncoder().encode(JSON.stringify(value)) });
}
export function proof({
  key,
  url,
  method,
  nonce,
  token,
}: {
  key: Uint8Array;
  url: string;
  method: string;
  nonce?: string;
  token?: string;
}) {
  const publicKey = p256.getPublicKey(key, false);
  const header = encodedJSON({
    value: {
      typ: "dpop+jwt",
      alg: "ES256",
      jwk: {
        kty: "EC",
        crv: "P-256",
        x: base64url({ bytes: publicKey.slice(1, 33) }),
        y: base64url({ bytes: publicKey.slice(33) }),
      },
    },
  });
  const payload = encodedJSON({
    value: {
      jti: Crypto.randomUUID(),
      htm: method,
      htu: url.split("?")[0],
      iat: Math.floor(Date.now() / 1000),
      ...(nonce ? { nonce } : {}),
      ...(token ? { ath: base64url({ bytes: sha256(new TextEncoder().encode(token)) }) } : {}),
    },
  });
  const input = `${header}.${payload}`;
  return `${input}.${base64url({ bytes: p256.sign(new TextEncoder().encode(input), key) })}`;
}
async function getJSON({ url }: { url: string }) {
  const response = await request({ url: httpsURL.parse(url) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return jsonObject.parse(await response.json());
}
async function dpopRequest({
  url,
  key,
  body,
  token,
  nonce,
  method = "POST",
}: {
  url: string;
  key: Uint8Array;
  body?: string;
  token?: string;
  nonce?: string;
  method?: string;
}) {
  let currentNonce = nonce;
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await request({
      url,
      method,
      body,
      headers: {
        DPoP: proof({ key, url, method, nonce: currentNonce, token }),
        ...(body ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
        ...(token ? { Authorization: `DPoP ${token}` } : {}),
      },
    });
    const nextNonce = response.headers.get("DPoP-Nonce") ?? undefined;
    if ((response.status === 400 || response.status === 401) && nextNonce && attempt === 0) {
      currentNonce = nextNonce;
      continue;
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    if (!nextNonce) throw new Error("OAuth response omitted DPoP-Nonce");
    return { data: jsonObject.parse(await response.json()), nonce: nextNonce };
  }
  throw new Error("OAuth nonce retry exhausted");
}
async function prepare({ handle }: { handle: string }) {
  const normalized = z.string().min(3).parse(handle.trim().replace(/^@/, ""));
  const resolved = await getJSON({
    url: `https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=${encodeURIComponent(normalized)}`,
  });
  const did = z.string().parse(resolved.did);
  const didURL = did.startsWith("did:plc:")
    ? `https://plc.directory/${did}`
    : did.startsWith("did:web:")
      ? `https://${did.slice(8).replaceAll(":", "/")}/.well-known/did.json`
      : null;
  if (!didURL) throw new Error("OAuth unsupported DID method");
  const document = await getJSON({ url: didURL });
  const services = z
    .array(z.object({ id: z.string(), type: z.string(), serviceEndpoint: z.unknown() }))
    .parse(document.service);
  const pds = httpsURL
    .parse(services.find((s) => s.type === "AtprotoPersonalDataServer")?.serviceEndpoint)
    .replace(/\/$/, "");
  const protectedMetadata = await getJSON({ url: `${pds}/.well-known/oauth-protected-resource` });
  const issuer = z.array(httpsURL).min(1).parse(protectedMetadata.authorization_servers)[0]!;
  const metadata = authMetadata.parse(
    await getJSON({ url: `${issuer.replace(/\/$/, "")}/.well-known/oauth-authorization-server` }),
  );
  if (metadata.issuer !== issuer) throw new Error("OAuth issuer mismatch");
  const key = Crypto.getRandomBytes(32);
  const verifier = base64url({ bytes: Crypto.getRandomBytes(32) });
  const state = base64url({ bytes: Crypto.getRandomBytes(24) });
  const body = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectURI,
    response_type: "code",
    scope: "atproto transition:generic",
    state,
    code_challenge: base64url({ bytes: sha256(new TextEncoder().encode(verifier)) }),
    code_challenge_method: "S256",
    login_hint: normalized,
  }).toString();
  const par = await dpopRequest({ url: metadata.pushed_authorization_request_endpoint, body, key });
  const requestURI = z.string().parse(par.data.request_uri);
  return {
    metadata,
    key,
    verifier,
    state,
    did,
    pds,
    nonce: par.nonce,
    url: `${metadata.authorization_endpoint}?${new URLSearchParams({ client_id: clientId, request_uri: requestURI })}`,
  };
}
export async function probeBlueskyPAR({ handle }: { handle: string }): Promise<Result> {
  await prepare({ handle });
  return result({
    id: "bluesky-par",
    status: "pass",
    detail: "Discovery, P-256 DPoP signing, PKCE and pushed authorization succeeded on Android.",
  });
}
export async function loginBluesky({ handle }: { handle: string }): Promise<Result> {
  const session = await prepare({ handle });
  const auth = await WebBrowser.openAuthSessionAsync(session.url, redirectURI);
  if (auth.type !== "success")
    return result({
      id: "bluesky-login",
      status: "blocked",
      detail: "Browser authorization was cancelled.",
    });
  const callback = new URL(auth.url);
  if (
    callback.searchParams.get("state") !== session.state ||
    callback.searchParams.get("iss") !== session.metadata.issuer
  )
    throw new Error("OAuth callback validation failed");
  const code = z.string().min(1).parse(callback.searchParams.get("code"));
  const tokens = await dpopRequest({
    url: session.metadata.token_endpoint,
    key: session.key,
    nonce: session.nonce,
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      code_verifier: session.verifier,
      client_id: clientId,
      redirect_uri: redirectURI,
    }).toString(),
  });
  const accessToken = z.string().parse(tokens.data.access_token);
  const refreshToken = z.string().parse(tokens.data.refresh_token);
  if (tokens.data.sub !== session.did) throw new Error("OAuth subject mismatch");
  await saveCredentials({
    provider: "bluesky",
    credentials: {
      accessToken,
      refreshToken,
      key: base64url({ bytes: session.key }),
      tokenEndpoint: session.metadata.token_endpoint,
      authNonce: tokens.nonce,
      pds: session.pds,
      did: session.did,
    },
  });
  return refreshBluesky();
}
export async function refreshBluesky(): Promise<Result> {
  const c = await loadCredentials({ provider: "bluesky" });
  if (!c)
    return result({
      id: "bluesky-session",
      status: "blocked",
      detail: "A separate Android OAuth login is required.",
    });
  const key = decoded({ value: c.key! });
  const refreshed = await dpopRequest({
    url: c.tokenEndpoint!,
    key,
    nonce: c.authNonce,
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: c.refreshToken!,
      client_id: clientId,
    }).toString(),
  });
  const accessToken = z.string().parse(refreshed.data.access_token);
  const credentials = {
    ...c,
    accessToken,
    refreshToken: z.string().parse(refreshed.data.refresh_token),
    authNonce: refreshed.nonce,
  };
  await saveCredentials({ provider: "bluesky", credentials });
  const feed = await dpopRequest({
    url: `${c.pds}/xrpc/app.bsky.notification.listNotifications?limit=1`,
    method: "GET",
    key,
    token: accessToken,
    nonce: c.resourceNonce,
  });
  if (!Array.isArray(feed.data.notifications))
    throw new Error("Response shape: Bluesky notifications missing");
  await saveCredentials({
    provider: "bluesky",
    credentials: { ...credentials, resourceNonce: feed.nonce },
  });
  return result({
    id: "bluesky-session",
    status: "pass",
    detail: "Android OAuth token refresh and DPoP-authenticated notifications succeeded.",
  });
}
