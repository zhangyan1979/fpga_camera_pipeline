# stage_win3x3 — 3×3 window filters

Camera-side processing stage for the ACZ702 pipeline.  It consumes the packed
64-bit camera words (four RGB565 pixels, pixel 0 in bits [15:0]) and returns the
3×3-filtered words with the frame and line tags delayed by the same number of
words.  Stage slot `sel = 2`.

| Item | Value |
|---|---|
| File | `rtl/stage_win3x3.v` |
| Module | `stage_win3x3` |
| Parameter | `WORDS_PER_LINE` — 200 in the camera pipeline (the default), 8 in the testbench |
| Clock domain | `cam_pclk` (≈ 42 MHz), asynchronous active-low reset |
| Throughput | one word every eight clocks (all eight phases are used) |
| Latency | **2·WORDS_PER_LINE + 4 words** — 404 words = two lines + four words at 200 words/line |
| Storage | 3 × BRAM36 (one per cached row; a 66-bit word does not fit a RAMB18 port) |
| Border policy | **clamp / duplicate** on all four sides |

The window for the four pixels of a word covers input columns `4x-1 … 4x+4`
(one pixel before the word, one after), and the output is delayed by two whole
rows.  Both of those facts drive the architecture below.

## 1. Architecture

### 1.1 Three line buffers, not two

The stage emits output row `y` while input row `y+2` is arriving.  That row
`y+2` must not overwrite the rows the window still needs: the window is
`y-1, y, y+1`, so three rows have to be live at once.  The buffer that holds
`y-1` is the one being overwritten by `y+2`; it is read in phases 0 and 1 and
written in phase 2, so the read always sees the old row `y-1`.

```
     line buffers (each WORDS_PER_LINE × 66 bit)
     +-------------+-------------+-------------+
     |  row n-3    |  row n-2    |  row n-1    |   <- at input row n
     |  (top)      |  (middle)   |  (bottom)   |
     +-------------+-------------+-------------+
           ^ read then overwritten          ^ read        ^ read
           with row n
                         output row n-2, three rows y-1,y,y+1
```

With only two buffers and the current input row, the middle of the three
available rows is `y+1`, which gives a one-line latency.  Two whole lines of
latency, as required by the tier contract, therefore need three rows of cache:
2 × BRAM would be a one-line design.  A 66-bit word is wider than a RAMB18
port (36 bits), so each cached row is one RAMB36 in 256 × 72 mode and the stage
costs 3 BRAM36 tiles.

The ring index `wr` advances once per input line and is **not** reset at a frame
tag, so the three-buffer rotation continues across the frame boundary; that is
what lets the last two rows of frame *k* be produced from the first rows of
frame *k+1*.  The border clamp then hides the rows that do not exist.

### 1.2 Word granularity and the three-stage pixel pipeline

Each line buffer stores `{sof, eol, 4 pixels}` (66 bits).  The tags live in the
same words as the pixels, so they cannot drift from the data.

A word arrives every eight `cam_pclk` cycles.  The address/setup work uses the
first three cycles; the four pixels then pass through three arithmetic stages,
one pixel per cycle, overlapping (P1 of pixel *p+1* runs while P2 of pixel *p*
and P3 of pixel *p−1* run):

| Phase | Action |
|---|---|
| 0 (the `s_valid` cycle) | drive the line-buffer read address `wx` |
| 1 | register the three row words at `x`, register their `sof`/`eol`, launch the read at `x+1` |
| 2 | assemble the six-pixel spans, reload the carries, write word `x` back, evaluate **P1(pixel 0)** |
| 3 | **P2(pixel 0)** and **P1(pixel 1)** |
| 4 | **P3(pixel 0)**, **P2(pixel 1)**, **P1(pixel 2)** |
| 5 | **P3(pixel 1)**, **P2(pixel 2)**, **P1(pixel 3)** |
| 6 | **P3(pixel 2)**, **P2(pixel 3)** |
| 7 | **P3(pixel 3)**; assemble the output word, the statistic and the line ring |

| Stage | Work |
|---|---|
| P1 | window select, channel widening, the three 9-value sums, the nine luminance values, and comparators 1…12 of the 19-comparator median network |
| P2 | the box-mean product `sum × 57`, comparators 13…19 of the median, min/max (the compare-exchange preserves the multiset), and the Sobel gradients and magnitude |
| P3 | mean shift + signed bias + clamp, sharpen `5·I − 4·blur`, Sobel gate, mode mux, RGB565 packing, and the per-pixel changed/above flags |

