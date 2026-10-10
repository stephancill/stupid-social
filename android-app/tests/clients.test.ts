import { expect, test, spyOn } from "bun:test";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { p256 } from "@noble/curves/nist.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { clientCommands, clientHelp, runClient } from "../scripts/clients/main";
import { parseClientArguments, type Context } from "../scripts/clients/arguments";
import {
  installProbeRuntime,
  normalizeCredentials,
  cookieCredentials,
  credentialsJSON,
  redact,
  writePrivateJSON,
  type ProbeNetwork,
} from "../scripts/clients/runtime";
import { xUnreadCount } from "../src/x/client";
import { githubPage } from "../src/github/client";
import { instagramGetProfile, instagramPosts } from "../src/instagram/client";
import { igBootstrap, igRequest } from "../src/instagram/session";
import { instagramHomepageViewer, instagramHomepageTray } from "../src/instagram/homepage";
import { spotifyRequest, spotifyProfileAttributes } from "../src/providers/spotify";
import { blueskyRequest } from "../src/providers/bluesky";
import type { ClientRuntime, Credentials } from "../src/clientRuntime";

const response = (value: unknown, headers?: HeadersInit) => Response.json(value, { headers });
function harness({
  network,
  initial,
  fetch,
}: {
  network: ProbeNetwork;
  initial: Credentials;
  fetch: ClientRuntime["fetch"];
}) {
  const calls: { url: URL; init: RequestInit; headers: Headers }[] = [];
  const session = installProbeRuntime({
    network,
    initial,
    fetch: async (url, init) => {
      calls.push({ url: new URL(url), init, headers: new Headers(init.headers) });
      return fetch(url, init);
    },
  });
  const run = ({
    name,
    args = [],
    options = {},
  }: {
    name: string;
    args?: string[];
    options?: Context["options"];
  }) => clientCommands[network][name]!.run({ network, args, options, session });
  return { calls, session, run };
}

test("all five probe entry points expose the retained command inventory without native imports", async () => {
  const expected = {
    x: "bootstrap account notifications load-notifications unread-count device-follow profile tweet search-users follow unfollow notify",
    instagram:
      "bootstrap refresh docids activity stories-tray story-page current-user news-inbox direct-inbox profile-username profile-web profile-diagnosis search-users mention-search story-seen force-story-seen like-media unlike-media like-story unlike-story follow unfollow upload-story-image delete-story graphql",
    github: "bootstrap validate notifications feed parse",
    spotify:
      "bootstrap refresh-token server-time totp buddylist validate-cookie-login profile-attributes resolve-username username current-username client-token user-profile search-users following followers audio-analysis track-preview is-track-saved save-track remove-track get",
    bluesky: "notifications load-notifications profile post-thread",
  };
  for (const network of Object.keys(expected) as ProbeNetwork[]) {
    expect(Object.keys(clientCommands[network]).sort()).toEqual(
      expected[network].split(" ").sort(),
    );
    const output = spyOn(console, "log").mockImplementation(() => {});
    try {
      await runClient({ network, args: ["--help"] });
      expect(output).toHaveBeenCalledWith(clientHelp({ network }));
    } finally {
      output.mockRestore();
    }
  }
});

test("CLI rejects ambiguous credentials and unrelated options before making requests", () => {
  const commands = clientCommands.instagram;
  expect(() => parseClientArguments({ commands, args: ["current-user"] })).toThrow(
    "credential source",
  );
  expect(() =>
    parseClientArguments({
      commands,
      args: ["current-user", "--simulator", "--credentials-file", "unused"],
    }),
  ).toThrow("credential source");
  expect(() =>
    parseClientArguments({ commands, args: ["current-user", "--simulator", "--posts"] }),
  ).toThrow("does not apply");
  expect(() => parseClientArguments({ commands, args: ["profile-web", "--simulator"] })).toThrow(
    "Expected:",
  );
  expect(
    parseClientArguments({
      commands,
      args: ["profile-web", "example", "--simulator", "--posts", "--cursor", "a+/="],
    }),
  ).toMatchObject({ options: { posts: true, cursor: "a+/=" } });
});

