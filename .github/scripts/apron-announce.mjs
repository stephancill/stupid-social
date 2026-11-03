// Announces pushes in the stupid social room on the Apron demo server, as the
// bot whose token is APRON_BOT_TOKEN. Commits pushed to main are posted as a
// list, tagged in `ext` with the push's head commit. A pushed
// testflight/<build> tag reacts ✈️ to the announcements whose head commit
// shipped in that build: in the tagged commit, and not in the previous
// testflight tag's. Reads the push event from GITHUB_EVENT_PATH.
// Dependency-free; needs Node 22+ for the global WebSocket. The client mirrors
// apron-chat/apron-pr-bot's apron.mjs and deployed.mjs.
import { readFileSync } from "node:fs";

const TIMEOUT_MS = 30_000;
const MAX_COMMITS = 10;
const EXT_KEY = "stupid-social-announce";
const REACTION = "✈️";
// History pages to read for announcements, within the demo server's Free
// plan of 50 records a page and 10 history requests a minute.
const PAGE_LIMIT = 50;
const MAX_PAGES = 8;

const env = (name) => {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
};

const escapeMarkdown = (text) => text.replace(/[\\`*_[\]<>~|&!]/g, "\\$&");

/** The message text for commits pushed to a branch, or null when there are none. */
const commitsText = ({ event, repo }) => {
  const commits = event.commits ?? [];
  if (commits.length === 0) return null;
  const branch = event.ref.replace(/^refs\/heads\//, "");
  const lines = commits.slice(-MAX_COMMITS).map((commit) => {
    const subject = escapeMarkdown(commit.message.split("\n")[0]);
    return `- [\`${commit.id.slice(0, 7)}\`](${commit.url}) ${subject}`;
  });
  const more = commits.length - MAX_COMMITS;
  const header = `🔨 ${commits.length} new commit${commits.length === 1 ? "" : "s"} to ${escapeMarkdown(repo)} ${escapeMarkdown(branch)}`;
  return [header, ...lines, ...(more > 0 ? [`…and [${more} more](${event.compare})`] : [])].join(
    "\n",
  );
};

const github = async ({ repo, token, path }) => {
  const response = await fetch(`https://api.github.com/repos/${repo}/${path}`, {
    headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" },
  });
  if (!response.ok) throw new Error(`GitHub ${path} failed: ${response.status}`);
  return response.json();
};

/** The commit a tag ref points at, through an annotated tag object. */
const tagCommit = async ({ repo, token, ref }) => {
  if (ref.object.type === "commit") return ref.object.sha;
  return (await github({ repo, token, path: `git/tags/${ref.object.sha}` })).object.sha;
};

