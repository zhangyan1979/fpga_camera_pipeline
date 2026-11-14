# Colour segmentation and per-label bounding boxes (stage 4)

`rtl/stage_seg.v` is the first application stage in the pipeline slot.  It turns
the camera's RGB565 words into four colour labels plus a background label, keeps
a bounding box for every label, reports the finished boxes to the PS through
`stat`, and optionally paints the detected pixels so the segmentation is
visible on the panel.

```
  RGB565 word ──► Y / Co / Cg ──► normalise by Y ──► four box tests ──► labels
                                                                          │
                       pass-through / paint ◄── 1x3 erosion ◄─────────────┘
                              │
                              ├──► m_* (frame buffer path)
                              └──► four label-addressed bbox RAMs ──► stat
```

Everything runs in `cam_pclk` (42 MHz) and is purely streaming: no line
buffers, no stall, no second clock domain.

## Control

The `param` and `knob` inputs are frame-stable (stage_mux re-latches them on the
emitted frame tag), so the stage samples them directly.

| signal | meaning |
|---|---|
| `knob[1:0]` | label rotation.  The four boxes are red, green, blue and yellow; `knob[1:0]=m` makes label 0 the box `m`, label 1 the box `m+1`, and so on (mod 4).  This is how the console chooses which colour `stat` reports. |
| `knob[2]` | 1 = paint every detected (eroded) pixel in a flat per-label colour; 0 = pass the camera word through unchanged.  Pass-through mode is bit exact. |
| `knob[7:3]` | unused |
| `param[7:0]` | box half-width in the normalised chroma plane, Q4 (16 = 1.0) |
| `param[15:8]` | minimum luminance.  Pixels with `Y < param[15:8]` are background; `Y = 0` is always background because the chroma normalisation is undefined there. |

The default useful value is `param = 0x1008` (minimum luminance 16, tolerance
8 = 0.5 in the normalised plane).

## Colour conversion

### RGB565 expansion

The 5/6/5 fields are left-aligned into 8 bits with zero low bits:

```
  R = {r5, 3'b000}    G = {g6, 2'b00}    B = {b5, 3'b000}
```

so `R, B` are multiples of 8 and `G` a multiple of 4.  Zero padding costs at
most 7/255 (2.7 %) in the RGB value compared with bit replication, but it keeps
`Y` on a 4-unit grid and therefore always even, which halves the reciprocal
table.  A 5-bit/6-bit sensor does not deliver more than that anyway.

### YCoCg-style transform (shifts and adds only)

```
  Y  = (R + 2G + B) / 4        Y  = 0 .. 250, always even
  Co = R - B                   Co = -248 .. +248
  Cg = G - (R + B)/2           Cg = -248 .. +252
```

`R + 2G + B` is formed with adds and shifts; `(R+B)/2` is a shift.  No
multiplier is used in this part.

### Normalisation without a divider

Intensity independence requires `Co/Y` and `Cg/Y`.  A 128 x 16 ROM is indexed
by `Y/2` and returns

```
  rec = floor(65536 / Y)
```

`Y` is even, so the table has 128 entries instead of 256; entry `Y/2` is
`floor(32768 / (Y/2))`.  The normalised chroma is

```
  co_n = (Co * rec) >> 12        Q4: 16 = 1.0
  cg_n = (Cg * rec) >> 12
```

which is `Co/Y * 16` and `Cg/Y * 16`.  The `>> 12` is an arithmetic shift
(floor), and `rec` itself is a floor, so both behave identically for negative
values.  `co_n`/`cg_n` fit in 13 bits signed; the largest possible value is
`252 * 32768 >> 12 = 2016`.

The RTL computes the `9x17` and `10x17` products in a 26-bit signed
intermediate (`prod_co`/`prod_cg`).  This matters: Verilog sizes a `*` to its
operands, not to the sum, so writing the multiply and shift in one expression
would truncate the product before the shift.

### Approximation error

* `rec` loses less than 1/65536 of the reciprocal: `|co_n|` error `< |Co|/4096`,
  at most 0.06 Q4 LSB.
* the final arithmetic shift loses less than 1 Q4 LSB = 1/16 = 0.0625 in the
  normalised plane.
