# The processing stage contract

Every image-processing algorithm in this project is a **stage**: a module that
takes the camera's word stream, returns a word stream, and is selected into the
frame-buffer path by `ctrl[4:2]`.  Stages run in parallel and are swapped at run
time from the console, so two algorithms can be compared on the same live picture
without a rebuild.

```
  ov5640_capture ──┬──────────────────────────────► stage_mux ──► afifo ──► fb_ddr
                   │                                  │  sel = ctrl[4:2]
                   ├──► stage 1 (LUT point op) ───────┤
                   ├──► stage 2 (3x3 window) ─────────┤
                   ├──► stage 3 (histogram) ──────────┤   stat ──► status_ext
                   └──► stage 4 (segmentation) ───────┘
```

All of it is in the camera pixel clock domain (`cam_pclk`, 42 MHz).

## Interface

```verilog
module my_stage (
    input  wire        clk,        // cam_pclk
    input  wire        rst_n,      // asynchronous, active low
    // input stream (four RGB565 pixels per word, pixel 0 in bits [15:0])
    input  wire [63:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,      // this word is the first of a frame
    input  wire        s_eol,      // this word is the last of a line
    // output stream, delayed by the stage's own latency
    output wire [63:0] m_data,
    output wire        m_valid,
    output wire        m_sof,
    output wire        m_eol,
    // control, already frame-stable (see below)
    input  wire [15:0] param,      // ctrl[31:16]
    input  wire [ 7:0] knob,       // ctrl[7:5] in the low three bits
    // one 32-bit statistic for the console
    output wire [31:0] stat
);
```

`stat` is sampled once per frame by `stage_mux`, so it needs no timing
constraints: drive it combinationally from whatever the stage has accumulated for
the frame just finished.

## The five invariants

`fb_ddr` counts words and switches buffers on the frame tag.  A stage that breaks
any of these makes the picture slide or tear, and the failure looks like a bug
somewhere else entirely.

1. **96 000 words per frame, 200 words per line.** A stage may delay, but never
   add, drop or re-order words. `wcnt` must be identical on input and output.
2. **The frame tag stays on the first word of the frame.** `m_sof` must be `s_sof`
   delayed by exactly the same number of words as `m_data`.
3. **`m_eol` is delayed with the data too**, and stays on the last word of every
   line. Getting this wrong is invisible until a filter uses it for border
   handling, and then only on the right-hand edge.
4. **Word alignment is four pixels**, restarted at every line and frame. A stage
   never sees a partial word and must never emit one.
5. **Latency is a whole number of words, and the stage never stalls.** There is no
   back-pressure: the camera keeps emitting. If a stage needs more than one cycle
   per word it must pipeline, not wait.

## What `stage_mux` does for you

* **Frame-stable parameters.** `sel`, `param` and `knob` come from the AXI clock
  domain. `stage_mux` synchronises them and re-latches them on the *emitted*
  frame tag, so a control write in mid-frame cannot split a frame.
  **A stage with latency must sample `param`/`knob` at its own input frame tag
  and carry the value down its pipeline with the pixels** — the mux's re-latch
  happens on the emitted tag, which is `latency` words later, so a stage that
  read `param` combinationally would apply the next frame's setting to the words
  still inside its pipeline. `stage_lut` (3 words) and `stage_hist` (5 clocks)
  both do this; it is two flops and it removes a whole class of "the picture
  changes a frame early" bug.
* **A hand-over that cannot tear.** When the selection changes, the mux stays
  silent until the newly selected stage produces its own frame tag; that tag
  then starts the next frame at word 0. The camera's vertical blanking is far
  longer than any stage latency, so nothing is lost — except that the frame
  *before* the switch is short by that stage's latency in words, which for the
  3×3 stage (404 words) is the bottom two lines of one frame. It is a single
  frame on a mode change, and `fb_ddr`'s fixed word count keeps it from sliding
  anything else.
* **Warm-up gating.** Words before the first frame tag after reset (a stage's
  pipeline is full of junk then) are dropped, so the frame tag still lands on
  offset 0.
* **Statistic transfer.** The 32-bit `stat` is snapshotted per frame and moved to
  the AXI clock domain with a toggle handshake; the PS never reads a torn value.

