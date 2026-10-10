import { z } from "zod";
import { accountSchema, socialError, type Account, type SourceResult } from "../app/models";
import { request, json } from "../app/http";
import { credentials } from "../clientRuntime";
import { farcasterProfile, castPost, parseFarcasterNotifications } from "./farcaster-parser";
const base = "https://haatz.quilibrium.com/v2/farcaster";
async function api({
  path,
  params,
  signal,
}: {
  path: string;
  params: Record<string, string>;
  signal?: AbortSignal;
}) {
  return json({
    response: await request({
      url: `${base}${path}?${new URLSearchParams(params)}`,
      signal,
      network: "farcaster",
    }),
    network: "farcaster",
  });
}
export async function connectFarcaster(): Promise<Account> {
  const c = await credentials({ network: "farcaster" });
  if (!c?.username) throw socialError({ message: "Enter your Farcaster username." });
  const profile = farcasterProfile({
    raw: (
      await api({ path: "/user/by-username", params: { username: c.username.replace(/^@/, "") } })
    ).user,
  });
  return accountSchema.parse({ ...profile, connectedAt: Date.now() });
}
export async function getFarcasterProfile({ id, signal }: { id: string; signal?: AbortSignal }) {
  return farcasterProfile({
    raw: (await api({ path: "/user", params: { fid: id }, signal })).user,
  });
}
export async function searchFarcaster({ query, signal }: { query: string; signal?: AbortSignal }) {
  const data = await api({ path: "/user/search", params: { q: query, limit: "20" }, signal });
  return z
    .array(z.unknown())
    .parse(data.users)
    .map((raw) => farcasterProfile({ raw }));
}
export async function farcasterPost({
  id,
  authorId,
  signal,
}: {
  id: string;
  authorId?: string;
  signal?: AbortSignal;
}) {
  const data = await api({
    path: "/cast",
    params: { identifier: id, type: "hash", ...(authorId ? { fid: authorId } : {}) },
    signal,
  });
  const post = castPost(data.cast);
  if (!post) throw socialError({ message: "This cast is unavailable." });
  return post;
}
export async function farcasterFeed({
  account,
  signal,
}: {
  account: Account;
  signal?: AbortSignal;
}): Promise<SourceResult> {
  const data = await api({
    path: "/notifications",
    params: { fid: account.id, limit: "50" },
    signal,
  });
  return parseFarcasterNotifications({ data, account });
}