* combined normalisation error `< 0.07` normalised units (about 1.1 Q4 LSB).
* the RGB565 expansion (zero-padded low bits) is the dominant error: it shifts
  a saturated colour by about 1 Q4 LSB in `co_n`, and the relative error grows
  for dark pixels because the reciprocal amplifies it.  This is one reason the
  minimum-luminance parameter exists.

The tolerance is normally 8..32 Q4 LSB (0.5..2.0 normalised units), so the
arithmetic error is well below one tolerance step.

### The four boxes

The centres are the exact Q4 results for saturated RGB565 primaries.  They are
fixed constants in the RTL:

| box | colour | RGB565 | `co_n` | `cg_n` |
|---|---|---|---|---|
| 0 | red | `0xF800` |  63 | -32 |
| 1 | green | `0x07E0` |   0 |  31 |
| 2 | blue | `0x001F` | -64 | -32 |
| 3 | yellow | `0xFFE0` |  21 |  10 |

Red and blue are not symmetric (+63/-64) because the shift is a floor.  The
rotation from `knob[1:0]` maps box `b` to label `(b - knob[1:0]) mod 4`, so
`knob[1:0] = 0` gives the table above and `knob[1:0] = 1` gives green,
blue, yellow, red for labels 0..3.

## Box test

For each of the four pixels in the word:

```
  lum_ok = (Y != 0) && (Y >= param[15:8])
  in_box(l) = |co_n - centre_co[l]| <= param[7:0] &&
              |cg_n - centre_cg[l]| <= param[7:0]
```

The label is the first `l` in 0..3 with `lum_ok && in_box(l)`, otherwise 15
(background).  Label 0 therefore has priority; overlapping boxes resolve
deterministically.  The test is a rectangle in the normalised chroma plane, not
a distance: both coordinates must be inside the half-width.

Worked example: a near-red pixel `0xF021` (R=240, G=4, B=8) gives Y=64,
Co=232, Cg=-120, `rec=1024`, `co_n=58`, `cg_n=-30`.  With tolerance 8 it is
5 and 2 away from the red centre (63,-32), so it is label 0.  The grey
background `0x8410` gives `(0,0)`, at least 10 away from every centre, so it is
background.

## Horizontal 1x3 erosion

A label is kept only if

```
  label[i] == label[i-1] == label[i+1]
```

with the missing neighbour at the left edge of a line replaced by `label[0]`
and the missing neighbour at the right edge replaced by `label[W-1]`
(duplication).  The window is centred and horizontal only.

Consequences, which the testbench checks exactly:

* a run of 1 or 2 pixels in x is removed;
* an interior run `[x0, x1]` becomes `[x0+1, x1-1]` (both sides shrink by one);
* a run that starts at `x=0` keeps `xmin=0` because the edge duplicates; a run
  that reaches the right edge keeps `xmax=W-1`;
* no vertical shrink at all: a one-pixel-tall horizontal streak of length >= 3
  survives, and isolated single-pixel noise on a vertical edge survives.  The
  3x3 stage of another tier is intended to compose with this one for full 2-D
  rejection.

The erosion is always on.  It is a handful of equality compares per pixel
lane; replace the four `er*` expressions with `a_lab[0..3]` in `stage_seg.v` if
a build without noise rejection is wanted.  There is no line buffer and no
extra latency beyond the one-word look-ahead described below.

## Per-label bounding boxes

Bailey 13.1 points out that a small fabric RAM indexed by the pixel label is
cheaper than a wide multiplexer across all labels.  Four pixels are classified
per clock, so the store is four parallel lanes, one per pixel position in the
word:

```
  lane p, label l:  mem[p][l] = {xmin, xmax, ymin, ymax}   40 bits
                    seen[p][l]                             1 bit
```

Each lane is a 4-entry RAM addressed by `label[1:0]`: asynchronous read,
synchronous write.  The address is the pixel's label, so the update is one
read-compare-write per pixel per clock.  The `seen` bit removes the need to
pre-load the RAM at the frame tag: the first pixel of a label writes
`xmin=xmax=x`, `ymin=ymax=y`, which is equivalent to initialising
`xmin/ymin=MAX` and `xmax/ymax=0`, in one write instead of a separate
initialisation pass.  The output frame tag (`m_sof`) clears all `seen` bits,
and the first word of the frame is processed with the bits already cleared
(the `new_frame` term forces the initialising write).

