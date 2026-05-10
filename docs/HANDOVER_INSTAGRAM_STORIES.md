# Instagram Stories — Handover Notes

## Status

Stories tray fetching, rendering, batch media fetching, and server-side seen marking all work.

## What Works

- `POST /api/v1/feed/reels_tray/` — returns active stories + highlight reels
- `GET /api/v1/feed/user/{userId}/story/` — returns individual story media (images, videos)
- `POST /api/v1/feed/reels_media/` — batch-fetches full story media for multiple reel IDs using `reel_ids=["..."]`
- Authentication via cookie header (`ds_user_id`, `csrftoken`, `sessionid`, `mid`)
- User agent: `Instagram 416.0.0.47.66 Android (35/35; 480dpi; 1080x2400; samsung; SM-S938U; qcom; en_US; 718621835)`
- App ID: `567067343352427` (Android app)
- Login via WKWebView with mobile user agent (`Nexus 5 / Chrome 147`)
- Cookies stored in iCloud Keychain with `rur`, `igDid`, `mid`, `sessionId`, `csrfToken`, `dsUserId`
- `InstagramTrayItem.id` decodes both int (regular stories) and string (highlight rewind `highlightRewind:xxx`)
- Stories deduplicated by user PK
- `InstagramStoryReel.seen` tracks the API tray `seen` field; unread stories sorted first with gradient ring

## Batch Story Media Endpoint (IMPLEMENTED)

`POST /api/v1/feed/reels_media/` is now used in `InstagramNotificationSource.fetchStoryReels()` instead of per-user `GET /api/v1/feed/user/{userId}/story/`. The tray endpoint still supplies ordering, user metadata, and `seen`.

- `reel_ids` must be a JSON array string such as `["5682861498"]`; plain `5682861498` and `reel_ids[]=...` return `400 Invalid reel id list`.
- Response shape is `{ "reels": { "<reel_id>": { ...reel... } }, "status": "ok" }`.
- Returned reels include `seen`, `items`, `items[].id`, `items[].pk`, `items[].taken_at`, `items[].media_type`, `items[].image_versions2.candidates`, `items[].video_versions`, and `items[].user.pk`.
- A curl test against 5 unique active tray reel IDs returned all 5 reels, all with non-empty `items`, 12 usable image URLs, and 12 usable video URLs.
- Duplicate/highlight tray entries collapse to one response per reel ID. This is fine for current behavior because the app already deduplicates by user PK.

## Story Seen Marking — RESOLVED

Working request shape found by tracing `instagram-private-api` source code:

```
POST /api/v2/media/seen/?reel=1&live_vod=0
Content-Type: application/x-www-form-urlencoded

ig_sig_key_version=4&signed_body=<hmac_sha256_hex>.<json>
```

Three fixes were needed beyond the original APK analysis:

1. **Endpoint**: `/api/v2/media/seen/` (not v1)
2. **Compound key**: `<mediaId>_<ownerId>` (e.g., `3893660934892232546_5682861498_5682861498`), not the APK-derived `owner_owner_reel:media` format
3. **HMAC key**: `9193488027538fd3450b83b7d05286d4ca9599a0f7eeed90d8c85925698a05dc` from `instagram-private-api/dist/core/constants.js`, different from earlier tested key

Required signed-body fields: `reels`, `container_module`, `reel_media_skipped`, `live_vods`, `live_vods_skipped`, `nuxes`, `nuxes_skipped`, `_uuid`, `_uid`, `_csrftoken`, `device_id`.

Swift implementation in `InstagramClient.markStorySeen(mediaItems:)` uses `CryptoKit.HMAC<SHA256>`.

Live curl test confirmed `sai.k1065` tray `seen` updated from `0` to `1778380574`.

### Previous Non-Working Attempts (Reference)

| What was wrong | Correct |
|---|---|
| Endpoint `POST /api/v1/media/seen/` | `POST /api/v2/media/seen/` |
| Compound key `owner_owner_reel:media` | `media.id_sourceId` |
| HMAC key `25eace53...` | `91934880...` |
| Missing `reel_media_skipped`, `_uid`, `device_id` etc. | All required fields present |
- If server-side seen cannot be replicated, implement local seen tracking in `UserDefaults` as the product fallback.

## Key Files

| File | Purpose |
|------|---------|
| `Sources/NoFeedSocialCore/Sources/InstagramClient.swift` | HTTP client, tray fetch, story media fetch |
| `Sources/NoFeedSocialCore/Sources/InstagramNotificationSource.swift` | `fetchStoryReels()`, story normalization |
| `Sources/NoFeedSocialCore/Models/AppModels.swift` | `InstagramStoryReel`, `InstagramStorySlide` |
| `Sources/NoFeedSocial/Views/InstagramStoryViewer.swift` | Full-screen story viewer with swipe nav |
| `Sources/NoFeedSocial/Views/FeedView.swift` | `StoriesBar`, `InstagramStoryBubble` |
| `Sources/NoFeedSocialCore/ViewModels/FeedViewModel.swift` | `fetchInstagramStories()`, sort/seen logic |
| `Sources/NoFeedSocialCore/Storage/CookieHeaderParser.swift` | `InstagramCredentials` model |
| `Sources/NoFeedSocial/Views/InstagramLoginWebView.swift` | WKWebView login flow |
