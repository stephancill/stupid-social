#!/usr/bin/env python3

"""Probe Spotify WebPlayer APIs using credentials captured by the app login flow.

The script is intentionally dependency-free so it can run with system Python.
It supports credentials from either a JSON file/stdin or the simulator UserDefaults
fallback used by this project during development.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


SPCLIENT_BASE_URL = "https://spclient.wg.spotify.com"
OPEN_SPOTIFY_BASE_URL = "https://open.spotify.com"
PATHFINDER_URL = "https://api-partner.spotify.com/pathfinder/v2/query"
APP_VERSION = "1.2.90.229.g33aad738"
BROWSER_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
DEFAULT_ACCEPT_LANGUAGE = "en-US,en;q=0.9"
TOKEN_REFRESH_LEEWAY_SECONDS = 120
SIM_PREFS_SCRIPT = os.path.expanduser(
    "~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py"
)
SIM_SPOTIFY_FALLBACK_KEY = "tech.stupid.StupidSocial.credentials.spotify.localFallback"

TOTP_VERSION = "61"
TOTP_PERIOD_SECONDS = 30
TOTP_OBFUSCATED_SECRET = ',7/*F("rLJ2oxaKL^f+E1xvP@N'

PATHFINDER_OPERATIONS = {
    "profile-attributes": {
        "operationName": "profileAttributes",
        "sha256Hash": "53bcb064f6cd18c23f752bc324a791194d20df612d8e1239c735144ab0399ced",
    },
    "find-top-results": {
        "operationName": "findTopResults",
        "sha256Hash": "755858df4daab8d212980b02a81dcf8c9a58447de318b59d07c4651a1d0450b9",
    },
    "is-track-saved": {
        "operationName": "areEntitiesInLibrary",
        "sha256Hash": "134337999233cc6fdd6b1e6dbf94841409f04a946c5c7b744b09ba0dfe5a85ed",
    },
    "save-track": {
        "operationName": "addToLibrary",
        "sha256Hash": "7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d",
    },
    "remove-track": {
        "operationName": "removeFromLibrary",
        "sha256Hash": "7c5a69420e2bfae3da5cc4e14cbc8bb3f6090f80afc00ffc179177f19be3f33d",
    },
}


@dataclass
class TokenResponse:
    access_token: str
    expires_at_ms: int | None

    @property
    def expires_at_seconds(self) -> float | None:
        if self.expires_at_ms is None:
            return None
        return self.expires_at_ms / 1000


class SpotifyWebClient:
    def __init__(self, credentials: dict[str, Any], accept_language: str) -> None:
        self.credentials = credentials
        self.accept_language = accept_language
        self.opener = urllib.request.build_opener()

    def bootstrap(self, refresh_if_needed: bool) -> dict[str, Any]:
        if refresh_if_needed and self.token_expired_or_missing():
            self.refresh_web_player_token(reason="transport")
        return {
            "credentials": credential_presence(self.credentials),
            "tokens": {
                "access_token_expired_or_missing": self.token_expired_or_missing(),
                "initial_token_expired_or_missing": self.initial_token_expired_or_missing(),
            },
            "totp": {
                "version": TOTP_VERSION,
                "self_test": spotify_totp(1_777_993_436) == "031750",
            },
        }

    def refresh_web_player_token(self, reason: str = "transport") -> dict[str, Any]:
        if not self.sp_dc():
            raise SystemExit("Spotify spDC/sp_dc cookie is required to refresh the WebPlayer token")

        current_token = spotify_totp(time.time())
        server_timestamp = self.server_time()
        server_token = spotify_totp(server_timestamp) if server_timestamp is not None else current_token
        params = urllib.parse.urlencode(
            {
                "reason": reason,
                "productType": "web-player",
                "totp": current_token,
                "totpServer": server_token,
                "totpVer": TOTP_VERSION,
            }
        )
        response = self.request_json(
            "GET",
            OPEN_SPOTIFY_BASE_URL + "/api/token?" + params,
            headers={
                "Accept": "application/json",
                "App-Platform": "WebPlayer",
                "Cookie": self.spotify_cookie_header(),
            },
        )
        token_response = parse_token_response(response)
        # The clientId returned by /api/token is required to mint a fresh
        # client-token (the Pathfinder `client-token` header). Capture it so the
        # reliable username path can refresh the token when the stored one is stale.
        client_id = response.get("clientId") or response.get("client_id")
        if client_id:
            self.credentials["clientId"] = client_id
        if reason == "init":
            self.credentials["initialBearerToken"] = token_response.access_token
            self.credentials["initialBearerTokenExpiresAt"] = token_response.expires_at_seconds
        else:
            self.credentials["bearerToken"] = token_response.access_token
            self.credentials["accessTokenExpiresAt"] = token_response.expires_at_seconds
        return {
            "status": "ok",
            "reason": reason,
            "accessToken": "present",
            "accessTokenExpirationTimestampMs": token_response.expires_at_ms,
        }

    def request_client_token(self) -> dict[str, Any]:
        """Mint a fresh client-token from the same cookie/session that buddylist
        uses. A stale or missing `client-token` is what makes Pathfinder (the
        username source) return HTTP 401/403 while spclient `buddylist` still 200s.
        Requires `clientId`, which /api/token (reason=init) returns for free."""
        client_id = self.credentials.get("clientId")
        if not client_id:
            self.refresh_web_player_token(reason="init")
            client_id = self.credentials.get("clientId")
        if not client_id:
            raise SystemExit("Could not obtain clientId to mint a client-token from /api/token")
        data = {
            "client_data": {
                "client_version": APP_VERSION,
                "client_id": client_id,
                "js_sdk_data": {
                    "device_brand": "",
                    "device_id": "",
                    "device_model": "",
                    "device_type": "",
                    "os": "",
                    "os_version": "",
                },
            }
        }
        headers = {
            "User-Agent": BROWSER_USER_AGENT,
            "Accept": "application/json",
            "Origin": OPEN_SPOTIFY_BASE_URL,
            "Referer": OPEN_SPOTIFY_BASE_URL + "/",
            "App-Platform": "WebPlayer",
            "Content-Type": "application/json",
        }
        response = self.request_json(
            "POST",
            "https://clienttoken.spotify.com/v1/clienttoken",
            headers=headers,
            body=json.dumps(data, separators=(",", ":")).encode(),
        )
        granted = response.get("granted_token") or {}
        token = granted.get("token")
        if not token:
            raise SystemExit("No granted_token.token in client-token mint response")
        self.credentials["clientToken"] = token
        return {
            "status": "ok",
            "client_token": "present",
            "client_token_refresh": response.get("granted_token", {}).get("refresh_token"),
        }

    def resolve_username(self) -> dict[str, Any]:
        """Reliable username resolution: use a freshly minted client-token plus
        the current access token — both derived from the same `sp_dc`-backed
        session that makes `buddylist` succeed — then call Pathfinder."""
        init_token = self.pathfinder_bearer_token()  # guarantees a fresh init token
        self.request_client_token()  # guarantees a fresh client-token in credentials
        client_token = self.client_token()
        operation = PATHFINDER_OPERATIONS["profile-attributes"]
        body = {
            "variables": {},
            "operationName": operation["operationName"],
            "extensions": {
                "persistedQuery": {"version": 1, "sha256Hash": operation["sha256Hash"]}
            },
        }
        headers = self.pathfinder_headers(init_token)
        headers["Client-Token"] = client_token
        response = self.request_json(
            "POST", PATHFINDER_URL, headers=headers,
            body=json.dumps(body, separators=(",", ":")).encode(),
        )
        username = response.get("data", {}).get("me", {}).get("profile", {}).get("username")
        if not isinstance(username, str) or not username:
            raise SystemExit("Spotify profile response did not include a username")
        self.credentials["username"] = username
        return {"status": "ok", "username": username}

    def server_time(self) -> float | None:
        try:
            response = self.request_json(
                "GET",
                OPEN_SPOTIFY_BASE_URL + "/api/server-time",
                headers={"Accept": "application/json"},
            )
        except SpotifyHTTPError:
            return None
        value = response.get("serverTime")
        return float(value) if isinstance(value, int | float) else None

    def buddylist(self) -> dict[str, Any]:
        return self.spclient_get("presence-view/v1/buddylist")

    def user_profile(self, username: str) -> dict[str, Any]:
        username = username.strip().removeprefix("spotify:user:")
        return self.spclient_get(f"user-profile-view/v3/profile/{urllib.parse.quote(username)}")

    def search_users(self, query: str) -> dict[str, Any]:
        query = query.strip()
        if not query:
            return {"status": "ok", "query": query, "users": []}
        response = self.pathfinder_query(
            "find-top-results",
            variables={"query": query, "numberOfTopResults": 20},
            use_initial_token=False,
        )
        return {
            "status": "ok",
            "query": query,
            "users": summarize_spotify_pathfinder_users(response),
            "raw": response,
        }

    def user_following(self, username: str) -> dict[str, Any]:
        username = username.strip().removeprefix("spotify:user:")
        return self.spclient_get(f"user-profile-view/v3/profile/{urllib.parse.quote(username)}/following?market=from_token")

    def user_followers(self, username: str) -> dict[str, Any]:
        username = username.strip().removeprefix("spotify:user:")
        return self.spclient_get(f"user-profile-view/v3/profile/{urllib.parse.quote(username)}/followers?market=from_token")

    def audio_analysis(self, track_id: str) -> dict[str, Any]:
        track_id = spotify_id(track_id)
        return self.spclient_get(f"audio-attributes/v1/audio-analysis/{urllib.parse.quote(track_id)}")

    def spclient_get(self, path: str, accept_language: str | None = None) -> dict[str, Any]:
        return self.request_json_with_refresh(
            "GET",
            SPCLIENT_BASE_URL + "/" + path.lstrip("/"),
            headers=self.spclient_headers(accept_language=accept_language),
        )

    def speechless_post(self, path: str, body: bytes) -> bytes:
        """POST a protobuf request to the Spotify Messages ("speechless") service.

        Only `application/x-protobuf` is accepted; `application/protobuf` returns 400.
        """
        url = SPCLIENT_BASE_URL + "/" + path.lstrip("/")

        def headers() -> dict[str, str]:
            return {
                **self.spclient_headers(),
                "Content-Type": "application/x-protobuf",
                "Accept": "application/x-protobuf",
            }

        try:
            return self.request_bytes("POST", url, headers(), body)
        except SpotifyHTTPError as exc:
            if exc.status_code not in {401, 403} or not self.sp_dc():
                raise SystemExit(str(exc)) from exc
            self.refresh_web_player_token(reason="transport")
            try:
                return self.request_bytes("POST", url, headers(), body)
            except SpotifyHTTPError as retry_exc:
                raise SystemExit(str(retry_exc)) from retry_exc

    def chats(self, limit: int) -> dict[str, Any]:
        request = pb_varint_field(1, SORT_ORDER_DESCENDING) + pb_varint_field(2, limit)
        decoded = pb_decode(
            self.speechless_post("speechless/v1/retrieve/chats-share-set/latest", request),
            "RetrieveLatestNodeResponse",
        )
        entries = decoded.get("latest_node_response", [])
        return {
            "status": "ok",
            "chats": [
                summarize_speechless_chat(entry.get("hierarchy", {}), entry.get("client_node"))
                for entry in entries
            ],
            "decoded": decoded,
        }

    def chat(self, chat_id: str, page_size: int, page_token: str | None) -> dict[str, Any]:
        chat_id = chat_id.strip().removeprefix("spotify:chat:")
        request = pb_string_field(1, chat_id) + pb_varint_field(5, SORT_ORDER_DESCENDING)
        request += pb_varint_field(9, page_size)
        if page_token:
            request += pb_string_field(8, page_token)
        decoded = pb_decode(
            self.speechless_post("speechless/v1/retrieve/hierarchy", request),
            "RetrieveNodeResponse",
        )
        return {
            "status": "ok",
            "chat": summarize_speechless_chat(decoded.get("hierarchy", {}), None),
            "messages": [summarize_speechless_node(node) for node in decoded.get("client_node", [])],
            "next_page_token": decoded.get("next_page_token"),
            "previous_page_token": decoded.get("previous_page_token"),
            "decoded": decoded,
        }

    def profile_attributes(self) -> dict[str, Any]:
        return self.pathfinder_query("profile-attributes", variables={}, use_initial_token=False)

    def current_username(self) -> dict[str, Any]:
        """Resolve the current user with the *same* bearer token config that
        buddylist uses (no client-token, no Pathfinder). `/v1/me` is the canonical
        current-user endpoint and returns `id` (the username) + `display_name`.
        Falls back via a token refresh on 401/403, mirroring `buddylist`."""
        headers = {"Authorization": f"Bearer {self.bearer_token()}", "Accept": "application/json"}
        try:
            response = self.request_json("GET", "https://api.spotify.com/v1/me", headers=headers)
        except SpotifyHTTPError as exc:
            if exc.status_code in {401, 403} and self.sp_dc():
                self.refresh_web_player_token(reason="transport")
                refreshed_headers = {**headers, "Authorization": f"Bearer {self.bearer_token()}"}
                response = self.request_json("GET", "https://api.spotify.com/v1/me", headers=refreshed_headers)
            else:
                raise SystemExit(str(exc)) from exc
        return {
            "status": "ok",
            "username": response.get("id"),
            "display_name": response.get("display_name"),
            "uri": response.get("uri"),
        }

    def is_track_saved(self, track_id: str) -> dict[str, Any]:
        track_id = spotify_id(track_id)
        return self.pathfinder_query(
            "is-track-saved",
            variables={"uris": [f"spotify:track:{track_id}"]},
            use_initial_token=True,
        )

    def save_track(self, track_id: str) -> dict[str, Any]:
        track_id = spotify_id(track_id)
        return self.pathfinder_query(
            "save-track",
            variables={"libraryItemUris": [f"spotify:track:{track_id}"]},
            use_initial_token=True,
        )

    def remove_track(self, track_id: str) -> dict[str, Any]:
        track_id = spotify_id(track_id)
        return self.pathfinder_query(
            "remove-track",
            variables={"libraryItemUris": [f"spotify:track:{track_id}"]},
            use_initial_token=True,
        )

    def pathfinder_query(
        self,
        command_name: str,
        variables: dict[str, Any],
        use_initial_token: bool,
    ) -> dict[str, Any]:
        operation = PATHFINDER_OPERATIONS[command_name]
        bearer_token = self.pathfinder_bearer_token() if use_initial_token else self.bearer_token()
        body = {
            "variables": variables,
            "operationName": operation["operationName"],
            "extensions": {
                "persistedQuery": {
                    "version": 1,
                    "sha256Hash": operation["sha256Hash"],
                }
            },
        }
        return self.request_json_with_refresh(
            "POST",
            PATHFINDER_URL,
            headers=self.pathfinder_headers(bearer_token),
            body=json.dumps(body, separators=(",", ":")).encode(),
        )

    def track_preview(self, track_id: str) -> dict[str, Any]:
        track_id = spotify_id(track_id)
        html = self.request_text(
            "GET",
            f"{OPEN_SPOTIFY_BASE_URL}/embed/track/{urllib.parse.quote(track_id)}",
            headers={"Accept-Language": self.accept_language},
        )
        return {"track_id": track_id, "preview_url": extract_preview_url(html)}

    def custom_get(self, url_or_path: str) -> dict[str, Any]:
        if url_or_path.startswith("https://"):
            url = url_or_path
        else:
            url = SPCLIENT_BASE_URL + "/" + url_or_path.lstrip("/")
        return self.request_json_with_refresh("GET", url, headers=self.spclient_headers())

    def exported_credentials(self) -> dict[str, Any]:
        return {key: value for key, value in self.credentials.items() if value is not None}

    def token_expired_or_missing(self) -> bool:
        token = self.bearer_token(allow_empty=True)
        expires_at = credential_timestamp(self.credentials.get("accessTokenExpiresAt"))
        return not token or (expires_at is not None and expires_at - time.time() <= TOKEN_REFRESH_LEEWAY_SECONDS)

    def initial_token_expired_or_missing(self) -> bool:
        token = str(self.credentials.get("initialBearerToken") or "")
        expires_at = credential_timestamp(self.credentials.get("initialBearerTokenExpiresAt"))
        return not token or (expires_at is not None and expires_at - time.time() <= TOKEN_REFRESH_LEEWAY_SECONDS)

    def pathfinder_bearer_token(self) -> str:
        if self.initial_token_expired_or_missing() and self.sp_dc():
            self.refresh_web_player_token(reason="init")
        return str(self.credentials.get("initialBearerToken") or self.bearer_token())

    def bearer_token(self, allow_empty: bool = False) -> str:
        token = str(self.credentials.get("bearerToken") or self.credentials.get("accessToken") or "")
        if not token and not allow_empty:
            raise SystemExit("Spotify bearerToken is required")
        return token

    def client_token(self) -> str:
        token = str(self.credentials.get("clientToken") or self.credentials.get("client-token") or "")
        if not token:
            raise SystemExit("Spotify clientToken is required")
        return token

    def sp_dc(self) -> str:
        return str(self.credentials.get("spDC") or self.credentials.get("sp_dc") or "")

    def spotify_cookie_header(self) -> str:
        values = []
        if sp_dc := self.sp_dc():
            values.append(f"sp_dc={sp_dc}")
        if sp_t := self.credentials.get("spT") or self.credentials.get("sp_t"):
            values.append(f"sp_t={sp_t}")
        if sp_key := self.credentials.get("spKey") or self.credentials.get("sp_key"):
            values.append(f"sp_key={sp_key}")
        return "; ".join(values)

    def spclient_headers(self, accept_language: str | None = None) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.bearer_token()}",
            "Spotify-App-Version": APP_VERSION,
            "App-Platform": "WebPlayer",
            "Accept": "application/json",
            "Accept-Language": accept_language or self.accept_language,
        }

    def pathfinder_headers(self, bearer_token: str) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {bearer_token}",
            "Client-Token": self.client_token(),
            "Spotify-App-Version": APP_VERSION,
            "App-Platform": "WebPlayer",
            "Content-Type": "application/json;charset=UTF-8",
            "Accept": "application/json",
            "Accept-Language": "en",
            "Origin": OPEN_SPOTIFY_BASE_URL,
            "Referer": OPEN_SPOTIFY_BASE_URL + "/",
            "User-Agent": BROWSER_USER_AGENT,
        }

    def request_json_with_refresh(
        self,
        method: str,
        url: str,
        headers: dict[str, str],
        body: bytes | None = None,
    ) -> dict[str, Any]:
        try:
            return self.request_json(method, url, headers, body)
        except SpotifyHTTPError as exc:
            if exc.status_code not in {401, 403} or not self.sp_dc():
                raise SystemExit(str(exc)) from exc
            self.refresh_web_player_token(reason="transport")
            refreshed_headers = {**headers, "Authorization": f"Bearer {self.bearer_token()}"}
            try:
                return self.request_json(method, url, refreshed_headers, body)
            except SpotifyHTTPError as retry_exc:
                raise SystemExit(str(retry_exc)) from retry_exc

    def request_json(
        self,
        method: str,
        url: str,
        headers: dict[str, str],
        body: bytes | None = None,
    ) -> dict[str, Any]:
        text = self.request_text(method, url, headers, body)
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Expected JSON from {url}, got {len(text)} bytes: {exc}") from exc

    def request_text(
        self,
        method: str,
        url: str,
        headers: dict[str, str],
        body: bytes | None = None,
    ) -> str:
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                return response.read().decode(charset, errors="replace")
        except urllib.error.HTTPError as exc:
            body_text = exc.read().decode("utf-8", errors="replace")
            raise SpotifyHTTPError(exc.code, method, url, body_text) from exc

    def request_bytes(
        self,
        method: str,
        url: str,
        headers: dict[str, str],
        body: bytes | None = None,
    ) -> bytes:
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            body_text = exc.read().decode("utf-8", errors="replace")
            raise SpotifyHTTPError(exc.code, method, url, body_text) from exc


class SpotifyHTTPError(Exception):
    def __init__(self, status_code: int, method: str, url: str, body: str) -> None:
        self.status_code = status_code
        self.method = method
        self.url = url
        self.body = body
        super().__init__(f"HTTP {status_code} {method} {url}\n{truncate(body, 1200)}")


def load_credentials(args: argparse.Namespace) -> dict[str, Any]:
    if args.credentials_json:
        return json.loads(args.credentials_json)
    if args.credentials_file:
        if args.credentials_file == "-":
            return json.load(sys.stdin)
        with open(args.credentials_file, "r", encoding="utf-8") as handle:
            return json.load(handle)
    if args.simulator:
        command = [sys.executable, SIM_PREFS_SCRIPT, "--raw-key", SIM_SPOTIFY_FALLBACK_KEY]
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return json.loads(result.stdout)
    raise SystemExit("Pass --simulator, --credentials-file, or --credentials-json")


def parse_token_response(value: dict[str, Any]) -> TokenResponse:
    token = value.get("accessToken") or value.get("access_token")
    if not isinstance(token, str) or not token:
        raise SystemExit("Spotify token response did not include accessToken")
    expires_at_ms = value.get("accessTokenExpirationTimestampMs")
    return TokenResponse(
        access_token=token,
        expires_at_ms=int(expires_at_ms) if isinstance(expires_at_ms, int | float | str) and str(expires_at_ms).isdigit() else None,
    )


def credential_timestamp(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, int | float):
        # Swift's default Date Codable representation is seconds since 2001-01-01,
        # while this script writes Unix seconds. Treat small values as the Swift form.
        if value < 1_000_000_000:
            return float(value) + 978_307_200
        return float(value)
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return None
        try:
            return credential_timestamp(float(stripped))
        except ValueError:
            pass
        try:
            return time.mktime(time.strptime(stripped.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z"))
        except ValueError:
            return None
    return None


def credential_presence(credentials: dict[str, Any]) -> dict[str, str]:
    secret_keys = {
        "bearerToken",
        "accessToken",
        "clientToken",
        "client-token",
        "spDC",
        "sp_dc",
        "spT",
        "sp_t",
        "spKey",
        "sp_key",
        "initialBearerToken",
    }
    result: dict[str, str] = {}
    for key, value in credentials.items():
        if key in secret_keys and value:
            result[key] = f"present ({len(str(value))} chars)"
        elif key in secret_keys:
            result[key] = "missing"
        else:
            result[key] = str(value) if value is not None else "null"
    return result


def spotify_totp(timestamp: float | int | None = None) -> str:
    timestamp = time.time() if timestamp is None else float(timestamp)
    counter = int(timestamp // TOTP_PERIOD_SECONDS)
    key = spotify_totp_secret()
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    truncated = (
        ((digest[offset] & 0x7F) << 24)
        | ((digest[offset + 1] & 0xFF) << 16)
        | ((digest[offset + 2] & 0xFF) << 8)
        | (digest[offset + 3] & 0xFF)
    )
    return f"{truncated % 1_000_000:06d}"


def spotify_totp_secret() -> bytes:
    decoded = [ord(char) ^ (index % 33 + 9) for index, char in enumerate(TOTP_OBFUSCATED_SECRET)]
    return "".join(str(value) for value in decoded).encode()


def spotify_id(value: str) -> str:
    value = value.strip()
    for prefix in (
        "spotify:track:",
        "spotify:album:",
        "spotify:playlist:",
        "spotify:artist:",
        "spotify:user:",
        "spotify:socialsession:",
    ):
        value = value.removeprefix(prefix)
    if "/track/" in value:
        value = value.split("/track/", 1)[1].split("?", 1)[0].split("/", 1)[0]
    return value


def extract_preview_url(html: str) -> str | None:
    marker = '"audioPreview":{"url":"'
    start = html.find(marker)
    if start == -1:
        return None
    start += len(marker)
    end = html.find('"', start)
    if end == -1:
        return None
    return html[start:end].replace("\\u0026", "&").replace("\\/", "/")


def summarize(value: Any, max_depth: int = 3) -> Any:
    if isinstance(value, dict) and "users" in value and "query" in value:
        return {
            "status": value.get("status"),
            "query": value.get("query"),
            "user_count": len(value.get("users") or []),
            "users": value.get("users"),
        }
    if max_depth <= 0:
        if isinstance(value, dict):
            return {"...": f"{len(value)} keys"}
        if isinstance(value, list):
            return [f"... {len(value)} items"]
        return redact_if_secret(value)
    if isinstance(value, dict):
        return {key: summarize(redact_key_value(key, value[key]), max_depth - 1) for key in list(value.keys())[:12]}
    if isinstance(value, list):
        return [summarize(item, max_depth - 1) for item in value[:3]]
    return redact_if_secret(value)


def redact_key_value(key: str, value: Any) -> Any:
    if isinstance(value, dict | list):
        return value
    lowered = key.lower()
    if any(secret in lowered for secret in ("token", "spdc", "sp_dc", "spt", "sp_t", "spkey", "sp_key", "authorization")):
        return "present" if value else value
    return value


def redact_if_secret(value: Any) -> Any:
    if isinstance(value, str) and len(value) > 160 and looks_like_token(value):
        return f"present ({len(value)} chars)"
    return value


def looks_like_token(value: str) -> bool:
    alphabet = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-=")
    return sum(char in alphabet for char in value) / max(len(value), 1) > 0.9


def truncate(value: str, limit: int) -> str:
    return value if len(value) <= limit else value[:limit] + "..."


def print_json(value: Any, summary: bool) -> None:
    output = summarize(value) if summary else value
    print(json.dumps(output, indent=2, sort_keys=True))


def write_output(path: str | None, value: Any) -> None:
    if not path:
        return
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def summarize_spotify_pathfinder_users(response: dict[str, Any]) -> list[dict[str, Any]]:
    direct_items = (
        response.get("data", {})
        .get("searchV2", {})
        .get("usersV2", {})
        .get("items", [])
    )
    top_items = (
        response.get("data", {})
        .get("searchV2", {})
        .get("topResultsV2", {})
        .get("itemsV2", [])
    )
    users: list[dict[str, Any]] = []
    seen: set[str] = set()

    def append_user(data: dict[str, Any]) -> None:
        uri = data.get("uri")
        username = uri.removeprefix("spotify:user:") if isinstance(uri, str) and uri.startswith("spotify:user:") else data.get("id")
        if not username or username in seen:
            return
        seen.add(username)
        image_sources = (
            data.get("visuals", {})
            .get("avatarImage", {})
            .get("sources", [])
        ) or (data.get("avatar") or {}).get("sources", [])
        image_url = image_sources[0].get("url") if image_sources and isinstance(image_sources[0], dict) else None
        users.append(
            {
                "id": data.get("id") or username,
                "username": username,
                "display_name": data.get("displayName") or data.get("name"),
                "image_url": image_url,
                "uri": uri,
            }
        )

    for item in direct_items:
        data = item.get("data", {}) if isinstance(item, dict) else {}
        append_user(data)
    for item in top_items:
        wrapper = item.get("item", {}) if isinstance(item, dict) else {}
        data = wrapper.get("data", {}) if isinstance(wrapper, dict) else {}
        uri = data.get("uri")
        if isinstance(uri, str) and uri.startswith("spotify:user:"):
            append_user(data)
    return users


# Spotify Messages ("speechless", client codename "campfire") protobuf schema subset,
# reconstructed from the Android app's `com.spotify.campfire.datasource.impl.proto`
# classes. Each field is `number: (name, type, repeated)`; types are "string", "varint",
# "bool", "enum:<Name>", or a message name. Unknown fields decode generically as "#<n>".
SPEECHLESS_SCHEMA: dict[str, dict[int, tuple[str, str, bool]]] = {
    "RetrieveLatestNodeResponse": {1: ("latest_node_response", "LatestNodeResponse", True)},
    "LatestNodeResponse": {1: ("hierarchy", "Hierarchy", False), 2: ("client_node", "ClientNode", False)},
    "RetrieveNodeResponse": {
        1: ("hierarchy", "Hierarchy", False),
        2: ("client_node", "ClientNode", True),
        3: ("next_page_token", "string", False),
        4: ("previous_page_token", "string", False),
    },
    "Hierarchy": {
        1: ("hierarchy_identifier", "HierarchyIdentifier", False),
        3: ("hierarchy_statistic", "HierarchyStatistic", False),
        4: ("hierarchy_metadata", "HierarchyMetadata", False),
        5: ("group", "Group", False),
    },
    "HierarchyIdentifier": {
        1: ("hierarchy_id", "string", False),
        2: ("hierarchy_class", "enum:HierarchyClass", False),
        3: ("uri", "string", False),
    },
    "HierarchyStatistic": {
        1: ("total_user_unseen_events", "varint", False),
        2: ("all_events_seen", "bool", False),
        3: ("total_user_unseen_activity_events", "varint", False),
        4: ("total_user_unseen_contribution_events", "varint", False),
        5: ("revision", "string", False),
    },
    "HierarchyMetadata": {
        1: ("initiator_username", "string", False),
        2: ("hierarchy_status", "enum:HierarchyStatus", False),
        3: ("current_user_participation_status", "varint", False),
        5: ("hierarchy_type", "enum:HierarchyType", False),
        6: ("created_at", "Timestamp", False),
        7: ("current_user_channel_muted", "bool", False),
        8: ("agents", "HierarchyAgent", True),
    },
    "HierarchyAgent": {1: ("username", "string", False), 2: ("agent_uri", "string", False)},
    "Group": {1: ("name", "string", False), 2: ("group_member", "GroupMember", True)},
    "GroupMember": {
        1: ("member_username", "string", False),
        2: ("group_member_status", "varint", False),
        3: ("user_role", "varint", False),
        4: ("invited_by_username", "string", False),
    },
    "ClientNode": {
        1: ("node_identifier", "NodeIdentifier", False),
        2: ("hierarchy_identifier", "HierarchyIdentifier", False),
        3: ("child_node", "ClientNode", True),
        4: ("node_statistic", "NodeStatistic", False),
        6: ("event_capture", "ClientEventCapture", False),
        8: ("message_payload", "MessagePayload", False),
    },
    "NodeIdentifier": {
        1: ("node_path_id", "string", False),
        2: ("node_class", "varint", False),
        3: ("uri", "string", False),
    },
    "NodeStatistic": {
        1: ("user_seen", "bool", False),
        2: ("total_unseen_event_count", "varint", False),
        3: ("total_user_unseen_activity_events", "varint", False),
        4: ("total_user_unseen_contribution_events", "varint", False),
    },
    "ClientEventCapture": {
        1: ("init_username", "string", False),
        2: ("event_capture", "EventCapture", False),
    },
    "EventCapture": {
        1: ("occurred_at", "Timestamp", False),
        2: ("event_id", "string", False),
        3: ("event_type", "enum:EventType", False),
    },
    "MessagePayload": {
        1: ("contribution_payload", "ContributionPayload", False),
        2: ("activity_payload", "ActivityPayload", False),
    },
    "ContributionPayload": {
        1: ("free_text", "FreeText", False),
        2: ("tracked_share", "TrackedShare", False),
        3: ("op_tracked_share", "OffplatformTrackedShare", False),
        4: ("chat_invite", "ChatInvite", False),
    },
    "FreeText": {1: ("message_text", "string", False)},
    "TrackedShare": {
        1: ("uri", "string", False),
        2: ("preview_id", "string", False),
        3: ("context", "TrackedShareContext", False),
        4: ("share_card_config_id", "string", False),
    },
    "OffplatformTrackedShare": {
        1: ("uri", "string", False),
        2: ("op_share_id", "string", False),
        3: ("destination", "string", False),
        4: ("sharing_user_id", "string", False),
        5: ("opening_user_id", "string", False),
    },
    "TrackedShareContext": {1: ("listening_activity", "ListeningActivity", False)},
    "ListeningActivity": {1: ("reaction", "string", False), 2: ("listening_username", "string", False)},
    "ChatInvite": {
        1: ("uri", "string", False),
        2: ("share_id", "string", False),
        3: ("destination", "string", False),
        4: ("inviting_user_id", "string", False),
    },
    "ActivityPayload": {1: ("reaction", "Reaction", False), 2: ("receipt", "Receipt", False)},
    "Reaction": {
        1: ("reaction_emoti", "enum:ReactionEmoti", False),
        2: ("initiator_username", "string", False),
        3: ("emoji_utf8", "string", False),
    },
    "Receipt": {1: ("receipt_type", "enum:ReceiptType", False), 2: ("initiator_username", "string", False)},
}

SPEECHLESS_ENUMS: dict[str, dict[int, str]] = {
    "HierarchyClass": {1: "channel", 2: "member", 3: "annotation", 4: "agent"},
    "HierarchyStatus": {1: "draft", 2: "active", 3: "canceled", 4: "deleted", 5: "rejected", 6: "blocked", 7: "inactive"},
    "HierarchyType": {1: "dm", 2: "group"},
    "EventType": {1: "add", 2: "bulk_add", 3: "delete", 4: "modify"},
    "ReactionEmoti": {1: "thumbs_up", 2: "heart", 3: "laugh", 7: "pleading_face", 8: "thumbs_down", 9: "fire", 10: "headphone"},
    "ReceiptType": {1: "played", 2: "saved", 3: "seen"},
}

SORT_ORDER_DESCENDING = 2


def pb_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def pb_varint_field(number: int, value: int) -> bytes:
    return pb_varint(number << 3) + pb_varint(value)


def pb_string_field(number: int, value: str) -> bytes:
    data = value.encode()
    return pb_varint(number << 3 | 2) + pb_varint(len(data)) + data


def pb_read_varint(data: bytes, index: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        if index >= len(data) or shift > 63:
            raise ValueError("truncated varint")
        byte = data[index]
        index += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, index


def pb_fields(data: bytes) -> list[tuple[int, int, Any]]:
    """Split a protobuf message into (field number, wire type, raw value) tuples."""
    fields: list[tuple[int, int, Any]] = []
    index = 0
    while index < len(data):
        key, index = pb_read_varint(data, index)
        number, wire_type = key >> 3, key & 7
        if number == 0:
            raise ValueError("field number 0")
        if wire_type == 0:
            value, index = pb_read_varint(data, index)
        elif wire_type == 1:
            value, index = data[index:index + 8], index + 8
        elif wire_type == 2:
            length, index = pb_read_varint(data, index)
            if index + length > len(data):
                raise ValueError("truncated length-delimited field")
            value, index = data[index:index + length], index + length
        elif wire_type == 5:
            value, index = data[index:index + 4], index + 4
        else:
            raise ValueError(f"unsupported wire type {wire_type}")
        fields.append((number, wire_type, value))
    return fields


def pb_decode_unknown(wire_type: int, value: Any) -> Any:
    if wire_type == 0:
        return value
    if wire_type != 2:
        return value.hex()
    try:
        text = value.decode()
        if text.isprintable():
            return text
    except UnicodeDecodeError:
        pass
    try:
        return pb_decode(value, None)
    except ValueError:
        return base64.b64encode(value).decode()


def pb_decode(data: bytes, message: str | None) -> dict[str, Any]:
    schema = SPEECHLESS_SCHEMA.get(message or "", {})
    result: dict[str, Any] = {}
    for number, wire_type, value in pb_fields(data):
        kind = schema[number][1] if number in schema else ""
        expects_varint = kind in {"varint", "bool"} or kind.startswith("enum:")
        # Fall back to generic decoding when the wire type contradicts the reconstructed schema.
        if number in schema and (wire_type == 0) == expects_varint:
            name, kind, repeated = schema[number]
            if kind == "string":
                decoded: Any = value.decode(errors="replace")
            elif kind == "varint":
                decoded = value
            elif kind == "bool":
                decoded = bool(value)
            elif kind.startswith("enum:"):
                decoded = SPEECHLESS_ENUMS[kind[5:]].get(value, value)
            elif kind == "Timestamp":
                parts = {n: v for n, _, v in pb_fields(value)}
                seconds = parts.get(1, 0) + parts.get(2, 0) / 1_000_000_000
                decoded = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))
            else:
                decoded = pb_decode(value, kind)
        else:
            name, repeated = f"#{number}", False
            decoded = pb_decode_unknown(wire_type, value)
            if name in result:
                existing = result[name]
                result[name] = (existing if isinstance(existing, list) else [existing]) + [decoded]
                continue
        if repeated:
            result.setdefault(name, []).append(decoded)
        else:
            result[name] = decoded
    return result


def summarize_speechless_node(node: dict[str, Any]) -> dict[str, Any]:
    identifier = node.get("node_identifier", {})
    capture = node.get("event_capture", {})
    payload = node.get("message_payload", {})
    contribution = payload.get("contribution_payload", {})
    activity = payload.get("activity_payload", {})
    summary: dict[str, Any] = {
        "id": identifier.get("node_path_id"),
        "uri": identifier.get("uri"),
        "sender": capture.get("init_username"),
        "sent_at": capture.get("event_capture", {}).get("occurred_at"),
        "seen": node.get("node_statistic", {}).get("user_seen"),
    }
    if share := contribution.get("tracked_share"):
        summary.update(kind="tracked_share", shared_uri=share.get("uri"))
    elif share := contribution.get("op_tracked_share"):
        summary.update(kind="op_tracked_share", shared_uri=share.get("uri"))
    elif text := contribution.get("free_text"):
        summary.update(kind="free_text", text=text.get("message_text"))
    elif contribution:
        summary["kind"] = next((key for key in contribution if not key.startswith("#")), "contribution")
    elif reaction := activity.get("reaction"):
        summary.update(kind="reaction", reaction=reaction.get("emoji_utf8") or reaction.get("reaction_emoti"))
    elif receipt := activity.get("receipt"):
        summary.update(kind="receipt", receipt=receipt.get("receipt_type"))
    else:
        summary["kind"] = "unknown"
    if children := node.get("child_node"):
        summary["children"] = [summarize_speechless_node(child) for child in children]
    return summary


def summarize_speechless_chat(hierarchy: dict[str, Any], latest_node: dict[str, Any] | None) -> dict[str, Any]:
    identifier = hierarchy.get("hierarchy_identifier", {})
    metadata = hierarchy.get("hierarchy_metadata", {})
    statistic = hierarchy.get("hierarchy_statistic", {})
    group = hierarchy.get("group", {})
    summary: dict[str, Any] = {
        "id": identifier.get("hierarchy_id"),
        "uri": identifier.get("uri"),
        "type": metadata.get("hierarchy_type"),
        "name": group.get("name"),
        "members": [member.get("member_username") for member in group.get("group_member", [])],
        "unseen_events": statistic.get("total_user_unseen_events", 0),
        "muted": metadata.get("current_user_channel_muted", False),
    }
    if latest_node:
        summary["latest"] = summarize_speechless_node(latest_node)
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate Spotify WebPlayer API calls using captured app credentials.")
    parser.add_argument("--simulator", action="store_true", help="Read Spotify credentials from the booted simulator fallback store.")
    parser.add_argument("--credentials-file", help="Path to credentials JSON, or '-' for stdin.")
    parser.add_argument("--credentials-json", help="Credentials JSON string.")
    parser.add_argument("--accept-language", default=DEFAULT_ACCEPT_LANGUAGE, help="Accept-Language header for Spotify requests.")
    parser.add_argument("--summary", action="store_true", help="Print compact summarized JSON instead of full responses.")
    parser.add_argument("--output", help="Write full JSON response for request commands to this path.")
    parser.add_argument("--save-credentials", help="Write updated token credentials to this JSON path after the command.")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("bootstrap", help="Print credential/token presence and TOTP self-test state.")
    refresh = subparsers.add_parser("refresh-token", help="Refresh a Spotify WebPlayer token using sp_dc/sp_t cookies.")
    refresh.add_argument("--reason", choices=("transport", "init"), default="transport", help="Token reason to request.")
    subparsers.add_parser("server-time", help="Fetch Spotify server time.")
    subparsers.add_parser("totp", help="Print a current Spotify WebPlayer TOTP for debugging.")
    subparsers.add_parser("buddylist", help="Fetch friend listening activity from presence-view/v1/buddylist.")
    subparsers.add_parser("validate-cookie-login", help="Validate login using only selected cookies, without captured WebPlayer tokens.")
    subparsers.add_parser("profile-attributes", help="Resolve the current user through api-partner profileAttributes.")
    subparsers.add_parser("resolve-username", help="Resolve the current user with a fresh session client-token.")
    subparsers.add_parser("current-username", help="Resolve the current user via GET api.spotify.com/v1/me (same bearer token as buddylist, no client-token).")
    subparsers.add_parser("client-token", help="Mint a fresh client-token from the same session as buddylist (spclient/Pthfinder 'client-token' header).")
    subparsers.add_parser("username", help="Resolve username by minting a fresh client-token, then Pathfinder (reliable when buddylist works).")

    profile = subparsers.add_parser("user-profile", help="Fetch a Spotify user profile by username.")
    profile.add_argument("username", help="Spotify username or spotify:user URI.")
    search_users = subparsers.add_parser("search-users", help="Search Spotify users through the WebPlayer search endpoint.")
    search_users.add_argument("query", help="Search query.")
    following = subparsers.add_parser("following", help="Fetch users followed by a Spotify username.")
    following.add_argument("username", help="Spotify username or spotify:user URI.")
    followers = subparsers.add_parser("followers", help="Fetch followers for a Spotify username.")
    followers.add_argument("username", help="Spotify username or spotify:user URI.")

    audio = subparsers.add_parser("audio-analysis", help="Fetch audio analysis for a bare track ID or spotify:track URI.")
    audio.add_argument("track_id", help="Spotify track ID, URI, or open.spotify.com track URL.")
    preview = subparsers.add_parser("track-preview", help="Extract track preview URL from the open.spotify.com embed page.")
    preview.add_argument("track_id", help="Spotify track ID, URI, or open.spotify.com track URL.")

    saved = subparsers.add_parser("is-track-saved", help="Check whether a track is in the current user's library.")
    saved.add_argument("track_id", help="Spotify track ID, URI, or open.spotify.com track URL.")
    save = subparsers.add_parser("save-track", help="Add a track to the current user's library.")
    save.add_argument("track_id", help="Spotify track ID, URI, or open.spotify.com track URL.")
    remove = subparsers.add_parser("remove-track", help="Remove a track from the current user's library.")
    remove.add_argument("track_id", help="Spotify track ID, URI, or open.spotify.com track URL.")

    chats = subparsers.add_parser("chats", help="List Spotify Messages chats with their latest message (speechless chats-share-set/latest).")
    chats.add_argument("--limit", type=int, default=20, help="Maximum chats to return.")
    chat = subparsers.add_parser("chat", help="Fetch messages in one Spotify Messages chat (speechless retrieve/hierarchy).")
    chat.add_argument("chat_id", help="Chat ID or spotify:chat URI.")
    chat.add_argument("--page-size", type=int, default=20, help="Messages per page.")
    chat.add_argument("--page-token", help="next_page_token from a previous page.")

    custom = subparsers.add_parser("get",help="GET a custom spclient path or absolute HTTPS URL with WebPlayer headers.")
    custom.add_argument("url_or_path", help="spclient path or absolute HTTPS URL.")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    credentialless_commands = {"server-time", "totp", "track-preview"}
    has_credential_source = bool(args.simulator or args.credentials_file or args.credentials_json)
    credentials = {} if args.command in credentialless_commands and not has_credential_source else load_credentials(args)
    client = SpotifyWebClient(credentials, args.accept_language)

    if args.command == "bootstrap":
        result = client.bootstrap(refresh_if_needed=False)
    elif args.command == "refresh-token":
        result = client.refresh_web_player_token(reason=args.reason)
    elif args.command == "server-time":
        result = {"serverTime": client.server_time()}
    elif args.command == "totp":
        result = {"totp": spotify_totp(), "totpVer": TOTP_VERSION, "selfTest": spotify_totp(1_777_993_436) == "031750"}
    elif args.command == "buddylist":
        result = client.buddylist()
    elif args.command == "validate-cookie-login":
        client.credentials = {
            key: value for key, value in credentials.items()
            if key in {"spDC", "sp_dc", "spT", "sp_t", "spKey", "sp_key"}
        }
        token = client.refresh_web_player_token(reason="transport")
        activity = client.buddylist()
        result = {
            "status": "ok",
            "captured_player_tokens_required": False,
            "token": token,
            "friend_count": len(activity.get("friends", [])),
        }
    elif args.command == "resolve-username":
        result = client.resolve_username()
    elif args.command == "profile-attributes":
        result = client.profile_attributes()
    elif args.command == "current-username":
        result = client.current_username()
    elif args.command == "client-token":
        result = client.request_client_token()
    elif args.command == "username":
        result = client.resolve_username()
    elif args.command == "user-profile":
        result = client.user_profile(args.username)
    elif args.command == "search-users":
        result = client.search_users(args.query)
    elif args.command == "following":
        result = client.user_following(args.username)
    elif args.command == "followers":
        result = client.user_followers(args.username)
    elif args.command == "audio-analysis":
        result = client.audio_analysis(args.track_id)
    elif args.command == "track-preview":
        result = client.track_preview(args.track_id)
    elif args.command == "is-track-saved":
        result = client.is_track_saved(args.track_id)
    elif args.command == "save-track":
        result = client.save_track(args.track_id)
    elif args.command == "remove-track":
        result = client.remove_track(args.track_id)
    elif args.command == "chats":
        result = client.chats(args.limit)
    elif args.command == "chat":
        result = client.chat(args.chat_id, args.page_size, args.page_token)
    elif args.command == "get":
        result = client.custom_get(args.url_or_path)
    else:
        raise SystemExit(f"Unknown command: {args.command}")

    write_output(args.output, result)
    if args.save_credentials:
        write_output(args.save_credentials, client.exported_credentials())
    print_json(result, summary=args.summary)


if __name__ == "__main__":
    main()
