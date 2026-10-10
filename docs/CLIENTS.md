# Shared TypeScript clients

The X, Instagram, GitHub, Spotify and Bluesky development clients run with Bun and import the Expo app's production clients directly. Request construction, response parsing, selected cookies, refreshes, Relay discovery and DPoP signing live in `android-app/src/`. CLI adapters live in `android-app/scripts/clients/`. The five root entry points are `scripts/<network>-web-client.ts`.

## Setup and usage

Install the existing Expo dependencies, then run commands from the repository root:

```sh
cd android-app
bun install
cd ..
bun scripts/x-web-client.ts --help
bun scripts/instagram-web-client.ts profile-web --help
```

Authenticated commands require exactly one source:

- `--simulator`: read only the selected network's native Swift simulator session. Defaults to the project's preferred simulator; override with `--udid <device>`. Requires macOS, a booted simulator and an existing local fallback session in the native app.
- `--credentials-file <path>`: read an Expo credentials object or native Swift credentials JSON. `-` reads stdin. Native numeric dates use Apple's reference epoch; Expo expiry fields use Unix milliseconds as strings. Native Bluesky keys are converted from base64 to base64url. Use a private local file outside version control.
- `--cookie-header-file <path>`: extract only the relevant cookies from a browser Cookie header. `-` reads stdin. Available for X, Instagram, GitHub and Spotify; Bluesky needs its OAuth session and DPoP private key.

The probes keep cookie/token rotation in memory. Use `--save-credentials <path>` to persist the resulting Expo-shaped credentials, including rotation that succeeded before a later request failed. The file is replaced atomically with owner-only permissions. There is no automatic simulator writeback. For a reusable Bluesky probe session, use a dedicated app login/export and keep its rotated refresh token with `--save-credentials`; an expired copied OAuth session can rotate the original app's refresh token.

Results are JSON with credential fields, known credential values and JWTs redacted. `--summary` summarizes arrays; `--output <path>` also saves the full redacted JSON. `--raw-output` still redacts secrets. Only `--save-credentials` exports actual credentials. Request header overrides are `--user-agent` and `--accept-language`. Invalid arguments, missing required response fields and service failures exit nonzero.

Examples:

```sh
bun scripts/x-web-client.ts --simulator unread-count
bun scripts/instagram-web-client.ts --simulator current-user
bun scripts/instagram-web-client.ts --simulator profile-web example --posts
bun scripts/instagram-web-client.ts --simulator profile-web example --posts --cursor 'opaque-cursor'
bun scripts/github-web-client.ts --simulator feed --summary
bun scripts/spotify-web-client.ts --simulator validate-cookie-login
bun scripts/spotify-web-client.ts --simulator resolve-username
bun scripts/bluesky-web-client.ts --credentials-file /private/tmp/bluesky.json profile \
  --save-credentials /private/tmp/bluesky.json
```

## Commands and side effects

Use `<command> --help` for positional arguments and options. All 67 former Python commands are retained.

| Client | Commands |
| --- | --- |
| X | `bootstrap`, `account`, `notifications`, `load-notifications`, `unread-count`, `device-follow`, `profile`, `tweet`, `search-users`, `follow`, `unfollow`, `notify` |
| Instagram | `bootstrap`, `refresh`, `docids`, `activity`, `stories-tray`, `story-page`, `current-user`, `news-inbox`, `direct-inbox`, `profile-username`, `profile-web`, `profile-diagnosis`, `search-users`, `mention-search`, `story-seen`, `force-story-seen`, `like-media`, `unlike-media`, `like-story`, `unlike-story`, `follow`, `unfollow`, `upload-story-image`, `delete-story`, `graphql` |
| GitHub | `bootstrap`, `validate`, `notifications`, `feed`, `parse` |
| Spotify | `bootstrap`, `refresh-token`, `server-time`, `totp`, `buddylist`, `validate-cookie-login`, `profile-attributes`, `resolve-username`, `username`, `current-username`, `client-token`, `user-profile`, `search-users`, `following`, `followers`, `audio-analysis`, `track-preview`, `is-track-saved`, `save-track`, `remove-track`, `get` |
| Bluesky | `notifications`, `load-notifications`, `profile`, `post-thread` |

