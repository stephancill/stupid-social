import { expect, test } from "bun:test";
import {
  instagramProfileRouteID,
  instagramProfileVariables,
  instagramProfileUser,
  instagramProfilePosts,
} from "../src/instagram/profile";
import { instagramProfile, instagramPost } from "../src/instagram/parsers";

const runtime = {
  gkx: {
    "17028": { result: false },
    "6793": { result: true },
    "17363": { result: false },
    "9448": { result: true },
    "12774": { result: false },
    "684": { result: false },
  },
  qex: {
    "1697": { r: null },
    "3668": { r: null },
    "2404": { r: true, l: "quoted } value" },
    "684": { r: true },
  },
};
const page = (value: unknown) =>
  `<script type="application/json" data-sjs>${JSON.stringify(value)}</script>`;
test("profile route resolution ignores viewer and unrelated IDs", () => {
  expect(
    instagramProfileRouteID({
      html: page({
        viewer: { id: "42" },
        initialRouteInfo: {
          route: {
            rootView: { props: { id: "99", page_logging: { params: { profile_id: "99" } } } },
          },
        },
      }),
    }),
  ).toBe("99");
  expect(() => instagramProfileRouteID({ html: page({ viewer: { id: "42" } }) })).toThrow(
    "unavailable",
  );
});
test("Relay variables distinguish gates from experiments with the same ID", () => {
  const variables = instagramProfileVariables({ html: page(runtime), posts: true });
  expect(variables.__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider).toBe(
    true,
  );
  expect(variables.__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider).toBe(
    false,
  );
  expect(variables.__relay_internal__pv__PolarisShortDramaEnabledrelayprovider).toBe(false);
  expect(
    instagramProfileVariables({ html: page(runtime) })
      .__relay_internal__pv__PolarisCannesGuardianExperienceEnabledrelayprovider,
  ).toBe(true);
  const experiment = structuredClone(runtime);
  Object.assign(experiment.qex["1697"], { r: true });
  Object.assign(experiment.qex["3668"], { r: true });
  expect(
    instagramProfileVariables({ html: page(experiment) })
      .__relay_internal__pv__PolarisShortDramaEnabledrelayprovider,
  ).toBe(true);
  expect(() => instagramProfileVariables({ html: page({}) })).toThrow("configuration");
});
test("profile identity is validated and current counts and relationships are retained", () => {
  const data = {
    data: {
      user: {
        pk: "99",
        username: "example",
        follower_count: 12,
        following_count: 5,
        media_count: 3,
        friendship_status: { following: true, followed_by: true },
      },
    },
  };
  const profile = instagramProfile({ value: instagramProfileUser({ data, id: "99" }) });
  expect([
    profile.followers,
    profile.following,
    profile.posts,
    profile.isFollowing,
    profile.followsYou,
  ]).toEqual([12, 5, 3, true, true]);
  expect(() => instagramProfileUser({ data, id: "42" })).toThrow("invalid profile");
  expect(() => instagramProfileUser({ data: { data: { user: null } }, id: "99" })).toThrow();
});
test("posts connection preserves media, opaque cursors, and empty private profiles", () => {
  const connection = {
    edges: [
      {
        node: {
          pk: "10",
          user: { pk: "99", username: "example" },
          code: "post",
          media_type: 1,
          caption: { text: "Hello" },
          image_versions2: { candidates: [{ url: "https://example.org/image.jpg", width: 100 }] },
        },
      },
    ],
    page_info: { has_next_page: true, end_cursor: "opaque+cursor/==" },
  };
  const data = { data: { xdt_api__v1__feed__user_timeline_graphql_connection: connection } };
  const result = instagramProfilePosts({ data });
  expect(result.nextCursor).toBe("opaque+cursor/==");
  expect(instagramPost({ value: result.items[0] }).text).toBe("Hello");
  expect(
    instagramProfilePosts({
      data: {
        data: {
          xdt_api__v1__feed__user_timeline_graphql_connection: {
            edges: [],
            page_info: { has_next_page: false, end_cursor: null },
          },
        },
      },
    }),
  ).toEqual({ items: [], nextCursor: undefined });
  expect(() =>
    instagramProfilePosts({
      data: {
        data: {
          xdt_api__v1__feed__user_timeline_graphql_connection: {
            edges: [],
            page_info: { has_next_page: true, end_cursor: null },
          },
        },
      },
    }),
  ).toThrow("next posts page");
  expect(() => instagramProfilePosts({ data: { data: {} } })).toThrow();
});
