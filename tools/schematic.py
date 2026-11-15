#!/usr/bin/env python3
"""
Drawing primitives shared by the schematic sheets.

A Canvas collects drawing operations; to_svg and to_png render the same list
through two backends, so the vector and the raster can never drift.  The canvas
size is passed to the backends, so several sheets of different sizes can use one
module.
"""

import math
from pathlib import Path
from xml.sax.saxutils import escape as _esc

from PIL import Image, ImageDraw, ImageFont

INK     = "#1b2430"
MUTED   = "#5d6a7a"
FAINT   = "#8b96a5"
PAPER   = "#fcfbf7"

SANS = "sans"
MONO = "mono"

# clock-domain palette:  lane fill, lane edge, header fill, module stroke, name
DOM = {
    "cam": ("#fdf4e2", "#e5c88c", "#f8e9c9", "#c08a2b", "#8a5a05"),
    "axi": ("#eaf1fb", "#adc6e4", "#dbe7f8", "#4a7fb5", "#1f4f86"),
    "pix": ("#e9f5ee", "#a2cdb5", "#d8ecdf", "#3d8a63", "#1d6344"),
    "ps":  ("#f1edf9", "#bfb2dd", "#e5ddf4", "#6b58a8", "#4b3a86"),
    "ext": ("#f4f2ec", "#cfc9bb", "#eae6db", "#8d8475", "#4d463c"),
}

DATA_C = "#1b2430"   # 64-bit video word stream
AXI_C  = "#2f6fb0"   # AXI4 / AXI4-Lite
CTRL_C = "#7b4fa8"   # control + status bus
CLK_C  = "#2f8a5c"   # clocks
REL_C  = "#b4682a"   # reload handshake


# ------------------------------------------------------------------ display list
class Canvas:
    def __init__(self):
        self.ops = []

    def rect(self, x, y, w, h, fill=None, stroke=None, r=0, sw=1, dash=None):
        self.ops.append(("rect", dict(x=x, y=y, w=w, h=h, fill=fill, stroke=stroke,
                                      r=r, sw=sw, dash=dash)))

    def line(self, x1, y1, x2, y2, stroke, sw=1, dash=None):
        self.ops.append(("poly", dict(pts=[(x1, y1), (x2, y2)], stroke=stroke,
                                      sw=sw, dash=dash, closed=False, fill=None)))

    def poly(self, pts, stroke, sw=1, dash=None, fill=None, closed=False):
        self.ops.append(("poly", dict(pts=list(pts), stroke=stroke, sw=sw, dash=dash,
                                      closed=closed, fill=fill)))

    def circle(self, x, y, r, fill):
        self.ops.append(("circle", dict(x=x, y=y, r=r, fill=fill)))

    def text(self, x, y, s, size=10, fill=INK, anchor="start", weight="400",
             family=SANS, ls=0.0):
        self.ops.append(("text", dict(x=x, y=y, s=str(s), size=size, fill=fill,
                                      anchor=anchor, weight=weight, family=family,
                                      ls=ls)))


def text_width(s, size, family, ls=0.0):
    adv = 0.60 if family == MONO else 0.53
    return len(s) * (size * adv + ls)


# ------------------------------------------------------------------ svg backend
def to_svg(g, path, w, h):
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
           f'viewBox="0 0 {w} {h}">']
    fam = {SANS: "Segoe UI, Inter, Helvetica, Arial, sans-serif",
           MONO: "Cascadia Mono, Consolas, 'DejaVu Sans Mono', monospace"}
    for kind, a in g.ops:
        if kind == "rect":
            d = f' stroke-dasharray="{a["dash"]}"' if a["dash"] else ""
            out.append(
                f'<rect x="{a["x"]:.1f}" y="{a["y"]:.1f}" width="{a["w"]:.1f}" '
                f'height="{a["h"]:.1f}" rx="{a["r"]}" fill="{a["fill"] or "none"}" '
                f'stroke="{a["stroke"] or "none"}" stroke-width="{a["sw"]}"{d}/>')
        elif kind == "poly":
            pts = a["pts"]
            d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
            if a["closed"]:
                d += " Z"
            ds = f' stroke-dasharray="{a["dash"]}"' if a["dash"] else ""
            out.append(
                f'<path d="{d}" fill="{a["fill"] or "none"}" '
                f'stroke="{a["stroke"] or "none"}" stroke-width="{a["sw"]}" '
                f'stroke-linejoin="round" stroke-linecap="round"{ds}/>')
        elif kind == "circle":
            out.append(f'<circle cx="{a["x"]:.1f}" cy="{a["y"]:.1f}" r="{a["r"]}" '
                       f'fill="{a["fill"]}"/>')
        elif kind == "text":
            s = _esc(a["s"])
            wt = ' font-weight="600"' if a["weight"] in ("600", "700") else ""
            an = f' text-anchor="{a["anchor"]}"' if a["anchor"] != "start" else ""
            lsp = f' letter-spacing="{a["ls"]}"' if a["ls"] else ""
            out.append(
                f'<text x="{a["x"]:.1f}" y="{a["y"]:.1f}" '
                f'font-family="{fam[a["family"]]}" font-size="{a["size"]}" '
                f'fill="{a["fill"]}"{an}{wt}{lsp}>{s}</text>')
    out.append("</svg>")
    path.write_text("".join(out), encoding="utf-8")
    return path


