# Architecture Refactor Plan

## Purpose

This plan captures the agreed architecture cleanup sequence for making the app easier to extend as the product grows beyond the original X/Farcaster notification MVP into Instagram stories/posting/DMs and Spotify activity.

The intent is not a rewrite. Each step should be small, behavior-preserving, and independently verifiable.

## Current Pressure Points

- `Sources/NoFeedSocial/Views/ContentView.swift:35-87` constructs stores, clients, sources, services, view models, and passes `SpotifyClient` directly into UI.
- `Sources/NoFeedSocialCore/ViewModels/FeedViewModel.swift:5-24` owns feed state, story bar state, Instagram own-story state, Spotify seen state, loading state, and errors.
- `Sources/NoFeedSocialCore/Sources/NotificationSource.swift:3-12` requires every source to implement validation, unread count, notification fetch, profile fetch, and target enrichment, even when those capabilities do not apply.
- `Sources/NoFeedSocialCore/Sources/SpotifyActivitySource.swift:40-46` conforms to `NotificationSource` only to return no unread count and no notifications.
- `Sources/NoFeedSocialCore/Sources/InstagramNotificationSource.swift:18-54` exposes story and posting capabilities outside the shared source protocol.
- `Sources/NoFeedSocialCore/Sources/InstagramClient.swift` is a large mixed-responsibility client containing session/bootstrap state, request construction, DTOs, story APIs, upload/delete/like behavior, and parsers.
- `Sources/NoFeedSocialCore/Services/FeedService.swift:14-15` tracks pending/revealed notification IDs in memory while `Sources/NoFeedSocialCore/Models/CachedNotification.swift:17-18` also has persisted `isNew` and `isPending` fields that are not wired through `NotificationCacheStore` snapshots.
- `Sources/NoFeedSocialCore/Storage/ReadWatermarkStore.swift:75-81` still defines timestamp-based unread evaluation for explicit read-state, while feed presentation uses cache-diff new/known state.

## Step 1: Add `AppContainer`

### Goal

Move dependency construction out of `ContentView` into a dedicated composition root.

### Justification

`ContentView` should be a SwiftUI routing/presentation view. It currently knows how to construct every store, client, source, service, and view model. That makes adding or replacing sources harder and causes UI files to understand core dependency wiring.

### Target Shape

Add a small container type in the app layer, for example:

```swift
@MainActor
final class AppContainer {
    let feedViewModel: FeedViewModel
    let settingsViewModel: SettingsViewModel
    let spotifyClient: SpotifyClient

    init(modelContext: ModelContext) {
        // construct stores, clients, sources, services, view models
    }
}
```

The container should own shared instances of:

- `AccountMetadataStore`
- `KeychainCredentialStore`
- `NotificationCacheStore`
- `ICloudReadWatermarkStore`
- network clients
- source adapters
- `FeedService`
- view models

`ContentView` should keep only a `@State private var container: AppContainer?` and call into container-provided view models.

### Migration Instructions

1. Add `Sources/NoFeedSocial/AppContainer.swift` or `Sources/NoFeedSocial/Support/AppContainer.swift`.
2. Move the body of `ContentView.configureDependencies()` into `AppContainer.init(modelContext:)`.
3. Keep the initial behavior identical: call `feed.loadCachedFeed()` during construction and fetch story bar content after the container is created.
4. Update `ContentView` to initialize the container once from `modelContext` and pass `container.feedViewModel`, `container.settingsViewModel`, and `container.spotifyClient` into `FeedView`.
5. Do not change source behavior, refresh behavior, or storage behavior in this step.

### Verification

- Run `swiftformat Sources/ Tests/`.
- Run `xtool dev build`.
- Launch/install with `xtool dev run --simulator --no-attach --no-logs --launch-timeout 420` unless explicitly skipped.

## Step 2: Split Feed View Model Responsibilities

### Goal

Separate notification-feed state from story bar state and story actions.

### Justification

`FeedViewModel` currently coordinates unrelated domains:

- feed load/refresh/reveal at `Sources/NoFeedSocialCore/ViewModels/FeedViewModel.swift:36-91`
- story bar fetching and pagination at `FeedViewModel.swift:101-167`
- Instagram story post/delete/like actions at `FeedViewModel.swift:169-221`
- Spotify seen persistence at `FeedViewModel.swift:255-292`
- optimistic Instagram story file writing and local state mutation at `FeedViewModel.swift:379-467`

