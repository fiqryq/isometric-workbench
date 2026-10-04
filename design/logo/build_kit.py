#!/usr/bin/env python3
"""Builds the Isometric Workbench logo kit SVGs (symbol, small cut, reversed, lockups, wordmark).

Usage: uv run --with fonttools --with uharfbuzz python design/logo/build_kit.py /path/to/Plex-SemiBold.ttf
The wordmark is IBM Plex Sans SemiBold (OFL), shaped with HarfBuzz and converted to outlines.
"""

import math
import sys
from pathlib import Path

import uharfbuzz as hb
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

BLUE = "#2D55E8"      # Blueprint ink
RED = "#E04A2F"       # Redline ink
INK = "#1A1A1A"
PAPER = "#FBFBFA"
WHITE = "#FFFFFF"

C30 = math.cos(math.pi / 6)
OUT = Path(__file__).parent / "kit"

# Geometry of the mark, in units of the cube edge.
MASTER = dict(gap=0.36, seam=0.04)
SMALL = dict(gap=0.50, seam=0.08)      # opened up so the lift survives 16–32 px
REVERSED = dict(gap=0.38, seam=0.05)   # light-on-dark spreads; open the gaps a touch


def mark_height(gap, **_):
    return 2 + gap


def mark(u, ox, oy, gap, seam, body=BLUE, lid=RED):
    """Two paths: the open block (left + right faces) and the lifted top face.
    (ox, oy) is the top-left of the mark's bounding box."""
    cx = ox + C30 * u
    cy = oy + (2 + gap) * u - u          # screen y of the iso origin's ground plane

    def p(x, y, z):
        return (cx + (x - y) * C30 * u, cy + (x + y) * 0.5 * u - z * u)

    def d(points):
        return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in points) + " Z"

    s, z = seam, 1 + gap
    left = [p(0, 1, 0), p(1 - s, 1, 0), p(1 - s, 1, 1), p(0, 1, 1)]
    right = [p(1, 0, 0), p(1, 1 - s, 0), p(1, 1 - s, 1), p(1, 0, 1)]
    top = [p(0, 0, z), p(1, 0, z), p(1, 1, z), p(0, 1, z)]
    return (f'<path id="block" fill="{body}" d="{d(left)} {d(right)}"/>'
            f'<path id="lid" fill="{lid}" d="{d(top)}"/>')


def mark_size(u, gap, **_):
    return 2 * C30 * u, (2 + gap) * u


class Wordmark:
    def __init__(self, font_path, tracking=-8):
        self.font = TTFont(font_path)
        self.glyphs = self.font.getGlyphSet()
        self.order = self.font.getGlyphOrder()
        blob = hb.Blob.from_file_path(font_path)
        self.hb_font = hb.Font(hb.Face(blob))
        self.upm = self.font["head"].unitsPerEm
        self.cap = self.font["OS/2"].sCapHeight
        self.tracking = tracking

    def shape(self, text):
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(self.hb_font, buf, {"kern": True, "liga": True})
        return buf.glyph_infos, buf.glyph_positions

    def width(self, text, cap_height):
        infos, positions = self.shape(text)
        adv = sum(p.x_advance + self.tracking for p in positions) - self.tracking
        return adv * cap_height / self.cap

    def path(self, text, x, baseline, cap_height):
        scale = cap_height / self.cap
        infos, positions = self.shape(text)
        pen_x, parts = 0, []
        for info, pos in zip(infos, positions):
            svg_pen = SVGPathPen(self.glyphs, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
            t = (scale, 0, 0, -scale, x + (pen_x + pos.x_offset) * scale, baseline - pos.y_offset * scale)
            self.glyphs[self.order[info.codepoint]].draw(TransformPen(svg_pen, t))
            if svg_pen.getCommands():
                parts.append(svg_pen.getCommands())
            pen_x += pos.x_advance + self.tracking
        return " ".join(parts)


def svg(w, h, title, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.0f} {h:.0f}" width="{w:.0f}" '
            f'height="{h:.0f}" role="img" aria-labelledby="title"><title id="title">{title}</title>\n'
            f'{body}\n</svg>\n')


def symbol_file(geom, body=BLUE, lid=RED, size=256, pad=12):
    u = (size - 2 * pad) / mark_height(**geom)
    w, h = mark_size(u, **geom)
    return svg(size, size, "Isometric Workbench",
               f'<g id="symbol">{mark(u, (size - w) / 2, (size - h) / 2, **geom, body=body, lid=lid)}</g>')


def horizontal(wm, body=BLUE, lid=RED, text=INK, height=256, pad=24):
    geom = MASTER
    u = (height - 2 * pad) / mark_height(**geom)
    sw, sh = mark_size(u, **geom)
    cap = 0.40 * sh
    gap = 0.75 * cap
    tw = wm.width("Isometric Workbench", cap)
    width = pad + sw + gap + tw + pad
    baseline = height / 2 + cap / 2
    body_svg = (f'<g id="symbol">{mark(u, pad, pad, **geom, body=body, lid=lid)}</g>'
                f'<path id="wordmark" fill="{text}" d="{wm.path("Isometric Workbench", pad + sw + gap, baseline, cap)}"/>')
    return svg(width, height, "Isometric Workbench", body_svg)


def stacked(wm, body=BLUE, lid=RED, text=INK, pad=24):
    geom = MASTER
    sh = 208
    u = sh / mark_height(**geom)
    sw, _ = mark_size(u, **geom)
    cap = 0.19 * sh
    leading = cap * 1.6
    lines = ["Isometric", "Workbench"]
    widths = [wm.width(t, cap) for t in lines]
    width = max(max(widths), sw) + 2 * pad
    first = pad + sh + 0.30 * sh + cap
    height = first + leading + pad
    parts = [f'<g id="symbol">{mark(u, (width - sw) / 2, pad, **geom, body=body, lid=lid)}</g>']
    d = " ".join(wm.path(t, (width - tw) / 2, first + i * leading, cap) for i, (t, tw) in enumerate(zip(lines, widths)))
    parts.append(f'<path id="wordmark" fill="{text}" d="{d}"/>')
    return svg(width, height, "Isometric Workbench", "".join(parts))


def wordmark_only(wm, text=INK, height=96, pad=12):
    cap = height - 2 * pad - 8
    tw = wm.width("Isometric Workbench", cap)
    return svg(tw + 2 * pad, height, "Isometric Workbench",
               f'<path id="wordmark" fill="{text}" d="{wm.path("Isometric Workbench", pad, pad + cap, cap)}"/>')


def main():
    wm = Wordmark(sys.argv[1])
    files = {
        "symbol/iw-symbol-color.svg": symbol_file(MASTER),
        "symbol/iw-symbol-small-color.svg": symbol_file(SMALL),
        "symbol/iw-symbol-reversed.svg": symbol_file(REVERSED, body=WHITE, lid=RED),
        "symbol/iw-symbol-reversed-white.svg": symbol_file(REVERSED, body=WHITE, lid=WHITE),
        "lockups/iw-horizontal-color.svg": horizontal(wm),
        "lockups/iw-horizontal-reversed.svg": horizontal(wm, body=WHITE, lid=RED, text=WHITE),
        "lockups/iw-stacked-color.svg": stacked(wm),
        "lockups/iw-stacked-reversed.svg": stacked(wm, body=WHITE, lid=RED, text=WHITE),
        "lockups/iw-wordmark.svg": wordmark_only(wm),
    }
    for name, content in files.items():
        path = OUT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        print("wrote", path.relative_to(OUT.parent))


if __name__ == "__main__":
    main()
