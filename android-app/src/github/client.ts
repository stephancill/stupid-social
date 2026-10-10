import { request, selectedResponseCookies } from "../app/http";
import { credentials, saveCredentials, generation, randomUUID } from "../clientRuntime";
import { socialError, type Account } from "../app/models";
import { githubIdentity, githubPublicProfile, githubCard, parseGitHubFeed } from "./parser";
export async function githubPage({
  path,
  authenticated = false,
  feed = false,
  etag,
}: {
  path: string;
  authenticated?: boolean;
  feed?: boolean;
  etag?: string;
}) {
  const c = authenticated ? await credentials({ network: "github" }) : null;
  if (authenticated && !c) throw socialError({ message: "Connect GitHub in Settings." });
  const version = generation({ network: "github" }),
    nonce = `v2:${randomUUID()}`;
  const response = await request({
    url: `https://github.com${path}`,
    network: "github",
    headers: {
      Accept: "text/html",
      "User-Agent": "NoFeedSocial/1",
      ...(etag ? { "If-None-Match": etag } : {}),
      ...(c
        ? {
            Cookie: `user_session=${c.userSession}; __Host-user_session_same_site=${c.sameSiteUserSession}; logged_in=yes`,
          }
        : {}),
      ...(feed
        ? {
            Referer: "https://github.com/",
            "X-Requested-With": "XMLHttpRequest",
            "X-Fetch-Nonce": nonce,
            "X-Fetch-Nonce-To-Validate": nonce,
          }
        : {}),
    },
  });
  if (response.status === 304)
    return { html: "", status: 304, etag: response.headers.get("etag") ?? etag };
  if (response.status >= 300 && response.status < 400)
    throw socialError({ message: "GitHub needs to reconnect. Sign in again in Settings." });
  if (!response.ok)
    throw socialError({ message: `GitHub returned an error (${response.status}).` });
  const rotated = selectedResponseCookies({
    headers: response.headers,
    selected: ["user_session", "__Host-user_session_same_site"],
  });
  if (c && Object.keys(rotated).length && generation({ network: "github" }) === version)
    await saveCredentials({
      expectedGeneration: version,
      network: "github",
      value: {
        ...c,
        ...(rotated.user_session ? { userSession: rotated.user_session } : {}),
        ...(rotated["__Host-user_session_same_site"]
          ? { sameSiteUserSession: rotated["__Host-user_session_same_site"]! }
          : {}),
      },
    });
  return {
    html: await response.text(),
    status: response.status,
    etag: response.headers.get("etag") ?? undefined,
  };
}
async function html(params: Parameters<typeof githubPage>[0]) {
  return (await githubPage(params)).html;
}
export async function connectGitHub() {
  const account = githubIdentity({ html: await html({ path: "/", authenticated: true }) });
  if (!account)
    throw socialError({
      message: "GitHub did not confirm the signed-in account. Try signing in again.",
    });
  return account;
}
export async function githubFeed({ account }: { account: Account }) {
  return parseGitHubFeed({
    html: await html({ path: "/conduit/for_you_feed", authenticated: true, feed: true }),
    account,
  });
}
export async function githubProfile({ username }: { username: string }) {
  return githubPublicProfile({
    html: await html({ path: `/${encodeURIComponent(username)}` }),
    username,
  });
}
export async function githubRepo({ url }: { url: string }) {
  const parsed = new URL(url);
  if (
    parsed.origin !== "https://github.com" ||
    parsed.pathname.split("/").filter(Boolean).length !== 2
  )
    throw new Error("Invalid repository");
  const page = await html({ path: parsed.pathname });
  const parent = page.match(/forked from\s*<a[^>]*href="\/([^"]+)"/)?.[1];
  return {
    ...githubCard({ html: page, url }),
    parentURL: parent ? `https://github.com/${parent}` : undefined,
  };
}
export async function githubSearch({ query }: { query: string }) {
  return [await githubProfile({ username: query.trim().replace(/^@/, "") })];
}
