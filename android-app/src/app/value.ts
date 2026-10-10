import { z } from "zod";
export const object = (value: unknown): Record<string, unknown> =>
  z.record(z.string(), z.unknown()).safeParse(value).data ?? {};
export const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);
export const text = (value: unknown): string =>
  typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
export const numeric = (value: unknown): number | undefined =>
  value !== null && value !== undefined && Number.isFinite(Number(value))
    ? Number(value)
    : undefined;
export const timestamp = (value: unknown): number =>
  typeof value === "number"
    ? value < 100000000000
      ? value * 1000
      : value
    : Date.parse(text(value)) || 0;
export function https(value: unknown): string | undefined {
  const s = z.url().safeParse(value);
  return s.success && new URL(s.data).protocol === "https:" ? s.data : undefined;
}
export function findObjects({ root, key }: { root: unknown; key: string }): unknown[] {
  const found: unknown[] = [];
  function walk(value: unknown) {
    if (Array.isArray(value)) {
      value.forEach(walk);
      return;
    }
    if (!value || typeof value !== "object") return;
    const o = object(value);
    if (key in o) found.push(o[key]);
    Object.values(o).forEach(walk);
  }
  walk(root);
  return found;
}
