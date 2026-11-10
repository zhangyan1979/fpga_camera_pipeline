# =============================================================================
#  frame_stats.py — quick numbers about a DDR frame dump (verification aid).
#
#  Usage: python tools/frame_stats.py <a.bin> [b.bin]
#
#  Prints the mean/min/max, how much of the picture is dark, and - when a
#  second dump is given - whether the two frames are identical.
# =============================================================================
import struct
import sys

W, H = 800, 480


def load(path):
    data = open(path, 'rb').read()
    if len(data) < W * H * 2:
        raise SystemExit(f'{path}: {len(data)} bytes, need {W * H * 2}')
    return data


def stats(path):
    data = load(path)
    px = struct.unpack('<%dH' % (W * H), data[:W * H * 2])
    mean = sum(px) / len(px)
    dark = sum(1 for v in px if v < 1024) / len(px)
    # row-to-row difference tells us the picture really is two-dimensional
    rows = [px[y * W:(y + 1) * W] for y in range(H)]
    row_delta = sum(
        abs(sum(rows[y]) / W - sum(rows[y - 1]) / W) for y in range(1, H)
    ) / (H - 1)
    return data, mean, min(px), max(px), dark, row_delta


a, mean, lo, hi, dark, rd = stats(sys.argv[1])
print(f'{sys.argv[1]}: mean={mean:8.1f} min={lo} max={hi} '
      f'dark={dark*100:5.1f}% row_delta={rd:6.2f}')

if len(sys.argv) > 2:
    b, mean_b, _, _, _, _ = stats(sys.argv[2])
    print(f'{sys.argv[2]}: mean={mean_b:8.1f}')
    same = a[:W * H * 2] == b[:W * H * 2]
    print(f'identical frames: {same}')
