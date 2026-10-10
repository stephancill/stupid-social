import { expect, test } from "bun:test";
import {
  captionInTrash,
  captionMentions,
  captionScale,
  exportTextLayout,
  insertMention,
  mentionToken,
  type Caption,
} from "../src/app/composer";
const caption: Caption = {
  id: "caption",
  text: "Hi @sam today",
  x: 0.3,
  y: 0.7,
  scale: 1,
  background: 0,
  font: 0,
  color: 0,
  mentions: [],
};
const actor = {
  network: "instagram" as const,
  id: "123",
  username: "sample.person",
  name: "Sample Person",
};

test("mentions follow the cursor and ignore email addresses and completed tokens", () => {
  expect(mentionToken({ text: "Hi @sample today", cursor: 6 })).toEqual({
    start: 3,
    end: 10,
    query: "sa",
  });
  expect(mentionToken({ text: "@", cursor: 1 })?.query).toBe("");
  expect(mentionToken({ text: "user@example.com", cursor: 16 })).toBeUndefined();
  expect(mentionToken({ text: "@sample hello", cursor: 13 })).toBeUndefined();
  expect(mentionToken({ text: "@sample", cursor: 0 })).toBeUndefined();
});
test("selecting a mention replaces the whole token without losing adjacent text", () => {
  const result = insertMention({ caption, cursor: 5, actor })!;
  expect(result.caption.text).toBe("Hi @sample.person today");
  expect(result.cursor).toBe(17);
  expect(result.caption.mentions).toEqual([actor]);
  const atEnd = insertMention({
    caption: { ...caption, text: "Hi @sa", mentions: [actor] },
    cursor: 6,
    actor,
  })!;
  expect(atEnd.caption.text).toBe("Hi @sample.person ");
  expect(atEnd.caption.mentions).toHaveLength(1);
});
test("export includes only selected mentions still present as complete handles", () => {
  const tagged = { ...caption, text: "Hello @SAMPLE.person", mentions: [actor] };
  expect(captionMentions({ captions: [tagged] })[0]).toMatchObject({
    user_id: actor.id,
    username: actor.username,
    x: 0.3,
    y: 0.7,
    rotation: 0,
  });
  expect(captionMentions({ captions: [{ ...tagged, text: "Hello @sample.person2" }] })).toEqual([]);
  expect(captionMentions({ captions: [{ ...tagged, text: "Removed" }] })).toEqual([]);
  expect(captionMentions({ captions: [{ ...tagged, mentions: [] }] })).toEqual([]);
});
test("export scales text uniformly into 9:16 rather than stretching the editor screenshot", () => {
  const output = exportTextLayout({
    canvas: { width: 400, height: 800 },
    output: { width: 1080, height: 1920 },
  });
  expect(output.scale).toBe(2.4);
  expect(output.maxWidth).toBeCloseTo(842.4);
});
test("caption resizing and the expanded trash target follow the iOS limits", () => {
  expect(captionScale({ scale: 0.1 })).toBe(0.45);
  expect(captionScale({ scale: 10 })).toBe(2.5);
  expect(captionInTrash({ x: 0.5, y: 708 / 800, width: 400, height: 800 })).toBe(true);
  expect(captionInTrash({ x: 0.63, y: 708 / 800, width: 400, height: 800 })).toBe(true);
  expect(captionInTrash({ x: 0.8, y: 708 / 800, width: 400, height: 800 })).toBe(false);
  expect(captionInTrash({ x: 0.5, y: 0.5, width: 400, height: 800 })).toBe(false);
});
