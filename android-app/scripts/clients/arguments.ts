import { parseArgs } from "node:util";
import { z } from "zod";
import type { ProbeNetwork, createProbeRuntime } from "./runtime";

export type Option = { type: "string" | "boolean"; multiple?: boolean };
export type Context = {
  network: ProbeNetwork;
  args: string[];
  options: Record<string, string | boolean | string[] | undefined>;
  session: ReturnType<typeof createProbeRuntime>;
};
export type Command = {
  description: string;
  arguments?: string[];
  options?: Record<string, Option>;
  anonymous?: boolean;
  run: (context: Context) => Promise<unknown>;
};
export const stringOption: Option = { type: "string" };
export const flagOption: Option = { type: "boolean" };
export const commonOptions: Record<string, Option> = {
  help: flagOption,
  simulator: flagOption,
  udid: stringOption,
  "credentials-file": stringOption,
  "cookie-header-file": stringOption,
  "save-credentials": stringOption,
  output: stringOption,
  summary: flagOption,
  "raw-output": flagOption,
  "user-agent": stringOption,
  "accept-language": stringOption,
};
export function parseClientArguments({
  args,
  commands,
}: {
  args: string[];
  commands: Record<string, Command>;
}) {
  const { values: rawValues, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: {
      ...commonOptions,
      ...Object.assign({}, ...Object.values(commands).map((c) => c.options)),
    },
  });
  const values = z
    .record(z.string(), z.union([z.string(), z.boolean(), z.array(z.string())]))
    .parse(rawValues);
  const [name, ...rest] = positionals;
  if (values.help || !name) return { help: true as const, name };
  const command = commands[name];
  if (!command) throw new Error("Unknown command. Use --help to list commands.");
  if (rest.length !== (command.arguments?.length ?? 0))
    throw new Error(
      `Expected: ${name} ${(command.arguments ?? []).map((a) => `<${a}>`).join(" ")}`,
    );
  for (const key of Object.keys(values))
    if (!(key in commonOptions) && !(key in (command.options ?? {})))
      throw new Error(`Option --${key} does not apply to ${name}.`);
  const sources = [
    values.simulator,
    values["credentials-file"],
    values["cookie-header-file"],
  ].filter(Boolean);
  if (sources.length > 1 || (!command.anonymous && sources.length !== 1))
    throw new Error(
      "Choose exactly one credential source: --simulator, --credentials-file, or --cookie-header-file.",
    );
  if (values.udid && !values.simulator) throw new Error("--udid requires --simulator.");
  return { help: false as const, name, command, args: rest, options: values };
}
export function option({
  context,
  name,
  fallback,
}: {
  context: Context;
  name: string;
  fallback?: string;
}) {
  return z
    .string()
    .min(1)
    .parse(context.options[name] ?? fallback);
}
export function optional({ context, name }: { context: Context; name: string }) {
  return z.string().min(1).optional().parse(context.options[name]);
}
export function integer({
  context,
  name,
  fallback,
  max = Number.MAX_SAFE_INTEGER,
}: {
  context: Context;
  name: string;
  fallback?: number;
  max?: number;
}) {
  return z.coerce
    .number()
    .int()
    .min(1)
    .max(max)
    .parse(context.options[name] ?? fallback);
}
export const numericID = (value: unknown) => z.string().regex(/^\d+$/).parse(value);
export const username = (value: unknown) => z.string().trim().min(1).parse(value).replace(/^@/, "");
