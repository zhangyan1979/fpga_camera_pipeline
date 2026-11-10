# =============================================================================
#  fb2png.py — turn a raw RGB565 DDR frame-buffer dump into a PNG.
#
#  Usage: python tools/fb2png.py <in.bin> <out.png> [gain] [gamma]
#
#      gain    multiply the linear channel value before the gamma curve (>1
#              brightens); default 1.0
#      gamma   gamma exponent applied after the gain (0.6 brightens mid-tones);
#              default 1.0
#
#  A dump is 800 x 480 RGB565 little-endian pixels, i.e. 768 000 bytes, which is
#  exactly what ps/dump_fb.tcl writes.
# =============================================================================
import struct
import sys

from PIL import Image

W, H = 800, 480

src = sys.argv[1] if len(sys.argv) > 1 else 'ps/fb_dump.bin'
dst = sys.argv[2] if len(sys.argv) > 2 else 'ps/fb_dump.png'
gain = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
gamma = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0

data = open(src, 'rb').read()
if len(data) < W * H * 2:
    raise SystemExit(f'{src}: {len(data)} bytes, need {W * H * 2}')


def curve(v, top):
    x = min(1.0, (v / top) * gain)
    return int(round(255.0 * (x ** gamma)))


img = Image.new('RGB', (W, H))
px = img.load()
for y in range(H):
    row = data[y * W * 2:(y + 1) * W * 2]
    for x, v in enumerate(struct.unpack('<%dH' % W, row)):
        px[x, y] = (curve((v >> 11) & 0x1F, 31),
                    curve((v >> 5) & 0x3F, 63),
                    curve(v & 0x1F, 31))

img.save(dst)
print(f'wrote {dst} (gain {gain}, gamma {gamma})')
