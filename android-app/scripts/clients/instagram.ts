import { z } from "zod";
import {
  connectInstagram,
  instagramGetProfile,
  instagramPosts,
  instagramSearch,
  instagramDirectInbox,
  instagramNewsInbox,
  instagramStoriesTray,
  instagramReel,
  instagramStorySeen,
  instagramFollow,
  instagramDelete,
  instagramPublish,
  mentionPlacementSchema,
} from "../../src/instagram/client";
import {
  igBootstrap,
  igDiscover,
  igGraph,
  igCustomGraph,
  igRequest,
  igPage,
} from "../../src/instagram/session";
import { instagramUsername } from "../../src/instagram/profile";
import { storySlideSchema } from "../../src/app/models";
import { inputText } from "./runtime";
import {
  type Command,
  type Context,
  stringOption,
  flagOption,
  option,
  optional,
  integer,
  numericID,
} from "./arguments";

const storyOptions = { "story-username": stringOption };
const mediaID = (value: unknown) => numericID(z.string().parse(value).split("_")[0]);
async function storyPage(c: Context) {
  const name = optional({ context: c, name: "story-username" });
  if (name) {
    await igBootstrap();
    await igPage({ path: `/stories/${encodeURIComponent(instagramUsername.parse(name))}/` });
  }
}
async function jsonArgument({ value }: { value: string }) {
  return JSON.parse(value.startsWith("@") ? await inputText({ path: value.slice(1) }) : value);
}
const mediaLike = ({ liked }: { liked: boolean }): Command => ({
  description: `${liked ? "Like" : "Unlike"} media through the shared Relay transport.`,
  arguments: ["media_id"],
  options: { "tracking-token": stringOption, "container-module": stringOption },
  run: (c) =>
    igGraph({
      operation: liked ? "like" : "unlike",
      root: liked ? "xig_media_like" : "xig_media_unlike",
      variables: {
        input: {
          media_id: mediaID(c.args[0]),
          ...(liked
            ? {
                container_module: option({
                  context: c,
                  name: "container-module",
                  fallback: "story_viewer",
                }),
              }
            : {}),
          ...(c.options["tracking-token"]
            ? { tracking_token: option({ context: c, name: "tracking-token" }) }
            : {}),
        },
      },
    }),
});
const storyLike = ({ liked }: { liked: boolean }): Command => ({
  description: `${liked ? "Like" : "Unlike"} a story through its story-specific Relay operation.`,
  arguments: ["media_id"],
  options: storyOptions,
  run: async (c) => {
    await storyPage(c);
    return igGraph({
      operation: liked ? "storyLike" : "storyUnlike",
      root: liked ? "xig_send_story_like" : "xig_unsend_story_like",
      variables: { input: { media_id: mediaID(c.args[0]) } },
    });
  },
});
const bootstrap: Command = {
  description: "Load the app's web session and report token presence only.",
  run: igBootstrap,
};
export const instagramCommands: Record<string, Command> = {
  bootstrap,
  refresh: bootstrap,
  docids: {
    description: "Discover current Relay document IDs from the app's page assets.",
    options: storyOptions,
    run: (c) => igDiscover({ storyUsername: optional({ context: c, name: "story-username" }) }),
  },
  activity: {
    description: "Read the activity Relay query.",
    run: () =>
      igGraph({
        operation: "activity",
        variables: { inbox_request_data: {}, pending_request_data: {} },
        read: true,
      }),
  },
  "stories-tray": {
    description: "Read the authenticated homepage's preloaded stories tray.",
    run: instagramStoriesTray,
  },
  "story-page": {
    description: "Read story slides from the preloaded page payload.",
    arguments: ["username"],
    run: (c) => instagramReel({ username: instagramUsername.parse(c.args[0]) }),
  },
  "current-user": {
    description: "Resolve the matching signed-in viewer from the authenticated homepage.",
    run: connectInstagram,
  },
  "news-inbox": {
    description: "Read activity; this also marks activity read on Instagram.",
    run: instagramNewsInbox,
  },
  "direct-inbox": {
    description: "Read Direct inbox without marking conversations seen.",
    run: instagramDirectInbox,
  },
  "profile-username": {
    description: "Read a profile using the app's current Relay query.",
    arguments: ["username"],
    run: (c) => instagramGetProfile({ username: instagramUsername.parse(c.args[0]) }),
  },
  "profile-web": {
    description: "Read a profile or its paginated posts using the app's current query.",
    arguments: ["username"],
    options: { posts: flagOption, cursor: stringOption },
    run: (c) =>
      c.options.posts
        ? instagramPosts({
            username: instagramUsername.parse(c.args[0]),
            cursor: optional({ context: c, name: "cursor" }),
          })
        : instagramGetProfile({ username: instagramUsername.parse(c.args[0]) }),
  },
  "profile-diagnosis": {
    description: "Compare inbox, retired REST profile, and profile-page status once each.",
    arguments: ["username"],
    run: async (c) => {
      const name = instagramUsername.parse(c.args[0]);
      await igBootstrap();
      const checks = [];
      for (const [label, path, page] of [
        ["authenticated-inbox", "/api/v1/direct_v2/inbox/?limit=1&thread_message_limit=1", false],
        [
          "web-profile-info",
          `/api/v1/users/web_profile_info/?username=${encodeURIComponent(name)}`,
          false,
        ],
        ["profile-page", `/${encodeURIComponent(name)}/`, true],
      ] as const) {
        const start = c.session.requests.length;
        try {
          const response = await igRequest({ path, page });
          checks.push({
            request: label,
            ...c.session.requests.at(-1),
            bodyLength: (await response.text()).length,
          });
        } catch {
          checks.push({
            request: label,
            ...(c.session.requests.length > start ? c.session.requests.at(-1) : { failed: true }),
          });
        }
      }
      return { checks, automaticRetries: 0 };
    },
  },
  "search-users": {
    description: "Search profiles using the app's client.",
    arguments: ["query"],
    run: (c) => instagramSearch({ query: c.args[0]! }),
  },
  "mention-search": {
    description: "Search users for story mentions.",
    arguments: ["query"],
    run: (c) => instagramSearch({ query: c.args[0]! }),
  },
  "story-seen": {
    description: "Mark one story seen using the app's mutation.",
    options: {
      ...storyOptions,
      "reel-id": stringOption,
      "media-id": stringOption,
      "owner-id": stringOption,
      "taken-at": stringOption,
      "seen-at": stringOption,
    },
    run: async (c) => {
      const slide = storySlideSchema.parse({
        id: mediaID(option({ context: c, name: "media-id" })),
        ownerId: numericID(option({ context: c, name: "owner-id" })),
        timestamp: integer({ context: c, name: "taken-at" }) * 1000,
      });
      const reelId = numericID(option({ context: c, name: "reel-id" }));
      await storyPage(c);
      return instagramStorySeen({
        slide,
        reelId,
        seenAt: integer({ context: c, name: "seen-at", fallback: Math.floor(Date.now() / 1000) }),
      });
    },
  },
  "force-story-seen": {
    description: "Mark a reel owner seen.",
    arguments: ["story_owner_id"],
    options: storyOptions,
    run: async (c) => {
      const id = numericID(c.args[0]);
      await storyPage(c);
      return igGraph({ operation: "forceSeen", variables: { storyOwnerId: id } });
    },
  },
  "like-media": mediaLike({ liked: true }),
  "unlike-media": mediaLike({ liked: false }),
  "like-story": storyLike({ liked: true }),
  "unlike-story": storyLike({ liked: false }),
  follow: {
    description: "Follow an account.",
    arguments: ["user_id"],
    run: (c) => instagramFollow({ id: numericID(c.args[0]), following: true }),
  },
  unfollow: {
    description: "Unfollow an account.",
    arguments: ["user_id"],
    run: (c) => instagramFollow({ id: numericID(c.args[0]), following: false }),
  },
  "upload-story-image": {
    description: "Publish a JPEG story with optional caption and mention placements.",
    options: {
      image: stringOption,
      width: stringOption,
      height: stringOption,
      caption: stringOption,
      mention: { type: "string", multiple: true },
      "mention-user-id": { type: "string", multiple: true },
      "mention-x": stringOption,
      "mention-y": stringOption,
      "mention-width": stringOption,
      "mention-height": stringOption,
      "mention-rotation": stringOption,
      "reel-mentions-json": stringOption,
    },
    run: async (c) => {
      const uri = option({ context: c, name: "image" }),
        width = integer({ context: c, name: "width" }),
        height = integer({ context: c, name: "height" });
      const geometry = {
        x: Number(c.options["mention-x"] ?? 0.5),
        y: Number(c.options["mention-y"] ?? 0.5),
        width: Number(c.options["mention-width"] ?? 0.5),
        height: Number(c.options["mention-height"] ?? 0.12),
        rotation: Number(c.options["mention-rotation"] ?? 0),
      };
      const raw = optional({ context: c, name: "reel-mentions-json" });
      const names = z.array(z.string()).parse(c.options.mention ?? []),
        ids = z.array(z.string()).parse(c.options["mention-user-id"] ?? []);
      if (raw && (names.length || ids.length))
        throw new Error("Choose --reel-mentions-json or individual mention options.");
      const mentions = raw
        ? z
            .array(mentionPlacementSchema.extend({ username: z.string().default("") }))
            .parse(await jsonArgument({ value: raw }))
        : [];
      // Validate placements before resolving usernames or uploading any image bytes.
      mentionPlacementSchema.parse({ ...geometry, user_id: "0", username: "" });
      for (const value of ids)
        mentions.push(
          mentionPlacementSchema.parse({ ...geometry, user_id: numericID(value), username: "" }),
        );
      for (const name of names) {
        const profile = await instagramGetProfile({ username: instagramUsername.parse(name) });
        mentions.push(
          mentionPlacementSchema.parse({
            ...geometry,
            user_id: profile.id,
            username: profile.username,
          }),
        );
      }
      return instagramPublish({
        uri,
        width,
        height,
        caption: z.string().parse(c.options.caption ?? ""),
        mentions,
      });
    },
  },
  "delete-story": {
    description: "Delete a story.",
    arguments: ["media_id"],
    options: storyOptions,
    run: async (c) => {
      const slide = storySlideSchema.parse({ id: mediaID(c.args[0]), timestamp: 0 });
      await storyPage(c);
      return instagramDelete({ slide });
    },
  },
  graphql: {
    description: "Run a specific document through the shared Instagram GraphQL transport.",
    arguments: ["doc_id", "variables"],
    options: { post: flagOption },
    run: async (c) =>
      igCustomGraph({
        docId: numericID(c.args[0]),
        variables: z
          .record(z.string(), z.unknown())
          .parse(await jsonArgument({ value: c.args[1]! })),
        read: !c.options.post,
      }),
  },
};
