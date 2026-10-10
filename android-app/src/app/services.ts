import { bridge } from "../bridge";
import { QueryClient } from "@tanstack/react-query";
import {
  type Account,
  type Actor,
  type Network,
  type Profile,
  type Post,
  type SourceResult,
  type SocialNotification,
  errorMessage,
  networks,
  socialError,
} from "./models";
import {
  credentials,
  generation,
  invalidateSession,
  loadAccounts,
  loadFeed,
  loadPreferences,
  migrateValidationCredentials,
  saveAccount,
  saveResult,
} from "./storage";
import { connectX, xFeed, markXRead, xSearch, xProfile, xPost } from "../x/client";
import {
  connectFarcaster,
  farcasterFeed,
  searchFarcaster,
  getFarcasterProfile,
  farcasterPost,
} from "../providers/farcaster";
import {
  connectBluesky,
  blueskyFeed,
  markBlueskyRead,
  blueskyProfile,
  blueskySearch,
  blueskyPost,
} from "../providers/bluesky";
import {
  connectInstagram,
  instagramFeed,
  instagramGetProfile,
  instagramSearch,
} from "../instagram/client";
import {
  connectGitHub,
  githubFeed,
  githubProfile,
  githubSearch,
  githubRepo,
} from "../github/client";
import { connectSpotify, spotifyFeed, spotifySearch, spotifyProfile } from "../providers/spotify";
export const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: false, staleTime: 60000 }, mutations: { retry: false } },
});
const connectors: Record<Network, () => Promise<Account>> = {
  x: connectX,
  farcaster: connectFarcaster,
  instagram: connectInstagram,
  bluesky: connectBluesky,
  github: connectGitHub,
  spotify: connectSpotify,
};
export async function connect({ network }: { network: Network }) {
  invalidateSession({ network });
  const version = generation({ network }),
    account = await connectors[network]();
  if (version !== generation({ network }))
    throw socialError({ message: "Sign-in was cancelled. Try again." });
  await saveAccount({ account });
  await queryClient.invalidateQueries({ queryKey: ["accounts"] });
  return account;
}
let initialization: Promise<Partial<Record<Network, string>>> | undefined;
export function initialize() {
  initialization ??= (async () => {
    await migrateValidationCredentials();
    const existing = await loadAccounts(),
      errors: Partial<Record<Network, string>> = {};
    await Promise.all(
      networks
        .filter((n) => !existing.some((a) => a.network === n))
        .map(async (network) => {
          if (!(await credentials({ network }))) return;
          try {
            await connect({ network });
          } catch (error) {
            errors[network] = errorMessage({ error });
          }
        }),
    );
    return errors;
  })();
  return initialization;
}
export type RefreshReport = Partial<Record<Network, string>>;
let refreshFlight: Promise<RefreshReport> | undefined;
export function refreshFeed() {
  refreshFlight ??= (async () => {
    const accounts = await loadAccounts(),
      report: RefreshReport = {};
    await Promise.all(
      accounts.map(async (account) => {
        const network = account.network,
          version = generation({ network }),
          seenAt = new Date().toISOString();
        try {
          let result: SourceResult, mark: (() => Promise<void>) | undefined;
          switch (network) {
            case "x": {
              const fetched = await xFeed({ account });
              result = fetched;
              mark = () => markXRead({ cursor: fetched.cursor });
              break;
            }
            case "farcaster":
              result = await farcasterFeed({ account });
              break;
            case "instagram":
              result = await instagramFeed({
                account,
                preferences: await loadPreferences({ network }),
              });
              break;
            case "bluesky":
              result = await blueskyFeed({ account });
              mark = () => markBlueskyRead({ seenAt });
              break;
            case "github":
              result = await githubFeed({ account });
              break;
            case "spotify":
              result = await spotifyFeed({ account });
              break;
          }
          if (generation({ network }) !== version) return;
          await saveResult({ account, ...result, expectedGeneration: version });
          await queryClient.invalidateQueries({ queryKey: ["feed"] });
          if (result.warning) report[network] = result.warning;
          if (mark && generation({ network }) === version) await mark();
        } catch (error) {
          if (generation({ network }) === version) report[network] = errorMessage({ error });
        }
      }),
    );
    await queryClient.invalidateQueries({ queryKey: ["accounts"] });
    if (__DEV__) {
      const feed = await loadFeed();
      await bridge.writeReport(
        JSON.stringify({
          kind: "android-app",
          updatedAt: Date.now(),
          accounts: accounts.map((a) => a.network),
          notifications: feed.notifications.length,
          stories: feed.stories.length,
          errors: report,
        }),
      );
    }
    return report;
  })().finally(() => {
    refreshFlight = undefined;
  });
  return refreshFlight;
}
export async function searchProfiles({ query, selected }: { query: string; selected?: Network }) {
  const accounts = await loadAccounts(),
    profiles: Profile[] = [],
    errors: RefreshReport = {};
  await Promise.all(
    accounts
      .filter((a) => !selected || a.network === selected)
      .map(async ({ network }) => {
        try {
          const result = await {
            x: () => xSearch({ query }),
            farcaster: () => searchFarcaster({ query }),
            instagram: () => instagramSearch({ query }),
            bluesky: () => blueskySearch({ query }),
            github: () => githubSearch({ query }),
            spotify: () => spotifySearch({ query }),
          }[network]();
          profiles.push(...result);
        } catch (error) {
          errors[network] = errorMessage({ error });
        }
      }),
  );
  return { profiles, errors };
}
export async function getProfile({ actor }: { actor: Actor }) {
  switch (actor.network) {
    case "x":
      return xProfile({ username: actor.username });
    case "farcaster":
      return getFarcasterProfile({ id: actor.id });
    case "instagram":
      return instagramGetProfile({ username: actor.username, id: actor.id });
    case "bluesky":
      return blueskyProfile({ id: actor.id });
    case "github":
      return githubProfile({ username: actor.username });
    case "spotify":
      return spotifyProfile({ username: actor.username });
  }
}
export function profileURL({ actor }: { actor: Actor }) {
  const name = encodeURIComponent(actor.username);
  return {
    x: `https://x.com/${name}`,
    farcaster: `https://farcaster.xyz/${name}`,
    instagram: `https://www.instagram.com/${name}/`,
    bluesky: `https://bsky.app/profile/${name}`,
    github: `https://github.com/${name}`,
    spotify: `https://open.spotify.com/user/${name}`,
  }[actor.network];
}
export async function notificationDetail({
  item,
}: {
  item: SocialNotification;
}): Promise<{ post?: Post; parentPost?: Post }> {
  if (!item.post) return { post: item.post, parentPost: item.parentPost };
  switch (item.network) {
    case "x": {
      const post = await xPost({ id: item.post.id });
      return { post, parentPost: post.parentId ? await xPost({ id: post.parentId }) : undefined };
    }
    case "farcaster":
      return { post: await farcasterPost({ id: item.post.id, authorId: item.post.author?.id }) };
    case "bluesky":
      return blueskyPost({ id: item.post.id });
    case "github":
      return { post: await githubRepo({ url: item.post.url }) };
    default:
      return { post: item.post, parentPost: item.parentPost };
  }
}
