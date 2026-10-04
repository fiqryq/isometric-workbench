#!/usr/bin/env python3
"""Generates the logo concept SVGs (black, 256 canvas) with exact isometric geometry."""

import math
from pathlib import Path

OUT = Path(__file__).parent / "concepts"
OUT.mkdir(exist_ok=True)
C30 = math.cos(math.pi / 6)


def iso(x, y, z, u, cx, cy):
    return (cx + (x - y) * C30 * u, cy + (x + y) * 0.5 * u - z * u)


def poly(points, **attrs):
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in points) + " Z"
    extra = "".join(f' {k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    return f'<path d="{d}"{extra}/>'


def svg(title, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" '
            f'role="img" aria-labelledby="title"><title id="title">{title}</title>\n{body}\n</svg>\n')


def lift(gap=0.2, seam=0.065, lid=0.0):
    """A: block whose top has lifted off. lid > 0 gives the lifted part a thickness."""
    u = 98
    total = 2 + gap + lid
    cx, cy = 128, 128 - (2 * u - total * u) / 2 + u * (total - 2) / 2
    cy = 128 + u * (total) / 2 - u  # bottom vertex at 128 + total*u/2
    p = lambda x, y, z: iso(x, y, z, u, cx, cy)
    s = seam
    left = [p(0, 1, 0), p(1 - s, 1, 0), p(1 - s, 1, 1), p(0, 1, 1)]
    right = [p(1, 0, 0), p(1, 1 - s, 0), p(1, 1 - s, 1), p(1, 0, 1)]
    z0 = 1 + gap
    parts = [poly(left), poly(right)]
    if lid:
        z1 = z0 + lid
        parts.append(poly([p(0, 1, z0), p(1 - s, 1, z0), p(1 - s, 1, z1), p(0, 1, z1)]))
        parts.append(poly([p(1, 0, z0), p(1, 1 - s, z0), p(1, 1 - s, z1), p(1, 0, z1)]))
        top = [p(0, 0, z1 + s * 0), p(1, 0, z1), p(1, 1, z1), p(0, 1, z1)]
        # top face sits above the lid sides, separated by a seam
        k = s * 0.9
        top = [p(0, 0, z1 + k), p(1, 0, z1 + k), p(1, 1, z1 + k), p(0, 1, z1 + k)]
        parts.append(poly(top))
    else:
        parts.append(poly([p(0, 0, z0), p(1, 0, z0), p(1, 1, z0), p(0, 1, z0)]))
    return svg("Isometric Workbench — Lift", f'<g fill="#111">{"".join(parts)}</g>')


def section(stroke=11):
    """B: line-art block with the front octant cut away; the cut faces are solid (poché)."""
    u = 50
    cx, cy = 128, 128 + 2 * u * 0.5  # centre of the 2x2x2 block on screen
    cy = 128 + u * 0  # placeholder, recomputed below
    # screen extent: top vertex z=2 at (0,0) -> y = cy - 2u ; bottom vertex (2,2,0) -> y = cy + 2u
    cy = 128
    p = lambda x, y, z: iso(x, y, z, u, cx, cy - 0)
    # shift so the whole block is centred: top (0,0,2) at cy-2u, bottom (2,2,0) at cy+2u -> already centred
    top = [p(0, 0, 2), p(2, 0, 2), p(2, 1, 2), p(1, 1, 2), p(1, 2, 2), p(0, 2, 2)]
    left = [p(0, 2, 2), p(1, 2, 2), p(1, 2, 1), p(2, 2, 1), p(2, 2, 0), p(0, 2, 0)]
    right = [p(2, 0, 2), p(2, 1, 2), p(2, 1, 1), p(2, 2, 1), p(2, 2, 0), p(2, 0, 0)]
    floor = [p(1, 1, 1), p(2, 1, 1), p(2, 2, 1), p(1, 2, 1)]
    wall_x = [p(1, 1, 1), p(1, 2, 1), p(1, 2, 2), p(1, 1, 2)]  # plane x=1, faces +x
    wall_y = [p(1, 1, 1), p(2, 1, 1), p(2, 1, 2), p(1, 1, 2)]  # plane y=1, faces +y
    line = f'fill="#fff" stroke="#111" stroke-width="{stroke}" stroke-linejoin="round"'
    body = (f'<g {line}>{poly(top)}{poly(left)}{poly(right)}</g>'
            f'<g fill="#111" stroke="#111" stroke-width="{stroke}" stroke-linejoin="round">'
            f'{poly(floor)}{poly(wall_x)}{poly(wall_y)}</g>')
    return svg("Isometric Workbench — Section", body)


def cylinder(cx, top_y, r, h, u_major, seam):
    """Iso cylinder: ellipse rx = r, ry = r*tan30-ish (iso circle ratio 0.577)."""
    rx, ry = r, r * 0.5774
    by = top_y + h
    sil = (f'M{cx - rx:.2f} {top_y:.2f} A{rx:.2f} {ry:.2f} 0 0 1 {cx + rx:.2f} {top_y:.2f} '
           f'L{cx + rx:.2f} {by:.2f} A{rx:.2f} {ry:.2f} 0 0 1 {cx - rx:.2f} {by:.2f} Z')
    rim = (f'M{cx - rx:.2f} {top_y:.2f} A{rx:.2f} {ry:.2f} 0 0 0 {cx + rx:.2f} {top_y:.2f}')
    return (f'<path fill="#111" d="{sil}"/>'
            f'<path fill="none" stroke="#fff" stroke-width="{seam}" d="{rim}"/>')


def axis_stack(seam=7):
    """C: an exploded assembly — three discs separated along a dash-dot centre line."""
    cx = 128
    discs = [(54, 22), (78, 20), (100, 26)]  # radius, thickness, top to bottom
    gap = 26
    heights = [r * 0.5774 * 2 + h for r, h in discs]
    total = sum(heights) + gap * (len(discs) - 1)
    y = 128 - total / 2
    shapes = []
    for (r, h), hh in zip(discs, heights):
        top_y = y + r * 0.5774
        shapes.append(cylinder(cx, top_y, r, h, 0, seam))
        y += hh + gap
    axis = (f'<path fill="none" stroke="#111" stroke-width="7" stroke-linecap="round" '
            f'stroke-dasharray="22 12 2 12" d="M128 8 V248"/>')
    return svg("Isometric Workbench — Assembly", axis + "".join(shapes))


def hatch_clip(points, spacing, width, cid):
    """Hatching clipped to a polygon (exploration only; bake to paths for the master)."""
    lines = "".join(f'M{x} 0 L{x + 256} 256 ' for x in range(-256, 256, spacing))
    return (f'<clipPath id="{cid}">{poly(points)}</clipPath>'
            f'<path clip-path="url(#{cid})" fill="none" stroke="#111" stroke-width="{width}" d="{lines}"/>')


def section_v2(stroke=11):
    """B v2: the cut faces are hatched like a section drawing; outer faces stay white."""
    u = 50
    p = lambda x, y, z: iso(x, y, z, u, 128, 128)
    top = [p(0, 0, 2), p(2, 0, 2), p(2, 1, 2), p(1, 1, 2), p(1, 2, 2), p(0, 2, 2)]
    left = [p(0, 2, 2), p(1, 2, 2), p(1, 2, 1), p(2, 2, 1), p(2, 2, 0), p(0, 2, 0)]
    right = [p(2, 0, 2), p(2, 1, 2), p(2, 1, 1), p(2, 2, 1), p(2, 2, 0), p(2, 0, 0)]
    floor = [p(1, 1, 1), p(2, 1, 1), p(2, 2, 1), p(1, 2, 1)]
    wall_x = [p(1, 1, 1), p(1, 2, 1), p(1, 2, 2), p(1, 1, 2)]
    wall_y = [p(1, 1, 1), p(2, 1, 1), p(2, 1, 2), p(1, 1, 2)]
    line = f'fill="none" stroke="#111" stroke-width="{stroke}" stroke-linejoin="round"'
    body = poly(wall_x, fill="#111")
    body += hatch_clip(floor, 18, 6, "f") + hatch_clip(wall_y, 18, 6, "w")
    body += f'<g {line}>{poly(top)}{poly(left)}{poly(right)}{poly(floor)}{poly(wall_x)}{poly(wall_y)}</g>'
    return svg("Isometric Workbench — Section", body)


def folded_w(h=1.0, tone="hatch"):
    """C: the letter W drawn along the two iso axes and extruded into a folded wall."""
    u = 60
    width = 4 * C30 * u
    height = 0.5 * u + h * u
    cx = 128 - width / 2
    cy = 128 + height / 2 - 0.5 * u  # ground point of the lowest folds
    pts = [(0, 0), (1, 0), (1, -1), (2, -1), (2, -2)]
    p = lambda x, y, z: (cx + (x - y) * C30 * u - (0 - 0), cy + (x + y) * 0.5 * u - z * u)
    # shift so the first point starts at the left edge: x - y = 0 at P0
    panels = []
    for i, ((x0, y0), (x1, y1)) in enumerate(zip(pts, pts[1:])):
        quad = [p(x0, y0, 0), p(x1, y1, 0), p(x1, y1, h), p(x0, y0, h)]
        panels.append((i, quad))
    body = ""
    for i, quad in panels:
        if i % 2 == 0:
            body += poly(quad, fill="#111")
        elif tone == "hatch":
            body += hatch_clip(quad, 16, 6, f"p{i}") + poly(quad, fill="none", stroke="#111",
                                                            stroke_width=8, stroke_linejoin="round")
        else:
            body += poly(quad, fill="none", stroke="#111", stroke_width=10, stroke_linejoin="round")
    return svg("Isometric Workbench — Folded W", body)


(OUT / "a-lift-v1.svg").write_text(lift())
(OUT / "a-lift-v2.svg").write_text(lift(gap=0.22, lid=0.3))
(OUT / "a-lift-v3.svg").write_text(lift(gap=0.38, seam=0.0))
(OUT / "a-lift-v4.svg").write_text(lift(gap=0.38, seam=0.04))
(OUT / "b-section-v1.svg").write_text(section())
(OUT / "b-section-v2.svg").write_text(section_v2())
(OUT / "c-folded-w-v1.svg").write_text(folded_w(1.6))
(OUT / "c-folded-w-v2.svg").write_text(folded_w(1.0, tone="outline"))
for old in OUT.glob("c-assembly-*.svg"):
    old.unlink()
print("wrote", sorted(p.name for p in OUT.glob("*.svg")))
