#!/usr/bin/env python3

"""Probe X web APIs using cookies captured by the app login flow.

The script is intentionally dependency-free so it can run with system Python.
It supports credentials from either a JSON file/stdin or the simulator UserDefaults
fallback used by this project during development.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


BASE_URL = "https://x.com"
BEARER_TOKEN = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
SEARCH_TIMELINE_QUERY_ID = "hz_94eVAtrtQo_vO3my7Rw"
APP_USER_AGENT = "NoFeedSocial/1"
SIM_PREFS_SCRIPT = os.path.expanduser(
    "~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py"
)
SIM_X_FALLBACK_KEY = "tech.stupid.StupidSocial.credentials.x.localFallback"

SEARCH_TIMELINE_FEATURES = {
    "rweb_video_screen_enabled": False,
    "rweb_cashtags_enabled": True,
    "profile_label_improvements_pcf_label_in_post_enabled": True,
    "responsive_web_profile_redirect_enabled": False,
    "rweb_tipjar_consumption_enabled": False,
    "verified_phone_label_enabled": False,
    "creator_subscriptions_tweet_preview_api_enabled": True,
    "responsive_web_graphql_timeline_navigation_enabled": True,
    "responsive_web_graphql_skip_user_profile_image_extensions_enabled": False,
    "premium_content_api_read_enabled": False,
    "communities_web_enable_tweet_community_results_fetch": True,
    "c9s_tweet_anatomy_moderator_badge_enabled": True,
    "responsive_web_grok_analyze_button_fetch_trends_enabled": False,
    "responsive_web_grok_analyze_post_followups_enabled": True,
    "rweb_cashtags_composer_attachment_enabled": True,
    "responsive_web_jetfuel_frame": True,
    "responsive_web_grok_share_attachment_enabled": True,
    "responsive_web_grok_annotations_enabled": True,
    "articles_preview_enabled": True,
    "responsive_web_edit_tweet_api_enabled": True,
    "rweb_conversational_replies_downvote_enabled": False,
    "graphql_is_translatable_rweb_tweet_is_translatable_enabled": True,
    "view_counts_everywhere_api_enabled": True,
    "longform_notetweets_consumption_enabled": True,
    "responsive_web_twitter_article_tweet_consumption_enabled": True,
    "content_disclosure_indicator_enabled": True,
    "content_disclosure_ai_generated_indicator_enabled": True,
    "responsive_web_grok_show_grok_translated_post": True,
    "responsive_web_grok_analysis_button_from_backend": True,
    "post_ctas_fetch_enabled": False,
    "freedom_of_speech_not_reach_fetch_enabled": True,
    "standardized_nudges_misinfo": True,
    "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": True,
    "longform_notetweets_rich_text_read_enabled": True,
    "longform_notetweets_inline_media_enabled": False,
    "responsive_web_grok_image_annotation_enabled": True,
    "responsive_web_grok_imagine_annotation_enabled": True,
    "responsive_web_grok_community_note_auto_translation_is_enabled": True,
    "responsive_web_enhance_cards_enabled": False,
}


class XWebClient:
    def __init__(self, credentials: dict[str, Any]) -> None:
        self.credentials = credentials
        self.opener = urllib.request.build_opener()

    def bootstrap(self) -> dict[str, Any]:
        return {
            "credentials": credential_presence(self.credentials),
            "auth_ready": bool(self.auth_token() and self.ct0()),
        }

    def search_users(self, query: str) -> dict[str, Any]:
        query = query.strip()
        if not query:
            return {"status": "ok", "query": query, "users": []}
        variables = {
            "rawQuery": query,
            "count": 20,
            "querySource": "typed_query",
            "product": "People",
            "withGrokTranslatedBio": True,
            "withQuickPromoteEligibilityTweetFields": False,
        }
        response = self.request_json(
            "POST",
            BASE_URL + f"/i/api/graphql/{SEARCH_TIMELINE_QUERY_ID}/SearchTimeline",
            body=json.dumps(
                {
                    "variables": variables,
                    "features": SEARCH_TIMELINE_FEATURES,
                    "queryId": SEARCH_TIMELINE_QUERY_ID,
                },
                separators=(",", ":"),
            ).encode(),
        )
        return {
            "status": "ok",
            "query": query,
            "users": summarize_search_timeline_users(response),
            "raw": response,
        }

    def request_json(self, method: str, url: str, body: bytes | None = None) -> Any:
        request = urllib.request.Request(url, data=body, headers=self.headers(), method=method)
        try:
            with self.opener.open(request, timeout=30) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                text = response.read().decode(charset, errors="replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"HTTP {exc.code} {method} {url}\n{truncate(body, 1200)}") from exc
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Expected JSON from {url}, got {len(text)} bytes: {exc}") from exc

    def headers(self) -> dict[str, str]:
        ct0 = self.ct0()
        return {
            "Authorization": f"Bearer {BEARER_TOKEN}",
            "Cookie": f"auth_token={self.auth_token()}; ct0={ct0}",
            "X-Csrf-Token": ct0,
            "User-Agent": APP_USER_AGENT,
        }

    def auth_token(self) -> str:
        token = str(self.credentials.get("authToken") or self.credentials.get("auth_token") or "")
        if not token:
            raise SystemExit("X authToken/auth_token cookie is required")
        return token

    def ct0(self) -> str:
        token = str(self.credentials.get("ct0") or "")
        if not token:
            raise SystemExit("X ct0 cookie is required")
        return token


def load_credentials(args: argparse.Namespace) -> dict[str, Any]:
    if args.credentials_json:
        return json.loads(args.credentials_json)
    if args.credentials_file:
        if args.credentials_file == "-":
            return json.load(sys.stdin)
        with open(args.credentials_file, "r", encoding="utf-8") as handle:
            return json.load(handle)
    if args.simulator:
        command = [sys.executable, SIM_PREFS_SCRIPT, "--raw-key", SIM_X_FALLBACK_KEY]
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return json.loads(result.stdout)
    raise SystemExit("Pass --simulator, --credentials-file, or --credentials-json")


def credential_presence(credentials: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in credentials.items():
        if key in {"authToken", "auth_token", "ct0"} and value:
            result[key] = f"present ({len(str(value))} chars)"
        elif key in {"authToken", "auth_token", "ct0"}:
            result[key] = "missing"
        else:
            result[key] = str(value) if value is not None else "null"
    return result


def summarize_search_timeline_users(response: dict[str, Any]) -> list[dict[str, Any]]:
    users: list[dict[str, Any]] = []
    seen: set[str] = set()

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            if value.get("__typename") == "TimelineUser" and isinstance(value.get("user_results"), dict):
                append_user(value["user_results"].get("result", {}))
            elif value.get("itemType") == "TimelineUser" and isinstance(value.get("user_results"), dict):
                append_user(value["user_results"].get("result", {}))
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    def append_user(user: dict[str, Any]) -> None:
        legacy = user.get("legacy", {}) if isinstance(user.get("legacy"), dict) else {}
        core = user.get("core", {}) if isinstance(user.get("core"), dict) else {}
        username = core.get("screen_name") or legacy.get("screen_name")
        user_id = user.get("rest_id") or legacy.get("id_str") or user.get("id") or username
        if not username or str(user_id) in seen:
            return
        seen.add(str(user_id))
        avatar = None
        if isinstance(user.get("avatar"), dict):
            avatar = user["avatar"].get("image_url")
        users.append(
            {
                "id": user_id,
                "username": username,
                "display_name": core.get("name") or legacy.get("name"),
                "description": legacy.get("description"),
                "followers_count": legacy.get("followers_count"),
                "following_count": legacy.get("friends_count"),
                "is_verified": user.get("is_blue_verified") or legacy.get("verified"),
                "profile_image_url": avatar or legacy.get("profile_image_url_https"),
            }
        )

    visit(response)
    return users


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
        return value
    if isinstance(value, dict):
        return {key: summarize(value[key], max_depth - 1) for key in list(value.keys())[:12]}
    if isinstance(value, list):
        return [summarize(item, max_depth - 1) for item in value[:3]]
    return value


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
    parser = argparse.ArgumentParser(description="Validate X web API calls using captured app cookies.")
    parser.add_argument("--simulator", action="store_true", help="Read X credentials from the booted simulator fallback store.")
    parser.add_argument("--credentials-file", help="Path to credentials JSON, or '-' for stdin.")
    parser.add_argument("--credentials-json", help="Credentials JSON string.")
    parser.add_argument("--summary", action="store_true", help="Print compact summarized JSON instead of full responses.")
    parser.add_argument("--output", help="Write full JSON response for request commands to this path.")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("bootstrap", help="Print credential presence without making an X API request.")
    search_users = subparsers.add_parser("search-users", help="Search X users through the web API endpoint used by the app.")
    search_users.add_argument("query", help="Search query.")
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    credentials = load_credentials(args)
    client = XWebClient(credentials)

    if args.command == "bootstrap":
        result = client.bootstrap()
    elif args.command == "search-users":
        result = client.search_users(args.query)
    else:
        raise SystemExit(f"Unknown command: {args.command}")

    write_output(args.output, result)
    print_json(result, summary=args.summary)


if __name__ == "__main__":
    main()
