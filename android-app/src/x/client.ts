import { z } from "zod";
import {
  accountSchema,
  socialError,
  type Account,
  type Post,
  type Profile,
  type SourceResult,
} from "../app/models";
import { credentials, generation, saveCredentials } from "../clientRuntime";
import { request, json, selectedResponseCookies } from "../app/http";
import {
  BEARER_TOKEN,
  NOTIFICATIONS_TIMELINE_FEATURES,
  NOTIFICATIONS_TIMELINE_QUERY_ID,
  SEARCH_TIMELINE_FEATURES,
  SEARCH_TIMELINE_QUERY_ID,
  TWEET_RESULT_QUERY_ID,
} from "./constants";
import {
  object,
  parseNotifications,
  parsePost,
  parseProfile,
  parseSearch,
  parseTweetResult,
} from "./parsers";

export const xCredentialsSchema = z.object({
  authToken: z.string().min(1),
  ct0: z.string().min(1),
});
async function api({
  path,
  method = "GET",
  body,
  signal,
}: {
  path: string;
  method?: string;
  body?: string;
  signal?: AbortSignal;
}) {
  const current = xCredentialsSchema.safeParse(await credentials({ network: "x" }));
  if (!current.success) throw socialError({ message: "Connect X in Settings to continue." });
  const sessionGeneration = generation({ network: "x" });
  const c = current.data;
  const response = await request({
    url: `https://x.com${path}`,
    method,
    body,
    signal,
    network: "x",
    headers: {
      Authorization: `Bearer ${BEARER_TOKEN}`,
      Cookie: `auth_token=${c.authToken}; ct0=${c.ct0}`,
      "X-Csrf-Token": c.ct0,
      "User-Agent": "NoFeedSocial/1",
      "Content-Type": body?.startsWith("{")
        ? "application/json"
        : "application/x-www-form-urlencoded",
    },
  });
  const next = selectedResponseCookies({
    headers: response.headers,
    selected: ["auth_token", "ct0"],
  });
  if (sessionGeneration === generation({ network: "x" }) && (next.auth_token || next.ct0)) {
    await saveCredentials({
      expectedGeneration: sessionGeneration,
      network: "x",
      value: { authToken: next.auth_token || c.authToken, ct0: next.ct0 || c.ct0 },
    });
  }
  const data = await json({ response, network: "x" });
  if (Array.isArray(data.errors) && data.errors.length)
    throw socialError({
      message: "X couldn't complete this request. Reconnect in Settings if this continues.",
    });
  return data;
}
export async function connectX(): Promise<Account> {
  const data = await api({ path: "/i/api/1.1/account/multi/list.json" });
  const user = z
    .object({
      users: z
        .array(z.object({ user_id: z.string(), screen_name: z.string(), name: z.string() }))
        .min(1),
    })
    .parse(data).users[0]!;
  return accountSchema.parse({
    network: "x",
    id: user.user_id,
    username: user.screen_name,
    name: user.name,
    connectedAt: Date.now(),
  });
}
export async function xFeed({
  account,
  signal,
  count = 40,
}: {
  account: Account;
  signal?: AbortSignal;
  count?: number;
}): Promise<SourceResult & { cursor: string }> {
  const params = new URLSearchParams({
    variables: JSON.stringify({
      timeline_type: "All",
      count: z.number().int().min(1).max(100).parse(count),
    }),
    features: JSON.stringify(NOTIFICATIONS_TIMELINE_FEATURES),
  });
  const raw = await api({
    path: `/i/api/graphql/${NOTIFICATIONS_TIMELINE_QUERY_ID}/NotificationsTimeline?${params}`,
    signal,
  });
  const { items, cursor } = parseNotifications({ raw, accountId: account.id });
  return { notifications: items, stories: [], cursor };
}
export async function xUnreadCount() {
  const data = await api({ path: "/i/api/2/notifications/all/unread_count.json" });
  return z.coerce.number().int().nonnegative().parse(data.unreadCount);
}
export { api as xRequest };
export async function markXRead({ cursor }: { cursor: string }) {
  await api({
    path: `/i/api/2/notifications/all/last_seen_cursor.json?${new URLSearchParams({ cursor })}`,
    method: "POST",
  });
}
export async function xSearch({
  query,
  signal,
}: {
  query: string;
  signal?: AbortSignal;
}): Promise<Profile[]> {
  const raw = await api({
    path: `/i/api/graphql/${SEARCH_TIMELINE_QUERY_ID}/SearchTimeline`,
    method: "POST",
    signal,
    body: JSON.stringify({
      variables: {
        rawQuery: query.trim(),
        count: 20,
        querySource: "typed_query",
        product: "People",
        withGrokTranslatedBio: true,
        withQuickPromoteEligibilityTweetFields: false,
      },
      features: SEARCH_TIMELINE_FEATURES,
      queryId: SEARCH_TIMELINE_QUERY_ID,
    }),
  });
  return parseSearch({ raw });
}
export async function xProfile({ username, signal }: { username: string; signal?: AbortSignal }) {
  const params = new URLSearchParams({
    variables: JSON.stringify({
      screen_name: username.replace(/^@/, ""),
      withSafetyModeUserFields: true,
    }),
    features: JSON.stringify({
      hidden_profile_subscriptions_enabled: true,
      rweb_tipjar_consumption_enabled: true,
      responsive_web_graphql_exclude_directive_enabled: true,
      highlights_tweets_tab_ui_enabled: true,
      responsive_web_twitter_article_notes_tab_enabled: true,
      creator_subscriptions_tweet_preview_api_enabled: true,
      responsive_web_graphql_timeline_navigation_enabled: true,
    }),
  });
  const raw = await api({
    path: `/i/api/graphql/IGgvgiOx4QZndDHuD3x9TQ/UserByScreenName?${params}`,
    signal,
  });
  const profile = parseProfile({ raw: object(object(raw.data).user).result });
  if (!profile) throw socialError({ message: "This X profile is unavailable." });
  return profile;
}
export async function xPost({ id, signal }: { id: string; signal?: AbortSignal }): Promise<Post> {
  const params = new URLSearchParams({
    variables: JSON.stringify({
      tweetId: id,
      withCommunity: false,
      includePromotedContent: false,
      withVoice: false,
    }),
    features: JSON.stringify({
      ...NOTIFICATIONS_TIMELINE_FEATURES,
      responsive_web_graphql_exclude_directive_enabled: true,
    }),
    fieldToggles: JSON.stringify({
      withArticleRichContentState: false,
      withArticlePlainText: false,
    }),
  });
  const raw = await api({
    path: `/i/api/graphql/${TWEET_RESULT_QUERY_ID}/TweetResultByRestId?${params}`,
    signal,
  });
  return parseTweetResult({ raw, id });
}
export async function xDevicePosts({ actorId, signal }: { actorId: string; signal?: AbortSignal }) {
  const data = await api({ path: "/i/api/2/notifications/device_follow.json", signal });
  const global = object(data.globalObjects),
    users = object(global.users);
  return Object.values(object(global.tweets))
    .map((value) => {
      const tweet = object(value);
      return parsePost({ raw: { ...tweet, user: users[String(tweet.user_id_str)] } });
    })
    .filter((p): p is Post => !!p && p.author?.id === actorId)
    .sort((a, b) => (b.timestamp ?? 0) - (a.timestamp ?? 0));
}
export async function xRelationship({
  userId,
  follow,
  notify,
}: {
  userId: string;
  follow?: boolean;
  notify?: boolean;
}) {
  const fields = new URLSearchParams({
    include_profile_interstitial_type: "1",
    include_blocking: "1",
    include_blocked_by: "1",
    include_followed_by: "1",
    include_want_retweets: "1",
    include_mute_edge: "1",
    include_can_dm: "1",
    include_can_media_tag: "1",
    include_ext_is_blue_verified: "1",
    include_ext_verified_type: "1",
    include_ext_profile_image_shape: "1",
    skip_status: "1",
  });
  if (notify !== undefined) {
    fields.set("id", userId);
    fields.set("cursor", "-1");
    fields.set("device", String(notify));
  } else {
    fields.set("user_id", userId);
  }
  await api({
    path: `/i/api/1.1/friendships/${notify !== undefined ? "update" : follow ? "create" : "destroy"}.json`,
    method: "POST",
    body: fields.toString(),
  });
}
