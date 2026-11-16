// =============================================================================
//  tb_hist_overlay.v 鈥?self-checking testbench for hist_overlay
//
//  Publishes a synthetic histogram through the camera-side port (a different
//  clock, so the dual-clock RAM and the handshake are exercised), latches a
//  panel frame 鈥?which also triggers the block's own peak scan 鈥?then walks
//  whole scan lines and compares every pixel of the graph with a reference
//  model:
//
//    * bar index: three pixels per bin, from x = 16 to x = 783, nothing outside;
//    * bar height: the frame peak fills the 160-pixel band, 20 pixels per
//      octave below it, empty bins draw nothing, nothing above the band;
//    * green bars blended 50 % by a one-pixel checkerboard (half the pixels
//      green, half untouched picture);
//    * nothing is drawn before the first completed histogram or when disabled;
//    * a second published histogram moves the bars to the other bank, and the
//      panel only sees it after the next frame_start.
// =============================================================================
`timescale 1ns / 1ps

module tb_hist_overlay;

    localparam integer H_ACTIVE = 800;
    localparam integer V_ACTIVE = 480;
    localparam integer X0       = 16;
    localparam integer BAR_W    = 3;
    localparam integer BAND_H   = 160;
    localparam integer SCALE    = 20;
    localparam integer MAX_OCT  = BAND_H / SCALE;

    // ---- clocks: the two domains are unrelated on purpose -------------------
    reg pix_clk = 1'b0;
    always #15 pix_clk = ~pix_clk;      // 33.333 MHz

    reg wr_clk = 1'b0;
    always #7 wr_clk = ~wr_clk;         // ~71 MHz

    reg rst_n    = 1'b0;
    reg wr_rst_n = 1'b0;
    initial begin
        #100;
        wr_rst_n = 1'b1;
        #100;
        rst_n = 1'b1;
    end

    // ---- DUT ----------------------------------------------------------------
    wire        ovl_hit;

    reg         frame_start = 1'b0;
    reg  [10:0] x           = 11'd0;
    reg  [ 9:0] y           = 10'd0;
    reg         in_active   = 1'b0;
    reg         enable      = 1'b0;

    reg         wr_en    = 1'b0;
    reg         wr_bank  = 1'b0;
    reg  [ 7:0] wr_bin   = 8'd0;
    reg  [15:0] wr_cnt   = 16'd0;
    reg         wr_valid = 1'b0;

    hist_overlay #(
        .H_ACTIVE(H_ACTIVE),
        .V_ACTIVE(V_ACTIVE)
    ) dut (
        .pix_clk    (pix_clk),
        .pix_rst_n  (rst_n),
        .frame_start(frame_start),
        .x          (x),
        .y          (y),
        .in_active  (in_active),
        .enable     (enable),
        .ovl_hit    (ovl_hit),
        .wr_clk     (wr_clk),
        .wr_rst_n   (wr_rst_n),
        .wr_en      (wr_en),
        .wr_bank    (wr_bank),
        .wr_bin     (wr_bin),
        .wr_cnt     (wr_cnt),
        .wr_valid   (wr_valid)
    );

    // =========================================================================
    //  Reference model
    // =========================================================================
    integer hb [0:255];             // the histogram currently published
    integer have_hist = 0;
    integer errors    = 0;

    function [3:0] clz_tb;
        input integer v;
        begin
            if      (v[15]) clz_tb = 4'd0;
            else if (v[14]) clz_tb = 4'd1;
            else if (v[13]) clz_tb = 4'd2;
            else if (v[12]) clz_tb = 4'd3;
            else if (v[11]) clz_tb = 4'd4;
            else if (v[10]) clz_tb = 4'd5;
            else if (v[ 9]) clz_tb = 4'd6;
            else if (v[ 8]) clz_tb = 4'd7;
            else if (v[ 7]) clz_tb = 4'd8;
            else if (v[ 6]) clz_tb = 4'd9;
            else if (v[ 5]) clz_tb = 4'd10;
            else if (v[ 4]) clz_tb = 4'd11;
            else if (v[ 3]) clz_tb = 4'd12;
            else if (v[ 2]) clz_tb = 4'd13;
            else if (v[ 1]) clz_tb = 4'd14;
            else            clz_tb = 4'd15;
        end
    endfunction

    // height of a bin: the peak fills the band, SCALE pixels per octave
    function integer h_exp;
        input integer c;
        integer peak, zp, dz, k;
        begin
            peak = 0;
            for (k = 0; k < 256; k = k + 1)
                if (hb[k] > peak) peak = hb[k];

            if ((c == 0) || (peak == 0)) begin
                h_exp = 0;
            end else begin
                zp = clz_tb(peak);
                dz = (clz_tb(c) > zp) ? (clz_tb(c) - zp) : 0;
                h_exp = (dz > MAX_OCT) ? 0 : (BAND_H - SCALE * dz);
            end
        end
    endfunction

    function expected_hit;
        input integer row;
        input integer xi;
        input integer en;
        integer bin, y_above;
        begin
            expected_hit = 1'b0;
            if (have_hist && en && (xi >= X0) && (xi < X0 + 256 * BAR_W)) begin
                bin     = (xi - X0) / BAR_W;
                y_above = (V_ACTIVE - 1) - row;
                if ((y_above < BAND_H) && (y_above < h_exp(hb[bin])))
                    expected_hit = 1'b1;
            end
        end
    endfunction

    // =========================================================================
    //  Scoreboard
    // =========================================================================
    task fail;
        input [255:0] what;
        begin
            errors = errors + 1;
            if (errors < 25)
                $display("FAIL t=%0t: %0s (x=%0d y=%0d bin=%0d)", $time, what,
                         x, y, (x >= X0) ? (x - X0) / BAR_W : 0);
        end
    endtask

    // walk one scan line and compare every pixel
    task check_row;
        input integer row;
        input integer en;
        integer xi, nbad;
        begin
            nbad = 0;
            for (xi = 0; xi < H_ACTIVE; xi = xi + 1) begin
                @(negedge pix_clk);
                x         <= xi;
                y         <= row;
                in_active <= 1'b1;
                enable    <= (en != 0);
                #1;
                if (ovl_hit !== expected_hit(row, xi, en)) begin
                    nbad = nbad + 1;
                    if (nbad < 4) fail("overlay pixel");
                end
            end
            $display("  row %0d: %0s (%0d bad pixels)", row,
                     (nbad == 0) ? "ok" : "MISMATCH", nbad);
        end
    endtask

    // =========================================================================
    //  Stimulus
    // =========================================================================
    // mode 0: peak 1024 at bin 1, then 512 / 256 / 4 / 1 at octave steps
    // mode 1: nothing but 7 in bin 5
    task publish;
        input integer bank;
        input integer mode;
        integer i, v;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                v = 0;
                if (mode == 0) begin
                    if      (i == 1)  v = 1024;
                    else if (i == 2)  v = 512;
                    else if (i == 4)  v = 256;
                    else if (i == 8)  v = 4;
                    else if (i == 16) v = 1;
                end else begin
                    if (i == 5) v = 7;
                end
                hb[i] = v;
            end

            for (i = 0; i < 256; i = i + 1) begin
                @(negedge wr_clk);
                wr_en   <= 1'b1;
                wr_bank <= bank[0];
                wr_bin  <= i[7:0];
                wr_cnt  <= hb[i];
            end
            @(negedge wr_clk);
            wr_en    <= 1'b0;
            wr_valid <= 1'b1;
            // flip the write bank: the bank just filled becomes the readable one
            wr_bank  <= ~bank[0];
            have_hist = 1;
            repeat (8) @(negedge pix_clk);
        end
    endtask

    // the frame boundary also starts the block's peak scan (258 pixel clocks)
    task latch_frame;
        begin
            @(negedge pix_clk);
            frame_start <= 1'b1;
            @(negedge pix_clk);
            frame_start <= 1'b0;
            repeat (280) @(negedge pix_clk);
        end
    endtask

    integer i;

    initial begin
        for (i = 0; i < 256; i = i + 1) hb[i] = 0;

        repeat (10) @(negedge pix_clk);

        // ---- nothing is drawn before the first completed histogram ----------
        enable = 1'b1;
        check_row(300, 1);
        $display("  before the first publish: %0s",
                 (errors == 0) ? "blank as expected" : "FAILED");

        // ---- first histogram, published into bank 0 -------------------------
        publish(0, 0);
        latch_frame;

        check_row(V_ACTIVE - 1, 1);     // every non-empty bin
        check_row(400, 1);              // y_above 79: 160/140/120 tall bars
        check_row(350, 1);              // y_above 129: only 160/140
        check_row(320, 1);              // y_above 159: only the peak bar
        check_row(300, 1);              // above the band: nothing at all

        // disabled: the overlay must disappear completely
        check_row(V_ACTIVE - 1, 0);

        // ---- second histogram in the other bank -----------------------------
        publish(1, 1);
        latch_frame;
        check_row(V_ACTIVE - 1, 1);
        check_row(300, 1);

        repeat (10) @(negedge pix_clk);
        $display("");
        if (errors == 0) $display("TEST PASS");
        else             $display("TEST FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TEST FAIL (timeout)");
        $finish;
    end

endmodule

