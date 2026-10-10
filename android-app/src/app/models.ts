import { z } from "zod";

export const networks = ["x", "farcaster", "instagram", "bluesky", "github", "spotify"] as const;
export const networkSchema = z.enum(networks);
export type Network = (typeof networks)[number];
export const networkNames: Record<Network, string> = {
  x: "X",
  farcaster: "Farcaster",
  instagram: "Instagram",
  bluesky: "Bluesky",
  github: "GitHub",
  spotify: "Spotify",
};
export const categories = [
  "mentions",
  "replies",
  "reactions",
  "posts",
  "follows",
  "messages",
] as const;
export type Category = (typeof categories)[number];
export const categoryLabels: Record<Category, string> = {
  mentions: "Mentions",
  replies: "Replies and comments",
  reactions: "Likes and reposts",
  posts: "Post notifications",
  follows: "Follows",
  messages: "Messages",
};
const webURL = z.url().refine((value) => new URL(value).protocol === "https:");
export const actorSchema = z.object({
  network: networkSchema.default("x"),
  id: z.string().min(1),
  username: z.string(),
  name: z.string(),
  avatar: webURL.optional(),
});
export type Actor = z.infer<typeof actorSchema>;
export const profileSchema = actorSchema.extend({
  bio: z.string().default(""),
  followers: z.number().optional(),
  following: z.number().optional(),
  posts: z.number().optional(),
  joinedAt: z.number().optional(),
  location: z.string().optional(),
  website: webURL.optional(),
  verified: z.boolean().optional(),
  isFollowing: z.boolean().optional(),
  followsYou: z.boolean().optional(),
  notifyPosts: z.boolean().optional(),
});
export type Profile = z.infer<typeof profileSchema>;
export const postSchema = z.object({
  id: z.string().min(1),
  text: z.string(),
  url: webURL,
  author: actorSchema.optional(),
  timestamp: z.number().optional(),
  likes: z.number().optional(),
  images: z.array(webURL),
  parentId: z.string().optional(),
  media: z.array(z.object({ image: webURL.optional(), video: webURL.optional() })).optional(),
});
export type Post = z.infer<typeof postSchema>;
export const notificationSchema = z.object({
  id: z.string().min(1),
  network: networkSchema,
  accountId: z.string().min(1),
  category: z.enum(categories),
  event: z.string(),
  timestamp: z.number().finite(),
  text: z.string(),
  actors: z.array(actorSchema).min(1),
  post: postSchema.optional(),
  relatedPosts: z.array(postSchema).default([]),
  url: webURL.optional(),
  parentPost: postSchema.optional(),
});
export type SocialNotification = z.infer<typeof notificationSchema>;
export const preferencesSchema = z.object({
  categories: z.array(z.enum(categories)).default([...categories]),
  includeMediaShares: z.boolean().default(true),
  storiesEnabled: z.boolean().default(true),
});
export type Preferences = z.infer<typeof preferencesSchema>;
export const defaultPreferences: Preferences = {
  categories: [...categories],
  includeMediaShares: true,
  storiesEnabled: true,
};
export const accountSchema = actorSchema.extend({ connectedAt: z.number() });
export type Account = z.infer<typeof accountSchema>;
export const storySlideSchema = z.object({
  id: z.string(),
  timestamp: z.number(),
  text: z.string().default(""),
  image: webURL.optional(),
  video: webURL.optional(),
  url: webURL.optional(),
  ownerId: z.string().optional(),
  liked: z.boolean().default(false),
  trackId: z.string().optional(),
  artist: z.string().optional(),
  title: z.string().optional(),
  audio: webURL.optional(),
  artwork: webURL.optional(),
  context: z.string().optional(),
  linkTitles: z.record(z.string(), z.string()).default({}),
  embedURL: webURL.optional(),
  embedLabel: z.string().optional(),
  github: z
    .object({
      kind: z.enum(["starred", "followed", "forked", "created", "updated"]),
      description: z.string().optional(),
      language: z.string().optional(),
      languageColor: z.string().optional(),
      stars: z.string().optional(),
      avatar: webURL.optional(),
      name: z.string().optional(),
      bio: z.string().optional(),
      repos: z.string().optional(),
      followers: z.string().optional(),
    })
    .optional(),
  duration: z.number().optional(),
  mentions: z.array(actorSchema).default([]),
  links: z.array(webURL).default([]),
});
export type StorySlide = z.infer<typeof storySlideSchema>;
export const storyReelSchema = z.object({
  id: z.string(),
  network: networkSchema,
  accountId: z.string(),
  actor: actorSchema,
  timestamp: z.number(),
  slides: z.array(storySlideSchema),
  seen: z.boolean(),
  thumbnail: webURL.optional(),
  closeFriends: z.boolean().default(false),
});
export type StoryReel = z.infer<typeof storyReelSchema>;
export type SourceResult = {
  notifications: SocialNotification[];
  stories: StoryReel[];
  warning?: string;
  preserveStories?: boolean;
  replaceMessages?: boolean;
};

export function errorMessage({ error }: { error: unknown }): string {
  if (error instanceof Error && error.name === "SocialError") return error.message;
  return "Something went wrong. Check your connection and try again.";
}
export function socialError({ message }: { message: string }) {
  const error = new Error(message);
  error.name = "SocialError";
  return error;
}
export function relativeTime({ timestamp, now = Date.now() }: { timestamp: number; now?: number }) {
  const minutes = Math.max(0, Math.floor((now - timestamp) / 60000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return days < 7 ? `${days}d` : new Date(timestamp).toLocaleDateString();
}