test("credential input selects cookies and converts native dates and DPoP keys", () => {
  expect(() =>
    credentialsJSON({ network: "x", input: '{"authToken":"private-unclosed-value' }),
  ).toThrow("Invalid credentials JSON.");
  expect(
    cookieCredentials({
      network: "x",
      header: "unrelated=discard; auth_token=fake-auth; ct0=fake-csrf",
    }),
  ).toEqual({ authToken: "fake-auth", ct0: "fake-csrf" });
  expect(() => cookieCredentials({ network: "bluesky", header: "a=b" })).toThrow("OAuth");
  expect(
    normalizeCredentials({
      network: "spotify",
      value: {
        sp_dc: "fake-cookie",
        accessTokenExpiresAt: 0,
        initialBearerTokenExpiresAt: "2026-09-20T00:00:00Z",
        username: null,
      },
    }),
  ).toEqual({
    spDC: "fake-cookie",
    expiresAt: "978307200000",
    initialExpiresAt: String(Date.parse("2026-09-20T00:00:00Z")),
  });
  const key = new Uint8Array(32).fill(7);
  expect(
    normalizeCredentials({
      network: "bluesky",
      value: {
        dpopPrivateKey: Buffer.from(key).toString("base64"),
        pdsURL: "https://pds.example/",
        authServerURL: "https://auth.example",
        expiresAt: 0,
      },
    }),
  ).toEqual({
    key: Buffer.from(key).toString("base64url"),
    pds: "https://pds.example",
    authServerURL: "https://auth.example",
    expiresAt: "978307200000",
  });
});

test("output redacts credential fields, bearer echoes and JWTs without hiding usernames", async () => {
  const session = installProbeRuntime({
    network: "spotify",
    initial: { bearerToken: "fake-bearer-secret", username: "example" },
  });
  await session.runtime.saveCredentials({
    network: "spotify",
    value: { bearerToken: "new-bearer-secret" },
  });
  expect(
    redact({
      secrets: session.knownSecrets,
      value: {
        username: "example",
        cookie: "sp_dc=private",
        accessTokenPresent: true,
        detail: "fake-bearer-secret new-bearer-secret",
        jwt: "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl",
      },
    }),
  ).toEqual({
    username: "example",
    cookie: "[redacted]",
    accessTokenPresent: true,
    detail: "[redacted] [redacted]",
    jwt: "[redacted]",
  });
});

