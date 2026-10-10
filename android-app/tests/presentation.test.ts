import { expect, test } from "bun:test";
import { notificationSchema, storyReelSchema, accountSchema } from "../src/app/models";
import {
  notificationCopy,
  sortedStories,
  notificationActivity,
  profileCount,
  likeCount,
} from "../src/app/presentation";
import { parseGitHubFeed } from "../src/github/parser";
const actor = { network: "x", id: "1", name: "Display name", username: "handle" };
const base = {
  id: "1",
  network: "x",
  accountId: "viewer",
  timestamp: 1,
  actors: [actor],
  event: "like",
  category: "reactions",
  text: "Display name liked your post",
};
test("iOS row copy uses usernames, correct aggregate grammar, and tweet wording", () => {
  const item = notificationSchema.parse({
    ...base,
    actors: [actor, { ...actor, id: "2", username: "other" }],
    text: "Display name and 1 other liked your post",
  });
  const copy = notificationCopy({ item });
  expect(copy.summary).toBe("handle and 1 other liked your tweet");
  expect(copy.leadingActor).toBe(true);
  expect(copy.remainder).toBe(" liked your tweet");
});
test("follow rows suppress previews; shared messages use their thumbnail", () => {
  const post = {
    id: "post",
    text: "Sent a reel",
    url: "https://example.com",
    images: ["https://example.com/image.jpg"],
  };
  expect(
    notificationCopy({ item: notificationSchema.parse({ ...base, category: "follows", post }) })
      .preview,
  ).toBeUndefined();
  expect(
    notificationCopy({ item: notificationSchema.parse({ ...base, category: "messages", post }) })
      .image,
  ).toBe(post.images[0]);
  expect(
    notificationCopy({
      item: notificationSchema.parse({
        ...base,
        category: "replies",
        post: { ...post, text: "A reply" },
      }),
    }).preview,
  ).toBe("A reply");
});
test("story bar places unseen people before seen people and sorts each section by time", () => {
  const reel = {
    id: "1",
    network: "instagram",
    accountId: "viewer",
    actor,
    timestamp: 1,
    seen: false,
    slides: [],
  };
  const reels = [
    storyReelSchema.parse({ ...reel, id: "seen", seen: true, timestamp: 10 }),
    storyReelSchema.parse(reel),
    storyReelSchema.parse({ ...reel, id: "new", timestamp: 2 }),
  ];
  expect(sortedStories({ reels }).map((r) => r.id)).toEqual(["new", "1", "seen"]);
});
test("GitHub cards retain visible repository metadata for the iOS story layout", () => {
  const meta = {
    card_type: "STARRED_REPOSITORY",
    record_id: "1",
    resource_id: "repo",
    created_at: "2026-09-18T10:00:00Z",
  };
  const hydro = (type: string, id: string) =>
    JSON.stringify({
      payload: {
        feed_card: meta,
        metadata: { clicked_resource_type: type, clicked_resource_id: id },
      },
    }).replaceAll('"', "&quot;");
  const html = `<article><a href="/alice" data-hydro-click="${hydro("USER", "alice")}"></a><div><a class="Link--primary Link text-bold" href="/demo/app" data-hydro-click="${hydro("REPO", "repo")}">demo/app</a></div><div>A useful library.</div><span class="repo-language-color" style="background-color: #F05138"></span><span itemprop="programmingLanguage">Swift</span><a aria-label="12,400 stargazers"></a></article>`;
  const result = parseGitHubFeed({
    html,
    account: accountSchema.parse({
      ...actor,
      network: "github",
      username: "viewer",
      connectedAt: 1,
    }),
  });
  expect(result.stories[0]!.slides[0]!.github).toMatchObject({
    kind: "starred",
    description: "A useful library.",
    language: "Swift",
    languageColor: "#F05138",
    stars: "12.4k",
  });
});

test("profile detail keeps location and website fields from existing payloads", async () => {
  const { parseProfile } = await import("../src/x/parsers");
  const { instagramProfile } = await import("../src/instagram/parsers");
  const x = parseProfile({
    raw: {
      rest_id: "1",
      core: { screen_name: "sample", name: "Sample" },
      location: { location: "Example City" },
      legacy: { entities: { url: { urls: [{ expanded_url: "https://example.com" }] } } },
    },
  });
  expect(x?.location).toBe("Example City");
  expect(x?.website).toBe("https://example.com");
  expect(
    instagramProfile({
      value: { pk: "1", username: "sample", external_url: "https://example.com" },
    }).website,
  ).toBe("https://example.com");
});
test("Instagram post detail preserves each carousel item's image and video", async () => {
  const { instagramPost } = await import("../src/instagram/parsers");
  const post = instagramPost({
    value: {
      pk: "1",
      code: "sample",
      user: { pk: "2", username: "sample" },
      carousel_media: [
        { image_versions2: { candidates: [{ url: "https://example.com/1.jpg" }] } },
        {
          image_versions2: { candidates: [{ url: "https://example.com/2.jpg" }] },
          video_versions: [{ url: "https://example.com/2.mp4" }],
        },
      ],
    },
  });
  expect(post.images).toHaveLength(2);
  expect(post.media).toEqual([
    { image: "https://example.com/1.jpg" },
    { image: "https://example.com/2.jpg", video: "https://example.com/2.mp4" },
  ]);
});
test("existing saved preferences keep Instagram stories enabled", async () => {
  const { preferencesSchema } = await import("../src/app/models");
  expect(
    preferencesSchema.parse({ categories: ["messages"], includeMediaShares: false }).storiesEnabled,
  ).toBe(true);
  expect(preferencesSchema.parse({ storiesEnabled: false }).storiesEnabled).toBe(false);
});

test("detail activity preserves the event sentence with iOS actor and post wording", () => {
  const item = notificationSchema.parse({
    ...base,
    category: "replies",
    text: "Display name replied to your post",
  });
  expect(notificationActivity({ item })).toBe("handle replied to your tweet");
});

test("detail counts preserve exact small values and iOS-specific compact precision", () => {
  expect(profileCount({ value: 197 })).toBe("197");
  expect(profileCount({ value: 132 })).toBe("132");
  expect(profileCount({ value: 1000 })).toBe("1.0K");
  expect(profileCount({ value: 12345 })).toBe("12.3K");
  expect(profileCount({ value: 1200000 })).toBe("1.2M");
  expect(likeCount({ value: 197 })).toBe("197");
  expect(likeCount({ value: 12345 })).toBe("12K");
});
