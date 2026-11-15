#!/usr/bin/env python3
"""
Port-level sheet for the ACZ702 camera pipeline.

The companion of docs/camera_pipeline_schematic.png: same pipeline, but every
block is drawn with the ports it actually has in the RTL - name, width and
direction - and adjacent blocks are wired port to port.

Ports whose partner is not adjacent carry the net name instead of a wire
("s_eol <- cam_weol"); the same name at the other end is the same net.  Ports
the top level leaves unconnected say "open" - that is deliberate, it is what the
instantiation does.

    python tools/make_port_sheet.py
    -> docs/camera_pipeline_ports.svg
    -> docs/camera_pipeline_ports.png
"""

from pathlib import Path

from schematic import *

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent / "docs"
SVG_OUT = DOCS / "camera_pipeline_ports.svg"
PNG_OUT = DOCS / "camera_pipeline_ports.png"

W, H = 2500, 1190

TITLE_H = 32
DOM_H = 16
ROW_H = 16.5
PAD_B = 10
STUB = 9
ROW_Y = 250          # top of every block in the datapath row

NET_C = "#6b7a8d"    # net name written inside a block
OPEN_C = "#b0553f"   # a port the top level leaves open


# ------------------------------------------------------------------ port block
def pblock(g, x, y, w, name, sub, dom, left=(), right=()):
    """Box with port rows; returns (height, {(side, name): (x_edge, y)}).

    Each port is (name, width, dir, net): dir is "in"/"out"/"io", net is None
    when the port is wired to a neighbour, else the net name to annotate.
    """
    _f, _e, _hd, stroke, name_c = DOM[dom]
    rows = max(len(left), len(right))
    h = TITLE_H + DOM_H + rows * ROW_H + PAD_B
    g.rect(x, y, w, h, fill="#fffdf9", stroke=stroke, r=8, sw=1.6)
    g.text(x + 9, y + 20, name, size=11.2, weight="600", family=MONO, fill=name_c)
    g.text(x + 9, y + 32, sub, size=7.6, fill=MUTED, family=MONO)
    g.line(x + 9, y + 37, x + w - 9, y + 37, stroke, sw=1)

    pos = {}
    for side, ports in (("L", left), ("R", right)):
        for i, (pn, wid, d, net) in enumerate(ports):
            py = y + TITLE_H + DOM_H + 15 + i * ROW_H
            edge = x if side == "L" else x + w
            pos[(side, pn)] = (edge, py)

            if side == "L":
                g.line(edge, py, edge - STUB, py, stroke, sw=1.4)
                if d == "in":
                    head(g, (edge - STUB, py), (edge, py), stroke, 6, 2.8)
                elif d == "out":
                    head(g, (edge, py), (edge - STUB, py), stroke, 6, 2.8)
                else:
                    g.poly([(edge - 4, py - 3.4), (edge - 0.6, py),
                            (edge - 4, py + 3.4), (edge - 7.4, py)],
                           stroke=None, fill=stroke, closed=True)
            else:
                g.line(edge, py, edge + STUB, py, stroke, sw=1.4)
                if d == "in":
                    head(g, (edge + STUB, py), (edge, py), stroke, 6, 2.8)
                elif d == "out":
                    head(g, (edge, py), (edge + STUB, py), stroke, 6, 2.8)
                else:
                    g.poly([(edge + 4, py - 3.4), (edge + 0.6, py),
                            (edge + 4, py + 3.4), (edge + 7.4, py)],
                           stroke=None, fill=stroke, closed=True)

            arrow = {"in": "←", "out": "→", "io": "↔"}[d]
            col = OPEN_C if net == "open" else NET_C
            nw = text_width(pn, 8.4, MONO)
            ww = text_width(wid, 7.4, MONO) if wid else 0
            ntw = text_width(f"{arrow} {net}", 7.6, MONO) if net else 0

            if side == "L":
                tx = x + 10
                g.text(tx, py + 3, pn, size=8.4, fill=INK, family=MONO)
                tx += nw
                if wid:
                    g.text(tx + 2, py + 3, wid, size=7.4, fill=FAINT, family=MONO)
                    tx += 2 + ww
                if net:
                    g.text(tx + 5, py + 3, f"{arrow} {net}", size=7.6, fill=col,
                           family=MONO)
            else:
                # right-aligned as a whole, so it still reads name-width-net
                tx = x + w - 10
                if net:
                    g.text(tx, py + 3, f"{arrow} {net}", size=7.6, fill=col,
                           family=MONO, anchor="end")
                    tx -= ntw + 5
                if wid:
                    g.text(tx, py + 3, wid, size=7.4, fill=FAINT, family=MONO,
                           anchor="end")
                    tx -= ww + 2
                g.text(tx, py + 3, pn, size=8.4, fill=INK, family=MONO, anchor="end")

    return h, pos