test("private JSON exports replace existing files with owner-only permissions", async () => {
  const directory = await mkdtemp(join(tmpdir(), "social-clients-"));
  try {
    const path = join(directory, "session.json");
    await writePrivateJSON({ path, value: { test: "first" } });
    await writePrivateJSON({ path, value: { test: "second" } });
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ test: "second" });
    expect((await stat(path)).mode & 0o777).toBe(0o600);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

const timeline = {
  data: {
    viewer_v2: {
      user_results: {
        result: {
          notification_timeline: {
            timeline: {
              instructions: [
                { entries: [{ content: { cursorType: "Top", value: "opaque-cursor" } }] },
              ],
            },
          },
        },
      },
    },
  },
};
test("X rotates only selected cookies and distinguishes count/read/mark-seen commands", async () => {
  const h = harness({
    network: "x",
    initial: { authToken: "fake-auth", ct0: "old-csrf" },
    fetch: async (url) => {
      if (url.includes("unread_count"))
        return response(
          { unreadCount: 2 },
          { "set-cookie": "ct0=new-csrf; Path=/; Secure, unrelated=discard; Path=/" },
        );
      if (url.includes("account/multi"))
        return response({ users: [{ user_id: "1", screen_name: "viewer", name: "Viewer" }] });
      return response(url.includes("NotificationsTimeline") ? timeline : {});
    },
  });
  expect(await xUnreadCount()).toBe(2);
  expect(h.calls).toHaveLength(1);
  expect(h.session.current()).toEqual({ authToken: "fake-auth", ct0: "new-csrf" });
  await h.run({ name: "notifications", options: { count: "5" } });
  expect(
    h.calls.every(
      ({ init }) =>
        init.method === "GET" && init.redirect === "manual" && init.credentials === "omit",
    ),
  ).toBe(true);
  const feed = h.calls.find(({ url }) => url.pathname.endsWith("NotificationsTimeline"))!;
  expect(JSON.parse(feed.url.searchParams.get("variables")!).count).toBe(5);
  expect(feed.headers.get("x-csrf-token")).toBe("new-csrf");
  await h.run({ name: "load-notifications" });
  expect(
    h.calls
      .filter(({ init }) => init.method === "POST")
      .map(({ url }) => [url.pathname, url.searchParams.get("cursor")]),
  ).toEqual([["/i/api/2/notifications/all/last_seen_cursor.json", "opaque-cursor"]]);
});

test("GitHub uses matching nonce headers, rotates cookies and handles conditional feeds and redirects", async () => {
  let status = 200;
  const h = harness({
    network: "github",
    initial: { userSession: "fake-session", sameSiteUserSession: "fake-same-site" },
    fetch: async () =>
      new Response(status === 200 ? '<meta name="user-login" content="viewer">' : null, {
        status,
        headers: {
          "set-cookie": "user_session=rotated-session; Path=/",
          etag: "version-1",
          location: "https://github.com/login",
        },
      }),
  });
  expect(await h.run({ name: "validate" })).toMatchObject({
    authenticated: true,
    account: { username: "viewer" },
  });
  expect(h.session.current()?.userSession).toBe("rotated-session");
  status = 304;
  expect(
    await githubPage({
      path: "/conduit/for_you_feed",
      authenticated: true,
      feed: true,
      etag: "version-1",
    }),
  ).toMatchObject({ status: 304, etag: "version-1" });
  const sent = h.calls.at(-1)!;
  expect(sent.headers.get("x-fetch-nonce")).toBe(sent.headers.get("x-fetch-nonce-to-validate"));
  expect(sent.headers.get("if-none-match")).toBe("version-1");
  expect(sent.headers.get("cookie")).toContain("user_session=rotated-session");
  status = 302;
  await expect(githubPage({ path: "/", authenticated: true })).rejects.toThrow("reconnect");
  expect(h.calls.every(({ init }) => init.redirect === "manual")).toBe(true);
});

const igPage = `<script type="application/json" data-sjs>${JSON.stringify({
  csrf_token: "fake-csrf",
  LSD: { token: "fake-lsd" },
  DTSGInitialData: { token: "fake-dtsg" },
  gkx: {
    "17028": { result: false },
    "6793": { result: true },
    "17363": { result: false },
    "9448": { result: true },
    "12774": { result: false },
    "684": { result: false },
  },
  qex: { "1697": { r: null }, "3668": { r: null }, "2404": { r: true }, "684": { r: true } },
  initialRouteInfo: {
    route: { rootView: { props: { id: "99", page_logging: { params: { profile_id: "99" } } } } },
  },
})}</script><script src="https://static.cdninstagram.com/fixture.js"></script>`;
const igDocs = [
  "PolarisProfilePageContentQuery",
  "PolarisProfilePostsQuery",
  "PolarisAPIReelSeenMutation",
]
  .map(
    (name, i) => `__d("${name}_instagramRelayOperation",[],(function(){e.exports="${i + 100}"}));`,
  )
  .join("\n");

const homepage = ({
  username = "example",
  id = "42",
  tray = [],
}: { username?: string; id?: string; tray?: unknown[] } = {}) =>
  `<script data-sjs>${JSON.stringify({ require: [["PolarisViewer", [], { data: { id, username, full_name: "Example", profile_pic_url: "https://example.org/avatar.jpg" } }, 1]], is_logged_out_user: false, data: { xdt_api__v1__feed__reels_tray: { tray } } })}</script>`;

test("Instagram identity and stories share a fresh homepage without inbox, GraphQL or asset requests", async () => {
  let html = homepage({ tray: [{ id: "99", user: { pk: "99", username: "friend" } }] });
  const h = harness({
    network: "instagram",
    initial: { sessionId: "session", dsUserId: "42", csrfToken: "csrf" },
    fetch: async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      return new Response(html);
    },
  });
  const [account, stories] = await Promise.all([
    h.run({ name: "current-user" }),
    h.run({ name: "stories-tray" }),
  ]);
  expect(account).toMatchObject({
    id: "42",
    username: "example",
    avatar: "https://example.org/avatar.jpg",
  });
  expect(stories).toMatchObject({
    data: { xdt_api__v1__feed__reels_tray: { tray: [{ id: "99" }] } },
  });
  expect(h.calls).toHaveLength(1);
  html = homepage({ username: "updated" });
  expect(await h.run({ name: "current-user" })).toMatchObject({ username: "updated" });
  expect(await h.run({ name: "stories-tray" })).toMatchObject({
    data: { xdt_api__v1__feed__reels_tray: { tray: [] } },
  });
  expect(h.calls).toHaveLength(3);
  expect(h.calls.every(({ url }) => url.pathname === "/")).toBe(true);
});

