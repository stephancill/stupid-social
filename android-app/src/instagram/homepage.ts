import { z } from "zod";
import { socialError } from "../app/models";
import { findObjects, object } from "../app/value";
import { instagramUsername } from "./profile";

const identifier = z
  .union([z.string().regex(/^[1-9]\d*$/), z.number().int().positive()])
  .transform(String);
const viewerSchema = z.object({ id: identifier, username: instagramUsername }).passthrough();
const traySchema = z
  .object({
    tray: z.array(
      z
        .object({
          id: identifier,
          user: z.object({ username: instagramUsername }).passthrough(),
        })
        .passthrough(),
    ),
  })
  .passthrough();

function pageObjects({ html }: { html: string }) {
  return [...html.matchAll(/<script\b[^>]*\bdata-sjs[^>]*>(.*?)<\/script>/gs)].flatMap((match) => {
    try {
      return [JSON.parse(match[1]!) as unknown];
    } catch {
      return [];
    }
  });
}
function viewerModule(value: unknown): unknown {
  if (Array.isArray(value)) {
    if (value[0] === "PolarisViewer") return object(value[2]).data;
    for (const child of value) {
      const found = viewerModule(child);
      if (found !== undefined) return found;
    }
  } else if (value && typeof value === "object") {
    for (const child of Object.values(value)) {
      const found = viewerModule(child);
      if (found !== undefined) return found;
    }
  }
}
export function instagramHomepageViewer({ html, accountID }: { html: string; accountID: string }) {
  const objects = pageObjects({ html });
  if (
    objects.some(
      (root) =>
        findObjects({ root, key: "is_logged_out_user" }).includes(true) ||
        findObjects({ root, key: "is_logged_out_user_ssr" }).includes(true),
    )
  )
    throw socialError({ message: "Instagram needs to reconnect. Open Settings to sign in again." });
  const raw = objects.map(viewerModule).find((value) => value !== undefined);
  const viewer = viewerSchema.safeParse(raw);
  if (!viewer.success)
    throw socialError({ message: "Instagram's homepage did not include the signed-in account." });
  if (viewer.data.id !== accountID)
    throw socialError({
      message:
        "Instagram's signed-in account does not match the saved credentials. Reconnect in Settings.",
    });
  return viewer.data;
}
export function instagramHomepageTray({ html, accountID }: { html: string; accountID: string }) {
  instagramHomepageViewer({ html, accountID });
  const raw = pageObjects({ html }).flatMap((root) =>
    findObjects({ root, key: "xdt_api__v1__feed__reels_tray" }),
  )[0];
  const tray = traySchema.safeParse(raw);
  if (!tray.success)
    throw socialError({
      message: "Instagram's homepage did not include a valid stories tray. Please try again later.",
    });
  return tray.data;
}
