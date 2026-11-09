#!/usr/bin/env python3
"""Probe LinkedIn's web client API (Voyager REST and the messaging GraphQL) with session cookies.

Dependency-free. Sends what www.linkedin.com's web client sends (observed 2026-11-09): the `li_at` and
`JSESSIONID` cookies, `csrf-token` set to JSESSIONID without its quotes, `x-restli-protocol-version: 2.0.0`
and a Chrome user agent. Query ids come from the messaging SDK in the web bundle (`kind:"query",
id:"messengerMessages.<hash>",name:"get-messages-by-timestamp"`); REST actions from the same SDK
(`Qa("restli",…,"messengerMessages",{action:"createMessage"})` → `voyagerMessagingDashMessengerMessages`).

Credentials: --credentials-file (JSON with `liAt`/`jsessionId`, as the app stores them, or the browser's
cookie names `li_at`/`JSESSIONID`), or --simulator (the booted simulator's LinkedIn account). Never printed.

Message text from other people is never printed: messages show sender, time, length, reactions and
attachment kinds. --show-text prints text only for messages the signed-in user sent.

Mutations (send, react, edit, recall, read, typing) need --expect-name to match a participant's name in
the conversation, so a typo can't post in the wrong chat.

Examples:
  scripts/linkedin-web-client.py --credentials-file logs/linkedin-cookies.json me
  scripts/linkedin-web-client.py --simulator notifications --count 20
  scripts/linkedin-web-client.py --simulator badges
  scripts/linkedin-web-client.py --simulator conversations [--cursor …]
  scripts/linkedin-web-client.py --simulator find --name "Helaine"
  scripts/linkedin-web-client.py --simulator messages --conversation URN [--before MS]
  scripts/linkedin-web-client.py --simulator send --conversation URN --expect-name Helaine --text "test" [--reply-to URN]
  scripts/linkedin-web-client.py --simulator react --conversation URN --expect-name Helaine --message URN --emoji 👍 [--remove]
  scripts/linkedin-web-client.py --simulator edit --conversation URN --expect-name Helaine --message URN --text "edited"
  scripts/linkedin-web-client.py --simulator recall --conversation URN --expect-name Helaine --message URN
  scripts/linkedin-web-client.py --simulator read --conversation URN --expect-name Helaine [--unread]
  scripts/linkedin-web-client.py --simulator typing --conversation URN --expect-name Helaine
  scripts/linkedin-web-client.py --simulator stream --seconds 60    # realtime events: topic, shape, never others' text
  scripts/linkedin-web-client.py --simulator raw /voyager/api/me
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sim_keychain  # noqa: E402

BASE = "https://www.linkedin.com"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
)
NORMALIZED = "application/vnd.linkedin.normalized+json+2.1"
GRAPHQL = "application/graphql"

# Messaging SDK query ids (web bundle, observed 2026-11-09).
Q_CONVERSATIONS_SYNC = "messengerConversations.0d5e6781bbee71c3e51c8843c6519f48"  # (mailboxUrn) newest 20
Q_CONVERSATIONS_PAGE = "messengerConversations.9501074288a12f3ae9e3c7ea243bccbf"  # (query,count,mailboxUrn,nextCursor|lastUpdatedBefore)
Q_CONVERSATION_BY_ID = "messengerConversations.fb3eab135970d880d59c5fad1bc695f9"  # (messengerConversationsId,count)
Q_MESSAGES_SYNC = "messengerMessages.5846eeb71c981f11e0134cb6626cc314"  # (conversationUrn) newest
Q_MESSAGES_BY_TIME = "messengerMessages.d8ea76885a52fd5dc5c317078ab7c977"  # (deliveredAt,conversationUrn,countBefore,countAfter)
Q_MAILBOX_COUNTS = "messengerMailboxCounts.fc528a5a81a76dff212a4a3d2d48e84b"  # (mailboxUrn)
NOTIFICATIONS_DECORATION = "com.linkedin.voyager.dash.deco.identity.notifications.CardsCollectionWithInjectionsNoPills-25"


class Client:
    def __init__(self, creds: dict[str, str]) -> None:
        self.li_at = creds.get("liAt") or creds.get("li_at")
        self.jsession = (creds.get("jsessionId") or creds.get("JSESSIONID") or "").strip('"')
        if not self.li_at or not self.jsession:
            raise SystemExit("Credentials need liAt and jsessionId.")

    def request(self, method: str, path: str, accept: str = NORMALIZED, body: Any = None) -> tuple[int, Any]:
        headers = {
            "cookie": f'li_at={self.li_at}; JSESSIONID="{self.jsession}"',
            "csrf-token": self.jsession,
            "accept": accept,
            "x-restli-protocol-version": "2.0.0",
            "x-li-lang": "en_US",
            "user-agent": USER_AGENT,
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["content-type"] = "text/plain;charset=UTF-8"
        request = urllib.request.Request(BASE + path, headers=headers, method=method, data=data)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, json.loads(raw)
            except ValueError:
                return error.code, raw[:300].decode(errors="replace")

    def get(self, path: str, accept: str = NORMALIZED) -> Any:
        status, body = self.request("GET", path, accept)
        if status != 200:
            raise SystemExit(f"GET {path.split('?')[0]} → {status}: {str(body)[:300]}")
        return body

    def graphql(self, query_id: str, variables: str) -> dict[str, Any]:
        body = self.get(f"/voyager/api/voyagerMessagingGraphQL/graphql?queryId={query_id}&variables={variables}", GRAPHQL)
        if body.get("errors"):
            raise SystemExit(f"GraphQL errors: {body['errors']}")
        return body["data"]

    def post(self, path: str, body: Any) -> tuple[int, Any]:
        return self.request("POST", path, "application/json", body)


def enc(value: str) -> str:
    """Rest.li encoding for a value inside `variables=(…)`: percent-encode everything reserved."""
    return urllib.parse.quote(value, safe="")


def load_credentials(args: argparse.Namespace) -> dict[str, str]:
    if args.credentials_file:
        return json.loads(Path(args.credentials_file).read_text())
    if args.simulator:
        return sim_keychain.load_credentials("linkedin", args.account_id)
    raise SystemExit("Pass --credentials-file or --simulator")


def me(client: Client) -> dict[str, Any]:
    body = client.get("/voyager/api/me")
    mini = next(x for x in body["included"] if x.get("dashEntityUrn"))
    return {
        "profileUrn": mini["dashEntityUrn"],
        "publicIdentifier": mini.get("publicIdentifier"),
        "name": f"{mini.get('firstName', '')} {mini.get('lastName', '')}".strip(),
    }


def participant_name(participant: dict[str, Any]) -> str:
    kind = participant.get("participantType") or {}
    if member := kind.get("member"):
        first = (member.get("firstName") or {}).get("text") or ""
        last = (member.get("lastName") or {}).get("text") or ""
        return f"{first} {last}".strip()
    if org := kind.get("organization"):
        return (org.get("name") or {}).get("text") or "Organization"
    if custom := kind.get("custom"):
        return (custom.get("name") or {}).get("text") or "Custom"
    return "?"


def summarize_conversation(c: dict[str, Any], me_urn: str) -> dict[str, Any]:
    others = [p for p in c["conversationParticipants"] if p["hostIdentityUrn"] != me_urn]
    last = (c.get("messages") or {}).get("elements") or []
    return {
        "urn": c["entityUrn"],
        "names": [participant_name(p) for p in others],
        "title": bool(c.get("title")),
        "group": c.get("groupChat"),
        "unread": c.get("unreadCount"),
        "read": c.get("read"),
        "lastActivityAt": c.get("lastActivityAt"),
        "lastReadAt": c.get("lastReadAt"),
        "categories": c.get("categories"),
        "lastMessageFromMe": bool(last) and last[-1]["sender"]["hostIdentityUrn"] == me_urn,
    }


def summarize_message(m: dict[str, Any], me_urn: str, show_text: bool) -> dict[str, Any]:
    mine = m["sender"]["hostIdentityUrn"] == me_urn
    text = (m.get("body") or {}).get("text") or ""
    summary = {
        "urn": m["entityUrn"],
        "deliveredAt": m["deliveredAt"],
        "mine": mine,
        "sender": participant_name(m.get("actor") or m["sender"]),
        "length": len(text),
        "format": m.get("messageBodyRenderFormat"),
        "reactions": [(r.get("emoji"), r.get("count"), r.get("viewerReacted")) for r in m.get("reactionSummaries") or []],
        "renderContent": [
            next((k for k, v in r.items() if v and not k.startswith("_")), "?") for r in m.get("renderContent") or []
        ],
        "subject": bool(m.get("subject")),
    }
    if show_text and mine:
        summary["text"] = text
    return summary


def conversation(client: Client, urn: str) -> dict[str, Any]:
    thread_id = urn.rsplit(",", 1)[1].rstrip(")")
    data = client.graphql(Q_CONVERSATION_BY_ID, f"(messengerConversationsId:{enc(urn)},count:1)")
    _ = thread_id
    return data["messengerConversationsById"]


def guard(client: Client, urn: str, expect: str | None) -> tuple[str, dict[str, Any]]:
    if not expect:
        raise SystemExit("Mutations need --expect-name.")
    me_urn = me(client)["profileUrn"]
    convo = conversation(client, urn)
    names = [participant_name(p) for p in convo["conversationParticipants"] if p["hostIdentityUrn"] != me_urn]
    if not any(expect.lower() in name.lower() for name in names):
        raise SystemExit(f"Conversation participants {names} don't match --expect-name {expect!r}.")
    return me_urn, convo


def cmd_me(client: Client, args: argparse.Namespace) -> Any:
    return me(client)


def cmd_notifications(client: Client, args: argparse.Namespace) -> Any:
    body = client.get(
        f"/voyager/api/voyagerIdentityDashNotificationCards?decorationId={NOTIFICATIONS_DECORATION}"
        f"&count={args.count}&q=filterVanityName&start={args.start}"
    )
    cards = {x["entityUrn"]: x for x in body["included"] if x.get("$type", "").endswith("notifications.Card")}
    profiles = {x["entityUrn"]: x for x in body["included"] if x.get("$type", "").endswith("profile.Profile")}
    out = []
    for urn in body["data"].get("*elements", []):
        card = cards.get(urn)
        if not card:
            continue
        actor = None
        for attribute in (card.get("headerImage") or {}).get("attributes") or []:
            ref = (attribute.get("detailData") or {}).get("*profilePicture")
            if ref and ref in profiles:
                p = profiles[ref]
                actor = {"name": f"{p.get('firstName', '')} {p.get('lastName', '')}".strip(), "vanity": p.get("publicIdentifier")}
        out.append(
            {
                "type": urn.split(":(", 1)[1].split(",", 1)[0] if ":(" in urn else urn,
                "headline": card["headline"]["text"],
                "read": card.get("read"),
                "publishedAt": card.get("publishedAt"),
                "target": (card.get("cardAction") or {}).get("actionTarget"),
                "actor": actor,
                "content": bool(card.get("contentPrimaryText")),
            }
        )
    return {"metadata": body["data"].get("metadata"), "cards": out}


def cmd_badges(client: Client, args: argparse.Namespace) -> Any:
    body = client.get("/voyager/api/voyagerNotificationsDashBadgingItemCounts")
    return [
        {"tab": x.get("badgingItem"), "count": x.get("count")}
        for x in body.get("included", []) + (body.get("data", {}).get("elements") or [])
        if isinstance(x, dict) and "count" in x
    ]


def cmd_conversations(client: Client, args: argparse.Namespace) -> Any:
    me_urn = me(client)["profileUrn"]
    # The primary inbox, as the web client's list shows it; the sync query (newest 20 of every category, with
    # a sync token) also returns chats filed elsewhere, such as spam (observed 2026-11-09).
    query = "(predicateUnions:List((conversationCategoryPredicate:(category:PRIMARY_INBOX))))"
    anchor = f",nextCursor:{args.cursor}" if args.cursor else ""
    data = client.graphql(Q_CONVERSATIONS_PAGE, f"(query:{query},count:20,mailboxUrn:{enc(me_urn)}{anchor})")
    coll = data["messengerConversationsByCategoryQuery"]
    return {
        "metadata": {k: v for k, v in (coll.get("metadata") or {}).items() if not k.startswith("_") and k != "newSyncToken"},
        "conversations": [summarize_conversation(c, me_urn) for c in coll["elements"]],
    }


def cmd_find(client: Client, args: argparse.Namespace) -> Any:
    me_urn = me(client)["profileUrn"]
    data = client.graphql(Q_CONVERSATIONS_SYNC, f"(mailboxUrn:{enc(me_urn)})")
    cursor = None
    pages = 0
    while True:
        coll = data.get("messengerConversationsBySyncToken") or data.get("messengerConversationsByCategoryQuery")
        for c in coll["elements"]:
            s = summarize_conversation(c, me_urn)
            if any(args.name.lower() in n.lower() for n in s["names"]):
                return s
        cursor = (coll.get("metadata") or {}).get("nextCursor")
        last = coll["elements"][-1]["lastActivityAt"] if coll["elements"] else None
        pages += 1
        if pages > 10 or not (cursor or last):
            return None
        query = "(predicateUnions:List((conversationCategoryPredicate:(category:PRIMARY_INBOX))))"
        anchor = f"nextCursor:{cursor}" if cursor else f"lastUpdatedBefore:{last}"
        data = client.graphql(Q_CONVERSATIONS_PAGE, f"(query:{query},count:20,mailboxUrn:{enc(me_urn)},{anchor})")


def cmd_messages(client: Client, args: argparse.Namespace) -> Any:
    me_urn = me(client)["profileUrn"]
    if args.before:
        data = client.graphql(
            Q_MESSAGES_BY_TIME,
            f"(deliveredAt:{args.before},conversationUrn:{enc(args.conversation)},countBefore:20,countAfter:0)",
        )
        coll = data["messengerMessagesByAnchorTimestamp"]
    else:
        data = client.graphql(Q_MESSAGES_SYNC, f"(conversationUrn:{enc(args.conversation)})")
        coll = data["messengerMessagesBySyncToken"]
    meta = {k: v for k, v in (coll.get("metadata") or {}).items() if not k.startswith("_") and k != "newSyncToken"}
    return {"metadata": meta, "messages": [summarize_message(m, me_urn, args.show_text) for m in coll["elements"]]}


def cmd_send(client: Client, args: argparse.Namespace) -> Any:
    me_urn, _ = guard(client, args.conversation, args.expect_name)
    render: list[dict[str, Any]] = []
    if args.reply_to:
        # The web composer quotes the replied-to message in full (`repliedMessageContent`, observed 2026-11-09).
        data = client.graphql(Q_MESSAGES_SYNC, f"(conversationUrn:{enc(args.conversation)})")
        original = next((m for m in data["messengerMessagesBySyncToken"]["elements"] if m["entityUrn"] == args.reply_to), None)
        if not original:
            raise SystemExit("--reply-to isn't among the newest messages.")
        render.append({
            "repliedMessageContent": {
                "originalSenderUrn": original["sender"]["entityUrn"],
                "originalSendAt": original["deliveredAt"],
                "originalMessageUrn": original["entityUrn"],
                "messageBody": {"text": original["body"]["text"], "attributes": original["body"].get("attributes") or []},
            }
        })
    body = {
        "message": {
            "body": {"attributes": [], "text": args.text},
            "renderContentUnions": render,
            "conversationUrn": args.conversation,
            "originToken": str(uuid.uuid4()),
        },
        "mailboxUrn": me_urn,
        "trackingId": uuid.uuid4().bytes.decode("latin-1"),
        "dedupeByClientGeneratedToken": False,
    }
    status, response = client.post("/voyager/api/voyagerMessagingDashMessengerMessages?action=createMessage", body)
    value = (response or {}).get("value") or {} if isinstance(response, dict) else {}
    return {"status": status, "entityUrn": value.get("entityUrn"), "deliveredAt": value.get("deliveredAt"), "keys": sorted(value)[:20], "error": None if status < 300 else str(response)[:300]}


def cmd_react(client: Client, args: argparse.Namespace) -> Any:
    guard(client, args.conversation, args.expect_name)
    action = "unreactWithEmoji" if args.remove else "reactWithEmoji"
    status, response = client.post(
        f"/voyager/api/voyagerMessagingDashMessengerMessages?action={action}",
        {"messageUrn": args.message, "emoji": args.emoji},
    )
    return {"status": status, "response": str(response)[:300] if response else None}


def cmd_edit(client: Client, args: argparse.Namespace) -> Any:
    guard(client, args.conversation, args.expect_name)
    status, response = client.post(
        f"/voyager/api/voyagerMessagingDashMessengerMessages/{enc(args.message)}",
        {"patch": {"$set": {"body": {"attributes": [], "text": args.text}}}},
    )
    return {"status": status, "response": str(response)[:300] if response else None}


def cmd_recall(client: Client, args: argparse.Namespace) -> Any:
    guard(client, args.conversation, args.expect_name)
    status, response = client.post(
        "/voyager/api/voyagerMessagingDashMessengerMessages?action=recall", {"messageUrn": args.message}
    )
    return {"status": status, "response": str(response)[:300] if response else None}


def cmd_read(client: Client, args: argparse.Namespace) -> Any:
    guard(client, args.conversation, args.expect_name)
    status, response = client.post(
        f"/voyager/api/voyagerMessagingDashMessengerConversations?ids=List({enc(args.conversation)})",
        {"entities": {args.conversation: {"patch": {"$set": {"read": not args.unread}}}}},
    )
    return {"status": status, "response": str(response)[:300] if response else None}


def cmd_typing(client: Client, args: argparse.Namespace) -> Any:
    guard(client, args.conversation, args.expect_name)
    status, response = client.post(
        "/voyager/api/voyagerMessagingDashMessengerConversations?action=typing", {"conversationUrn": args.conversation}
    )
    return {"status": status, "response": str(response)[:300] if response else None}


def shape(value: Any, depth: int = 0) -> Any:
    if depth > 6:
        return "…"
    if isinstance(value, dict):
        return {k: shape(v, depth + 1) for k, v in value.items() if not k.startswith("_") and k != "$recipeTypes"}
    if isinstance(value, list):
        return [shape(value[0], depth + 1), f"×{len(value)}"] if value else []
    return type(value).__name__


def cmd_raw(client: Client, args: argparse.Namespace) -> Any:
    accept = GRAPHQL if "voyagerMessagingGraphQL" in args.path else NORMALIZED
    return shape(client.get(args.path, accept))


# The messaging topics' realtime decorations, from the web client's `x-li-query-map` header (observed 2026-11-09).
# The server decorates each event with the named GraphQL query before sending it.
REALTIME_QUERY_MAP = {
    "conversationsBroadcastTopic": "voyagerMessagingDashMessengerRealtimeDecoration.f855048b390b286e513d7b23c59efee3",
    "conversationsTopic": "voyagerMessagingDashMessengerRealtimeDecoration.f855048b390b286e513d7b23c59efee3",
    "conversationDeletesBroadcastTopic": "voyagerMessagingDashMessengerRealtimeDecoration.282abe5fa1a242cb76825c32dbbfaede",
    "conversationDeletesTopic": "voyagerMessagingDashMessengerRealtimeDecoration.282abe5fa1a242cb76825c32dbbfaede",
    "messageReactionSummariesBroadcastTopic": "voyagerMessagingDashMessengerRealtimeDecoration.85ff5a1aabf7c52f40aa85ccc84e3bf5",
    "messageReactionSummariesTopic": "voyagerMessagingDashMessengerRealtimeDecoration.85ff5a1aabf7c52f40aa85ccc84e3bf5",
    "messageSeenReceiptsBroadcastTopic": "voyagerMessagingDashMessengerRealtimeDecoration.e23d3971dc83a115b03584cf2381256c",
    "messageSeenReceiptsTopic": "voyagerMessagingDashMessengerRealtimeDecoration.e23d3971dc83a115b03584cf2381256c",
    "messagesBroadcastTopic": "voyagerMessagingDashMessengerRealtimeDecoration.db0f1d3f53747f49f3fd87b139df9eda",
    "messagesTopic": "voyagerMessagingDashMessengerRealtimeDecoration.db0f1d3f53747f49f3fd87b139df9eda",
    "typingIndicatorsBroadcastTopic": "voyagerMessagingDashMessengerRealtimeDecoration.234ce03cd062b2438dae060ca854a6d2",
    "typingIndicatorsTopic": "voyagerMessagingDashMessengerRealtimeDecoration.234ce03cd062b2438dae060ca854a6d2",
}


def realtime_headers(client: Client, session_id: str) -> dict[str, str]:
    query_map = {topic: {"queryId": query, "variables": {}, "extensions": {}} for topic, query in REALTIME_QUERY_MAP.items()}
    return {
        "cookie": f'li_at={client.li_at}; JSESSIONID="{client.jsession}"',
        "csrf-token": client.jsession,
        "accept": "text/event-stream",
        "cache-control": "no-cache",
        "x-restli-protocol-version": "2.0.0",
        "x-li-accept": NORMALIZED,
        "x-li-query-accept": GRAPHQL,
        "x-li-recipe-accept": NORMALIZED,
        "x-li-query-map": json.dumps({"topicToGraphQLQueryParams": query_map}, separators=(",", ":")),
        "x-li-realtime-session": session_id,
        # Without `mpName` the stream answers 400 "Could not map to valid appName for supplied mpName: null".
        "x-li-track": json.dumps({"clientVersion": "1.13.47699", "mpVersion": "1.13.47699", "osName": "web", "mpName": "voyager-web", "deviceFormFactor": "DESKTOP"}, separators=(",", ":")),
        "user-agent": USER_AGENT,
    }


def summarize_event(event: dict[str, Any], me_urn: str) -> dict[str, Any]:
    """Topic and shape of one realtime event; text from others is replaced by its length."""
    if "com.linkedin.realtimefrontend.DecoratedEvent" in event:
        decorated = event["com.linkedin.realtimefrontend.DecoratedEvent"]
        payload = decorated.get("payload") or {}
        data = (payload.get("data") or {})
        result = next((v.get("result") for k, v in data.items() if isinstance(v, dict) and "result" in v), None)
        summary: dict[str, Any] = {"topic": decorated.get("topic"), "keys": list(data.keys()), "shape": shape(result)}
        if isinstance(result, dict):
            sender = ((result.get("sender") or {}).get("hostIdentityUrn"))
            body = (result.get("body") or {}).get("text")
            if body is not None:
                summary["mine"] = sender == me_urn
                summary["text" if sender == me_urn else "length"] = body if sender == me_urn else len(body)
            for key in ("entityUrn", "deliveredAt", "messageBodyRenderFormat"):
                if key in result:
                    summary[key] = result[key]
            if "conversation" in result:
                summary["conversation"] = (result["conversation"] or {}).get("entityUrn")
        return summary
    return {"event": list(event.keys()), "shape": shape(event)}


def cmd_stream(client: Client, args: argparse.Namespace) -> Any:
    """Opens /realtime/connect (server-sent events) and prints each event's topic and shape until --seconds pass."""
    import http.client
    import ssl
    import time

    me_urn = me(client)["profileUrn"]
    session_id = str(uuid.uuid4())
    connection = http.client.HTTPSConnection("www.linkedin.com", timeout=args.seconds + 30, context=ssl.create_default_context())
    connection.request("GET", "/realtime/connect?rc=1", headers=realtime_headers(client, session_id))
    response = connection.getresponse()
    print(json.dumps({"status": response.status, "content-type": response.getheader("content-type")}), flush=True)
    if response.status != 200:
        return {"body": response.read(300).decode(errors="replace")}
    deadline = time.time() + args.seconds
    events = 0
    buffer = b""
    while time.time() < deadline:
        chunk = response.readline()
        if not chunk:
            break
        line = chunk.rstrip(b"\r\n")
        if line.startswith(b"data:"):
            buffer += line[5:].strip()
        elif line == b"" and buffer:
            try:
                event = json.loads(buffer)
            except ValueError:
                print(json.dumps({"unparsed": buffer[:200].decode(errors="replace")}), flush=True)
            else:
                events += 1
                print(json.dumps(summarize_event(event, me_urn), ensure_ascii=False), flush=True)
            buffer = b""
        elif line and not line.startswith(b":"):
            print(json.dumps({"line": line[:200].decode(errors="replace")}), flush=True)
    connection.close()
    return {"events": events}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--credentials-file")
    parser.add_argument("--simulator", action="store_true")
    parser.add_argument("--account-id")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("me")
    p = sub.add_parser("notifications")
    p.add_argument("--count", type=int, default=20)
    p.add_argument("--start", type=int, default=0)
    sub.add_parser("badges")
    p = sub.add_parser("conversations")
    p.add_argument("--cursor")
    p = sub.add_parser("find")
    p.add_argument("--name", required=True)
    p = sub.add_parser("messages")
    p.add_argument("--conversation", required=True)
    p.add_argument("--before", type=int)
    p.add_argument("--show-text", action="store_true")
    for name in ["send", "react", "edit", "recall", "read", "typing"]:
        p = sub.add_parser(name)
        p.add_argument("--conversation", required=True)
        p.add_argument("--expect-name")
        if name in ("send", "edit"):
            p.add_argument("--text", required=True)
        if name == "send":
            p.add_argument("--reply-to", help="A message urn to reply to.")
        if name in ("react", "edit", "recall"):
            p.add_argument("--message", required=True)
        if name == "react":
            p.add_argument("--emoji", required=True)
            p.add_argument("--remove", action="store_true")
        if name == "read":
            p.add_argument("--unread", action="store_true")
    p = sub.add_parser("stream")
    p.add_argument("--seconds", type=int, default=60)
    p = sub.add_parser("raw")
    p.add_argument("path")
    args = parser.parse_args()
    client = Client(load_credentials(args))
    handler = globals()[f"cmd_{args.command}"]
    print(json.dumps(handler(client, args), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
