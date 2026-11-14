# `stage_lut` — point operations through a lookup table

`rtl/stage_lut.v` is the tier-0 processing stage: a **point operation**, where every
output pixel depends on exactly one input pixel and nothing else. Brightness,
contrast, gamma, invert, threshold and false colouring are all point operations, and
they are all the same hardware here — only the contents of a 256-entry table, or the
three bits that select a curve, change.

* Slot: `sel = 1` (the LSB slot of `stage_mux`).
* Latency: **3 words**, fixed, in every mode.
* Clock domain: `cam_pclk` only. No CDC, no back-pressure, no stalls.
* New files: `rtl/stage_lut.v`, `sim/tb_stage_lut.v`, this document.
  Nothing else in the tree was touched.

## Why a table is the right implementation

A point operation is a function of one 8-bit value. Implemented as arithmetic, each
operation in the chain costs real hardware *per channel per pixel* — and this stage
carries twelve channels at a time (four pixels × R, G, B). Four chained operations
would be four arithmetic units times twelve, and a new curve would be a new arithmetic
chain.

Implemented as a table, the same ROM evaluates **any** function of one byte at the
cost of one lookup: gamma `v^0.7` (not expressible in cheap integer arithmetic at
all), a film-style S-curve, a per-channel white-balance map, an inverted or
thresholded output. The table is written once, from the design's own model, and the
datapath never changes (Bailey, *Design for Embedded Image Processing on FPGAs*, 2e,
sec. 7.1.3: "one table can replace a chain of point operations"). The classic
example is exactly this one: gamma and contrast baked into a single table so the
pixel path is one synchronous read.

Two of the modes here are deliberately *not* table reads:

* **brightness/contrast** (`knob = 1`) depends on `param`, which the console can
  change at any frame. A table for it would have to be rebuilt from `param`, and a
  rebuild is 256 writes that must not land mid-frame. The affine map is exact in one
  multiply-add, so it is arithmetic: `clamp((v * gain) / 8 + offset)`.
* **invert** and the **threshold** are one's-complement and one compare — a 256-entry
  ROM that contains `255 - v` is the same answer for 40× the LUTs.

Everything else — gamma, and the false-colour ramp — is the table idea, or its
arithmetic twin for a curve with no detail to store: the false-colour palette is
three linear segments, so generating it (`3 comparators, 2 subtractors, a mux`) is
cheaper than a 256 × 16 ROM replicated per pixel, and the result is identical to what
that ROM would contain.

## Datapath

```
                 +----------------------------------------------------+
                 |  every register below is ONE concatenated vector:  |
                 |  {data, mode, param, sof, eol, valid}              |
                 +----------------------------------------------------+
 s_data[63:0]
   |  four RGB565 pixels, pixel 0 in bits [15:0]
   v
 [1] unpack + expand to 8 bits          R5 -> R8 {v,v[4:2]}, G6 -> G8 {v,v[5:4]}
   |                                     luma y = (R + 2G + B)/4, per pixel
   v   reg sr1
 [2] table / curve for each of 12 channels
   |   0 identity | 1 affine | 2 gamma ROM | 3 threshold | 4 palette | 5 invert
   v   reg sr2
 [3] requantise 8 -> 5/6/5 by truncation, repack four pixels into 64 bits
   |
   v   reg sr3
 m_data / m_valid / m_sof / m_eol
```

`m_sof`, `m_eol` and `m_valid` are **inside** each pipeline register, never in flops of
their own, which is what keeps the frame tag on the first word and the line end on the
last word of every line. The control word rides in the same vector as the pixels: the
stage samples `param`/`knob` at its *input* frame tag and carries that value with the
words, so the parameter change that `stage_mux` applies on the *emitted* tag (three
words later) can never split one frame between two settings.

A word that enters at cycle `t` appears at `m_*` at cycle `t + 3`:

| cycle | register | contents |
|---|---|---|
| `t` | — | `{s_data, s_sof, s_eol, s_valid}` sampled |
| `t+1` | `sr1` | 96-bit expanded RGB + mode + param + tags |
| `t+2` | `sr2` | 96-bit mapped RGB + tags (table output register) |
| `t+3` | `sr3` | 64-bit requantised word + tags → `m_*` |