# ------------------------------------------------------------------ png backend
FONTS = {
    (SANS, "400"): ["C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"],
    (SANS, "600"): ["C:/Windows/Fonts/seguisb.ttf", "C:/Windows/Fonts/segoeuib.ttf"],
    (MONO, "400"): ["C:/Windows/Fonts/consola.ttf"],
    (MONO, "600"): ["C:/Windows/Fonts/consolab.ttf"],
}


def load_font(family, weight, px):
    key = (family, "600" if weight in ("600", "700") else "400")
    for cand in FONTS[key]:
        if Path(cand).exists():
            return ImageFont.truetype(cand, px)


def dash_segments(pts, pattern, scale=1.0):
    """Split a polyline into on/off runs; returns a list of point lists."""
    if not pattern:
        return [pts]
    pat = [float(p) * scale for p in pattern.replace(",", " ").split()]
    segs, cur, on, idx, left = [], [pts[0]], True, 0, pat[0]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        seg_len = math.hypot(x1 - x0, y1 - y0)
        if seg_len == 0:
            continue
        ux, uy = (x1 - x0) / seg_len, (y1 - y0) / seg_len
        pos = 0.0
        while pos < seg_len:
            step = min(left, seg_len - pos)
            nx, ny = x0 + ux * (pos + step), y0 + uy * (pos + step)
            if on:
                cur.append((nx, ny))
            pos += step
            left -= step
            if left <= 1e-9:
                if on and len(cur) > 1:
                    segs.append(cur)
                cur = [(nx, ny)]
                idx = (idx + 1) % len(pat)
                left = pat[idx]
                on = not on
    if on and len(cur) > 1:
        segs.append(cur)
    return segs


def rrect_pts(x, y, w, h, r, steps=8):
    r = min(r, w / 2, h / 2)
    if r <= 0:
        return [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]
    pts = []
    corners = [((x + w - r, y + r), -90), ((x + w - r, y + h - r), 0),
               ((x + r, y + h - r), 90), ((x + r, y + r), 180)]
    for (cx, cy), a0 in corners:
        for i in range(steps + 1):
            a = math.radians(a0 + 90.0 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    pts.append(pts[0])
    return pts


def to_png(g, path, w, h, out_scale=2, ss=3):
    S = out_scale * ss
    img = Image.new("RGB", (int(w * S), int(h * S)), PAPER)
    d = ImageDraw.Draw(img)
    fcache = {}

    def font(family, weight, size):
        k = (family, weight, round(size * S, 2))
        if k not in fcache:
            fcache[k] = load_font(family, weight, max(1, int(round(size * S))))
        return fcache[k]

    for kind, a in g.ops:
        if kind == "rect":
            box = [a["x"] * S, a["y"] * S, (a["x"] + a["w"]) * S, (a["y"] + a["h"]) * S]
            r = a["r"] * S
            if a["dash"]:
                pts = rrect_pts(*box, r, steps=10)
                for seg in dash_segments(pts, a["dash"], S):
                    d.line([(p[0], p[1]) for p in seg], fill=a["stroke"],
                           width=max(1, int(round(a["sw"] * S))), joint="curve")
            else:
                if a["fill"] and a["stroke"]:
                    d.rounded_rectangle(box, radius=r, fill=a["fill"],
                                        outline=a["stroke"], width=max(1, round(a["sw"] * S)))
                elif a["fill"]:
                    d.rounded_rectangle(box, radius=r, fill=a["fill"])
                elif a["stroke"]:
                    d.rounded_rectangle(box, radius=r, outline=a["stroke"],
                                        width=max(1, round(a["sw"] * S)))
        elif kind == "poly":
            pts = [(x * S, y * S) for x, y in a["pts"]]
            if a["fill"]:
                d.polygon(pts, fill=a["fill"])
            if a["stroke"]:
                for seg in dash_segments(pts, a["dash"], S):
                    d.line(seg, fill=a["stroke"],
                           width=max(1, int(round(a["sw"] * S))), joint="curve")
        elif kind == "circle":
            cx, cy, r = a["x"] * S, a["y"] * S, a["r"] * S
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=a["fill"])
        elif kind == "text":
            f = font(a["family"], a["weight"], a["size"])
            anchor = {"start": "ls", "middle": "ms", "end": "rs"}[a["anchor"]]
            if a["ls"]:
                x = a["x"] * S
                for ch in a["s"]:
                    d.text((x, a["y"] * S), ch, font=f, fill=a["fill"], anchor="ls")
                    x += d.textlength(ch, font=f) + a["ls"] * S
            else:
                d.text((a["x"] * S, a["y"] * S), a["s"], font=f, fill=a["fill"],
                       anchor=anchor)
    img = img.resize((int(w * out_scale), int(h * out_scale)), Image.LANCZOS)
    img.save(path, optimize=True)
    return path