This makes any story feature change risk touching feed refresh code and vice versa.

### Target Shape

Keep `FeedViewModel` focused on notification list state:

```swift
@MainActor
public final class FeedViewModel: ObservableObject {
    @Published public private(set) var items: [DisplayNotificationItem] = []
    @Published public private(set) var pendingNewCount = 0
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isForegroundRefreshing = false
    @Published public var errorMessage: String?
}
```

Introduce a story-focused model, for example:

```swift
@MainActor
public final class StoryBarViewModel: ObservableObject {
    @Published public private(set) var items: [StoryBarItem] = []
    @Published public private(set) var ownInstagramStoryActor: NotificationActor?
    @Published public private(set) var ownInstagramStoryReel: InstagramStoryReel?
    @Published public private(set) var contentLoaded = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isNextPageLoading = false
}
```

Move Instagram story mutations to a narrow action object if that keeps the story model smaller:

```swift
@MainActor
public final class InstagramStoryActions {
    func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws
    func deleteStory(mediaId: String, isVideo: Bool) async throws
    func setStoryLiked(mediaId: String, liked: Bool) async throws
}
```

Move Spotify seen persistence into `SpotifyActivitySeenStore` so it can be tested without UI state.

### Migration Instructions

1. Extract Spotify seen read/write logic from `FeedViewModel.swift:255-292` into `SpotifyActivitySeenStore`.
2. Add `StoryBarViewModel` and move story fetching, pagination, merging, seen marking, and viewer item helpers from `FeedViewModel` into it.
3. Move optimistic Instagram posting helpers into either `StoryBarViewModel` or `InstagramStoryActions`; prefer `InstagramStoryActions` if the story model becomes too large.
4. Update `AppContainer` to construct both `FeedViewModel` and `StoryBarViewModel`.
5. Update `FeedView` to observe both models.
6. Preserve current user-visible behavior: same story ordering, same own-story composer affordance, same pending-new notification behavior, same refresh-triggered story reload.

### Verification

- Run existing tests.
- Add focused tests for `SpotifyActivitySeenStore` if practical.
- Run `swiftformat Sources/ Tests/`.
- Run `xtool dev build`.
- Manually verify feed refresh, story bar loading, story pagination, Instagram story posting, story delete, story like, and Spotify seen state.

## Step 3: Split `NotificationSource` Into Capability Protocols

### Goal

Replace the broad `NotificationSource` protocol with small protocols that describe actual capabilities.

### Justification

The app is no longer made only of notification sources. Spotify is activity/story-bar content, not feed notifications. Instagram is both notifications and stories/posting. A single protocol forces fake methods and hides the product boundary between notifications, profiles, stories, and target details.

Unread count is not used in the current app path, so it should be removed rather than preserved as an abstraction.

### Target Shape

Replace `NotificationSource` with capability protocols:

```swift
public protocol SocialSource {
    var network: SocialNetwork { get }
}

public protocol AccountValidating: SocialSource {
    func validateAccount() async throws -> AccountStatus
}

public protocol NotificationFetching: SocialSource {
    func fetchNotifications(reason: RefreshReason) async throws -> [NotificationItem]
}

public protocol ProfileFetching: SocialSource {
    func fetchProfile(id: String) async throws -> NetworkProfile
}

public protocol NotificationTargetDetailFetching: SocialSource {
    func fetchTargetDetails(for item: NotificationItem) async throws -> NotificationTargetDetails
}
```

Rename `NotificationTargetMetrics` to `NotificationTargetDetails` because it contains author, text, image URLs, posted date, like count, and related targets, not just metrics.

Story and activity protocols should remain separate from notification fetching:

```swift
public protocol StoryFetching: SocialSource {
    var hasMoreStoryReels: Bool { get }
    func fetchStoryReels() async throws -> [InstagramStoryReel]
    func fetchNextStoryReelPage() async throws -> [InstagramStoryReel]
}

public protocol StoryPosting: SocialSource {
    func postPhotoStory(imageData: Data, width: Int, height: Int, mimeType: String) async throws
    func deleteStory(mediaId: String, isVideo: Bool) async throws
    func setStoryLiked(mediaId: String, liked: Bool) async throws
}

public protocol ActivityFetching: SocialSource {
    func fetchActivity(reason: RefreshReason) async throws -> [SpotifyActivityItem]
}
```

