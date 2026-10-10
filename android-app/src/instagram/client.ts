import { z } from "zod";
import {
  accountSchema,
  errorMessage,
  socialError,
  type Account,
  type Preferences,
  type Profile,
  type SourceResult,
  type StorySlide,
} from "../app/models";
import { credentials, readFile } from "../clientRuntime";
import { object, list, findObjects } from "../app/value";
import {
  igPage,
  igGraph,
  igJSON,
  igRequest,
  igProfileGraph,
  igBootstrap,
  igHomepage,
  jazoest,
} from "./session";
import { instagramProfilePosts } from "./profile";
import { instagramHomepageViewer, instagramHomepageTray } from "./homepage";
import {
  instagramProfile,
  instagramNews,
  instagramMessages,
  instagramTray,
  instagramSlides,
  instagramPost,
} from "./parsers";
const inbox =
  "/api/v1/direct_v2/inbox/?visual_message_return_type=unseen&thread_message_limit=10&persistentBadging=true&limit=20";
export async function connectInstagram(): Promise<Account> {
  const c = await credentials({ network: "instagram" });
  const html = await igHomepage();
  const viewer = instagramProfile({
    value: instagramHomepageViewer({ html, accountID: c!.dsUserId! }),
  });
  return accountSchema.parse({ ...viewer, connectedAt: Date.now() });
}
export const instagramDirectInbox = () => igJSON({ path: inbox });
export async function instagramNewsInbox() {
  const c = await credentials({ network: "instagram" });
  return igJSON({
    path: "/api/v1/news/inbox/",
    form: { selected_filters: "", max_id: "", jazoest: jazoest({ csrf: c!.csrfToken! }) },
  });
}
export async function instagramStoriesTray() {
  const c = await credentials({ network: "instagram" });
  const html = await igHomepage();
  return {
    data: {
      xdt_api__v1__feed__reels_tray: instagramHomepageTray({ html, accountID: c!.dsUserId! }),
    },
  };
}
export async function instagramGetProfile({
  username,
  id,
}: {
  username: string;
  id?: string;
}): Promise<Profile> {
  const data = await igProfileGraph({ username, id });
  return instagramProfile({ value: object(data.data).user });
}
export async function instagramSearch({ query }: { query: string }) {
  const data = await igJSON({
    path: `/web/search/topsearch/?context=blended&query=${encodeURIComponent(query)}&rank_token=0.0&include_reel=false`,
  });
  return list(data.users).map((v) => instagramProfile({ value: object(v).user }));
}
export async function instagramPosts({ username, cursor }: { username: string; cursor?: string }) {
  const data = instagramProfilePosts({
    data: await igProfileGraph({ username, cursor, posts: true }),
  });
  return {
    posts: list(data.items).map((value) => instagramPost({ value })),
    nextCursor: data.nextCursor,
  };
}
export async function instagramFeed({
  account,
  preferences,
}: {
  account: Account;
  preferences: Preferences;
}): Promise<SourceResult> {
  const results = await Promise.allSettled([
    instagramNewsInbox(),
    preferences.categories.includes("messages") ? instagramDirectInbox() : Promise.resolve({}),
    instagramStoriesTray(),
  ]);
  const [news, dm, tray] = results;
  if (results.every((r) => r.status === "rejected")) throw (news as PromiseRejectedResult).reason;
  const notifications = [
    ...(news!.status === "fulfilled" ? instagramNews({ data: news!.value, account }) : []),
    ...(dm!.status === "fulfilled"
      ? instagramMessages({ data: dm!.value, account, preferences })
      : []),
  ];
  return {
    notifications,
    preserveStories: tray!.status === "rejected",
    replaceMessages: dm!.status === "fulfilled",
    stories: tray!.status === "fulfilled" ? instagramTray({ data: tray!.value, account }) : [],
    warning:
      results
        .flatMap((r, i) =>
          r.status === "rejected"
            ? `${["Activity", "Messages", "Stories"][i]}: ${errorMessage({ error: r.reason })}`
            : [],
        )
        .join("\n") || undefined,
  };
}
export async function instagramReel({ username }: { username: string }) {
  const html = await igPage({ path: `/stories/${encodeURIComponent(username)}/` });
  for (const match of html.matchAll(/<script\b[^>]*\bdata-sjs[^>]*>(.*?)<\/script>/gs)) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(match[1]!);
    } catch {
      continue;
    }
    const payload = findObjects({ root: parsed, key: "xdt_api__v1__feed__reels_media" })[0];
    if (payload) return instagramSlides({ value: list(object(payload).reels_media)[0], username });
  }
  throw socialError({ message: "This story is unavailable or has expired." });
}
export async function instagramStorySeen({
  slide,
  reelId = slide.ownerId,
  seenAt = Math.floor(Date.now() / 1000),
}: {
  slide: StorySlide;
  reelId?: string;
  seenAt?: number;
}) {
  return igGraph({
    operation: "seen",
    variables: {
      reelId,
      reelMediaId: slide.id.split("_")[0],
      reelMediaOwnerId: slide.ownerId,
      reelMediaTakenAt: Math.floor(slide.timestamp / 1000),
      viewSeenAt: seenAt,
    },
  });
}
export async function instagramStoryLike({ slide, liked }: { slide: StorySlide; liked: boolean }) {
  await igGraph({
    operation: liked ? "like" : "unlike",
    root: liked ? "xig_media_like" : "xig_media_unlike",
    variables: {
      input: { media_id: slide.id, ...(liked ? { container_module: "story_viewer" } : {}) },
    },
  });
}
export async function instagramFollow({ id, following }: { id: string; following: boolean }) {
  return igGraph({
    operation: following ? "follow" : "unfollow",
    root: following ? "xdt_create_friendship" : "xdt_destroy_friendship",
    variables: {
      target_user_id: id,
      ...(following ? { data: { include_follow_friction_check: true } } : {}),
    },
  });
}
export async function instagramDelete({ slide }: { slide: StorySlide }) {
  return igGraph({
    operation: "delete",
    root: "xdt_api__v1__create__delete",
    variables: { mediaId: slide.id.split("_")[0] },
  });
}
export const mentionPlacementSchema = z.object({
  user_id: z.string(),
  username: z.string(),
  x: z.number().min(0).max(1),
  y: z.number().min(0).max(1),
  width: z.number().positive(),
  height: z.number().positive(),
  rotation: z.number().default(0),
  z: z.number().default(0),
});
export type MentionPlacement = z.infer<typeof mentionPlacementSchema>;
export async function instagramPublish({
  uri,
  mentions,
  width = 1080,
  height = 1920,
  caption = "",
}: {
  uri: string;
  mentions: MentionPlacement[];
  width?: number;
  height?: number;
  caption?: string;
}) {
  z.number().int().positive().parse(width);
  z.number().int().positive().parse(height);
  await igBootstrap();
  const placements = z.array(mentionPlacementSchema).parse(mentions),
    c = await credentials({ network: "instagram" });
  if (!c) throw socialError({ message: "Connect Instagram in Settings." });
  const bytes = await readFile({ uri }),
    uploadId = String(Date.now()),
    name = `fb_uploader_${uploadId}`;
  const upload = await igRequest({
    path: `https://i.instagram.com/rupload_igphoto/${name}`,
    method: "POST",
    body: bytes,
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Entity-Length": String(bytes.byteLength),
      "X-Entity-Name": name,
      "X-Entity-Type": "image/jpeg",
      Offset: "0",
      "X-Instagram-Rupload-Params": JSON.stringify({
        media_type: 1,
        upload_id: uploadId,
        upload_media_height: height,
        upload_media_width: width,
      }),
    },
  });
  if (!upload.ok)
    throw socialError({ message: `Instagram photo upload failed (${upload.status}).` });
  const data = await igJSON({
    path: "/api/v1/media/configure_to_story/",
    form: {
      caption,
      configure_mode: "1",
      share_to_facebook: "",
      share_to_fb_destination_id: "",
      share_to_fb_destination_type: "USER",
      upload_id: uploadId,
      jazoest: jazoest({ csrf: c.csrfToken! }),
      ...(placements.length
        ? { include_e2ee_mentioned_user_list: "1", reel_mentions: JSON.stringify(placements) }
        : {}),
    },
  });
  if (data.status !== "ok")
    throw socialError({
      message: "Instagram did not confirm this story. Check your account before trying again.",
    });
  return data;
}
