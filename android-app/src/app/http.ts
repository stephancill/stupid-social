import { clientFetch } from "../clientRuntime";
import { z } from "zod";
import { networkNames, socialError, type Network } from "./models";

export async function request({
  url,
  method = "GET",
  headers = {},
  body,
  signal,
  network,
  allowUnauthorized = false,
}: {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string | Uint8Array;
  signal?: AbortSignal;
  network?: Network;
  allowUnauthorized?: boolean;
}) {
  const validated = z
    .url()
    .refine((u) => new URL(u).protocol === "https:")
    .parse(url);
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timer = setTimeout(abort, 30000);
  try {
    const response = await clientFetch(validated, {
      method,
      headers,
      body: body instanceof Uint8Array ? new Uint8Array(body).buffer : body,
      credentials: "omit",
      redirect: "manual",
      signal: controller.signal,
    });
    if (!allowUnauthorized && (response.status === 401 || response.status === 403))
      throw socialError({
        message: `${network ? networkNames[network] : "This account"} needs to reconnect. Open Settings to sign in again.`,
      });
    if (response.status === 429)
      throw socialError({
        message: `${network ? networkNames[network] : "The service"} is limiting requests. Wait a few minutes and try again.`,
      });
    return response;
  } catch (error) {
    if (error instanceof Error && error.name === "SocialError") throw error;
    throw socialError({
      message: signal?.aborted
        ? "Request cancelled."
        : "Couldn't connect. Check your internet connection and try again.",
    });
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", abort);
  }
}
export async function json({
  response,
  network,
}: {
  response: Awaited<ReturnType<typeof request>>;
  network: Network;
}) {
  if (!response.ok)
    throw socialError({
      message: `${networkNames[network]} returned an error (${response.status}). Please try again later.`,
    });
  try {
    return z.record(z.string(), z.unknown()).parse(await response.json());
  } catch {
    throw socialError({
      message: `${networkNames[network]} returned an unfamiliar response. Reconnect in Settings if this continues.`,
    });
  }
}
export { selectedResponseCookies } from "./cookies";