Expected conformances:

- `XNotificationSource`: `NotificationFetching`, `AccountValidating`, `ProfileFetching`, `NotificationTargetDetailFetching`
- `FarcasterNotificationSource`: `NotificationFetching`, `AccountValidating`, `ProfileFetching`, `NotificationTargetDetailFetching`
- `InstagramNotificationSource`: `NotificationFetching`, `AccountValidating`, `ProfileFetching`, `StoryFetching`, `StoryPosting`; optionally `NotificationTargetDetailFetching` only if it has a real supported implementation
- `SpotifyActivitySource`: `ActivityFetching`, `AccountValidating`, `ProfileFetching`
- `DebugNotificationSource`: `NotificationFetching`, `AccountValidating`

### Migration Instructions

1. Add the new protocols beside the existing `NotificationSource` protocol.
2. Rename `NotificationTargetMetrics` to `NotificationTargetDetails` and `fetchTargetMetrics` to `fetchTargetDetails` in a mechanical pass.
3. Make each source conform to the capability protocols it actually supports while temporarily keeping `NotificationSource` if needed to avoid a large one-shot change.
4. Change `FeedService` to accept:
   - `[any NotificationFetching]` for refreshes
   - `[any AccountValidating]` for health checks
   - `[SocialNetwork: any ProfileFetching]` for profile lookup
   - `[SocialNetwork: any NotificationTargetDetailFetching]` for target detail lookup
5. Remove `fetchUnreadCount()` from protocols and sources once no callers remain.
6. Change `SpotifyActivitySource` so it no longer conforms to notification fetching.
7. Delete the old `NotificationSource` protocol after all callers are migrated.

### Verification

- Use grep to confirm `fetchUnreadCount` has no remaining source or caller references unless a new feature explicitly reintroduces it.
- Use grep to confirm `NotificationSource` has been removed or is only a temporary compatibility alias during the same migration.
- Run existing tests.
- Run `swiftformat Sources/ Tests/`.
- Run `xtool dev build`.

## Step 4: Extract Instagram Client Parser, DTO, And Session Files

### Goal

Split `InstagramClient.swift` into files organized by reason to change.

### Justification

`Sources/NoFeedSocialCore/Sources/InstagramClient.swift` is currently 2,177 lines and combines independent concerns:

- category definitions and client state at `InstagramClient.swift:4-56`
- notification and DM request paths at `InstagramClient.swift:104-153`
- story tray and story page request paths at `InstagramClient.swift:155-220`
- response models starting around `InstagramClient.swift:945`
- notification parser starting around `InstagramClient.swift:1766`

This makes endpoint changes risky and makes parser testing harder than necessary.

### Target Shape

Prefer file-level extraction before introducing new abstractions:

- `InstagramClient.swift`: public client facade and high-level API methods
- `InstagramSession.swift`: bootstrap state, web state, headers, cookie/header helpers, doc ID discovery/session request helpers
- `InstagramNotificationModels.swift`: notification/news/direct DTOs
- `InstagramStoryModels.swift`: tray/story/page DTOs
- `InstagramProfileModels.swift`: profile/current-user DTOs
- `InstagramNotificationParser.swift`: news inbox normalization
- `InstagramDirectMessageParser.swift`: direct inbox normalization
- `InstagramStoryParser.swift`: story-page payload extraction and slide mapping, if this becomes large enough

Keep public app models in `Sources/NoFeedSocialCore/Models/` and source-specific response DTOs in `Sources/NoFeedSocialCore/Sources/Instagram...` files.

### Migration Instructions

1. Start with pure moves: extract private DTOs and parser enums without changing behavior.
2. Keep access control as restrictive as possible. Use `private` when same-file, `fileprivate` only when required, and internal by default only for cross-file source DTOs.
3. Move parser code and add or update parser tests if fixtures already exist.
4. Extract session/request helpers after DTO/parser moves are stable.
5. Avoid broad protocol abstractions during this step; the main win is separating endpoint/session/parser concerns.

### Verification

