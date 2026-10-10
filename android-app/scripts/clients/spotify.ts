import { z } from "zod";
import {
  spotifyClientToken,
  spotifyToken,
  spotifyServerTime,
  spotifyRequest,
  spotifyProfileAttributes,
  spotifyProfile,
  spotifySearch,
  spotifyPreview,
  spotifySaved,
  spotifySave,
} from "../../src/providers/spotify";
import { spotifyTOTP } from "../../src/providers/spotify-totp";
import { object, list } from "../../src/app/value";
import { credentialPresence } from "./runtime";
import { type Command, type Context, stringOption, option, username } from "./arguments";

function track(c: Context) {
  let value = z.string().min(1).parse(c.args[0]);
  if (value.startsWith("https://open.spotify.com/track/"))
    value = new URL(value).pathname.split("/")[2]!;
  return z
    .string()
    .regex(/^[A-Za-z0-9]+$/)
    .parse(value.replace(/^spotify:track:/, ""));
}
const user = (c: Context) => username(c.args[0]).replace(/^spotify:user:/, "");
async function resolveUsername(c: Context) {
  await spotifyClientToken({ force: true });
  const data = await spotifyProfileAttributes();
  const name = z
    .string()
    .min(1)
    .parse(object(object(object(data.data).me).profile).username);
  await c.session.runtime.saveCredentials({
    network: "spotify",
    value: { ...c.session.current(), username: name },
  });
  return { username: name };
}
export const spotifyCommands: Record<string, Command> = {
  bootstrap: {
    description: "Show credential presence without refreshing or printing tokens.",
    run: async (c) => credentialPresence({ value: c.session.current() }),
  },
  "refresh-token": {
    description: "Refresh the WebPlayer token; output contains presence only.",
    options: { reason: stringOption },
    run: async (c) => {
      const reason = z
        .enum(["transport", "init"])
        .parse(option({ context: c, name: "reason", fallback: "transport" }));
      const value = await spotifyToken({ initial: reason === "init", force: true });
      return {
        refreshed: true,
        reason,
        expiresAt: value[reason === "init" ? "initialExpiresAt" : "expiresAt"],
      };
    },
  },
  "server-time": {
    description: "Read Spotify's server time.",
    anonymous: true,
    run: spotifyServerTime,
  },
  totp: {
    description:
      "Check the shared TOTP implementation without printing a live authentication code.",
    anonymous: true,
    run: async () => ({
      generated: /^\d{6}$/.test(spotifyTOTP({ seconds: Date.now() / 1000 })),
      version: 61,
    }),
  },
  buddylist: {
    description: "Read friend listening activity.",
    run: () => spotifyRequest({ path: "presence-view/v1/buddylist" }),
  },
  "validate-cookie-login": {
    description: "Discard captured tokens and validate renewal and activity from cookies only.",
    run: async (c) => {
      const current = c.session.current()!;
      await c.session.runtime.saveCredentials({
        network: "spotify",
        value: Object.fromEntries(
          ["spDC", "spT", "spKey"].flatMap((key) => (current[key] ? [[key, current[key]!]] : [])),
        ),
      });
      const data = await spotifyRequest({ path: "presence-view/v1/buddylist" });
      z.array(z.unknown()).parse(data.friends);
      return {
        authenticated: true,
        friends: list(data.friends).length,
        bearerPresent: !!c.session.current()?.bearerToken,
      };
    },
  },
  "profile-attributes": {
    description: "Read current-user Pathfinder attributes.",
    run: spotifyProfileAttributes,
  },
  "resolve-username": {
    description: "Resolve the viewer with a fresh session client token.",
    run: resolveUsername,
  },
  username: { description: "Resolve the signed-in username.", run: resolveUsername },
  "current-username": {
    description: "Read the current user through the canonical Spotify /v1/me endpoint.",
    run: () => spotifyRequest({ path: "https://api.spotify.com/v1/me" }),
  },
  "client-token": {
    description: "Mint a fresh client token; never print its value.",
    run: async () => ({
      clientTokenPresent: !!(await spotifyClientToken({ force: true })).clientToken,
    }),
  },
  "user-profile": {
    description: "Read a user profile and relationship counts.",
    arguments: ["username"],
    run: (c) => spotifyProfile({ username: user(c) }),
  },
  "search-users": {
    description: "Search using the app's user-search client.",
    arguments: ["query"],
    run: (c) => spotifySearch({ query: username(c.args[0]) }),
  },
  following: {
    description: "Read followed users.",
    arguments: ["username"],
    run: (c) =>
      spotifyRequest({
        path: `user-profile-view/v3/profile/${encodeURIComponent(user(c))}/following?market=from_token`,
      }),
  },
  followers: {
    description: "Read followers.",
    arguments: ["username"],
    run: (c) =>
      spotifyRequest({
        path: `user-profile-view/v3/profile/${encodeURIComponent(user(c))}/followers?market=from_token`,
      }),
  },
  "audio-analysis": {
    description: "Read track audio analysis.",
    arguments: ["track_id"],
    run: (c) => spotifyRequest({ path: `audio-attributes/v1/audio-analysis/${track(c)}` }),
  },
  "track-preview": {
    description: "Read the public embedded track preview URL.",
    arguments: ["track_id"],
    anonymous: true,
    run: async (c) => ({ previewURL: await spotifyPreview({ trackId: track(c) }) }),
  },
  "is-track-saved": {
    description: "Check the current library.",
    arguments: ["track_id"],
    run: async (c) => ({ saved: await spotifySaved({ trackId: track(c) }) }),
  },
  "save-track": {
    description: "Save a track to the library.",
    arguments: ["track_id"],
    run: async (c) => {
      await spotifySave({ trackId: track(c), saved: true });
      return { saved: true };
    },
  },
  "remove-track": {
    description: "Remove a track from the library.",
    arguments: ["track_id"],
    run: async (c) => {
      await spotifySave({ trackId: track(c), saved: false });
      return { saved: false };
    },
  },
  get: {
    description: "GET a spclient path or an allowed Spotify API HTTPS URL.",
    arguments: ["url_or_path"],
    run: (c) => spotifyRequest({ path: c.args[0]! }),
  },
};
