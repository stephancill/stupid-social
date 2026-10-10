import {
  actorSchema,
  profileSchema,
  notificationSchema,
  storyReelSchema,
  storySlideSchema,
  postSchema,
  type Account,
  type Preferences,
  type SocialNotification,
} from "../app/models";
import { object, list, text, numeric, timestamp, https, findObjects } from "../app/value";
export function instagramProfile({ value }: { value: unknown }) {
  const p = object(value),
    friendship = object(p.friendship_status);
  return profileSchema.parse({
    network: "instagram",
    id: text(p.pk ?? p.id),
    username: text(p.username),
    name: text(p.full_name || p.username),
    avatar: https(p.profile_pic_url_hd ?? p.profile_pic_url),
    bio: text(p.biography),
    website: https(p.external_url),
    followers: p.follower_count ?? object(p.edge_followed_by).count,
    following: p.following_count ?? object(p.edge_follow).count,
    posts: p.media_count ?? object(p.edge_owner_to_timeline_media).count,
    isFollowing: p.followed_by_viewer ?? friendship.following,
    followsYou: p.follows_viewer ?? friendship.followed_by,
    verified: p.is_verified,
  });
}
export function instagramNews({
  data,
  account,
}: {
  data: Record<string, unknown>;
  account: Account;
}): SocialNotification[] {
  const categories = {
    user_followed: "follows",
    ig_profile_story_highlight: "posts",
    comment: "replies",
    post_like: "reactions",
    story_like: "reactions",
    comment_like: "reactions",
  } as const;
  return [
    ...list(data.priority_stories),
    ...list(data.new_stories),
    ...list(data.old_stories),
  ].flatMap((value) => {
    const n = object(value),
      a = object(n.args),
      event = text(n.notif_name),
      category = categories[event as keyof typeof categories];
    if (!category) return [];
    const raw = text(a.rich_text),
      actors = [...raw.matchAll(/\{([^|]+)\|[^|]*\|[^|]*\|user\?id=(\d+)[^}]*\}/g)]
        .slice(0, 2)
        .map((m) =>
          actorSchema.parse({
            network: "instagram",
            id: m[2],
            username: m[1],
            name: m[1],
            avatar:
              text(a.profile_id) === m[2]
                ? https(a.profile_image)
                : text(a.profile_id2) === m[2]
                  ? https(a.profile_image2)
                  : undefined,
          }),
        );
    if (!actors.length && a.profile_id)
      actors.push(
        actorSchema.parse({
          network: "instagram",
          id: text(a.profile_id),
          username: text(a.profile_name),
          name: text(a.profile_name),
          avatar: https(a.profile_image),
        }),
      );
    if (!actors.length) return [];
    const media = object(list(a.media)[0] ?? list(a.images)[0]),
      image = https(media.image),
      id = text(media.id || n.pk),
      storyId = text(a.destination).match(/(?:media_id|feed_item_id)=([^&]+)/)?.[1];
    const url =
      event === "story_like" && storyId
        ? `https://www.instagram.com/stories/${account.username}/${storyId.split("_")[0]}/`
        : `https://www.instagram.com/${account.username}/`;
    const clean = raw.replace(/\{([^|]+)[^}]*\}/g, "$1");
    return [
      notificationSchema.parse({
        id: `instagram:${account.id}:${n.pk}`,
        accountId: account.id,
        network: "instagram",
        category,
        event,
        timestamp: timestamp(a.timestamp),
        actors,
        text: clean || `${actors[0]!.name} ${event.replaceAll("_", " ")}`,
        url,
        post:
          image || clean.includes(":")
            ? {
                id,
                text: clean.includes(":") ? clean.slice(clean.lastIndexOf(":") + 1).trim() : "",
                url,
                images: image ? [image] : [],
                author: account,
              }
            : undefined,
      }),
    ];
  });
}
export function instagramMessages({
  data,
  account,
  preferences,
}: {
  data: Record<string, unknown>;
  account: Account;
  preferences: Preferences;
}) {
  return list(object(data.inbox).threads).flatMap((value) => {
    const thread = object(value),
      item = object(thread.last_permanent_item),
      viewer = text(thread.viewer_id || account.id),
      type = text(item.item_type);
    if (
      !item.item_id ||
      text(item.user_id) === viewer ||
      (!preferences.includeMediaShares && ["xma_clip", "xma_media_share"].includes(type))
    )
      return [];
    const at = numeric(item.timestamp ?? thread.last_activity_at) ?? 0,
      seen = numeric(object(object(thread.last_seen_at)[viewer]).timestamp) ?? 0;
    if (!thread.marked_as_unread && at <= seen) return [];
    const actors = list(thread.users)
      .map((user) => instagramProfile({ value: user }))
      .filter((user) => user.id !== viewer)
      .sort((a, b) => Number(b.id === text(item.user_id)) - Number(a.id === text(item.user_id)));
    if (!actors.length) return [];
    const xma = object(list(item[type])[0]),
      preview =
        text(
          item.text ||
            item.auxiliary_text ||
            xma.title_text ||
            xma.caption_body_text ||
            xma.subtitle_text,
        ) ||
        {
          xma_clip: "Sent a reel",
          xma_media_share: "Sent a post",
          xma_reel_mention: "Mentioned you in a story",
          xma_reel_share: "Replied to a story",
          voice_media: "Sent a voice message",
        }[type] ||
        "Sent a message";
    const url = `https://www.instagram.com/direct/t/${thread.thread_v2_id || thread.thread_id}/`,
      image = https(xma.preview_url);
    return [
      notificationSchema.parse({
        id: `instagram:${account.id}:direct:${thread.thread_id}:${item.item_id}`,
        network: "instagram",
        accountId: account.id,
        category: "messages",
        event: type,
        timestamp: at / 1000,
        text: `${actors[0]!.name} sent a message`,
        actors,
        url,
        post: {
          id: text(thread.thread_id),
          text: preview,
          url,
          images: image ? [image] : [],
          author: actors[0],
        },
      }),
    ];
  });
}
export function instagramTray({
  data,
  account,
}: {
  data: Record<string, unknown>;
  account: Account;
}) {
  const trayContainer = findObjects({ root: data, key: "tray" }).find(Array.isArray);
  if (!trayContainer) throw new Error("Missing Instagram tray");
  return list(trayContainer).flatMap((value) => {
    const reel = object(value),
      user = object(reel.user),
      friendship = object(user.friendship_status);
    if (reel.muted || friendship.muting || friendship.is_muting_reel) return [];
    const actor = instagramProfile({ value: user }),
      at = timestamp(reel.latest_reel_media);
    return [
      storyReelSchema.parse({
        id: `instagram:${account.id}:${reel.id}`,
        network: "instagram",
        accountId: account.id,
        actor,
        timestamp: at,
        slides: [],
        seen: (numeric(reel.seen) ?? 0) * 1000 >= at,
        thumbnail: actor.avatar,
        closeFriends: !!reel.has_besties_media,
      }),
    ];
  });
}
export function instagramSlides({ value, username }: { value: unknown; username: string }) {
  const reel = object(value);
  return list(reel.items).map((value) => {
    const item = object(value),
      image = object(list(object(item.image_versions2).candidates)[0]),
      video = object(list(item.video_versions)[0]);
    const music = object(
        list(item.story_music_stickers)[0] ?? object(item.music_metadata).music_info,
      ),
      asset = object(music.music_asset_info);
    return storySlideSchema.parse({
      id: text(item.pk || item.id).split("_")[0],
      ownerId: text(object(item.user).pk || object(reel.user).pk || reel.id),
      timestamp: timestamp(item.taken_at),
      text: text(object(item.caption).text),
      image: https(image.url),
      video: https(video.url),
      duration: numeric(item.video_duration) || undefined,
      liked: !!item.has_liked,
      url: `https://www.instagram.com/stories/${username}/${item.pk || text(item.id).split("_")[0]}/`,
      title: text(asset.title) || undefined,
      artist: text(asset.display_artist) || undefined,
      artwork: https(
        asset.cover_artwork_thumbnail_uri ||
          asset.cover_artwork_thumbnail_url ||
          asset.cover_artwork_uri ||
          asset.cover_artwork_url,
      ),
      linkTitles: Object.fromEntries(
        list(item.story_link_stickers).flatMap((v) => {
          const link = object(object(v).story_link);
          const url = https(link.url);
          return url ? [[url, text(link.link_title || link.display_url) || "Open link"]] : [];
        }),
      ),
      embedURL: (() => {
        const shared = object(list(item.story_feed_media)[0]);
        return shared.media_code
          ? `https://www.instagram.com/${shared.product_type === "clips" ? "reel" : "p"}/${shared.media_code}/`
          : undefined;
      })(),
      embedLabel:
        object(list(item.story_feed_media)[0]).product_type === "clips" ? "Open reel" : "Open post",
      audio: https(asset.progressive_download_url),
      mentions: [
        ...list(item.reel_mentions).flatMap((v) =>
          object(v).user ? [instagramProfile({ value: object(v).user })] : [],
        ),
        ...list(item.story_bloks_stickers).flatMap((v) => {
          const username = text(
            object(object(object(object(v).bloks_sticker).sticker_data).ig_mention).username,
          ).trim();
          return username ? [instagramProfile({ value: { pk: username, username } })] : [];
        }),
      ].filter(
        (actor, index, actors) =>
          actors.findIndex((candidate) => candidate.username === actor.username) === index,
      ),
      links: [
        ...list(item.story_feed_media).flatMap((v) => {
          const m = object(v);
          return m.media_code
            ? [
                `https://www.instagram.com/${m.product_type === "clips" ? "reel" : "p"}/${m.media_code}/`,
              ]
            : [];
        }),
        ...list(item.story_link_stickers).flatMap(
          (v) => https(object(object(v).story_link).url) ?? [],
        ),
      ],
    });
  });
}
export function instagramPost({ value }: { value: unknown }) {
  const p = object(value),
    actor = instagramProfile({ value: p.user });
  const media = list(p.carousel_media).length ? list(p.carousel_media) : [p];
  return postSchema.parse({
    id: text(p.pk || p.id),
    author: actor,
    text: text(object(p.caption).text),
    url: `https://www.instagram.com/p/${p.code}/`,
    timestamp: timestamp(p.taken_at),
    likes: p.like_count,
    media: media.map((value) => {
      const item = object(value);
      return {
        image: https(object(list(object(item.image_versions2).candidates)[0]).url),
        video: https(object(list(item.video_versions)[0]).url),
      };
    }),
    images: media.flatMap(
      (v) => https(object(list(object(object(v).image_versions2).candidates)[0]).url) ?? [],
    ),
  });
}
