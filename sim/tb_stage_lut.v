// =============================================================================
//  tb_stage_lut.v — self-checking testbench for the LUT point-operation stage
//
//  A synthetic word stream of WPL = 8 words per line, LINES = 4 lines per frame
//  and NFRAMES = 10 frames is driven into stage_lut.  Every pixel encodes its
//  (frame, line, word, pixel) position, so a word that is late, early, dropped,
//  duplicated or taken from another frame cannot match:
//
//      R = code[ 4: 0] ^ 15,  G = code[10:5] ^ 42,  B = code[6:2] ^ 11
//      code = ((frame*LINES + line)*WPL + word)*4 + pixel
//
//  with one fully saturated pixel and one black pixel per frame so the
//  saturation counter has something to count.
//
//  The scoreboard checks, word by word:
//
//    * mode 0 (and the reserved modes 6, 7) is bit-identical to the raw stream,
//      compared against the words the source actually drove,
//    * every other mode against a reference model implemented here: threshold
//      on luminance, brightness/contrast, gamma, false colour, invert,
//    * m_sof on the first word of every frame and m_eol on the last word of
//      every line, and nothing is emitted before the first frame tag,
//    * exactly WORDS_PER_LINE * LINES words per frame, for every frame,
//    * the latency is the documented LAT words,
//    * stat is the reference statistic of the frame that just finished:
//      above-threshold count, mean luminance and saturated-pixel count.
//
//  Frames 0..2 are the three-frame contract check (identity, threshold 128,
//  threshold 0); frames 3..9 sweep the remaining modes so that no mode is left
//  untested.  stat is published on the next frame tag, so the last frame's
//  statistic is the one frame the run cannot check.
// =============================================================================
`timescale 1ns / 1ps

module tb_stage_lut;

    localparam integer WPL     = 8;             // words per line
    localparam integer LINES   = 4;             // lines per frame
    localparam integer WPFR    = WPL * LINES;   // 32 words per frame
    localparam integer PIX     = WPFR * 4;      // 128 pixels per frame
    localparam integer NFRAMES = 10;
    localparam integer LAT     = 3;             // documented stage latency

    // ---- clock and reset ----------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- source -------------------------------------------------------------
    reg  [63:0] src_data;
    reg         src_valid;
    reg         src_sof;
    wire        src_eol;

    img_geom #(.WORDS_PER_LINE(WPL)) u_geom (
        .clk  (clk),
        .rst_n(rst_n),
        .sof  (src_sof),
        .valid(src_valid),
        .eol  (src_eol),
        .wx   (),
        .wy   ()
    );

    // ---- control ------------------------------------------------------------
    reg [15:0] param;
    reg [ 7:0] knob;

    // ---- stage under test ---------------------------------------------------
    wire [63:0] m_data;
    wire        m_valid;
    wire        m_sof;
    wire        m_eol;
    wire [31:0] stat;

    stage_lut #(
        .WORDS_PER_LINE (WPL),
        .LINES_PER_FRAME(LINES)
    ) u_dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_data (src_data),
        .s_valid(src_valid),
        .s_sof  (src_sof),
        .s_eol  (src_eol),
        .m_data (m_data),
        .m_valid(m_valid),
        .m_sof  (m_sof),
        .m_eol  (m_eol),
        .param  (param),
        .knob   (knob),
        .stat   (stat)
    );

    // =========================================================================
    //  Stimulus schedule (also read by the reference model) and scoreboard state
    // =========================================================================
    reg [2:0]  mode_q [0:NFRAMES-1];        // mode of each frame
    reg [15:0] par_q  [0:NFRAMES-1];        // param of each frame
    reg [63:0] raw_q  [0:NFRAMES*WPFR-1];   // the words the source drove

    // =========================================================================
    //  Reference model
    // =========================================================================
    function [7:0] ex5;                         // 5 -> 8 bits, bit replication
        input [4:0] v;
        begin
            ex5 = {v, v[4:2]};
        end
    endfunction

    function [7:0] ex6;                         // 6 -> 8 bits
        input [5:0] v;
        begin
            ex6 = {v, v[5:4]};
        end
    endfunction

    function [7:0] luma;                        // (R + 2G + B) / 4
        input [7:0] r;
        input [7:0] g;
        input [7:0] b;
        begin
            luma = ({2'b00, r} + {1'b0, g, 1'b0} + {2'b00, b}) >> 2;
        end
    endfunction

    function [7:0] ref_affine;                  // mode 1
        input [7:0] v;
        input [3:0] gain;
        input [3:0] offs;
        integer s;
        begin
            s = (v * gain) / 8 + offs - 8;
            if (s < 0)        ref_affine = 8'd0;
            else if (s > 255) ref_affine = 8'd255;
            else              ref_affine = s[7:0];
        end
    endfunction

    function [7:0] ref_gamma;                   // mode 2, real arithmetic
        input [7:0] v;
        integer g;
        begin
            if (v == 0) begin
                ref_gamma = 8'd0;
            end else begin
                g = $rtoi(255.0 * $pow(v / 255.0, 0.7) + 0.5);
                if (g > 255) g = 255;
                ref_gamma = g[7:0];
            end
        end
    endfunction

    function [23:0] ref_false;                  // mode 4
        input [7:0] y;
        reg [4:0] pr;
        reg [5:0] pg;
        reg [4:0] pb;
        reg [7:0] t;
        begin
            if (y < 8'd64) begin
                pr = 5'd0;
                pg = y[5:0];
                pb = 5'd31;
            end else if (y < 8'd192) begin
                t  = y - 8'd64;
                pr = t[6:2];
                pg = 6'd63;
                pb = 5'd31 - t[6:2];
            end else begin
                t  = y - 8'd192;
                pr = 5'd31;
                pg = 6'd63 - t[5:0];
                pb = 5'd0;
            end
            ref_false = {pr, pr[4:2], pg, pg[5:4], pb, pb[4:2]};
        end
    endfunction

    function [15:0] ref_pix;
        input [2:0]  mode;
        input [15:0] par;
        input [15:0] p;
        reg [7:0] r8, g8, b8, y;
        reg [7:0] nr, ng, nb;
        begin
            r8 = ex5(p[15:11]);
            g8 = ex6(p[10:5]);
            b8 = ex5(p[4:0]);
            y  = luma(r8, g8, b8);
            case (mode)
            3'd1: begin
                nr = ref_affine(r8, par[3:0], par[7:4]);
                ng = ref_affine(g8, par[3:0], par[7:4]);
                nb = ref_affine(b8, par[3:0], par[7:4]);
            end
            3'd2: begin
                nr = ref_gamma(r8);
                ng = ref_gamma(g8);
                nb = ref_gamma(b8);
            end
            3'd3: begin
                nr = (y > par[7:0]) ? 8'hFF : 8'h00;
                ng = nr;
                nb = nr;
            end
            3'd4: begin
                {nr, ng, nb} = ref_false(y);
            end
            3'd5: begin
                nr = ~r8;
                ng = ~g8;
                nb = ~b8;
            end
            default: begin
                nr = r8;
                ng = g8;
                nb = b8;
            end
            endcase
            // 8 -> 5/6/5 by truncation, exactly as the stage does
            ref_pix = {nr[7:3], ng[7:2], nb[7:3]};
        end
    endfunction

    // modes 0, 6 and 7 are identity: the input word itself, no round trip
    function [63:0] ref_word;
        input [2:0]  mode;
        input [15:0] par;
        input [63:0] w;
        integer i;
        reg [63:0] acc;
        begin
            if ((mode == 3'd0) || (mode > 3'd5)) begin
                ref_word = w;
            end else begin
                acc = 64'd0;
                for (i = 0; i < 4; i = i + 1)
                    acc[i*16 +: 16] = ref_pix(mode, par, w[i*16 +: 16]);
                ref_word = acc;
            end
        end
    endfunction

    // ---- the synthetic picture ----------------------------------------------
    function [15:0] px;
        input integer f;
        input integer l;
        input integer w;
        input integer p;
        integer code;
        begin
            code = ((f * LINES + l) * WPL + w) * 4 + p;
            if ((l == 0) && (w == 0) && (p == 0)) begin
                px = 16'hFFFF;                  // one saturated pixel per frame
            end else if ((l == LINES - 1) && (w == WPL - 1) && (p == 3)) begin
                px = 16'h0000;                  // one black pixel per frame
            end else begin
                px = {code[4:0] ^ 5'h15, code[10:5] ^ 6'h2A, code[6:2] ^ 5'h0B};
            end
        end
    endfunction

    function [63:0] pat_word;
        input integer f;
        input integer l;
        input integer w;
        reg [63:0] acc;
        begin
            acc        = 64'd0;
            acc[15:0]  = px(f, l, w, 0);
            acc[31:16] = px(f, l, w, 1);
            acc[47:32] = px(f, l, w, 2);
            acc[63:48] = px(f, l, w, 3);
            pat_word   = acc;
        end
    endfunction

    // ---- expected statistic -------------------------------------------------
    function [31:0] exp_stat;
        input integer fr;
        integer l, w, p;
        integer above, sum, sat, mean;
        reg [15:0] pv;
        reg [15:0] lvl;
        reg [7:0]  r8, g8, b8, y;
        begin
            above = 0;
            sum   = 0;
            sat   = 0;
            lvl   = par_q[fr];
            for (l = 0; l < LINES; l = l + 1)
                for (w = 0; w < WPL; w = w + 1)
                    for (p = 0; p < 4; p = p + 1) begin
                        pv = px(fr, l, w, p);
                        r8 = ex5(pv[15:11]);
                        g8 = ex6(pv[10:5]);
                        b8 = ex5(pv[4:0]);
                        y  = luma(r8, g8, b8);
                        if (y > lvl[7:0]) above = above + 1;
                        sum = sum + y;
                        if ((pv[15:11] == 5'h1F) && (pv[10:5] == 6'h3F) &&
                            (pv[4:0] == 5'h1F)) sat = sat + 1;
                    end
            if (above > 65535) above = 65535;
            if (sat > 255)     sat   = 255;
            mean = sum / PIX;
            exp_stat = {sat[7:0], mean[7:0], above[15:0]};
        end
    endfunction

    // =========================================================================
    //  Scoreboard state
    // =========================================================================
    integer of_cnt           = 0;       // output frames started
    integer ow               = 0;       // word index in the output frame
    integer errs             = 0;
    integer words_out        = 0;
    integer words_before_tag = 0;
    integer frames_done      = 0;
    integer stat_checks      = 0;

    time t_in_tag  = 0;
    time t_out_tag = 0;

    task fail;
        input [255:0] what;
        begin
            if (errs < 24)
                $display("FAIL t=%0t: %0s (frame %0d word %0d)",
                         $time, what, of_cnt - 1, ow);
            errs = errs + 1;
        end
    endtask

    // latency: the first frame tag in and the first frame tag out
    always @(posedge clk) begin
        if (src_valid && src_sof && (t_in_tag == 0))  t_in_tag  = $time;
        if (m_valid   && m_sof   && (t_out_tag == 0)) t_out_tag = $time;
    end

    // ---- word-by-word scoreboard -------------------------------------------
    integer fi, li, wi;
    reg [63:0] expect;

    always @(posedge clk) begin
        if (m_valid) begin
            if ((of_cnt == 0) && !m_sof) words_before_tag = words_before_tag + 1;

            if (m_sof) begin
                if ((of_cnt > 0) && (ow != WPFR)) begin
                    fail("frame length");
                    $display("      frame %0d had %0d words, expected %0d",
                             of_cnt - 1, ow, WPFR);
                end
                ow          = 0;
                of_cnt      = of_cnt + 1;
                frames_done = frames_done + 1;
            end

            if ((ow == 0) && !m_sof) fail("first word of a frame without a tag");

            fi = of_cnt - 1;
            if ((fi >= 0) && (fi < NFRAMES)) begin
                li     = ow / WPL;
                wi     = ow % WPL;
                expect = ref_word(mode_q[fi], par_q[fi], pat_word(fi, li, wi));
                if (m_data !== expect) begin
                    fail("word data");
                    $display("      got %h expected %h (mode %0d)",
                             m_data, expect, mode_q[fi]);
                end
                // identity, checked against the words the source really drove
                if (((mode_q[fi] == 3'd0) || (mode_q[fi] > 3'd5)) &&
                    (m_data !== raw_q[fi*WPFR + ow])) begin
                    fail("identity is not bit-exact");
                end
            end

            if (m_sof !== (ow == 0))           fail("frame tag position");
            if (m_eol !== ((ow % WPL) == (WPL - 1))) fail("line end position");

            ow        = ow + 1;
            words_out = words_out + 1;
        end
    end

    // ---- statistic of the frame that just finished --------------------------
    task check_stat;
        input integer fr;
        reg [31:0] want;
        begin
            want = exp_stat(fr);
            stat_checks = stat_checks + 1;
            if (stat !== want) begin
                fail("statistic");
                $display("      stat %h expected %h (frame %0d)", stat, want, fr);
            end else begin
                $display("  stat frame %0d: %h  above=%0d mean=%0d saturated=%0d",
                         fr, stat, stat[15:0], stat[23:16], stat[31:24]);
            end
        end
    endtask

    // =========================================================================
    //  Stimulus
    // =========================================================================
    integer f, l, w;

    initial begin
        // frame 0..2: the three-frame contract check
        mode_q[0] = 3'd0; par_q[0] = 16'h0000;   // identity, bit-exact
        mode_q[1] = 3'd3; par_q[1] = 16'h0080;   // threshold at 128
        mode_q[2] = 3'd3; par_q[2] = 16'h0000;   // threshold at 0
        // frame 3..9: mode sweep, one frame each
        mode_q[3] = 3'd1; par_q[3] = 16'h00AC;   // gain 12, offset +2
        mode_q[4] = 3'd1; par_q[4] = 16'h0071;   // gain  1, offset -1 (clamps)
        mode_q[5] = 3'd2; par_q[5] = 16'h0000;   // gamma 0.7
        mode_q[6] = 3'd4; par_q[6] = 16'h0000;   // false colour
        mode_q[7] = 3'd5; par_q[7] = 16'h0000;   // invert
        mode_q[8] = 3'd6; par_q[8] = 16'h0000;   // reserved -> identity
        mode_q[9] = 3'd7; par_q[9] = 16'h0000;   // reserved -> identity

        src_data  = 64'd0;
        src_valid = 1'b0;
        src_sof   = 1'b0;
        param     = 16'd0;
        knob      = 8'd0;

        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        for (f = 0; f < NFRAMES; f = f + 1) begin
            // the control word is frame-stable: set it before the frame tag
            knob  = {5'd0, mode_q[f]};
            param = par_q[f];
            repeat (2) @(negedge clk);

            for (l = 0; l < LINES; l = l + 1) begin
                for (w = 0; w < WPL; w = w + 1) begin
                    @(negedge clk);
                    src_valid = 1'b1;
                    src_sof   = (l == 0) && (w == 0);
                    src_data  = pat_word(f, l, w);
                    raw_q[f*WPFR + l*WPL + w] = src_data;
                end
                // line gap: blanking must not disturb the tags
                @(negedge clk);
                src_valid = 1'b0;
                src_sof   = 1'b0;
                @(negedge clk);
            end

            // the frame's words are in, stat still shows the previous frame
            if (f > 0) check_stat(f - 1);
        end

        // drain the pipeline
        repeat (24) @(negedge clk);

        $display("");
        $display("frames out=%0d (expected %0d), words out=%0d (expected %0d)",
                 frames_done, NFRAMES, words_out, NFRAMES * WPFR);
        $display("words before the first frame tag=%0d (must be 0)",
                 words_before_tag);
        $display("latency=%0d words (expected %0d)",
                 (t_out_tag - t_in_tag) / 10, LAT);
        $display("stat checks=%0d (frames 0..%0d)", stat_checks, NFRAMES - 2);

        if (frames_done != NFRAMES) begin
            $display("FAIL: %0d of %0d frames came through", frames_done, NFRAMES);
            errs = errs + 1;
        end
        if (words_out != NFRAMES * WPFR) begin
            $display("FAIL: %0d words out, expected %0d",
                     words_out, NFRAMES * WPFR);
            errs = errs + 1;
        end
        if (words_before_tag != 0) begin
            $display("FAIL: emitted words before the first frame tag");
            errs = errs + 1;
        end
        if ((t_out_tag - t_in_tag) / 10 != LAT) begin
            $display("FAIL: latency is not %0d words", LAT);
            errs = errs + 1;
        end

        if (errs == 0) $display("TEST PASS");
        else           $display("TEST FAIL (%0d errors)", errs);
        $finish;
    end

    initial begin
        #500_000;
        $display("TEST FAIL (timeout)");
        $finish;
    end

endmodule