A BRAM-based table would spend one of those three cycles on the BRAM output register;
with a distributed ROM the read is combinational, and the registered address /
registered data split above still gives a 3-word latency and a short logic path. The
latency is the same in every mode, which the frame contract needs: a mode change that
also changed the latency would move the frame tag.

## `knob` / `param` encoding

`knob[2:0]` selects the mode. `knob[7:3]` is ignored.

| `knob[2:0]` | mode | `param` |
|---|---|---|
| `0` | identity — **bit-exact** passthrough | ignored |
| `1` | brightness / contrast | `param[3:0]` gain, 1..15, 8 = unity; `param[7:4]` offset, unsigned with bias 8 (8 = none, 0 = −8, 15 = +7) |
| `2` | gamma 0.7, fixed 256-entry table | ignored |
| `3` | threshold on luminance: white if `y > param[7:0]`, else black | `param[7:0]` level 0..255 |
| `4` | false colour: luma → blue → cyan → yellow → red | ignored |
| `5` | invert, `255 - v` per channel | ignored |
| `6`, `7` | reserved, behave as identity | ignored |

`param[15:8]` is unused. Useful values to type at the console (`param = {offset[3:0],
gain[3:0]}` in the low byte; in mode 3 the whole low byte is the level):

| value | mode 1 | mode 3 |
|---|---|---|
| `0x0088` | unity: gain 8, offset 8 → no change | level 136 |
| `0x0080` | gain 0, offset 8 → near black | level 128 |
| `0x00AC` | gain 12, offset +2 | level 172 |
| `0x00F8` | gain 8, offset +7 (brightest) | level 248 |
| `0x0008` | gain 8, offset −8 (darkest) | level 8 |

Both fields of mode 1 are biased so that the neutral setting is the middle of the field
(`8`) rather than `0`, which puts the "no change" word at `0x88` — walk `param` up from
0 and the picture passes through exactly-neutral at 0x88 instead of through black.
That matters because the console only offers `+`/`-` on a 16-bit word, one step at a
time.

## `stat[31:0]`

| bits | meaning |
|---|---|
| `[15:0]` | number of pixels whose luminance is above `param[7:0]`, saturating at 0xFFFF |
| `[23:16]` | frame mean luminance, `sum(y) / 384000`, 0..255 |
| `[31:24]` | number of fully saturated pixels (R = 31, G = 63, B = 31), saturating at 255 |

* Statistics are measured on the **input** pixels, so the same number means the same
  thing whatever the mode is doing to the picture. In mode 3 the above-threshold count
  is the number of white pixels.
* The threshold level in `stat[15:0]` is always `param[7:0]`, in every mode — the
  console can read the scene's bright-pixel count without being in mode 3.
* The value on `stat` is the frame that **just finished**: the accumulators are
  published and cleared on the next frame tag. That is exactly when `stage_mux`
  snapshots it (one cycle after the tag), so the PS never reads a torn or partial
  frame. `stat` is combinational from those registers, as the contract allows; the
  mean's division by a constant settles a whole frame before it is read.

Measured by `tb_stage_lut` on its synthetic 8 × 4-word frame (`0x0193007f` =
127 above, mean 147, 1 saturated):

```
  stat frame 0: 0193007f  above=127 mean=147 saturated=1
```

## Quantisation

* 5 → 8 bits is bit replication (`{v, v[4:2]}`), 6 → 8 is `{v, v[5:4]}`. These map 0 to
  0 and 31/63 to 255, and their inverse is an exact truncation.
* 8 → 5/6/5 is **truncation** of the top bits, not rounding. Truncation is the exact
  inverse of expansion, so the identity mode is bit-exact for all 65 536 pixel values
  — rounding would not be (a rounded requantiser lifts some values by one code and
  breaks the passthrough guarantee).