test("Instagram homepage rejects logout, wrong accounts, unrelated users and absent or malformed trays", () => {
  expect(() => instagramHomepageViewer({ html: homepage({ id: "99" }), accountID: "42" })).toThrow(
    "does not match",
  );
  expect(() =>
    instagramHomepageViewer({
      html: homepage().replace('"is_logged_out_user":false', '"is_logged_out_user":true'),
      accountID: "42",
    }),
  ).toThrow("reconnect");
  expect(() =>
    instagramHomepageViewer({
      html: '<script data-sjs>{"user":{"id":"42","username":"unrelated"}}</script>',
      accountID: "42",
    }),
  ).toThrow("signed-in account");
  expect(() =>
    instagramHomepageViewer({ html: homepage({ username: "" }), accountID: "42" }),
  ).toThrow("signed-in account");
  expect(() =>
    instagramHomepageTray({
      html: homepage().replace('"tray":[]', '"tray":null'),
      accountID: "42",
    }),
  ).toThrow("valid stories tray");
  expect(() =>
    instagramHomepageTray({
      html: homepage().replace('"xdt_api__v1__feed__reels_tray"', '"unrelated"'),
      accountID: "42",
    }),
  ).toThrow("valid stories tray");
  expect(() =>
    instagramHomepageTray({ html: homepage({ tray: [{ id: "99", user: {} }] }), accountID: "42" }),
  ).toThrow("valid stories tray");
});