Every combinational cone is bounded by pipeline registers, so no datapath
reaches across more than one phase.  The sorting network still exists **once**
per channel, not four times per word, and the 32-bit statistic accumulator only
ever sees registered per-pixel flags: one 3-bit sum and one 16-bit saturating
add per word.

The buffers are addressed by the word column `wx` produced by `img_geom` on the
*input* stream.  `wx` holds while `valid` is low, so horizontal blanking simply
stops the sequencer and cannot move the write pointer.  The output tags are not
regenerated with a second `img_geom`: they were written into the buffer with the
pixels and are read back from the middle row, which is exactly "the tag delayed
by the same number of words as the data".

### 1.3 Output alignment

The computed word goes through a four-slot `{sof, eol, data}` shift register
clocked once per completed word.  This adds exactly four *words* of latency
(independent of blanking gaps) and keeps the tags in the same slot as the data.
`m_valid` is asserted from the same word-done pulse, so `m_data`, `m_valid`,
`m_sof` and `m_eol` always describe the same word.

## 2. Border policy — clamp / duplicate

Every out-of-frame neighbour repeats the nearest edge pixel:

```
row -1  = row 0        column -1  = column 0
row  H  = row H-1      column  W  = column W-1
```

A 3×3 window in a corner is therefore the corner pixel repeated nine times.
There is no constant extension and no mirroring.

Implementation:

