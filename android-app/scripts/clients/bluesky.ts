import { z } from "zod";
import { blueskyRequest, markBlueskyRead } from "../../src/providers/bluesky";
import { object, list } from "../../src/app/value";
import { type Command, type Context, stringOption, integer, optional } from "./arguments";

const notifications = (c: Context) =>
  blueskyRequest({
    method: "app.bsky.notification.listNotifications",
    params: { limit: String(integer({ context: c, name: "limit", fallback: 50, max: 100 })) },
  });
export const blueskyCommands: Record<string, Command> = {
  notifications: {
    description: "Read notifications without marking seen.",
    options: { limit: stringOption },
    run: notifications,
  },
  "load-notifications": {
    description: "Read notifications and mark seen.",
    options: { limit: stringOption },
    run: async (c) => {
      const seenAt = new Date().toISOString(),
        result = await notifications(c);
      await markBlueskyRead({ seenAt });
      return { ...result, markedSeen: true };
    },
  },
  profile: {
    description: "Read an actor profile, defaulting to the signed-in DID.",
    options: { actor: stringOption },
    run: (c) =>
      blueskyRequest({
        method: "app.bsky.actor.getProfile",
        params: {
          actor: z
            .string()
            .min(1)
            .parse(c.options.actor ?? c.session.current()?.did),
        },
      }),
  },
  "post-thread": {
    description: "Read a thread specified by --uri or the first post notification.",
    options: { uri: stringOption, limit: stringOption },
    run: async (c) => {
      let uri = optional({ context: c, name: "uri" });
      if (!uri) {
        const data = await notifications(c);
        uri = list(data.notifications)
          .map((value) => {
            const n = object(value);
            return (
              n.reasonSubject ||
              (object(n.record)["$type"] === "app.bsky.feed.post" ? n.uri : undefined)
            );
          })
          .find((value) => typeof value === "string") as string | undefined;
      }
      if (!uri) throw new Error("No post notification is available. Supply --uri.");
      return blueskyRequest({
        method: "app.bsky.feed.getPostThread",
        params: { uri: z.string().startsWith("at://").parse(uri), depth: "0" },
      });
    },
  },
};
