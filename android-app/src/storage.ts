import * as SecureStore from "expo-secure-store";
import { z } from "zod";
import { bridge } from "./bridge";
import { parseCookies } from "./app/cookies";
export { parseCookies } from "./app/cookies";

export const providerSchema = z.enum(["x", "instagram", "github", "spotify"]);
export type Provider = z.infer<typeof providerSchema>;
export const credentialsSchema = z.record(z.string(), z.string());
export type Credentials = z.infer<typeof credentialsSchema>;
const key = ({ provider }: { provider: string }) => `validation.${provider}`;

export async function saveCredentials({
  provider,
  credentials,
}: {
  provider: string;
  credentials: Credentials;
}) {
  await SecureStore.setItemAsync(
    key({ provider }),
    JSON.stringify(credentialsSchema.parse(credentials)),
  );
}
export async function loadCredentials({ provider }: { provider: string }) {
  const value = await SecureStore.getItemAsync(key({ provider }));
  return value ? credentialsSchema.parse(JSON.parse(value)) : null;
}
export async function importSeed() {
  const seed = await bridge.importSeed();
  if (!seed) return 0;
  const parsed = z.partialRecord(providerSchema, credentialsSchema).parse(JSON.parse(seed));
  for (const [provider, credentials] of Object.entries(parsed)) {
    if (credentials) await saveCredentials({ provider, credentials });
  }
  return Object.keys(parsed).length;
}
export const loginURLs: Record<Provider, string> = {
  x: "https://x.com/i/flow/login",
  instagram: "https://www.instagram.com/accounts/login/",
  github: "https://github.com/login",
  spotify: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F%3Fnd%3D1",
};
export const cookieURLs: Record<Provider, string> = {
  x: "https://x.com/",
  instagram: "https://www.instagram.com/",
  github: "https://github.com/",
  spotify: "https://open.spotify.com/",
};
const cookieFields: Record<Provider, Record<string, string>> = {
  x: { auth_token: "authToken", ct0: "ct0" },
  instagram: {
    sessionid: "sessionId",
    csrftoken: "csrfToken",
    ds_user_id: "dsUserId",
    mid: "mid",
    rur: "rur",
    ig_did: "igDid",
  },
  github: { user_session: "userSession", "__Host-user_session_same_site": "sameSiteUserSession" },
  spotify: { sp_dc: "spDC", sp_t: "spT", sp_key: "spKey" },
};
export async function captureCookies({
  provider,
  bearerToken,
  clientToken,
}: {
  provider: Provider;
  bearerToken?: string;
  clientToken?: string;
}) {
  const cookies = parseCookies({ header: await bridge.cookies(cookieURLs[provider]) });
  const credentials: Credentials = {};
  for (const [name, field] of Object.entries(cookieFields[provider])) {
    if (cookies[name]) credentials[field] = cookies[name];
  }
  const required: Record<Provider, string[]> = {
    x: ["authToken", "ct0"],
    instagram: ["sessionId", "csrfToken", "dsUserId"],
    github: ["userSession", "sameSiteUserSession"],
    spotify: ["spDC", "spT"],
  };
  if (!required[provider].every((field) => credentials[field])) return false;
  if (provider === "spotify") {
    if (!bearerToken) return false;
    credentials.bearerToken = bearerToken;
    credentials.clientToken = clientToken ?? "";
  }
  await saveCredentials({ provider, credentials });
  return true;
}
