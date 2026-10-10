import { accountSchema } from "../../src/app/models";
import { connectGitHub, githubPage, githubFeed } from "../../src/github/client";
import { parseGitHubFeed, githubIdentity } from "../../src/github/parser";
import { credentialPresence, inputText, writePrivateJSON } from "./runtime";
import { type Command, stringOption, flagOption, optional } from "./arguments";

export const githubCommands: Record<string, Command> = {
  bootstrap: {
    description: "Show selected credential presence without a request.",
    run: async (c) => credentialPresence({ value: c.session.current() }),
  },
  validate: {
    description: "Confirm the session and current account without following redirects.",
    run: async () => ({ authenticated: true, account: await connectGitHub() }),
  },
  notifications: {
    description: "Read stars of the viewer's repositories using the app parser.",
    run: async () => (await githubFeed({ account: await connectGitHub() })).notifications,
  },
  feed: {
    description: "Read normalized activity and notifications; supports conditional ETag requests.",
    options: { etag: stringOption, structured: flagOption, "structured-output": stringOption },
    run: async (c) => {
      const account = await connectGitHub();
      const page = await githubPage({
        path: "/conduit/for_you_feed",
        authenticated: true,
        feed: true,
        etag: optional({ context: c, name: "etag" }),
      });
      const result = {
        status: page.status,
        etag: page.etag,
        ...(page.status === 304
          ? { notModified: true }
          : parseGitHubFeed({ html: page.html, account })),
      };
      const output = optional({ context: c, name: "structured-output" });
      if (output) await writePrivateJSON({ path: output, value: result });
      return result;
    },
  },
  parse: {
    description: "Parse saved HTML with --viewer, or the viewer embedded in the page.",
    arguments: ["input"],
    anonymous: true,
    options: { viewer: stringOption },
    run: async (c) => {
      const html = await inputText({ path: c.args[0]! });
      const viewer = optional({ context: c, name: "viewer" });
      const account = viewer
        ? accountSchema.parse({
            network: "github",
            id: viewer,
            username: viewer,
            name: viewer,
            connectedAt: 0,
          })
        : githubIdentity({ html });
      if (!account)
        throw new Error(
          "This HTML has no viewer identity. Supply --viewer for correct owned-repository classification.",
        );
      return parseGitHubFeed({ html, account });
    },
  },
};
