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
NOTIFICATIONS_TIMELINE_QUERY_ID = "8kmedJD_u653xqEjZIS7yA"
# Post reads and engagement, as X's web client sends them: query ids, variables and feature
# switches come from its `main.<hash>.js` bundle (`queryId:"…",operationName:"…",metadata:{featureSwitches:[…]}`),
# and the switch values from the `featureSwitch` config in the signed-in https://x.com/home page.
TWEET_QUERY_IDS = {
    "TweetResultByRestId": "U8lc5aomF5krJzZ9vJ9wxg",
    "FavoriteTweet": "lI07N6Otwv1PhnEgXILM7A",
    "UnfavoriteTweet": "ZYKSe-w7KEslx3JhSIk5LA",
    "CreateRetweet": "mbRO74GrOvSfRcJnlMapnQ",
    "DeleteRetweet": "ZyZigVsNiFO6v1dEks1eWg",
    "CreateTweet": "l4hk8uVGvR-a8kzQ4nOhPA",
    "DeleteTweet": "nxpZCY2K-I6QoFHAHeojFQ",
    "TweetDetail": "qpemjmVMoTWDvcRT43JIVQ",
}
TWEET_FEATURES = {
    "creator_subscriptions_tweet_preview_api_enabled": True,
    "premium_content_api_read_enabled": False,
    "communities_web_enable_tweet_community_results_fetch": True,
    "c9s_tweet_anatomy_moderator_badge_enabled": True,
    "responsive_web_grok_analyze_button_fetch_trends_enabled": False,
    "responsive_web_grok_analyze_post_followups_enabled": False,
    "rweb_cashtags_composer_attachment_enabled": True,
    "responsive_web_jetfuel_frame": True,
    "rweb_sports_post_context_enabled": True,
    "x_elections_post_context_enabled": True,
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
    "rweb_cashtags_enabled": True,
    "freedom_of_speech_not_reach_fetch_enabled": True,
    "standardized_nudges_misinfo": True,
    "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": True,
    "longform_notetweets_rich_text_read_enabled": True,
    "longform_notetweets_inline_media_enabled": False,
    "profile_label_improvements_pcf_label_in_post_enabled": True,
    "responsive_web_profile_redirect_enabled": True,
    "rweb_tipjar_consumption_enabled": False,
    "verified_phone_label_enabled": False,
    "responsive_web_nested_quote_preview_enabled": True,
    "responsive_web_grok_image_annotation_enabled": True,
    "responsive_web_grok_imagine_annotation_enabled": True,
    "responsive_web_made_on_x_label_enabled": False,
    "responsive_web_grok_community_note_auto_translation_is_enabled": True,
    "responsive_web_graphql_timeline_navigation_enabled": True,
}
APP_USER_AGENT = "StupidSocial/1"
SIM_PREFS_SCRIPT = os.path.expanduser(
    "~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py"
)
SIM_X_FALLBACK_KEY = "tech.stupid.StupidSocial.credentials.x.localFallback"
ENV_LOCAL_CREDENTIALS_KEY = "DIAGNOSE_X_CREDS"

DM_QUERY = {
    "dm_users": "true",
    "include_groups": "true",
    "include_inbox_timelines": "true",
    "include_ext_media_color": "true",
    "supports_reactions": "true",
    "supports_edit": "true",
    "include_ext_edit_control": "true",
    "include_ext_is_blue_verified": "1",
    "ext": "mediaColor,altText,mediaStats",
}

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

