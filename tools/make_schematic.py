#!/usr/bin/env python3
"""
Module schematic for the ACZ702 camera pipeline.

Draws the PL top level (rtl/ov5640_top.v) as a block diagram: the three clock
domains as lanes, the video path left to right, the two CDC FIFOs on the lane
boundaries, the PS7 / DDR3 / AXI-Lite resources underneath, and the SCCB and
I2C bring-up engines described by their ports.

The scene is built as a display list so the same geometry is emitted twice:

    docs/camera_pipeline_schematic.svg   vector, for docs / printing
    docs/camera_pipeline_schematic.png   raster, 2x, for a quick look

    python tools/make_schematic.py
"""

import math
from pathlib import Path
from xml.sax.saxutils import escape as _esc

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent / "docs"
SVG_OUT = DOCS / "camera_pipeline_schematic.svg"
PNG_OUT = DOCS / "camera_pipeline_schematic.png"

W, H = 1820, 1152

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
def to_svg(g, path):
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">']
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


def to_png(g, path, out_scale=2, ss=3):
    S = out_scale * ss
    img = Image.new("RGB", (int(W * S), int(H * S)), PAPER)
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
    img = img.resize((int(W * out_scale), int(H * out_scale)), Image.LANCZOS)
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


# ================================================================== the scene
def scene(g):
    g.rect(0, 0, W, H, fill=PAPER)

    # ---------------------------------------------------------------- header
    g.line(36, 112, W - 36, 112, "#d9d4c7", sw=1.2)
    g.text(44, 56, "Camera pipeline — module schematic", size=29, weight="600")
    g.text(44, 82, "Zynq-7020 · ACZ702 · top level rtl/ov5640_top.v", size=12.5, fill=MUTED)
    g.text(44, 100, "OV5640 DVP → 4-stage slot → DDR3 double buffer → 800×480 TFT @ 60 Hz",
           size=12.5, fill=MUTED, family=MONO)

    lx, ly = 1092, 40
    for key, label in (("cam", "camera_pclk 42 MHz"), ("axi", "clk50 50 MHz (AXI)"),
                       ("pix", "clk_pix 33.33 MHz"), ("ps", "PS / board")):
        f, e, hd, _st, _n = DOM[key]
        g.rect(lx, ly - 11, 15, 15, fill=hd, stroke=e, r=3, sw=1.2)
        g.text(lx + 22, ly + 1, label, size=10, fill=MUTED, family=MONO)
        lx += 22 + text_width(label, 10, MONO) + 22

    lx = 1092
    for color, dash, sw, label in ((DATA_C, None, 2.6, "video word"),
                                   (AXI_C, None, 3.2, "AXI4"),
                                   (CTRL_C, "7 4", 2.2, "ctrl / status"),
                                   (REL_C, "5 3", 1.8, "reload handshake"),
                                   (CLK_C, "2 3", 1.6, "clock")):
        if dash:
            for seg in dash_segments([(lx, 73), (lx + 26, 73)], dash):
                g.poly(seg, stroke=color, sw=sw)
        else:
            g.line(lx, 73, lx + 26, 73, color, sw=sw)
        g.text(lx + 32, 76, label, size=9.6, fill=MUTED)
        lx += 32 + text_width(label, 9.6, SANS) + 20

    # ---------------------------------------------------------------- lanes
    lane(g, 36, 122, 640, 670, "cam", "camera_pclk", "42 MHz · OV5640 DVP · pin M17 → BUFG")
    lane(g, 668, 122, 1200, 670, "axi", "clk50", "50 MHz · PS FCLK0 · AXI4 master + AXI-Lite")
    lane(g, 1228, 122, 1784, 670, "pix", "clk_pix", "33.333 MHz · MMCM · 1056×526 @ 60 Hz")

    # bottom band background, early so no wire is painted over by it
    g.rect(36, 722, W - 72, 362, fill="#fbfaf6", stroke="#ddd8ca", r=14, sw=1.2)

    # ---------------------------------------------------------------- capture
    module(g, 56, 300, 116, 156, "OV5640",
           ("CY-sensor · DVP", "RGB565 · 800 × 480", "~30 fps", "PCLK ~42 MHz",
            "XVCLK 24 MHz", "SCCB 400 kHz", "8-bit data"),
           dom="ext", name_size=13, sub_size=8.6)

    module(g, 188, 300, 108, 156, "ov5640_capture",
           ("byte pair → RGB565", "clip 800 × 480", "4 px → 64-bit word",
            "align @ EOL, SOF", "tag bit 64", "HREF / VSYNC", "200 × 480 words"),
           dom="cam", name_size=10.4, sub_size=8.0)

    RAIL = 316
    g.line(RAIL, 209, RAIL, 601, DATA_C, sw=2.4)
    wire(g, [(296, 396), (RAIL, 396)], DATA_C, sw=2.4)
    wire(g, [(RAIL, 209), (336, 209)], DATA_C, sw=1.6)

    # stage slot panel sits behind its modules
    g.rect(326, 246, 268, 394, fill="#fefaf2", stroke="#e8d3a8", r=12, sw=1.2, dash="7 5")
    g.text(330, 654, "stage slot — 4 parallel stages, one selected",
           size=9.2, fill="#8a5a05")

    # what the eight-clock word period buys a camera-side stage
    g.rect(56, 582, 250, 74, fill="#fffaf0", stroke="#eddcc0", r=8, sw=1)
    g.text(68, 604, "budget: one word every 8 cam_pclk", size=8.4, fill="#8a5a05",
           weight="600", family=MONO)
    g.text(68, 620, "eight clocks of slack per word, so a", size=8.4, fill=MUTED)
    g.text(68, 634, "3×3 window shares one datapath", size=8.4, fill=MUTED)
    g.text(68, 648, "across the four pixels", size=8.4, fill=MUTED)

    module(g, 336, 180, 130, 58, "img_geom", ("eol · wx · wy", "on the delayed stream"),
           dom="cam", name_size=11.4, sub_size=8.5, pad=8)
    wire(g, [(401, 238), (401, 252)], DATA_C, sw=1.5, dash="4 3")

    stage_defs = [("stage_lut", ("identity · gamma", "threshold · false", "colour · invert")),
                  ("stage_win3x3", ("box · Sobel · median", "erode · dilate", "sharpen")),
                  ("stage_hist", ("pass + histogram", "equalise", "auto-exposure")),
                  ("stage_seg", ("4 chroma boxes", "paint or pass", "bounding boxes"))]
    SY, SH = [262, 356, 450, 544], 78
    for (nm, subs), y in zip(stage_defs, SY):
        module(g, 336, y, 130, SH, nm, subs, dom="cam", name_size=10.8, sub_size=8.2, pad=8)
        wire(g, [(RAIL, y + SH / 2), (336, y + SH / 2)], DATA_C, sw=2.4)

    module(g, 486, 262, 98, 360, "stage_mux", ("sel = ctrl[4:2]",), dom="cam",
           name_size=11.2, sub_size=8.4, pad=9)
    # 4 -> 1 badge and the guarantees the mux provides
    g.rect(506, 420, 58, 26, fill="#fdf1d6", stroke="#dfc07a", r=13, sw=1)
    g.text(535, 438, "4 → 1", size=10.4, weight="600", fill="#8a5a05",
           anchor="middle", family=MONO)
    for i, s in enumerate(("frame-stable", "param / knob", "tear-free", "hand-over",
                           "warm-up gating")):
        g.text(496, 470 + i * 12.4, s, size=8.0, fill=MUTED)
    g.text(496, 546, "stat → PS", size=8.0, fill=CTRL_C, family=MONO)
    for y in SY:
        wire(g, [(466, y + SH / 2), (486, y + SH / 2)], DATA_C, sw=1.9,
             head_size=7, half=3.4)

    wire(g, [(584, 356), (606, 356)], DATA_C, sw=2.4)

    module(g, 606, 316, 100, 88, "afifo",
           ("65 bit", "show-ahead", "Gray ptr", "42 → 50 MHz"),
           dom="axi", name_size=11.2, sub_size=8.3, pad=8, fill="#ffffff")
    chip(g, 656, 424, "CDC 1", "#ffffff", fg="#1f4f86", size=8.6, stroke="#adc6e4", sw=1)

    # ---------------------------------------------------------------- DDR engine
    module(g, 744, 262, 256, 280, "fb_ddr", ("AXI4 master · 64-bit · 128 B bursts",),
           dom="axi", name_size=13.2, sub_size=8.9, pad=10)
    g.rect(756, 320, 124, 70, fill="#f7fafd", stroke="#adc6e4", r=6, sw=1)
    g.text(766, 340, "write engine", size=9.4, weight="600", fill="#1f4f86", family=MONO)
    for i, s in enumerate(("A → B on frame tag", "96 000 words/frame", "drops when frozen")):
        g.text(766, 355 + i * 13, s, size=7.8, fill=MUTED)
    g.rect(756, 440, 124, 70, fill="#f7fafd", stroke="#adc6e4", r=6, sw=1)
    g.text(766, 460, "read engine", size=9.4, weight="600", fill="#1f4f86", family=MONO)
    for i, s in enumerate(("retarget in vblank", "drain prefetch", "refill disp fifo")):
        g.text(766, 475 + i * 13, s, size=7.8, fill=MUTED)

    for i, s in enumerate(("two buffers A, B", "no tearing:", "switch only in", "vertical blank")):
        g.text(892, 338 + i * 14, s, size=8.4, fill=MUTED, family=MONO)

    # the point of the double buffer, in three lines, right of the ctrl tap
    g.text(876, 572, "double buffer:", size=8.2, fill="#1f4f86", weight="600")
    for i, s in enumerate(("camera fills A", "panel reads B", "swap @ vblank")):
        g.text(876, 588 + i * 14, s, size=8.2, fill=MUTED, family=MONO)

    wire(g, [(706, 356), (744, 356)], DATA_C, sw=2.6)

    # AXI master: leaves the engine, runs along the bottom of the clk50 lane
    wire(g, [(950, 542), (950, 656), (1210, 656), (1210, 744)], AXI_C, sw=3.2,
         head_size=11, half=5.4)
    g.text(958, 648, "AXI4 · AW / W / B / AR / R · 64-bit @ 50 MHz", size=8.6,
           fill=AXI_C, family=MONO)

    wire(g, [(1000, 476), (1150, 476)], DATA_C, sw=2.6)
    g.text(1075, 470, "disp_data", size=8.2, fill=MUTED, family=MONO, anchor="middle")

    # reload handshake, drawn above the display FIFO so it does not cross it
    wire(g, [(1320, 452), (1300, 452), (1300, 420), (1000, 420)], REL_C, sw=1.7,
         dash="5 3", both=True, head_size=7, half=3.2)
    chip(g, 1078, 420, "rel_req / rel_ack", "#ffffff", fg=REL_C, size=8.0,
         stroke="#e2c4a4", sw=1)

    # ---------------------------------------------------------------- display
    module(g, 1150, 436, 100, 88, "afifo",
           ("64 bit", "show-ahead", "Gray ptr", "50 → 33.33 MHz"),
           dom="pix", name_size=11.2, sub_size=8.3, pad=8, fill="#ffffff")
    chip(g, 1200, 544, "CDC 2", "#ffffff", fg="#1d6344", size=8.6, stroke="#a2cdb5", sw=1)

    module(g, 1320, 300, 240, 200, "lcd_display",
           ("1056 × 526 @ 33.333 MHz", "= 60.0 Hz, HS/VS negative", "DE high, RGB565",
            "4-px word shifter", "underrun → black", "frame counter"),
           dom="pix", name_size=13, sub_size=9.0)
    g.text(1330, 424, "test pattern = ctrl[0]", size=8.4, fill=CTRL_C, family=MONO)
    g.text(1330, 438, "video_valid gates output", size=8.4, fill=FAINT, family=MONO)
    g.text(1330, 452, "reload in vertical blank", size=8.4, fill=REL_C, family=MONO)

    wire(g, [(1250, 476), (1320, 476)], DATA_C, sw=2.6)

    module(g, 1600, 300, 174, 120, "TFT panel",
           ('4.3" 800 × 480', "RGB565 + HS/VS/DE", "backlight ← PWM (R17)"),
           dom="ext", name_size=12.4, sub_size=8.9, pad=9)
    module(g, 1600, 466, 174, 120, "SiI9022A",
           ("HDMI transmitter", "same 16-bit RGB bus", "I²C set-up @ 1 s"),
           dom="ext", name_size=12.4, sub_size=8.9, pad=9)

    wire(g, [(1560, 344), (1600, 344)], DATA_C, sw=2.6)
    wire(g, [(1560, 488), (1600, 488)], DATA_C, sw=2.0, head_size=8, half=4)

    # ---------------------------------------------------------------- ctrl bus
    BUS_Y = 690
    g.line(360, BUS_Y, 1440, BUS_Y, CTRL_C, sw=2.2)
    g.text(352, 684, "ctrl[31:0] →", size=9.0, fill=CTRL_C, family=MONO,
           weight="600", anchor="end")
    g.text(1430, 684, "← status_cam · status_disp · status_ext", size=9.0, fill=CTRL_C,
           family=MONO, weight="600", anchor="end")

    for x, ybot in ((570, 622), (860, 542), (1440, 500)):
        wire(g, [(x, BUS_Y), (x, ybot)], CTRL_C, sw=1.9, dash="7 4",
             head_size=7.5, half=3.6)
        dot(g, x, BUS_Y, CTRL_C)

    g.text(552, 684, "sel ctrl[4:2] · knob ctrl[7:5]", size=8.0, fill=CTRL_C,
           family=MONO, anchor="end")
    g.text(850, 630, "freeze = ctrl[1]", size=8.0, fill=CTRL_C, family=MONO, anchor="end")
    g.text(1450, 522, "pattern = ctrl[0]", size=8.0, fill=CTRL_C, family=MONO)
    g.text(548, 708, "status_ext ← stage stat", size=8.0, fill=CTRL_C, family=MONO,
           anchor="end")

    # the AXI master crosses this bus without joining it: cut a clean overpass
    g.rect(1205, 685, 10, 10, fill=PAPER)
    g.line(1210, 683, 1210, 697, AXI_C, sw=3.2)

    # ---------------------------------------------------------------- bottom band
    g.text(52, 748, "PS7 + board resources", size=12.6, weight="600", fill="#4b3a86")
    g.text(262, 748, "— outside the video path; the PS supplies DDR3, clk50 and the ctrl / status words",
           size=9.6, fill=MUTED)

    module(g, 56, 766, 190, 120, "clk_gen",
           ("MMCM · VCO 1200 MHz", "CLKOUT0 /36 → clk_pix", "CLKOUT1 /50 → clk_cam",
            "locked gates all resets", "→ camera_xclk 24 MHz"),
           dom="axi", name_size=11.8, sub_size=8.3, pad=9)
    g.text(66, 876, "in: clk50", size=8.2, fill=FAINT, family=MONO)

    module(g, 276, 766, 190, 100, "backlight / LED",
           ("8-bit PWM @ 195 kHz", "duty = ctrl[15:8]", "lcd_bl → panel (R17)",
            "status LED: 1 Hz / 4 Hz"),
           dom="axi", name_size=11.4, sub_size=8.3, pad=9)
    wire(g, [(360, BUS_Y), (360, 766)], CTRL_C, sw=1.9, dash="7 4",
         head_size=7.5, half=3.6)
    dot(g, 360, BUS_Y, CTRL_C)

    g.rect(496, 766, 190, 100, fill="#f6f3ec", stroke="#ddd8ca", r=9, sw=1)
    g.text(508, 788, "BANDWIDTH", size=8.6, fill=MUTED, weight="600", ls=0.9)
    for i, s in enumerate(("write 23 MB/s", "read  46 MB/s", "HP0  400 MB/s")):
        g.text(508, 806 + i * 14, s, size=8.6, fill=MUTED, family=MONO)
    g.text(508, 854, "4 px / AXI beat", size=8.0, fill=FAINT, family=MONO)

    module(g, 276, 892, 190, 110, "ov5640_init",
           ("SCCB master · write only", "21 ms power-up wait", "252 register writes",
            "flip + mirror in sensor", "→ camera header"),
           dom="axi", name_size=11.2, sub_size=8.3, pad=9)

    module(g, 496, 892, 190, 110, "sii9022_init",
           ("I²C master · PL bus", "T10 / R14 · write-only", "42 register writes",
            "1 s after reset", "→ SiI9022A"),
           dom="axi", name_size=11.2, sub_size=8.3, pad=9)

    # ---------------------------------------------------------------- AXI-Lite
    g.rect(716, 766, 380, 302, fill="#ffffff", stroke="#bfb2dd", r=12, sw=1.3, dash="6 4")
    g.text(728, 788, "AXI4-Lite · clk50", size=10.4, weight="600", fill="#4b3a86",
           family=MONO)
    g.text(728, 802, "1 → 3 SmartConnect · three 32-bit words", size=8.2, fill=MUTED)

    module(g, 736, 812, 236, 74, "axi_gpio_ctrl",
           ("all outputs · ctrl[31:0]", "pattern · freeze · stage · BL"),
           dom="ps", name_size=10.6, sub_size=8.2, pad=8)
    module(g, 736, 898, 236, 74, "axi_gpio_status",
           ("ch1 status_cam · ch2 status_disp", "init · live · fps · frames · errs"),
           dom="ps", name_size=10.6, sub_size=8.2, pad=8)
    module(g, 736, 984, 236, 74, "axi_gpio_ext",
           ("32-bit · status_ext", "the selected stage's statistic"),
           dom="ps", name_size=10.6, sub_size=8.2, pad=8)

    g.rect(1000, 852, 80, 190, fill="#f1edf9", stroke="#bfb2dd", r=8, sw=1.2)
    g.text(1040, 928, "smc", size=9.4, fill="#4b3a86", anchor="middle", family=MONO,
           weight="600")
    g.text(1040, 942, "lite", size=9.4, fill="#4b3a86", anchor="middle", family=MONO,
           weight="600")
    g.text(1040, 964, "1→3", size=8.6, fill=MUTED, anchor="middle", family=MONO)
    for y in (849, 935, 1021):
        wire(g, [(1000, y), (972, y)], AXI_C, sw=2.0, head_size=7.5, half=3.6)

    wire(g, [(950, BUS_Y), (950, 812)], CTRL_C, sw=1.9, dash="7 4", head_size=7.5, half=3.6)
    dot(g, 950, BUS_Y, CTRL_C)
    g.text(958, 704, "ctrl out · status in", size=7.8, fill=CTRL_C, family=MONO)

    # ---------------------------------------------------------------- PS7
    module(g, 1126, 744, 350, 270, "Zynq-7020 PS (PS7)", (), dom="ps",
           name_size=13.2, pad=11)
    g.text(1137, 792, "ARM Cortex-A9 ×2 @ 667 MHz", size=9.2, fill=MUTED)
    g.text(1137, 807, "DDR3 controller · 32-bit @ 533 MHz", size=9.2, fill=MUTED,
           family=MONO)
    g.text(1137, 822, "UART1 · MIO48/49 · CH343P", size=9.2, fill=MUTED)
    g.line(1137, 834, 1465, 834, "#bfb2dd", sw=1)
    for i, (s, c, fam) in enumerate((
            ("ps7_init: DDR3, clocks, UART", MUTED, SANS),
            ("no pixel data crosses the PS", MUTED, SANS),
            ("M_AXI_GP0 → AXI4-Lite", AXI_C, MONO),
            ("S_AXI_HP0 ← PL AXI4 master", AXI_C, MONO),
            ("DDR3 ← frame buffers A / B", MUTED, MONO))):
        g.text(1137, 852 + i * 15, s, size=8.6, fill=c, family=fam)

    # the two status words, bit for bit, so the PS interface is not hand-waving
    g.line(1137, 926, 1465, 926, "#bfb2dd", sw=1)
    g.text(1137, 944, "status_cam  = {frames, fps, 6'd0, live, init}", size=8.2,
           fill=MUTED, family=MONO)
    g.text(1137, 958, "status_disp = {axi_errs, underruns, frames}", size=8.2,
           fill=MUTED, family=MONO)
    g.text(1137, 972, "status_ext  = stage stat (32 bit)", size=8.2, fill=MUTED,
           family=MONO)

    wire(g, [(1126, 940), (1080, 940)], AXI_C, sw=2.2, head_size=7.5, half=3.6)
    g.text(1103, 932, "M_AXI_GP0", size=7.8, fill=AXI_C, family=MONO, anchor="middle")

    # ---------------------------------------------------------------- DDR3
    module(g, 1506, 744, 268, 150, "DDR3 device", ("1 GB on the PS DDR3 port",),
           dom="ext", name_size=12.4, sub_size=8.8, pad=10)
    for i, s in enumerate(("frame buffer A 0x0180_0000", "frame buffer B 0x018B_B800",
                           "768 000 B each · 96 000 words")):
        g.text(1516, 800 + i * 14, s, size=8.4, fill=MUTED, family=MONO)
    g.text(1516, 848, "written 30 ×/s · read 60 ×/s", size=8.2, fill=FAINT, family=MONO)
    wire(g, [(1476, 810), (1506, 810)], AXI_C, sw=3.0, both=True, head_size=9, half=4.6)

    # ---------------------------------------------------------------- console
    module(g, 1506, 924, 268, 100, "CH343P USB-UART", ("console · COM3 · 115200 8N1",),
           dom="ext", name_size=11.8, sub_size=8.8, pad=10)
    g.text(1516, 978, "1 line / s · single-key cmds", size=8.4, fill=MUTED, family=MONO)
    g.text(1516, 992, "p f s k + - b i h", size=8.4, fill=MUTED, family=MONO)
    wire(g, [(1476, 968), (1506, 968)], AXI_C, sw=2.0, head_size=7.5, half=3.6)

    g.text(1516, 1048, "no external PL clock pin:", size=8.4, fill=FAINT, family=MONO)
    g.text(1516, 1062, "the PL runs from PS FCLK0 only", size=8.4, fill=FAINT,
           family=MONO)

    # ---------------------------------------------------------------- footer
    g.line(36, 1112, W - 36, 1112, "#d9d4c7", sw=1)
    g.text(36, 1132, "ACZ702 · xc7z020clg400-1 · Vivado 2023.2 · drawn from the module tree "
                     "of camera_pipeline/rtl/ov5640_top.v", size=8.6, fill=FAINT,
           family=MONO)
    g.text(W - 36, 1132, "video: 800 × 480 RGB565 · 4 px / 64-bit word · 200 × 480 words per frame",
           size=8.6, fill=FAINT, family=MONO, anchor="end")


def main():
    g = Canvas()
    scene(g)
    DOCS.mkdir(parents=True, exist_ok=True)
    to_svg(g, SVG_OUT)
    to_png(g, PNG_OUT)
    print(f"wrote {SVG_OUT.name}: {SVG_OUT.stat().st_size} bytes")
    print(f"wrote {PNG_OUT.name}: {PNG_OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
