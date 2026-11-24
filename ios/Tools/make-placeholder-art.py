#!/usr/bin/env python3
"""Fill the asset catalogs of this public source release with plain placeholder images.

The public repository has no art: the asset catalogs keep their Contents.json, but the images
(app icons, illustrations, the pixel cat, custom control symbols) are not published. The project
builds without them; Xcode then prints a warning for every missing file and the app shows empty
images. Run this once to write a flat grey square (or a grey circle symbol) for every missing
file, so the build is quiet and the app icon is not blank:

    python3 ios/Tools/make-placeholder-art.py          # writes only files that are missing
    python3 ios/Tools/make-placeholder-art.py --clean  # removes what it wrote

It never overwrites an existing file. What it writes is listed in
ios/Tools/.placeholder-art-written (ignored by git), and the repository's .gitignore ignores images
inside asset catalogs, so the placeholders are not committed by accident. Standard library only.

Not covered: furniture and cat meshes, room textures, sounds and fonts under
ios/Meowverse/Resources/ are loaded at run time and are simply absent (see SOURCE-RELEASE.md).
"""
import json
import struct
import sys
import zlib
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
LOG = IOS / "Tools" / ".placeholder-art-written"
GREY = (0xC9, 0xC4, 0xBC)


def png(width, height, rgb=GREY):
    """An opaque RGB PNG of one colour."""
    row = b"\x00" + bytes(rgb) * width
    raw = row * height

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def svg_image():
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
            '<rect width="64" height="64" rx="8" fill="#C9C4BC"/></svg>\n').encode()


def svg_symbol():
    # A custom-symbol template Xcode accepts (Apple's template v4 layout): baseline and cap-line
    # guides and margins for Small, Medium and Large, and a plain circle as the Regular glyph.
    sizes = {"S": (696, 625.541, 1398.340, 1501.340, 576, 721, 103),
             "M": (1126, 1055.541, 1385.340, 1514.340, 1006, 1151, 129),
             "L": (1556, 1485.541, 1369.340, 1530.340, 1436, 1581, 161)}
    guides, glyphs = [], []
    for name, (base, cap, left, right, top, bottom, width) in sizes.items():
        guides.append(f'  <line id="Baseline-{name}" x1="263" x2="3036" y1="{base}" y2="{base}"/>')
        guides.append(f'  <line id="Capline-{name}" x1="263" x2="3036" y1="{cap}" y2="{cap}"/>')
    for name, (base, cap, left, right, top, bottom, width) in sizes.items():
        guides.append(f'  <line id="left-margin-Regular-{name}" x1="{left}" x2="{left}" y1="{top}" y2="{bottom}"/>')
        guides.append(f'  <line id="right-margin-Regular-{name}" x1="{right}" x2="{right}" y1="{top}" y2="{bottom}"/>')
        r = width / 2
        glyphs.append(f'  <g id="Regular-{name}" transform="matrix(1 0 0 1 {left} {base})">\n'
                      f'   <path d="M0 {-r:.3f}A{r:.3f} {r:.3f} 0 1 0 {width} {-r:.3f}A{r:.3f} {r:.3f} 0 1 0 0 {-r:.3f}Z"/>\n  </g>')
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">\n'
            ' <g id="Notes"><text id="template-version" x="3036" y="1933">Template v.4.0</text></g>\n'
            ' <g id="Guides">\n' + "\n".join(guides) + '\n </g>\n'
            ' <g id="Symbols">\n' + "\n".join(glyphs) + '\n </g>\n</svg>\n').encode()


def pixel_size(entry):
    """Pixel size for an image-set or app-icon entry; 64 pt at the entry's scale otherwise."""
    scale = int(str(entry.get("scale", "1x")).rstrip("x") or 1)
    size = entry.get("size")
    if size:
        w, h = (float(v) for v in size.split("x"))
        return max(1, round(w * scale)), max(1, round(h * scale))
    return 64 * scale, 64 * scale


def placeholders():
    for contents in sorted(IOS.rglob("*.xcassets/**/Contents.json")):
        folder = contents.parent
        data = json.loads(contents.read_text(encoding="utf-8"))
        for entry in data.get("images", []):
            name = entry.get("filename")
            if not name:
                continue
            if name.lower().endswith(".svg"):
                yield folder / name, svg_image()
            elif name.lower().endswith(".pdf"):
                continue  # none in this project; skip rather than write a broken PDF
            else:
                w, h = pixel_size(entry)
                yield folder / name, png(w, h)
        for entry in data.get("symbols", []):
            name = entry.get("filename")
            if name:
                yield folder / name, svg_symbol()


def main():
    if "--clean" in sys.argv[1:]:
        if LOG.exists():
            for line in LOG.read_text(encoding="utf-8").splitlines():
                (IOS / line).unlink(missing_ok=True)
            LOG.unlink()
        print("removed the placeholders")
        return
    written = []
    for path, data in placeholders():
        if path.exists():
            continue
        path.write_bytes(data)
        written.append(str(path.relative_to(IOS)))
    previous = LOG.read_text(encoding="utf-8").splitlines() if LOG.exists() else []
    LOG.write_text("\n".join(sorted(set(previous) | set(written))) + "\n", encoding="utf-8")
    print(f"wrote {len(written)} placeholder files (listed in {LOG.relative_to(IOS.parent)})")


if __name__ == "__main__":
    main()
