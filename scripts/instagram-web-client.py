#!/usr/bin/env python3

"""Probe Instagram's web APIs using cookies captured by the app login flow.

The script is intentionally dependency-free so it can run with system Python.
It supports credentials from either a JSON file/stdin or the simulator UserDefaults
fallback used by this project during development.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import random
import re
import string
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from html import unescape
from http.cookiejar import Cookie
from typing import Any


BASE_URL = "https://www.instagram.com"
SIM_PREFS_SCRIPT = os.path.expanduser(
    "~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py"
)
SIM_INSTAGRAM_FALLBACK_KEY = "tech.stupid.StupidSocial.credentials.instagram.localFallback"

WEB_APP_ID_MOBILE = "1217981644879628"
ASBD_ID = "359341"
IPHONE_SAFARI_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

OPERATION_NAMES = {
    "activity": "PolarisActivityFeedStoriesViewQuery",
    "stories-tray": "PolarisStoriesV3TrayContainerQuery",
    "reels-media-standalone": "PolarisStoriesV3ReelPageStandaloneQuery",
    "reels-media-gallery": "PolarisStoriesV3ReelPageGalleryQuery",
    "profile-content": "PolarisProfilePageContentQuery",
    "delete-story": "usePolarisStoriesV3DeleteMediaMutation",
}

OPERATION_RE = re.compile(
    r'__d\("([^"]+?)_instagramRelayOperation",\[\],\(function\([^)]*\)\{.*?\.exports="(\d+)"',
    re.DOTALL,
)

DEFAULT_VARIABLES = {
    "activity": {
        "inbox_request_data": {},
        "pending_request_data": {},
    },
    "stories-tray": {
        "data": {
            "is_following_feed": False,
            "reason": "web_home",
        },
        "suggestedUsersData": {
            "max_id": "",
            "max_number_to_display": 0,
            "module": "discover_people",
            "paginate": False,
        },
    },
}


@dataclass
class WebState:
    html: str
    csrf_token: str | None = None
    lsd: str | None = None
    fb_dtsg: str | None = None
    user_id: str | None = None
    revision: str | None = None
    hsi: str | None = None
    haste_session: str | None = None
    spin_t: str | None = None
    device_id: str | None = None
    machine_id: str | None = None
    bloks_version_id: str | None = None


class InstagramWebClient:
    def __init__(self, credentials: dict[str, Any], user_agent: str) -> None:
        self.credentials = credentials
        self.user_agent = user_agent
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookie_jar))
        self.request_count = 0
        self.web_session_id = random_base36(6)
        self.www_claim: str | None = None
        self.state: WebState | None = None
        self.doc_ids: dict[str, str] = {}
        self._seed_cookies(credentials)

    def bootstrap(self) -> WebState:
        return self.refresh_state()

    def refresh_state(self) -> WebState:
        html = self.request_text("GET", BASE_URL + "/", headers=self._base_page_headers())
        state = parse_web_state(html)
        state.csrf_token = cookie_value(self.cookie_jar, "csrftoken") or state.csrf_token
        if not state.user_id or state.user_id == "0":
            state.user_id = cookie_value(self.cookie_jar, "ds_user_id") or self.credentials.get("dsUserId")
        state.device_id = state.device_id or cookie_value(self.cookie_jar, "ig_did") or self.credentials.get("igDid")
        state.machine_id = state.machine_id or cookie_value(self.cookie_jar, "mid") or self.credentials.get("mid")
        self.state = state
        return state

    def discover_doc_ids(self, extra_pages: list[str] | None = None) -> dict[str, str]:
        self._ensure_bootstrapped()
        state = self._state()
        sources = [state.html]
        for page_url in extra_pages or []:
            try:
                sources.append(self.request_text("GET", page_url, headers=self._base_page_headers()))
            except InstagramHTTPError:
                continue

        doc_ids: dict[str, str] = {}
        script_sources: list[str] = []
        seen_script_sources: set[str] = set()
        for source in sources:
            doc_ids.update(parse_doc_ids(source))
            for script_url in script_urls(source):
                if script_url in seen_script_sources:
                    continue
                seen_script_sources.add(script_url)
                script_sources.append(script_url)

        for script_url in script_sources:
            try:
                source = self.request_text("GET", script_url, headers=self._base_asset_headers())
            except InstagramHTTPError:
                continue
            doc_ids.update(parse_doc_ids(source))

        self.doc_ids = doc_ids
        return doc_ids

    def doc_id(self, command_name: str) -> str:
        operation_name = OPERATION_NAMES[command_name]
        if not self.doc_ids:
            self.discover_doc_ids()
        if doc_id := self.doc_ids.get(operation_name):
            return doc_id
        raise SystemExit(
            f"Could not discover doc ID for {operation_name}. "
            "Try `docids --story-username <username>` for story-only operations."
        )

    def refresh_story_doc_ids(self, username: str) -> None:
        username = username.strip().lstrip("@")
        if not username:
            return
        self.discover_doc_ids([BASE_URL + f"/stories/{urllib.parse.quote(username)}/"])

    def graphql_get(self, doc_id: str, variables: dict[str, Any]) -> dict[str, Any]:
        self._ensure_bootstrapped()
        params = {
            "doc_id": doc_id,
            "variables": json.dumps(variables, separators=(",", ":")),
        }
        url = BASE_URL + "/graphql/query/?" + urllib.parse.urlencode(params)
        return self.request_json_with_refresh("GET", url, headers=self.web_headers())

    def graphql_post(
        self,
        doc_id: str,
        variables: dict[str, Any],
        friendly_name: str | None = None,
        root_field_name: str | None = None,
        endpoint: str = "/api/graphql",
    ) -> dict[str, Any]:
        self._ensure_bootstrapped()
        state = self._state()
        fields: dict[str, str] = {
            "doc_id": doc_id,
            "variables": json.dumps(variables, separators=(",", ":")),
            "server_timestamps": "true",
            "__user": state.user_id or "0",
            "__a": "1",
            "__req": request_id(self.request_count),
        }
        if state.revision:
            fields["__rev"] = state.revision
        if state.hsi:
            fields["__hsi"] = state.hsi
        if state.haste_session:
            fields["__hs"] = state.haste_session
        if state.lsd:
            fields["lsd"] = state.lsd
        if state.fb_dtsg:
            fields["fb_dtsg"] = state.fb_dtsg
        if state.csrf_token:
            fields["jazoest"] = jazoest(state.csrf_token)
        if friendly_name:
            fields["fb_api_caller_class"] = "RelayModern"
            fields["fb_api_req_friendly_name"] = friendly_name

        self.request_count += 1
        headers = {**self.web_headers(), "Content-Type": "application/x-www-form-urlencoded"}
        if friendly_name:
            headers["X-FB-Friendly-Name"] = friendly_name
        if root_field_name:
            headers["X-Root-Field-Name"] = root_field_name
        return self.request_json_with_refresh(
            "POST",
            BASE_URL + endpoint,
            headers=headers,
            body=urllib.parse.urlencode(fields).encode(),
        )

    def rest_news_inbox(self) -> dict[str, Any]:
        self._ensure_bootstrapped()
        state = self._state()
        fields = {"selected_filters": "", "max_id": ""}
        if state.csrf_token:
            fields["jazoest"] = jazoest(state.csrf_token)
        return self.request_json_with_refresh(
            "POST",
            BASE_URL + "/api/v1/news/inbox/",
            headers={**self.web_headers(), "Content-Type": "application/x-www-form-urlencoded"},
            body=urllib.parse.urlencode(fields).encode(),
        )

    def rest_direct_inbox(self) -> dict[str, Any]:
        self._ensure_bootstrapped()
        url = BASE_URL + "/api/v1/direct_v2/inbox/?persistentBadging=true"
        return self.request_json_with_refresh("GET", url, headers=self.web_headers())

    def upload_story_image(self, image_path: str, width: int, height: int, caption: str) -> dict[str, Any]:
        self._ensure_bootstrapped()
        with open(image_path, "rb") as handle:
            image_bytes = handle.read()
        upload_id = str(int(time.time() * 1000))
        entity_name = f"fb_uploader_{upload_id}"
        rupload_params = {
            "media_type": 1,
            "upload_id": upload_id,
            "upload_media_height": height,
            "upload_media_width": width,
        }
        upload_headers = self.rupload_headers(
            entity_name=entity_name,
            entity_type="image/jpeg",
            entity_length=len(image_bytes),
            rupload_params=rupload_params,
        )
        upload_response = self.request_json_with_refresh(
            "POST",
            f"https://i.instagram.com/rupload_igphoto/{entity_name}",
            headers=upload_headers,
            body=image_bytes,
        )

        configure_fields = {
            "caption": caption,
            "configure_mode": "1",
            "share_to_facebook": "",
            "share_to_fb_destination_id": "",
            "share_to_fb_destination_type": "USER",
            "upload_id": upload_id,
        }
        state = self._state()
        if state.csrf_token:
            configure_fields["jazoest"] = jazoest(state.csrf_token)
        configure_response = self.request_json_with_refresh(
            "POST",
            BASE_URL + "/api/v1/media/configure_to_story/",
            headers={**self.web_headers(), "Content-Type": "application/x-www-form-urlencoded"},
            body=urllib.parse.urlencode(configure_fields).encode(),
        )
        return {
            "upload_id": upload_id,
            "entity_name": entity_name,
            "upload": upload_response,
            "configure": configure_response,
        }

    def delete_story(self, media_id: str, username: str | None) -> dict[str, Any]:
        self._ensure_bootstrapped()
        if username:
            self.refresh_story_doc_ids(username)
        return self.graphql_post(
            self.doc_id("delete-story"),
            {"mediaId": media_id},
            friendly_name=OPERATION_NAMES["delete-story"],
            root_field_name="xdt_api__v1__create__delete",
            endpoint="/graphql/query",
        )

    def exported_credentials(self) -> dict[str, str]:
        mappings = {
            "sessionId": "sessionid",
            "csrfToken": "csrftoken",
            "dsUserId": "ds_user_id",
            "mid": "mid",
            "rur": "rur",
            "igDid": "ig_did",
        }
        return {
            output_name: value
            for output_name, cookie_name in mappings.items()
            if (value := cookie_value(self.cookie_jar, cookie_name))
        }

    def web_headers(self) -> dict[str, str]:
        state = self._state()
        headers = {
            "User-Agent": self.user_agent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": BASE_URL,
            "Referer": BASE_URL + "/",
            "X-ASBD-ID": ASBD_ID,
            "X-IG-App-ID": WEB_APP_ID_MOBILE,
            "X-IG-Max-Touch-Points": "5",
            "X-Web-Session-ID": self.web_session_id,
        }
        if state.csrf_token:
            headers["X-CSRFToken"] = state.csrf_token
        if state.lsd:
            headers["X-FB-LSD"] = state.lsd
        if state.device_id:
            headers["X-Web-Device-Id"] = state.device_id
        if state.machine_id:
            headers["X-Mid"] = state.machine_id
        if self.www_claim:
            headers["X-IG-WWW-Claim"] = self.www_claim
        if state.bloks_version_id:
            headers["X-BLOKS-VERSION-ID"] = state.bloks_version_id
        return headers

    def rupload_headers(
        self,
        entity_name: str,
        entity_type: str,
        entity_length: int,
        rupload_params: dict[str, Any],
    ) -> dict[str, str]:
        headers = self.web_headers()
        headers.pop("X-IG-WWW-Claim", None)
        headers.pop("X-Web-Device-Id", None)
        headers.update(
            {
                "Offset": "0",
                "X-Entity-Length": str(entity_length),
                "X-Entity-Name": entity_name,
                "X-Entity-Type": entity_type,
                "X-Instagram-Rupload-Params": json.dumps(rupload_params, separators=(",", ":")),
                "Content-Type": "application/octet-stream",
                "Content-Length": str(entity_length),
            }
        )
        return headers

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

    def request_json_with_refresh(
        self,
        method: str,
        url: str,
        headers: dict[str, str],
        body: bytes | None = None,
    ) -> dict[str, Any]:
        try:
            return self.request_json(method, url, headers, body)
        except InstagramHTTPError as exc:
            if exc.status_code not in {400, 401, 403}:
                raise SystemExit(str(exc)) from exc
            self.refresh_state()
            refreshed_headers = {**headers, **self.web_headers()}
            try:
                return self.request_json(method, url, refreshed_headers, body)
            except InstagramHTTPError as retry_exc:
                raise SystemExit(str(retry_exc)) from retry_exc

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
                claim = response.headers.get("x-ig-set-www-claim") or response.headers.get("x-ig-www-claim")
                if claim:
                    self.www_claim = claim
                charset = response.headers.get_content_charset() or "utf-8"
                return response.read().decode(charset, errors="replace")
        except urllib.error.HTTPError as exc:
            body_text = exc.read().decode("utf-8", errors="replace")
            raise InstagramHTTPError(exc.code, method, url, body_text) from exc

    def _base_page_headers(self) -> dict[str, str]:
        return {
            "User-Agent": self.user_agent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        }

    def _base_asset_headers(self) -> dict[str, str]:
        return {
            "User-Agent": self.user_agent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": BASE_URL + "/",
        }

    def _seed_cookies(self, credentials: dict[str, Any]) -> None:
        mappings = {
            "sessionid": credentials.get("sessionid") or credentials.get("sessionId"),
            "csrftoken": credentials.get("csrftoken") or credentials.get("csrfToken"),
            "ds_user_id": credentials.get("ds_user_id") or credentials.get("dsUserId"),
            "mid": credentials.get("mid"),
            "rur": credentials.get("rur"),
            "ig_did": credentials.get("ig_did") or credentials.get("igDid"),
        }
        for name, value in mappings.items():
            if value:
                self.cookie_jar.set_cookie(make_cookie(name, str(value)))

    def _ensure_bootstrapped(self) -> None:
        if self.state is None:
            self.bootstrap()

    def _state(self) -> WebState:
        if self.state is None:
            raise RuntimeError("Client is not bootstrapped")
        return self.state


def parse_web_state(html: str) -> WebState:
    decoded = unescape(html)
    state = WebState(html=html)

    state.revision = first_match(decoded, r'"rev"\s*:\s*(\d+)')
    state.hsi = first_match(decoded, r'"hsi"\s*:\s*"?([0-9]+)"?')
    state.haste_session = first_match(decoded, r'"haste_session"\s*:\s*"([^"]+)"')
    state.spin_t = first_match(decoded, r'"__spin_t"\s*:\s*(\d+)') or first_match(decoded, r'"spin_t"\s*:\s*(\d+)')
    state.user_id = first_match(decoded, r'"USER_ID"\s*:\s*"([0-9]+)"')
    state.lsd = first_match(decoded, r'"LSD"[^\n]*?"token"\s*:\s*"([^"]+)"') or first_match(
        decoded, r'"token"\s*:\s*"([A-Za-z0-9_\-]+)"[^\n]{0,120}"LSD"'
    )
    state.fb_dtsg = first_match(decoded, r'"DTSGInitialData"[^\n]*?"token"\s*:\s*"([^"]*)"')
    state.csrf_token = first_match(decoded, r'"csrf_token"\s*:\s*"([^"]+)"')
    state.device_id = first_match(decoded, r'"device_id"\s*:\s*"([^"]+)"')
    state.machine_id = first_match(decoded, r'"machine_id"\s*:\s*"([^"]+)"')
    state.bloks_version_id = first_match(decoded, r'"WebBloksVersioningID"[^\n]*?"versioningID"\s*:\s*"([^"]+)"')

    return state


def parse_doc_ids(source: str) -> dict[str, str]:
    return {name: doc_id for name, doc_id in OPERATION_RE.findall(source)}


def script_urls(html: str) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for match in re.finditer(r'<script\b[^>]*\bsrc="([^"]+)"', html):
        url = unescape(match.group(1))
        if url.startswith("data:") or "static.cdninstagram.com" not in url:
            continue
        absolute = urllib.parse.urljoin(BASE_URL + "/", url)
        if absolute not in seen:
            seen.add(absolute)
            urls.append(absolute)
    return urls


class InstagramHTTPError(Exception):
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
        command = [sys.executable, SIM_PREFS_SCRIPT, "--raw-key", SIM_INSTAGRAM_FALLBACK_KEY]
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return json.loads(result.stdout)
    raise SystemExit("Pass --simulator, --credentials-file, or --credentials-json")


def make_cookie(name: str, value: str) -> Cookie:
    return Cookie(
        version=0,
        name=name,
        value=value,
        port=None,
        port_specified=False,
        domain=".instagram.com",
        domain_specified=True,
        domain_initial_dot=True,
        path="/",
        path_specified=True,
        secure=True,
        expires=None,
        discard=True,
        comment=None,
        comment_url=None,
        rest={},
        rfc2109=False,
    )


def cookie_value(cookie_jar: http.cookiejar.CookieJar, name: str) -> str | None:
    for cookie in cookie_jar:
        if cookie.name == name:
            return cookie.value
    return None


def first_match(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text)
    return match.group(1) if match else None


def random_base36(length: int) -> str:
    alphabet = string.ascii_lowercase + string.digits
    return "".join(random.choice(alphabet) for _ in range(length))


def request_id(count: int) -> str:
    alphabet = string.ascii_lowercase + string.digits
    value = count + 1
    result = ""
    while value:
        value, remainder = divmod(value, len(alphabet))
        result = alphabet[remainder] + result
    return result or "1"


def jazoest(token: str) -> str:
    return "2" + str(sum(ord(char) for char in token))


def summarize(value: Any, max_depth: int = 3) -> Any:
    if max_depth <= 0:
        if isinstance(value, dict):
            return {"...": f"{len(value)} keys"}
        if isinstance(value, list):
            return [f"... {len(value)} items"]
        return value
    if isinstance(value, dict):
        return {key: summarize(value[key], max_depth - 1) for key in list(value.keys())[:12]}
    if isinstance(value, list):
        return [summarize(item, max_depth - 1) for item in value[:3]]
    return value


def truncate(value: str, limit: int) -> str:
    return value if len(value) <= limit else value[:limit] + "..."


def print_json(value: Any, raw: bool) -> None:
    output = value if raw else summarize(value)
    print(json.dumps(output, indent=2, sort_keys=True))


def write_output(path: str | None, value: Any) -> None:
    if not path:
        return
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate Instagram web API calls using captured app cookies.")
    parser.add_argument("--simulator", action="store_true", help="Read Instagram credentials from the booted simulator fallback store.")
    parser.add_argument("--credentials-file", help="Path to credentials JSON, or '-' for stdin.")
    parser.add_argument("--credentials-json", help="Credentials JSON string.")
    parser.add_argument(
        "--user-agent",
        default=IPHONE_SAFARI_UA,
        help="Browser user agent to use for homepage and web API calls.",
    )
    parser.add_argument("--raw-output", action="store_true", help="Print full JSON responses instead of summaries. May expose account data.")
    parser.add_argument("--output", help="Write full JSON response for request commands to this path.")
    parser.add_argument("--save-credentials", help="Write updated cookie credentials to this JSON path after the command.")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("bootstrap", help="Load homepage and print extracted token/config presence.")
    subparsers.add_parser("refresh", help="Refresh web runtime state and print updated cookie/token presence.")
    docids = subparsers.add_parser("docids", help="Load homepage assets and print discovered GraphQL operation doc IDs.")
    docids.add_argument("--story-username", help="Also load /stories/<username>/ assets before scanning for doc IDs.")
    subparsers.add_parser("activity", help="Call PolarisActivityFeedStoriesViewQuery.")
    subparsers.add_parser("stories-tray", help="Call PolarisStoriesV3TrayContainerQuery.")
    subparsers.add_parser("news-inbox", help="Call web-visible REST /api/v1/news/inbox/.")
    subparsers.add_parser("direct-inbox", help="Call web-visible REST /api/v1/direct_v2/inbox/.")

    profile = subparsers.add_parser("profile", help="Call PolarisProfilePageContentQuery.")
    profile.add_argument("user_id", help="Instagram numeric user ID.")

    standalone = subparsers.add_parser("reels-media", help="Call PolarisStoriesV3ReelPageStandaloneQuery.")
    standalone.add_argument("reel_id", help="Reel/user ID.")
    standalone.add_argument("--media-id", default="", help="Optional initial media ID.")

    upload = subparsers.add_parser("upload-story-image", help="Upload a JPEG as an Instagram story. Requires --confirm-upload.")
    upload.add_argument("--image", required=True, help="Path to JPEG image bytes.")
    upload.add_argument("--width", type=int, required=True, help="Image width in pixels.")
    upload.add_argument("--height", type=int, required=True, help="Image height in pixels.")
    upload.add_argument("--caption", default="", help="Story caption text.")
    upload.add_argument("--confirm-upload", action="store_true", help="Required to actually publish the story.")

    delete = subparsers.add_parser("delete-story", help="Delete an Instagram story by numeric media ID. Requires --confirm-delete.")
    delete.add_argument("media_id", help="Numeric story media ID without the owner suffix.")
    delete.add_argument("--story-username", help="Username whose story page should be loaded to discover the current delete doc ID.")
    delete.add_argument("--confirm-delete", action="store_true", help="Required to actually delete the story.")

    custom = subparsers.add_parser("graphql", help="Call a custom GraphQL doc ID.")
    custom.add_argument("doc_id", help="GraphQL document ID.")
    custom.add_argument("variables", help="Variables JSON string or @path.")
    custom.add_argument("--post", action="store_true", help="Use POST /api/graphql instead of GET /graphql/query/.")

    return parser


def load_variables(value: str) -> dict[str, Any]:
    if value.startswith("@"):
        with open(value[1:], "r", encoding="utf-8") as handle:
            return json.load(handle)
    return json.loads(value)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    credentials = load_credentials(args)
    client = InstagramWebClient(credentials, args.user_agent)

    if args.command == "bootstrap" or args.command == "refresh":
        state = client.refresh_state()
        if args.save_credentials:
            write_output(args.save_credentials, client.exported_credentials())
        print_json(
            {
                "cookies": {cookie.name: "present" for cookie in client.cookie_jar},
                "tokens": {
                    "csrf_token": bool(state.csrf_token),
                    "lsd": bool(state.lsd),
                    "fb_dtsg": bool(state.fb_dtsg),
                    "user_id": state.user_id or None,
                    "revision": state.revision,
                    "hsi": bool(state.hsi),
                    "haste_session": state.haste_session,
                    "device_id": bool(state.device_id),
                    "machine_id": bool(state.machine_id),
                    "bloks_version_id": bool(state.bloks_version_id),
                },
            },
            raw=True,
        )
        return

    if args.command == "docids":
        extra_pages = None
        if args.story_username:
            username = args.story_username.strip().lstrip("@")
            extra_pages = [BASE_URL + f"/stories/{urllib.parse.quote(username)}/"]
        doc_ids = client.discover_doc_ids(extra_pages)
        if args.output:
            write_output(args.output, doc_ids)
        print_json(doc_ids, raw=True)
        return

    if args.command == "activity":
        result = client.graphql_get(client.doc_id("activity"), DEFAULT_VARIABLES["activity"])
    elif args.command == "stories-tray":
        result = client.graphql_get(client.doc_id("stories-tray"), DEFAULT_VARIABLES["stories-tray"])
    elif args.command == "news-inbox":
        result = client.rest_news_inbox()
    elif args.command == "direct-inbox":
        result = client.rest_direct_inbox()
    elif args.command == "profile":
        result = client.graphql_get(client.doc_id("profile-content"), {"enable_integrity_filters": True, "id": args.user_id})
    elif args.command == "reels-media":
        result = client.graphql_get(
            client.doc_id("reels-media-standalone"),
            {"media_id": args.media_id, "reel_ids_arr": [args.reel_id]},
        )
    elif args.command == "upload-story-image":
        if not args.confirm_upload:
            raise SystemExit("Refusing to upload without --confirm-upload")
        result = client.upload_story_image(args.image, args.width, args.height, args.caption)
    elif args.command == "delete-story":
        if not args.confirm_delete:
            raise SystemExit("Refusing to delete without --confirm-delete")
        result = client.delete_story(args.media_id, args.story_username)
    elif args.command == "graphql":
        variables = load_variables(args.variables)
        result = client.graphql_post(args.doc_id, variables) if args.post else client.graphql_get(args.doc_id, variables)
    else:
        raise SystemExit(f"Unknown command: {args.command}")

    write_output(args.output, result)
    if args.save_credentials:
        write_output(args.save_credentials, client.exported_credentials())
    print_json(result, raw=args.raw_output)


if __name__ == "__main__":
    main()