test("Instagram keeps working session headers while a fresh homepage is in flight", async () => {
  let complete!: (response: Response) => void;
  let notifyStarted!: () => void;
  const started = new Promise<void>((resolve) => {
    notifyStarted = resolve;
  });
  let pageCount = 0;
  const page = (token: string) =>
    `${homepage()}<script data-sjs>${JSON.stringify({ LSD: { token }, csrf_token: `${token}-csrf` })}</script>`;
  const h = harness({
    network: "instagram",
    initial: { sessionId: "session", dsUserId: "42", csrfToken: "csrf" },
    fetch: async (url) => {
      if (new URL(url).pathname !== "/") return response({ status: "ok" });
      if (++pageCount === 1) return new Response(page("first"));
      notifyStarted();
      return new Promise<Response>((resolve) => {
        complete = resolve;
      });
    },
  });
  await igBootstrap();
  const refreshed = h.run({ name: "current-user" });
  await started;
  await igRequest({ path: "/api/v1/direct_v2/inbox/" });
  expect(h.calls.at(-1)!.headers.get("X-FB-LSD")).toBe("first");
  expect(h.calls.at(-1)!.headers.get("X-CSRFToken")).toBe("first-csrf");
  complete(new Response(page("second")));
  await refreshed;
  await igRequest({ path: "/api/v1/direct_v2/inbox/" });
  expect(h.calls.at(-1)!.headers.get("X-FB-LSD")).toBe("second");
  expect(h.calls.at(-1)!.headers.get("X-CSRFToken")).toBe("second-csrf");
});
test("Instagram CLI and app share runtime discovery, modern profile queries, pagination and seen mutation", async () => {
  const h = harness({
    network: "instagram",
    initial: { sessionId: "fake-session", csrfToken: "old-csrf", dsUserId: "42" },
    fetch: async (url, init) => {
      const parsed = new URL(url);
      if (parsed.hostname === "static.cdninstagram.com") return new Response(igDocs);
      if (parsed.pathname.startsWith("/graphql/query")) {
        const doc = parsed.searchParams.get("doc_id");
        if (init.method === "POST") return response({ data: { status: "ok" } });
        return response({
          data:
            doc === "100"
              ? { user: { pk: "99", username: "example", full_name: "Example" } }
              : {
                  xdt_api__v1__feed__user_timeline_graphql_connection: {
                    edges: [],
                    page_info: { has_next_page: false, end_cursor: null },
                  },
                },
        });
      }
      return new Response(igPage, { headers: { "set-cookie": "csrftoken=fake-csrf; Path=/" } });
    },
  });
  await igBootstrap();
  expect((await instagramGetProfile({ username: "example" })).id).toBe("99");
  await instagramPosts({ username: "example", cursor: "opaque+/=" });
  const posts = h.calls.find(({ url }) => url.searchParams.get("doc_id") === "101")!;
  expect(JSON.parse(posts.url.searchParams.get("variables")!).after).toBe("opaque+/=");
  expect(h.calls.filter(({ url }) => url.hostname === "static.cdninstagram.com")).toHaveLength(1);
  expect(h.calls.some(({ url }) => url.pathname.includes("web_profile_info"))).toBe(false);
  expect(h.session.current()?.csrfToken).toBe("fake-csrf");
  await h.run({
    name: "story-seen",
    options: {
      "media-id": "123_99",
      "owner-id": "99",
      "reel-id": "99",
      "taken-at": "1000",
      "seen-at": "2000",
    },
  });
  const mutations = h.calls.filter(({ init }) => init.method === "POST");
  expect(mutations).toHaveLength(1);
  expect(
    JSON.parse(new URLSearchParams(mutations[0]!.init.body as string).get("variables")!),
  ).toEqual({
    reelId: "99",
    reelMediaId: "123",
    reelMediaOwnerId: "99",
    reelMediaTakenAt: 1000,
    viewSeenAt: 2000,
  });
});

test("rate-limited Instagram bootstrap fails once without retry storms", async () => {
  const h = harness({
    network: "instagram",
    initial: { sessionId: "fake-session" },
    fetch: async () => new Response("", { status: 429, headers: { "retry-after": "60" } }),
  });
  await expect(igBootstrap()).rejects.toThrow("limiting requests");
  expect(h.calls).toHaveLength(1);
  expect(h.session.requests[0]).toMatchObject({ status: 429, retryAfter: "60" });
});

