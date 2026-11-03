#!/usr/bin/env python3
"""Which Lottie features a corpus of Telegram stickers (.tgs, gzipped Lottie JSON) uses.

Prints, for each feature, how many stickers use it, so the app's renderer (StupidSocialCore/Stickers) supports the
common ones first. With --cover, prints a small set of stickers that together use every feature seen, for the
reference-image comparison (scripts/lottie-compare.py).

    python3 scripts/lottie-census.py logs/sticker-corpus [--cover]
"""

import argparse
import collections
import gzip
import json
import pathlib

LAYER_TYPES = {0: "precomp", 1: "solid", 2: "image", 3: "null", 4: "shape", 5: "text"}
SHAPE_TYPES = {
    "gr": "group", "sh": "path", "rc": "rect", "el": "ellipse", "sr": "star", "fl": "fill", "st": "stroke",
    "gf": "gradient fill", "gs": "gradient stroke", "tr": "transform", "tm": "trim path", "rd": "round corners",
    "mm": "merge paths", "rp": "repeater", "op": "offset path", "pb": "pucker bloat", "tw": "twist", "zz": "zig zag",
}
MATTES = {1: "alpha", 2: "alpha inverted", 3: "luma", 4: "luma inverted"}
MASK_MODES = {"a": "add", "s": "subtract", "i": "intersect", "l": "lighten", "d": "darken", "f": "difference", "n": "none"}


