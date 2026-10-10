import { z } from "zod";
import { request, json, selectedResponseCookies } from "../app/http";
import { socialError } from "../app/models";
import { credentials, generation, saveCredentials } from "../clientRuntime";
import { object, list } from "../app/value";
import {
  instagramUsername,
  instagramProfileRouteID,
  instagramProfileVariables,
  instagramProfileUser,
} from "./profile";
export const igBase = "https://www.instagram.com";
const ua =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";
const fields: Record<string, string> = {
  sessionid: "sessionId",
  csrftoken: "csrfToken",
  ds_user_id: "dsUserId",
  mid: "mid",
  rur: "rur",
  ig_did: "igDid",
};
const operations = {
  activity: "PolarisActivityFeedStoriesViewQuery",
  forceSeen: "PolarisAPIForceStorySeenMutation",
  storyLike: "usePolarisStoriesV4LikeMutationLikeMutation",
  storyUnlike: "usePolarisStoriesV4LikeMutationUnlikeMutation",
  profile: "PolarisProfilePageContentQuery",
  profilePosts: "PolarisProfilePostsQuery",
  tray: "PolarisStoriesV3TrayContainerQuery",
  delete: "usePolarisStoriesV3DeleteMediaMutation",
  seen: "PolarisAPIReelSeenMutation",
  like: "usePolarisLikeMediaXIGLikeMutation",
  unlike: "usePolarisLikeMediaXIGUnlikeMutation",
  follow: "usePolarisFollowUserFollowMutation",
  unfollow: "usePolarisFollowUserUnfollowMutation",
};
let state: Record<string, string> = {},
  stateVersion = -1,
  bootstrap: Promise<void> | undefined;
