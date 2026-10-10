import type { Actor } from "./models";

export type Caption = {
  id: string;
  text: string;
  x: number;
  y: number;
  scale: number;
  background: number;
  font: number;
  color: number;
  mentions: Actor[];
};

export function captionScale({ scale }: { scale: number }) {
  return Math.max(0.45, Math.min(2.5, scale));
}

export function mentionToken({ text, cursor }: { text: string; cursor: number }) {
  const position = Math.max(0, Math.min(text.length, cursor));
  const start = text.lastIndexOf("@", position - 1);
  if (start < 0 || start >= position || (start > 0 && !/\s/u.test(text[start - 1]!)))
    return undefined;
  const query = text.slice(start + 1, position);
  if (!/^[\p{L}\p{N}._]*$/u.test(query)) return undefined;
  const suffix = text.slice(position).match(/^[\p{L}\p{N}._]*/u)?.[0] ?? "";
  return { start, end: position + suffix.length, query };
}

export function insertMention({
  caption,
  cursor,
  actor,
}: {
  caption: Caption;
  cursor: number;
  actor: Actor;
}) {
  const token = mentionToken({ text: caption.text, cursor });
  if (!token) return undefined;
  const replacement = `@${actor.username}${token.end === caption.text.length ? " " : ""}`;
  return {
    caption: {
      ...caption,
      text: caption.text.slice(0, token.start) + replacement + caption.text.slice(token.end),
      mentions: [...caption.mentions.filter((item) => item.id !== actor.id), actor],
    },
    cursor: token.start + replacement.length,
  };
}

export function captionMentions({ captions }: { captions: Caption[] }) {
  return captions.flatMap((caption) => {
    const handles = new Set(
      [...caption.text.matchAll(/(?:^|\s)@([\p{L}\p{N}._]+)/gu)].map((match) =>
        match[1]!.toLowerCase(),
      ),
    );
    return caption.mentions
      .filter((actor) => handles.has(actor.username.toLowerCase()))
      .map((actor) => ({
        user_id: actor.id,
        username: actor.username,
        x: Math.max(0, Math.min(1, caption.x)),
        y: Math.max(0, Math.min(1, caption.y)),
        width: Math.max(0.18, Math.min(0.82, caption.text.length * 0.028 * caption.scale)),
        height: Math.max(0.06, Math.min(0.18, 0.08 * caption.scale)),
        rotation: 0,
        z: 0,
      }));
  });
}

export function captionInTrash({
  x,
  y,
  width,
  height,
}: {
  x: number;
  y: number;
  width: number;
  height: number;
}) {
  return Math.abs(x * width - width / 2) <= 52 && Math.abs(y * height - (height - 92)) <= 52;
}

export function exportTextLayout({
  canvas,
  output,
}: {
  canvas: { width: number; height: number };
  output: { width: number; height: number };
}) {
  return {
    scale: Math.min(output.width / canvas.width, output.height / canvas.height),
    maxWidth: (Math.min(canvas.width - 88, 420) * output.width) / canvas.width,
  };
}
