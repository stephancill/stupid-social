import type { Network } from "./app/models";
import type { Credentials } from "./app/storage";
export type { Credentials } from "./app/storage";

export type ClientResponse = Pick<
  Response,
  "ok" | "status" | "headers" | "text" | "json" | "arrayBuffer"
>;
export type ClientRuntime = {
  fetch: (url: string, init: RequestInit) => Promise<ClientResponse>;
  credentials: (params: { network: Network }) => Promise<Credentials | null>;
  saveCredentials: (params: {
    network: Network;
    value: Credentials | null;
    expectedGeneration?: number;
  }) => Promise<void>;
  generation: (params: { network: Network }) => number;
  randomUUID: () => string;
  randomBytes: (size: number) => Uint8Array;
  readFile: (params: { uri: string }) => Promise<Uint8Array>;
  openAuthSession: (params: {
    url: string;
    redirectURI: string;
  }) => Promise<{ type: "success"; url: string } | { type: "cancel" }>;
};

let configured: ClientRuntime | undefined;
export function configureClientRuntime({ runtime }: { runtime: ClientRuntime }) {
  configured = runtime;
}
function runtime() {
  if (!configured) throw new Error("Configure the provider client runtime before making requests.");
  return configured;
}
export const clientFetch: ClientRuntime["fetch"] = (url, init) => runtime().fetch(url, init);
export const credentials: ClientRuntime["credentials"] = (params) => runtime().credentials(params);
export const saveCredentials: ClientRuntime["saveCredentials"] = (params) =>
  runtime().saveCredentials(params);
export const generation: ClientRuntime["generation"] = (params) => runtime().generation(params);
export const randomUUID: ClientRuntime["randomUUID"] = () => runtime().randomUUID();
export const randomBytes: ClientRuntime["randomBytes"] = (size) => runtime().randomBytes(size);
export const readFile: ClientRuntime["readFile"] = (params) => runtime().readFile(params);
export const openAuthSession: ClientRuntime["openAuthSession"] = (params) =>
  runtime().openAuthSession(params);
