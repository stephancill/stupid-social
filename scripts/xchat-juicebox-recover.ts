// Recovers the XChat private-key secret from X's Juicebox realms, for scripts/xchat-client.py.
//
// stdin: {"config": <key_store_token_map_json object>, "tokens": {"<realm id hex>": "<jwt>"}}
// The PIN comes from X_CHAT_PIN (bun loads .env.local), so it never appears in argv or output.
// stdout: {"secret_hex": "..."} on success, or {"error": ..., "reason": ..., "guesses_remaining": ...}.
// Each call that reaches the realms with a wrong PIN uses up one of the user's guesses.
import * as glue from "juicebox-sdk/juicebox-sdk_bg.js";
import { z } from "zod";

// The package is built for bundlers that import .wasm as a module; bun doesn't, so instantiate it here.
const wasmPath = Bun.resolveSync("juicebox-sdk/juicebox-sdk_bg.wasm", import.meta.dir);
const { instance } = await WebAssembly.instantiate(await Bun.file(wasmPath).arrayBuffer(), { "./juicebox-sdk_bg.js": glue });
glue.__wbg_set_wasm(instance.exports);
const { Client, Configuration } = glue;

const input = z
  .object({
    config: z.object({
      realms: z.array(z.object({ id: z.string(), address: z.string(), public_key: z.string().optional() })),
      register_threshold: z.number(),
      recover_threshold: z.number(),
      pin_hashing_mode: z.string(),
    }),
    tokens: z.record(z.string(), z.string()),
  })
  .parse(await Bun.stdin.json());

const pin = process.env.X_CHAT_PIN;
if (!pin) throw new Error("X_CHAT_PIN is not set in .env.local");

for (const realm of input.config.realms) {
  if (!input.tokens[realm.id]) throw new Error(`No auth token for realm ${realm.id}`);
}

(globalThis as { JuiceboxGetAuthToken?: (realmId: Uint8Array) => Promise<string> }).JuiceboxGetAuthToken = async (realmId) =>
  input.tokens[Buffer.from(realmId).toString("hex")] ?? Promise.reject(new Error("unknown realm"));

const client = new Client(new Configuration(input.config), []);
try {
  const secret = await client.recover(new TextEncoder().encode(pin), new Uint8Array());
  console.log(JSON.stringify({ secret_hex: Buffer.from(secret).toString("hex") }));
} catch (error) {
  const failure = error as { reason?: number; guesses_remaining?: number };
  console.log(JSON.stringify({ error: String(error), reason: failure.reason ?? null, guesses_remaining: failure.guesses_remaining ?? null }));
  process.exit(1);
}
