import type { Actor, SocialNotification, StoryReel } from "./models";
export function actorName({ actor }: { actor: Actor }) {
  return actor.username || actor.name || actor.id;
}
export function notificationCopy({ item }: { item: SocialNotification }) {
  const first = item.actors[0]!,
    name = actorName({ actor: first }),
    count = item.actors.length - 1;
  const actor = `${name}${count ? ` and ${count} other${count === 1 ? "" : "s"}` : ""}`;
  let summary = item.text;
  if (item.category === "replies") summary = `${actor} replied to you`;
  else if (item.category === "mentions") summary = `${actor} mentioned you`;
  else if (item.category === "follows") summary = `${actor} followed you`;
  else {
    for (const person of item.actors) {
      summary = summary.replaceAll(`@${person.username}`, person.username);
      if (person.name && person.name !== person.username)
        summary = summary.replaceAll(person.name, actorName({ actor: person }));
    }
    if (item.network === "x")
      summary = summary
        .replace("reposted your post", "retweeted your tweet")
        .replace("your post", "your tweet");
  }
  const target = item.post,
    text = target?.text ?? "";
  const messageImage =
    item.category === "messages" && /^(sent a reel|sent a post|sent media)/i.test(text);
  const useText = ["reactions", "replies", "mentions", "messages"].includes(item.category);
  const image =
    item.category !== "follows" && (messageImage || !text || !useText)
      ? target?.images[0]
      : undefined;
  const preview =
    item.category === "follows" || image
      ? undefined
      : useText && text
        ? text
        : item.network !== "bluesky"
          ? name
          : undefined;
  const leadingActor = summary.startsWith(actor);
  return {
    actor,
    summary,
    leadingActor,
    remainder: leadingActor ? summary.slice(actor.length) : "",
    preview,
    image,
  };
}
export function sortedStories({ reels }: { reels: StoryReel[] }) {
  return [...reels].sort((a, b) => Number(a.seen) - Number(b.seen) || b.timestamp - a.timestamp);
}

export function notificationActivity({ item }: { item: SocialNotification }) {
  let text = item.text;
  for (const actor of item.actors) {
    if (actor.name && actor.name !== actor.username)
      text = text.replaceAll(actor.name, actorName({ actor }));
    text = text.replaceAll(`@${actor.username}`, actor.username);
  }
  return item.network === "x"
    ? text.replace("reposted your post", "retweeted your tweet").replace("your post", "your tweet")
    : text;
}

export function profileCount({ value }: { value: number }) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(value);
}
export function likeCount({ value }: { value: number }) {
  const unit = [
    { threshold: 1_000_000_000, suffix: "B" },
    { threshold: 1_000_000, suffix: "M" },
    { threshold: 1_000, suffix: "K" },
  ].find(({ threshold }) => Math.abs(value) >= threshold);
  if (!unit) return String(value);
  const scaled = value / unit.threshold;
  const digits = Math.max(1, Math.floor(Math.log10(Math.abs(scaled))) + 1);
  return `${scaled.toFixed(Math.max(0, 2 - digits))}${unit.suffix}`;
}