let docs: Record<string, string> = {};
const scripts = new Set<string>();
const loadedScripts = new Set<string>();
let requestCount = 0;
const webSession = Math.random().toString(36).slice(2, 8);
let wwwClaim: string | undefined;
let bootstrapHTML = "";
export function documentIds({ source }: { source: string }) {
  return Object.fromEntries(
    [
      ...source.matchAll(
        /__d\("([^"]+?)_instagramRelayOperation",\[\],\(function\([^)]*\)\{.*?\.exports="(\d+)"/gs,
      ),
    ].map((m) => [m[1]!, m[2]!]),
  );
}
function recordPage({ html }: { html: string }) {
  Object.assign(docs, documentIds({ source: html }));
  const previous = [...scripts];
  scripts.clear();
  for (const match of html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)) {
    const url = new URL(match[1]!.replaceAll("&amp;", "&"), igBase);
    if (
      url.protocol === "https:" &&
      (url.hostname === "static.cdninstagram.com" || url.hostname.endsWith(".cdninstagram.com"))
    )
      scripts.add(url.href);
  }
  for (const url of previous) scripts.add(url);
}
export function jazoest({ csrf }: { csrf: string }) {
  return `2${[...csrf].reduce((sum, c) => sum + c.charCodeAt(0), 0)}`;
}
export async function igRequest({
  path,
  method = "GET",
  body,
  headers = {},
  page = false,
}: {
  path: string;
  method?: string;
  body?: string | Uint8Array;
  headers?: Record<string, string>;
  page?: boolean;
}) {
  const version = generation({ network: "instagram" });
  const c = await credentials({ network: "instagram" });
  if (!c?.sessionId) throw socialError({ message: "Connect Instagram in Settings." });
  const url = new URL(path, igBase);
  if (!["www.instagram.com", "i.instagram.com"].includes(url.hostname))
    throw new Error("Invalid Instagram host");
  const requestHeaders: Record<string, string> = {
    Cookie: Object.entries(fields)
      .flatMap(([cookie, key]) => (c[key] ? `${cookie}=${c[key]}` : []))
      .join("; "),
    "User-Agent": ua,
    "Accept-Language": "en-US,en;q=0.9",
    Accept: page ? "text/html,application/xhtml+xml" : "*/*",
    ...(page
      ? {}
      : {
          Origin: igBase,
          Referer: `${igBase}/`,
          "X-IG-App-ID": "1217981644879628",
          "X-ASBD-ID": "359341",
          "X-IG-Max-Touch-Points": "5",
          "X-Web-Session-ID": webSession,
          ...(wwwClaim ? { "X-IG-WWW-Claim": wwwClaim } : {}),
          "X-CSRFToken": state.csrf ?? c.csrfToken!,
          ...(state.lsd ? { "X-FB-LSD": state.lsd } : {}),
          ...(c.igDid ? { "X-Web-Device-Id": c.igDid } : {}),
          ...(c.mid ? { "X-Mid": c.mid } : {}),
        }),
    ...headers,
  };
  if (url.hostname === "i.instagram.com" && path.includes("rupload_igphoto")) {
    delete requestHeaders["X-Web-Device-Id"];
    delete requestHeaders["X-IG-WWW-Claim"];
  }
  const response = await request({
    url: url.href,
    method,
    body,
    network: "instagram",
    headers: requestHeaders,
  });
  wwwClaim =
    response.headers.get("x-ig-set-www-claim") ??
    response.headers.get("x-ig-www-claim") ??
    wwwClaim;
  const rotated = selectedResponseCookies({
    headers: response.headers,
    selected: Object.keys(fields),
  });
  if (Object.keys(rotated).length && generation({ network: "instagram" }) === version) {
    const latest = await credentials({ network: "instagram" });
    if (latest)
      await saveCredentials({
        expectedGeneration: version,
        network: "instagram",
        value: {
          ...latest,
          ...Object.fromEntries(Object.entries(rotated).map(([k, v]) => [fields[k]!, v])),
        },
      });
    if (rotated.csrftoken) state.csrf = rotated.csrftoken;
  }
  if (response.status >= 300 && response.status < 400)
    throw socialError({ message: "Instagram needs to reconnect. Open Settings to sign in again." });
  return response;
}
export async function igPage({ path }: { path: string }) {
  const response = await igRequest({ path, page: true });
  if (!response.ok)
    throw socialError({ message: `Instagram returned an error (${response.status}).` });
  const html = await response.text();
  recordPage({ html });
  return html;
}
async function boot({ refresh = false }: { refresh?: boolean } = {}) {
  const version = generation({ network: "instagram" });
  if (stateVersion === version && !refresh) return;
  bootstrap ??= (async () => {
    if (stateVersion !== version) {
      state = {};
      docs = {};
      scripts.clear();
      loadedScripts.clear();
      wwwClaim = undefined;
      bootstrapHTML = "";
    }
    const html = await igPage({ path: "/" });
    const nextState: Record<string, string> = {};
    const patterns: Record<string, RegExp> = {
      csrf: /"csrf_token"\s*:\s*"([^"]+)"/,
      lsd: /"LSD"[^\n]*?"token"\s*:\s*"([^"]+)"/,
      fb_dtsg: /"DTSGInitialData"[^\n]*?"token"\s*:\s*"([^"]*)"/,
      __rev: /"rev"\s*:\s*(\d+)/,
      __hsi: /"hsi"\s*:\s*"?([0-9]+)/,
      __hs: /"haste_session"\s*:\s*"([^"]+)"/,
    };
    for (const [key, pattern] of Object.entries(patterns)) {
      const value = html.match(pattern)?.[1];
      if (value) nextState[key] = value;
    }
    if (generation({ network: "instagram" }) === version) {
      state = nextState;
      bootstrapHTML = html;
      stateVersion = version;
    }
  })().finally(() => {
    bootstrap = undefined;
  });
  await bootstrap;
}

export async function igHomepage() {
  await boot({ refresh: true });
  return bootstrapHTML;
}

