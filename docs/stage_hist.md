# stage_hist — streaming histogram, equalisation and automatic exposure

`rtl/stage_hist.v` is a `stage_mux` slot (Bailey 2e, chapter 8: 8.1.1 histogram,
8.1.3 equalisation, 8.1.4 automatic exposure).  It measures the luminance
histogram of every frame, derives the mean, the 99th percentile and the
saturated-pixel fraction, and can either pass the picture through or replace it
with the histogram-equalised grey image built from the *previous* frame.

Everything runs in the camera pixel clock domain.  Four RGB565 pixels arrive in
one 64-bit word (pixel 0 in `[15:0]`), one word every eight `cam_pclk` cycles, so
the stage has eight clocks per word and uses five of them: one accepting clock
plus four accumulator phases.  It never stalls and never adds or drops a word.

| file | contents |
|---|---|
| `rtl/stage_hist.v` | the stage |
| `sim/tb_stage_hist.v` | self-checking testbench, ends in `TEST PASS` |
| this file | design notes and integration |

## Interface

```verilog
module stage_hist #(
    parameter integer WORDS_PER_LINE = 200,
    parameter integer LINES          = 480
) (
    input  wire        clk,         // cam_pclk
    input  wire        rst_n,
    input  wire [63:0] s_data, s_valid, s_sof, s_eol,
    output reg  [63:0] m_data,
    output reg         m_valid, m_sof, m_eol,
    input  wire [15:0] param,
    input  wire [ 7:0] knob,
    output wire [31:0] stat
);
```

`LINES` is the frame height; together with `WORDS_PER_LINE` it is the only
extra information the stage needs, because the end of a frame is detected from
`s_eol` and the line count (the stage contract fixes the geometry at
200 words x 480 lines = 96 000 words).  For the real camera instantiate it with
`.WORDS_PER_LINE(200), .LINES(480)`.

### Latency

The pipeline is **five clocks**: the accepting clock plus the four accumulator
phases.  The data, `m_valid`, `m_sof` and `m_eol` all travel through that same
five-stage pipeline, so the tags cannot drift off the word they belong to.  A
word arrives every eight clocks, so the stage is always less than one word
behind; measured in words on the real stream the latency is "the previous
word".  The stage relies on the eight-clock word period (five clocks cannot be
compressed into fewer without a second accumulator); a gapless one-word-per-
clock stream cannot be accumulated by a single 256 x 16 BRAM.

## Modes: `knob[2:0]`

| `knob[2:0]` | mode | output pixels | what is reported |
|---|---|---|---|
| 0 | pass-through + histogram | bit-exact copy of the input | everything |
| 1 | histogram equalisation | greyscale `map[Y]` of the previous frame | everything |
| 2 | auto-exposure, report only | bit-exact copy of the input | `stat[7:0]` = measured 99th percentile |
| 3..7 | reserved | behaves as mode 0 | everything |

`knob` and `param` are latched on the *input* frame tag, so a control write
cannot split a frame.  A change takes effect on the frame that follows the tag;
`stage_mux` re-latches its own copy on the *emitted* tag, so the practical
effect is that a control write lands one frame later.

### `param[15:0]`

* **mode 1** — `param[7:0]` is the equalisation **strength**: 0 keeps the
  luminance (`map[b] = b`, the output is still greyscale), 255 is the full
  cumulative mapping.  `param[15:8]` is unused.  Set `param` before switching to
  mode 1: the map used during frame N is built at the end of frame N-1 with the
  parameter latched for frame N-1.
* **mode 2** — `param[7:0]` is the **target 99th percentile** (suggested
  default 252).  The hardware does not interpret it: mode 2 only *reports* the
  measured percentile, and the PS compares the two and moves the sensor's
  exposure.  That keeps the dead band and the control law on the PS side.
* modes 0 and 3..7 ignore `param`.

### `stat[31:0]`

Sampled once per frame by `stage_mux`; it always describes the frame that just
finished (so the value at frame N's tag is frame N-1's statistic).

| bits | field | meaning |
|---|---|---|
| `[7:0]` | **p99** | 99th-percentile luminance of the frame (0..250 with this Y formula) |
| `[15:8]` | **mean** | `floor(sum(Y) / 384000)` for the real 800x480 frame, i.e. 0..255 |
| `[23:16]` | **sat%** | saturated pixels as a percentage of the frame, 0..100 |
| `[31:24]` | **strength** | equalisation strength actually applied to that frame (0 unless mode 1) |

