import { parseDocument } from "htmlparser2";
import { getElementsByTagName, getText, getOuterHTML, findAll } from "domutils";
import { isTag } from "domhandler";
import {
  accountSchema,
  profileSchema,
  storyReelSchema,
  notificationSchema,
  type Account,
  type SourceResult,
} from "../app/models";
import { object, text, https, timestamp } from "../app/value";
export function githubActor({ username }: { username: string }) {
  return profileSchema.parse({
    network: "github",
    id: username.toLowerCase(),
    username,
    name: username,
    avatar: `https://github.com/${username}.png?size=192`,
  });
}
export function githubIdentity({ html }: { html: string }) {
  const username =
    html.match(/"userMenu"\s*:\s*\{\s*"owner"\s*:\s*\{[^}]*"login"\s*:\s*"([^"]+)"/)?.[1] ??
    html.match(/<meta\s+name="user-login"\s+content="([^"]+)"/)?.[1];
  return username
    ? accountSchema.parse({ ...githubActor({ username }), connectedAt: Date.now() })
    : undefined;
}
export function githubCard({ html, url }: { html: string; url: string }) {
  const doc = parseDocument(html),
    metas = getElementsByTagName("meta", doc.children, true),
    og = (name: string) => metas.find((e) => e.attribs.property === name)?.attribs.content;
  return {
    id: url,
    text: og("og:description") ?? "",
    title: og("og:title") ?? "Repository",
    url,
    images: https(og("og:image")) ? [og("og:image")!] : [],
  };
}
export function githubPublicProfile({ html, username }: { html: string; username: string }) {
  const doc = parseDocument(html),
    elements = findAll((e) => isTag(e), doc.children),
    byClass = (name: string) =>
      elements.find((e) => (e.attribs.class ?? "").split(/\s+/).includes(name));
  const count = (tab: string) => {
    const a = elements.find((e) => e.name === "a" && (e.attribs.href ?? "").includes(`tab=${tab}`));
    const raw = a
      ? getText(a)
          .trim()
          .match(/[\d.,]+[km]?/i)?.[0]
      : undefined;
    if (!raw) return undefined;
    return Math.round(
      Number(raw.replace(/[,km]/gi, "")) * (/k/i.test(raw) ? 1000 : /m/i.test(raw) ? 1000000 : 1),
    );
  };
  return profileSchema.parse({
    ...githubActor({ username }),
    name: byClass("p-name") ? getText(byClass("p-name")!).trim() : username,
    bio: byClass("p-note") ? getText(byClass("p-note")!).trim() : "",
    followers: count("followers"),
    following: count("following"),
  });
}
type Card = {
  metadata: Record<string, unknown>;
  actions: { type: string; id: string; url: string }[];
};
export function parseGitHubFeed({
  html,
  account,
}: {
  html: string;
  account: Account;
}): SourceResult {
  const doc = parseDocument(html),
    cards = new Map<string, Card>(),
    elements = findAll((e) => isTag(e), doc.children);
  function hidden(e: (typeof elements)[number]) {
    let p = e.parent;
    while (p) {
      if (isTag(p) && (p.attribs.class ?? "").includes("Details-content--hidden")) return true;
      p = p.parent;
    }
    return false;
  }
  for (const e of elements) {
    if (hidden(e)) continue;
    for (const kind of ["view", "click"]) {
      const raw = e.attribs[`data-hydro-${kind}`];
      if (!raw) continue;
      let value: unknown;
      try {
        value = JSON.parse(raw);
      } catch {
        continue;
      }
      const payload = object(object(value).payload),
        meta = object(payload.feed_card);
      if (!meta.card_type) continue;
      const key = `${meta.card_type}:${meta.record_id}`,
        card = cards.get(key) ?? { metadata: meta, actions: [] };
      cards.set(key, card);
      if (kind === "click" && e.attribs.href) {
        const url = new URL(e.attribs.href, "https://github.com");
        if (url.origin !== "https://github.com") continue;
        const m = object(payload.metadata);
        card.actions.push({
          type: text(m.clicked_resource_type),
          id: text(m.clicked_resource_id),
          url: url.href,
        });
      }
    }
  }
  const items: {
    id: string;
    actor: ReturnType<typeof githubActor>;
    at: number;
    target: string;
    url: string;
    verb: string;
    position: string;
    sub: number;
  }[] = [];
  const verbs: Record<string, string> = {
    STARRED_REPOSITORY: "starred",
    FOLLOW: "followed",
    FORKED_REPOSITORY: "forked",
    CREATED_REPOSITORY: "created",
  };
  for (const [id, { metadata: m, actions }] of cards) {
    const verb = verbs[text(m.card_type)];
    if (!verb) continue;
    const follow = m.card_type === "FOLLOW",
      user = actions.find((a) => a.type === "USER" && (!follow || a.id === text(m.resource_id))),
      target = actions.find(
        (a) =>
          a.type === (follow ? "USER" : "REPO") &&
          a.id === text(follow ? m.record_id : m.resource_id),
      );
    if (!target) continue;
    const username = user ? new URL(user.url).pathname.split("/")[1]! : "";
    items.push({
      id,
      actor: githubActor({ username: username || `user-${m.resource_id}` }),
      at: timestamp(m.created_at),
      target: new URL(target.url).pathname.slice(1),
      url: target.url,
      verb,
      position: text(m.card_position),
      sub: Number(m.card_sub_position ?? 0),
    });
  }
  const actorByPosition = new Map(
    items
      .filter((i) => i.sub === 0 && !i.actor.username.startsWith("user-"))
      .map((i) => [i.position, i.actor]),
  );
  for (const i of items)
    if ((i.sub > 0 || i.actor.username.startsWith("user-")) && actorByPosition.has(i.position))
      i.actor = actorByPosition.get(i.position)!;
  // Rendered actor rows complement Hydro metadata in owned-repository rollups.
  const rendered = getElementsByTagName("article", doc.children, true)
    .filter((article) => !hidden(article))
    .map((article) => {
      const anchors = getElementsByTagName("a", article.children, true);
      const repos = [
        ...new Set(
          anchors.flatMap((a) => {
            const path = (a.attribs.href ?? "").replace(/^https:\/\/github.com/, "").split("?")[0]!;
            const parts = path.split("/").filter(Boolean);
            return parts.length === 2 && parts[0]!.toLowerCase() === account.username.toLowerCase()
              ? [parts.join("/")]
              : [];
          }),
        ),
      ];
      const actors = anchors
        .filter(
          (a) =>
            /^\/[\w-]+$/.test(a.attribs.href ?? "") &&
            /starred/.test(a.next ? getText(a.next) : ""),
        )
        .map((a) => a.attribs.href!.slice(1));
      const metadata = Object.values(article.attribs).join(" ");
      const position = metadata.match(/"card_position"\s*:\s*(\d+)/)?.[1];
      const hover = article.attribs["data-hovercard-url"];
      let created: string | undefined;
      if (hover) {
        try {
          created =
            new URL(hover, "https://github.com").searchParams.get(
              "payload[feed_card][created_at]",
            ) ?? undefined;
        } catch {
          /* Invalid metadata has no usable date. */
        }
      }
      const at = timestamp(
        created?.replace(
          /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{2})(\d{2})$/,
          "$1T$2$3:$4",
        ) ?? getElementsByTagName("relative-time", article.children, true)[0]?.attribs.datetime,
      );
      return { repos, actors, position, at };
    });
  const renderedActors = new Map<string, string[]>();
  for (const row of rendered)
    if (row.position && row.actors.length) renderedActors.set(row.position, row.actors);
  for (const row of rendered)
    for (const actor of new Set(
      row.actors.length ? row.actors : row.position ? renderedActors.get(row.position) : [],
    ))
      for (const target of row.repos) {
        if (
          items.some(
            (i) => i.actor.username === actor && i.target === target && i.verb === "starred",
          )
        )
          continue;
        items.push({
          id: `rollup:${actor}:${target}`,
          actor: githubActor({ username: actor }),
          at: row.at,
          target,
          url: `https://github.com/${target}`,
          verb: "starred",
          position: row.position ?? "",
          sub: 0,
        });
      }
  const notifications: SourceResult["notifications"] = [],
    groups = new Map<string, typeof items>();
  for (const item of items) {
    if (item.actor.username.startsWith("user-")) continue;
    const summary = `${item.actor.username} ${item.verb} ${item.target}`;
    if (
      item.verb === "starred" &&
      item.target.split("/")[0]!.toLowerCase() === account.username.toLowerCase()
    ) {
      notifications.push(
        notificationSchema.parse({
          id: `github:${account.id}:star:${item.actor.id}:${item.target}`,
          network: "github",
          accountId: account.id,
          category: "reactions",
          event: "star",
          timestamp: item.at,
          actors: [item.actor],
          text: summary,
          url: item.url,
          post: { id: item.target, text: item.target, url: item.url, images: [] },
        }),
      );
    } else {
      const group = groups.get(item.actor.id) ?? [];
      group.push(item);
      groups.set(item.actor.id, group);
    }
  }
  const stories = [...groups.entries()].map(([id, items]) =>
    storyReelSchema.parse({
      id: `github:${account.id}:${id}`,
      network: "github",
      accountId: account.id,
      actor: items[0]!.actor,
      timestamp: Math.max(...items.map((i) => i.at)),
      seen: false,
      thumbnail: items[0]!.actor.avatar,
      slides: items
        .sort((a, b) => a.at - b.at)
        .map((i) => ({
          id: i.id,
          timestamp: i.at,
          title: i.target,
          github: {
            kind: i.verb,
            avatar: `https://github.com/${i.target.split("/")[0]}.png?size=192`,
            ...cardDetails({
              target: i.target,
              articles: getElementsByTagName("article", doc.children, true),
            }),
          },
          text: `${i.actor.username} ${i.verb} ${i.target}`,
          url: i.url,
        })),
    }),
  );
  return { notifications, stories };
}

