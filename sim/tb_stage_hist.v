// =============================================================================
//  tb_stage_hist.v — self-checking testbench for stage_hist
//
//  Three frames of 8 words x 8 lines (64 words, 256 pixels) are fed at the real
//  camera rate of one word per eight clocks.  stage_hist's WORDS_PER_LINE
//  parameter defaults to 200 for the real camera; the bench overrides it with 8
//  so a frame is only 64 words and three frames fit in a short run.  The
//  luminance distribution is known exactly, and is deliberately packed so that
//  consecutive pixels share a bin: four-in-a-word runs of the same value, plus
//  words that change value at a phase boundary.
//
//    frame 0  mode 0  distribution A  (25 % Y32, 50 % Y128, 25 % Y224)
//    frame 1  mode 1  distribution A  -> equalisation from frame 0's histogram
//    frame 2  mode 2  distribution B  (25 % Y32, 50 % Y200, 25 % Y250)
//
//  Checked, word by word, against a reference model:
//    * word data (bit-exact in modes 0/2, grey-map output in mode 1),
//    * the frame tag on word 0 and the line end on the last word of each line,
//    * exactly 64 words per frame and nothing before the first tag,
//    * the statistic of frame N-1 at the tag of frame N,
//    * the completed histogram bin counts (captured during the finalise scan),
//    * the 256-entry equalisation map: value, monotonicity, dark stays dark.
// =============================================================================
`timescale 1ns / 1ps

module tb_stage_hist;

    localparam integer WPL  = 8;        // words per line
    localparam integer LINES = 8;       // lines per frame
    localparam integer WPFR = WPL * LINES;
    localparam integer NPIX = WPFR * 4;
    localparam integer FRAMES = 3;

    // RGB565 codes whose luminance is exactly the value in the name
    localparam [15:0] P32  = 16'h2104;
    localparam [15:0] P128 = 16'h8410;
    localparam [15:0] P200 = 16'hCE59;
    localparam [15:0] P224 = 16'hE71C;
    localparam [15:0] P250 = 16'hFFFF;

    localparam [2:0] S_SCAN = 3'd3;     // stage_hist FSM state, for probes

    // ---- clock and reset ----------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz, eight clocks per word

    reg rst_n = 1'b0;

    // ---- DUT ----------------------------------------------------------------
    reg  [63:0] s_data  = 64'd0;
    reg         s_valid = 1'b0;
    reg         s_sof   = 1'b0;
    reg         s_eol   = 1'b0;
    reg  [15:0] param   = 16'd0;
    reg  [ 7:0] knob    = 8'd0;
    wire [63:0] m_data;
    wire        m_valid, m_sof, m_eol;
    wire [31:0] stat;

    stage_hist #(
        .WORDS_PER_LINE(WPL),
        .LINES         (LINES)
    ) dut (
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
        .knob   (knob),
        .stat   (stat)
    );

    // =========================================================================
    //  Reference model
    // =========================================================================
    // Y = (77*R5 + 75*G6 + 29*B5) >> 5, the same shifts and adds as the RTL
    function [7:0] y_ref;
        input [15:0] p;
        integer r, g, b, acc;
        begin
            r   = p[15:11];
            g   = p[10:5];
            b   = p[4:0];
            acc = 77*r + 75*g + 29*b;
            y_ref = acc >> 5;
        end
    endfunction

    // the pixel pattern of each frame, pixel index 0..255
    function [15:0] pix_of;
        input integer fr;
        input integer idx;
        integer w, p;
        begin
            w = idx / 4;
            p = idx % 4;
            if (fr == 2) begin
                // distribution B: 64 x Y32, 128 x Y200, 64 x Y250
                if (idx < 64)       pix_of = P32;
                else if (idx < 192) pix_of = P200;
                else                pix_of = P250;
            end else begin
                // distribution A, with the value changes placed on phase
                // boundaries so that consecutive pixels collide in the bin RAM
                if (w <= 14)        pix_of = P32;
                else if (w == 15)   pix_of = (p < 3) ? P32 : P128;
                else if (w == 16)   pix_of = (p == 0) ? P32 : P128;
                else if (w <= 46)   pix_of = P128;
                else if (w == 47)   pix_of = (p < 3) ? P128 : P224;
                else if (w == 48)   pix_of = (p == 0) ? P128 : P224;
                else                pix_of = P224;
            end
        end
    endfunction

    function [63:0] word_of;
        input integer fr;
        input integer w;
        integer base;
        begin
            base = w * 4;
            word_of = {pix_of(fr, base+3), pix_of(fr, base+2),
                       pix_of(fr, base+1), pix_of(fr, base)};
        end
    endfunction

    // cumulative histogram of the two distributions, at bin b
    function integer cum_of;
        input integer which;
        input integer b;
        begin
            if (which == 0) begin
                if (b < 32)        cum_of = 0;
                else if (b < 128)  cum_of = 64;
                else if (b < 224)  cum_of = 192;
                else               cum_of = 256;
            end else begin
                if (b < 32)        cum_of = 0;
                else if (b < 200)  cum_of = 64;
                else if (b < 250)  cum_of = 192;
                else               cum_of = 256;
            end
        end
    endfunction

    // the RTL's scaling: eq = round(255*cum/256), then blend to `strength`
    function [7:0] map_of;
        input integer which;
        input integer b;
        input integer strength;
        integer eq, d;
        begin
            eq = (255 * cum_of(which, b) + 128) >> 8;
            d  = (eq - b) * strength;
            map_of = b + ((d + 128) >>> 8);
        end
    endfunction

    // expected output word
    function [63:0] exp_word;
        input integer fr;
        input integer w;
        integer i, base;
        reg [15:0] p, q;
        reg [7:0]  y, m;
        begin
            base = w * 4;
            exp_word = 64'd0;
            for (i = 0; i < 4; i = i + 1) begin
                p = pix_of(fr, base + i);
                if (fr == 1) begin
                    y = y_ref(p);
                    m = map_of(0, y, 255);
                    q = {m[7:3], m[7:2], m[7:3]};   // mode 1: grey mapping
                end else begin
                    q = p;                          // pass-through
                end
                exp_word[16*i +: 16] = q;
            end
        end
    endfunction

    // =========================================================================
    //  Scoreboard
    // =========================================================================
    integer cf = -1;            // output frame index
    integer cw = 0;             // word index inside it
    integer frames_out = 0;
    integer words_out = 0;
    integer errors = 0;

    task fail;
        input [255:0] what;
        begin
            if (errors < 20)
                $display("FAIL t=%0t: %0s (frame %0d word %0d)",
                         $time, what, cf, cw);
            errors = errors + 1;
        end
    endtask

    task check_stat;
        input [31:0] e;
        begin
            if (stat !== e) begin
                fail("stat");
                $display("      stat=%h expected %h", stat, e);
            end
        end
    endtask

    // completed histogram, captured as the finalise scan reads it
    reg [15:0] hcap [0:255];

    always @(negedge clk) begin
        if ((dut.state == S_SCAN) && (dut.fin_cnt != 9'd0))
            hcap[dut.fin_bin] = dut.hist_q;
    end

    task check_hist;
        input integer which;
        integer i, total;
        reg [15:0] e;
        begin
            total = 0;
            for (i = 0; i < 256; i = i + 1) begin
                total = total + hcap[i];
                e = 16'd0;
                if (which == 0) begin
                    if (i == 32)       e = 16'd64;
                    else if (i == 128) e = 16'd128;
                    else if (i == 224) e = 16'd64;
                end else begin
                    if (i == 32)       e = 16'd64;
                    else if (i == 200) e = 16'd128;
                    else if (i == 250) e = 16'd64;
                end
                if (hcap[i] !== e) begin
                    fail("histogram bin");
                    $display("      bin %0d got %0d expected %0d",
                             i, hcap[i], e);
                end
            end
            if (total != NPIX) begin
                fail("histogram total");
                $display("      total %0d expected %0d", total, NPIX);
            end
        end
    endtask

    task check_map;
        input integer which;
        input integer strength;
        integer i;
        reg [7:0] e;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                e = map_of(which, i, strength);
                if (dut.map_ram[i] !== e) begin
                    fail("map value");
                    $display("      bin %0d got %0d expected %0d",
                             i, dut.map_ram[i], e);
                end
                if ((i > 0) && (dut.map_ram[i] < dut.map_ram[i-1]))
                    fail("map is not monotonic");
            end
            if (dut.map_ram[0] !== 8'd0) fail("map[0] is not zero");

            if (which == 0) begin
                // the dark bin must stay dark, white must reach full scale
                if (dut.map_ram[32] > 8'd96)  fail("dark bin mapped too bright");
                if (dut.map_ram[32] < 8'd32)  fail("dark bin mapped too dark");
                if (dut.map_ram[224] < 8'd250) fail("white not mapped to 255");
            end
        end
    endtask

    // =========================================================================
    //  Output monitor
    // =========================================================================
    always @(negedge clk) begin
        if (m_valid) begin
            if (m_sof) begin
                if ((cf >= 0) && (cw != WPFR)) begin
                    fail("frame word count");
                    $display("      previous frame had %0d words", cw);
                end
                cf = cf + 1;
                cw = 0;
            end else if (cf < 0) begin
                fail("word emitted before the first frame tag");
            end

            if (m_sof !== (cw == 0))                 fail("frame tag position");
            if (m_eol !== ((cw % WPL) == (WPL - 1))) fail("line end position");

            if (cw < WPFR) begin
                if (m_data !== exp_word(cf, cw)) begin
                    fail("word data");
                    $display("      got %h expected %h", m_data, exp_word(cf, cw));
                end
            end

            // the statistic belongs to the frame that just finished
            if (m_sof) begin
                case (cf)
                0:       check_stat(32'h0000_0000);
                1:       check_stat(32'h0000_80E0);  // frame 0: mean 128, p99 224
                2:       check_stat(32'hFF00_80E0);  // frame 1: strength 255
                default: ;
                endcase
            end

            cw = cw + 1;
            words_out = words_out + 1;
        end
    end

    // =========================================================================
    //  Stimulus
    // =========================================================================
    task drive_word;
        input [63:0] d;
        input        sof_i;
        input        eol_i;
        begin
            @(negedge clk);
            s_data  = d;
            s_valid = 1'b1;
            s_sof   = sof_i;
            s_eol   = eol_i;
            @(negedge clk);
            s_valid = 1'b0;
            s_sof   = 1'b0;
            s_eol   = 1'b0;
            repeat (6) @(negedge clk);      // one word every eight clocks
        end
    endtask

    task send_frame;
        input integer fr;
        integer w;
        begin
            for (w = 0; w < WPFR; w = w + 1)
                drive_word(word_of(fr, w), (w == 0),
                           ((w % WPL) == (WPL - 1)));
        end
    endtask

    task wait_final;
        integer guard;
        begin
            guard = 0;
            while (!dut.final_done && (guard < 4000)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 4000) fail("finalise timeout");
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        // the post-reset histogram clear takes 256 clocks
        repeat (320) @(negedge clk);

        // ---- frame 0: pass-through, only the histogram runs ------------------
        knob  = 8'd0;
        param = 16'h00FF;
        send_frame(0);
        wait_final;
        check_stat(32'h0000_80E0);
        check_hist(0);
        check_map(0, 255);

        // ---- frame 1: equalisation with frame 0's histogram ------------------
        knob  = 8'd1;
        param = 16'h00FF;
        send_frame(1);
        wait_final;
        check_stat(32'hFF00_80E0);
        check_hist(0);
        check_map(0, 255);

        // ---- frame 2: auto-exposure reporting, pass-through ------------------
        knob  = 8'd2;
        param = 16'h00FC;               // target 99th percentile = 252
        send_frame(2);
        wait_final;
        check_stat(32'h0019_AAFA);      // sat 25 %, mean 170, p99 250
        check_hist(1);
        check_map(1, 252);

        repeat (30) @(negedge clk);

        frames_out = cf + 1;
        $display("");
        $display("frames=%0d words=%0d (expected %0d x %0d)",
                 frames_out, words_out, FRAMES, WPFR);
        if (frames_out != FRAMES)         fail("frame count");
        if (cw != WPFR)                   fail("last frame is truncated");
        if (words_out != FRAMES * WPFR)   fail("total word count");
        if (stat !== 32'h0019_AAFA)       fail("stat after the last frame");

        if (errors == 0) $display("TEST PASS");
        else             $display("TEST FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TEST FAIL (timeout)");
        $finish;
    end

endmodule
