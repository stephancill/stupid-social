import { z } from "zod";
import { request, json } from "../app/http";
import { credentials, saveCredentials, generation, type Credentials } from "../clientRuntime";
import {
  accountSchema,
  profileSchema,
  storyReelSchema,
  socialError,
  type Account,
  type SourceResult,
} from "../app/models";
import { object, list, text, https, findObjects } from "../app/value";
import { spotifyTOTP } from "./spotify-totp";
const appVersion = "1.2.90.229.g33aad738",
  ua =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const flights = new Map<string, Promise<Credentials>>();
async function token({
  initial = false,
  force = false,
}: { initial?: boolean; force?: boolean } = {}) {
  const key = initial ? "initialBearerToken" : "bearerToken",
    expiry = initial ? "initialExpiresAt" : "expiresAt";
  const c = await credentials({ network: "spotify" });
  if (!c) throw socialError({ message: "Connect Spotify in Settings." });
  if (!force && c[key] && Number(c[expiry]) > Date.now() + 120000) return c;
  if (!c.spDC)
    throw socialError({ message: "Spotify needs to reconnect. Sign in again in Settings." });
  const current = flights.get(key);
  if (current) return current;
  const version = generation({ network: "spotify" });
  const pending = (async () => {
    const clock = await spotifyServerTime();
    const query = new URLSearchParams({
      reason: initial ? "init" : "transport",
      productType: "web-player",
      totp: spotifyTOTP({ seconds: Date.now() / 1000 }),
      totpServer: spotifyTOTP({ seconds: z.number().parse(clock.serverTime) }),
      totpVer: "61",
    });
    const data = await json({
      response: await request({
        url: `https://open.spotify.com/api/token?${query}`,
        network: "spotify",
        headers: {
          Accept: "application/json",
          "app-platform": "WebPlayer",
          Cookie: [`sp_dc=${c.spDC}`, c.spT && `sp_t=${c.spT}`, c.spKey && `sp_key=${c.spKey}`]
            .filter(Boolean)
            .join("; "),
        },
      }),
      network: "spotify",
    });
    const latest = await credentials({ network: "spotify" }),
      next = {
        ...c,
        ...latest,
        [key]: z.string().parse(data.accessToken),
        [expiry]: String(data.accessTokenExpirationTimestampMs ?? Date.now() + 300000),
        clientId: text(data.clientId || c.clientId),
      };
    if (generation({ network: "spotify" }) === version)
      await saveCredentials({ network: "spotify", value: next, expectedGeneration: version });
    return next;
  })().finally(() => flights.delete(key));
  flights.set(key, pending);
  return pending;
}
async function api({ path }: { path: string }) {
  const url = new URL(path.replace(/^\//, ""), "https://spclient.wg.spotify.com/");
  if (
    url.protocol !== "https:" ||
    !["spclient.wg.spotify.com", "api.spotify.com"].includes(url.hostname) ||
    url.username ||
    url.password
  )
    throw new Error("Unsupported authenticated Spotify host");
  let c = await token();
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await request({
      url: url.href,
      allowUnauthorized: true,
      network: "spotify",
      headers: {
        authorization: `Bearer ${c.bearerToken}`,
        "spotify-app-version": appVersion,
        "app-platform": "WebPlayer",
        accept: "application/json",
        "accept-language": "en",
      },
    });
    if ((response.status === 401 || response.status === 403) && attempt === 0) {
      c = await token({ force: true });
      continue;
    }
    return json({ response, network: "spotify" });
  }
  throw socialError({ message: "Spotify needs to reconnect. Sign in again in Settings." });
}
export async function spotifyClientToken({ force = false }: { force?: boolean } = {}) {
  let c = await token({ initial: true });
  const version = generation({ network: "spotify" });
  if (force || !c.clientToken) {
    const data = await json({
      response: await request({
        url: "https://clienttoken.spotify.com/v1/clienttoken",
        method: "POST",
        headers: {
          "User-Agent": ua,
          Accept: "application/json",
          "App-Platform": "WebPlayer",
          "Content-Type": "application/json",
          Origin: "https://open.spotify.com",
          Referer: "https://open.spotify.com/",
        },
        body: JSON.stringify({
          client_data: {
            client_version: appVersion,
            client_id: c.clientId,
            js_sdk_data: {
              device_brand: "",
              device_id: "",
              device_model: "",
              device_type: "",
              os: "",
              os_version: "",
            },
          },
        }),
      }),
      network: "spotify",
    });
    c = { ...c, clientToken: z.string().parse(object(data.granted_token).token) };
    if (generation({ network: "spotify" }) === version)
      await saveCredentials({ network: "spotify", value: c, expectedGeneration: version });
  }
  return c;
}
async function pathfinder({
  operation,
  variables,
  hash,
}: {
  operation: string;
  variables: Record<string, unknown>;
  hash: string;
}) {
  const c = await spotifyClientToken();
  const data = await json({
    response: await request({
      url: "https://api-partner.spotify.com/pathfinder/v2/query",
      network: "spotify",
      method: "POST",
      headers: {
        authorization: `Bearer ${c.initialBearerToken}`,
        "client-token": c.clientToken!,
        "spotify-app-version": appVersion,
        "app-platform": "WebPlayer",
        "Content-Type": "application/json;charset=UTF-8",
        Origin: "https://open.spotify.com",
        Referer: "https://open.spotify.com/",
        "User-Agent": ua,
      },
      body: JSON.stringify({
        operationName: operation,
        variables,
        extensions: { persistedQuery: { version: 1, sha256Hash: hash } },
      }),
    }),
    network: "spotify",
  });
  if (list(data.errors).length)
    throw socialError({ message: "Spotify couldn't complete this action. Reconnect in Settings." });
  return data;
}
function profile({ value }: { value: unknown }) {
  const p = object(value);
  return profileSchema.parse({
    network: "spotify",
    id: text(p.username || p.uri).replace("spotify:user:", ""),
    username: text(p.username || p.uri).replace("spotify:user:", ""),
    name: text(p.name || p.display_name || p.username),
    avatar: https(p.image_url || p.imageUrl),
    followers: p.followers_count,
    bio: "",
  });
}
export async function spotifyProfile({ username }: { username: string }) {
  const p = profile({
    value: await api({ path: `user-profile-view/v3/profile/${encodeURIComponent(username)}` }),
  });
  const [followers, following] = await Promise.all([
    api({
      path: `user-profile-view/v3/profile/${encodeURIComponent(username)}/followers?market=from_token`,
    }),
    api({
      path: `user-profile-view/v3/profile/${encodeURIComponent(username)}/following?market=from_token`,
    }),
  ]);
  return {
    ...p,
    followers: list(followers.profiles).length,
    following: list(following.profiles).length,
  };
}
export async function connectSpotify(): Promise<Account> {
  await api({ path: "presence-view/v1/buddylist" });
  const data = await spotifyProfileAttributes();
  const username = z.string().parse(object(object(object(data.data).me).profile).username);
  return accountSchema.parse({
    ...profile({
      value: await api({ path: `user-profile-view/v3/profile/${encodeURIComponent(username)}` }),
    }),
    connectedAt: Date.now(),
  });
}
export function spotifyProfileAttributes() {
  return pathfinder({
    operation: "profileAttributes",
    variables: {},
    hash: "53bcb064f6cd18c23f752bc324a791194d20df612d8e1239c735144ab0399ced",
  });
}
export function spotifyServerTime() {
  return request({ url: "https://open.spotify.com/api/server-time" }).then((response) =>
    json({ response, network: "spotify" }),
  );
}
export { token as spotifyToken, api as spotifyRequest };
export async function spotifyFeed({ account }: { account: Account }): Promise<SourceResult> {
  const data = await api({ path: "presence-view/v1/buddylist" });
  if (!Array.isArray(data.friends))
    throw socialError({ message: "Spotify returned an unfamiliar activity response." });
  const stories = list(data.friends).map((value) => {
    const f = object(value),
      u = object(f.user),
      track = object(f.track),
      actor = profile({ value: u }),
      id = text(track.uri).split(":").pop()!,
      at = z.number().parse(f.timestamp),
      image = https(track.imageUrl);
    return storyReelSchema.parse({
      id: `spotify:${account.id}:${actor.id}`,
      network: "spotify",
      accountId: account.id,
      actor,
      timestamp: at,
      seen: false,
      thumbnail: image,
      slides: [
        {
          id: `${id}:${at}`,
          trackId: id,
          timestamp: at,
          title: text(track.name),
          artist: text(object(track.artist).name),
          text: text(object(track.album).name),
          context: text(object(track.context).name) || undefined,
          image,
          url: `https://open.spotify.com/track/${id}`,
        },
      ],
    });
  });
  return { notifications: [], stories };
}
export async function spotifySearch({ query }: { query: string }) {
  const data = await api({
    path: `searchview/km/v4/search/${encodeURIComponent(query)}?entityVersion=2&limit=10&market=from_token&platform=web`,
  });
  const values = findObjects({ root: data, key: "uri" }).filter((v) =>
    text(v).startsWith("spotify:user:"),
  );
  return Promise.all(
    [...new Set(values.map(text))].slice(0, 10).map(async (uri) =>
      profile({
        value: await api({
          path: `user-profile-view/v3/profile/${encodeURIComponent(uri.split(":").pop()!)}`,
        }),
      }),
    ),
  );
}
export async function spotifyPreview({ trackId }: { trackId: string }) {
  const response = await request({
    url: `https://open.spotify.com/embed/track/${encodeURIComponent(trackId)}`,
  });
  if (!response.ok) throw socialError({ message: "Spotify preview is unavailable." });
  const html = await response.text(),
    raw = html.match(/"audioPreview"\s*:\s*\{\s*"url"\s*:\s*"([^"]+)"/)?.[1];
  return raw ? https(JSON.parse(`"${raw}"`)) : undefined;
}
export async function spotifySaved({ trackId }: { trackId: string }) {
  const data = await pathfinder({
    operation: "areEntitiesInLibrary",
    variables: { uris: [`spotify:track:${trackId}`] },
    hash: "134337999233cc6fdd6b1e6dbf94841409f04a946c5c7b744b09ba0dfe5a85ed",
  });
  return z.boolean().parse(object(object(list(object(data.data).lookup)[0]).data).saved);
}
export async function spotifySave({ trackId, saved }: { trackId: string; saved: boolean }) {
  await pathfinder({
    operation: saved ? "addToLibrary" : "removeFromLibrary",
    variables: { libraryItemUris: [`spotify:track:${trackId}`] },
    hash: "7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d",
  });
}