The saturation field deliberately departs from the "count / 1024" suggested in
the brief: a 256-pixel test frame would always report zero with that scaling,
and the percentage is what an exposure loop actually needs (it is also
frame-size independent).  The count is available to the PS by multiplying back
if it ever needs it.

A pixel is **saturated** when `Y >= 250`.  250 is the maximum the luminance
formula produces for RGB565 white, so any pixel at or above it is clipped
white.

## Luminance

```
R5 = d[15:11]   G6 = d[10:5]   B5 = d[4:0]

Y  = (77*R5 + 75*G6 + 29*B5) >> 5      // 0..250, shifts and adds only

   77*R5 = (R5<<6) + (R5<<3) + (R5<<2) + R5
   75*G6 = (G6<<6) + (G6<<3) + (G6<<1) + G6
   29*B5 = (B5<<4) + (B5<<3) + (B5<<2) + B5
```

The weights are the usual Rec.601 77/150/29, folded for 5/6/5 channel widths
(the green channel is one bit wider, so its weight is halved).  The result is
monotonic in every channel and uses no multiplier and no divider.  Pure white
`31/63/31` gives `(2387 + 4725 + 899) >> 5 = 250`, pure black gives 0; the
histogram therefore uses bins 0..250 and the top five bins stay empty.

The same combinational `lum()` is reused for the histogram bin, the
equalisation lookup and the grey output, so the bin and the map index can never
disagree.

## The four-phase accumulator and the read-before-write hazard

One BRAM18 holds the 256 x 16 histogram (simple dual port: one write port, one
registered read port).  One bin is updated per phase, four pixels per word:

| clock | phase | address presented | BRAM read data valid | write committed |
|---|---|---|---|---|
| W   | 0 (accept) | `bin0` | – | – |
| W+1 | 1 | `bin1` | `mem[bin0]` | `bin0 <- mem[bin0] + 1` |
| W+2 | 2 | `bin2` | `mem[bin1]` | `bin1 <- (bin0==bin1 ? d0 : mem[bin1]) + 1` |
| W+3 | 3 | `bin3` | `mem[bin2]` | `bin2 <- ...` |
| W+4 | 4 (flush) | – | `mem[bin3]` | `bin3 <- ...` |

The read data delivered in phase *k* is the count of the bin presented in phase
*k-1*, which is exactly the bin being written in phase *k*.  If the write issued
in phase *k-1* (the bin of pixel *k-2*) targeted the same bin, the BRAM output
is **stale**: the read happened at the same clock edge as the write and returned
the old value.  The stage therefore keeps the write issued in the previous cycle
in `wr_bin_q` / `wr_data_q` and forwards it:

```verilog
wire        fwd  = wr_vld_q && (wr_bin_q == wr_bin);
wire [15:0] base = fwd ? wr_data_q : hist_q;
wire [15:0] wr_acc = (base == 16'hFFFF) ? 16'hFFFF : base + 16'd1;
```

This is the Bailey fig. 8.3 forward path.  It is correct for any run of equal
pixels: the *k*-th pixel of a run leaves its bin at `old + k + 1`, because every
phase forwards the value its predecessor wrote; it does not matter whether the
inferred BRAM is read-first or write-first (the forward value is the same either
way).

`wr_vld_q` is cleared in the accepting phase, so the last write of the previous
word — which was committed long before the next word's phase 0 read — is never
forwarded across the word boundary.  Bins saturate at `16'hFFFF` rather than
wrapping: a frame with more than 65 535 pixels in one bin (a large flat image)
stops counting that bin, which is the standard 16-bit histogram compromise.

The testbench deliberately drives runs of four equal pixels per word and
same-bin values across word boundaries; removing the forward path (a mutation
test) makes the bin counts come out at 33 instead of 64, which the testbench
catches.

## Frame boundary: finalise, clear, swap

After the last word of a frame (detected as `s_eol` on line `LINES-1`) the
accumulator finishes its four phases and the stage enters the finalise scan.
This happens in the vertical blanking, before the next frame tag:

1. **Scan 256 bins**, one per clock, from bin 255 down to 0.  Each bin is read,
   and the clear write of zero goes to the bin read in the *previous* cycle, so
   the read and write addresses always differ and one BRAM port can do both.
   That is 257 clocks.
