import { z } from "zod";
import { parseCookies } from "./cookies";

const cookieFields = {
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
type CookieNetwork = keyof typeof cookieFields;
type LoginCredentials = Record<string, string>;
const required: Record<CookieNetwork, string[]> = {
  x: ["authToken", "ct0"],
  instagram: ["sessionId", "csrfToken", "dsUserId"],
  github: ["userSession", "sameSiteUserSession"],
  spotify: ["spDC", "spT"],
};

export function selectedLoginCookies({
  network,
  header,
}: {
  network: CookieNetwork;
  header: string;
}) {
  const cookies = parseCookies({ header: z.string().parse(header) });
  const value: LoginCredentials = {};
  for (const [name, field] of Object.entries(cookieFields[network])) {
    if (cookies[name]) value[field] = cookies[name];
  }
  return required[network].every((field) => value[field]) ? value : undefined;
}

export function createLoginCookieDetector({
  network,
  readCookies,
  connect,
  isActive,
  onError,
}: {
  network: CookieNetwork;
  readCookies: () => Promise<string>;
  connect: (value: LoginCredentials) => Promise<void>;
  isActive: () => boolean;
  onError: (error: unknown) => void;
}) {
  let stopped = false,
    busy = false,
    completed = false;
  let attempted: string | undefined;
  const active = () => !stopped && !completed && isActive();
  return {
    async check({ retry = false }: { retry?: boolean } = {}) {
      if (busy || !active()) return;
      busy = true;
      try {
        const value = selectedLoginCookies({ network, header: await readCookies() });
        if (!active() || !value) return;
        // Optional-cookie rotation must not repeatedly validate a rejected session.
        const identity = JSON.stringify(required[network].map((field) => value[field]));
        if (!retry && identity === attempted) return;
        attempted = identity;
        await connect(value);
        completed = true;
      } catch (error) {
        if (!stopped && !completed) onError(error);
      } finally {
        busy = false;
      }
    },
    stop() {
      stopped = true;
      attempted = undefined;
    },
  };
}