/** The commits of testflight `build` and of the highest-numbered testflight tag below it (null when none). */
const releaseCommits = async ({ repo, token, build }) => {
  const refs = await github({ repo, token, path: "git/matching-refs/tags/testflight/" });
  const numbered = refs
    .map((ref) => ({ ref, build: Number(ref.ref.replace(/^refs\/tags\/testflight\//, "")) }))
    .filter((entry) => Number.isInteger(entry.build));
  const current = numbered.find((entry) => entry.build === build);
  if (!current) throw new Error(`testflight/${build} is not a tag of ${repo}.`);
  const previous = numbered
    .filter((entry) => entry.build < build)
    .sort((a, b) => b.build - a.build)[0];
  return {
    release: await tagCommit({ repo, token, ref: current.ref }),
    previous: previous ? await tagCommit({ repo, token, ref: previous.ref }) : null,
  };
};

/** Whether commit `sha` is `head` or an ancestor of it; false when GitHub does not know `sha`. */
const isIncluded = async ({ repo, token, sha, head }) => {
  if (sha === head) return true;
  const response = await fetch(
    `https://api.github.com/repos/${repo}/compare/${sha}...${head}?per_page=1`,
    { headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" } },
  );
  if (response.status === 404) return false;
  if (!response.ok) throw new Error(`comparing ${sha}...${head} failed: ${response.status}`);
  const { status } = await response.json();
  return status === "ahead" || status === "identical";
};

/**
 * Connects to `url` and signs in with bot `token`. Resolves with `you`, the
 * bot's identity, `request(method, params, id)`, and `close()`.
 */
const connect = ({ url, token }) =>
  new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const waiting = new Map();
    let counter = 0;
    let closed = null;
    const settle = (id, error, value) => {
      const entry = waiting.get(id);
      if (!entry) return;
      waiting.delete(id);
      clearTimeout(entry.timer);
      if (error) entry.reject(error);
      else entry.resolve(value);
    };
    const fail = (error) => {
      closed ??= error;
      for (const id of waiting.keys()) settle(id, error);
      reject(error);
    };
    const request = (method, params, id = `${method}-${++counter}`) => {
      if (closed) return Promise.reject(closed);
      return new Promise((resolveRequest, rejectRequest) => {
        const timer = setTimeout(
          () => settle(id, new Error(`${method} timed out after ${TIMEOUT_MS} ms`)),
          TIMEOUT_MS,
        );
        waiting.set(id, { method, resolve: resolveRequest, reject: rejectRequest, timer });
        socket.send(JSON.stringify({ id, method, params }));
      });
    };
    const close = () => {
      closed ??= new Error("connection closed");
      socket.close();
    };
    const timer = setTimeout(() => fail(new Error(`timed out after ${TIMEOUT_MS} ms`)), TIMEOUT_MS);
    socket.onerror = (event) =>
      fail(new Error(`WebSocket error: ${event.message ?? "connection failed"}`));
    socket.onclose = ({ code, reason }) =>
      fail(new Error(`connection closed (${code}${reason ? `: ${reason}` : ""})`));
    socket.onmessage = ({ data }) => {
      let frame;
      try {
        frame = JSON.parse(data);
      } catch {
        return;
      }
      if (frame.method === "server") {
        request("auth", { scheme: "token", token }, "auth").then(
          ({ you }) => {
            clearTimeout(timer);
            resolve({ you, request, close });
          },
          (error) => {
            clearTimeout(timer);
            close();
            reject(error);
          },
        );
      } else if (frame.id !== undefined && waiting.has(frame.id)) {
        const { method } = waiting.get(frame.id);
        if (!frame.error) settle(frame.id, null, frame.result);
        else settle(frame.id, new Error(`${method} failed: ${frame.error.message}`));
      }
    };
  });

/**
 * The bot's announcements of `repo` in the room's recent history, newest
 * first: each one's `message_id`, head commit `sha`, and the bot's current
 * reaction `emojis` on it. Only each message's latest snapshot counts.
 */
const announcements = async ({ request, botId, roomId, repo }) => {
  const messages = [];
  const reactions = [];
  let before;
  for (let page = 0; page < MAX_PAGES; page++) {
    const result = await request("history", {
      room_id: roomId,
      limit: PAGE_LIMIT,
      ...(before ? { before } : {}),
    });
    messages.push(...(result.messages ?? []));
    reactions.push(...(result.reactions ?? []));
    if (!result.more || !result.first_log_id) break;
    before = String(BigInt(result.first_log_id) - 1n);
  }
  const newer = (a, b) => !b || BigInt(a.log_id) > BigInt(b.log_id);
  const latest = new Map();
  for (const message of messages) {
    if (newer(message, latest.get(message.message_id))) latest.set(message.message_id, message);
  }
  const sets = new Map();
  for (const record of reactions) {
    const set = record.reactions?.find((entry) => entry.from?.user_id === botId);
    if (set && newer(record, sets.get(record.message_id))) {
      sets.set(record.message_id, { log_id: record.log_id, emojis: set.emojis ?? [] });
    }
  }
  const prefix = `${repo}@`;
  return [...latest.values()]
    .filter((message) => message.from?.user_id === botId && !message.deleted)
    .filter((message) => message.ext?.[EXT_KEY]?.startsWith(prefix))
    .sort((a, b) => (BigInt(b.log_id) > BigInt(a.log_id) ? 1 : -1))
    .map((message) => ({
      message_id: message.message_id,
      sha: message.ext[EXT_KEY].slice(prefix.length),
      emojis: sets.get(message.message_id)?.emojis ?? [],
    }));
};

const event = JSON.parse(readFileSync(env("GITHUB_EVENT_PATH"), "utf8"));
const repo = env("GITHUB_REPOSITORY");
const roomId = env("APRON_ROOM_ID");

if (event.ref.startsWith("refs/tags/testflight/")) {
  const build = Number(event.ref.replace(/^refs\/tags\/testflight\//, ""));
  if (!Number.isInteger(build)) throw new Error(`${event.ref} is not testflight/<build>.`);
  const githubToken = env("GITHUB_TOKEN");
  const { release, previous } = await releaseCommits({ repo, token: githubToken, build });
  const shipped = async (sha) =>
    (await isIncluded({ repo, token: githubToken, sha, head: release })) &&
    !(previous && (await isIncluded({ repo, token: githubToken, sha, head: previous })));
  const { you, request, close } = await connect({
    url: env("APRON_URL"),
    token: env("APRON_BOT_TOKEN"),
  });
  try {
    const pending = (await announcements({ request, botId: you.user_id, roomId, repo })).filter(
      ({ emojis }) => !emojis.includes(REACTION),
    );
    const reacted = [];
    for (const announcement of pending) {
      if (!(await shipped(announcement.sha))) continue;
      // Stable per announcement and build, so a rerun does not react twice.
      await request(
        "reactions",
        { message_id: announcement.message_id, emojis: [...announcement.emojis, REACTION] },
        `testflight-${announcement.message_id}-${build}`,
      );
      reacted.push(announcement.message_id);
    }
    console.log(
      `Reacted ${REACTION} for build ${build} to ${reacted.length} announcement${reacted.length === 1 ? "" : "s"} in ${roomId}${reacted.length ? `: ${reacted.join(", ")}` : ""}`,
    );
  } finally {
    close();
  }
} else {
  const text = commitsText({ event, repo });
  if (!text) {
    console.log("Nothing to announce.");
  } else {
    console.log(text);
    const { request, close } = await connect({
      url: env("APRON_URL"),
      token: env("APRON_BOT_TOKEN"),
    });
    try {
      const result = await request(
        "message",
        {
          room_id: roomId,
          body: { text, format: "markdown" },
          ext: { [EXT_KEY]: `${repo}@${event.after}` },
        },
        // Stable per push, so a rerun does not post twice.
        `commits-${repo}-${event.after}`,
      );
      console.log(`Announced ${event.ref} in ${roomId}: ${JSON.stringify(result)}`);
    } finally {
      close();
    }
  }
}
