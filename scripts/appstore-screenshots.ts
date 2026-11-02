// App Store screenshots in the stupid style: white, plain lowercase type, black mouse-drawn doodles.
// Frames demo-mode captures from screenshots/<set>/raw/<device>/ into screenshots/<set>/<device>/ at native size.
// Usage: bun scripts/appstore-screenshots.ts <set> [iphone|ipad ...]   e.g. bun scripts/appstore-screenshots.ts appstore-1.0.2
import { $ } from "bun";
import { mkdirSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const logo = `${root}Assets.xcassets/AppIcon.appiconset/Icon-1024.png`;
// Inlined so a slow CDN can't leave a page without its doodles or layout.
const rough = await (
  await fetch("https://cdn.jsdelivr.net/npm/roughjs@4.6.6/bundled/rough.js")
).text();
const devices = {
  iphone: { width: 1320, height: 2868, scale: 1, shotWidth: 0.78 },
  ipad: { width: 2048, height: 2732, scale: 1.45, shotWidth: 0.74 },
};

// Doodles run in the page: strike/under/circle(id) mark a word, arrow() points from the subtitle into the screen,
// star() sits by the headline, logo() puts the app icon's bubble top right.
type Slide = {
  raw: string;
  headline: string;
  subtitle: string;
  doodles: string;
  devices?: (keyof typeof devices)[];
};
const slides: Slide[] = [
  {
    raw: "01-feed",
    headline: `only the best<br>parts of social`,
    subtitle: `your people. not the <span id="m">feed</span>`,
    doodles: `strike("m"); logo(); arrow();`,
  },
  {
    raw: "02-chats",
    headline: `every chat,<br><span id="m">one inbox</span>`,
    subtitle: `telegram, x, instagram, bluesky, spotify and apron`,
    doodles: `under("m"); star(); arrow();`,
  },
  {
    raw: "03-story",
    headline: `stories from<br><span id="m">friends</span>, not<br>strangers`,
    subtitle: `instagram, spotify and github`,
    doodles: `circle("m"); star(); arrow();`,
  },
  {
    raw: "04-chat-apron",
    headline: `react like<br>you <span id="m">mean it</span>`,
    subtitle: `replies, reactions and custom emoji`,
    doodles: `under("m"); arrow();`,
  },
  {
    raw: "05-chat-trip-top",
    headline: `photos, voice<br>notes, <span id="m">the lot</span>`,
    subtitle: `in every chat, on every network`,
    doodles: `under("m"); star(); arrow();`,
  },
  {
    raw: "06-detail",
    headline: `<span id="m">no</span> rabbit<br>holes`,
    subtitle: `just the post behind the notification`,
    doodles: `under("m"); arrow();`,
  },
  {
    raw: "07-chat-amy",
    headline: `made for<br><span id="m">actual</span> friends`,
    subtitle: `no strangers, no ads, no feed`,
    doodles: `under("m"); star(); arrow();`,
    devices: ["iphone"],
  },
];

function page(slide: Slide, rawPath: string, device: (typeof devices)[keyof typeof devices]) {
  const { width, height, scale: s, shotWidth } = device;
  return `<!doctype html><html><head><meta charset="utf-8">
<script>${rough}</script>
<style>
  * { margin: 0; box-sizing: border-box }
  body { width: ${width}px; height: ${height}px; overflow: hidden; background: #fff; color: #000; position: relative; font-family: -apple-system, system-ui, sans-serif }
  .text { position: absolute; top: ${140 * s}px; left: ${100 * s}px; right: ${100 * s}px }
  h1 { font-weight: 700; font-size: ${136 * s}px; line-height: 1; letter-spacing: ${-4 * s}px }
  p { margin-top: ${44 * s}px; font-size: ${56 * s}px; line-height: 1.15 }
  span { display: inline-block }
  .shot { position: absolute; left: ${(width * (1 - shotWidth)) / 2}px; width: ${width * shotWidth}px; border-radius: ${118 * s}px; overflow: hidden }
  .shot img { display: block; width: 100% }
  svg { position: absolute; inset: 0; width: ${width}px; height: ${height}px; overflow: visible }
</style></head><body>
<div class="text"><h1>${slide.headline}</h1><p>${slide.subtitle}</p></div>
<div class="shot"><img src="file://${rawPath}"></div>
<svg id="d"></svg>
<script>
  // Measure once the screenshot has loaded, or the screen has no height yet.
  window.addEventListener("load", () => {
  const s = ${s}, W = ${width};
  const svg = document.getElementById("d"), rc = rough.svg(svg);
  let seed = 7;
  const pen = (w = 15) => ({ stroke: "#000", strokeWidth: w * s, roughness: 1.6, bowing: 1.4, disableMultiStroke: true, seed: seed++ });
  const add = (node) => svg.appendChild(node);
  const box = (el) => (typeof el === "string" ? document.getElementById(el) : el).getBoundingClientRect();
  const sub = box(document.querySelector("p")), head = box(document.querySelector("h1"));
  // The screen starts a fixed gap below the subtitle, leaving room for the arrow.
  const shotEl = document.querySelector(".shot");
  shotEl.style.top = sub.bottom + 250 * s + "px";
  const shot = box(shotEl);

  function strike(id) {
    const r = box(id), y = r.top + r.height * 0.55;
    add(rc.line(r.left - 14 * s, y + 8 * s, r.right + 14 * s, y - 10 * s, pen(11)));
    add(rc.line(r.left - 8 * s, y - 6 * s, r.right + 18 * s, y + 4 * s, pen(11)));
  }
  function under(id) {
    const r = box(id);
    add(rc.curve([[r.left - 6 * s, r.bottom + 6 * s], [r.left + r.width / 2, r.bottom - 4 * s], [r.right + 10 * s, r.bottom + 2 * s]], pen()));
  }
  function circle(id) {
    const r = box(id);
    add(rc.ellipse(r.left + r.width / 2, r.top + r.height / 2 + 6 * s, r.width + 36 * s, r.height + 14 * s, pen(11)));
  }
  function arrow() {
    const x = W * 0.72, y0 = sub.bottom + 40 * s, y1 = shot.top - 40 * s;
    const pts = [[x - 80 * s, y0], [x + 40 * s, y0 + (y1 - y0) * 0.35], [x + 70 * s, y1]];
    add(rc.curve(pts, pen()));
    const [a, b] = pts.slice(-2), angle = Math.atan2(b[1] - a[1], b[0] - a[0]), length = 70 * s;
    for (const d of [0.62, -0.62]) add(rc.line(b[0], b[1], b[0] - length * Math.cos(angle + d), b[1] - length * Math.sin(angle + d), pen()));
  }
  function star() {
    const x = W - 170 * s, y = head.top + 90 * s, r = 60 * s;
    for (let i = 0; i < 5; i++) {
      const a = -Math.PI / 2 + (i * 2 * Math.PI) / 5;
      add(rc.line(x, y, x + r * Math.cos(a), y + r * Math.sin(a), pen()));
    }
  }
  function logo() {
    const size = 380 * s, image = document.createElementNS("http://www.w3.org/2000/svg", "image");
    image.setAttribute("href", "file://${logo}");
    image.setAttribute("x", W - size + 20 * s);
    image.setAttribute("y", head.top - size * 0.22);
    image.setAttribute("width", size);
    image.setAttribute("height", size);
    svg.prepend(image);
  }

  // A wobbly hand-drawn outline around the screen, like the stupid simulator icon.
  const m = 26 * s, R = 140 * s, l = shot.left - m, t = shot.top - m, w = shot.width + 2 * m, h = shot.height + 2 * m;
  add(rc.path(\`M\${l + R} \${t} L\${l + w - R} \${t} Q\${l + w} \${t} \${l + w} \${t + R} L\${l + w} \${t + h - R} Q\${l + w} \${t + h} \${l + w - R} \${t + h} L\${l + R} \${t + h} Q\${l} \${t + h} \${l} \${t + h - R} L\${l} \${t + R} Q\${l} \${t} \${l + R} \${t}\`, { ...pen(16), roughness: 1.1 }));
  ${slide.doodles}
  });
</script></body></html>`;
}

const [set, ...only] = Bun.argv.slice(2);
if (!set) throw new Error("usage: bun scripts/appstore-screenshots.ts <set> [iphone|ipad ...]");
for (const name of (only.length ? only : Object.keys(devices)) as (keyof typeof devices)[]) {
  const device = devices[name];
  const out = `${root}screenshots/${set}/${name}`;
  mkdirSync(`${out}/html`, { recursive: true });
  let index = 1;
  for (const slide of slides.filter((slide) => !slide.devices || slide.devices.includes(name))) {
    const raw = `${root}screenshots/${set}/raw/${name}/${slide.raw}.png`;
    if (!(await Bun.file(raw).exists())) throw new Error(`missing capture ${raw}`);
    const file = `${String(index++).padStart(2, "0")}-${slide.raw.replace(/^\d+-/, "")}`;
    await Bun.write(`${out}/html/${file}.html`, page(slide, raw, device));
    // Chrome exits non-zero on teardown after writing the screenshot, so check the file instead.
    await $`${chrome} --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files --force-device-scale-factor=1 --window-size=${device.width},${device.height} --virtual-time-budget=8000 --screenshot=${out}/${file}.png file://${out}/html/${file}.html`
      .quiet()
      .nothrow();
    if (!(await Bun.file(`${out}/${file}.png`).exists()))
      throw new Error(`Chrome wrote no ${file}.png`);
    console.log(`${name}/${file}.png`);
  }
}