export async function igProfileGraph({
  username,
  id,
  posts = false,
  cursor,
}: {
  username: string;
  id?: string;
  posts?: boolean;
  cursor?: string;
}) {
  const name = instagramUsername.parse(username);
  await boot();
  const operation = posts ? "profilePosts" : "profile";
  let profileID = id && /^\d+$/.test(id) ? id : undefined;
  if (!docs[operations[operation]] || (!posts && !profileID)) {
    const html = await igPage({ path: `/${encodeURIComponent(name)}/` });
    if (!posts && !profileID) profileID = instagramProfileRouteID({ html });
  }
  const variables: Record<string, unknown> = instagramProfileVariables({
    html: bootstrapHTML,
    posts,
  });
  if (posts) {
    variables.username = name;
    variables.data = {
      count: 12,
      include_reel_media_seen_timestamp: true,
      include_relationship_info: true,
      latest_besties_reel_media: true,
      latest_reel_media: true,
    };
    if (cursor) variables.after = cursor;
  } else {
    variables.id = profileID;
    variables.enable_integrity_filters = true;
  }
  const data = await igGraph({ operation, variables, read: true });
  if (!posts) instagramProfileUser({ data, id: profileID! });
  return data;
}
export async function igJSON({ path, form }: { path: string; form?: Record<string, string> }) {
  await boot();
  const data = await json({
    response: await igRequest({
      path,
      method: form ? "POST" : "GET",
      body: form ? new URLSearchParams(form).toString() : undefined,
      headers: form ? { "Content-Type": "application/x-www-form-urlencoded" } : {},
    }),
    network: "instagram",
  });
  if (data.status === "fail" || list(data.errors).length)
    throw socialError({
      message: "Instagram could not complete this request. Try again or reconnect in Settings.",
    });
  return data;
}
export async function igGraph({
  operation,
  variables,
  root,
  read = false,
}: {
  operation: keyof typeof operations;
  variables: Record<string, unknown>;
  root?: string;
  read?: boolean;
}) {
  await boot();
  const name = operations[operation];
  await igDiscover({ name });
  if (!docs[name])
    throw socialError({
      message: "Instagram's current page does not expose this action. Reconnect and try again.",
    });
  return igCustomGraph({ docId: docs[name], name, variables, root, read });
}
export async function igDiscover({
  name,
  storyUsername,
}: { name?: string; storyUsername?: string } = {}) {
  await boot();
  if (storyUsername)
    await igPage({
      path: `/stories/${encodeURIComponent(instagramUsername.parse(storyUsername))}/`,
    });
  if (!name || !docs[name])
    for (const url of scripts) {
      if (loadedScripts.has(url)) continue;
      const response = await request({ url, headers: { "User-Agent": ua } });
      if (response.ok) {
        Object.assign(docs, documentIds({ source: await response.text() }));
        loadedScripts.add(url);
      }
      if (name && docs[name]) break;
    }
  return { ...docs };
}
export async function igBootstrap() {
  await boot();
  return {
    tokens: Object.fromEntries(Object.entries(state).map(([key, value]) => [key, !!value])),
    documentCount: Object.keys(docs).length,
  };
}
export async function igCustomGraph({
  docId,
  variables,
  name,
  root,
  read = true,
}: {
  docId: string;
  variables: Record<string, unknown>;
  name?: string;
  root?: string;
  read?: boolean;
}) {
  await boot();
  z.string().regex(/^\d+$/).parse(docId);
  if (read)
    return igJSON({
      path: `/graphql/query/?${new URLSearchParams({ doc_id: docId, variables: JSON.stringify(variables) })}`,
    });
  const c = await credentials({ network: "instagram" });
  const form = {
    doc_id: docId,
    variables: JSON.stringify(variables),
    server_timestamps: "true",
    __user: c!.dsUserId!,
    __a: "1",
    __req: (++requestCount).toString(36),
    ...Object.fromEntries(Object.entries(state).filter(([k]) => k !== "csrf")),
    jazoest: jazoest({ csrf: state.csrf ?? c!.csrfToken! }),
    ...(root && name ? { fb_api_caller_class: "RelayModern", fb_api_req_friendly_name: name } : {}),
  };
  const data = await json({
    response: await igRequest({
      path: "/graphql/query",
      method: "POST",
      body: new URLSearchParams(form).toString(),
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        ...(root && name ? { "X-FB-Friendly-Name": name, "X-Root-Field-Name": root } : {}),
      },
    }),
    network: "instagram",
  });
  if (list(data.errors).length || (root && !object(data.data)[root]))
    throw socialError({ message: "Instagram did not accept this action. Please try again." });
  return z.record(z.string(), z.unknown()).parse(data);
}