# ------------------------------------------------------------------ primitives
def head(g, p0, p1, color, size=9.0, half=4.4):
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy) or 1.0
    ux, uy = dx / L, dy / L
    px, py = -uy, ux
    bx, by = x1 - ux * size, y1 - uy * size
    g.poly([(x1, y1), (bx + px * half, by + py * half),
            (bx - px * half, by - py * half)], stroke=None, fill=color, closed=True)


def wire(g, pts, color=DATA_C, sw=2.4, dash=None, both=False, head_size=9.0, half=4.4):
    if dash:
        for seg in dash_segments(pts, dash):
            g.poly(seg, stroke=color, sw=sw)
    else:
        g.poly(pts, stroke=color, sw=sw)
    head(g, pts[-2], pts[-1], color, head_size, half)
    if both:
        head(g, pts[1], pts[0], color, head_size, half)


def dot(g, x, y, color, r=3.2):
    g.circle(x, y, r, color)


def chip(g, x, y, s, bg, fg=INK, size=9.0, pad_x=4.5, pad_y=3.2, family=MONO,
         stroke=None, sw=0):
    w = text_width(s, size, family) + 2 * pad_x
    h = size + 2 * pad_y
    g.rect(x - w / 2, y - h / 2, w, h, fill=bg, stroke=stroke, r=3, sw=sw)
    g.text(x, y + size * 0.34, s, size=size, fill=fg, anchor="middle", family=family)


def module(g, x, y, w, h, name, subs=(), dom="cam", name_size=12.4, sub_size=9.2,
           pad=10, fill="#fffdf9", dashed=None):
    _f, _e, _hd, stroke, name_c = DOM[dom]
    g.rect(x, y, w, h, fill=fill, stroke=stroke, r=9, sw=1.7, dash=dashed)
    g.text(x + pad, y + pad + name_size * 0.80, name, size=name_size,
           weight="600", family=MONO, fill=name_c)
    yy = y + pad + name_size * 0.80 + 6
    g.line(x + pad, yy, x + w - pad, yy, stroke, sw=1)
    for i, s in enumerate(subs):
        g.text(x + pad, yy + 13 + i * 11.8, s, size=sub_size, fill=MUTED)


def lane(g, x0, y0, x1, y1, dom, name, sub):
    f, e, hd, _st, _n = DOM[dom]
    g.rect(x0, y0, x1 - x0, y1 - y0, fill=f, r=16)
    g.rect(x0, y0, x1 - x0, 62, fill=hd, r=16)
    g.rect(x0, y0 + 30, x1 - x0, 32, fill=hd)
    g.rect(x0, y0, x1 - x0, y1 - y0, stroke=e, r=16, sw=1.4)
    g.line(x0, y0 + 44, x1, y0 + 44, e, sw=1.2)
    g.text(x0 + 16, y0 + 28, name, size=13.4, weight="600", family=MONO, fill=DOM[dom][4])
    g.text(x0 + 16 + text_width(name, 13.4, MONO) + 12, y0 + 28, sub,
           size=10.2, fill=MUTED)