* `x = 0` → the left neighbour is pixel 0 of the same word (`{p0,p0}` in the
  carry instead of the previous word's tail);
* `x = WORDS_PER_LINE-1` → the right neighbour is pixel 3 of the same word
  (look-ahead `p4` replaced by `p3`);
* output row 0 → the top row of the window is the middle row;
* output row `H-1` → the bottom row of the window is the middle row.

The last condition needs no knowledge of `H`.  The stage uses the `img_geom`
line index `wy` of the input word, which is the row two lines ahead of the
output row:

* `wy == 1` (input line 1 of a new frame) means the *bottom* row of the window
  is line 0 of that new frame, so the row being emitted is the previous frame's
  last row — clamp the bottom;
* `wy == 2` (input line 2) means the *middle* row of the window is line 0, so
  the row being emitted is row 0 — clamp the top.

This works for any frame height and needs no `V_ACTIVE` parameter.

## 3. Latency

| Contribution | Words |
|---|---|
| row buffers (output row `y` while input row `y+2` arrives) | 2 · `WORDS_PER_LINE` = 400 |
| output alignment register | 4 |
| **total** | **404** (two lines + four words) |

For the testbench geometry (8 words per line) the measured value is
`2·8 + 4 = 20` words; the testbench checks it exactly.  The latency in lines is
2.02 lines.  Data, `valid`, `sof` and `eol` all travel through the same buffer
words and the same alignment slots, so they are delayed together.

## 4. Modes and arithmetic

`knob[2:0]` selects the mode; `knob[7:3]` is ignored.  All three channels are
processed identically.  RGB565 channels are widened to 8 bits before averaging
or filtering, and narrowed again on output:

```
R8 = {R5, R5[4:2]}      G8 = {G6, G6[5:4]}      B8 = {B5, B5[4:2]}
R5 = R8[7:3]            G6 = G8[7:2]            B5 = B8[7:3]
```

Widening by bit replication makes 31/63 map to 255/255, so a white pixel stays
white.  Rank filters (median, erode, dilate) are monotonic under this widening,
so computing on the widened values and narrowing is the same as filtering the
native 5/6/5 codes.

### Mode 0 — 3×3 box mean (modes 6 and 7 behave identically)

```
sum   = Σ9 channel8                          (12 bits, 0…2295)
mean  = (sum × 57) >> 9
out   = clamp(mean + signed(param[7:0]), 0, 255)
```

`57/512 = 0.111328125` approximates `1/9 = 0.111…`.  It is **exact for every
sum that is a multiple of 9** (sum = 9k, k ≤ 255: `513k >> 9 = k`), because
`k + k/512 < k+1`.  For other sums it is the nearest fixed-point value, at most
one LSB away from the true mean; the result is never above 255 and never
negative.  Using `(sum*57)>>9` instead of a divider costs three constant
multiplies and no DSP unless the tool chooses to map them.

`param[7:0]` is a **signed** bias (two's complement) added after the mean:
`0x0010` is +16, `0x00F8` is −8.  The sum is clamped to 0…255, so a negative
bias crushes dark areas to black and a positive one clips to white.  Modes 6
and 7 are reserved and behave exactly like mode 0 (bias included).

### Mode 1 — Sobel magnitude on luminance

```
Y   = (77·R8 + 150·G8 + 29·B8 + 128) >> 8          Rec.601 weights (sum 256)
Gx  = (Y_tr + 2·Y_mr + Y_br) − (Y_tl + 2·Y_ml + Y_bl)
Gy  = (Y_bl + 2·Y_bc + Y_br) − (Y_tl + 2·Y_tc + Y_tr)
mag = |Gx| + |Gy|                                  0…2040
```

`|Gx| + |Gy|` (the 1-norm) is used instead of `√(Gx²+Gy²)`: no square root and
no DSP, and for edge display the difference is only the diagonal response.
`param` is a **threshold**: a pixel is "above" when `mag > param` (unsigned
16-bit compare; `mag` can never exceed 2040, so any `param` above 2040 makes the
whole map black).  `param` acts as a noise gate:

```
out8  = min(mag, 255)
pixel = (mag > param) ? {out8[7:3], out8[7:2], out8[7:3]}
                      : 16'h0000
```

so the result is a grey edge map on a black background.  The same `mag > param`
condition drives `stat[31:16]`.  In every other mode `stat[31:16]` counts
nothing and stays 0.

### Mode 2 — 3×3 median

Per channel, the median of the nine widened 8-bit values.  It is computed with
the 19-comparator Smith network (the one used in the XC4000E application note),
which is less than a full sort.  The network is instantiated once per channel
and split across the pipeline: comparators 1…12 run in P1 and 13…19 in P2.  The
network was checked against a full sort for 200 000 random 9-tuples before it
was committed, and the testbench's reference model uses a bubble sort rather
than the same network, so a tapping error cannot hide.

### Mode 3 — erode (minimum) and mode 4 — dilate (maximum)

Per channel, `min` / `max` of the nine neighbours, built as a tree of eight
comparators.  For a 3×3 structuring element erode removes bright specks on a
dark background and dilate removes dark holes, which is the usual introduction
to morphology.

### Mode 5 — sharpen

```
blur = (Σ9 channel8 × 57) >> 9          same box mean as mode 0, no bias
out  = clamp(5·I − 4·blur, 0, 255)      I = centre pixel, channel8
```

This is the unsharp-mask form `I + 4·(I − blur)`: flat areas are unchanged,
edges are amplified, and the clamp stops the 14-bit intermediate from wrapping.
The mean is shared with mode 0, so the extra cost over the box filter is three
subtractions and three clamps.

### `param`

| Mode | Meaning |
|---|---|
| 0, 6, 7 | signed bias added to every mean channel, `param[7:0]` |
| 1 | edge threshold against `|Gx|+|Gy|` |
| 2, 3, 4, 5 | ignored |

## 5. `stat[31:0]`

The statistic is updated when the stage computes its own frame-tag word (four
words before that tag is emitted): it latches the totals of the frame that has
just finished and starts the new frame's counters.

| Bits | Meaning |
|---|---|
| `[31:16]` | pixels whose Sobel magnitude exceeded `param` — mode 1 only, 0 in all other modes |
| `[15:0]` | pixels whose filtered RGB565 differs from the centre input pixel, all modes |

Both fields saturate at `16'hFFFF` (a frame has 384 000 pixels, so saturation is
reachable and is part of the definition).  `stage_mux` samples `stat` once per
offered frame tag while the stage is still two lines behind, so the console
normally displays the statistic of the frame that has just left the stage, which
is the frame the picture being displayed was built from.

## 6. Resource use and timing (measured)

Synthesis, place and route: Vivado 2023.2, `xc7z020clg400-1`, full four-stage
design (`ps/build_hw.tcl`, `impl_1` routed), instance
`design_1_i/cam_top_0/inst/u_stage_win3x3`.

| Resource | This stage | Whole design |
|---|---|---|
| Slice LUTs | **3 227** (3 162 logic + 65 SRL) | 15 269 (28.70 %) |
| Slice registers | **1 209** | 24 144 (22.69 %) |
| Block RAM | **3 × RAMB36** | 4 tiles (3 RAMB36 + 2 RAMB18) |
| DSP48E1 | **3** | 12 |

A 66-bit-wide, 200-deep row does not fit in a RAMB18: the widest RAMB18 port is
36 bits.  Each row is therefore one RAMB36 in 256 × 72 mode, and the three rows
cost three RAMB36 tiles.  (The first estimate of 1.5 tiles assumed a 64-bit word
could be packed into an 18 Kb block; the tool correctly uses a 36 Kb block.)
The three DSP48s come from the constant multiplications in the datapath; the
rest of the luma and sharpen arithmetic was mapped to LUT logic.

| Timing | Value |
|---|---|
| camera_pclk WNS / WHS | **+4.174 ns / +0.028 ns** (42 MHz, 23.810 ns period) |
| whole design WNS / WHS | +2.495 ns / +0.021 ns |
| camera_pclk failing endpoints | **0** of 23 941 |

The worst camera_pclk path is now in `u_stage_hist` (the tier-3 stage), not
here: every path in this stage has at least 4.17 ns of setup margin.  The
whole-design WNS is a control-to-FIFO path (`axi_gpio_ctrl` → `u_disp_fifo`),
also unrelated to this stage.  Before the pipeline split the stage alone had
WNS −8.331 ns, TNS −338.6 ns and 99 failing endpoints, all through the
9-way-sum / `×57` / statistic chain.

The cost is spread across the three pipeline stages (P1 sums, luma and the
first half of the median; P2 the product, the second half, min/max and the
gradients; P3 mean, sharpen, mode mux and packing).  Every mode is built because
`knob` is a runtime control.  The table below is the incremental estimate of
what each mode contributes to the measured total of 3 227 LUTs:

| Mode block | Approx. LUTs | Note |
|---|---|---|
| shared control, buffer muxes, 6-pixel span muxes, output aligner, statistic | ~900 | 3 BRAM36 for the rows |
| mode 0 / 6 / 7 box mean | ~370 | 3 sum trees, 3 constant ×57, bias + clamp |
| mode 1 Sobel | ~540 | 9 lumas, gradients, magnitude, gate |
| mode 2 median | ~900 | 3 channels × 19 comparators, split P1/P2 |
| mode 3 erode | ~190 | 3 channels × 8 comparators |
| mode 4 dilate | ~190 | 3 channels × 8 comparators |
| mode 5 sharpen | ~150 | reuses the mode-0 mean |

## 7. Why the 2-pixel (32-bit) carry exists

The window for output word `x` needs input columns `4x-1 … 4x+4`: six pixels per
row.  Four of them are the current word, one is pixel 0 of the **next** word
(the right neighbour of `p3`) and one is pixel 3 of the **previous** word (the
left neighbour of `p0`).  Per row the stage therefore keeps a 32-bit carry — the
previous word's upper half, pixels 2 and 3 — and uses its high pixel
`carry[31:16]` as column `4x-1`.

The off-by-two trap is a one-word shift of that carry:

* consume the carry in phase 2 (P1 of pixel 0 reads the spans before they are
  registered), **then** reload it from the word just read at the same clock
  edge; reloading one phase earlier (or in phase 1) makes the whole window one
  pixel wider to the left on every word;
* the left neighbour is pixel **3** of the previous word (`carry[31:16]`), not
  pixel 2; using the low half shifts the image by one pixel;
* at `x = 0` the carry must be the clamp `{p0,p0}`, not the previous line's last
  word, or the left border of every line shows the right edge of the previous
  line;
* at `x = WORDS_PER_LINE-1` the look-ahead `p4` is pixel 3 of the same word, not
  pixel 0 of the next line (the read address wraps).

Keeping two pixels rather than one is the natural 32-bit slice of the 64-bit
word and makes the span a uniform `{p4, p3, p2, p1, p0, p-1}` mux; only
`carry[31:16]` participates in the 3×3.

## 8. Integration into `rtl/ov5640_top.v`

The slot is `sel = 2`, so `stage_mux` needs `NUM_STAGES = 4` and this stage sits
in bits 2·64 … 2·64+63 of the flattened buses.  Replace the existing
single-stage block (`u_stage_mux`, around lines 232-266 of the current file)
with:

```verilog
    // =====================================================================
    //  Processing stage slots (camera PCLK domain)
    // =====================================================================
    //  slot 1  tier 2  point operation          sel = 1
    //  slot 2  tier 1  3x3 window filters       sel = 2   <- this module
    //  slot 3  tier 3  histogram                sel = 3
    //  slot 4  tier 4  segmentation             sel = 4
    wire [15:0] st_param;
    wire [ 7:0] st_knob;

    wire [63:0] st1_data, st2_data, st3_data, st4_data;
    wire        st1_valid, st2_valid, st3_valid, st4_valid;
    wire        st1_sof,   st2_sof,   st3_sof,   st4_sof;
    wire        st1_eol,   st2_eol,   st3_eol,   st4_eol;
    wire [31:0] st1_stat,  st2_stat,  st3_stat,  st4_stat;

    // ---- slot 1: tier 2, point operation (placeholder module name) ------
    // stage_lut #(...) u_stage1 (
    //     .clk(cam_pclk), .rst_n(cam_rst_n),
    //     .s_data(cam_word), .s_valid(cam_word_valid),
    //     .s_sof(cam_word_first), .s_eol(cam_weol),
    //     .m_data(st1_data), .m_valid(st1_valid),
    //     .m_sof(st1_sof), .m_eol(st1_eol),
    //     .param(st_param), .knob(st_knob), .stat(st1_stat)
    // );

    // ---- slot 2: tier 1, 3x3 window filters -----------------------------
    stage_win3x3 #(
        .WORDS_PER_LINE(WORDS_PER_LINE)
    ) u_stage2 (
        .clk    (cam_pclk),
        .rst_n  (cam_rst_n),
        .s_data (cam_word),
        .s_valid(cam_word_valid),
        .s_sof  (cam_word_first),
        .s_eol  (cam_weol),
        .m_data (st2_data),
        .m_valid(st2_valid),
        .m_sof  (st2_sof),
        .m_eol  (st2_eol),
        .param  (st_param),
        .knob   (st_knob),
        .stat   (st2_stat)
    );

    // ---- slot 3: tier 3, histogram (placeholder module name) ------------
    // stage_hist #(...) u_stage3 (
    //     .clk(cam_pclk), .rst_n(cam_rst_n),
    //     .s_data(cam_word), .s_valid(cam_word_valid),
    //     .s_sof(cam_word_first), .s_eol(cam_weol),
    //     .m_data(st3_data), .m_valid(st3_valid),
    //     .m_sof(st3_sof), .m_eol(st3_eol),
    //     .param(st_param), .knob(st_knob), .stat(st3_stat)
    // );

    // ---- slot 4: tier 4, segmentation (placeholder module name) ---------
    // stage_seg #(...) u_stage4 (
    //     .clk(cam_pclk), .rst_n(cam_rst_n),
    //     .s_data(cam_word), .s_valid(cam_word_valid),
    //     .s_sof(cam_word_first), .s_eol(cam_weol),
    //     .m_data(st4_data), .m_valid(st4_valid),
    //     .m_sof(st4_sof), .m_eol(st4_eol),
    //     .param(st_param), .knob(st_knob), .stat(st4_stat)
    // );

    stage_mux #(
        .NUM_STAGES(4)
    ) u_stage_mux (
        .clk       (cam_pclk),
        .rst_n     (cam_rst_n),
        .s_data    (cam_word),
        .s_valid   (cam_word_valid),
        .s_sof     (cam_word_first),
        .s_eol     (cam_weol),
        // slot k-1 occupies bits (k-1)*64 +: 64 (and 32 for st_stat)
        .st_data   ({st4_data,  st3_data,  st2_data,  st1_data }),
        .st_valid  ({st4_valid, st3_valid, st2_valid, st1_valid}),
        .st_sof    ({st4_sof,   st3_sof,   st2_sof,   st1_sof  }),
        .st_eol    ({st4_eol,   st3_eol,   st2_eol,   st1_eol  }),
        .st_stat   ({st4_stat,  st3_stat,  st2_stat,  st1_stat }),
        .sel       (ctrl[4:2]),
        .param     (ctrl[31:16]),
        .knob      ({5'd0, ctrl[7:5]}),
        .clk_ctrl  (clk50),
        .rst_ctrl_n(sys_rst_n),
        .m_data    (stage_word),
        .m_valid   (stage_valid),
        .m_sof     (stage_sof),
        .m_eol     (stage_eol),
        .s_param   (st_param),
        .s_knob    (st_knob),
        .stat      (stage_stat)
    );
```

Notes on the snippet:

* `WORDS_PER_LINE` already exists in `ov5640_top.v` as `H_ACTIVE / 4` (200);
  pass it so the stage geometry matches the camera.
* `st_data`, `st_valid`, `st_sof`, `st_eol` and `st_stat` are concatenated
  **slot 4 first, slot 1 last** — `stage_mux` indexes `k-1` from the LSB.  The
  order matters; swapping two slots selects the wrong stage.
* `st_param` / `st_knob` must be fanned out to every stage.  They are
  frame-stable and re-latched by `stage_mux` on the emitted frame tag, so a
  stage may use them directly.
* The other three slots are the sibling tiers' modules.  Until a tier lands,
  leave that slot tied off (e.g. `assign stN_data = cam_word; assign
  stN_valid = 1'b0;` and lower `NUM_STAGES` to the highest populated slot), so
  the frame-buffer path stays safe.
* `ctrl[4:2] = 2` selects this stage; `ctrl[7:5]` is the mode; `ctrl[31:16]` is
  `param`.

### Console

The slot's name in `ps/app/main.c` is `stage_name[2]`; change the entry from
`"stage 2"` to:

```c
    "win3x3",
```

No new key is needed — the existing console already drives it: `s` cycles the
selected stage (press twice from bypass to reach slot 2) and `k` cycles
`knob[2:0]` through the eight modes, showing `stage win3x3 mode N`.  If a
dedicated jump key is wanted, `w` is unused in `main.c` and is the natural
choice.  The 1 Hz status line prints `stat` as `stat=0x%08X`.

## 9. Verification

Self-checking testbench: `sim/tb_stage_win3x3.v`, discovered automatically by
`sim/run_sim.ps1`.

### What it proves

* nine `(mode, param)` groups — box mean with a positive and a negative bias,
  Sobel with a threshold, median, erode, dilate, sharpen, and modes 6/7 as box —
  each with three input frames;
* word-by-word comparison against an array reference model with the same
  clamp/duplicate border policy and the same fixed-point arithmetic, for two
  complete output frames per group (384 pixels per group, 3 456 pixels total);
* interior and border pixels counted and reported separately;
* `m_sof` on the first word of each frame and nowhere else;
* `m_eol` on the last word of each line and nowhere else;
* exactly `WORDS_PER_LINE × LINES = 48` words between frame tags;
* `stat` equal to the reference counts of the frame that just finished
  (including 0 before the first tag);
* the advertised latency of two lines + four words (measured 20 words at 8
  words/line);
* the geometry wraps every 8 words and lines are separated by a 3-clock
  blanking gap, so a free-running write pointer or an off-by-one row index
  fails immediately.

The reference model deliberately uses a bubble sort for the median, and loops
for min/max, rather than the RTL's network, so a network or tap error cannot be
mirrored.  Two temporary mutations were run against the final bench as a
sanity check: breaking the `x = 0` carry clamp produced border failures on every
first word of a line, and returning `p3` instead of `p4` from the median network
failed mode 2 only.

### Running it

```powershell
cd sim
$env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH
xvlog.bat ..\rtl\img_geom.v ..\rtl\stage_mux.v ..\rtl\stage_win3x3.v tb_stage_win3x3.v
xelab.bat -debug typical tb_stage_win3x3 -s tb_win
xsim.bat tb_win -runall
```

```
mode 0 param 0010: interior 240 ok / 0 bad, border 144 ok / 0 bad, frames 2, latency 20 words
...
groups=9 pixel mismatches=0 other errors=0
TEST PASS
```

and the full suite from the worktree root:

```powershell
powershell -ExecutionPolicy Bypass -File sim/run_sim.ps1
```

ends with `all simulations passed`.

### Limits

* The stage assumes the contract's one word per eight `cam_pclk` cycles and uses
  all eight phases.  A source that presented two words closer than eight clocks
  would need a fourth pipeline lane (or a wider parallel network) rather than
  the overlapped P1/P2/P3 schedule.
* Synthesis, place and route were run on the full four-stage design after this
  change: `IMPL STATUS: write_bitstream Complete!`, camera_pclk WNS +4.174 ns,
  whole-design WNS +2.495 ns, WHS +0.021 ns (see section 6).
