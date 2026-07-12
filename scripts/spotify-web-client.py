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

    def profile_attributes(self) -> dict[str, Any]:
        return self.pathfinder_query("profile-attributes", variables={}, use_initial_token=False)

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
            "Client-Token": self.client_token(),
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
    subparsers.add_parser("profile-attributes", help="Resolve the current user through api-partner profileAttributes.")

    profile = subparsers.add_parser("user-profile", help="Fetch a Spotify user profile by username.")
    profile.add_argument("username", help="Spotify username or spotify:user URI.")
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

    custom = subparsers.add_parser("get", help="GET a custom spclient path or absolute HTTPS URL with WebPlayer headers.")
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
    elif args.command == "profile-attributes":
        result = client.profile_attributes()
    elif args.command == "user-profile":
        result = client.user_profile(args.username)
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
