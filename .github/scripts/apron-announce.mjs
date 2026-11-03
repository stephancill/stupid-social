// Posts a push to the stupid social room on the Apron demo server, as the bot
// whose token is APRON_BOT_TOKEN: commits pushed to main as a list, and a
// pushed testflight/<build> tag as a release with the tag's notes. Reads the
// push event from GITHUB_EVENT_PATH. Dependency-free; needs Node 22+ for the
// global WebSocket. The connection mirrors apron-chat/apron-pr-bot's apron.mjs.
import { readFileSync } from "node:fs";

const TIMEOUT_MS = 30_000;
const MAX_COMMITS = 10;
const TESTFLIGHT_URL = "https://testflight.apple.com/join/fU5cYTpg";

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

/** The annotated tag's message, from the GitHub API. */
const tagMessage = async ({ repo, tag, token }) => {
  const api = async (path) => {
    const response = await fetch(`https://api.github.com/repos/${repo}/${path}`, {
      headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" },
    });
    if (!response.ok) throw new Error(`GitHub ${path} failed: ${response.status}`);
    return response.json();
  };
  const ref = await api(`git/ref/tags/${tag}`);
  if (ref.object.type !== "tag") throw new Error(`${tag} is not an annotated tag.`);
  return (await api(`git/tags/${ref.object.sha}`)).message;
};

/** The message text for a pushed testflight/<build> tag; its notes follow the tag message's first line. */
const releaseText = async ({ repo, tag, token }) => {
  const build = tag.replace(/^testflight\//, "");
  const message = await tagMessage({ repo, tag, token });
  const notes = message.split("\n").slice(1).join("\n").trim();
  return [
    `🚀 **TestFlight build ${escapeMarkdown(build)}** is out`,
    ...(notes ? [notes] : []),
    TESTFLIGHT_URL,
  ].join("\n\n");
};

/** Signs in to `url` with bot `token` and sends one `message`; the request id dedupes reruns. */
const post = ({ url, token, params, requestId }) =>
  new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const timer = setTimeout(
      () => finish(new Error(`timed out after ${TIMEOUT_MS} ms`)),
      TIMEOUT_MS,
    );
    const finish = (error, result) => {
      clearTimeout(timer);
      socket.onclose = null;
      socket.close();
      if (error) reject(error);
      else resolve(result);
    };
    const send = (id, method, requestParams) =>
      socket.send(JSON.stringify({ id, method, params: requestParams }));
    socket.onerror = (event) =>
      finish(new Error(`WebSocket error: ${event.message ?? "connection failed"}`));
    socket.onclose = ({ code, reason }) =>
      finish(new Error(`connection closed (${code}${reason ? `: ${reason}` : ""})`));
    socket.onmessage = ({ data }) => {
      let frame;
      try {
        frame = JSON.parse(data);
      } catch {
        return;
      }
      if (frame.method === "server") send("auth", "auth", { scheme: "token", token });
      else if (frame.id === "auth") {
        if (frame.error) finish(new Error(`auth failed: ${frame.error.message}`));
        else send(requestId, "message", params);
      } else if (frame.id === requestId) {
        if (frame.error) finish(new Error(`message failed: ${frame.error.message}`));
        else finish(null, frame.result);
      }
    };
  });

const event = JSON.parse(readFileSync(env("GITHUB_EVENT_PATH"), "utf8"));
const repo = env("GITHUB_REPOSITORY");
const roomId = env("APRON_ROOM_ID");

let text;
let requestId;
if (event.ref.startsWith("refs/tags/testflight/")) {
  const tag = event.ref.replace(/^refs\/tags\//, "");
  text = await releaseText({ repo, tag, token: env("GITHUB_TOKEN") });
  requestId = `release-${repo}-${tag}`;
} else {
  text = commitsText({ event, repo });
  requestId = `commits-${repo}-${event.after}`;
}

if (!text) {
  console.log("Nothing to announce.");
} else {
  console.log(text);
  const result = await post({
    url: env("APRON_URL"),
    token: env("APRON_BOT_TOKEN"),
    params: { room_id: roomId, body: { text, format: "markdown" } },
    requestId,
  });
  console.log(`Announced ${event.ref} in ${roomId}: ${JSON.stringify(result)}`);
}
