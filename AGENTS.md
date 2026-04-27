# Project Conventions

## Required Context

- Always read `docs/PLAN.md` before making product, architecture, or implementation decisions.
- Treat `docs/PLAN.md` as the source of truth for current requirements.
- Record implementation decisions, tradeoffs, endpoint discoveries, and notable deviations in `docs/IMPLEMENTATION.md` as work progresses.
- Keep `docs/IMPLEMENTATION.md` factual and chronological enough that another agent can resume work without re-discovering context.

## Product Direction

- This is a universal macOS and iOS app built with xtool.
- The MVP is notifications-only for X and Farcaster.
- The app should help users avoid algorithmic feeds while still seeing direct social notifications.
- Posting, Bluesky, Instagram, multiple accounts, and backend services are future scope unless `docs/PLAN.md` changes.

## Apple App Conventions

- Prefer SwiftUI for shared macOS and iOS UI.
- Keep UI very simple, restrained, and aligned with Apple's Human Interface Guidelines.
- Prefer built-in SwiftUI and platform UI primitives over custom controls, custom styling, or bespoke interaction patterns.
- Keep platform-specific code isolated behind small adapters or conditional compilation.
- Prefer native Apple APIs over extra dependencies unless the dependency clearly reduces risk or complexity.
- Preserve a universal app structure that can run on both macOS and iOS through xtool.
- Verify xtool build/run behavior after meaningful project changes when feasible.

## State And Storage

- Store credentials in iCloud Keychain.
- Never persist raw X cookie headers after extracting the required selected cookie values.
- Never log credentials, cookie headers, tokens, or derived auth values.
- Sync read watermarks with `NSUbiquitousKeyValueStore`.
- Keep notification item cache local-only for the MVP.
- Keep the normalized notification schema minimal unless `docs/PLAN.md` is updated.

## Network Integration

- Implement X as a native Swift client using `docs/CLI_DOCS.md` and the patched `twitter-cli` behavior as references only.
- Do not shell out to `twitter-cli` for the production app path.
- X background polling must use count-only behavior to avoid marking notifications read server-side.
- X full notification fetch must be explicit manual refresh only.
- Use Hypersnap at `https://haatz.quilibrium.com` for Farcaster reads.
- Resolve Farcaster usernames with `GET /v2/farcaster/user/by-username`.
- Fetch Farcaster notifications with `GET /v2/farcaster/notifications`.

## Read State

- Read state is explicit only.
- Opening the app, refreshing the feed, or opening notification detail must not mark notifications read.
- Only explicit user actions such as `Mark all as read` can advance a read watermark.
- Derive unread state from per-network/account timestamp watermarks.

## Engineering Style

- Prefer small, direct changes over broad abstractions.
- Keep adapters narrow and source-specific normalization explicit.
- Avoid backward compatibility code unless required by persisted data, shipped behavior, or an explicit requirement.
- Add comments only when code is not self-explanatory.
- Keep secrets out of logs, diagnostics, fixtures, screenshots, and documentation examples.

## Documentation

- Update `docs/PLAN.md` when requirements change.
- Update `docs/IMPLEMENTATION.md` when implementation choices are made or changed.
- Keep API endpoint assumptions, response quirks, and side effects documented.
- If behavior differs from the plan, record the reason and whether it is temporary or intentional.