- Run parser/unit tests after each extraction chunk.
- Run `swiftformat Sources/ Tests/`.
- Run `xtool dev build`.
- If Instagram credentials are available in the simulator, manually verify current user, notifications, direct messages, story tray, story view, story post, story like, and story delete.

## Step 5: Clean Up New/Pending/Unread Semantics

### Goal

Make feed presentation state explicit and remove contradictory read/new terminology.

### Justification

The product requirements say read state is explicit and app-local read watermarks exist, but current feed presentation uses cache-diff identity state for the `New` boundary. The code currently mixes terms:

- `DisplayNotificationItem.isUnread` in `Sources/NoFeedSocialCore/Models/AppModels.swift:196-207`
- in-memory `pendingIds` and `revealedIds` in `Sources/NoFeedSocialCore/Services/FeedService.swift:11-12`
- persisted `CachedNotification.isNew` and `CachedNotification.isPending` in `Sources/NoFeedSocialCore/Models/CachedNotification.swift:17-18`
- timestamp watermark unread logic in `Sources/NoFeedSocialCore/Storage/ReadWatermarkStore.swift:75-81`

The architecture should make it obvious whether a row is:

- app-read/app-unread by explicit watermark
- newly inserted by a refresh
- pending until the user taps the new-items affordance
- merely recent cached content

### Target Shape

Rename display state away from unread if it is not watermark-based. The implemented minimal Phase 5 path uses `isNew`:

```swift
public struct DisplayNotificationItem: Identifiable, Hashable {
    public let item: NotificationItem
    public let isNew: Bool
}
```

A future cleanup could replace the boolean with a small presentation enum:

```swift
public struct DisplayNotificationItem: Identifiable, Hashable {
    public let item: NotificationItem
    public let presentationState: NotificationPresentationState
}

public enum NotificationPresentationState: Hashable, Sendable {
    case new
    case known
}
```

If explicit unread watermarks are reintroduced in the visible UI, model that separately:

```swift
public struct DisplayNotificationItem: Identifiable, Hashable {
    public let item: NotificationItem
    public let isAppUnread: Bool
    public let presentationState: NotificationPresentationState
}
```

Decide whether pending/new state is persistent or session-only:

- If session-only, remove `CachedNotification.isNew` and `CachedNotification.isPending` in a safe SwiftData migration-aware way.
- If persistent, teach `NotificationCacheStore` to load and save a cache snapshot that includes those fields instead of dropping them when converting to `NotificationItem`.

### Migration Instructions

1. Document the chosen semantics before editing code: current behavior appears to use cache-diff `new`, not watermark `unread`, for the visible separator.
2. Rename `DisplayNotificationItem.isUnread` to `isNew` or replace it with `NotificationPresentationState`. Phase 5 chose `isNew` for minimal behavior-preserving cleanup.
3. Rename `unreadItems` and `readItems` in `FeedView.swift:224-230` to `newItems` and `knownItems` if they remain cache-diff based.
4. Decide whether `CachedNotification.isNew` and `isPending` are used. Either wire them through `NotificationCacheStore` or remove them in a migration-safe way. Phase 5 left the persisted fields unchanged because they are unused and removing them requires migration-aware cleanup.
5. If read watermarks are not used in the visible feed, keep `ReadWatermarkStore` only for future explicit read features or remove visible read terminology from feed code.
6. Update tests to assert the intended cache-diff behavior: manual refresh reveals new items immediately; foreground refresh keeps new items pending until revealed; opening cached feed does not mark items new.

### Verification

- Add or update unit tests for manual refresh, foreground pending refresh, reveal pending notifications, and cached-feed load.
- Run existing tests.
- Run `swiftformat Sources/ Tests/`.
- Run `xtool dev build`.
- Manually verify the `N New` toolbar affordance and the `New` separator behavior.

## General Migration Rules

- Keep each step behavior-preserving unless a step explicitly changes terminology or state semantics.
- Prefer small mechanical moves before semantic changes.
- Keep public protocols minimal and capability-based.
- Avoid backward compatibility code unless needed for persisted data, shipped behavior, or explicit requirements.
- When changing SwiftData models, provide default values for new properties and handle existing installed caches safely.
- Update `docs/IMPLEMENTATION.md` after each implemented step with what changed, any deviations, and verification performed.