* Consequence for the curves: one 8-bit LSB of quantisation error, i.e. at most 1/8 of
  a 5-bit code step and 1/4 of a 6-bit one. Gamma truncates rather than rounds on the
  way out, which biases the darkest codes down by at most one 5-bit step; that is
  visible only as a slightly blacker black, and it is the price of the exact
  passthrough.

## Cost

Simulation only in this tier (no synthesis was run), so these are estimates derived
from what the RTL infers; the arithmetic is given so the numbers can be checked.

| resource | estimate | where it goes |
|---|---|---|
| LUT | ~1000 (≈2 % of XC7Z020) | gamma ROM 250–500, affine 360 (or 0 with DSPs), palette ~100, luma ~40, clamp/compare ~60, control + statistic ~100 |
| FF | ~380 | `sr1` 118 + `sr2` 99 + `sr3` 67, control 19, statistic 78 |
| BRAM | **0** | the table is a distributed ROM |
| DSP48 | 12 (or 0) | the mode-1 multiply; without DSPs it becomes ~360 LUTs |
| latency | 3 words | |

Why the gamma table is not BRAM: it is read **twelve times per word** (four pixels ×
three channels) and a 7-series BRAM has at most two ports. Twelve independent reads
per clock cannot come from a block RAM, so the table synthesises as distributed ROM —
a 256 × 8 ROM is roughly 32–40 LUTs per read port, and the 5-bit channels only ever
reach 32 of the 256 entries, which synthesis prunes. A BRAM version would need one
table per channel plus an eight-phase read schedule (the 8 `cam_pclk` cycles per word
would allow it) and would trade the design's scarcest resource, BRAM tiles, for its
most abundant one. Not worth it for a point operation.

## Border and edge cases

* **No borders.** A point operation touches one pixel, so the first and last pixel of
  a line and of a frame are processed exactly like every other pixel. There is no
  window, no line buffer and no border policy to choose. `m_eol`/`m_sof` are passed
  through only because the downstream stages and `fb_ddr` need them.
* **Word alignment is untouched**: a word in is four pixels in, the same four pixels
  out, pixel 0 still in bits `[15:0]`. No mode adds, drops or re-orders a word.
* **Mode changes** take effect at the stage's input frame tag, with the parameter
  carried alongside the pixels, so a change never splits a frame — including the three
  words still in the pipeline when the new parameter appears.
* **Reserved modes 6 and 7** behave as identity, so an out-of-date console cannot
  black out the picture.
* **Short frames.** The mean divides by the contract's fixed 384 000 pixels. A frame
  cut short by a stage hand-over (documented in `stage_mux.v`) reports a
  proportionally darker mean for that one frame; the counters themselves always restart
  at the frame tag, so nothing drifts. The two saturating counters stop at their
  maximum instead of wrapping (a white frame reports 0xFFFF above-threshold pixels,
  not 0).
* **Luminance** is `(R + 2G + B) / 4` — the cheapest weighting that still puts most of
  the weight on green. It is exact in 8 bits, and it is used identically by the
  threshold, the false-colour ramp and the statistic.

## Integration into `rtl/ov5640_top.v`

The stage is slot 1, so it is the **LSB** entry of every `st_*` concatenation and it
needs `NUM_STAGES` raised to 4. Slots 2–4 are not populated yet and are fed the raw
stream, which is the foundation build's convention (`stage_mux.v` only ever looks at
the selected slot, so an unused slot's contents are irrelevant and any `ctrl[4:2]`
value stays safe).

Replace the single existing `stage_mux` instance (and the `stage_word` /
`stage_valid` / `stage_sof` / `stage_eol` / `stage_stat` declaration block above it)
with:

