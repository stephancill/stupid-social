import { z } from "zod";
import {
  actorSchema,
  notificationSchema,
  postSchema,
  profileSchema,
  socialError,
  type Actor,
  type Category,
  type Post,
  type Profile,
  type SocialNotification,
} from "../app/models";

export const record = z.record(z.string(), z.unknown());
export function object(value: unknown): Record<string, unknown> {
  return record.safeParse(value).data ?? {};
}
export function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}
function string(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}
function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
function bool(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}
function url(value: unknown): string | undefined {
  const candidate = z.url().safeParse(value);
  return candidate.success && new URL(candidate.data).protocol === "https:"
    ? candidate.data
    : undefined;
}
function date(value: unknown): number | undefined {
  const result = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isFinite(result) ? result : undefined;
}
export function decodeText({ value }: { value: string }) {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}
export function parseProfile({ raw }: { raw: unknown }): Profile | undefined {
  const user = object(raw),
    core = object(user.core),
    legacy = object(user.legacy),
    avatar = object(user.avatar);
  const relationship = object(user.relationship_perspectives);
  const username =
    string(core.screen_name) ?? string(legacy.screen_name) ?? string(user.screen_name);
  const id =
    string(user.rest_id) ?? string(legacy.id_str) ?? string(user.user_id) ?? string(user.id_str);
  if (!id || !username) return undefined;
  return profileSchema.parse({
    id,
    username,
    name: string(core.name) ?? string(legacy.name) ?? string(user.name) ?? username,
    avatar: url(
      avatar.image_url ?? legacy.profile_image_url_https ?? user.profile_image_url_https,
    )?.replace("_normal", ""),
    bio: decodeText({ value: string(legacy.description) ?? string(user.description) ?? "" }),
    location:
      string(object(user.location).location) ?? string(legacy.location) ?? string(user.location),
    website: url(object(list(object(object(legacy.entities).url).urls)[0]).expanded_url),
    followers: number(legacy.followers_count ?? user.followers_count),
    following: number(legacy.friends_count ?? user.friends_count),
    posts: number(legacy.statuses_count ?? user.statuses_count),
    joinedAt: date(core.created_at ?? legacy.created_at ?? user.created_at),
    verified: bool(user.is_blue_verified ?? legacy.verified ?? user.verified),
    isFollowing: bool(relationship.following ?? legacy.following ?? user.following),
    followsYou: bool(relationship.followed_by ?? legacy.followed_by),
    notifyPosts: bool(
      object(user.notifications_settings).notifications_enabled ??
        legacy.notifications ??
        user.notifications,
    ),
  });
}
function actor(raw: unknown): Actor | undefined {
  const profile = parseProfile({ raw });
  return profile ? actorSchema.parse(profile) : undefined;
}
export function parsePost({ raw }: { raw: unknown }): Post | undefined {
  let tweet = object(raw);
  if (tweet.__typename === "TweetWithVisibilityResults") tweet = object(tweet.tweet);
  const legacy = Object.keys(object(tweet.legacy)).length ? object(tweet.legacy) : tweet;
  const id = string(tweet.rest_id) ?? string(legacy.id_str);
  if (!id) return undefined;
  const author = actor(object(object(tweet.core).user_results).result ?? legacy.user);
  const note = object(object(tweet.note_tweet).note_tweet_results).result;
  let text = string(object(note).text) ?? string(legacy.full_text) ?? string(legacy.text) ?? "";
  for (const entity of list(object(legacy.entities).urls)) {
    const e = object(entity);
    if (typeof e.url === "string" && typeof e.expanded_url === "string")
      text = text.replaceAll(e.url, e.expanded_url);
  }
  const media = list(object(legacy.extended_entities ?? tweet.extended_entities).media);
  return postSchema.parse({
    id,
    text: decodeText({ value: text }),
    author,
    url: `https://x.com/${author?.username ?? "i"}/status/${id}`,
    timestamp: date(legacy.created_at),
    likes: number(legacy.favorite_count),
    parentId: string(legacy.in_reply_to_status_id_str),
    images: [
      ...new Set(media.map((m) => url(object(m).media_url_https)).filter((u): u is string => !!u)),
    ],
  });
}
export function parseTweetResult({ raw, id }: { raw: unknown; id: string }): Post {
  const result = object(object(object(object(raw).data).tweetResult).result);
  if (result.__typename !== "Tweet" && result.__typename !== "TweetWithVisibilityResults")
    throw socialError({ message: "This post is unavailable." });
  const post = parsePost({ raw: result });
  if (!post || post.id !== id)
    throw socialError({ message: "X returned an unfamiliar post response. Please try again." });
  return post;
}
const categoryByEvent: Record<string, Category> = {
  user_mentioned_you: "mentions",
  user_mentioned_you_in_a_quote_tweet: "mentions",
  user_replied_to_your_tweet: "replies",
  user_quoted_your_tweet: "replies",
  users_liked_your_tweet: "reactions",
  user_liked_multiple_tweets: "reactions",
  users_retweeted_your_tweet: "reactions",
  users_followed_you: "follows",
  follow_from_recommended_user: "follows",
  device_follow_tweet_notification_entry: "posts",
  user_tweeted: "posts",
  user_tweeted_entry: "posts",
  tweet_notification: "posts",
  user_posted: "posts",
};
function description({ event, actors }: { event: string; actors: Actor[] }) {
  const first = actors[0]!,
    name = first.name || `@${first.username}`;
  const who = `${name}${actors.length > 1 ? ` and ${actors.length - 1} other${actors.length > 2 ? "s" : ""}` : ""}`;
  if (event.includes("mentioned")) return `${who} mentioned you`;
  if (event.includes("replied")) return `${who} replied to your post`;
  if (event.includes("quoted")) return `${who} quoted your post`;
  if (event.includes("liked")) return `${who} liked your post`;
  if (event.includes("retweeted")) return `${who} reposted your post`;
  if (categoryByEvent[event] === "follows") return `${who} followed you`;
  return `New post from ${who}`;
}
const timelineSchema = z.object({
  data: z.object({
    viewer_v2: z.object({
      user_results: z.object({
        result: z.object({
          notification_timeline: z.object({
            timeline: z.object({
              instructions: z.array(z.object({ entries: z.array(record).optional() })),
            }),
          }),
        }),
      }),
    }),
  }),
});
export function parseNotifications({ raw, accountId }: { raw: unknown; accountId: string }) {
  const decoded = timelineSchema.safeParse(raw);
  if (!decoded.success)
    throw socialError({
      message: "X returned an unfamiliar notification response. Please try again later.",
    });
  const entries =
    decoded.data.data.viewer_v2.user_results.result.notification_timeline.timeline.instructions.flatMap(
      (i) => i.entries ?? [],
    );
  const cursor = entries.map((e) => object(e.content)).find((c) => c.cursorType === "Top")?.value;
  if (typeof cursor !== "string" || !cursor)
    throw socialError({
      message: "X did not return a notification cursor. Please try again later.",
    });
  const items: SocialNotification[] = [];
  for (const entry of entries) {
    const content = object(entry.content),
      item = object(content.itemContent),
      template = object(item.template);
    if (content.cursorType) continue;
    const event = string(object(content.clientEventInfo).element) ?? "unknown",
      category = categoryByEvent[event];
    if (!category) continue;
    const tweet = parsePost({ raw: object(item.tweet_results).result });
    const related = list(template.target_objects)
      .map((t) => parsePost({ raw: object(object(t).tweet_results).result }))
      .filter((p): p is Post => !!p);
    const post = tweet ?? related[0];
    const actors = tweet?.author
      ? [tweet.author]
      : list(template.from_users)
          .map((u) => actor(object(object(u).user_results).result))
          .filter((a): a is Actor => !!a);
    if (!actors.length) continue;
    const timestamp = tweet?.timestamp ?? Number(entry.sortIndex);
    if (!Number.isFinite(timestamp) || timestamp <= 0 || timestamp > Date.now() + 86400000)
      continue;
    const sourceId = post?.id ?? string(item.id) ?? string(entry.entryId);
    if (!sourceId) continue;
    items.push(
      notificationSchema.parse({
        id: `x:${accountId}:${sourceId}:${event}`,
        network: "x",
        accountId,
        event,
        category,
        timestamp,
        text: description({ event, actors }),
        actors,
        post,
        relatedPosts: related.slice(1),
        url: post?.url ?? url(object(item.notification_url).url),
      }),
    );
  }
  return { items, cursor };
}
export function parseSearch({ raw }: { raw: unknown }) {
  const root = object(object(object(raw).data).search_by_raw_query);
  const instructions = object(object(root.search_timeline).timeline).instructions;
  if (!Array.isArray(instructions))
    throw socialError({ message: "X search is temporarily unavailable. Please try again later." });
  const users: Profile[] = [],
    seen = new Set<string>();
  function visit(value: unknown) {
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    const o = object(value);
    if (o.itemType === "TimelineUser" || o.__typename === "TimelineUser") {
      const user = parseProfile({ raw: object(o.user_results).result });
      if (user && !seen.has(user.id)) {
        seen.add(user.id);
        users.push(user);
      }
    }
    Object.values(o)
      .filter((v) => v && typeof v === "object")
      .forEach(visit);
  }
  visit(instructions);
  return users;
}