## Coordinates

A stage that needs `x`/`y` regenerates them rather than importing them, because
the stage delays the stream. Instantiate `img_geom` on the delayed stream:

```verilog
    wire        m_eol_i;
    wire [ 8:0] m_wx, m_wy;

    img_geom #(.WORDS_PER_LINE(WORDS_PER_LINE)) u_geom (
        .clk  (clk),
        .rst_n(rst_n),
        .sof  (m_sof),
        .valid(m_valid),
        .eol  (m_eol_i),        // must equal m_eol
        .wx   (m_wx),           // 0..199, one word = four pixels
        .wy   (m_wy)            // 0..479
    );
```

`m_wx`/`m_wy` are word coordinates: pixel x of pixel `i` in the word is
`4*m_wx + i`.

## Budget

One word leaves the camera every 8 `cam_pclk` cycles (two bytes per pixel, four
pixels per word), so a stage has **eight clocks of slack per word**: a 3×3
sorting network can be shared between the four pixels of the word, and a
multiplier can be reused in phases rather than replicated. That is the single
most useful property of this insertion point and the reason arithmetic belongs
here rather than on the AXI side, where there is one clock per word.

A 3×3 window needs two line buffers of 200 words: 1 BRAM18 each at 64 bits wide.
The whole design currently uses 14.6 % of the LUTs, 0.5 of 140 BRAM tiles and 0
of 220 DSPs, so there is room for several stages.

## Worked example: the smallest possible stage

```verilog
//  stage_invert.v — point operation: complement all four pixels
module stage_invert (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,
    input  wire        s_eol,
    output wire [63:0] m_data,
    output wire        m_valid,
    output wire        m_sof,
    output wire        m_eol,
    input  wire [15:0] param,
    input  wire [ 7:0] knob,
    output wire [31:0] stat
);
    // latency 0: the tags and the data are all combinational passthroughs
    assign m_data  = s_data ^ {4{16'hFFFF}};
    assign m_valid = s_valid;
    assign m_sof   = s_sof;
    assign m_eol   = s_eol;
    assign stat    = {16'd0, param};
endmodule
```

A stage with latency `L` registers data and tags together, `L` words deep
(`{s_data, s_sof, s_eol, s_valid}` in one shift register) - never separately,
which is how tags end up on the wrong word.

## Adding one

1. `rtl/stage_<name>.v` — the module. No changes to any other file.
2. `sim/tb_stage_<name>.v` — self-checking, must print `TEST PASS`.
   `sim/run_sim.ps1` discovers it automatically and compiles it against the whole
   RTL tree, so no file list needs editing.
3. In `rtl/ov5640_top.v`: raise `stage_mux`'s `NUM_STAGES`, concatenate the new
   stage's outputs onto `st_data` / `st_valid` / `st_sof` / `st_eol` / `st_stat`
   (slot `k-1` is `sel = k`), and drive its `param`/`knob` from the mux.
4. In `ps/app/main.c`: give the slot a name in `stage_name[]`.
5. Document, in the stage's own header, what `knob` and `param` mean and what
   `stat` reports.

## Verifying one

The testbench must prove more than "the picture looks plausible":

* **Bypass identity.** With `sel = 0` the frame-buffer path must be bit-identical
  to the raw stream; the existing `tb_pipeline` frame-id scoreboard covers this.
* **Word count and tags.** `tb_stage_contract` shows the pattern: drive a
  synthetic stream whose content encodes frame/line/column, and check every
  output word against the expected pattern, plus `m_sof`/`m_eol` position and the
  words-per-frame count.
* **A reference model.** For anything with arithmetic, implement the same
  algorithm in Python over a dumped frame (`ps/dump_fb.tcl` + `tools/fb2png.py`)
  and compare bit-exactly. Quantisation and border policy are design decisions;
  differences should be explainable, not surprising.

## Border policy

A 3×3 window at the image edge needs pixels that do not exist. Pick one of
constant extension, duplication, or mirroring and say so in the stage header;
`docs/` is the place for the reasoning. The choice is visible in every dumped
frame's edges, and it is the first thing a reviewer asks about.