**Coordinate width.**  The brief suggests nine bits for x, but the panel is
800 pixels wide and `x` reaches 799; nine bits (0..511) would fold the right
third of the image onto the left.  The implementation therefore uses 10 bits
for x and y.  The RAM word is 40 bits, still tiny.

The lanes are merged at the end of the frame.  `frame_end` is the last word of
the last line (`m_valid && m_eol_i && m_wy == LINES-1`), where `LINES` is the
`V_ACTIVE` parameter.  One clock later a four-cycle merge reads label 0..3 in
turn, reduces the four lanes with min/max, and writes the report registers:

```
  rep_xmin[0:3], rep_xmax[0:3], rep_ymin[0:3], rep_ymax[0:3], rep_present[0:3]
```

The merge runs during the vertical blanking, so it cannot collide with pixel
updates.  A label that is absent in the frame is reported as
`xmin=ymin=1023`, `xmax=ymax=0`, `present=0`; `present` is the authoritative
"non-empty" flag.

### Frame-to-frame reporting

The report is the frame that **just finished**, and it is held while the next
frame is accumulated:

1. frame F is accumulated into the lane RAMs as its output words stream out;
2. at the end of frame F the four lanes are merged into `rep_*`;
3. frame F+1 starts on its own frame tag, clears the `seen` bits and begins
   accumulating, but `rep_*` is untouched;
4. at the end of frame F+1, `rep_*` is replaced by frame F+1.

`stage_mux` samples `stat` one clock after the **input** frame tag, and the
vertical blanking between frames is far longer than the stage's latency, so at
that instant the report already contains the frame that just completed.  This
is the requested "report one frame while the next accumulates": no ping-pong
copy is needed, because the working state lives in the lane RAMs and the report
is a separate register set.

## Statistic

`stat` is combinational from the report registers, so stage_mux can snapshot it
without any handshake:

| bits | field |
|---|---|
| `[7:0]` | number of non-empty labels, 0..4 |
| `[15:8]` | label-0 box width in pixels, `xmax-xmin+1`, saturated at 255 |
| `[23:16]` | label-0 box height in pixels, `ymax-ymin+1`, saturated at 255 |
| `[31:24]` | label-0 centre x in units of 4 pixels, `(xmin+xmax)>>3` |

When label 0 is absent the width, height and centre fields are zero (the label
count still counts the other labels).  The width and height saturate because
the fields are eight bits and a box can span the whole 800-pixel line; the
centre field is 0..199 and fits.

Example: label 0 occupies `x=0..2`, `y=0..3`, and one other label is present:
`stat = {centre 0, height 4, width 3, count 2} = 0x0004_0302`.

## Latency and stream invariants

The data path has four valid-word slots: RGB unpack, normalise, label, and the
eroder/output stage.  The last slot holds a word until the next word supplies
the right neighbour of its last pixel; this is one word of look-ahead inside
the stage, not a line buffer.  At the end of a line the right neighbour does
not exist, so the edge pixel is duplicated and the word is flushed on the
following clock.  The camera's horizontal blanking (and the seven idle
`cam_pclk` cycles between words) absorbs that clock.

The original word, `sof` and `eol` all travel in the same registers, so:

* the output word order is the input word order, one word per input word;
* `m_sof` is on the first word of the frame and `m_eol` on the last word of
  every line;
* the output contains exactly `WORDS_PER_LINE * LINES` words per frame
  (200 x 480 = 96 000 for the real panel);
* there is no stall and no back-pressure.

`LINES` must be set to the real number of active lines (`V_ACTIVE`), because
it is how the stage recognises the end of a frame.

## Resource estimate

The design has not been through synthesis in this task (deliberately: only
simulation is allowed).  From the structure:

| resource | estimate | reason |
|---|---|---|
| DSP48E1 | 8 | one `9x17` Co multiply and one `10x17` Cg multiply per pixel lane |
| BRAM | 0 | the reciprocal ROM (4 copies of 128 x 16) and the bbox store map to LUT/LUTRAM |
| LUT | ~800-1100 | 4 x 128 x 16 ROM (~130), 4 x 4 x 40 bbox LUTRAM (~160), label compares, merge, stat, pipeline |
| FF | ~700 | eight 13-bit chroma registers per pipeline stage, data/tag pipeline (4 x 67), four 40-bit report sets, seen bits |

