# Technical Design

## Purpose

This document is the source of truth for planned implementation details. `docs/PLAN.md` remains the source of truth for product requirements.

Implementation work should follow this document unless `docs/PLAN.md` changes or an implementation note records a deliberate deviation.

## Current Scope

The MVP is a universal macOS and iOS SwiftUI app built with xtool. It supports a combined notifications feed for one X account and one Farcaster account.

Out of scope for this technical design:

- Posting and cross-posting.
- Bluesky and Instagram.
- Multiple accounts per network.
- Backend services.
- Full notification item sync across devices.

## Architecture

Use a simple MVVM architecture.

- SwiftUI views own presentation and platform-native UI structure.
- View models expose observable state and user actions.
- Network integrations live behind source-specific clients and adapters.
- Shared feed assembly and read-state logic should stay outside views.
- Prefer small, direct types over broad generic abstractions.

Suggested high-level modules:

- `App`: app entry point, scene setup, dependency construction.
- `Views`: SwiftUI screens and reusable view components.
- `ViewModels`: observable view models for feed, settings, account detail, and refresh state.
- `Models`: normalized app models and persisted SwiftData models.
- `Sources`: network source protocols and source-specific adapters.
- `Storage`: Keychain, UserDefaults, SwiftData, and iCloud KVS helpers.
- `Support`: logging, date handling, errors, and small utilities.

## UI Design

Use built-in SwiftUI and platform primitives wherever possible.

- Feed: a single chronological `List` with network badges and unread styling.
- Settings: minimal `Form` for account setup/status.
- Account detail: simple detail screen with avatar, name, follower count, and following count.
- Actions: standard toolbar/menu buttons for refresh and `Mark all as read`.
- Avoid custom controls, bespoke styling, and non-native interaction patterns unless the plan changes.

## Data Model

Use a minimal normalized notification display model.

Suggested app model:

```swift
struct NotificationItem: Identifiable, Hashable {
    let id: String
    let network: SocialNetwork
    let accountId: String
    let sourceId: String?
    let type: NotificationType
    let timestamp: Date
    let text: String
    let actors: [NotificationActor]
    let target: NotificationTarget?
}
```

`isUnread` should be derived from read watermarks, not persisted as source truth.

Suggested supporting models:

```swift
enum SocialNetwork: String, Codable {
    case x
    case farcaster
}

struct NotificationActor: Hashable, Codable {
    let id: String
    let network: SocialNetwork
    let username: String?
    let displayName: String?
    let avatarURL: URL?
}

struct NotificationTarget: Hashable, Codable {
    let id: String
    let text: String?
    let url: URL?
}
```

Keep source-specific response models separate from normalized app models.

## Local Persistence

Use SwiftData for local notification cache.

- Cache notification items locally per device.
- Do not sync notification items through iCloud in the MVP.
- Retain cached notifications for 24 hours.
- Cache only display-safe normalized data needed for the feed and detail views.
- Do not persist raw source payloads unless a future implementation note documents a specific need.

Use UserDefaults for non-secret account metadata.

Examples:

- Configured account identifiers.
- Account display handles/usernames.
- Last successful refresh timestamps.
- Basic account status flags.

Do not store secrets in UserDefaults.

## Credentials

Use iCloud Keychain for credentials.

Credential access behavior:

- Synchronizable across the user's Apple devices.
- Accessible after first device unlock.
- If iCloud Keychain sync is unavailable, save credentials locally and surface local-only sync status.
- Simulator development builds may use non-synchronizable local Keychain storage so account setup and service testing can be exercised without iCloud Keychain entitlements.

X credential handling:

- User pastes a full browser `Cookie` header.
- Parse selected required cookie values from the header.
- Persist only the selected required cookie values, especially `auth_token` and `ct0`.
- Discard the raw cookie header after extraction.

Farcaster credential handling:

- No Farcaster secret is required for MVP notification reads.
- Store only non-secret username/FID metadata outside Keychain.

Never log credentials, cookie headers, tokens, or derived auth values.

## Read State

Read state is explicit only.

- Opening the app does not mark notifications read.
- Opening the feed does not mark notifications read.
- Refreshing does not mark notifications read.
- Opening notification detail does not mark notifications read.
- `Mark all as read` advances read state.

Use `NSUbiquitousKeyValueStore` for read watermark sync.

If iCloud KVS is unavailable, fall back to local-only `UserDefaults` storage for the same watermark keys.

Suggested key format:

```text
readWatermark.<network>.<accountId>
```

Suggested value shape:

```json
{
  "network": "x",
  "accountId": "...",
  "lastReadAt": "2026-04-27T00:00:00Z",
  "updatedAt": "2026-04-27T00:00:00Z"
}
```

Unread evaluation:

- App-read when `notification.timestamp <= lastReadAt`.
- App-unread when `notification.timestamp > lastReadAt`.

`Mark all as read` should set the relevant watermark to the newest currently loaded notification timestamp for that account/network scope.

## Network Source Protocol

Model each notification source behind a common protocol.

Suggested protocol:

```swift
protocol NotificationSource {
    var network: SocialNetwork { get }

    func validateAccount() async throws -> AccountStatus
    func fetchUnreadCount() async throws -> Int?
    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem]
    func fetchProfile(id: String) async throws -> NetworkProfile
}
```