2. While scanning, accumulate the tail sum (`tail`), the weighted sum (`sum`),
   the percentile decision (`p99`) and the saturated count (`sat_cnt`).
3. **Divide** `sum / TOTAL_PIXELS` for the mean (32 restoring steps), then
   `100 * sat_cnt / TOTAL_PIXELS` for the saturation percentage (32 steps).
4. Latch `stat`, publish the new equalisation map and set `map_valid`.

The whole finalise is about **325 clocks** (257 + 2 x 33), nothing compared
with the camera's vertical blanking (tens of thousands of cam_pclk cycles), and
it happens entirely between the last word of frame N and the first word of
frame N+1.  The histogram memory itself is single-buffered (the one-BRAM18
budget): the "swap" is between the histogram being filled and the *shadow*
copies of its results — `stat` and the map RAM — which are latched at the end of
the finalise.  Consequently:

* frame N is accumulated into the histogram while `stat` and the equalisation
  map still hold frame N-1's results;
* the moment frame N+1 starts, its map (built from frame N) is already in the
  map RAM and `stat` already holds frame N — nothing ever reads a half-built
  histogram, and the PS never sees a mix of two frames;
* if the blanking were ever shorter than the finalise (a contract violation),
  a frame tag during the scan aborts the statistics for that frame but the
  word is still accepted and emitted, so the picture keeps its word count.

Right after reset the histogram is cleared by a 256-clock pass in `S_CLEAR`.
The OV5640 takes milliseconds to configure, so the camera cannot produce a word
during that window; the first frame after reset is still a valid frame, and the
first *map* is published after it.

## Mean, 99th percentile and saturation

The scan walks bins from 255 down to 0 and keeps `tail` = the number of pixels
**above** the bin currently being processed.

**Mean.**  The weighted sum is accumulated without a multiplier, using

```
sum_b b * count[b]  =  sum_{b=0}^{255} tail(b)
```

so each scan cycle simply adds the current `tail` to a 28-bit accumulator
(`sum <= sum + tail`).  At the end `mean = floor(sum / TOTAL_PIXELS)` from the
serial restoring divider: 32 shift-subtract steps against the compile-time
constant `TOTAL_PIXELS`.  The divider is reused for the saturation percentage,
so the frame costs only two divisions.

**99th percentile.**  The smallest bin `b` such that at most 1 % of the frame's
pixels are strictly brighter than `b`:

```
p99 = min { b : 100 * tail(b) <= TOTAL_PIXELS }
```

`tail(b)` is exactly the running tail value before adding `count[b]`, so the
comparison is done in the same scan.  `100*tail` is `(tail<<6)+(tail<<5)+
(tail<<2)` — again shifts and adds.  Scanning downwards means the last bin that
satisfies the inequality is the smallest, so the running assignment
`p99 <= fin_bin` when the condition holds needs no search or sort.  For the
test frame (25 % Y32, 50 % Y128, 25 % Y224) this gives 224, which is exactly
where the cumulative count reaches 99 %.

**Saturation.**  A bin at or above `SAT_Y = 250` is saturated; its count is
added to a 20-bit `sat_cnt` during the same scan, then divided into a
percentage: `sat% = floor(100 * sat_cnt / TOTAL_PIXELS)`.

## Equalisation map and its scaling

The map is built in the same top-down scan.  At bin `b`, the number of pixels at
or below `b` is

```
cum(b) = TOTAL_PIXELS - tail(b)
```

and the full-scale cumulative mapping (0..255) is

```
eq(b) = round(255 * cum(b) / TOTAL_PIXELS)
      = (cum(b) * MAP_MUL + (1<<17)) >> 18
MAP_MUL = round(255 * 2^18 / TOTAL_PIXELS)      // fixed at elaboration
```

For the real frame `MAP_MUL = 174` (an 8-bit constant), so the constant multiply
costs a handful of adders rather than a divider; the rounding term makes
full white land exactly on 255.  For the 8x8 test frame the same expression
degenerates to the exact `round(255*cum/256)`.

The strength blend is

```
map(b) = b + round( ((eq(b) - b) * strength) / 256 ),   strength = param[7:0]
```

