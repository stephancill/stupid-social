import { z } from "zod";
import {
  profileSchema,
  notificationSchema,
  postSchema,
  type Account,
  type Actor,
  type Category,
  type Profile,
  type SourceResult,
} from "../app/models";
import { object, list, text, numeric, timestamp, https } from "../app/value";
export function farcasterProfile({ raw }: { raw: unknown }): Profile {
  const p = object(raw);
  return profileSchema.parse({
    network: "farcaster",
    id: text(p.fid),
    username: text(p.username),
    name: text(p.display_name) || text(p.username),
    avatar: https(p.pfp_url),
    bio: text(object(object(p.profile).bio).text),
    followers: numeric(p.follower_count),
    following: numeric(p.following_count),
    joinedAt: timestamp(p.registered_at) || undefined,
  });
}
export function castPost(raw: unknown) {
  const c = object(raw);
  if (!text(c.hash)) return undefined;
  const author = c.author ? farcasterProfile({ raw: c.author }) : undefined;
  let content = text(c.text);
  const chars = Array.from(content),
    profiles = list(c.mentioned_profiles),
    ranges = list(c.mentioned_profiles_ranges);
  for (let i = Math.min(profiles.length, ranges.length) - 1; i >= 0; i--) {
    const r = object(ranges[i]);
    const start = numeric(r.start),
      end = numeric(r.end);
    if (start !== undefined && end !== undefined)
      chars.splice(start, end - start, `@${text(object(profiles[i]).username)}`);
  }
  content = chars.join("");
  return postSchema.parse({
    id: text(c.hash),
    text: content,
    url: `https://farcaster.xyz/${author?.username || "~/conversations"}/${text(c.hash)}`,
    author,
    timestamp: timestamp(c.timestamp) || undefined,
    images: list(c.embeds)
      .map((e) => https(object(e).url))
      .filter((u) => u && /\.(png|jpe?g|webp|gif)(\?|$)/i.test(u)),
    likes: numeric(object(c.reactions).likes_count),
    parentId: text(c.parent_hash) || undefined,
  });
}
export function parseFarcasterNotifications({
  data,
  account,
}: {
  data: Record<string, unknown>;
  account: Account;
}): SourceResult {
  const notifications = z
    .array(z.unknown())
    .parse(data.notifications)
    .flatMap((raw) => {
      const n = object(raw),
        event = text(n.type),
        cast = object(n.cast);
      const category: Category | undefined = (
        {
          "cast-mention": "mentions",
          "cast-reply": "replies",
          reply: text(object(cast.parent_author).fid) === account.id ? "replies" : "mentions",
          mention: "mentions",
          likes: "reactions",
          follows: "follows",
          reaction: "reactions",
          follow: "follows",
        } as const as Record<string, Category>
      )[event];
      if (!category) return [];
      const users = n.user
        ? [n.user]
        : list(n.reactions).length
          ? list(n.reactions)
          : list(n.follows).length
            ? list(n.follows)
            : cast.author
              ? [cast.author]
              : [];
      const actors = users.map((u) => farcasterProfile({ raw: u })) as Actor[];
      if (!actors.length) return [];
      const at = timestamp(n.timestamp ?? n.most_recent_timestamp);
      if (!at) return [];
      const post = castPost(cast),
        verb =
          category === "reactions"
            ? "reacted to your cast"
            : category === "follows"
              ? "followed you"
              : category === "replies"
                ? "replied to you"
                : "mentioned you";
      return [
        notificationSchema.parse({
          id: `farcaster:${account.id}:${event}:${post?.id ?? actors[0]!.id}`,
          network: "farcaster",
          accountId: account.id,
          category,
          event,
          timestamp: at,
          actors,
          text: `${actors[0]!.name}${actors.length > 1 ? ` and ${actors.length - 1} others` : ""} ${verb}`,
          post,
        }),
      ];
    });
  const groups = new Map<string, (typeof notifications)[number]>();
  for (const item of notifications) {
    const key =
      item.category === "follows"
        ? `farcaster:${account.id}:follows`
        : item.category === "reactions"
          ? `farcaster:${account.id}:reaction:${item.post?.id}`
          : item.id;
    const old = groups.get(key);
    const actors = [
      ...new Map(
        [...(old?.actors ?? []), ...item.actors].map((actor) => [actor.id, actor]),
      ).values(),
    ];
    groups.set(key, {
      ...item,
      id: key,
      actors,
      timestamp: Math.max(old?.timestamp ?? 0, item.timestamp),
      text: `${actors[0]!.name}${actors.length > 1 ? ` and ${actors.length - 1} others` : ""} ${item.category === "reactions" ? "reacted to your cast" : item.category === "follows" ? "followed you" : item.category === "replies" ? "replied to you" : "mentioned you"}`,
    });
  }
  return {
    notifications: [...groups.values()].sort((a, b) => b.timestamp - a.timestamp),
    stories: [],
  };
}