Source implementations may no-op or return `nil` for capabilities that do not exist.

Keep source-specific clients concrete behind adapters:

- `XClient`
- `XNotificationSource`
- `FarcasterClient`
- `FarcasterNotificationSource`

## X Integration

X must use a native Swift client. Do not shell out to `twitter-cli` in the production app path.

Known behavior from `docs/CLI_DOCS.md`:

- Count-only polling should not mark X notifications read.
- Full notification timeline fetch can mark fetched entries read server-side.

Implementation rule:

- Background refresh uses count-only behavior.
- Full X notification fetch happens only through explicit manual refresh.
- Opening the feed shows cached X items and count until manual refresh.

Endpoint discovery is a required implementation spike before building the X client.

The spike should document:

- Exact endpoint URLs.
- Required headers.
- Required cookies.
- Query ids or feature flags if applicable.
- Response shapes for count and notifications.
- Side effects observed during fetch.
- Any endpoint behavior that differs from `docs/CLI_DOCS.md`.

Record endpoint discoveries and side effects in `docs/IMPLEMENTATION.md` as work progresses.

## Farcaster Integration

Use Hypersnap at `https://haatz.quilibrium.com`.

Endpoints:

- Resolve username: `GET /v2/farcaster/user/by-username`
- Fetch notifications: `GET /v2/farcaster/notifications`

Notification query:

- Resolve username to FID during setup.
- Fetch notifications by `fid`.
- Support pagination with `cursor` when needed.

Known notification types:

- `cast-mention`
- `cast-reply`
- `reaction`
- `follow`

Hypersnap notification reads do not mark app read state. Hypersnap seen/write endpoints are not part of the MVP because they return `501 Not Implemented`.

## Decoding Strategy

Use strict `Codable` response models.

- Define source-specific response structs for each endpoint.
- Decode required fields strictly.
- Treat schema mismatches as integration errors.
- Normalize source responses into `NotificationItem` immediately after decoding.

If X endpoint responses prove unstable during the required spike, document the issue before changing this strategy.

## Feed Assembly

The feed view model should request data through a feed service rather than talking directly to network clients.

Feed service responsibilities:

- Load cached notifications from SwiftData.
- Trigger source refreshes according to user action or background policy.
- Normalize and merge source results.
- Apply 24-hour retention cleanup.
- Sort by timestamp descending.
- Derive feed `New` presentation from cache identity differences: items inserted into the local cache by refresh are new; previously cached items are known.

Manual refresh behavior:

- Fetch Farcaster notifications.
- Fetch X full notifications only because the user explicitly requested refresh.
- Merge results into local SwiftData cache.
- Compare incoming notification IDs against the local cache; mark only newly inserted items as new.

Open/feed-load behavior:

- Load cached notifications.
- Fetch or show latest counts where safe.
- Do not full-fetch X automatically.
- Do not advance read watermarks.

## Foreground Automatic Refresh

Use scene phase changes for automatic refresh when the app enters the foreground. Do not use `BGTaskScheduler` for the MVP refresh path.

Design expectations:

- Trigger an automatic refresh on `scenePhase == .active`.
- X foreground automatic refresh performs count-only polling.
- Farcaster foreground automatic refresh may fetch notifications because it does not alter server-side read state.
- Foreground automatic refresh updates local cache/count state and marks newly inserted notification IDs as pending.
- Pending notification items remain hidden from the visible feed until the user explicitly loads them from the feed's new-items badge/button.

## Account Status And Errors

Expose inline account status in settings.

Suggested statuses:

- Not configured.
- Valid.
- Invalid credentials.
- iCloud unavailable.
- Network unavailable.
- Service error.

Credential failures should show inline reconnect/update controls.

Errors should be user-actionable without exposing secrets or raw request data.

## Logging And Diagnostics

Use minimal `OSLog`.

- Never log secrets.
- Prefer privacy annotations and redaction.
- Log high-level events such as refresh start/success/failure and source status.
- Do not log request bodies, response bodies, cookie headers, tokens, or raw payloads.
- Do not write persistent file logs in the MVP.

## Testing Strategy

Require unit tests for core logic.

Unit test targets:

- Cookie header parsing and selected-cookie extraction.
- Hypersnap response decoding.
- X response decoding for `notifications/all.json` globalObjects + timeline entries.
- Source-specific normalization into `NotificationItem`.
- Read watermark evaluation.
- `Mark all as read` watermark updates.
- 24-hour cache retention behavior.
- Feed merge and sort behavior.

Add integration tests where practical.

- Network integration tests should be opt-in.
- Live tests must not require secrets in source control.
- Live tests must not log credentials or response bodies.
- Prefer sanitized fixtures for repeatable parser and normalization tests.

## Verification

After meaningful implementation changes, verify with the repository's build/test tooling.

Expected verification once the app is scaffolded:

- Swift tests pass.
- xtool build succeeds.
- xtool run behavior is checked when feasible.

## Future Posting

Posting is deferred entirely for this design.

Do not add composer models, posting protocols, or posting UI in the MVP unless `docs/PLAN.md` changes.
