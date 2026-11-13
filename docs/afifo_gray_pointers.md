# Gray-coded pointers in `afifo`

This note explains why `rtl/afifo.v` encodes FIFO pointers in Gray code before they
cross between unrelated clocks. The same module is instantiated twice on the video path:
camera PCLK (~42 MHz) → AXI at 50 MHz (65-bit words), then AXI → panel pixel clock
(33.333 MHz, 64-bit words).

## What crosses clock domains

Each side keeps its own binary pointer (`wbin`, `rbin`) to index the RAM and advance only
when that side writes or reads. The *other* side’s pointer must be observed to decide
`wr_full` on the write clock and `rd_empty` on the read clock. Those foreign pointers are
not combinatorially connected; they pass through a two-register synchronizer on the
receiving domain:

```verilog
// read pointer, sampled in the write domain
rgray_s1 <= rgray;
rgray_s2 <= rgray_s1;

// write pointer, sampled in the read domain
wgray_s1 <= wgray;
wgray_s2 <= wgray_s1;
```

Nothing in this path can guarantee that all bits of a multi-bit value change on the same
edge of the source clock relative to the destination clock. That is the CDC hazard Gray
code is meant to remove for *monotonic* counters.

## Why binary pointers are unsafe here

On a single clock, incrementing `0111` → `1000` (7 → 8) is one addition. Across clocks,
each bit is a separate wire into the synchronizer. The destination flop chain can sample
some bits from the old value and some from the new value on the same conceptual update.
The synchronized word may never have existed as a real pointer—for example something like
`0101` when the source only ever held `0111` or `1000`.

If `wr_full` or `rd_empty` is built from that sample, the FIFO can briefly think it is
empty when it has data, or not full when it is about to overflow. In a streaming video
path that means underruns, torn frames, or silent corruption.

## What Gray code buys you

A reflected Gray code is assigned from binary with the same rule as in the RTL:

```verilog
wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
```

For this FIFO, pointers only ever increment by one (no decrement, no random jumps).
Property: each increment changes **exactly one** Gray bit, including the wrap (e.g. index
255 → 0 in 8 bits is Gray `10000000` → `00000000`, one bit flip).

While the synchronizer is settling, the sampled value is therefore either the previous
valid Gray code or the next valid one—never an arbitrary bit pattern in between. Empty
and full tests that compare Gray values stay aligned with “one step behind” or “one step
ahead,” not with a corrupt third state.

The tradeoff is latency: the observed pointer trails the true pointer by roughly two
cycles of the receiving clock. That lag is the **safe** direction for a FIFO:

- The writer sees a read pointer that is **behind** → may declare **full early** (never
  overwrite unread data).
- The reader sees a write pointer that is **behind** → may declare **empty early** (never
  pop garbage).

The header comment in `afifo.v` documents that `wr_level` / `rd_level` inherit the same
delay, which is what you want for burst engines that throttle on occupancy.

## Binary vs Gray in the module

| Register / wire | Clock domain | Role |
|-----------------|--------------|------|
| `wbin`, `rbin`  | local        | RAM address (`mem[bin[AW-1:0]]`), arithmetic for levels |
| `wgray`, `rgray`| local        | Exported copy for CDC and empty/full compares |

Binary is kept where you need a numeric index or difference; Gray is what crosses between
domains.

## Empty and full

Depth is `2**AW` words, but the pointer width is `PTR_W = AW + 1`. The extra bit
distinguishes “empty” from “full” when the address bits alone would match (write pointer
has caught read pointer after exactly one lap around the ring).

- **Empty (read side):** Gray write and read pointers match after synchronizing the write
  pointer: `rd_empty = (rgray == wgray_s2)`.

- **Full (write side):** Compare the *next* write Gray code (the state after the write
  currently in progress) against the synchronized read pointer, with the top two Gray bits
  inverted on the read side. That is the standard “one slot reserved” full detection in
  Gray form:

```verilog
wr_full = (wgray_nxt == {~rgray_s2[PTR_W-1:PTR_W-2], rgray_s2[PTR_W-3:0]});
```

Using `wgray_nxt` rather than `wgray` asserts full on the cycle that would consume the
last free entry.

## Converting back for occupancy

Empty/full only need equality on Gray codes. `wr_level` and `rd_level` need binary
subtraction, so the synchronized Gray pointer is converted with `gray2bin()` (XOR unfold
from MSB to LSB) on the receiving side:

```verilog
wr_level = wbin - gray2bin(rgray_s2);
rd_level = gray2bin(wgray_s2) - rbin;
```

Those counts are approximate from the other domain’s point of view—they lag the
synchronizer—but that is acceptable for throttling and status.

## Worked example (8-bit index)

Binary increment 7 → 8 flips four bits; Gray moves by one bit:

| Index (bin) | Binary   | Gray (8b) |
|-------------|----------|-----------|
| 7           | `00000111` | `00000100` |
| 8           | `00001000` | `00001100` |

Only bit 2 of the Gray code changes between those two legal states. A synchronizer
catching the transition sees either `00000100` or `00001100`, not a mixed pattern.

For a full 0–255 table, evaluate `gray = (index >> 1) ^ index` for each index; the
8-bit patterns for indices 0–15 are enough to see the single-bit-flip pattern between
successive entries.

## Further reading

- `rtl/afifo.v` — implementation and show-ahead read (`rd_data` valid while not empty).
- `README.md` — where the two FIFO instances sit in the camera → DDR → panel path.
- Clifford E. Cummings, *Simulation and Synthesis Techniques for Asynchronous FIFO
  Design* — canonical Gray-pointer FIFO construction (same full/empty encoding family).