test("Spotify renews from sp_dc alone, coalesces renewal and keeps init/client tokens separate", async () => {
  const h = harness({
    network: "spotify",
    initial: { spDC: "fake-spdc" },
    fetch: async (url, init) => {
      if (url.includes("server-time")) return response({ serverTime: 1777993436 });
      if (url.includes("/api/token"))
        return response({
          accessToken:
            new URL(url).searchParams.get("reason") === "init" ? "fake-initial" : "fake-transport",
          accessTokenExpirationTimestampMs: Date.now() + 3600000,
          clientId: "test-client",
        });
      if (url.includes("clienttoken.spotify"))
        return response({ granted_token: { token: "fake-client-token" } });
      if (url.includes("pathfinder")) {
        expect(JSON.parse(init.body as string).operationName).toBe("profileAttributes");
        return response({ data: { me: { profile: { username: "example" } } } });
      }
      return response({ friends: [] });
    },
  });
  await Promise.all([
    spotifyRequest({ path: "presence-view/v1/buddylist" }),
    spotifyRequest({ path: "presence-view/v1/buddylist" }),
  ]);
  expect(h.calls.filter(({ url }) => url.pathname === "/api/token")).toHaveLength(1);
  await spotifyProfileAttributes();
  const renewals = h.calls.filter(({ url }) => url.pathname === "/api/token");
  expect(renewals.map(({ url }) => url.searchParams.get("reason"))).toEqual(["transport", "init"]);
  expect(renewals.every(({ headers }) => headers.get("cookie") === "sp_dc=fake-spdc")).toBe(true);
  const pathfinder = h.calls.find(({ url }) => url.hostname === "api-partner.spotify.com")!;
  const clientToken = h.calls.find(({ url }) => url.hostname === "clienttoken.spotify.com")!;
  expect(clientToken.headers.get("accept")).toBe("application/json");
  expect(clientToken.headers.get("app-platform")).toBe("WebPlayer");
  expect(pathfinder.headers.get("authorization")).toBe("Bearer fake-initial");
  expect(pathfinder.headers.get("client-token")).toBe("fake-client-token");
  expect(h.session.current()?.bearerToken).toBe("fake-transport");
  await expect(spotifyRequest({ path: "https://unrelated.example/private" })).rejects.toThrow(
    "Unsupported",
  );
});

test("Spotify retries an expired bearer once and propagates persistent rejection", async () => {
  let apiCalls = 0;
  const h = harness({
    network: "spotify",
    initial: {
      spDC: "fake-spdc",
      bearerToken: "expired-on-server",
      expiresAt: String(Date.now() + 3600000),
    },
    fetch: async (url) => {
      if (url.includes("server-time")) return response({ serverTime: 1777993436 });
      if (url.includes("/api/token"))
        return response({
          accessToken: "replacement-bearer",
          accessTokenExpirationTimestampMs: Date.now() + 3600000,
        });
      apiCalls++;
      return new Response("{}", { status: 401 });
    },
  });
  await expect(spotifyRequest({ path: "presence-view/v1/buddylist" })).rejects.toThrow("401");
  expect(apiCalls).toBe(2);
  expect(h.session.current()?.bearerToken).toBe("replacement-bearer");
});

