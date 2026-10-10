import { z } from "zod";
import type { ClientRuntime } from "../../src/clientRuntime";
import { xCommands } from "./x";
import { instagramCommands } from "./instagram";
import { githubCommands } from "./github";
import { spotifyCommands } from "./spotify";
import { blueskyCommands } from "./bluesky";
import { parseClientArguments, type Command } from "./arguments";
import {
  type ProbeNetwork,
  installProbeRuntime,
  inputText,
  credentialsJSON,
  cookieCredentials,
  simulatorCredentials,
  redact,
  writePrivateJSON,
} from "./runtime";

export const clientCommands: Record<ProbeNetwork, Record<string, Command>> = {
  x: xCommands,
  instagram: instagramCommands,
  github: githubCommands,
  spotify: spotifyCommands,
  bluesky: blueskyCommands,
};
function summary(value: unknown, depth = 0): unknown {
  if (Array.isArray(value))
    return { count: value.length, sample: value.slice(0, 3).map((v) => summary(v, depth + 1)) };
  if (value && typeof value === "object") {
    const entries = Object.entries(value);
    return depth > 3
      ? { fields: entries.map(([key]) => key) }
      : Object.fromEntries(entries.map(([key, child]) => [key, summary(child, depth + 1)]));
  }
  return value;
}
export function clientHelp({ network, command }: { network: ProbeNetwork; command?: string }) {
  const commands = clientCommands[network];
  const selected =
    command && commands[command]
      ? [[command, commands[command]!] as const]
      : Object.entries(commands);
  return [
    `Usage: bun scripts/${network}-web-client.ts [options] <command> [arguments]`,
    "",
    ...selected.flatMap(([name, spec]) => [
      `  ${name} ${(spec.arguments ?? []).map((a) => `<${a}>`).join(" ")} — ${spec.description}`,
      ...Object.entries(spec.options ?? {}).map(
        ([key, option]) =>
          `    --${key}${option.type === "string" ? " <value>" : ""}${option.multiple ? " (repeatable)" : ""}`,
      ),
    ]),
    "",
    "Credential sources (choose one for authenticated commands):",
    "  --simulator [--udid <device>]        Read only the selected native simulator session.",
    "  --credentials-file <path|->         Expo or native credentials JSON; '-' reads stdin.",
    "  --cookie-header-file <path|->       Extract selected cookies from a browser header.",
    "  --save-credentials <path>           Save updated credentials privately (mode 0600).",
    "",
    "Output: --summary, --output <json-path>, --raw-output (full JSON, still redacted).",
    "Request overrides: --user-agent <value>, --accept-language <value>.",
    "Mutating commands execute their named action. No mutation is performed by --help or bootstrap credential checks.",
  ].join("\n");
}
export async function runClient({
  network,
  args = process.argv.slice(2),
  fetch,
}: {
  network: ProbeNetwork;
  args?: string[];
  fetch?: ClientRuntime["fetch"];
}) {
  let session: ReturnType<typeof installProbeRuntime> | undefined;
  try {
    const parsed = parseClientArguments({ args, commands: clientCommands[network] });
    if (parsed.help) {
      console.log(clientHelp({ network, command: parsed.name }));
      return;
    }
    const { options } = parsed;
    const initial = options.simulator
      ? await simulatorCredentials({ network, udid: z.string().optional().parse(options.udid) })
      : options["credentials-file"]
        ? credentialsJSON({
            network,
            input: await inputText({ path: z.string().parse(options["credentials-file"]) }),
          })
        : options["cookie-header-file"]
          ? cookieCredentials({
              network,
              header: await inputText({ path: z.string().parse(options["cookie-header-file"]) }),
            })
          : null;
    session = installProbeRuntime({
      network,
      initial,
      fetch,
      headers: {
        ...(options["user-agent"] ? { "User-Agent": z.string().parse(options["user-agent"]) } : {}),
        ...(options["accept-language"]
          ? { "Accept-Language": z.string().parse(options["accept-language"]) }
          : {}),
      },
    });
    let result: unknown;
    try {
      result = await parsed.command.run({ network, args: parsed.args, options, session });
    } finally {
      if (options["save-credentials"])
        await writePrivateJSON({
          path: z.string().parse(options["save-credentials"]),
          value: session.current(),
        });
    }
    const safe = redact({ value: result ?? { status: "ok" }, secrets: session.knownSecrets });
    if (options.output)
      await writePrivateJSON({ path: z.string().parse(options.output), value: safe });
    console.log(JSON.stringify(options.summary ? summary(safe) : safe, null, 2));
  } catch (error) {
    const message =
      error instanceof z.ZodError
        ? "Invalid input or response shape. Check the command's arguments and credential fields."
        : error instanceof Error
          ? error.message
          : "Client failed.";
    console.error(redact({ value: message, secrets: session?.knownSecrets }));
    process.exitCode = 1;
  }
}