- X and Bluesky `notifications` read without advancing last-seen; `load-notifications` explicitly marks seen. X `unread-count` is the count-only probe. Reading an Instagram story page does not mark it seen.
- Instagram `news-inbox` marks activity read, matching the existing endpoint. `direct-inbox` does not mark conversations seen. `profile-diagnosis` checks the inbox, retired REST profile endpoint and profile page once each; it does not retry rejected endpoints.
- Instagram `current-user` and `stories-tray` read fresh authenticated homepage payloads, verify the viewer against the supplied account ID, and share overlapping page requests. They do not use the Direct inbox or standalone tray GraphQL request. `story-page` reads preloaded slides without marking them seen. A missing tray is an error; an empty tray is a successful result.
- Follow/unfollow/notify, story seen/likes/upload/delete and Spotify save/remove commands perform their named mutations. Generic Instagram `graphql` is an explicit endpoint experiment; its document ID determines side effects. No mutations happen from `--help`.
- `bootstrap` for X/GitHub/Spotify reports credential presence without requests. Instagram `bootstrap`/`refresh` load the homepage and establish shared session state. Token commands can rotate credentials even though their output contains only status/presence information.
- Spotify `server-time`, `totp`, `track-preview`, and GitHub `parse` can run without credentials. GitHub saved-HTML parsing requires a viewer embedded in the page or `--viewer <username>` so owned-repository notifications are classified correctly.

## Migration from Python

The `.py` entry points have been removed; replace `python3 scripts/<network>-web-client.py` with `bun scripts/<network>-web-client.ts`. No compatibility wrappers are installed.

- Commands return the shared app's normalized profiles, posts, stories and notifications where the app has a model; low-level diagnostics still return redacted service JSON. Update scripts that depended on Python-specific wrappers or summary keys.
- GitHub `feed`, `parse` and `--output` return normalized JSON rather than authenticated HTML. `feed --etag` supports 304 responses; `--structured-output` saves the same structured result, and `--structured` selects the default output. Python's `--no-structured` is removed.
- Instagram `profile-username` uses the current profile-page Relay query, like `profile-web`; it no longer calls the rate-limited REST endpoint. Only `profile-diagnosis` deliberately checks that retired endpoint.
- Instagram document discovery uses the shared app's in-memory session cache. Python-only disk-cache flags (`--cache-file`, `--cache-ttl-seconds`, `--no-cache`) are removed. Custom `graphql --post` uses the app's `/graphql/query` POST transport, replacing the probe's `/api/graphql` variant.
- Inline `--credentials-json` is removed. Use a file or stdin. Saved credentials use the Expo schema; old Python token-expiry exports are not an input format. Native simulator exports remain supported.
- Spotify user search and profiles use the app's query/normalization, including follower/following counts. Arbitrary `get` URLs are restricted to HTTPS on `spclient.wg.spotify.com` and `api.spotify.com`. TOTP and token commands no longer print live codes or tokens.
- Bluesky now requires an explicit credential source instead of implicitly reading the simulator. OAuth browser sign-in stays in the app.

## Validation

Run the repository's checks from `android-app/`:

```sh
bun run format
bun run check
bun run lint
bun run test
```

The tooling includes the root TypeScript wrappers. `tests/clients.test.ts` runs the real provider clients with a fake transport to cover credential conversion, rotation, redaction, private exports, modern Instagram profile pagination, Spotify token renewal and Bluesky signed nonce retries. Existing parser tests cover normalized content. Live endpoint changes should be validated through these probes before porting to Swift; refactors test mutations with fixtures rather than creating real social actions.
