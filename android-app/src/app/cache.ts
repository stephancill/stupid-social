import type { SocialNotification } from "./models";
export const retention = 86400000;
export type CachedNotification = { item: SocialNotification; cachedAt: number };
function notificationIdentity({ item }: { item: SocialNotification }) {
  const scope = [item.network, item.accountId];
  // X changes timeline IDs for the same follow between refreshes.
  if (item.network === "x" && item.category === "follows" && !item.post)
    return JSON.stringify([
      ...scope,
      "follow",
      item.timestamp,
      [...new Set(item.actors.map((actor) => actor.id))].sort(),
    ]);
  return JSON.stringify([...scope, "id", item.id]);
}
export function mergeRecent({
  existing,
  incoming,
  now = Date.now(),
}: {
  existing: CachedNotification[];
  incoming: SocialNotification[];
  now?: number;
}) {
  const bySourceId = new Map<string, CachedNotification>();
  const rows = [
    ...existing
      .filter((row) => now - row.cachedAt < retention)
      .sort((a, b) => a.cachedAt - b.cachedAt),
    ...incoming.map((item) => ({ item, cachedAt: now })),
  ];
  for (const row of rows) {
    const { item } = row,
      key = JSON.stringify([item.network, item.accountId, item.id]);
    bySourceId.delete(key);
    bySourceId.set(key, row);
  }
  const map = new Map<string, CachedNotification>();
  for (const row of bySourceId.values()) map.set(notificationIdentity({ item: row.item }), row);
  return [...map.values()].sort(
    (a, b) => b.item.timestamp - a.item.timestamp || a.item.id.localeCompare(b.item.id),
  );
}