which is one signed 10x9 multiply per bin per frame (one DSP or a small
shift-add network).  Strength 0 gives `map(b) = b` (an identity map, the output
is the greyscale luminance); strength 255 gives the full cumulative mapping to
within one LSB of rounding.  Because `cum(b)` is non-decreasing and the blend is
a monotonic interpolation, **`map()` is guaranteed monotonic** — the testbench
checks every one of the 256 entries.

The map RAM is 256 x 8 asynchronous-read distributed RAM (the phase engine reads
it with a combinational address; a BRAM would need an extra pipeline stage).  It
is written once per frame during the finalise scan and read during the frame.
Before the first map has been built, `map_valid` is 0 and the lookup returns the
luminance unchanged, so no uninitialised memory ever reaches the output.

Mode 1 output pixel: `{Y'[7:3], Y'[7:2], Y'[7:3]}` where `Y' = map[Y]`.  It is a
greyscale picture, which is the honest presentation of a single-channel
histogram operation; the colour image is still there in modes 0 and 2.  Mode 1
is a pure point operation, so there is **no border policy** to declare.

## Resource estimate

Hand estimate from the component count (no synthesis was run for the tier — the
brief forbids it).  The numbers are for the real 200 x 480 instantiation.

| resource | estimate | where |
|---|---|---|
| BRAM18 | **1** | 256 x 16 histogram, simple dual port |
| distributed RAM | **32 LUTs** | 256 x 8 equalisation map |
| DSP48E1 | **1** | `(eq - b) * strength`, one bin per frame |
| LUTs | **~600** | phase engine and forward mux (~120), serial divider (~90), scan arithmetic and 100x / MAP_MUL constant multiplies (~180), control/FSM (~80), luminance (~40), map read and grey pack (~40) |
| flip-flops | **~500** | 64-bit input and output words, 32-bit grey accumulator, 3 x 32-bit divider registers, 28+20+20+8 bit statistics, counters, tag pipeline |
| clock domains | 1 | cam_pclk only; no CDC inside the stage |
| latency | 5 clocks | less than one 8-clock word period |

For scale: the whole design currently uses about 14.6 % of the XC7Z020 LUTs, so
this stage is roughly another 1 % of the device, half a BRAM tile and one DSP.

## Integration into `rtl/ov5640_top.v`

The stage's slot is **`sel = 3`**, so `stage_mux` needs `NUM_STAGES = 4`.  The
existing instance in `ov5640_top.v` (currently `NUM_STAGES(1)` with the raw
stream in slot 1) is replaced by the block below.  Slots 1, 2 and 4 are
placeholders for the other tiers: until those stages exist, tie their outputs to
the raw stream so selecting them still shows a picture.

