// =============================================================================
//  hist_overlay.v — live luminance-histogram overlay for the panel
//
//  stage_hist publishes every bin during its finalise scan, which is the one
//  moment in a frame when a completed count exists.  This block keeps two
//  copies of the 256 bins in a dual-clock block RAM: the camera fills one bank
//  while the panel reads the other, so the panel always draws a histogram that
//  belongs to a single completed frame (one camera frame old, the same
//  one-frame convention as `stat` and the equalisation map).
//
//  The graph lives in a band at the bottom of the screen, 256 bars of three
//  pixels from x = 16 to x = 783.  Height is a log scale *relative to the
//  frame's own peak bin*, 20 pixels per octave: an absolute scale would let one
//  dark wall fill the whole panel, and a band keeps the picture readable.
//
//  The block outputs a *mask*, not a colour: inside a bar the panel keeps the
//  pixel's red and blue and forces its green channel to full scale.  Averaging
//  green with a warm, dim picture comes out olive (that is what made the first
//  version look grey); saturating only the green channel tints the picture
//  without touching its luminance detail, so the scene stays visible.
//
//  In blanking the block scans its own bank once to find the peak (258 clocks
//  of the ~48 000 the panel spends in blanking), so the stage needs to publish
//  nothing but the bins.  One BRAM read and a 16-bit leading-zero encoder sit in
//  the pixel path: about 10 ns of the 30 ns period.
// =============================================================================
`timescale 1ns / 1ps

module hist_overlay #(
    parameter integer H_ACTIVE = 800,
    parameter integer V_ACTIVE = 480,
    parameter integer BAR_W    = 3,         // pixels per bin
    parameter integer X0       = 16,        // left edge of the graph
    parameter integer BAND_H   = 160,       // height of the band it lives in
    parameter integer SCALE    = 20         // pixels per octave
) (
    // ---- panel side (pixel clock) -------------------------------------------
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,     // one-clock pulse at the start of blanking
    input  wire [10:0] x,               // 0 .. H_ACTIVE-1 inside the active window
    input  wire [ 9:0] y,               // 0 .. V_ACTIVE-1
    input  wire        in_active,
    input  wire        enable,
    output wire        ovl_hit,         // draw a bar here; the panel tints green
    // ---- camera side: published histogram -----------------------------------
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_en,
    input  wire        wr_bank,         // bank being filled; the other is readable
    input  wire [ 7:0] wr_bin,
    input  wire [15:0] wr_cnt,
    input  wire        wr_valid         // at least one scan has completed
);

    localparam integer BINS     = 256;
    localparam integer BOX_W    = BINS * BAR_W;
    localparam integer BOX_END  = (X0 + BOX_W < H_ACTIVE) ? (X0 + BOX_W) : H_ACTIVE;
    localparam integer MAX_OCT  = BAND_H / SCALE;

    localparam [10:0] X0_11 = X0;
    localparam [10:0] X1_11 = BOX_END;
    localparam [ 9:0] V_LAST = V_ACTIVE - 1;
    localparam [ 4:0] MAX_OCT5 = MAX_OCT;

    // =========================================================================
    //  Leading-zero count of a 16-bit bin count (0 for the top bit set)
    // =========================================================================
    function [3:0] clz16;
        input [15:0] v;
        begin
            if      (v[15]) clz16 = 4'd0;
            else if (v[14]) clz16 = 4'd1;
            else if (v[13]) clz16 = 4'd2;
            else if (v[12]) clz16 = 4'd3;
            else if (v[11]) clz16 = 4'd4;
            else if (v[10]) clz16 = 4'd5;
            else if (v[ 9]) clz16 = 4'd6;
            else if (v[ 8]) clz16 = 4'd7;
            else if (v[ 7]) clz16 = 4'd8;
            else if (v[ 6]) clz16 = 4'd9;
            else if (v[ 5]) clz16 = 4'd10;
            else if (v[ 4]) clz16 = 4'd11;
            else if (v[ 3]) clz16 = 4'd12;
            else if (v[ 2]) clz16 = 4'd13;
            else if (v[ 1]) clz16 = 4'd14;
            else            clz16 = 4'd15;
        end
    endfunction

    // =========================================================================
    //  Snapshot RAM: 2 banks x 256 bins, one write port, one read port
    // =========================================================================
    (* ram_style = "block" *) reg [15:0] snap [0:2*BINS-1];
    reg [15:0] cnt_q;

    // camera side: the scan writes each bin once, into the bank being filled
    always @(posedge wr_clk) begin
        if (wr_en) snap[{wr_bank, wr_bin}] <= wr_cnt;
    end

    // =========================================================================
    //  Bank and validity into the pixel clock domain
    // =========================================================================
    // Both are levels that only move on a frame boundary; three flops are enough
    // for the metastability and give the bank a stable value well before the
    // panel latches it.
    reg [2:0] bank_s;
    reg [2:0] vld_s;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            bank_s <= 3'd0;
            vld_s  <= 3'd0;
        end else begin
            bank_s <= {bank_s[1:0], wr_bank};
            vld_s  <= {vld_s[1:0],  wr_valid};
        end
    end

    wire ovl_valid = vld_s[2];

    // The panel latches the readable bank once per frame, in blanking, so the
    // bars cannot change halfway down the screen.
    reg rd_bank;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)       rd_bank <= 1'b0;
        else if (frame_start) rd_bank <= ~bank_s[2];
    end

    // =========================================================================
    //  Bar geometry: three pixels per bin, regenerated from x
    // =========================================================================
    reg [1:0] gcnt;             // which pixel of the 3-pixel group this is
    reg [7:0] bidx;             // bin of the pixel at x

    wire in_box = in_active && (x >= X0_11) && (x < X1_11) && ovl_valid && enable;

    // the address presented now is for the *next* pixel, so the registered RAM
    // output lands on the pixel it belongs to
    wire [7:0] bin_next = (gcnt == 2'd2) ? (bidx + 8'd1) : bidx;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            gcnt <= 2'd0;
            bidx <= 8'd0;
        end else if (!in_active || (x < X0_11) || (x >= X1_11)) begin
            gcnt <= 2'd0;
            bidx <= 8'd0;
        end else if (gcnt == 2'd2) begin
            gcnt <= 2'd0;
            bidx <= bidx + 8'd1;
        end else begin
            gcnt <= gcnt + 2'd1;
        end
    end

    // =========================================================================
    //  Peak scan: one pass over the readable bank in blanking
    // =========================================================================
    // 258 pixel clocks out of the ~48 000 the panel spends in blanking, so the
    // graph can scale to the frame's own peak without the stage publishing a
    // maximum.  The scan owns the read port while it runs; there are no pixels
    // to draw then.
    reg        scanning;
    reg [8:0]  scan_n;
    reg [15:0] peak;
    reg [3:0]  zp;              // clz16(peak): octave the full band represents

    wire [8:0] ram_a = scanning ? {rd_bank, scan_n[7:0]} : {rd_bank, bin_next};

    always @(posedge pix_clk) begin
        cnt_q <= snap[ram_a];
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            scanning <= 1'b0;
            scan_n   <= 9'd0;
            peak     <= 16'd0;
            zp       <= 4'd15;
        end else if (frame_start) begin
            scanning <= 1'b1;
            scan_n   <= 9'd0;
            peak     <= 16'd0;
        end else if (scanning) begin
            // cnt_q lags the address by one clock, so bin n is compared at
            // scan_n = n + 1
            if ((scan_n != 9'd0) && (scan_n <= 9'd256) && (cnt_q > peak))
                peak <= cnt_q;

            if (scan_n == 9'd257) begin
                scanning <= 1'b0;
                zp       <= clz16(peak);
            end
            scan_n <= scan_n + 9'd1;
        end
    end

    // =========================================================================
    //  Height: BAND_H at the peak bin, SCALE pixels per octave below it
    // =========================================================================
    // A log scale keeps a single-frame histogram readable (a linear one would
    // flatten everything but the peak); being relative to the frame's peak
    // keeps the bars in the band whatever the scene's absolute brightness is.
    wire [3:0] zc = clz16(cnt_q);
    wire [4:0] dz = ({1'b0, zc} > {1'b0, zp}) ? ({1'b0, zc} - {1'b0, zp}) : 5'd0;

    wire [9:0] bar_h = (cnt_q == 16'd0)    ? 10'd0 :
                       (dz > MAX_OCT5)     ? 10'd0 :
                       (BAND_H - SCALE * dz);

    wire [9:0] y_above = V_LAST - y;        // 0 on the bottom row
    wire       bar     = in_box && (y_above < BAND_H) && (y_above < bar_h);

    assign ovl_hit = bar;

endmodule
