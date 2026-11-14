// =============================================================================
//  tb_stage_win3x3.v — self-checking test for stage_win3x3
//
//  Geometry is deliberately tiny: 8 words per line (32 pixels), 6 lines, 3
//  frames.  With eight words per line the window wraps every line, which is the
//  point of the test.  Lines are separated by a non-multiple-of-eight blanking
//  gap, so a stage that indexed its line buffers with a free-running pointer
//  instead of the word position would fail immediately.
//
//  For every mode the bench builds a reference frame in an array, feeds the
//  same frame three times, and compares every output word with the reference
//  (clamp/duplicate border policy, identical fixed-point arithmetic).  Interior
//  and border pixels are counted separately.  It also checks:
//
//    * m_sof on the first word of every frame and only there,
//    * m_eol on the last word of every line and only there,
//    * exactly WORDS_PER_LINE * LINES words per frame,
//    * that the statistic belongs to the frame that just finished,
//    * the advertised latency of two lines plus four words.
//
//  With three input frames the pipeline leaves two complete output frames; the
//  third is still in flight when the stimulus stops and is not checked.
// =============================================================================
`timescale 1ns / 1ps

module tb_stage_win3x3;

    localparam integer WPL    = 8;              // words per line
    localparam integer LINES  = 6;
    localparam integer FRAMES = 3;
    localparam integer WIDTH  = WPL * 4;        // pixels per line
    localparam integer NPIX   = WIDTH * LINES;
    localparam integer FRAME_WORDS = WPL * LINES;
    localparam integer GROUPS = 9;
    localparam integer GAP_LINE  = 3;           // extra blanking between lines
    localparam integer GAP_FRAME = 7;           // extra blanking between frames

    // ---- clock and DUT ------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n   = 1'b0;
    reg [63:0] s_data  = 64'd0;
    reg        s_valid = 1'b0;
    reg        s_sof   = 1'b0;
    reg        s_eol   = 1'b0;

    wire [63:0] m_data;
    wire        m_valid;
    wire        m_sof;
    wire        m_eol;
    wire [31:0] stat;

    reg  [2:0]  mode  = 3'd0;
    reg  [15:0] param = 16'd0;

    stage_win3x3 #(
        .WORDS_PER_LINE(WPL)
    ) u_dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data (s_data),
        .s_valid(s_valid),
        .s_sof  (s_sof),
        .s_eol  (s_eol),
        .m_data (m_data),
        .m_valid(m_valid),
        .m_sof  (m_sof),
        .m_eol  (m_eol),
        .param  (param),
        .knob   ({5'd0, mode}),
        .stat   (stat)
    );

    // =========================================================================
    //  Source / reference arrays
    // =========================================================================
    reg [15:0] in_pix [0:FRAMES*NPIX-1];
    reg [15:0] e_pix  [0:FRAMES*NPIX-1];
    reg [15:0] e_chg  [0:FRAMES-1];
    reg [15:0] e_abv  [0:FRAMES-1];

    function integer fidx;
        input integer f;
        input integer y;
        input integer x;
        begin fidx = (f * LINES + y) * WIDTH + x; end
    endfunction

    // deterministic two-dimensional pattern: every channel changes with x, y
    // and the frame number, so a wrong neighbour or a wrong frame shows up
    function [15:0] pat;
        input integer f;
        input integer y;
        input integer x;
        reg [4:0] r;
        reg [5:0] g;
        reg [4:0] b;
        begin
            r = (x * 3 + y * 5 + f * 7 + 2) & 5'h1F;
            g = (x * 2 + y * 11 + f * 13 + 8) & 6'h3F;
            b = (x * 5 + y * 3 + f * 11 + 16) & 5'h1F;
            pat = {r, g, b};
        end
    endfunction

    // =========================================================================
    //  Reference model — deliberately different structure from the RTL where it
    //  matters (full bubble sort for the median, loops for min/max), same
    //  fixed-point arithmetic and same clamp/duplicate border policy.
    // =========================================================================
    reg [15:0] w9 [0:8];                    // tl tc tr / ml mc mr / bl bc br

    function [7:0] w8r;
        input [15:0] p;
        begin w8r = {p[15:11], p[15:13]}; end
    endfunction

    function [7:0] w8g;
        input [15:0] p;
        begin w8g = {p[10:5], p[10:9]}; end
    endfunction

    function [7:0] w8b;
        input [15:0] p;
        begin w8b = {p[4:0], p[4:2]}; end
    endfunction

    function [7:0] cl8;
        input signed [13:0] v;
        begin
            if (v < 14'sd0)        cl8 = 8'd0;
            else if (v > 14'sd255) cl8 = 8'd255;
            else                   cl8 = v[7:0];
        end
    endfunction

    function [7:0] mean9;
        input [11:0] s;
        begin mean9 = (s * 57) >> 9; end
    endfunction

    function [16:0] model_filt;
        input [2:0]  md;
        input [15:0] prm;

        reg [7:0] rr [0:8];
        reg [7:0] gg [0:8];
        reg [7:0] bb [0:8];
        reg [7:0] sv [0:8];
        reg [7:0] yv [0:8];
        reg [7:0] tmp, mn, mx, medr, medg, medb;
        reg [11:0] sr, sg, sb;
        reg [7:0]  avr, avg, avb;
        reg [10:0] sx1, sx2, sy1, sy2;
        reg signed [11:0] gx, gy;
        reg [11:0] ax, ay, mag;
        reg [7:0]  gry, or8, og8, ob8;
        reg        above;
        reg signed [13:0] bias, v14;
        integer i, j;

        begin
            for (i = 0; i < 9; i = i + 1) begin
                rr[i] = w8r(w9[i]);
                gg[i] = w8g(w9[i]);
                bb[i] = w8b(w9[i]);
            end

            sr = 12'd0; sg = 12'd0; sb = 12'd0;
            for (i = 0; i < 9; i = i + 1) begin
                sr = sr + rr[i];
                sg = sg + gg[i];
                sb = sb + bb[i];
            end
            avr = mean9(sr);
            avg = mean9(sg);
            avb = mean9(sb);

            for (i = 0; i < 9; i = i + 1)
                yv[i] = (rr[i] * 77 + gg[i] * 150 + bb[i] * 29 + 128) >> 8;

            sx1 = yv[2] + (yv[5] << 1) + yv[8];
            sx2 = yv[0] + (yv[3] << 1) + yv[6];
            sy1 = yv[6] + (yv[7] << 1) + yv[8];
            sy2 = yv[0] + (yv[1] << 1) + yv[2];
            gx  = $signed({1'b0, sx1}) - $signed({1'b0, sx2});
            gy  = $signed({1'b0, sy1}) - $signed({1'b0, sy2});
            ax  = gx[11] ? (~gx + 12'd1) : gx;
            ay  = gy[11] ? (~gy + 12'd1) : gy;
            mag = ax + ay;

            above = 1'b0;
            bias  = {{6{prm[7]}}, prm[7:0]};
            or8 = 8'd0; og8 = 8'd0; ob8 = 8'd0;

            case (md)
            3'd0, 3'd6, 3'd7: begin
                or8 = cl8($signed({6'b0, avr}) + bias);
                og8 = cl8($signed({6'b0, avg}) + bias);
                ob8 = cl8($signed({6'b0, avb}) + bias);
            end
            3'd1: begin
                above = ({4'd0, mag} > prm);
                if (above) begin
                    gry = (mag > 12'd255) ? 8'd255 : mag[7:0];
                    or8 = gry; og8 = gry; ob8 = gry;
                end
            end
            3'd2: begin
                for (i = 0; i < 9; i = i + 1) sv[i] = rr[i];
                for (i = 0; i < 8; i = i + 1)
                    for (j = 0; j < 8 - i; j = j + 1)
                        if (sv[j] > sv[j+1]) begin
                            tmp = sv[j]; sv[j] = sv[j+1]; sv[j+1] = tmp;
                        end
                medr = sv[4];

                for (i = 0; i < 9; i = i + 1) sv[i] = gg[i];
                for (i = 0; i < 8; i = i + 1)
                    for (j = 0; j < 8 - i; j = j + 1)
                        if (sv[j] > sv[j+1]) begin
                            tmp = sv[j]; sv[j] = sv[j+1]; sv[j+1] = tmp;
                        end
                medg = sv[4];

                for (i = 0; i < 9; i = i + 1) sv[i] = bb[i];
                for (i = 0; i < 8; i = i + 1)
                    for (j = 0; j < 8 - i; j = j + 1)
                        if (sv[j] > sv[j+1]) begin
                            tmp = sv[j]; sv[j] = sv[j+1]; sv[j+1] = tmp;
                        end
                medb = sv[4];

                or8 = medr; og8 = medg; ob8 = medb;
            end
            3'd3: begin
                mn = 8'd255;
                for (i = 0; i < 9; i = i + 1) if (rr[i] < mn) mn = rr[i];
                or8 = mn;
                mn = 8'd255;
                for (i = 0; i < 9; i = i + 1) if (gg[i] < mn) mn = gg[i];
                og8 = mn;
                mn = 8'd255;
                for (i = 0; i < 9; i = i + 1) if (bb[i] < mn) mn = bb[i];
                ob8 = mn;
            end
            3'd4: begin
                mx = 8'd0;
                for (i = 0; i < 9; i = i + 1) if (rr[i] > mx) mx = rr[i];
                or8 = mx;
                mx = 8'd0;
                for (i = 0; i < 9; i = i + 1) if (gg[i] > mx) mx = gg[i];
                og8 = mx;
                mx = 8'd0;
                for (i = 0; i < 9; i = i + 1) if (bb[i] > mx) mx = bb[i];
                ob8 = mx;
            end
            default: begin                       // 5: 5*I - 4*blur
                v14 = ($signed({6'b0, rr[4]}) * 14'sd5) -
                      ($signed({6'b0, avr})  * 14'sd4);
                or8 = cl8(v14);
                v14 = ($signed({6'b0, gg[4]}) * 14'sd5) -
                      ($signed({6'b0, avg})  * 14'sd4);
                og8 = cl8(v14);
                v14 = ($signed({6'b0, bb[4]}) * 14'sd5) -
                      ($signed({6'b0, avb})  * 14'sd4);
                ob8 = cl8(v14);
            end
            endcase

            model_filt = {above, or8[7:3], og8[7:2], ob8[7:3]};
        end
    endfunction

    task build_model;
        input [2:0]  md;
        input [15:0] prm;
        integer f, y, x, i, j, xx, yy;
        reg [15:0] outp;
        reg [16:0] fp;
        begin
            for (f = 0; f < FRAMES; f = f + 1) begin
                e_chg[f] = 16'd0;
                e_abv[f] = 16'd0;
                for (y = 0; y < LINES; y = y + 1) begin
                    for (x = 0; x < WIDTH; x = x + 1) begin
                        for (j = 0; j < 3; j = j + 1) begin
                            yy = y + j - 1;
                            if (yy < 0) yy = 0;
                            if (yy > LINES - 1) yy = LINES - 1;
                            for (i = 0; i < 3; i = i + 1) begin
                                xx = x + i - 1;
                                if (xx < 0) xx = 0;
                                if (xx > WIDTH - 1) xx = WIDTH - 1;
                                w9[j*3 + i] = in_pix[fidx(f, yy, xx)];
                            end
                        end
                        fp   = model_filt(md, prm);
                        outp = fp[15:0];
                        e_pix[fidx(f, y, x)] = outp;
                        if (outp != w9[4]) e_chg[f] = e_chg[f] + 16'd1;
                        if (fp[16])        e_abv[f] = e_abv[f] + 16'd1;
                    end
                end
            end
        end
    endtask

    // =========================================================================
    //  Stimulus
    // =========================================================================
    integer f0, y0, x0, gi;
    integer init_errs;
    reg [2:0]  g_mode  [0:GROUPS-1];
    reg [15:0] g_param [0:GROUPS-1];

    task drive_word;
        input [63:0] d;
        input        sof;
        input        eol;
        begin
            @(negedge clk);
            s_valid = 1'b1;
            s_data  = d;
            s_sof   = sof;
            s_eol   = eol;
            @(negedge clk);
            s_valid = 1'b0;
            s_sof   = 1'b0;
            s_eol   = 1'b0;
            repeat (6) @(negedge clk);
        end
    endtask

    task drive_frame;
        input integer f;
        integer y, w;
        reg [63:0] d;
        begin
            for (y = 0; y < LINES; y = y + 1) begin
                for (w = 0; w < WPL; w = w + 1) begin
                    d = {in_pix[fidx(f, y, 4*w + 3)],
                         in_pix[fidx(f, y, 4*w + 2)],
                         in_pix[fidx(f, y, 4*w + 1)],
                         in_pix[fidx(f, y, 4*w)]};
                    drive_word(d, (y == 0) && (w == 0), (w == WPL - 1));
                end
                if (y != LINES - 1)
                    repeat (GAP_LINE) @(negedge clk);
            end
        end
    endtask

    // =========================================================================
    //  Scoreboard
    // =========================================================================
    reg        tb_clr;
    reg        score_on;
    reg        seen_tag;
    integer    errs;
    integer    int_ok, int_bad, bor_ok, bor_bad;
    integer    frames_done;
    integer    of, ow;
    integer    in_words, lat_start, lat_words;

    integer si;
    reg [15:0] got_px, exp_px;
    reg        is_border;

    task fail;
        input [255:0] msg;
        begin
            if (errs < 25)
                $display("FAIL t=%0t: %0s (frame %0d word %0d)", $time, msg, of, ow);
            errs = errs + 1;
        end
    endtask

    always @(posedge clk) begin
        if (s_valid) in_words = in_words + 1;
        if (s_valid && s_sof) lat_start = in_words;

        if (tb_clr) begin
            errs        = 0;
            int_ok      = 0;
            int_bad     = 0;
            bor_ok      = 0;
            bor_bad     = 0;
            frames_done = 0;
            of          = 0;
            ow          = 0;
            seen_tag    = 0;
            score_on    = 1;
            in_words    = 0;
            lat_start   = 0;
            lat_words   = -1;
        end else if (m_valid) begin
            if (m_sof) begin
                if (!seen_tag) begin
                    if (stat !== 32'd0) fail("stat not zero before the first frame");
                    lat_words = in_words - lat_start;
                    seen_tag  = 1;
                    of        = 0;
                    ow        = 0;
                end else begin
                    if (ow != FRAME_WORDS) begin
                        fail("frame word count");
                        $display("      frame %0d has %0d words, expected %0d",
                                 of, ow, FRAME_WORDS);
                    end
                    if (stat !== {e_abv[of], e_chg[of]}) begin
                        fail("statistic");
                        $display("      stat=%h expected %h (above=%0d changed=%0d)",
                                 stat, {e_abv[of], e_chg[of]}, e_abv[of], e_chg[of]);
                    end
                    frames_done = frames_done + 1;
                    of          = of + 1;
                    ow          = 0;
                    if (of >= 2) score_on = 0;      // two complete frames is enough
                end
            end

            if (seen_tag && score_on && (of < 2)) begin
                if (m_sof !== (ow == 0)) fail("frame tag position");
                if (m_eol !== ((ow % WPL) == (WPL - 1))) fail("line end position");

                for (si = 0; si < 4; si = si + 1) begin
                    got_px = (m_data >> (16 * si)) & 16'hFFFF;
                    exp_px = e_pix[fidx(of, ow / WPL, 4 * (ow % WPL) + si)];
                    is_border = ((4 * (ow % WPL) + si) == 0) ||
                                ((4 * (ow % WPL) + si) == WIDTH - 1) ||
                                ((ow / WPL) == 0) || ((ow / WPL) == LINES - 1);
                    if (got_px === exp_px) begin
                        if (is_border) bor_ok = bor_ok + 1;
                        else           int_ok = int_ok + 1;
                    end else begin
                        if (is_border) bor_bad = bor_bad + 1;
                        else           int_bad = int_bad + 1;
                        fail("pixel");
                        $display("      frame %0d word %0d pixel %0d got %h expected %h",
                                 of, ow, si, got_px, exp_px);
                    end
                end

                ow = ow + 1;
            end
        end
    end

    // =========================================================================
    //  Main sequence
    // =========================================================================
    initial begin
        g_mode[0] = 3'd0; g_param[0] = 16'h0010;    // box mean, +16 bias
        g_mode[1] = 3'd0; g_param[1] = 16'h00F8;    // box mean, -8 bias (clamps)
        g_mode[2] = 3'd1; g_param[2] = 16'd60;      // Sobel, threshold 60
        g_mode[3] = 3'd2; g_param[3] = 16'h0000;    // median
        g_mode[4] = 3'd3; g_param[4] = 16'h0000;    // erode
        g_mode[5] = 3'd4; g_param[5] = 16'h0000;    // dilate
        g_mode[6] = 3'd5; g_param[6] = 16'h0000;    // sharpen
        g_mode[7] = 3'd6; g_param[7] = 16'h0008;    // reserve -> box +8
        g_mode[8] = 3'd7; g_param[8] = 16'h0008;    // reserve -> box +8

        init_errs = 0;
        tb_clr    = 1'b0;
        score_on  = 1'b0;
        mode      = 3'd0;
        param     = 16'd0;

        for (f0 = 0; f0 < FRAMES; f0 = f0 + 1)
            for (y0 = 0; y0 < LINES; y0 = y0 + 1)
                for (x0 = 0; x0 < WIDTH; x0 = x0 + 1)
                    in_pix[fidx(f0, y0, x0)] = pat(f0, y0, x0);

        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        for (gi = 0; gi < GROUPS; gi = gi + 1) begin
            mode  = g_mode[gi];
            param = g_param[gi];
            build_model(g_mode[gi], g_param[gi]);

            // reset DUT and scoreboard together
            tb_clr = 1'b1;
            rst_n  = 1'b0;
            repeat (4) @(negedge clk);
            rst_n  = 1'b1;
            tb_clr = 1'b0;
            repeat (2) @(negedge clk);

            for (f0 = 0; f0 < FRAMES; f0 = f0 + 1) begin
                drive_frame(f0);
                if (f0 != FRAMES - 1)
                    repeat (GAP_FRAME) @(negedge clk);
            end

            // let the tail of the second frame drain
            repeat (80) @(negedge clk);

            $display("mode %0d param %04h: interior %0d ok / %0d bad, border %0d ok / %0d bad, frames %0d, latency %0d words",
                     g_mode[gi], g_param[gi], int_ok, int_bad, bor_ok, bor_bad,
                     frames_done, lat_words);

            if (frames_done != 2) begin
                $display("FAIL: mode %0d produced %0d complete frames, expected 2",
                         g_mode[gi], frames_done);
                init_errs = init_errs + 1;
            end
            if (int_bad != 0 || bor_bad != 0) begin
                $display("FAIL: mode %0d mismatches (interior %0d, border %0d)",
                         g_mode[gi], int_bad, bor_bad);
                init_errs = init_errs + 1;
            end
            if (lat_words != 2 * WPL + 4) begin
                $display("FAIL: mode %0d latency %0d words, expected %0d",
                         g_mode[gi], lat_words, 2 * WPL + 4);
                init_errs = init_errs + 1;
            end
            if (int_ok + bor_ok < 2 * FRAME_WORDS * 4) begin
                $display("FAIL: mode %0d only checked %0d pixels",
                         g_mode[gi], int_ok + bor_ok);
                init_errs = init_errs + 1;
            end
        end

        repeat (20) @(negedge clk);
        $display("");
        $display("groups=%0d pixel mismatches=%0d other errors=%0d", GROUPS, errs, init_errs);
        if (errs == 0 && init_errs == 0) $display("TEST PASS");
        else                             $display("TEST FAIL");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL: timeout");
        $display("TEST FAIL");
        $finish;
    end

endmodule
