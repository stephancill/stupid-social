import type { NativeStackScreenProps } from "@react-navigation/native-stack";
import type { Actor, Profile, Post, Network, SocialNotification, StoryReel } from "./models";
export type Routes = {
  Home: undefined;
  Search: undefined;
  Settings: { issues?: Partial<Record<Network, string>> } | undefined;
  Account: { network: Network; issue?: string };
  Login: { network: "x" | "instagram" | "github" | "spotify" };
  Profile: { actor: Actor; preview?: boolean; initialProfile?: Profile };
  Post: { post: Post; network: Network };
  Notification: { item: SocialNotification; preview?: boolean };
  Stories: { reels: StoryReel[]; index: number; preview?: boolean };
  Composer: undefined;
  Browser: { url: string; title: string };
  Diagnostics: undefined;
};
export type ScreenProps<T extends keyof Routes> = NativeStackScreenProps<Routes, T>;
