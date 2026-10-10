import { createContext, useContext, useState, type ReactNode } from "react";
import {
  accountSchema,
  notificationSchema,
  storyReelSchema,
  networks,
  type Network,
} from "./models";
const Context = createContext({ enabled: false, setEnabled: (_enabled: boolean) => {} });
export function PreviewProvider({ children }: { children: ReactNode }) {
  const [enabled, setEnabled] = useState(false);
  return <Context.Provider value={{ enabled, setEnabled }}>{children}</Context.Provider>;
}
export function usePreview() {
  return useContext(Context);
}
function demoActor({
  network,
  username,
  name,
}: {
  network: Network;
  username: string;
  name: string;
}) {
  const hash = Array.from(username).reduce((sum, char) => sum + char.charCodeAt(0), 0);
  const avatar = ["jules_dev", "maya.co"].includes(username)
    ? `https://randomuser.me/api/portraits/women/${hash % 60}.jpg`
    : username === "torres"
      ? `https://randomuser.me/api/portraits/men/${hash % 90}.jpg`
      : `https://i.pravatar.cc/120?img=${(hash % 70) + 1}`;
  return { network, id: `sample-${network}-${username}`, username, name, avatar };
}
export function previewData() {
  const now = Date.now(),
    minutes = (n: number) => now - n * 60000;
  const photo = (seed: string) => `https://picsum.photos/seed/${seed}/1080/1920`;
  const accounts = networks.map((network) =>
    accountSchema.parse({
      network,
      id: `preview-${network}`,
      username: "preview",
      name: "Preview account",
      connectedAt: now,
    }),
  );
  const alex = demoActor({ network: "x", username: "alex_smith", name: "Alex Smith" }),
    jules = demoActor({ network: "x", username: "jules_dev", name: "Jules" }),
    nova = demoActor({ network: "farcaster", username: "nova.builds", name: "Nova" }),
    maya = demoActor({ network: "bluesky", username: "maya.co", name: "maya" }),
    kade = demoActor({ network: "bluesky", username: "kade.bsky.social", name: "Kade" }),
    riley = demoActor({ network: "farcaster", username: "riley.wtf", name: "riley" }),
    amy = demoActor({ network: "instagram", username: "amy_stories", name: "Amy" }),
    torres = demoActor({ network: "github", username: "torres", name: "torres" });
  const notifications = [
    {
      actor: alex,
      category: "replies",
      at: 3,
      text: "@alex_smith replied to your post",
      preview: "Love this — finally a feed I can open without getting lost. Shipping!",
    },
    { actor: nova, category: "follows", at: 8, text: "@nova.builds followed you" },
    {
      actor: jules,
      category: "mentions",
      at: 11,
      text: "@jules_dev mentioned you in a post",
      preview: "@stephancill your microcopy about avoiding algorithmic feeds is spot on.",
    },
    {
      actor: maya,
      category: "replies",
      at: 14,
      text: "@maya.co replied to your post",
      preview: "Big fan of showing notifications without the feed.",
    },
    {
      actor: amy,
      category: "messages",
      at: 18,
      text: "@amy_stories sent you a message",
      preview: "Do you have an invite code? I want in!",
    },
    {
      actor: kade,
      network: "github",
      category: "reactions",
      at: 22,
      text: "@kade.bsky.social starred your repository",
      preview: "stupid-social",
    },
    {
      actor: kade,
      category: "reactions",
      at: 26,
      text: "@kade.bsky.social liked your post",
      preview: "You can feel the algorithms adjusting.",
    },
    {
      actor: riley,
      category: "replies",
      at: 31,
      text: "@riley.wtf replied to your cast",
      preview: "This is the calm feed I came here for.",
    },
    { actor: jules, category: "follows", at: 36, text: "@jules_dev followed you" },
  ].map((item, index) =>
    notificationSchema.parse({
      id: `preview-${index}`,
      network: item.network ?? item.actor.network,
      accountId: `preview-${item.network ?? item.actor.network}`,
      category: item.category,
      event: "preview",
      timestamp: minutes(item.at),
      text: item.text,
      actors: [item.actor],
      post: item.preview
        ? {
            id: `preview-${index}`,
            text: item.preview,
            images:
              index === 0
                ? [photo("reply-coast")]
                : index === 4
                  ? ["https://picsum.photos/seed/message-sunset/1200/1000"]
                  : index === 6
                    ? ["https://picsum.photos/seed/algorithms/1200/1000"]
                    : [],
            author: index === 5 ? undefined : item.actor,
            likes: index === 2 ? 2 : undefined,
            timestamp: minutes(item.at),
            url:
              index === 0
                ? "https://x.com/alex_smith/status/1101"
                : "https://stupidtech.net/stupid-social",
          }
        : undefined,
    }),
  );
  const alix = demoActor({ network: "instagram", username: "alix.photos", name: "alix" }),
    miles = demoActor({ network: "instagram", username: "miles.j", name: "Miles" }),
    nico = demoActor({ network: "spotify", username: "nico", name: "Nico" }),
    pearl = demoActor({ network: "github", username: "pearl.dev", name: "Pearl" });
  const stories = [
    {
      actor: alix,
      timestamp: minutes(6),
      slides: [
        { id: "alix-1", timestamp: minutes(6), image: photo("alix-coast") },
        {
          id: "alix-2",
          timestamp: minutes(4),
          image: photo("alix-sunset"),
          title: "Sunshine",
          artist: "Luna",
          artwork: photo("sunshine-art"),
        },
      ],
    },
    {
      actor: miles,
      timestamp: minutes(12),
      slides: [{ id: "miles-1", timestamp: minutes(12), image: photo("miles-board") }],
    },
    {
      actor: nico,
      timestamp: minutes(2),
      thumbnail: photo("neon-drift"),
      slides: [
        {
          id: "spotify-preview",
          timestamp: minutes(2),
          title: "Midnight City",
          artist: "Riddle",
          text: "Neon Drift",
          image: photo("neon-drift"),
          trackId: "demo",
          url: "https://open.spotify.com/track/demo",
        },
      ],
    },
    {
      actor: torres,
      timestamp: minutes(5),
      slides: [
        {
          id: "github-repo",
          timestamp: minutes(5),
          title: "demo/swiftui-gallery",
          text: "starred demo/swiftui-gallery",
          url: "https://github.com/demo/swiftui-gallery",
          github: {
            kind: "starred",
            avatar: torres.avatar,
            description: "A gallery of modern SwiftUI patterns.",
            language: "Swift",
            languageColor: "#F05138",
            stars: "12.4k",
          },
        },
      ],
    },
    {
      actor: pearl,
      timestamp: minutes(9),
      slides: [
        {
          id: "github-follow",
          timestamp: minutes(9),
          title: "felix",
          text: "followed you",
          url: "https://github.com/felix",
          github: {
            kind: "followed",
            avatar: pearl.avatar,
            name: "Felix",
            bio: "Indie maker. Privacy first.",
          },
        },
      ],
    },
  ].map((item, index) =>
    storyReelSchema.parse({
      ...item,
      id: `preview-story-${index}`,
      network: item.actor.network,
      accountId: `preview-${item.actor.network}`,
      seen: false,
    }),
  );
  return { accounts, notifications, stories };
}