def features(animation: dict) -> set[str]:
    found: set[str] = set()
    found.add(f"fps {animation.get('fr')}")

    def prop(value, name: str):
        if not isinstance(value, dict):
            return
        if value.get("a") == 1 or (isinstance(value.get("k"), list) and value["k"] and isinstance(value["k"][0], dict) and "t" in value["k"][0]):
            found.add(f"animated {name}")
            for key in value["k"]:
                if not isinstance(key, dict):
                    continue
                if key.get("h") == 1:
                    found.add("keyframe hold")
                if "ti" in key or "to" in key:
                    if any(v != 0 for v in (key.get("ti") or []) + (key.get("to") or [])):
                        found.add("keyframe spatial tangents")
                if isinstance((key.get("o") or {}).get("x"), list) and len(key["o"]["x"]) > 1:
                    found.add("keyframe per-dimension easing")
        if "x" in value:
            found.add("expression")

    def transform(t: dict, where: str):
        if not t:
            return
        p = t.get("p") or {}
        if p.get("s") is True:
            found.add(f"{where} split position")
        for key in ("a", "p", "s", "r", "o", "sk", "sa"):
            if key in t:
                prop(t[key], f"{where} transform.{key}")
        if (t.get("sk") or {}).get("k", 0) not in (0, [0]):
            found.add(f"{where} skew")
        for key in ("rx", "ry", "rz", "or"):
            if key in t:
                found.add(f"{where} 3d rotation")

    def shapes(items: list, depth: int):
        for item in items:
            ty = item.get("ty")
            found.add(f"shape {SHAPE_TYPES.get(ty, ty)}")
            if item.get("hd"):
                found.add("shape hidden")
            if ty == "gr":
                shapes(item.get("it", []), depth + 1)
            elif ty == "sh":
                prop(item.get("ks"), "path")
            elif ty in ("rc", "el", "sr"):
                if item.get("d") == 3:
                    found.add("shape direction reversed")
                for key in ("p", "s", "r", "ir", "or", "is", "os", "pt"):
                    if key in item:
                        prop(item[key], f"{SHAPE_TYPES[ty]}.{key}")
                if ty == "sr":
                    found.add(f"star type {item.get('sy')}")
            elif ty in ("fl", "gf"):
                found.add(f"fill rule {item.get('r', 1)}")
                prop(item.get("o"), f"{SHAPE_TYPES[ty]} opacity")
                if ty == "fl":
                    prop(item.get("c"), "fill color")
                else:
                    found.add(f"gradient type {item.get('t')}")
                    prop(item.get("g", {}).get("k"), "gradient colors")
                    stops = item.get("g", {}).get("p", 0)
                    values = item.get("g", {}).get("k", {}).get("k")
                    if isinstance(values, list) and values and not isinstance(values[0], dict) and len(values) > stops * 4:
                        found.add("gradient with opacity stops")
                    if "h" in item:
                        prop(item["h"], "gradient highlight")
            elif ty in ("st", "gs"):
                found.add(f"line cap {item.get('lc')}")
                found.add(f"line join {item.get('lj')}")
                prop(item.get("w"), "stroke width")
                prop(item.get("o"), "stroke opacity")
                if ty == "st":
                    prop(item.get("c"), "stroke color")
                if item.get("d"):
                    found.add("stroke dashes")
            elif ty == "tr":
                transform(item, "group")
            elif ty == "tm":
                found.add(f"trim mode {item.get('m', 1)}")
                for key in ("s", "e", "o"):
                    prop(item.get(key), f"trim.{key}")
            elif ty == "rd":
                prop(item.get("r"), "round corners radius")
            elif ty == "rp":
                prop(item.get("c"), "repeater copies")

    def layers(items: list, in_precomp: bool):
        for layer in items:
            ty = layer.get("ty")
            found.add(f"layer {LAYER_TYPES.get(ty, ty)}")
            if layer.get("ddd"):
                found.add("layer 3d")
            if layer.get("ao"):
                found.add("layer auto-orient")
            if layer.get("sr", 1) != 1:
                found.add("layer time stretch")
            if layer.get("st", 0) != 0:
                found.add("layer start time")
            if "tm" in layer:
                found.add("layer time remap")
            if "parent" in layer:
                found.add("layer parent")
            if layer.get("hd"):
                found.add("layer hidden")
            if layer.get("bm", 0):
                found.add(f"blend mode {layer['bm']}")
            if layer.get("tt"):
                found.add(f"track matte {MATTES.get(layer['tt'], layer['tt'])}")
            if layer.get("td"):
                found.add("matte source")
            if layer.get("ef"):
                found.add("effects")
            if layer.get("hasMask") or layer.get("masksProperties"):
                for mask in layer.get("masksProperties") or []:
                    found.add(f"mask {MASK_MODES.get(mask.get('mode'), mask.get('mode'))}{' inverted' if mask.get('inv') else ''}")
                    prop(mask.get("pt"), "mask path")
                    if (mask.get("o") or {}).get("k", 100) != 100 or (mask.get("o") or {}).get("a"):
                        found.add("mask opacity")
                    if (mask.get("x") or {}).get("k", 0) not in (0, None):
                        found.add("mask expansion")
            if in_precomp:
                found.add("layer inside precomp")
            transform(layer.get("ks") or {}, "layer")
            if ty == 0:
                if layer.get("w") is not None:
                    found.add("precomp size")
            if ty == 4:
                shapes(layer.get("shapes", []), 0)

    layers(animation.get("layers", []), False)
    for asset in animation.get("assets", []):
        if "layers" in asset:
            found.add("asset precomp")
            layers(asset["layers"], True)
        elif "p" in asset:
            found.add("asset image")
    if animation.get("markers"):
        found.add("markers")
    if animation.get("chars") or animation.get("fonts"):
        found.add("text glyphs")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("corpus")
    parser.add_argument("--cover", action="store_true", help="print stickers that together use every feature")
    args = parser.parse_args()
    paths = sorted(pathlib.Path(args.corpus).glob("*.tgs"))
    per_file: dict[str, set[str]] = {}
    counts: collections.Counter = collections.Counter()
    for path in paths:
        animation = json.loads(gzip.decompress(path.read_bytes()))
        found = features(animation)
        per_file[path.name] = found
        counts.update(found)
    print(f"{len(paths)} stickers")
    for feature, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        print(f"{count:6d} {100 * count / len(paths):5.1f}%  {feature}")
    if args.cover:
        remaining = set(counts)
        chosen = []
        while remaining:
            name = max(per_file, key=lambda n: len(per_file[n] & remaining))
            gained = per_file[name] & remaining
            if not gained:
                break
            chosen.append(name)
            remaining -= gained
        print("\ncover:", " ".join(chosen))


if __name__ == "__main__":
    main()
