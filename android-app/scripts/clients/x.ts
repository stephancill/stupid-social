import {
  connectX,
  xFeed,
  markXRead,
  xUnreadCount,
  xProfile,
  xPost,
  xSearch,
  xRelationship,
  xRequest,
} from "../../src/x/client";
import { credentialPresence } from "./runtime";
import { type Command, stringOption, integer, numericID, username } from "./arguments";

export const xCommands: Record<string, Command> = {
  bootstrap: {
    description: "Show selected credential presence without a request.",
    run: async (c) => credentialPresence({ value: c.session.current() }),
  },
  account: { description: "Resolve the signed-in account.", run: () => connectX() },
  notifications: {
    description: "Read notifications without advancing last-seen.",
    options: { count: stringOption },
    run: async (c) =>
      xFeed({
        account: await connectX(),
        count: integer({ context: c, name: "count", fallback: 40, max: 100 }),
      }),
  },
  "load-notifications": {
    description: "Read notifications and advance the server last-seen cursor.",
    options: { count: stringOption },
    run: async (c) => {
      const result = await xFeed({
        account: await connectX(),
        count: integer({ context: c, name: "count", fallback: 40, max: 100 }),
      });
      await markXRead({ cursor: result.cursor });
      return { ...result, markedSeen: true, unreadCount: await xUnreadCount() };
    },
  },
  "unread-count": {
    description: "Read the notification count without marking read.",
    run: async () => ({ unreadCount: await xUnreadCount() }),
  },
  "device-follow": {
    description: "Read the post-notification timeline.",
    run: () => xRequest({ path: "/i/api/2/notifications/device_follow.json" }),
  },
  profile: {
    description: "Read a profile.",
    arguments: ["username"],
    run: (c) => xProfile({ username: username(c.args[0]) }),
  },
  tweet: {
    description: "Read a tweet and its parent using the app's query.",
    arguments: ["tweet_id"],
    run: (c) => xPost({ id: numericID(c.args[0]) }),
  },
  "search-users": {
    description: "Search profiles.",
    arguments: ["query"],
    run: (c) => xSearch({ query: username(c.args[0]) }),
  },
  follow: {
    description: "Follow an account.",
    arguments: ["user_id"],
    run: async (c) => {
      await xRelationship({ userId: numericID(c.args[0]), follow: true });
      return { following: true };
    },
  },
  unfollow: {
    description: "Unfollow an account.",
    arguments: ["user_id"],
    run: async (c) => {
      await xRelationship({ userId: numericID(c.args[0]), follow: false });
      return { following: false };
    },
  },
  notify: {
    description: "Enable or disable post notifications.",
    arguments: ["user_id", "on|off"],
    run: async (c) => {
      if (!["on", "off"].includes(c.args[1]!)) throw new Error("Expected on or off.");
      await xRelationship({ userId: numericID(c.args[0]), notify: c.args[1] === "on" });
      return { notified: c.args[1] === "on" };
    },
  },
};