```verilog
    // =========================================================================
    //  Processing stage slots (camera PCLK domain)
    // =========================================================================
    // slot k-1 carries stage k, selected by ctrl[4:2].  The stages run in
    // parallel on the same raw word stream.
    wire [63:0]  st_data_1, st_data_2, st_data_3, st_data_4;
    wire         st_valid_1, st_valid_2, st_valid_3, st_valid_4;
    wire         st_sof_1, st_sof_2, st_sof_3, st_sof_4;
    wire         st_eol_1, st_eol_2, st_eol_3, st_eol_4;
    wire [31:0]  st_stat_1, st_stat_2, st_stat_3, st_stat_4;
    wire [15:0]  st_param;
    wire [ 7:0]  st_knob;

    // ---- slot 1: <LUT point-operation stage> -------------------------------
    //  stage_xyz #(...) u_stage1 ( ... .m_data(st_data_1), ... );
    //  placeholder until that stage exists: the raw stream
    assign st_data_1  = cam_word;
    assign st_valid_1 = cam_word_valid;
    assign st_sof_1   = cam_word_first;
    assign st_eol_1   = cam_weol;
    assign st_stat_1  = 32'd0;

    // ---- slot 2: <3x3 window stage> ----------------------------------------
    assign st_data_2  = cam_word;
    assign st_valid_2 = cam_word_valid;
    assign st_sof_2   = cam_word_first;
    assign st_eol_2   = cam_weol;
    assign st_stat_2  = 32'd0;

    // ---- slot 3: streaming histogram / equalisation / auto exposure --------
    stage_hist #(
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .LINES         (V_ACTIVE)
    ) u_stage3 (
        .clk    (cam_pclk),
        .rst_n  (cam_rst_n),
        .s_data (cam_word),
        .s_valid(cam_word_valid),
        .s_sof  (cam_word_first),
        .s_eol  (cam_weol),
        .m_data (st_data_3),
        .m_valid(st_valid_3),
        .m_sof  (st_sof_3),
        .m_eol  (st_eol_3),
        .param  (st_param),
        .knob   (st_knob),
        .stat   (st_stat_3)
    );

    // ---- slot 4: <tier 4 stage> --------------------------------------------
    assign st_data_4  = cam_word;
    assign st_valid_4 = cam_word_valid;
    assign st_sof_4   = cam_word_first;
    assign st_eol_4   = cam_weol;
    assign st_stat_4  = 32'd0;

    // ---- mux: slot k-1 carries stage k -------------------------------------
    stage_mux #(
        .NUM_STAGES(4)
    ) u_stage_mux (
        .clk       (cam_pclk),
        .rst_n     (cam_rst_n),
        .s_data    (cam_word),
        .s_valid   (cam_word_valid),
        .s_sof     (cam_word_first),
        .s_eol     (cam_weol),
        .st_data   ({st_data_4,  st_data_3,  st_data_2,  st_data_1}),
        .st_valid  ({st_valid_4, st_valid_3, st_valid_2, st_valid_1}),
        .st_sof    ({st_sof_4,   st_sof_3,   st_sof_2,   st_sof_1}),
        .st_eol    ({st_eol_4,   st_eol_3,   st_eol_2,   st_eol_1}),
        .st_stat   ({st_stat_4,  st_stat_3,  st_stat_2,  st_stat_1}),
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

`WORDS_PER_LINE` already exists in `ov5640_top.v` (`H_ACTIVE / 4`), and
`V_ACTIVE` is a module parameter, so no new parameter is needed.

### Console

Give the slot a name in `ps/app/main.c` (`stage_name[3]` — index equals `sel`):

```c
static const char *const stage_name[NUM_STAGES] = {
    "bypass",
    "stage 1",
    "stage 2",
    "histogram",        /* stage 3: histogram + auto exposure */
    "stage 4",
    ...
};
```

Suggested new console key: **`e`** — print the auto-exposure band.  Add it to
`print_help()` and to `console_poll()`:

```c
/* in print_help() */
xil_printf("  e   exposure band (p99 vs target)\r\n");

/* in console_poll() */
case 'e': {
    u32 ext    = status_ext();
    u32 target = param & 0xFFu;
    int p99    = (int)(ext & 0xFFu);
    xil_printf("ae: p99=%d mean=%u sat=%u%% target=%u +/-8 -> %s\r\n",
               p99,
               (unsigned)((ext >> 8)  & 0xFFu),
               (unsigned)((ext >> 16) & 0xFFu),
               (unsigned)target,
               (p99 >= (int)target - 8 && p99 <= (int)target + 8)
                   ? "in band" : "out of band");
    break;
}
```

Run it with `s` until `stage 3: histogram` and `k` until mode 2, `+`/`-` to set
the target: the loop the PS would close is "p99 above the band -> shorten the
exposure, below -> lengthen it".  The stage reports, the PS decides — which is
the point of keeping the dead band out of the FPGA.

## Verification

`sim/run_sim.ps1` picks the testbench up automatically and compiles it against
the whole RTL tree.  The bench runs three frames of 8 words x 8 lines (64 words,
256 pixels) at one word per eight clocks:

* frame 0, mode 0, Y distribution 64 x 32 / 128 x 128 / 64 x 224, with runs of
  four equal pixels per word and same-bin values across word boundaries;
* frame 1, mode 1, same distribution: the output must be the grey image of the
  map built from frame 0, checked pixel by pixel against a reference model;
* frame 2, mode 2, distribution 64 x 32 / 128 x 200 / 64 x 250 (the 250s are
  saturated): pass-through must be bit-exact.

Checked: every output word against the reference, the frame tag on word 0, the
line end on the last word of every line, 64 words per frame and 192 total,
nothing before the first tag; the completed histogram bin counts captured as the
finalise scan reads them; `stat` at every frame tag (frame N-1's values); and
the full 256-entry map (values, monotonicity, `map[32]` still dark, white mapped
to full scale).  Removing the forward path in a copy of the RTL makes the bench
fail on the bin counts, which is the test that matters most here.
