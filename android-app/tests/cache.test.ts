import { describe, expect, test } from "bun:test";
import { mergeRecent, retention } from "../src/app/cache";
import { notificationSchema, type SocialNotification } from "../src/app/models";

const now = 1800000000000;
function follow(overrides: Partial<SocialNotification> = {}) {
  return notificationSchema.parse({
    id: "x:viewer:timeline-old:users_followed_you",
    network: "x",
    accountId: "viewer",
    category: "follows",
    event: "users_followed_you",
    timestamp: now - 3600000,
    text: "Alice followed you",
    actors: [{ network: "x", id: "alice", username: "alice", name: "Alice" }],
    ...overrides,
  });
}

describe("notification cache identity", () => {
  test("collapses saved X follows with changed timeline IDs before a refresh", () => {
    const recent = follow({ id: "new-timeline-id", text: "Updated display name followed you" });
    const result = mergeRecent({
      now,
      existing: [
        { item: recent, cachedAt: now - 10 },
        { item: follow(), cachedAt: now - 1000 },
      ],
      incoming: [],
    });
    expect(result).toEqual([{ item: recent, cachedAt: now - 10 }]);
  });

  test("refresh replaces the same follow even if X changes its presentation event", () => {
    const incoming = follow({ id: "new-timeline-id", event: "follow_from_recommended_user" });
    expect(
      mergeRecent({
        now,
        existing: [{ item: follow(), cachedAt: now - 1000 }],
        incoming: [incoming, incoming],
      }),
    ).toEqual([{ item: incoming, cachedAt: now }]);
  });

  test("actor ordering does not create another copy of the same follow group", () => {
    const first = follow();
    const actors = [...first.actors, { ...first.actors[0]!, id: "bob", username: "bob" }];
    const incoming = follow({ id: "new-group", actors: [...actors].reverse() });
    expect(
      mergeRecent({
        now,
        existing: [{ item: follow({ actors }), cachedAt: now - 1000 }],
        incoming: [incoming],
      }).map((row) => row.item),
    ).toEqual([incoming]);
  });

  test("keeps different follow times, people, accounts, and networks", () => {
    const first = follow();
    const incoming = [
      first,
      follow({ id: "later-follow", timestamp: first.timestamp + 1000 }),
      follow({ id: "other-person", actors: [{ ...first.actors[0]!, id: "bob" }] }),
      follow({ accountId: "other-viewer" }),
      follow({ network: "instagram" }),
    ];
    expect(mergeRecent({ now, existing: [], incoming })).toHaveLength(incoming.length);
  });

  test("the original provider ID still updates a changed event timestamp", () => {
    const incoming = follow({ timestamp: now });
    expect(
      mergeRecent({
        now,
        existing: [{ item: follow(), cachedAt: now - 1000 }],
        incoming: [incoming],
      }),
    ).toEqual([{ item: incoming, cachedAt: now }]);
  });

  test("similar-looking non-follow events remain distinct", () => {
    const incoming = [
      follow({ id: "like", category: "reactions", event: "users_liked_your_tweet" }),
      follow({ id: "repost", category: "reactions", event: "users_retweeted_your_tweet" }),
      follow({ id: "reply-one", category: "replies", event: "user_replied_to_your_tweet" }),
      follow({ id: "reply-two", category: "replies", event: "user_replied_to_your_tweet" }),
    ];
    expect(mergeRecent({ now, existing: [], incoming })).toHaveLength(4);
  });

  test("deduplication does not extend retention of events absent from a refresh", () => {
    const item = follow();
    const saved = mergeRecent({
      now,
      existing: [
        { item, cachedAt: now - retention + 1 },
        { item: follow({ id: "expired-alias" }), cachedAt: now - retention },
      ],
      incoming: [],
    });
    expect(saved).toEqual([{ item, cachedAt: now - retention + 1 }]);
    expect(mergeRecent({ now: now + 1, existing: saved, incoming: [] })).toEqual([]);
  });
});