function cardDetails({
  target,
  articles,
}: {
  target: string;
  articles: import("domhandler").Element[];
}) {
  const article = articles.find((a) =>
    getElementsByTagName("a", a.children, true).some((e) => e.attribs.href === `/${target}`),
  );
  if (!article) return {};
  const elements = findAll(isTag, article.children);
  const value = (name: string) => elements.find((e) => e.attribs.itemprop === name);
  const language = value("programmingLanguage");
  const color = elements
    .find((e) => (e.attribs.class ?? "").includes("repo-language-color"))
    ?.attribs.style?.match(/#[0-9a-f]{6}/i)?.[0];
  const stars = elements
    .map((e) => e.attribs["aria-label"]?.match(/([0-9.,]+[kKmM]?)\s+stargazers/)?.[1])
    .find(Boolean);
  const description = elements.find((e) => (e.attribs.class ?? "").includes("wb-break-all"));
  const anchor = elements.find(
    (e) =>
      e.name === "a" &&
      e.attribs.href === `/${target}` &&
      (e.attribs.class ?? "").includes("text-bold"),
  );
  const text = getText(article);
  const fragment = getOuterHTML(article).match(
    /class="Link--primary Link text[^"]*"[^>]*>[^<]*<\/a>\s*<\/div>\s*<div[^>]*>\s*([^<]*)/,
  )?.[1];
  const rawStars = stars
    ? Number(stars.replace(/[,km]/gi, "")) *
      (/k/i.test(stars) ? 1000 : /m/i.test(stars) ? 1000000 : 1)
    : undefined;
  const formattedStars =
    rawStars === undefined
      ? undefined
      : Intl.NumberFormat("en-US", { notation: "compact", maximumSignificantDigits: 3 })
          .format(rawStars)
          .toLowerCase();
  return {
    language: language ? getText(language).trim() : undefined,
    languageColor: color,
    stars: formattedStars,
    description:
      target.includes("/") && fragment
        ? getText(parseDocument(fragment).children).trim()
        : description
          ? getText(description).trim()
          : undefined,
    name: !target.includes("/") && anchor ? getText(anchor).trim() : undefined,
    bio: !target.includes("/") && description ? getText(description).trim() : undefined,
    repos: text.match(/([0-9.,]+[kKmM]?)\s+repositories/)?.[1],
    followers: text.match(/([0-9.,]+[kKmM]?)\s+followers/)?.[1],
  };
}
