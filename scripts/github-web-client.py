#!/usr/bin/env python3

"""Probe GitHub's authenticated For You feed HTML endpoint.

The script is intentionally dependency-free so it can run with system Python.
Credentials can come from a browser Cookie header, credentials JSON, or the
simulator UserDefaults fallback used by this project during development.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import Counter
from html.parser import HTMLParser
from typing import Any


BASE_URL = "https://github.com"
FOR_YOU_FEED_URL = BASE_URL + "/conduit/for_you_feed"
APP_USER_AGENT = "NoFeedSocial/1"
DEFAULT_ACCEPT_LANGUAGE = "en-US,en;q=0.9"
SIM_PREFS_SCRIPT = os.path.expanduser(
    "~/.config/opencode/skills/sim-prefs/sim-prefs/scripts/read_prefs.py"
)
SIM_GITHUB_FALLBACK_KEY = "tech.stupid.StupidSocial.credentials.github.localFallback"


class GitHubHTTPError(Exception):
    pass


class GitHubFeedParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.cards: dict[tuple[str, str], dict[str, Any]] = {}
        self.order: list[tuple[str, str]] = []
        self.active_anchor: dict[str, Any] | None = None
        self.div_depth = 0
        self.hidden_div_depths: list[int] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "div":
            self.div_depth += 1
            classes = (values.get("class") or "").split()
            if "Details-content--hidden" in classes:
                self.hidden_div_depths.append(self.div_depth)

        if self.hidden_div_depths:
            return

        if hydro_view := values.get("data-hydro-view"):
            payload = decode_hydro_payload(hydro_view)
            card = payload.get("feed_card")
            if isinstance(card, dict) and card.get("card_type") and card.get("record_id"):
                key = card_key(card)
                if key not in self.cards:
                    self.cards[key] = {"metadata": card, "actions": []}
                    self.order.append(key)

        if hydro_click := values.get("data-hydro-click"):
            payload = decode_hydro_payload(hydro_click)
            card = payload.get("feed_card")
            if isinstance(card, dict) and card.get("card_type") and card.get("record_id"):
                key = card_key(card)
                entry = self.cards.setdefault(key, {"metadata": card, "actions": []})
                action = {
                    "target": payload.get("click_target"),
                    "metadata": payload.get("metadata") or {},
                    "url": absolute_github_url(values.get("href")),
                    "avatar_url": None,
                }
                entry["actions"].append(action)
                if tag == "a":
                    self.active_anchor = action

        if tag == "img" and self.active_anchor is not None:
            self.active_anchor["avatar_url"] = values.get("src")

    def handle_endtag(self, tag: str) -> None:
        if tag == "a":
            self.active_anchor = None
        if tag == "div":
            if self.hidden_div_depths and self.hidden_div_depths[-1] == self.div_depth:
                self.hidden_div_depths.pop()
            self.div_depth -= 1

    def structured_feed(self) -> dict[str, Any]:
        items = [normalize_card(self.cards[key]) for key in self.order]
        inherit_rollup_actors(items)
        repo_details = repo_metadata_from_html(self._html or "")
        html = self._html or ""
        for item in items:
            target_name = (item["target"] or {}).get("name")
            if item["type"] == "FOLLOW" and target_name:
                item["user"] = follow_user_metadata_from_html(html, target_name)
            else:
                item["user"] = None
            detail = repo_details.get(target_name)
            item["repo"] = detail if detail else None
        type_counts = Counter(item["type"] for item in items)
        return {
            "item_count": len(items),
            "types": dict(sorted(type_counts.items())),
            "items": items,
        }


class GitHubWebClient:
    def __init__(self, credentials: dict[str, Any], accept_language: str) -> None:
        self.credentials = credentials
        self.accept_language = accept_language
        self.opener = urllib.request.build_opener()

    def bootstrap(self) -> dict[str, Any]:
        return {
            "credentials": credential_presence(self.credentials),
            "auth_ready": all(
                value != "missing"
                for value in credential_presence(self.credentials).values()
            ),
        }

    def for_you_feed(self, etag: str | None = None) -> tuple[str | None, dict[str, Any]]:
        nonce = "v2:" + str(uuid.uuid4())
        headers = {
            "Accept": "text/html",
            "Accept-Language": self.accept_language,
            "Cookie": self.cookie_header(),
            "Referer": BASE_URL + "/",
            "User-Agent": APP_USER_AGENT,
            "X-Fetch-Nonce": nonce,
            "X-Fetch-Nonce-To-Validate": nonce,
            "X-Requested-With": "XMLHttpRequest",
        }
        if etag:
            headers["If-None-Match"] = etag

        request = urllib.request.Request(FOR_YOU_FEED_URL, headers=headers, method="GET")
        try:
            with self.opener.open(request, timeout=30) as response:
                final_url = response.geturl()
                content_type = response.headers.get_content_type()
                charset = response.headers.get_content_charset() or "utf-8"
                html = response.read().decode(charset, errors="replace")
                response_etag = response.headers.get("ETag")
                status = response.status
        except urllib.error.HTTPError as exc:
            if exc.code == 304:
                return None, {"status": "not_modified", "etag": etag}
            body = exc.read().decode("utf-8", errors="replace")
            if exc.code in {401, 403}:
                raise GitHubHTTPError(
                    f"GitHub authentication failed (HTTP {exc.code}); refresh the session cookies."
                ) from exc
            raise GitHubHTTPError(
                f"GitHub For You feed failed (HTTP {exc.code}): {truncate(body, 500)}"
            ) from exc
        except urllib.error.URLError as exc:
            raise GitHubHTTPError(f"GitHub request failed: {exc.reason}") from exc

        if final_url != FOR_YOU_FEED_URL:
            raise GitHubHTTPError(
                f"GitHub redirected the authenticated feed request to {final_url}; refresh the session cookies."
            )
        if content_type != "text/html":
            raise GitHubHTTPError(
                f"Expected text/html from GitHub, got {content_type or 'an unknown content type'}."
            )
        if not html.strip():
            raise GitHubHTTPError("GitHub returned an empty For You feed response.")

        summary = summarize_html(html)
        summary.update(
            {
                "status": "ok",
                "http_status": status,
                "bytes": len(html.encode("utf-8")),
                "lines": len(html.splitlines()),
                "etag": response_etag,
            }
        )
        return html, summary

    def cookie_header(self) -> str:
        return "; ".join(
            [
                f"user_session={self.user_session()}",
                f"__Host-user_session_same_site={self.same_site_user_session()}",
                "logged_in=yes",
            ]
        )

    def user_session(self) -> str:
        value = str(
            self.credentials.get("userSession")
            or self.credentials.get("user_session")
            or ""
        )
        if not value:
            raise SystemExit("GitHub user_session cookie is required")
        return value

    def same_site_user_session(self) -> str:
        value = str(
            self.credentials.get("sameSiteUserSession")
            or self.credentials.get("__Host-user_session_same_site")
            or ""
        )
        if not value:
            raise SystemExit("GitHub __Host-user_session_same_site cookie is required")
        return value


def parse_cookie_header(header: str) -> dict[str, str]:
    cookies: dict[str, str] = {}
    for part in header.split(";"):
        name, separator, value = part.strip().partition("=")
        if separator and name:
            cookies[name] = value
    return cookies


def load_credentials(args: argparse.Namespace) -> dict[str, Any]:
    if args.cookie_header_file:
        if args.cookie_header_file == "-":
            return parse_cookie_header(sys.stdin.read().strip())
        with open(args.cookie_header_file, "r", encoding="utf-8") as handle:
            return parse_cookie_header(handle.read().strip())
    if args.credentials_file:
        if args.credentials_file == "-":
            return json.load(sys.stdin)
        with open(args.credentials_file, "r", encoding="utf-8") as handle:
            return json.load(handle)
    if args.simulator:
        command = [
            sys.executable,
            SIM_PREFS_SCRIPT,
            "--raw-key",
            SIM_GITHUB_FALLBACK_KEY,
        ]
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return json.loads(result.stdout)
    raise SystemExit("Pass --cookie-header-file, --credentials-file, or --simulator")


def credential_presence(credentials: dict[str, Any]) -> dict[str, str]:
    aliases = {
        "user_session": ("user_session", "userSession"),
        "__Host-user_session_same_site": (
            "__Host-user_session_same_site",
            "sameSiteUserSession",
        ),
    }
    result: dict[str, str] = {}
    for label, keys in aliases.items():
        value = next((credentials.get(key) for key in keys if credentials.get(key)), None)
        result[label] = f"present ({len(str(value))} chars)" if value else "missing"
    return result


def decode_hydro_payload(raw: str) -> dict[str, Any]:
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    payload = decoded.get("payload")
    return payload if isinstance(payload, dict) else {}


def card_key(card: dict[str, Any]) -> tuple[str, str]:
    return str(card["card_type"]), str(card["record_id"])


def absolute_github_url(value: str | None) -> str | None:
    if not value:
        return None
    absolute = urllib.parse.urljoin(BASE_URL, value)
    return absolute if absolute.startswith(BASE_URL + "/") else None


def normalize_card(entry: dict[str, Any]) -> dict[str, Any]:
    card = entry["metadata"]
    actions = entry["actions"]
    card_type = str(card["card_type"])
    record_id = card["record_id"]
    resource_id = card.get("resource_id")

    if card_type == "FOLLOW":
        actor = resource_from_actions(actions, resource_type="USER", resource_id=resource_id)
        target = resource_from_actions(actions, resource_type="USER", resource_id=record_id)
        summary = f"{resource_name(actor, 'Someone')} followed {resource_name(target, 'a user')}"
    elif card_type in {"STARRED_REPOSITORY", "FORKED_REPOSITORY"}:
        actor = resource_from_actions(actions, resource_type="USER")
        target = resource_from_actions(actions, resource_type="REPO", resource_id=resource_id)
        verb = "starred" if card_type == "STARRED_REPOSITORY" else "forked"
        summary = f"{resource_name(actor, 'Someone')} {verb} {resource_name(target, 'a repository')}"
    else:
        actor = resource_from_actions(actions, resource_type="USER")
        target = resource_from_actions(
            actions,
            resource_type=str(card.get("resource_type") or ""),
            resource_id=resource_id,
        )
        summary = card_type.replace("_", " ").lower()

    return {
        "id": f"github-{card_type.lower()}-{record_id}",
        "type": card_type,
        "created_at": card.get("created_at"),
        "actor": actor,
        "target": target,
        "summary": summary,
        "resource": {
            "type": card.get("resource_type"),
            "id": resource_id,
            "relationship": card.get("resource_relationship") or None,
        },
        "position": card.get("card_position"),
        "sub_position": card.get("card_sub_position"),
        "ranking_model": card.get("ranking_model_id"),
        "gatherer": card.get("gatherer"),
    }


def inherit_rollup_actors(items: list[dict[str, Any]]) -> None:
    rollup_actors = {
        int(item["position"]): item["actor"]
        for item in items
        if item["sub_position"] == 0
        and item["position"] is not None
        and item["actor"] is not None
    }
    follow_actors = {
        str(item["resource"]["id"]): item["actor"]
        for item in items
        if item["type"] == "FOLLOW" and item["actor"] is not None
    }
    for item in items:
        position = item["position"]
        if item["sub_position"] is not None and position in rollup_actors:
            item["actor"] = rollup_actors[position]
        elif item["type"] == "FOLLOW" and item["actor"] is None:
            item["actor"] = follow_actors.get(str(item["resource"]["id"]))

        verb = {
            "STARRED_REPOSITORY": "starred",
            "FOLLOW": "followed",
            "FORKED_REPOSITORY": "forked",
        }.get(item["type"])
        if verb:
            item["summary"] = (
                f"{resource_name(item['actor'], 'Someone')} {verb} "
                f"{resource_name(item['target'], 'a user' if item['type'] == 'FOLLOW' else 'a repository')}"
            )


def resource_from_actions(
    actions: list[dict[str, Any]],
    resource_type: str,
    resource_id: Any = None,
) -> dict[str, Any] | None:
    matches: list[dict[str, Any]] = []
    for action in actions:
        metadata = action["metadata"]
        if metadata.get("clicked_resource_type") != resource_type:
            continue
        if resource_id is not None and str(metadata.get("clicked_resource_id")) != str(resource_id):
            continue
        matches.append(action)
    if not matches:
        return None

    preferred_targets = {
        "USER": ("feed_user_link", "avatar"),
        "REPO": ("repository_link",),
    }.get(resource_type, ())
    selected = next(
        (action for target in preferred_targets for action in matches if action["target"] == target),
        matches[0],
    )
    selected_metadata = selected["metadata"]
    url = selected["url"] or next((action["url"] for action in matches if action["url"]), None)
    avatar_url = next(
        (action["avatar_url"] for action in matches if action["avatar_url"]),
        None,
    )
    name = None
    if url:
        path = urllib.parse.urlparse(url).path.strip("/")
        name = path if resource_type == "REPO" else path.split("/", 1)[0]
    return {
        "type": resource_type,
        "id": selected_metadata.get("clicked_resource_id"),
        "name": name,
        "url": url,
        "avatar_url": avatar_url if resource_type == "USER" else None,
    }


def resource_name(resource: dict[str, Any] | None, fallback: str) -> str:
    if not resource:
        return fallback
    return str(resource.get("name") or fallback)


def parse_structured_html(html: str) -> dict[str, Any]:
    parser = GitHubFeedParser()
    parser.feed(html)
    parser._html = html
    return parser.structured_feed()


def summarize_html(html: str) -> dict[str, Any]:
    structured = parse_structured_html(html)
    timestamps = [item["created_at"] for item in structured["items"] if item["created_at"]]
    links = []
    seen_links: set[str] = set()
    for item in structured["items"]:
        for resource in (item["actor"], item["target"]):
            if resource and resource["url"] and resource["url"] not in seen_links:
                seen_links.add(resource["url"])
                links.append(resource["url"])
    return {
        "feed_item_count": structured["item_count"],
        "types": structured["types"],
        "timestamp_count": len(timestamps),
        "timestamps": timestamps[:20],
        "github_link_count": len(links),
        "links": links[:20],
    }


def truncate(value: str, limit: int) -> str:
    normalized = " ".join(value.split())
    return normalized if len(normalized) <= limit else normalized[:limit] + "..."

def extract_starred_your_repo(html: str, viewer: str) -> list[dict[str, Any]]:
    """Return every "starred YOUR repository" notification from the For You feed.

    GitHub aggregates several distinct stars of the same owned repo into one visible
    rollup card (e.g. ``s0urledd starred your repository`` rows), which the
    record_id-based story parser collapses to a single event. To surface every real
    notification we walk each <article> and pair every starring-actor row with the
    owned repo(s) the card names. Returns one entry per (actor, repo)."""
    viewer_lower = (viewer or "").lower()

    actor_re = re.compile(
        r'<a[^>]*href="/(?P<u>[A-Za-z0-9_-]+)"[^>]*class="[^"]*Link[^"]*text-bold"[^>]*>\s*(?P=u)\s*</a>\s*starred',
        re.S,
    )
    repo_re = re.compile(r'href="/(' + re.escape(viewer_lower) + r'/[\w.-]+)' + r'[/"]')

    result: dict[tuple[str, str], dict[str, Any]] = {}
    for article in re.split(r"(?=<article\b)", html or ""):
        actors = set()
        for m in actor_re.finditer(article):
            actors.add(m.group("u"))
        repos = set()
        for rm in repo_re.finditer(article):
            repos.add(rm.group(1).strip("/"))
        if not actors:
            continue
        if not repos and "your repository" not in article:
            continue
        for actor in actors:
            for repo in repos:
                result.setdefault((actor, repo), {"actor": actor, "target": repo})
    return sorted(result.values(), key=lambda r: r["actor"])

def repo_metadata_from_html(html: str) -> dict[str, dict[str, str | None]]:
    """Extract per-repository card metadata (description, language, stars) by
    scanning each <article> element, keyed by the repository owner/name."""
    result: dict[str, dict[str, str | None]] = {}
    for article in re.split(r"(?=<article\b)", html or ""):
        if "repository_link" not in article:
            continue
        end = article.find("</article>")
        chunk = article[: end + len("</article>")] if end != -1 else article
        if "wb-break-word" not in chunk:
            continue
        after = chunk.split("wb-break-word", 1)[1]
        name_match = re.search(r'text-[a-z]*-?bold"[^>]*>([^<]+)</a>', after)
        if not name_match:
            continue
        name = name_match.group(1).strip()
        if not name:
            continue
        description = None
        m = re.search(r'class="[^"]*text[^"]*"[^>]*>[^<]*</a>\s*</div>\s*<div[^>]*>\s*([^<]*)', chunk)
        if m:
            description = " ".join(m.group(1).split()) or None
        language = None
        m = re.search(r'itemprop="programmingLanguage">([^<]+)</span>', chunk)
        if m:
            language = m.group(1).strip()
        stars = None
        m = re.search(r'aria-label="([0-9.,]+[kKmM]?)\s+stargazers"', chunk)
        if m:
            stars = m.group(1).strip()
        result[name] = {
            "description": description,
            "language": language,
            "stars": stars,
        }
    return result


def follow_user_metadata_from_html(html: str, username: str) -> dict[str, str | None] | None:
    """Extract the followed user's card (display name, bio, repo + follower counts).

    Mirrors the Swift parser: the bio is read only from the card's ``wb-break-all``
    container, so the ``color-fg-muted`` username handle and muted counts do not
    leak into the bio text. The anchor is chosen from a card that actually renders
    a bio, because the username can also appear earlier in the document as an
    actor/star card.
    """
    if not username or not html:
        return None
    anchor_re = re.compile(
        r'href="/%s"[^>]*class="[^"]*text-bold"[^>]*>([^<]+)</a>' % re.escape(username)
    )
    chosen = None
    chunk = None
    for match in anchor_re.finditer(html):
        article_start = html.rfind("<article", 0, match.start())
        article_end = html.find("</article>", match.start())
        if article_start == -1 or article_end == -1 or article_end <= article_start:
            continue
        candidate = html[article_start:article_end]
        if chosen is None:
            chosen, chunk = match, candidate
        if 'class="m-0 mt-1 wb-break-all"' in candidate:
            chosen, chunk = match, candidate
            break
    if chosen is None or chunk is None:
        return None
    display_name = chosen.group(1).strip() or None
    repos = re.search(r"([0-9.,]+[kKmM]?)\s+repositories", chunk)
    followers = re.search(r"([0-9.,]+[kKmM]?)\s+followers", chunk)
    bio_match = re.search(
        r'class="m-0 mt-1 wb-break-all"[^>]*>\s*<div>(.*?)</div>\s*</div>',
        chunk,
        flags=re.S,
    )
    bio = None
    if bio_match:
        text = re.sub(r"<[^>]+>", " ", bio_match.group(1))
        for entity, char in {
            "amp": "&",
            "quot": '"',
            "#39": "'",
            "lt": "<",
            "gt": ">",
        }.items():
            text = text.replace(f"&{entity};", char)
        cleaned = " ".join(text.split()).strip()
        bio = cleaned or None
    return {
        "displayName": display_name,
        "bio": bio,
        "repositories": repos.group(1).strip() if repos else None,
        "followers": followers.group(1).strip() if followers else None,
    }


def write_html(path: str | None, html: str | None) -> None:
    if not path or html is None:
        return
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(html)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate GitHub's authenticated For You feed HTML endpoint."
    )
    parser.add_argument(
        "--cookie-header-file",
        help="Path containing a browser Cookie header, or '-' for stdin.",
    )
    parser.add_argument(
        "--credentials-file",
        help="Path to selected credentials JSON, or '-' for stdin.",
    )
    parser.add_argument(
        "--simulator",
        action="store_true",
        help="Read GitHub credentials from the booted simulator fallback store.",
    )
    parser.add_argument(
        "--accept-language",
        default=DEFAULT_ACCEPT_LANGUAGE,
        help="Accept-Language request header.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser(
        "bootstrap", help="Print credential presence without making a request."
    )
    notifications = subparsers.add_parser(
        "notifications",
        help="Fetch the feed and print 'starred YOUR repository' notifications ",
    )
    notifications.add_argument("--output", help="Write notification JSON to this path.")
    feed = subparsers.add_parser("feed", help="Fetch the GitHub For You HTML feed.")
    feed.add_argument("--etag", help="Send If-None-Match with this ETag.")
    feed.add_argument("--output", help="Write raw HTML to this path.")
    output_mode = feed.add_mutually_exclusive_group()
    output_mode.add_argument(
        "--summary",
        action="store_true",
        help="Print structural JSON instead of the raw HTML.",
    )
    output_mode.add_argument(
        "--structured",
        action="store_true",
        help="Parse and print normalized feed items as JSON.",
    )
    feed.add_argument(
        "--structured-output",
        help="Write normalized feed JSON to this path.",
    )
    parse = subparsers.add_parser(
        "parse", help="Parse previously saved GitHub For You feed HTML."
    )
    parse.add_argument("input", help="Raw HTML path, or '-' for stdin.")
    parse.add_argument("--output", help="Write structured JSON to this path.")
    return parser


def main() -> None:
    args = build_parser().parse_args()

    try:
        if args.command == "parse":
            if args.input == "-":
                html = sys.stdin.read()
            else:
                with open(args.input, "r", encoding="utf-8") as handle:
                    html = handle.read()
            result = parse_structured_html(html)
            write_json(args.output, result)
            print(json.dumps(result, indent=2, sort_keys=True))
            return

        credentials = load_credentials(args)
        client = GitHubWebClient(credentials, accept_language=args.accept_language)
        if args.command == "bootstrap":
            print(json.dumps(client.bootstrap(), indent=2, sort_keys=True))
            return
        if args.command == "feed":
            html, summary = client.for_you_feed(etag=args.etag)
            write_html(args.output, html)
            structured = parse_structured_html(html) if html is not None else None
            if structured is not None:
                write_json(args.structured_output, structured)
            if args.structured and html is not None:
                print(json.dumps(structured, indent=2, sort_keys=True))
            elif args.summary:
                print(json.dumps(summary, indent=2, sort_keys=True))
            elif html is not None:
                sys.stdout.write(html)
            else:
                print(json.dumps(summary, indent=2, sort_keys=True))
            return
        if args.command == "notifications":
            html, _ = client.for_you_feed()
            viewer = credentials.get("username")
            notifications_list = extract_starred_your_repo(html, viewer) if html else []
            write_json(args.output, notifications_list)
            print(json.dumps(notifications_list, indent=2, sort_keys=True))
            return
        raise SystemExit(f"Unknown command: {args.command}")
    except GitHubHTTPError as exc:
        raise SystemExit(str(exc)) from exc


def write_json(path: str | None, value: Any) -> None:
    if not path:
        return
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
