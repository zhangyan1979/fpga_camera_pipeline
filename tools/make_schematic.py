#!/usr/bin/env python3
"""
Module schematic for the ACZ702 camera pipeline: clock domains as lanes, the
video path left to right, both CDC FIFOs on the lane boundaries, the PS7 / DDR3
resources underneath.  Port-level detail lives in make_port_sheet.py.

    python tools/make_schematic.py
    -> docs/camera_pipeline_schematic.svg
    -> docs/camera_pipeline_schematic.png
"""

from pathlib import Path

from schematic import *

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent / "docs"
SVG_OUT = DOCS / "camera_pipeline_schematic.svg"
PNG_OUT = DOCS / "camera_pipeline_schematic.png"

W, H = 1820, 1152

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
    to_svg(g, SVG_OUT, W, H)
    to_png(g, PNG_OUT, W, H)
    print(f"wrote {SVG_OUT.name}: {SVG_OUT.stat().st_size} bytes")
    print(f"wrote {PNG_OUT.name}: {PNG_OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