NOTIFICATIONS_TIMELINE_FEATURES = {
    "rweb_video_screen_enabled": False,
    "rweb_cashtags_enabled": True,
    "profile_label_improvements_pcf_label_in_post_enabled": True,
    "responsive_web_profile_redirect_enabled": True,
    "rweb_tipjar_consumption_enabled": False,
    "verified_phone_label_enabled": False,
    "creator_subscriptions_tweet_preview_api_enabled": True,
    "responsive_web_graphql_timeline_navigation_enabled": True,
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

    def tweet(self, tweet_id: str) -> dict[str, Any]:
        """One post with the viewer's engagement state (favorited, retweeted) and its counts."""
        variables = {"tweetId": tweet_id, "withCommunity": False, "includePromotedContent": False, "withVoice": False}
        query = urllib.parse.urlencode(
            {
                "variables": json.dumps(variables, separators=(",", ":")),
                "features": json.dumps(TWEET_FEATURES, separators=(",", ":")),
            }
        )
        query_id = TWEET_QUERY_IDS["TweetResultByRestId"]
        response = self.request_json("GET", BASE_URL + f"/i/api/graphql/{query_id}/TweetResultByRestId?{query}")
        result = ((response.get("data") or {}).get("tweetResult") or {}).get("result") or {}
        result = result.get("tweet") or result
        legacy = result.get("legacy") or {}
        fields = ["favorited", "retweeted", "favorite_count", "retweet_count", "reply_count", "quote_count"]
        return {
            "typename": result.get("__typename"),
            "rest_id": result.get("rest_id"),
            "state": {field: legacy.get(field) for field in fields},
            "views": (result.get("views") or {}).get("count"),
            "raw": response,
        }

    def thread(self, tweet_id: str, cursor: str | None = None) -> dict[str, Any]:
        """The conversation around a post (`TweetDetail`): its ancestors, the post, and reply threads below it."""
        variables: dict[str, Any] = {
            "focalTweetId": tweet_id,
            "referrer": "tweet",
            "rankingMode": "Relevance",
            "includePromotedContent": False,
            "withCommunity": True,
            "withQuickPromoteEligibilityTweetFields": False,
            "withBirdwatchNotes": True,
            "withVoice": True,
        }
        if cursor:
            variables["cursor"] = cursor
        features = {**TWEET_FEATURES, "rweb_video_screen_enabled": False, "responsive_web_enhance_cards_enabled": False}
        query = urllib.parse.urlencode(
            {
                "variables": json.dumps(variables, separators=(",", ":")),
                "features": json.dumps(features, separators=(",", ":")),
            }
        )
        query_id = TWEET_QUERY_IDS["TweetDetail"]
        response = self.request_json("GET", BASE_URL + f"/i/api/graphql/{query_id}/TweetDetail?{query}")
        return {"entries": summarize_thread(response), "raw": response}

    def tweet_mutation(self, operation: str, variables: dict[str, Any], features: dict[str, Any] | None = None) -> Any:
        query_id = TWEET_QUERY_IDS[operation]
        body: dict[str, Any] = {"variables": variables, "queryId": query_id}
        if features is not None:
            body["features"] = features
        headers = {"Content-Type": "application/json"}
        return self.request_json(
            "POST",
            BASE_URL + f"/i/api/graphql/{query_id}/{operation}",
            body=json.dumps(body, separators=(",", ":")).encode(),
            extra_headers=headers,
        )

    def set_liked(self, tweet_id: str, liked: bool) -> Any:
        if liked:
            return self.tweet_mutation("FavoriteTweet", {"tweet_id": tweet_id})
        return self.tweet_mutation("UnfavoriteTweet", {"tweet_id": tweet_id})

    def set_retweeted(self, tweet_id: str, retweeted: bool) -> Any:
        if retweeted:
            return self.tweet_mutation("CreateRetweet", {"tweet_id": tweet_id})
        return self.tweet_mutation("DeleteRetweet", {"source_tweet_id": tweet_id})

    def create_tweet(self, text: str, reply_to: str | None = None, quote: str | None = None) -> Any:
        variables: dict[str, Any] = {
            "tweet_text": text,
            "media": {"media_entities": [], "possibly_sensitive": False},
            "semantic_annotation_ids": [],
        }
        if reply_to:
            variables["reply"] = {"in_reply_to_tweet_id": reply_to, "exclude_reply_user_ids": []}
        if quote:
            variables["attachment_url"] = f"https://x.com/i/status/{quote}"
        features = {k: v for k, v in TWEET_FEATURES.items() if k != "creator_subscriptions_tweet_preview_api_enabled"}
        response = self.tweet_mutation("CreateTweet", variables, features)
        result = ((((response.get("data") or {}).get("create_tweet") or {}).get("tweet_results") or {}).get("result")) or {}
        return {"rest_id": result.get("rest_id"), "errors": response.get("errors")}

    def delete_tweet(self, tweet_id: str) -> Any:
        return self.tweet_mutation("DeleteTweet", {"tweet_id": tweet_id})

    def request_json(
        self, method: str, url: str, body: bytes | None = None, extra_headers: dict[str, str] | None = None
    ) -> Any:
        request = urllib.request.Request(url, data=body, headers={**self.headers(), **(extra_headers or {})}, method=method)
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

    def set_following(self, user_id: str, follow: bool) -> dict[str, Any]:
        return self.friendships_mutation("create" if follow else "destroy", {"user_id": user_id})

    def set_notifications(self, user_id: str, enabled: bool) -> dict[str, Any]:
        return self.friendships_mutation(
            "update",
            {"id": user_id, "cursor": "-1", "device": "true" if enabled else "false"},
        )

    def friendships_mutation(self, path: str, extra: dict[str, str]) -> dict[str, Any]:
        fields = {
            "include_profile_interstitial_type": "1",
            "include_blocking": "1",
            "include_blocked_by": "1",
            "include_followed_by": "1",
            "include_want_retweets": "1",
            "include_mute_edge": "1",
            "include_can_dm": "1",
            "include_can_media_tag": "1",
            "include_ext_is_blue_verified": "1",
            "include_ext_verified_type": "1",
            "include_ext_profile_image_shape": "1",
            "skip_status": "1",
        }
        fields.update(extra)
        body = urllib.parse.urlencode(fields).encode()
        headers = self.headers()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        request = urllib.request.Request(
            BASE_URL + f"/i/api/1.1/friendships/{path}.json",
            data=body,
            headers=headers,
            method="POST",
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                text = response.read().decode(charset, errors="replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"HTTP {exc.code} POST friendships/{path}\n{truncate(body, 1200)}") from exc
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Expected JSON for friendships/{path}, got {len(text)} bytes: {exc}") from exc

    def notifications(self, count: int = 40) -> dict[str, Any]:
        variables = {"timeline_type": "All", "count": count}
        query = urllib.parse.urlencode(
            {
                "variables": json.dumps(variables, separators=(",", ":")).encode(),
                "features": json.dumps(NOTIFICATIONS_TIMELINE_FEATURES, separators=(",", ":")).encode(),
            }
        )
        response = self.request_json(
            "GET",
            BASE_URL + f"/i/api/graphql/{NOTIFICATIONS_TIMELINE_QUERY_ID}/NotificationsTimeline?{query}",
        )
        summary = summarize_notifications(response)
        summary["top_cursor"] = notification_top_cursor(response)
        return summary

    def unread_count(self) -> int:
        response = self.request_json(
            "GET",
            BASE_URL + "/i/api/2/notifications/all/unread_count.json",
        )
        return int(response.get("unread_count") or 0)

    def mark_notifications_read(self, cursor: str) -> dict[str, Any]:
        url = (
            BASE_URL
            + "/i/api/2/notifications/all/last_seen_cursor.json?"
            + urllib.parse.urlencode({"cursor": cursor})
        )
        request = urllib.request.Request(url, headers=self.headers(), method="POST")
        try:
            with self.opener.open(request, timeout=30) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                text = response.read().decode(charset, errors="replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"HTTP {exc.code} POST notifications/all/last_seen_cursor\n{truncate(body, 1200)}") from exc
        try:
            return json.loads(text) if text else {}
        except json.JSONDecodeError as exc:
            raise SystemExit(f"Expected JSON for notifications/all/last_seen_cursor, got {len(text)} bytes: {exc}") from exc

    def load_notifications(self, count: int = 40) -> dict[str, Any]:
        summary = self.notifications(count=count)
        cursor = summary.get("top_cursor")
        if not cursor:
            raise SystemExit("X notifications response did not include a top cursor")
        summary["mark_read_response"] = self.mark_notifications_read(cursor)
        summary["unread_count_after"] = self.unread_count()
        return summary

    def dm_inbox(self) -> dict[str, Any]:
        """Legacy (plaintext) DM inbox: conversations, their latest events, and the users in them."""
        response = self.request_json("GET", BASE_URL + "/i/api/1.1/dm/inbox_initial_state.json?" + urllib.parse.urlencode(DM_QUERY))
        state = response.get("inbox_initial_state") or {}
        return {"status": "ok", "summary": summarize_dm_inbox(state), "raw": response}

    def dm_conversation(self, conversation_id: str, max_id: str | None = None) -> dict[str, Any]:
        """One page of a legacy conversation's history, older than `max_id` when given."""
        query = dict(DM_QUERY, context="FETCH_DM_CONVERSATION_HISTORY", include_conversation_info="true")
        if max_id:
            query["max_id"] = max_id
        response = self.request_json(
            "GET",
            BASE_URL + f"/i/api/1.1/dm/conversation/{urllib.parse.quote(conversation_id)}.json?" + urllib.parse.urlencode(query),
        )
        timeline = response.get("conversation_timeline") or {}
        return {
            "status": timeline.get("status"),
            "min_entry_id": timeline.get("min_entry_id"),
            "max_entry_id": timeline.get("max_entry_id"),
            "entry_kinds": count_entry_kinds(timeline.get("entries") or []),
            "raw": response,
        }

    def dm_updates(self, cursor: str) -> dict[str, Any]:
        """Legacy DM events since `cursor` (the inbox's `cursor`), as the app polls while a chat is open."""
        response = self.request_json(
            "GET", BASE_URL + "/i/api/1.1/dm/user_updates.json?" + urllib.parse.urlencode(dict(DM_QUERY, cursor=cursor))
        )
        events = response.get("user_events") or {}
        return {"cursor": events.get("cursor"), "entry_kinds": count_entry_kinds(events.get("entries") or []), "raw": response}

    def dm_unread_count(self) -> dict[str, Any]:
        return self.request_json("GET", BASE_URL + "/i/api/2/badge_count/badge_count.json?supports_ntab_urt=1")

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
    if args.env_local:
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env.local")
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                name, _, value = line.strip().partition("=")
                if name == ENV_LOCAL_CREDENTIALS_KEY:
                    return json.loads(value.strip().strip("'\""))
        raise SystemExit(f"{ENV_LOCAL_CREDENTIALS_KEY} not found in .env.local")
    if args.simulator:
        command = [sys.executable, SIM_PREFS_SCRIPT, "--raw-key", SIM_X_FALLBACK_KEY]
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return json.loads(result.stdout)
    raise SystemExit("Pass --simulator, --env-local, --credentials-file, or --credentials-json")


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


def summarize_dm_inbox(state: dict[str, Any]) -> list[dict[str, Any]]:
    """Conversations newest first, by shape only: no names or message text."""
    rows = []
    for conversation in state.get("conversations", {}).values():
        rows.append(
            {
                "conversation_id_length": len(conversation.get("conversation_id") or ""),
                "type": conversation.get("type"),
                "status": conversation.get("status"),
                "trusted": conversation.get("trusted"),
                "muted": conversation.get("muted"),
                "participants": len(conversation.get("participants") or []),
                "unread": int(conversation.get("last_read_event_id") or 0) < int(conversation.get("max_entry_id") or 0),
                "sort_timestamp": conversation.get("sort_timestamp"),
            }
        )
    return sorted(rows, key=lambda row: -int(row["sort_timestamp"] or 0))


def count_entry_kinds(entries: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for entry in entries:
        for kind in entry:
            counts[kind] = counts.get(kind, 0) + 1
    return counts


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


def summarize_thread(response: dict[str, Any]) -> list[dict[str, Any]]:
    """Each `TweetDetail` entry in order: its id, kind, and the posts in it (id, author, what it replies to)."""
    instructions = ((response.get("data") or {}).get("threaded_conversation_with_injections_v2") or {}).get("instructions") or []

    def post(item_content: dict[str, Any]) -> dict[str, Any] | None:
        result = ((item_content.get("tweet_results") or {}).get("result")) or {}
        result = result.get("tweet") or result
        legacy = result.get("legacy") or {}
        if not legacy:
            return None
        user = ((result.get("core") or {}).get("user_results") or {}).get("result") or {}
        return {
            "id": result.get("rest_id"),
            "author": (user.get("core") or {}).get("screen_name"),
            "in_reply_to": legacy.get("in_reply_to_status_id_str"),
            "display_type": item_content.get("tweetDisplayType"),
        }

    summary = []
    for instruction in instructions:
        for entry in instruction.get("entries") or []:
            content = entry.get("content") or {}
            row: dict[str, Any] = {"entry_id": entry.get("entryId"), "type": content.get("entryType") or content.get("__typename")}
            if content.get("itemContent"):
                row["posts"] = [p for p in [post(content["itemContent"])] if p]
                if content["itemContent"].get("cursorType"):
                    row["cursor"] = content["itemContent"].get("cursorType")
            elif content.get("items"):
                row["posts"] = [p for item in content["items"] for p in [post(((item.get("item") or {}).get("itemContent")) or {})] if p]
                row["more"] = [i.get("entryId") for i in content["items"] if "cursor" in (i.get("entryId") or "")]
            elif content.get("cursorType"):
                row["cursor"] = content.get("cursorType")
            summary.append(row)
    return summary


def summarize_notifications(response: dict[str, Any]) -> dict[str, Any]:
    """Summarize grouped X notifications, focusing on actor ordering.

    Parses the GraphQL `NotificationsTimeline` response: walks the timeline
    instructions and, for each aggregate-engagement entry (liked/retweeted/
    followed), prints the resolved `from_users` order exactly as X serves it
    (the app displays these in the same order, newest-like-first).
    """
    instructions = (
        response.get("data", {})
        .get("viewer_v2", {})
        .get("user_results", {})
        .get("result", {})
        .get("notification_timeline", {})
        .get("timeline", {})
        .get("instructions")
        or []
    )
    entries: list[dict[str, Any]] = []
    for instruction in instructions:
        entries.extend(instruction.get("entries") or [])

    def user_summary(user: dict[str, Any]) -> dict[str, Any]:
        core = user.get("core") or {}
        return {
            "id": user.get("rest_id") or user.get("id"),
            "username": core.get("screen_name"),
            "display_name": core.get("name"),
        }

    grouped: list[dict[str, Any]] = []
    action_elements = {
        "users_liked_your_tweet",
        "users_retweeted_your_tweet",
        "user_liked_multiple_tweets",
        "follow_from_recommended_user",
        "users_followed_you",
    }
    for entry in entries:
        content = entry.get("content") or {}
        item = content.get("itemContent") or {}
        event = (content.get("clientEventInfo") or {}).get("element")
        if event not in action_elements:
            continue
        template = item.get("template") or {}
        resolved = []
        for ref in template.get("from_users") or []:
            user = (ref.get("user_results") or {}).get("result") or {}
            resolved.append(user_summary(user))
        targets = []
        for obj in template.get("target_objects") or []:
            tweet = (obj.get("tweet_results") or {}).get("result") or {}
            targets.append(tweet.get("rest_id"))
        grouped.append(
            {
                "entry_id": entry.get("entryId"),
                "element": event,
                "from_users": [u.get("username") for u in resolved],
                "from_users_detail": resolved,
                "target_tweet_ids": targets,
            }
        )

    return {
        "status": "ok",
        "grouped_count": len(grouped),
        "grouped": grouped,
        "total_entries": len(entries),
    }


def notification_top_cursor(response: dict[str, Any]) -> str | None:
    instructions = (
        response.get("data", {})
        .get("viewer_v2", {})
        .get("user_results", {})
        .get("result", {})
        .get("notification_timeline", {})
        .get("timeline", {})
        .get("instructions")
        or []
    )
    for instruction in instructions:
        for entry in instruction.get("entries") or []:
            content = entry.get("content") or {}
            if content.get("cursorType") == "Top" and content.get("value"):
                return str(content["value"])
    return None


def summarize(value: Any, max_depth: int = 3) -> Any:
    if isinstance(value, dict) and "raw" in value and max_depth == 3:
        return {key: item for key, item in value.items() if key != "raw"}
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
    parser.add_argument("--env-local", action="store_true", help=f"Read X credentials JSON from {ENV_LOCAL_CREDENTIALS_KEY} in .env.local.")
    parser.add_argument("--credentials-file", help="Path to credentials JSON, or '-' for stdin.")
    parser.add_argument("--credentials-json", help="Credentials JSON string.")
    parser.add_argument("--summary", action="store_true", help="Print compact summarized JSON instead of full responses.")
    parser.add_argument("--output", help="Write full JSON response for request commands to this path.")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("bootstrap", help="Print credential presence without making an X API request.")
    notifications = subparsers.add_parser("notifications", help="Fetch the X notifications feed and summarize grouped actor order.")
    notifications.add_argument("--count", type=int, default=40, help="Number of notifications to fetch (default 40).")
    load_notifications = subparsers.add_parser(
        "load-notifications",
        help="Fetch X notifications, advance the server last-seen cursor, and verify the unread count.",
    )
    load_notifications.add_argument("--count", type=int, default=40, help="Number of notifications to fetch (default 40).")
    subparsers.add_parser("unread-count", help="Fetch the server-side X notification unread count.")
    search_users = subparsers.add_parser("search-users", help="Search X users through the web API endpoint used by the app.")
    search_users.add_argument("query", help="Search query.")
    follow = subparsers.add_parser("follow", help="Follow an X user by numeric user id.")
    follow.add_argument("user_id", help="Numeric X user id.")
    unfollow = subparsers.add_parser("unfollow", help="Unfollow an X user by numeric user id.")
    unfollow.add_argument("user_id", help="Numeric X user id.")
    notify = subparsers.add_parser("notify", help="Set post notifications for an X user.")
    notify.add_argument("user_id", help="Numeric X user id.")
    notify.add_argument("enabled", choices=["on", "off"], help="Turn notifications on or off.")
    dm_inbox = subparsers.add_parser("dm-inbox", help="Fetch the legacy (plaintext) DM inbox; --summary prints conversation shapes only.")
    dm_conversation = subparsers.add_parser("dm-conversation", help="Fetch one page of a legacy DM conversation's history.")
    dm_conversation.add_argument("conversation_id", help="Legacy conversation id, e.g. <user_id>-<user_id>.")
    dm_conversation.add_argument("--max-id", help="Fetch events older than this event id.")
    dm_updates = subparsers.add_parser("dm-updates", help="Fetch legacy DM events since an inbox cursor.")
    dm_updates.add_argument("cursor", help="The inbox's `cursor` value.")
    subparsers.add_parser("dm-unread-count", help="Fetch the DM unread badge count.")
    tweet = subparsers.add_parser("tweet", help="Fetch one post with the viewer's like/repost state and counts.")
    tweet.add_argument("tweet_id")
    for name, help_text in [
        ("like", "Like a post."),
        ("unlike", "Remove your like from a post."),
        ("retweet", "Repost a post."),
        ("unretweet", "Undo your repost of a post."),
        ("delete-tweet", "Delete one of your own posts."),
    ]:
        subparsers.add_parser(name, help=help_text).add_argument("tweet_id")
    thread = subparsers.add_parser("thread", help="Fetch the conversation around a post (TweetDetail).")
    thread.add_argument("tweet_id")
    thread.add_argument("--cursor")
    reply = subparsers.add_parser("reply", help="Reply to a post (publishes a post).")
    reply.add_argument("tweet_id")
    reply.add_argument("text")
    quote = subparsers.add_parser("quote", help="Quote a post (publishes a post).")
    quote.add_argument("tweet_id")
    quote.add_argument("text")
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    credentials = load_credentials(args)
    client = XWebClient(credentials)

    if args.command == "bootstrap":
        result = client.bootstrap()
    elif args.command == "notifications":
        result = client.notifications(count=args.count)
    elif args.command == "load-notifications":
        result = client.load_notifications(count=args.count)
    elif args.command == "unread-count":
        result = {"unread_count": client.unread_count()}
    elif args.command == "search-users":
        result = client.search_users(args.query)
    elif args.command == "follow":
        result = client.set_following(args.user_id, True)
    elif args.command == "unfollow":
        result = client.set_following(args.user_id, False)
    elif args.command == "notify":
        result = client.set_notifications(args.user_id, args.enabled == "on")
    elif args.command == "dm-inbox":
        result = client.dm_inbox()
    elif args.command == "dm-conversation":
        result = client.dm_conversation(args.conversation_id, max_id=args.max_id)
    elif args.command == "dm-updates":
        result = client.dm_updates(args.cursor)
    elif args.command == "dm-unread-count":
        result = client.dm_unread_count()
    elif args.command == "thread":
        result = client.thread(args.tweet_id, cursor=args.cursor)
    elif args.command == "tweet":
        result = client.tweet(args.tweet_id)
    elif args.command in ("like", "unlike"):
        result = client.set_liked(args.tweet_id, args.command == "like")
    elif args.command in ("retweet", "unretweet"):
        result = client.set_retweeted(args.tweet_id, args.command == "retweet")
    elif args.command == "delete-tweet":
        result = client.delete_tweet(args.tweet_id)
    elif args.command == "reply":
        result = client.create_tweet(args.text, reply_to=args.tweet_id)
    elif args.command == "quote":
        result = client.create_tweet(args.text, quote=args.tweet_id)
    else:
        raise SystemExit(f"Unknown command: {args.command}")

    write_output(args.output, result)
    print_json(result, summary=args.summary)


if __name__ == "__main__":
    main()
