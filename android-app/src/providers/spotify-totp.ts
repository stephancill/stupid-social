import { hmac } from "@noble/hashes/hmac.js";
import { sha1 } from "@noble/hashes/legacy.js";
export function spotifyTOTP({ seconds }: { seconds: number }) {
  const secret = new TextEncoder().encode(
    [...',7/*F("rLJ2oxaKL^f+E1xvP@N'].map((c, i) => c.charCodeAt(0) ^ ((i % 33) + 9)).join(""),
  );
  const counter = new Uint8Array(8);
  new DataView(counter.buffer).setBigUint64(0, BigInt(Math.floor(seconds / 30)));
  const digest = hmac(sha1, secret, counter),
    offset = digest[digest.length - 1]! & 15;
  return String(
    (new DataView(digest.buffer, digest.byteOffset).getUint32(offset) & 0x7fffffff) % 1000000,
  ).padStart(6, "0");
}