```verilog
    wire [63:0] stage_word;
    wire        stage_valid;
    wire        stage_sof;
    wire        stage_eol;
    wire [31:0] stage_stat;

    wire [15:0] stage_param;
    wire [ 7:0] stage_knob;

    // slot 1 = stage_lut (sel = 1): point operations through a 256-entry table
    wire [63:0] lut_data;
    wire        lut_valid;
    wire        lut_sof;
    wire        lut_eol;
    wire [31:0] lut_stat;

    stage_lut #(
        .WORDS_PER_LINE (WORDS_PER_LINE),      // 200
        .LINES_PER_FRAME(V_ACTIVE)             // 480
    ) u_stage_lut (
        .clk    (cam_pclk),
        .rst_n  (cam_rst_n),
        .s_data (cam_word),
        .s_valid(cam_word_valid),
        .s_sof  (cam_word_first),
        .s_eol  (cam_weol),
        .m_data (lut_data),
        .m_valid(lut_valid),
        .m_sof  (lut_sof),
        .m_eol  (lut_eol),
        .param  (stage_param),
        .knob   (stage_knob),
        .stat   (lut_stat)
    );

    stage_mux #(
        .NUM_STAGES(4)                         // was 1
    ) u_stage_mux (
        .clk       (cam_pclk),
        .rst_n     (cam_rst_n),
        .s_data    (cam_word),
        .s_valid   (cam_word_valid),
        .s_sof     (cam_word_first),
        .s_eol     (cam_weol),
        // slot 1 in the LSB, then the raw stream in the still-empty slots 2..4
        .st_data   ({cam_word,        cam_word,        cam_word,
                     lut_data}),
        .st_valid  ({cam_word_valid,  cam_word_valid,  cam_word_valid,
                     lut_valid}),
        .st_sof    ({cam_word_first,  cam_word_first,  cam_word_first,
                     lut_sof}),
        .st_eol    ({cam_weol,        cam_weol,        cam_weol,
                     lut_eol}),
        .st_stat   ({32'd0,           32'd0,           32'd0,
                     lut_stat}),
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

Then in `ps/app/main.c`, name the slot (keep it in step with `ov5640_top.v`):

```c
static const char *const stage_name[NUM_STAGES] = {
    "bypass",
    "lut point op",     /* was "stage 1" */
    ...
};
```

### Console key name

Suggested name: **`lut`** for the slot, so the console reads `stage 1: lut point op`.

The stage is selected with the existing `s` key (next processing stage — press until
`ctrl stage=1`), the mode with `k` (`ctrl knob=0..7`), and the parameter with `+` / `-`.
`+`/`-` walks the whole 16-bit word, so the useful settings are the ones in the table
above: `0x0080` for a clean thresholded picture (mode 3, level 128) and `0x00AC` for
extra contrast (mode 1, gain 12, offset +2). `status_ext` on the console is then this
stage's `stat[31:0]`.

## Verification

`sim/tb_stage_lut.v` drives 8 words per line × 4 lines per frame, with one black pixel
and one saturated pixel per frame, and every pixel encoding its own
(frame, line, word, pixel) position so that any misalignment cannot match:

```
  cd sim
  $env:PATH = "D:\Xilinx\Vivado\2023.2\bin;" + $env:PATH
  xvlog.bat ..\rtl\img_geom.v ..\rtl\stage_mux.v ..\rtl\stage_lut.v tb_stage_lut.v
  xelab.bat -debug typical tb_stage_lut -s tb_lut
  xsim.bat tb_lut -runall
```

It checks, word by word,

1. mode 0 (and reserved 6, 7) against the words the source actually drove — bit-exact,
   tags included;
2. every other mode against a reference model in the testbench: threshold on
   luminance, brightness/contrast (both clamps), gamma (real arithmetic, `$pow`, no
   shared table), false colour and invert;
3. `m_sof` on the first word of every frame, `m_eol` on the last word of every line, and
   nothing at all before the first frame tag;
4. exactly `WORDS_PER_LINE * LINES` words in every frame, exactly 10 frames;
5. the latency, as the distance between the first input tag and the first output tag;
6. `stat` against the same reference statistic for frames 0–8 (the last frame's
   statistic is published on a frame tag that does not exist in a 10-frame run).

Frames 0–2 are the three-frame contract check (identity, threshold 128, threshold 0);
frames 3–9 sweep the remaining modes so no mode is untested. The run ends with one
`TEST PASS` line.
