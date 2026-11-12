# RTL conventions

Every file in `rtl/` follows the same skeleton, so a new module (an image-processing
stage, another sensor, a second panel) drops in without a style debate.

## File skeleton

```verilog
// =============================================================================
//  <file>.v — <one-line title>
//
//  <what the module does, which clock domain it runs in, and the invariants a
//  caller must keep.  Two to eight lines; the detail belongs in the code.>
// =============================================================================
`timescale 1ns / 1ps

module <name> #(
    parameter integer W = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    ...
);
```

* `timescale 1ns / 1ps` in every file, always the same value.
* The header banner is 79 columns wide; the first line is
  `<file>.v — <title>`, the body explains *why*, not *what*.

## Ports

* ANSI style, one port per line, grouped by direction with a `// ---- x ----`
  comment when the group is not obvious.
* Order: clock, reset, inputs, outputs.  Widths are right-aligned inside the
  brackets (`[31:0]`, `[ 7:0]`), names are aligned one column past the widest
  declaration.
* Lowercase snake_case; `_n` suffix for active-low (`rst_n`, `wr_rst_n`);
  `m_axi_*` / `s_axi_*` for AXI pins, so Vivado can infer the interface.
* No unused ports.  If an AXI master does not use `bid`/`rid`, those pins stay on
  the top-level module (the block design needs the interface) and are simply not
  connected any deeper.

## Registers and resets

* One `always` block per function; `always @(posedge clk or negedge rst_n)` with
  `if (!rst_n) ... else ...` — asynchronous assertion, synchronous release.
* Non-blocking assignments in clocked blocks, blocking in combinational blocks
  (`always @(*)`), and every combinational block lists *all* its inputs.
* No initial values in RTL (`reg x = 0;` is testbench-only), no `$display`.

## Names

Module names say what the block *is*, not where it sits in this particular design:

| Block | Rule | Examples |
|---|---|---|
| chip bring-up | named after the chip it programs | `ov5640_init`, `sii9022_init` |
| data-path stage | named after the function | `ov5640_capture`, `fb_ddr`, `lcd_display` |
| reusable helper | generic name, parameters do the work | `afifo`, `clk_gen`, `i2c_control`, `i2c_bit_shift` |

A bring-up block that only ever touched one sensor is called `<sensor>_init` — if a
second sensor is added it gets its own table and its own `<sensor>_init`, not a
`CAMERA_TYPE` parameter.

| Kind | Convention | Example |
|---|---|---|
| clock / reset | `clk`-prefixed, `_n` for active low | `clk50`, `clk_pix`, `sys_rst_n` |
| registers | lowercase, unit suffix where it helps | `h_cnt`, `w_beat`, `dly_cnt` |
| FSM state | `S_*` localparams | `S_IDLE`, `S_DRAIN` |
| constants | UPPER_CASE localparams | `LUT_SIZE`, `BURSTS_PER_FRAME` |
| instance | `u_<module>` | `u_fb_ddr`, `u_cam_fifo`, `u_ov5640_init` |

## Layout

* Four spaces per level, no tabs, no trailing whitespace, one blank line between
  logical blocks, `begin` on the same line as its `if`/`case` item.
* Section banners inside longer modules:

```verilog
    // =========================================================================
    //  Write engine: camera words -> DDR
    // =========================================================================
```

* Comments explain the reason for the code (`// the tag travels with the data, so
  there is no clock-domain race`) rather than restating it.

## Parameters

* `parameter integer` for sizes and counters, `parameter [n:0]` for values that
  are sliced, `parameter` for booleans.
* Derive what can be derived (`localparam integer BURSTS_PER_FRAME =
  WORDS_PER_FRAME / BEATS;`) instead of adding another parameter.
* `$clog2` is fine for width of counters that must hold a parameter-dependent
  value (`localparam integer XW = $clog2(H_ACTIVE + 1);`).

## Testbenches

`sim/tb_*.v` use the same skeleton, a self-checking scoreboard and one
`TEST PASS` / `TEST FAIL` line at the end; `sim/run_sim.ps1` fails the run if
either compilation or elaboration fails, so a stale snapshot can never be
mistaken for a passing test.