const bskyKey = new Uint8Array(32).fill(7);
const bsky = {
  did: "did:plc:example",
  key: Buffer.from(bskyKey).toString("base64url"),
  pds: "https://pds.example",
  authServerURL: "https://auth.example",
  refreshToken: "fake-refresh",
  accessToken: "old-access",
  expiresAt: "0",
};
test("Bluesky discovers its native session issuer, rotates OAuth and signs nonce retries", async () => {
  let authAttempts = 0,
    resourceAttempts = 0;
  const h = harness({
    network: "bluesky",
    initial: bsky,
    fetch: async (url, init) => {
      if (url.includes(".well-known"))
        return response({
          issuer: "https://auth.example",
          token_endpoint: "https://auth.example/token",
          pushed_authorization_request_endpoint: "https://auth.example/par",
          authorization_endpoint: "https://auth.example/authorize",
        });
      if (url === "https://auth.example/token") {
        authAttempts++;
        if (authAttempts === 1)
          return new Response("{}", { status: 400, headers: { "DPoP-Nonce": "auth-challenge" } });
        expect(new URLSearchParams(init.body as string).get("refresh_token")).toBe("fake-refresh");
        return response(
          {
            sub: bsky.did,
            access_token: "new-access",
            refresh_token: "new-refresh",
            expires_in: 3600,
          },
          { "DPoP-Nonce": "next-auth" },
        );
      }
      resourceAttempts++;
      if (resourceAttempts === 1)
        return new Response("{}", { status: 401, headers: { "DPoP-Nonce": "resource-challenge" } });
      return response({ did: bsky.did }, { "DPoP-Nonce": "next-resource" });
    },
  });
  await blueskyRequest({ method: "app.bsky.actor.getProfile", params: { actor: bsky.did } });
  expect([authAttempts, resourceAttempts]).toEqual([2, 2]);
  expect(h.session.current()).toMatchObject({
    accessToken: "new-access",
    refreshToken: "new-refresh",
    authNonce: "next-auth",
    resourceNonce: "next-resource",
    tokenEndpoint: "https://auth.example/token",
  });
  const [header, payload, signature] = h.calls.at(-1)!.headers.get("dpop")!.split(".");
  const claims = JSON.parse(Buffer.from(payload!, "base64url").toString());
  expect(claims).toMatchObject({
    htm: "GET",
    htu: "https://pds.example/xrpc/app.bsky.actor.getProfile",
    nonce: "resource-challenge",
    ath: Buffer.from(sha256(new TextEncoder().encode("new-access"))).toString("base64url"),
  });
  expect(
    p256.verify(
      Buffer.from(signature!, "base64url"),
      new TextEncoder().encode(`${header}.${payload}`),
      p256.getPublicKey(bskyKey),
    ),
  ).toBe(true);
});

test("Bluesky notifications do not mark seen unless explicitly requested", async () => {
  const h = harness({
    network: "bluesky",
    initial: { ...bsky, expiresAt: String(Date.now() + 3600000) },
    fetch: async () => response({ notifications: [] }),
  });
  await h.run({ name: "notifications" });
  expect(h.calls.map(({ init }) => init.method)).toEqual(["GET"]);
  await h.run({ name: "load-notifications" });
  expect(h.calls.map(({ url }) => url.pathname)).toEqual([
    "/xrpc/app.bsky.notification.listNotifications",
    "/xrpc/app.bsky.notification.listNotifications",
    "/xrpc/app.bsky.notification.updateSeen",
  ]);
  expect(h.calls.at(-1)!.init.method).toBe("POST");
});

test("CLI saves rotated credentials even when the subsequent request fails, without printing them", async () => {
  const directory = await mkdtemp(join(tmpdir(), "social-cli-"));
  const path = join(directory, "credentials.json"),
    saved = join(directory, "saved.json");
  const output = spyOn(console, "log").mockImplementation(() => {});
  const errors = spyOn(console, "error").mockImplementation(() => {});
  const oldExitCode = process.exitCode;
  const fetch: ClientRuntime["fetch"] = async (input) => {
    const url = String(input);
    if (url.includes("server-time")) return response({ serverTime: 1777993436 });
    if (url.includes("/api/token"))
      return response({
        accessToken: "new-private-bearer",
        accessTokenExpirationTimestampMs: Date.now() + 3600000,
      });
    return new Response("{}", { status: 500 });
  };
  try {
    await writePrivateJSON({ path, value: { spDC: "private-cookie" } });
    await runClient({
      network: "spotify",
      fetch,
      args: ["buddylist", "--credentials-file", path, "--save-credentials", saved],
    });
    expect(process.exitCode).toBe(1);
    expect(JSON.parse(await readFile(saved, "utf8")).bearerToken).toBe("new-private-bearer");
    expect(output).not.toHaveBeenCalled();
    expect(JSON.stringify(errors.mock.calls)).not.toMatch(/private-cookie|new-private-bearer/);
  } finally {
    output.mockRestore();
    errors.mockRestore();
    process.exitCode = oldExitCode ?? 0;
    await rm(directory, { recursive: true, force: true });
  }
});
