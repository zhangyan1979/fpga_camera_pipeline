# =============================================================================
#  hist_overlay_preview.py 鈥?render what rtl/hist_overlay.v will draw.
#
#  Usage: python tools/hist_overlay_preview.py <in.bin> <out.png> [gain] [gamma]
#
#  Reads a raw RGB565 DDR frame dump (800 x 480 little-endian, as written by
#  ps/dump_fb.tcl), builds the luminance histogram with the same integer
#  formula as stage_hist, then draws the overlay the way the RTL does:
#
#    * bin  = (x - 16) / 3, three pixels per bin, x from 16 to 783;
#    * the graph lives in a 160-pixel band at the bottom of the screen;
#    * bar  = (479 - y) < h(count), with the frame peak filling the band and
#      20 pixels per octave below it:  h = 160 - 20*(clz(count) - clz(peak)),
#      h = 0 for an empty bin or more than 8 octaves below the peak;
#    * inside a bar the mask keeps the pixel's red and blue and saturates its
#      green channel: the picture shows through, tinted green.
#
#  gain / gamma brighten the *base picture* only (like docs/frame_boost.png);
#  the histogram, the mean and the percentile are always computed from the raw
#  dump, which is what the hardware measures.
# =============================================================================
import struct
import sys

from PIL import Image

W, H = 800, 480
TOTAL = W * H
X0 = 16
BAR_W = 3
BINS = 256

src = sys.argv[1] if len(sys.argv) > 1 else 'docs/live_a.bin'
dst = sys.argv[2] if len(sys.argv) > 2 else 'docs/frame_hist_overlay.png'
gain = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
gamma = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0

data = open(src, 'rb').read()
if len(data) < TOTAL * 2:
    raise SystemExit(f'{src}: {len(data)} bytes, need {TOTAL * 2}')
pix = struct.unpack('<%dH' % TOTAL, data[:TOTAL * 2])


def lum(p):
    r5 = (p >> 11) & 0x1F
    g6 = (p >> 5) & 0x3F
    b5 = p & 0x1F
    return (77 * r5 + 75 * g6 + 29 * b5) >> 5


hist = [0] * BINS
for p in pix:
    hist[lum(p)] += 1
hist = [min(c, 0xFFFF) for c in hist]          # the RTL saturates at 16 bits

# mean and 99th percentile, the same definitions as stage_hist
mean = sum(b * c for b, c in enumerate(hist)) // TOTAL

p99 = 0
tail = 0
for b in range(255, -1, -1):
    if 100 * tail <= TOTAL:
        p99 = b
    tail += hist[b]


def clz16(v):
    n = 0
    for bit in range(15, -1, -1):
        if v & (1 << bit):
            break
        n += 1
    return n


BAND_H = 160
SCALE = 20
MAX_OCT = BAND_H // SCALE          # 8 octaves of range below the peak
PEAK = max(hist)
ZP = clz16(PEAK) if PEAK else 15


def height(c):
    if c == 0 or PEAK == 0:
        return 0
    dz = max(0, clz16(c) - ZP)
    return 0 if dz > MAX_OCT else BAND_H - SCALE * dz


def mix(a, b):
    r5 = ((a >> 11 & 0x1F) + (b >> 11 & 0x1F)) >> 1
    g6 = ((a >> 5 & 0x3F) + (b >> 5 & 0x3F)) >> 1
    b5 = ((a & 0x1F) + (b & 0x1F)) >> 1
    return (r5 << 11) | (g6 << 5) | b5


GREEN = 0x07E0

out = [0] * TOTAL
for y in range(H):
    y_above = (H - 1) - y
    base_row = y * W
    for x in range(W):
        p = pix[base_row + x]
        if X0 <= x < X0 + BINS * BAR_W and y_above < BAND_H:
            # the mask keeps R and B and saturates the green channel
            if y_above < height(hist[(x - X0) // BAR_W]):
                p = (p & 0xF81F) | GREEN
        out[base_row + x] = p


def curve(v, top):
    x = min(1.0, (v / top) * gain)
    return int(round(255.0 * (x ** gamma)))


img = Image.new('RGB', (W, H))
px = img.load()
for y in range(H):
    for x in range(W):
        v = out[y * W + x]
        px[x, y] = (curve((v >> 11) & 0x1F, 31),
                    curve((v >> 5) & 0x3F, 63),
                    curve(v & 0x1F, 31))

img.save(dst)
print(f'{src} -> {dst}: mean {mean}, p99 {p99} (stat only), '
      f'peak {PEAK} at bin {hist.index(PEAK)}')
