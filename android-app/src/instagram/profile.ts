import { z } from "zod";
import { object, text } from "../app/value";

export const instagramUsername = z
  .string()
  .trim()
  .transform((value) => value.replace(/^@/, ""))
  .pipe(z.string().regex(/^[A-Za-z0-9._]+$/));
const numericID = z.string().regex(/^\d+$/);

function pageDictionaries({ html }: { html: string }) {
  const dictionaries: Record<string, unknown>[] = [];
  function walk(value: unknown) {
    if (Array.isArray(value)) return value.forEach(walk);
    if (!value || typeof value !== "object") return;
    const dictionary = value as Record<string, unknown>;
    dictionaries.push(dictionary);
    Object.values(dictionary).forEach(walk);
  }
  for (const match of html.matchAll(/<script\b[^>]*\bdata-sjs[^>]*>(.*?)<\/script>/gs)) {
    try {
      walk(JSON.parse(match[1]!));
    } catch {
      continue;
    }
  }
  return dictionaries;
}

export function instagramProfileRouteID({ html }: { html: string }) {
  for (const dictionary of pageDictionaries({ html })) {
    const route = object(object(dictionary.initialRouteInfo).route);
    const props = object(object(route.rootView).props);
    if (!("profile_id" in object(object(props.page_logging).params))) continue;
    const result = numericID.safeParse(props.id);
    if (result.success) return result.data;
  }
  throw new Error("This Instagram profile is unavailable.");
}

export function instagramProfileVariables({
  html,
  posts = false,
}: {
  html: string;
  posts?: boolean;
}) {
  const dictionaries = pageDictionaries({ html });
  function config({ id, field }: { id: string; field: string }) {
    for (const dictionary of dictionaries) {
      const value = object(dictionary[id]);
      if (field in value) return value[field];
    }
    throw new Error("Instagram profile configuration is missing. Reconnect and try again.");
  }
  const gate = (id: string) => z.boolean().parse(config({ id, field: "result" }));
  const providers: Record<string, boolean> = {
    PolarisShortDramaEnabled:
      config({ id: "1697", field: "r" }) === true
        ? config({ id: "3668", field: "r" }) === true
        : gate("12774"),
  };
  if (posts) {
    providers.PolarisMultiCaptionCarouselEnabled = config({ id: "2404", field: "r" }) === true;
    providers.PolarisReelsRecoDebugOverlayEnabled = gate("684");
  } else {
    for (const [name, id] of Object.entries({
      PolarisCASB976ProfileEnabled: "17028",
      PolarisCannesGuardianExperienceEnabled: "6793",
      PolarisWebSchoolsEnabled: "17363",
      PolarisRepostsConsumptionEnabled: "9448",
    }))
      providers[name] = gate(id);
  }
  return Object.fromEntries(
    Object.entries(providers).map(([name, value]) => [
      `__relay_internal__pv__${name}relayprovider`,
      value,
    ]),
  );
}

export function instagramProfileUser({ data, id }: { data: unknown; id: string }) {
  const user = object(object(object(data).data).user);
  if (
    text(user.pk ?? user.id) !== numericID.parse(id) ||
    !instagramUsername.safeParse(user.username).success
  )
    throw new Error("Instagram returned an invalid profile.");
  return user;
}

export function instagramProfilePosts({ data }: { data: unknown }) {
  const connection = z
    .object({
      edges: z.array(z.object({ node: z.record(z.string(), z.unknown()) })),
      page_info: z.object({ has_next_page: z.boolean(), end_cursor: z.string().nullable() }),
    })
    .parse(object(object(data).data).xdt_api__v1__feed__user_timeline_graphql_connection);
  if (connection.page_info.has_next_page && !connection.page_info.end_cursor)
    throw new Error("Instagram did not provide the next posts page.");
  return {
    items: connection.edges.map(({ node }) => node),
    nextCursor: connection.page_info.has_next_page ? connection.page_info.end_cursor! : undefined,
  };
}