def link(g, a, pa, b, pb, color=DATA_C, sw=1.9):
    """Connect port pa of block a to port pb of block b, orthogonal routing."""
    (x1, y1) = a["pos"][pa]
    (x2, y2) = b["pos"][pb]
    if abs(y1 - y2) < 0.6:
        g.line(x1, y1, x2, y2, color, sw=sw)
    else:
        mx = (x1 + x2) / 2
        g.poly([(x1, y1), (mx, y1), (mx, y2), (x2, y2)], stroke=color, sw=sw)


# ================================================================== the scene
def scene(g):
    g.rect(0, 0, W, H, fill=PAPER)

    g.line(36, 104, W - 36, 104, "#d9d4c7", sw=1.2)
    g.text(44, 52, "Camera pipeline — port level", size=28, weight="600")
    g.text(44, 76, "Zynq-7020 · ACZ702 · every block as rtl/ov5640_top.v instantiates it",
           size=12, fill=MUTED)
    g.text(770, 76, "port rows: name [width]  ·  ← from a net, → drives a net",
           size=11, fill=FAINT, family=MONO)

    # legend
    gx, gy = 1720, 34
    g.text(gx, gy, "port direction", size=8.6, fill=MUTED, weight="600")
    head(g, (gx, gy + 16), (gx + 13, gy + 16), INK, 6, 2.8)
    g.text(gx + 19, gy + 19, "into the block", size=9, fill=MUTED)
    head(g, (gx + 112, gy + 16), (gx + 99, gy + 16), INK, 6, 2.8)
    g.text(gx + 120, gy + 19, "out of it", size=9, fill=MUTED)
    g.text(gx, gy + 38, "← net", size=8.2, fill=NET_C, family=MONO, weight="600")
    g.text(gx + 44, gy + 38, "joined by name, not drawn", size=9, fill=MUTED)
    g.text(gx + 210, gy + 38, "← open", size=8.2, fill=OPEN_C, family=MONO,
           weight="600")
    g.text(gx + 254, gy + 38, "nothing connected", size=9, fill=MUTED)

    # ---------------------------------------------------------------- lanes
    lane(g, 36, 114, 1130, 730, "cam", "camera_pclk",
         "42 MHz · clk cam_pclk · rst_n cam_rst_n")
    lane(g, 1160, 114, 1940, 730, "axi", "clk50",
         "50 MHz · PS FCLK0 · clk50 · sys_rst_n")
    lane(g, 1970, 114, 2464, 730, "pix", "clk_pix",
         "33.333 MHz · MMCM · clk_pix · pix_rst_n")

    B = {}
    Y = ROW_Y

    # ---------------------------------------------------------------- camera
    h, p = pblock(g, 60, Y, 190, "OV5640", "camera header", "ext",
                  left=[("XVCLK", "", "in", "clk_cam"),
                        ("SCL", "", "in", "camera_sclk"),
                        ("SDA", "", "io", "camera_sdat")],
                  right=[("HREF", "", "out", None),
                         ("VSYNC", "", "out", None),
                         ("D", "[7:0]", "out", None),
                         ("PCLK", "", "out", "BUFG → cam_pclk")])
    B["sens"] = dict(pos=p, x=60, y=Y, w=190, h=h)

    h, p = pblock(g, 285, Y, 230, "u_capture", "ov5640_capture", "cam",
                  left=[("href", "", "in", None),
                        ("vsync", "", "in", None),
                        ("data", "[7:0]", "in", None)],
                  right=[("word", "[63:0]", "out", "cam_word"),
                         ("word_valid", "", "out", "cam_word_valid"),
                         ("word_first", "", "out", "cam_word_first")])
    B["cap"] = dict(pos=p, x=285, y=Y, w=230, h=h)

    h, p = pblock(g, 570, 570, 250, "u_geom", "img_geom", "cam",
                  left=[("sof", "", "in", "word_first"),
                        ("valid", "", "in", "word_valid")],
                  right=[("eol", "", "out", "cam_weol"),
                         ("wx", "[8:0]", "out", "open"),
                         ("wy", "[8:0]", "out", "open")])
    B["geom"] = dict(pos=p, x=570, y=570, w=250, h=h)

    h, p = pblock(g, 570, Y, 250, "u_stage_*", "lut · win3x3 · hist · seg — 4 identical", "cam",
                  left=[("s_data", "[63:0]", "in", None),
                        ("s_valid", "", "in", None),
                        ("s_sof", "", "in", None),
                        ("s_eol", "", "in", "cam_weol"),
                        ("param", "[15:0]", "in", "stage_param"),
                        ("knob", "[7:0]", "in", "stage_knob")],
                  right=[("m_data", "[63:0]", "out", "st_data[63:0]"),
                         ("m_valid", "", "out", "st_valid[0]"),
                         ("m_sof", "", "out", "st_sof[0]"),
                         ("m_eol", "", "out", "st_eol[0]"),
                         ("stat", "[31:0]", "out", "st_stat")])
    B["stg"] = dict(pos=p, x=570, y=Y, w=250, h=h)

    h, p = pblock(g, 865, Y, 270, "u_stage_mux", "4 : 1 · sel = 0 passes the raw stream", "cam",
                  left=[("s_data", "[63:0]", "in", "cam_word"),
                        ("s_valid", "", "in", "cam_word_valid"),
                        ("s_sof", "", "in", "cam_word_first"),
                        ("s_eol", "", "in", "cam_weol"),
                        ("st_data", "[255:0]", "in", "4 × m_data"),
                        ("st_valid", "[3:0]", "in", "4 × m_valid"),
                        ("st_sof", "[3:0]", "in", "4 × m_sof"),
                        ("st_eol", "[3:0]", "in", "4 × m_eol"),
                        ("st_stat", "[127:0]", "in", "4 × stat"),
                        ("sel", "[2:0]", "in", "ctrl[4:2]"),
                        ("param", "[15:0]", "in", "ctrl[31:16]"),
                        ("knob", "[7:0]", "in", "ctrl[7:5]"),
                        ("clk_ctrl", "", "in", "clk50"),
                        ("rst_ctrl_n", "", "in", "sys_rst_n")],
                  right=[("m_data", "[63:0]", "out", None),
                         ("m_valid", "", "out", None),
                         ("m_sof", "", "out", "wr_data[64]"),
                         ("m_eol", "", "out", "open"),
                         ("s_param", "[15:0]", "out", "stage_param"),
                         ("s_knob", "[7:0]", "out", "stage_knob"),
                         ("stat", "[31:0]", "out", "status_ext")])
    B["mux"] = dict(pos=p, x=865, y=Y, w=270, h=h)

    h, p = pblock(g, 1145, Y, 230, "u_cam_fifo", "afifo #(AW=7, W=65)", "axi",
                  left=[("wr_data", "[64:0]", "in", "{m_sof, m_data}"),
                        ("wr_en", "", "in", None),
                        ("wr_full", "", "out", "open"),
                        ("wr_level", "[7:0]", "out", "open"),
                        ("wr_clk", "", "in", "cam_pclk"),
                        ("wr_rst_n", "", "in", "cam_rst_n")],
                  right=[("rd_data", "[64:0]", "out", None),
                         ("rd_empty", "", "out", None),
                         ("rd_en", "", "in", None),
                         ("rd_level", "[7:0]", "out", None),
                         ("rd_clk", "", "in", "clk50"),
                         ("rd_rst_n", "", "in", "sys_rst_n")])
    B["cfifo"] = dict(pos=p, x=1145, y=Y, w=230, h=h)

    # ---------------------------------------------------------------- ddr side
    h, p = pblock(g, 1405, Y, 300, "u_fb_ddr", "AXI4 master → S_AXI_HP0", "axi",
                  left=[("cam_data", "[64:0]", "in", None),
                        ("cam_empty", "", "in", None),
                        ("cam_pop", "", "out", None),
                        ("cam_level", "[7:0]", "in", None),
                        ("freeze", "", "in", "ctrl[1]")],
                  right=[("disp_data", "[63:0]", "out", None),
                         ("disp_push", "", "out", None),
                         ("disp_full", "", "in", None),
                         ("disp_level", "[7:0]", "in", None),
                         ("rel_ack", "", "out", "u_lcd_display"),
                         ("rel_req", "", "in", "u_lcd_display"),
                         ("frame_seen", "", "out", "video_valid"),
                         ("cam_frames", "[15:0]", "out", "status_cam[31:16]"),
                         ("frame_new", "", "out", "fps_cnt"),
                         ("axi_errs", "[7:0]", "out", "status_disp[31:24]")])
    B["fb"] = dict(pos=p, x=1405, y=Y, w=300, h=h)

    h, p = pblock(g, 1745, Y, 230, "u_disp_fifo", "afifo #(AW=7, W=64)", "pix",
                  left=[("wr_data", "[63:0]", "in", None),
                        ("wr_en", "", "in", None),
                        ("wr_full", "", "out", None),
                        ("wr_level", "[7:0]", "out", None),
                        ("wr_clk", "", "in", "clk50"),
                        ("wr_rst_n", "", "in", "sys_rst_n")],
                  right=[("rd_data", "[63:0]", "out", None),
                         ("rd_empty", "", "out", None),
                         ("rd_en", "", "in", None),
                         ("rd_level", "[7:0]", "out", "open"),
                         ("rd_clk", "", "in", "clk_pix"),
                         ("rd_rst_n", "", "in", "pix_rst_n")])
    B["dfifo"] = dict(pos=p, x=1745, y=Y, w=230, h=h)

    # ---------------------------------------------------------------- panel side
    h, p = pblock(g, 2005, Y, 270, "u_lcd_display", "1056 × 526 @ 33.333 MHz", "pix",
                  left=[("fifo_data", "[63:0]", "in", None),
                        ("fifo_empty", "", "in", None),
                        ("fifo_pop", "", "out", None),
                        ("rel_req", "", "out", "u_fb_ddr"),
                        ("rel_ack", "", "in", "u_fb_ddr"),
                        ("video_valid", "", "in", "frame_seen"),
                        ("test_pattern", "", "in", "ctrl[0]"),
                        ("frames", "[15:0]", "out", "status_disp"),
                        ("underruns", "[7:0]", "out", "status_disp")],
                  right=[("lcd_hsync", "", "out", None),
                         ("lcd_vsync", "", "out", None),
                         ("lcd_de", "", "out", None),
                         ("lcd_rgb", "[15:0]", "out", None)])
    B["lcd"] = dict(pos=p, x=2005, y=Y, w=270, h=h)

    h, p = pblock(g, 2315, Y, 149, "TFT", "ribbon", "ext",
                  left=[("hsync", "", "in", None),
                        ("vsync", "", "in", None),
                        ("de", "", "in", None),
                        ("rgb", "[15:0]", "in", None),
                        ("pclk", "", "in", "lcd_pclk"),
                        ("bl", "", "in", "lcd_bl")])
    B["pnl"] = dict(pos=p, x=2315, y=Y, w=149, h=h)

    h, p = pblock(g, 2315, 540, 149, "SiI9022A", "HDMI out", "ext",
                  left=[("hsync", "", "in", "lcd_hsync"),
                        ("vsync", "", "in", "lcd_vsync"),
                        ("de", "", "in", "lcd_de"),
                        ("rgb", "[15:0]", "in", "lcd_rgb"),
                        ("scl", "", "in", "hdmi_sclk"),
                        ("sda", "", "io", "hdmi_sdat")])
    B["sii"] = dict(pos=p, x=2315, y=540, w=149, h=h)

    # ---------------------------------------------------------------- wires
    link(g, B["sens"], ("R", "HREF"), B["cap"], ("L", "href"))
    link(g, B["sens"], ("R", "VSYNC"), B["cap"], ("L", "vsync"))
    link(g, B["sens"], ("R", "D"), B["cap"], ("L", "data"))

    link(g, B["cap"], ("R", "word"), B["stg"], ("L", "s_data"))
    link(g, B["cap"], ("R", "word_valid"), B["stg"], ("L", "s_valid"))
    link(g, B["cap"], ("R", "word_first"), B["stg"], ("L", "s_sof"))

    link(g, B["mux"], ("R", "m_data"), B["cfifo"], ("L", "wr_data"))
    link(g, B["mux"], ("R", "m_valid"), B["cfifo"], ("L", "wr_en"))

    link(g, B["cfifo"], ("R", "rd_data"), B["fb"], ("L", "cam_data"))
    link(g, B["cfifo"], ("R", "rd_empty"), B["fb"], ("L", "cam_empty"))
    link(g, B["cfifo"], ("R", "rd_en"), B["fb"], ("L", "cam_pop"))
    link(g, B["cfifo"], ("R", "rd_level"), B["fb"], ("L", "cam_level"))

    link(g, B["fb"], ("R", "disp_data"), B["dfifo"], ("L", "wr_data"))
    link(g, B["fb"], ("R", "disp_push"), B["dfifo"], ("L", "wr_en"))
    link(g, B["fb"], ("R", "disp_full"), B["dfifo"], ("L", "wr_full"))
    link(g, B["fb"], ("R", "disp_level"), B["dfifo"], ("L", "wr_level"))

    link(g, B["dfifo"], ("R", "rd_data"), B["lcd"], ("L", "fifo_data"))
    link(g, B["dfifo"], ("R", "rd_empty"), B["lcd"], ("L", "fifo_empty"))
    link(g, B["dfifo"], ("R", "rd_en"), B["lcd"], ("L", "fifo_pop"))

    link(g, B["lcd"], ("R", "lcd_hsync"), B["pnl"], ("L", "hsync"))
    link(g, B["lcd"], ("R", "lcd_vsync"), B["pnl"], ("L", "vsync"))
    link(g, B["lcd"], ("R", "lcd_de"), B["pnl"], ("L", "de"))
    link(g, B["lcd"], ("R", "lcd_rgb"), B["pnl"], ("L", "rgb"))

    # ---------------------------------------------------------------- AXI port
    fbx, fbw = B["fb"]["x"], B["fb"]["w"]
    fbb = B["fb"]["y"] + B["fb"]["h"]
    cx = fbx + fbw / 2
    psy = 545
    g.line(cx, fbb, cx, psy, AXI_C, sw=3.4)
    head(g, (cx, psy - 12), (cx, psy), AXI_C, 9.5, 4.6)
    g.line(cx - 34, fbb, cx + 34, fbb, AXI_C, sw=5.0)
    g.text(cx + 14, fbb + 22, "m_axi_* · 37 signals", size=8.4, fill=AXI_C, family=MONO)
    g.text(cx + 14, fbb + 34, "AW W B AR R · 64-bit @ 50 MHz", size=8.0, fill=MUTED,
           family=MONO)

    psx, psw = 1420, 280
    g.rect(psx, psy, psw, 84, fill="#f1edf9", stroke="#6b58a8", r=8, sw=1.6)
    g.text(psx + 10, psy + 20, "PS7 S_AXI_HP0", size=11.2, weight="600",
           family=MONO, fill="#4b3a86")
    g.text(psx + 10, psy + 32, "AXI4 slave · 64-bit @ 50 MHz", size=7.6, fill=MUTED,
           family=MONO)
    g.line(psx + 10, psy + 38, psx + psw - 10, psy + 38, "#6b58a8", sw=1)
    for i, ch in enumerate(("AW", "W", "B", "AR", "R")):
        gx2 = psx + 26 + i * 48
        g.rect(gx2 - 13, psy + 48, 26, 20, fill="#e5ddf4", stroke="#bfb2dd", r=4, sw=1)
        g.text(gx2, psy + 62, ch, size=8.6, weight="600", fill="#4b3a86",
               family=MONO, anchor="middle")

    # ---------------------------------------------------------------- bottom band
    g.rect(36, 760, W - 72, 396, fill="#fbfaf6", stroke="#ddd8ca", r=14, sw=1.2)
    g.text(52, 786, "PS7 + board resources", size=12.4, weight="600", fill="#4b3a86")
    g.text(262, 786, "— where the nets above come from: clocks, ctrl fields, status words, the two I²C engines",
           size=9.4, fill=MUTED)

    h, p = pblock(g, 56, 806, 240, "u_clk_gen", "MMCM 1200 MHz", "axi",
                  left=[("clk50", "", "in", "PS FCLK0"),
                        ("rst", "", "in", "~rst50_n")],
                  right=[("clk_pix", "", "out", "clk_pix"),
                         ("clk_cam", "", "out", "camera_xclk"),
                         ("locked", "", "out", "mmcm_locked")])
    B["clk"] = dict(pos=p, x=56, y=806, w=240, h=h)

    h, p = pblock(g, 336, 806, 230, "u_ov5640_init", "SCCB · 252 writes", "axi",
                  left=[("clk", "", "in", "clk50"),
                        ("rst_n", "", "in", "sys_rst_n")],
                  right=[("init_done", "", "out", "cam_init_done"),
                         ("i2c_sclk", "", "out", "camera_sclk"),
                         ("i2c_sdat", "", "io", "camera_sdat")])
    B["cinit"] = dict(pos=p, x=336, y=806, w=230, h=h)

    h, p = pblock(g, 606, 806, 230, "u_sii9022_init", "I²C · 42 writes", "axi",
                  left=[("clk", "", "in", "clk50"),
                        ("rst_n", "", "in", "sys_rst_n"),
                        ("go", "", "in", "hdmi_go")],
                  right=[("i2c_sclk", "", "out", "hdmi_sclk"),
                         ("i2c_sdat", "", "io", "hdmi_sdat")])
    B["sinit"] = dict(pos=p, x=606, y=806, w=230, h=h)

    h, p = pblock(g, 876, 806, 250, "axi_gpio_ctrl", "32-bit, all outputs", "ps",
                  right=[("ctrl", "[31:0]", "out", "6 fields →")])
    B["gctrl"] = dict(pos=p, x=876, y=806, w=250, h=h)

    h, p = pblock(g, 876, 900, 250, "axi_gpio_status", "ch1 and ch2, 32-bit", "ps",
                  left=[("status_cam", "[31:0]", "in", "{frames, fps, live, init}"),
                        ("status_disp", "[31:0]", "in", "{errs, underruns, frames}")])
    B["gstat"] = dict(pos=p, x=876, y=900, w=250, h=h)

    h, p = pblock(g, 1166, 806, 230, "axi_gpio_ext", "32-bit", "ps",
                  left=[("status_ext", "[31:0]", "in", "stage stat")])
    B["gext"] = dict(pos=p, x=1166, y=806, w=230, h=h)

    # ctrl field map
    g.rect(56, 968, 520, 168, fill="#ffffff", stroke="#bfb2dd", r=8, sw=1.2)
    g.text(68, 988, "ctrl[31:0] field map", size=10, weight="600", fill="#4b3a86",
           family=MONO)
    fields = (("ctrl[0]", "u_lcd_display.test_pattern"),
              ("ctrl[1]", "u_fb_ddr.freeze"),
              ("ctrl[4:2]", "u_stage_mux.sel"),
              ("ctrl[7:5]", "u_stage_mux.knob"),
              ("ctrl[15:8]", "backlight PWM duty"),
              ("ctrl[31:16]", "u_stage_mux.param"))
    for i, (f, t) in enumerate(fields):
        fx = 68 + (i // 3) * 250
        fy = 1010 + (i % 3) * 16
        g.text(fx, fy, f, size=8.0, fill=CTRL_C, family=MONO, weight="600")
        g.text(fx + 64, fy, "→ " + t, size=8.0, fill=MUTED, family=MONO)

    g.text(68, 1080, "The six fields are not separate nets: the PS writes one 32-bit", size=8.0,
           fill=MUTED)
    g.text(68, 1092, "GPIO word and the PL slices it where it is used.  u_stage_mux", size=8.0,
           fill=MUTED)
    g.text(68, 1104, "re-samples sel / param / knob on the frame tag, so a ctrl write", size=8.0,
           fill=MUTED)
    g.text(68, 1116, "never tears a frame in half.", size=8.0, fill=MUTED)

    # AXI channel table
    ax, ay = 1400, 806
    aw = W - 72 - ax
    g.rect(ax, ay, aw, 318, fill="#ffffff", stroke="#adc6e4", r=8, sw=1.2)
    g.text(ax + 12, ay + 20, "m_axi_* — the 37 signals behind that bus port",
           size=10, weight="600", fill=AXI_C, family=MONO)
    chans = (("AW", "awid[3:0] awaddr[31:0] awlen[7:0] awsize[2:0]",
              "awburst[1:0] awlock awcache[3:0] awprot[2:0] awqos[3:0] awregion[3:0]",
              "awvalid / awready"),
             ("W", "wdata[63:0] wstrb[7:0]", "wlast", "wvalid / wready"),
             ("B", "bresp[1:0]", "bid[3:0] exists on the top port, unused by fb_ddr",
              "bvalid / bready"),
             ("AR", "arid[3:0] araddr[31:0] arlen[7:0] arsize[2:0]",
              "arburst[1:0] arlock arcache[3:0] arprot[2:0] arqos[3:0] arregion[3:0]",
              "arvalid / arready"),
             ("R", "rdata[63:0] rresp[1:0] rlast", "rid[3:0] exists on the top port, unused",
              "rvalid / rready"))
    for i, (ch, l1, l2, l3) in enumerate(chans):
        cy = ay + 46 + i * 50
        g.rect(ax + 12, cy - 13, 44, 20, fill="#eaf1fb", stroke="#adc6e4", r=4, sw=1)
        g.text(ax + 34, cy + 1, ch, size=9.4, weight="600", fill=AXI_C,
               family=MONO, anchor="middle")
        g.text(ax + 66, cy - 4, l1, size=7.6, fill=MUTED, family=MONO)
        g.text(ax + 66, cy + 8, l2, size=7.6, fill=MUTED, family=MONO)
        g.text(ax + aw - 14, cy - 4, l3, size=7.6, fill=AXI_C, family=MONO, anchor="end")

    # ---------------------------------------------------------------- footer
    g.line(36, 1168, W - 36, 1168, "#d9d4c7", sw=1)
    g.text(36, 1182, "ACZ702 · xc7z020clg400-1 · port names, widths and directions read from "
                     "camera_pipeline/rtl/*.v", size=8.4, fill=FAINT, family=MONO)
    g.text(W - 36, 1182, "drawn wires = adjacent blocks;  a net name on a port joins it to "
                         "the same name elsewhere", size=8.4, fill=FAINT, family=MONO,
           anchor="end")


def main():
    g = Canvas()
    scene(g)
    DOCS.mkdir(parents=True, exist_ok=True)
    to_svg(g, SVG_OUT, W, H)
    to_png(g, PNG_OUT, W, H, out_scale=2)
    print(f"wrote {SVG_OUT.name}: {SVG_OUT.stat().st_size} bytes")
    print(f"wrote {PNG_OUT.name}: {PNG_OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
