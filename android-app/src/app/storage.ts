import { mergeRecent, retention, type CachedNotification } from "./cache";
import * as SecureStore from "expo-secure-store";
import * as SQLite from "expo-sqlite";
import { z } from "zod";
import {
  accountSchema,
  defaultPreferences,
  networkSchema,
  networks,
  notificationSchema,
  preferencesSchema,
  storyReelSchema,
  type Account,
  type Network,
  type Preferences,
  type SocialNotification,
  type StoryReel,
} from "./models";

export const credentialsSchema = z.record(z.string(), z.string());
export type Credentials = z.infer<typeof credentialsSchema>;
const generations: Partial<Record<Network, number>> = {};
export function generation({ network }: { network: Network }) {
  return generations[network] ?? 0;
}
export function invalidateSession({ network }: { network: Network }) {
  generations[network] = generation({ network }) + 1;
}
export async function credentials({ network }: { network: Network }) {
  const value = await SecureStore.getItemAsync(`social.credentials.${network}`);
  return value ? credentialsSchema.parse(JSON.parse(value)) : null;
}
const secretWrites: Partial<Record<Network, Promise<void>>> = {};
function writeSecret({ network, run }: { network: Network; run: () => Promise<void> }) {
  const next = (secretWrites[network] ?? Promise.resolve()).then(run);
  secretWrites[network] = next.catch(() => undefined);
  return next;
}
export async function saveCredentials({
  network,
  value,
  expectedGeneration,
}: {
  network: Network;
  value: Credentials | null;
  expectedGeneration?: number;
}) {
  const payload = value === null ? null : JSON.stringify(credentialsSchema.parse(value));
  await writeSecret({
    network,
    run: async () => {
      if (expectedGeneration !== undefined && generation({ network }) !== expectedGeneration)
        return;
      if (payload === null) await SecureStore.deleteItemAsync(`social.credentials.${network}`);
      else await SecureStore.setItemAsync(`social.credentials.${network}`, payload);
    },
  });
}
let database: Promise<SQLite.SQLiteDatabase> | undefined;
function db() {
  database ??= (async () => {
    const connection = await SQLite.openDatabaseAsync("stupid-social.db");
    await connection.execAsync(`PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS accounts (network TEXT PRIMARY KEY, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS preferences (network TEXT PRIMARY KEY, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS cache (id TEXT NOT NULL, network TEXT NOT NULL, account_id TEXT NOT NULL, kind TEXT NOT NULL, cached_at INTEGER NOT NULL, timestamp INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(network, account_id, kind, id));
      CREATE TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY, timestamp INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS status (network TEXT PRIMARY KEY, refreshed_at INTEGER);`);
    return connection;
  })();
  return database;
}
let writes = Promise.resolve();
function write({ run }: { run: (connection: SQLite.SQLiteDatabase) => Promise<void> }) {
  const pending = writes.then(async () => run(await db()));
  writes = pending.catch(() => undefined);
  return pending;
}
export async function loadAccounts(): Promise<Account[]> {
  const rows = await (await db()).getAllAsync<{ payload: string }>("SELECT payload FROM accounts");
  return rows.map((r) => accountSchema.parse(JSON.parse(r.payload)));
}
export async function saveAccount({ account }: { account: Account }) {
  await write({
    run: async (connection) => {
      const existing = await connection.getFirstAsync<{ payload: string }>(
        "SELECT payload FROM accounts WHERE network = ?",
        account.network,
      );
      if (existing && accountSchema.parse(JSON.parse(existing.payload)).id !== account.id) {
        await connection.runAsync("DELETE FROM cache WHERE network = ?", account.network);
      }
      await connection.runAsync(
        "INSERT OR REPLACE INTO accounts VALUES (?, ?)",
        account.network,
        JSON.stringify(accountSchema.parse(account)),
      );
    },
  });
}
export async function removeAccount({ network }: { network: Network }) {
  invalidateSession({ network });
  await writeSecret({
    network,
    run: async () => {
      await SecureStore.deleteItemAsync(`social.credentials.${network}`);
      await SecureStore.deleteItemAsync(`validation.${network}`);
    },
  });
  await write({
    run: async (connection) => {
      await connection.withExclusiveTransactionAsync(async (tx) => {
        await tx.runAsync("DELETE FROM accounts WHERE network = ?", network);
        await tx.runAsync("DELETE FROM cache WHERE network = ?", network);
        await tx.runAsync("DELETE FROM status WHERE network = ?", network);
        await tx.runAsync("DELETE FROM seen WHERE id LIKE ?", `${network}:%`);
      });
    },
  });
}
export async function loadPreferences({ network }: { network: Network }): Promise<Preferences> {
  const row = await (
    await db()
  ).getFirstAsync<{ payload: string }>(
    "SELECT payload FROM preferences WHERE network = ?",
    network,
  );
  return row ? preferencesSchema.parse(JSON.parse(row.payload)) : defaultPreferences;
}
export async function savePreferences({
  network,
  value,
}: {
  network: Network;
  value: Preferences;
}) {
  await write({
    run: async (connection) => {
      await connection.runAsync(
        "INSERT OR REPLACE INTO preferences VALUES (?, ?)",
        network,
        JSON.stringify(preferencesSchema.parse(value)),
      );
    },
  });
}
export async function saveResult({
  account,
  notifications,
  stories,
  preserveStories = false,
  replaceMessages = false,
  expectedGeneration,
}: {
  account: Account;
  notifications: SocialNotification[];
  stories: StoryReel[];
  expectedGeneration: number;
  preserveStories?: boolean;
  replaceMessages?: boolean;
}) {
  await write({
    run: async (connection) => {
      if (generation({ network: account.network }) !== expectedGeneration) return;
      const active = await connection.getFirstAsync<{ payload: string }>(
        "SELECT payload FROM accounts WHERE network = ?",
        account.network,
      );
      if (!active || accountSchema.parse(JSON.parse(active.payload)).id !== account.id) return;
      const now = Date.now();
      await connection.withExclusiveTransactionAsync(async (tx) => {
        await tx.runAsync("DELETE FROM cache WHERE cached_at < ?", now - retention);
        if (!preserveStories)
          await tx.runAsync(
            "DELETE FROM cache WHERE network = ? AND account_id = ? AND kind = 'story'",
            account.network,
            account.id,
          );
        if (replaceMessages)
          await tx.runAsync(
            "DELETE FROM cache WHERE network = ? AND account_id = ? AND json_extract(payload, '$.category') = 'messages'",
            account.network,
            account.id,
          );
        const existing = await tx.getAllAsync<{ payload: string; cached_at: number }>(
          "SELECT payload, cached_at FROM cache WHERE network = ? AND account_id = ? AND kind = 'notification'",
          account.network,
          account.id,
        );
        const merged = mergeRecent({
          existing: existing.map((row) => ({
            item: notificationSchema.parse(JSON.parse(row.payload)),
            cachedAt: row.cached_at,
          })),
          incoming: notifications,
          now,
        });
        await tx.runAsync(
          "DELETE FROM cache WHERE network = ? AND account_id = ? AND kind = 'notification'",
          account.network,
          account.id,
        );
        for (const { item, cachedAt } of merged) {
          await tx.runAsync(
            "INSERT OR REPLACE INTO cache VALUES (?, ?, ?, ?, ?, ?, ?)",
            item.id,
            account.network,
            account.id,
            "notification",
            cachedAt,
            item.timestamp,
            JSON.stringify(item),
          );
        }
        for (const item of stories) {
          await tx.runAsync(
            "INSERT OR REPLACE INTO cache VALUES (?, ?, ?, ?, ?, ?, ?)",
            item.id,
            account.network,
            account.id,
            "story",
            now,
            item.timestamp,
            JSON.stringify(item),
          );
        }
        await tx.runAsync("INSERT OR REPLACE INTO status VALUES (?, ?)", account.network, now);
      });
    },
  });
}
export async function loadFeed() {
  await writes;
  const rows = await (
    await db()
  ).getAllAsync<{ kind: string; payload: string; cached_at: number }>(
    "SELECT cache.kind, cache.payload, cache.cached_at FROM cache JOIN accounts ON accounts.network = cache.network AND json_extract(accounts.payload, '$.id') = cache.account_id WHERE cached_at >= ? ORDER BY timestamp DESC",
    Date.now() - retention,
  );
  const preferences = Object.fromEntries(
    await Promise.all(
      networks.map(async (network) => [network, await loadPreferences({ network })]),
    ),
  );
  const notifications: CachedNotification[] = [],
    stories: StoryReel[] = [];
  for (const row of rows) {
    if (row.kind === "notification") {
      const item = notificationSchema.parse(JSON.parse(row.payload));
      if (preferences[item.network]?.categories.includes(item.category))
        notifications.push({ item, cachedAt: row.cached_at });
    } else {
      const reel = storyReelSchema.parse(JSON.parse(row.payload));
      if (reel.network === "instagram" && !preferences.instagram?.storiesEnabled) continue;
      const seen = await (
        await db()
      ).getFirstAsync<{ timestamp: number }>("SELECT timestamp FROM seen WHERE id = ?", reel.id);
      stories.push({ ...reel, seen: reel.seen || !!(seen && seen.timestamp >= reel.timestamp) });
    }
  }
  return {
    notifications: mergeRecent({ existing: notifications, incoming: [] }).map((row) => row.item),
    stories,
  };
}
export async function markSeen({ reel }: { reel: StoryReel }) {
  await write({
    run: async (connection) => {
      await connection.runAsync(
        "INSERT OR REPLACE INTO seen VALUES (?, ?)",
        reel.id,
        reel.timestamp,
      );
    },
  });
}
export async function clearCache() {
  await write({
    run: async (connection) => {
      await connection.runAsync("DELETE FROM cache");
    },
  });
}
export async function loadRefreshTimes() {
  const rows = await (
    await db()
  ).getAllAsync<{ network: string; refreshed_at: number }>("SELECT * FROM status");
  return Object.fromEntries(rows.map((r) => [networkSchema.parse(r.network), r.refreshed_at]));
}
export async function migrateValidationCredentials() {
  const pending: Network[] = [];
  for (const network of networks) {
    if (await credentials({ network })) continue;
    const old = await SecureStore.getItemAsync(`validation.${network}`);
    if (!old) continue;
    await saveCredentials({ network, value: credentialsSchema.parse(JSON.parse(old)) });
    await SecureStore.deleteItemAsync(`validation.${network}`);
    pending.push(network);
  }
  return pending;
}