There is plenty of headroom on the XC7Z020 (14.6 % of LUTs and 0 of 220 DSPs
used before this stage).  Timing at 42 MHz is not a concern: the longest path
is a 9x17 multiply plus the 13-bit normalised compare, and the pipeline
registers break the word stream.

## Known limitations

* **No vertical erosion.**  A one-pixel-tall horizontal streak of length >= 3
  survives, and isolated single-pixel noise on a vertical edge is not removed.
  Compose with the 3x3 tier for full 2-D rejection.
* **Fixed boxes, not adaptive thresholds.**  The four centres are saturated
  RGBY references; a real scene under the panel's lighting needs the tolerance
  and minimum luminance calibrated, and the centres are a compile-time table.
  This is a tracker/demo, not a colour constancy algorithm.
* **Erosion shrinks the reported box.**  The box is the box of the eroded mask,
  so an interior run loses one pixel on each side; a left-edge run keeps
  `xmin=0` by duplication.  This is intentional but must be remembered when
  comparing against a reference annotation.
* **Label priority.**  Overlapping boxes resolve to the lowest label, so a
  large tolerance can make one colour absorb another.
* **Coordinate range.**  x is 10 bits (0..799) and y is 10 bits (0..479); the
  stage is sized for the 800 x 480 panel.  The stat width/height fields
  saturate at 255.
* **Report needs blanking.**  The four-cycle merge runs after the last word of
  the frame and assumes the next frame tag is at least ~6 clocks later.  The
  camera's vertical blanking is many lines, so this is safe; a source with no
  blanking at all would overrun the merge.
* **No per-label pixel count or centroid**, only the box; adding a count is
  another 4 x 16 bits in the same lane RAMs.
* **The knob changes label meaning.**  The PS must read `knob[1:0]` to know
  which colour is label 0 when it interprets `stat`.

## Integration

The slot is `sel = 4`, i.e. the fourth populated stage, so `NUM_STAGES` becomes
4 and `seg_*` occupies the top 64-bit / 32-bit slice of the flattened mux
inputs.  In `rtl/ov5640_top.v`, replace the single-stage block with:

```verilog
    // =========================================================================
    //  Processing stage slot (camera PCLK domain)
    // =========================================================================
    //  Slots 1..3 are the other tiers' stages: replace st1_*..st3_* with their
    //  instances.  Slot 4 is the segmentation stage (sel = 4).
    wire [63:0] st1_data, st2_data, st3_data;
    wire        st1_valid, st2_valid, st3_valid;
    wire        st1_sof, st2_sof, st3_sof;
    wire        st1_eol, st2_eol, st3_eol;
    wire [31:0] st1_stat, st2_stat, st3_stat;

    wire [63:0] seg_data;
    wire        seg_valid, seg_sof, seg_eol;
    wire [31:0] seg_stat;
    wire [15:0] stage_param;
    wire [ 7:0] stage_knob;

    stage_seg #(
        .WORDS_PER_LINE(WORDS_PER_LINE),   // H_ACTIVE / 4 = 200
        .LINES         (V_ACTIVE)          // 480
    ) u_stage_seg (
        .clk    (cam_pclk),
        .rst_n  (cam_rst_n),
        .s_data (cam_word),
        .s_valid(cam_word_valid),
        .s_sof  (cam_word_first),
        .s_eol  (cam_weol),
        .m_data (seg_data),
        .m_valid(seg_valid),
        .m_sof  (seg_sof),
        .m_eol  (seg_eol),
        .param  (stage_param),
        .knob   (stage_knob),
        .stat   (seg_stat)
    );

    stage_mux #(
        .NUM_STAGES(4)
    ) u_stage_mux (
        .clk       (cam_pclk),
        .rst_n     (cam_rst_n),
        .s_data    (cam_word),
        .s_valid   (cam_word_valid),
        .s_sof     (cam_word_first),
        .s_eol     (cam_weol),
        // slot k-1 carries stage k; the segmentation stage is slot 3 (sel = 4)
        .st_data   ({seg_data,  st3_data,  st2_data,  st1_data}),
        .st_valid  ({seg_valid, st3_valid, st2_valid, st1_valid}),
        .st_sof    ({seg_sof,   st3_sof,   st2_sof,   st1_sof}),
        .st_eol    ({seg_eol,   st3_eol,   st2_eol,   st1_eol}),
        .st_stat   ({seg_stat,  st3_stat,  st2_stat,  st1_stat}),
        .sel       (ctrl[4:2]),
        .param     (ctrl[31:16]),
        .knob      ({5'd0, ctrl[7:5]}),
        .clk_ctrl  (clk50),
        .rst_ctrl_n(sys_rst_n),
        .m_data    (stage_word),
        .m_valid   (stage_valid),
        .m_sof     (stage_sof),
        .m_eol     (stage_eol),
        .s_param   (stage_param),
        .s_knob    (stage_knob),
        .stat      (stage_stat)
    );
```

