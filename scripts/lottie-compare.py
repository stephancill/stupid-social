#!/usr/bin/env python3
"""Compare the app's Lottie renderer (Sources/StupidChatKit/Stickers) with rlottie, Telegram's renderer.

Builds both renderers as Mac command-line tools (Telegram's rlottie fork from third-party/rlottie-telegram, cloned and built with cmake on
first use), renders evenly spaced frames of each sticker with both, and measures how many pixels differ, as a share
of the pixels either one draws. Writes logs/lottie-compare/report.html, worst first, with reference, ours and the
difference side by side.

    python3 scripts/lottie-compare.py logs/sticker-corpus/*.tgs [--frames 8] [--size 256] [--threshold 2]
    python3 scripts/lottie-compare.py Tests/Fixtures/Lottie/*.json

Needs cmake, ninja and ImageMagick (`magick`). The corpus comes from `scripts/telegram-client.py sticker-corpus`.
"""

import argparse
import concurrent.futures
import gzip
import html
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ROOT / "logs" / "lottie-tools"
OUTPUT = ROOT / "logs" / "lottie-compare"
# Telegram's fork: what Telegram's apps draw. Upstream rlottie has since added limits that blank some stickers.
RLOTTIE = ROOT / "third-party" / "rlottie-telegram"


def run(command: list, **kwargs) -> str:
    return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs).stdout


def build_tools() -> tuple[pathlib.Path, pathlib.Path]:
    TOOLS.mkdir(parents=True, exist_ok=True)
    if not (RLOTTIE / "build" / "librlottie.a").exists():
        if not RLOTTIE.exists():
            run(["git", "clone", "--depth", "1", "https://github.com/TelegramMessenger/rlottie", str(RLOTTIE)])
        run(["cmake", "-S", str(RLOTTIE), "-B", str(RLOTTIE / "build"), "-G", "Ninja", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
             "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DLOTTIE_MODULE=OFF", "-DLOTTIE_THREAD=OFF",
             # Its NEON assembly isn't built on macOS; the portable C++ paths draw the same.
             "-DCMAKE_CXX_FLAGS=-U__ARM_NEON__ -w", "-DCMAKE_C_FLAGS=-U__ARM_NEON__"])
        subprocess.run(["cmake", "--build", str(RLOTTIE / "build"), "--target", "rlottie"], check=True, capture_output=True)
    reference = TOOLS / "reference"
    source = ROOT / "scripts" / "lottie" / "reference.cpp"
    if not reference.exists() or reference.stat().st_mtime < source.stat().st_mtime:
        run(["clang++", "-std=c++17", "-O2", "-I", str(RLOTTIE / "inc"), str(source), str(RLOTTIE / "build" / "librlottie.a"), "-o", str(reference)])
    ours = TOOLS / "render"
    sources = sorted((ROOT / "Sources" / "StupidChatKit" / "Stickers").glob("*.swift")) + [ROOT / "scripts" / "lottie" / "render.swift"]
    if not ours.exists() or ours.stat().st_mtime < max(s.stat().st_mtime for s in sources):
        # render.swift is top-level code, so it's compiled as main.swift.
        main = TOOLS / "main.swift"
        shutil.copy(sources[-1], main)
        run(["xcrun", "swiftc", "-O", "-o", str(ours)] + [str(s) for s in sources[:-1]] + [str(main)])
    return reference, ours


def pixels(path: pathlib.Path) -> int:
    """Pixels that aren't fully transparent."""
    return int(float(run(["magick", str(path), "-alpha", "extract", "-threshold", "0", "-format", "%[fx:mean*w*h]", "info:"])))


