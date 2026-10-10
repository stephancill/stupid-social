import { p256 } from "@noble/curves/nist.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { z } from "zod";
import { request } from "../app/http";
import {
  accountSchema,
  profileSchema,
  notificationSchema,
  postSchema,
  socialError,
  type Account,
  type Profile,
  type SourceResult,
} from "../app/models";
import { object, list, text, https, timestamp } from "../app/value";
import {
  saveCredentials,
  generation,
  credentials as loadCredentials,
  randomUUID,
  randomBytes,
  openAuthSession,
} from "../clientRuntime";

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
      jti: randomUUID(),
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
  if (!response.ok)
    throw socialError({
      message: `Bluesky returned an error (${response.status}). Reconnect in Settings if this continues.`,
    });
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
      allowUnauthorized: true,
      method,
      body,
      headers: {
        DPoP: proof({ key, url, method, nonce: currentNonce, token }),
        ...(body
          ? { "Content-Type": token ? "application/json" : "application/x-www-form-urlencoded" }
          : {}),
        ...(token ? { Authorization: `DPoP ${token}` } : {}),
      },
    });
    const nextNonce = response.headers.get("DPoP-Nonce") ?? undefined;
    if ((response.status === 400 || response.status === 401) && nextNonce && attempt === 0) {
      currentNonce = nextNonce;
      continue;
    }
    if (!response.ok)
      throw socialError({
        message: `Bluesky returned an error (${response.status}). Reconnect in Settings if this continues.`,
      });
    return {
      data:
        response.status === 204 || response.headers.get("content-length") === "0"
          ? {}
          : jsonObject.parse(JSON.parse((await response.text()) || "{}")),
      nonce: nextNonce ?? currentNonce ?? "",
    };
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
      ? `https://${did.slice(8).includes(":") ? did.slice(8).replaceAll(":", "/") : `${did.slice(8)}/.well-known`}/did.json`
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
  const key = randomBytes(32);
  const verifier = base64url({ bytes: randomBytes(32) });
  const state = base64url({ bytes: randomBytes(24) });
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
export async function loginBluesky({ handle }: { handle: string }): Promise<Account> {
  const session = await prepare({ handle });
  const auth = await openAuthSession({ url: session.url, redirectURI });
  if (auth.type !== "success") throw socialError({ message: "Bluesky sign-in was cancelled." });
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
    network: "bluesky",
    value: {
      accessToken,
      refreshToken,
      expiresAt: String(Date.now() + Number(tokens.data.expires_in ?? 300) * 1000),
      key: base64url({ bytes: session.key }),
      tokenEndpoint: session.metadata.token_endpoint,
      authNonce: tokens.nonce,
      pds: session.pds,
      did: session.did,
    },
  });
  return connectBluesky();
}
let renewing: Promise<void> | undefined;
async function refresh() {
  renewing ??= (async () => {
    const version = generation({ network: "bluesky" });
    const c = await loadCredentials({ network: "bluesky" });
    if (!c) throw socialError({ message: "Connect Bluesky in Settings." });
    let tokenEndpoint = c.tokenEndpoint;
    if (!tokenEndpoint) {
      const issuer = httpsURL.parse(c.authServerURL);
      const metadata = authMetadata.parse(
        await getJSON({
          url: `${issuer.replace(/\/$/, "")}/.well-known/oauth-authorization-server`,
        }),
      );
      if (metadata.issuer !== issuer) throw new Error("OAuth issuer mismatch");
      tokenEndpoint = metadata.token_endpoint;
    }
    const reply = await dpopRequest({
      url: tokenEndpoint,
      key: decoded({ value: c.key! }),
      nonce: c.authNonce,
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: c.refreshToken!,
        client_id: clientId,
      }).toString(),
    });
    if (reply.data.sub && reply.data.sub !== c.did)
      throw socialError({ message: "Bluesky account changed. Reconnect in Settings." });
    if (generation({ network: "bluesky" }) === version)
      await saveCredentials({
        expectedGeneration: version,
        network: "bluesky",
        value: {
          ...c,
          tokenEndpoint,
          accessToken: z.string().parse(reply.data.access_token),
          refreshToken: z.string().parse(reply.data.refresh_token),
          expiresAt: String(Date.now() + Number(reply.data.expires_in ?? 300) * 1000),
          authNonce: reply.nonce,
        },
      });
  })().finally(() => {
    renewing = undefined;
  });
  return renewing;
}
async function api({
  method,
  params = {},
  body,
}: {
  method: string;
  params?: Record<string, string>;
  body?: Record<string, unknown>;
}) {
  let c = await loadCredentials({ network: "bluesky" });
  if (!c) throw socialError({ message: "Connect Bluesky in Settings." });
  if (!c.expiresAt || Number(c.expiresAt) < Date.now() + 30000) {
    await refresh();
    c = (await loadCredentials({ network: "bluesky" }))!;
  }
  const version = generation({ network: "bluesky" });
  const reply = await dpopRequest({
    url: `${c.pds}/xrpc/${method}?${new URLSearchParams(params)}`,
    key: decoded({ value: c.key! }),
    token: c.accessToken,
    nonce: c.resourceNonce,
    method: body ? "POST" : "GET",
    body: body ? JSON.stringify(body) : undefined,
  });
  if (generation({ network: "bluesky" }) === version) {
    const latest = await loadCredentials({ network: "bluesky" });
    if (latest)
      await saveCredentials({
        expectedGeneration: version,
        network: "bluesky",
        value: { ...latest, resourceNonce: reply.nonce },
      });
  }
  return reply.data;
}
export function parseBlueskyProfile({ value }: { value: unknown }): Profile {
  const p = object(value),
    viewer = object(p.viewer);
  return profileSchema.parse({
    network: "bluesky",
    id: p.did,
    username: p.handle,
    name: p.displayName || p.handle,
    avatar: https(p.avatar),
    bio: p.description ?? "",
    followers: p.followersCount,
    following: p.followsCount,
    posts: p.postsCount,
    isFollowing: !!viewer.following,
    followsYou: !!viewer.followedBy,
  });
}
export async function blueskyProfile({ id }: { id: string }) {
  return parseBlueskyProfile({
    value: await api({ method: "app.bsky.actor.getProfile", params: { actor: id } }),
  });
}
export async function connectBluesky(): Promise<Account> {
  const c = await loadCredentials({ network: "bluesky" });
  return accountSchema.parse({
    ...(await blueskyProfile({ id: z.string().parse(c?.did) })),
    connectedAt: Date.now(),
  });
}
export async function blueskySearch({ query }: { query: string }) {
  const data = await api({
    method: "app.bsky.actor.searchActors",
    params: { q: query, limit: "20" },
  });
  return list(data.actors).map((value) => parseBlueskyProfile({ value }));
}
export function parseBlueskyPost({ value }: { value: unknown }) {
  const p = object(value),
    record = object(p.record),
    author = parseBlueskyProfile({ value: p.author });
  return postSchema.parse({
    id: p.uri,
    text: text(record.text),
    author,
    timestamp: timestamp(record.createdAt),
    likes: p.likeCount,
    url: `https://bsky.app/profile/${author.username}/post/${text(p.uri).split("/").pop()}`,
    images: list(object(p.embed).images).flatMap((image) => https(object(image).fullsize) ?? []),
    parentId: object(object(record.reply).parent).uri,
  });
}
export async function blueskyPost({ id }: { id: string }) {
  const data = await api({
    method: "app.bsky.feed.getPostThread",
    params: { uri: id, depth: "1", parentHeight: "1" },
  });
  const thread = object(data.thread);
  return {
    post: parseBlueskyPost({ value: thread.post }),
    parentPost: object(thread.parent).post
      ? parseBlueskyPost({ value: object(thread.parent).post })
      : undefined,
  };
}
export async function blueskyFeed({ account }: { account: Account }): Promise<SourceResult> {
  const data = await api({
    method: "app.bsky.notification.listNotifications",
    params: { limit: "100" },
  });
  if (!Array.isArray(data.notifications))
    throw socialError({ message: "Bluesky notifications have changed. Please try again later." });
  const reasons = {
    mention: "mentions",
    reply: "replies",
    like: "reactions",
    repost: "reactions",
    quote: "mentions",
    follow: "follows",
  } as const;
  const notifications = list(data.notifications).flatMap((value) => {
    const n = object(value),
      event = text(n.reason),
      category = reasons[event as keyof typeof reasons];
    if (!category) return [];
    const actor = parseBlueskyProfile({ value: n.author }),
      record = object(n.record),
      uri = text(n.reasonSubject || n.uri);
    const ownPost = event === "reply" || event === "mention" || event === "quote";
    const url =
      event === "follow"
        ? `https://bsky.app/profile/${actor.username}`
        : `https://bsky.app/profile/${uri.split("/")[2]}/post/${uri.split("/").pop()}`;
    return [
      notificationSchema.parse({
        id: `bluesky:${account.id}:${n.uri}:${event}`,
        network: "bluesky",
        accountId: account.id,
        category,
        event,
        timestamp: timestamp(n.indexedAt),
        text: {
          like: "liked your post",
          repost: "reposted your post",
          follow: "followed you",
          reply: "replied to you",
          mention: "mentioned you",
          quote: "quoted your post",
        }[event],
        actors: [actor],
        url,
        post:
          event === "follow"
            ? undefined
            : {
                id: uri,
                text: ownPost ? text(record.text) : "",
                url,
                images: [],
                ...(ownPost ? { author: actor } : {}),
              },
      }),
    ];
  });
  return { notifications, stories: [] };
}
export async function markBlueskyRead({ seenAt }: { seenAt: string }) {
  await api({ method: "app.bsky.notification.updateSeen", body: { seenAt } });
}
export { api as blueskyRequest };