The `st1_*`..`st3_*` declarations are placeholders for the sibling tiers; if a
slot is not populated, either tie its data/valid/sof/eol/stat to the raw stream
and zero, or leave `NUM_STAGES` at that slot and drop the upper concatenation
entries.  `stage_word`, `stage_valid`, `stage_sof`, `stage_eol` and
`stage_stat` are the names already used by the FIFO write side.

In `ps/app/main.c` (not modified by this tier):

* the table is already sized `NUM_STAGES 8`, so just change `stage_name[4]` from
  `"stage 4"` to `"segment"` (the entry that `s` selects when `ctrl[4:2] == 4`);
* `ctrl[4:2]` already selects the stage, so `s` cycles to it;
* `ctrl[7:5]` is the 3-bit knob, so `k` cycles it 0..7.  `k & 3` is the label
  rotation and `k & 4` turns paint on (0..3 pass through, 4..7 paint);
* `+`/`-` change `param`; `0x1008` is a sensible starting point (minimum
  luminance 16, tolerance 8).  The current single key steps the whole 16-bit
  word, so a future improvement is separate keys for the low and high bytes.

### Console key and PS print

Suggested key: **`g`** (free, "geometry") for a decoded one-line box report.
Add to `print_help()` and `console_poll()`:

```c
/* help */
xil_printf("  g   print the segmentation boxes\r\n");

/* console_poll() */
case 'g':
{
    u32 s = status_ext();
    unsigned n  =  s        & 0xFFu;   /* non-empty labels            */
    unsigned w  = (s >>  8) & 0xFFu;   /* label-0 width, pixels       */
    unsigned h  = (s >> 16) & 0xFFu;   /* label-0 height, pixels      */
    unsigned cx = (s >> 24) & 0xFFu;   /* label-0 centre x / 4        */
    static const char *const box[4] = { "red", "green", "blue", "yellow" };

    xil_printf("seg: labels=%u, label0=%s box %ux%u centre_x=%u\r\n",
               n, box[knob & 3], w, h, cx * 4u);
    break;
}
```

`knob & 3` is the rotation, so the printed colour name is the colour that
label 0 currently represents.  The existing `i` status line already prints
`stat=0x%08X`; the four bytes decode as the table in the Statistic section.

## Verification

`sim/tb_stage_seg.v` uses `WORDS_PER_LINE=8`, `LINES=8`, three frames and a
32 x 8 scene.  It checks, word by word:

* pass-through mode is bit identical to the source for the two pass-through
  frames, including the four pixels inside every word;
* paint mode replaces the eroded label-0 pixels with the flat colour and leaves
  the background untouched;
* `m_sof` is on word 0 and `m_eol` on the last word of every line, and every
  frame has exactly 64 words;
* the reported boxes are the exact post-erosion boxes: frame 0's red rectangle
  touches the left and top edges (`xmin=0`, `ymin=0`, `xmax=2` after the right
  edge is eroded), frame 1's single red and blue noise pixels are removed, and
  frame 2's near-red rectangle is painted at columns 6..7 only;
* `stat` matches the encoded width, height, centre and label count for every
  frame, and the report is still the previous frame while the next frame is
  being driven.

Commands (from the worktree root):

```
cd sim
$env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH
xvlog.bat ..\rtl\img_geom.v ..\rtl\stage_mux.v ..\rtl\stage_seg.v tb_stage_seg.v
xelab.bat -debug typical tb_stage_seg -s tb_seg
xsim.bat tb_seg -runall
```

The testbench ends with `TEST PASS`.  The full regression
`powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1` discovers
`tb_stage_seg` automatically and ends with `all simulations passed`.