def compare(args: tuple) -> dict:
    sticker, reference, ours, size, frame_count, fuzz = args
    name = sticker.stem
    out = OUTPUT / name
    out.mkdir(parents=True, exist_ok=True)
    json_path = out / "animation.json"
    data = sticker.read_bytes()
    json_path.write_bytes(gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data)
    try:
        total = int(run([str(reference), str(json_path), str(out), str(size), "0"]).split()[0])
    except subprocess.CalledProcessError as error:
        return {"name": name, "error": f"rlottie: {error.stderr.strip()}"}
    frames = sorted({round(i * (total - 1) / max(frame_count - 1, 1)) for i in range(frame_count)})
    run([str(reference), str(json_path), str(out), str(size)] + [str(f) for f in frames])
    try:
        run([str(ours), str(sticker), str(out), str(size)] + [str(f) for f in frames])
    except subprocess.CalledProcessError as error:
        return {"name": name, "error": f"ours: {error.stderr.strip()[-300:]}"}
    results = []
    for frame in frames:
        ref, mine, diff = out / f"{frame}.pam", out / f"{frame}.png", out / f"{frame}-diff.png"
        run(["magick", str(ref), str(out / f"{frame}-ref.png")])
        # Differences in colour or coverage beyond `fuzz`, over the pixels either renderer draws.
        result = subprocess.run(["magick", "compare", "-metric", "AE", "-fuzz", f"{fuzz}%", str(ref), str(mine), str(diff)], capture_output=True, text=True)
        differing = int(float(result.stderr.split()[0]))
        drawn = max(pixels(ref), pixels(mine), 1)
        results.append((frame, 100 * differing / drawn))
    worst = max(results, key=lambda r: r[1])
    return {"name": name, "frames": results, "worst": worst[1], "worst_frame": worst[0], "total": total}


def report(results: list[dict], threshold: float):
    rows = []
    for result in sorted(results, key=lambda r: -r.get("worst", 1e9)):
        name = result["name"]
        if "error" in result:
            rows.append(f"<tr><td>{html.escape(name)}</td><td colspan=4>{html.escape(result['error'])}</td></tr>")
            continue
        frame = result["worst_frame"]
        status = "pass" if result["worst"] <= threshold else "FAIL"
        cells = "".join(f'<td><img src="{name}/{frame}{suffix}.png" width=160></td>' for suffix in ("-ref", "", "-diff"))
        per_frame = ", ".join(f"{f}: {p:.1f}%" for f, p in result["frames"])
        rows.append(f"<tr><td>{html.escape(name)}<br>{status} {result['worst']:.2f}% (frame {frame})<br><small>{per_frame}</small></td>{cells}</tr>")
    page = f"""<!doctype html><meta charset=utf-8><title>Lottie comparison</title>
<style>body{{font:14px system-ui;background:#f4f4f4}}td{{vertical-align:top;padding:4px}}img{{background:repeating-conic-gradient(#ddd 0 25%,#fff 0 50%) 0/16px 16px}}</style>
<p>Differing pixels (fuzz) as a share of drawn pixels. Threshold {threshold}%.</p>
<table><tr><th>sticker</th><th>rlottie</th><th>ours</th><th>difference</th></tr>{''.join(rows)}</table>"""
    (OUTPUT / "report.html").write_text(page)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", type=pathlib.Path)
    parser.add_argument("--frames", type=int, default=8)
    parser.add_argument("--size", type=int, default=256)
    parser.add_argument("--threshold", type=float, default=2.0, help="percent of drawn pixels that may differ")
    parser.add_argument("--fuzz", type=float, default=10.0, help="colour distance (percent) under which pixels match")
    args = parser.parse_args()
    reference, ours = build_tools()
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    jobs = [(f, reference, ours, args.size, args.frames, args.fuzz) for f in args.files]
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
        results = list(pool.map(compare, jobs))
    report(results, args.threshold)
    compared = [r for r in results if "error" not in r]
    passed = [r for r in compared if r["worst"] <= args.threshold]
    errors = [r for r in results if "error" in r]
    print(f"{len(passed)}/{len(compared)} pass (worst frame ≤ {args.threshold}% differing), {len(errors)} errors")
    for result in sorted(compared, key=lambda r: -r["worst"])[:15]:
        print(f"  {result['worst']:6.2f}%  {result['name']} frame {result['worst_frame']}")
    for result in errors[:10]:
        print(f"  error {result['name']}: {result['error']}")
    print(f"report: {OUTPUT / 'report.html'}")
    sys.exit(0 if len(passed) == len(compared) and not errors else 1)


if __name__ == "__main__":
    main()
