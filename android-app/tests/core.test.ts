import { selectedResponseCookies } from "../src/app/cookies";
import { describe, expect, test } from "bun:test";
import { accountSchema, notificationSchema } from "../src/app/models";
import { mergeRecent, retention } from "../src/app/cache";
import { parseNotifications, parseProfile, parsePost, parseTweetResult } from "../src/x/parsers";
import {
  instagramMessages,
  instagramNews,
  instagramSlides,
  instagramTray,
} from "../src/instagram/parsers";
import { parseGitHubFeed } from "../src/github/parser";
import { parseFarcasterNotifications } from "../src/providers/farcaster-parser";
import { spotifyTOTP } from "../src/providers/spotify-totp";
const now = Math.floor(Date.now() / 1000) * 1000;
const viewer = (network: "x" | "instagram" | "github" | "farcaster") =>
  accountSchema.parse({ network, id: "100", username: "viewer", name: "Viewer", connectedAt: now });
const xUser = {
  rest_id: "1",
  core: { screen_name: "alice", name: "Alice" },
  avatar: { image_url: "https://example.com/avatar.jpg" },
  legacy: { followers_count: 12, friends_count: 8, description: "Hello &amp; welcome" },
};
const xTweet = {
  rest_id: "200",
  legacy: { full_text: "A post", created_at: "Mon Aug 31 12:00:00 +0000 2026", favorite_count: 3 },
  core: { user_results: { result: xUser } },
};
const timeline = (entries: unknown[]) => ({
  data: {
    viewer_v2: {
      user_results: {
        result: { notification_timeline: { timeline: { instructions: [{ entries }] } } },
      },
    },
  },
});
const cursor = { content: { cursorType: "Top", value: "opaque-cursor" } };
describe("X", () => {
  test("hydrates GraphQL tweet details with exact reply and parent IDs", () => {
    const id = "2000000000000000001",
      parentId = "2000000000000000000";
    const result = parseTweetResult({
      id,
      raw: {
        data: {
          tweetResult: {
            result: {
              ...xTweet,
              __typename: "Tweet",
              rest_id: id,
              legacy: { ...xTweet.legacy, in_reply_to_status_id_str: parentId },
            },
          },
        },
      },
    });
    expect(result.id).toBe(id);
    expect(result.parentId).toBe(parentId);
    expect(result.text).toBe("A post");
    expect(result.likes).toBe(3);
    expect(result.author?.username).toBe("alice");
    expect(result.timestamp).toBe(Date.parse(xTweet.legacy.created_at));
  });
  test("unwraps visibility-limited GraphQL tweets without losing long text or media", () => {
    const result = parseTweetResult({
      id: "200",
      raw: {
        data: {
          tweetResult: {
            result: {
              __typename: "TweetWithVisibilityResults",
              tweet: {
                ...xTweet,
                __typename: "Tweet",
                note_tweet: {
                  note_tweet_results: { result: { text: "Complete &amp; untruncated" } },
                },
                extended_entities: {
                  media: [{ media_url_https: "https://example.com/photo.jpg" }],
                },
              },
            },
          },
        },
      },
    });
    expect(result.text).toBe("Complete & untruncated");
    expect(result.images).toEqual(["https://example.com/photo.jpg"]);
  });
  test("rejects missing, unavailable, and mismatched detail results", () => {
    expect(() => parseTweetResult({ id: "200", raw: { data: {} } })).toThrow("unavailable");
    expect(() =>
      parseTweetResult({
        id: "200",
        raw: {
          data: { tweetResult: { result: { __typename: "TweetTombstone", rest_id: "200" } } },
        },
      }),
    ).toThrow("unavailable");
    expect(() =>
      parseTweetResult({
        id: "201",
        raw: { data: { tweetResult: { result: { ...xTweet, __typename: "Tweet" } } } },
      }),
    ).toThrow("unfamiliar post response");
  });
  test("reads modern profiles and media post authors", () => {
    expect(parseProfile({ raw: xUser })?.bio).toBe("Hello & welcome");
    expect(parsePost({ raw: xTweet })?.author?.username).toBe("alice");
  });
  test("requires a top cursor before callers mark notifications read", () => {
    expect(() => parseNotifications({ raw: timeline([]), accountId: "100" })).toThrow();
  });
  test("normalizes direct notification posts and ignores promoted suggestions", () => {
    const result = parseNotifications({
      accountId: "100",
      raw: timeline([
        cursor,
        {
          entryId: "entry",
          sortIndex: String(now),
          content: {
            clientEventInfo: { element: "user_mentioned_you" },
            itemContent: { tweet_results: { result: xTweet } },
          },
        },
        {
          entryId: "ad",
          sortIndex: String(now),
          content: {
            clientEventInfo: { element: "promoted_tweet" },
            itemContent: { tweet_results: { result: xTweet } },
          },
        },
      ]),
    });
    expect(result.cursor).toBe("opaque-cursor");
    expect(result.items).toHaveLength(1);
    expect(result.items[0]!.category).toBe("mentions");
  });
  test("preserves every aggregate actor and related target", () => {
    const result = parseNotifications({
      accountId: "100",
      raw: timeline([
        cursor,
        {
          entryId: "agg",
          sortIndex: String(now),
          content: {
            clientEventInfo: { element: "users_liked_your_tweet" },
            itemContent: {
              template: {
                from_users: [
                  { user_results: { result: xUser } },
                  { user_results: { result: { ...xUser, rest_id: "2" } } },
                ],
                target_objects: [
                  { tweet_results: { result: xTweet } },
                  { tweet_results: { result: { ...xTweet, rest_id: "201" } } },
                ],
              },
            },
          },
        },
      ]),
    });
    expect(result.items[0]!.actors).toHaveLength(2);
    expect(result.items[0]!.relatedPosts[0]!.id).toBe("201");
  });
});
describe("Instagram", () => {
  const alice = { pk: "1", username: "alice", full_name: "Alice" };
  const thread = {
    thread_id: "t1",
    thread_v2_id: "thread",
    users: [alice],
    last_permanent_item: {
      item_id: "m1",
      user_id: "1",
      timestamp: now * 1000,
      item_type: "text",
      text: "Hello",
    },
    last_seen_at: { "100": { timestamp: (now - 1000) * 1000 } },
  };
  const messages = (threads: unknown[], includeMediaShares = true) =>
    instagramMessages({
      data: { inbox: { threads } },
      account: viewer("instagram"),
      preferences: { categories: ["messages"], storiesEnabled: true, includeMediaShares },
    });
  test("includes unread messages and excludes own and read messages", () => {
    expect(messages([thread])).toHaveLength(1);
    expect(
      messages([
        { ...thread, last_permanent_item: { ...thread.last_permanent_item, user_id: "100" } },
      ]),
    ).toHaveLength(0);
    expect(
      messages([{ ...thread, last_seen_at: { "100": { timestamp: now * 1000 } } }]),
    ).toHaveLength(0);
    expect(messages([thread])[0]!.timestamp).toBe(now);
  });
  test("media-share suppression still allows text messages", () => {
    expect(
      messages(
        [
          {
            ...thread,
            last_permanent_item: { ...thread.last_permanent_item, item_type: "xma_clip" },
          },
        ],
        false,
      ),
    ).toHaveLength(0);
    expect(messages([thread], false)).toHaveLength(1);
  });
  test("extracts actors from activity rich text", () => {
    const items = instagramNews({
      account: viewer("instagram"),
      data: {
        new_stories: [
          {
            pk: "n1",
            notif_name: "post_like",
            args: {
              timestamp: now / 1000,
              rich_text: "{alice|a|b|user?id=1} liked your photo",
              profile_id: "1",
              profile_image: "https://example.com/a.jpg",
            },
          },
        ],
      },
    });
    expect(items[0]!.actors[0]!.username).toBe("alice");
  });
  test("suppresses muted stories and preserves seen state", () => {
    const data = {
      data: {
        tray: {
          tray: [
            { id: "1", user: alice, latest_reel_media: now / 1000, seen: now / 1000 },
            { id: "2", user: { ...alice, pk: "2" }, muted: true },
          ],
        },
      },
    };
    const reels = instagramTray({ data, account: viewer("instagram") });
    expect(reels).toHaveLength(1);
    expect(reels[0]!.seen).toBe(true);
  });
  test("story video and links survive normalization", () => {
    const slides = instagramSlides({
      username: "alice",
      value: {
        id: "1",
        user: alice,
        items: [
          {
            pk: "s1",
            taken_at: now / 1000,
            video_versions: [{ url: "https://example.com/video.mp4" }],
            image_versions2: { candidates: [{ url: "https://example.com/image.jpg" }] },
            story_link_stickers: [{ story_link: { url: "https://example.com" } }],
            reel_mentions: [{ user: alice }],
          },
        ],
      },
    });
    expect(slides[0]!.video).toContain("video.mp4");
    expect(slides[0]!.mentions[0]!.username).toBe("alice");
    expect(slides[0]!.links).toEqual(["https://example.com"]);
  });
  test("story stickers retain music and username-only mentions and use the bare media ID", () => {
    const slides = instagramSlides({
      username: "alice",
      value: {
        id: "1",
        user: alice,
        items: [
          {
            id: "123456_1",
            taken_at: now / 1000,
            story_music_stickers: [
              { music_asset_info: { title: "A song", display_artist: "An artist" } },
            ],
            story_bloks_stickers: [
              { bloks_sticker: { sticker_data: { ig_mention: { username: "bob" } } } },
            ],
          },
        ],
      },
    });
    expect(slides[0]!.id).toBe("123456");
    expect(slides[0]!.title).toBe("A song");
    expect(slides[0]!.artist).toBe("An artist");
    expect(slides[0]!.mentions[0]!.username).toBe("bob");
  });
});
function card({
  id,
  actor = "alice",
  repo = "other/repo",
  position = 0,
  sub = 0,
  kind = "STARRED_REPOSITORY",
  at = "2026-08-30T13:00:00Z",
}: {
  id: string;
  actor?: string;
  repo?: string;
  position?: number;
  sub?: number;
  kind?: string;
  at?: string;
}) {
  const meta = {
    card_type: kind,
    created_at: at,
    record_id: id,
    resource_id: id,
    card_position: position,
    card_sub_position: sub,
  };
  const hydro = (extra: Record<string, unknown> = {}) =>
    JSON.stringify({ payload: { feed_card: meta, ...extra } }).replaceAll('"', "&quot;");
  return `<article data-hydro-view="${hydro()}"><a href="/${actor}" data-hydro-click="${hydro({ metadata: { clicked_resource_type: "USER", clicked_resource_id: actor } })}"></a><a href="/${repo}" data-hydro-click="${hydro({ metadata: { clicked_resource_type: "REPO", clicked_resource_id: id } })}"></a></article>`;
}
describe("GitHub", () => {
  test("groups by actor and routes owned-repository stars into notifications", () => {
    const result = parseGitHubFeed({
      account: viewer("github"),
      html:
        card({ id: "1", repo: "viewer/app" }) +
        card({ id: "2", position: 1 }) +
        card({ id: "3", position: 2, kind: "FORKED_REPOSITORY", at: "2026-08-29T13:00:00Z" }),
    });
    expect(result.notifications).toHaveLength(1);
    expect(result.stories).toHaveLength(1);
    expect(result.stories[0]!.slides[0]!.id).toContain("FORKED");
  });
  test("hidden rollup members remain hidden", () => {
    const result = parseGitHubFeed({
      account: viewer("github"),
      html:
        card({ id: "1" }) +
        `<div class="Details-content--hidden">${card({ id: "2", actor: "bob" })}</div>`,
    });
    expect(result.stories).toHaveLength(1);
  });
  test("inherits the primary rollup actor instead of the repository owner", () => {
    const result = parseGitHubFeed({
      account: viewer("github"),
      html:
        card({ id: "1", actor: "alice", position: 3, sub: 0 }) +
        card({ id: "2", actor: "owner", position: 3, sub: 1 }),
    });
    expect(result.stories).toHaveLength(1);
    expect(result.stories[0]!.actor.username).toBe("alice");
    expect(result.stories[0]!.slides).toHaveLength(2);
  });
  test("expands owned-repository rollups and keeps their original dates", () => {
    const html = `<article data-hovercard-url="https://github.com/users/alice/hovercard?payload%5Bfeed_card%5D%5Bcreated_at%5D=2026-08-29+02%3A14%3A51+-0700"><a href="/viewer/repo">viewer/repo</a><a href="/alice">alice</a> starred <a href="/bob">bob</a> starred</article>`;
    const result = parseGitHubFeed({ account: viewer("github"), html });
    expect(result.notifications).toHaveLength(2);
    expect(result.notifications[0]!.timestamp).toBe(Date.parse("2026-08-29T02:14:51-07:00"));
  });
});
describe("Farcaster", () => {
  test("classifies Hypersnap reply aliases and groups follows", () => {
    const data = {
      notifications: [
        {
          type: "reply",
          timestamp: "2026-08-30T13:00:00Z",
          cast: {
            hash: "0xabc",
            text: "Hello",
            author: { fid: 1, username: "alice" },
            parent_author: { fid: 100 },
          },
        },
        {
          type: "reply",
          timestamp: "2026-08-30T13:00:00Z",
          cast: {
            hash: "0xdef",
            author: { fid: 1, username: "alice" },
            parent_author: { fid: 200 },
          },
        },
        {
          type: "follows",
          most_recent_timestamp: now / 1000,
          follows: [{ fid: 2, username: "bob" }],
        },
        {
          type: "follow",
          most_recent_timestamp: now / 1000,
          follows: [{ fid: 3, username: "carol" }],
        },
      ],
    };
    const result = parseFarcasterNotifications({ data, account: viewer("farcaster") });
    expect(result.notifications).toHaveLength(3);
    expect(result.notifications.find((i) => i.category === "follows")!.actors).toHaveLength(2);
    expect(result.notifications.some((i) => i.category === "mentions")).toBe(true);
    expect(result.notifications.some((i) => i.category === "replies")).toBe(true);
  });
});
test("24-hour cache preserves recent items, expires old ones, and deduplicates refreshes", () => {
  const item = (id: string) =>
    notificationSchema.parse({
      id,
      network: "x",
      accountId: "100",
      category: "follows",
      event: "follow",
      timestamp: now,
      text: "followed",
      actors: [{ ...viewer("x"), id: `actor-${id}` }],
    });
  const result = mergeRecent({
    now,
    existing: [
      { item: item("old"), cachedAt: now - retention },
      { item: item("keep"), cachedAt: now - 1000 },
    ],
    incoming: [item("new"), item("new")],
  });
  expect(result.map((r) => r.item.id).sort()).toEqual(["keep", "new"]);
});
test("Spotify token code matches the validated Python reference", () => {
  expect(spotifyTOTP({ seconds: 1789645200 })).toBe("844776");
  expect(spotifyTOTP({ seconds: 1789645201 })).toBe(spotifyTOTP({ seconds: 1789645200 }));
});

test("Expo folded Set-Cookie headers rotate selected values without splitting Expires dates", () => {
  const result = selectedResponseCookies({
    headers: {
      get: () =>
        "ct0=new; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure, auth_token=session; HttpOnly, irrelevant=ignored",
    },
    selected: ["ct0", "auth_token"],
  });
  expect(result).toEqual({ ct0: "new", auth_token: "session" });
});
