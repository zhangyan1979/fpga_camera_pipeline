// =============================================================================
//  tb_stage_seg.v — self-checking test for stage_seg
//
//  The scene is 8 words (32 pixels) by 8 lines and is drawn in three frames.
//  The 1x3 horizontal erosion is always active, so the expected boxes are the
//  boxes after erosion, not the drawn rectangles:
//
//    frame 0  pass-through:
//               red   rectangle (0,0)-(3,3)   touches the left and top edge;
//                     erosion keeps x=0 (edge duplication) and removes x=3
//               green rectangle (10,2)-(17,5)
//    frame 1  pass-through, different positions, plus a single red noise pixel
//             at (24,6) and a single blue noise pixel at (28,1); both must be
//             removed and must not extend or create a box
//    frame 2  paint mode: a near-red rectangle (5,4)-(8,7) that falls in the
//             label-0 box; erosion keeps columns 6..7, which are painted flat
//
//  The monitor checks, word by word, pass-through bit exactness (or the painted
//  picture), the frame tag, the line-end tag and the frame length.  After every
//  frame the report registers and stat are checked against the exact expected
//  boxes; the report is also checked after the next frame's first line has been
//  accepted, to prove that the completed frame stays reported while the next
//  accumulates.
// =============================================================================
`timescale 1ns / 1ps

module tb_stage_seg;

    localparam integer WPL    = 8;          // words per line
    localparam integer LINES  = 8;          // lines per frame
    localparam integer WPFR   = WPL * LINES;
    localparam integer FRAMES = 3;

    localparam [15:0] C_GREY  = 16'h8410;
    localparam [15:0] C_RED   = 16'hF800;
    localparam [15:0] C_GREEN = 16'h07E0;
    localparam [15:0] C_BLUE  = 16'h001F;
    localparam [15:0] C_NRED  = 16'hF021;   // (240,4,8): label 0, not the flat red

    // ---- clocks and reset ---------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;

    // ---- DUT ----------------------------------------------------------------
    reg  [63:0] s_data  = 64'd0;
    reg         s_valid = 1'b0;
    reg         s_sof   = 1'b0;
    reg         s_eol   = 1'b0;
    reg  [15:0] param   = 16'h1008;
    reg  [ 7:0] knob    = 8'h00;

    wire [63:0] m_data;
    wire        m_valid, m_sof, m_eol;
    wire [31:0] stat;

    stage_seg #(
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
    function [7:0] ref_y;
        input [15:0] p;
        integer r, g, b;
        begin
            r = {p[15:11], 3'b000};
            g = {p[10:5],  2'b00};
            b = {p[4:0],   3'b000};
            ref_y = (r + 2*g + b) >> 2;
        end
    endfunction

    function signed [12:0] ref_co_n;
        input [15:0] p;
        integer r, b, y, rec;
        begin
            r   = {p[15:11], 3'b000};
            b   = {p[4:0],   3'b000};
            y   = ref_y(p);
            rec = (y == 0) ? 0 : (65536 / y);
            ref_co_n = ((r - b) * rec) >>> 12;
        end
    endfunction

    function signed [12:0] ref_cg_n;
        input [15:0] p;
        integer r, g, b, y, rec;
        begin
            r   = {p[15:11], 3'b000};
            g   = {p[10:5],  2'b00};
            b   = {p[4:0],   3'b000};
            y   = ref_y(p);
            rec = (y == 0) ? 0 : (65536 / y);
            ref_cg_n = ((g - ((r + b) >> 1)) * rec) >>> 12;
        end
    endfunction

    function integer box_co;
        input integer b;
        begin
            case (b)
            0: box_co =  63;
            1: box_co =   0;
            2: box_co = -64;
            default: box_co = 21;
            endcase
        end
    endfunction

    function integer box_cg;
        input integer b;
        begin
            case (b)
            0: box_cg = -32;
            1: box_cg =  31;
            2: box_cg = -32;
            default: box_cg = 10;
            endcase
        end
    endfunction

    function [3:0] ref_label;
        input [15:0] p;
        input [1:0]  mode;
        input [7:0]  tol;
        input [7:0]  min_lum;
        integer y, co, cg, l, b;
        begin
            ref_label = 4'hF;
            y = ref_y(p);
            if ((y != 0) && (y >= min_lum)) begin
                co = ref_co_n(p);
                cg = ref_cg_n(p);
                for (l = 0; l < 4; l = l + 1) begin
                    b = l + mode;
                    if (b >= 4) b = b - 4;
                    if ((ref_label == 4'hF) &&
                        (co >= (box_co(b) - tol)) && (co <= (box_co(b) + tol)) &&
                        (cg >= (box_cg(b) - tol)) && (cg <= (box_cg(b) + tol)))
                        ref_label = l;
                end
            end
        end
    endfunction

    function [3:0] ref_eroded;
        input integer f, x, y;
        integer xl, xr;
        reg [3:0] lc, ll, lr;
        begin
            lc = ref_label(scene(f, x, y), 2'd0, 8'd8, 8'd16);
            xl = (x == 0)        ? x : (x - 1);
            xr = (x == (WPL*4-1)) ? x : (x + 1);
            ll = ref_label(scene(f, xl, y), 2'd0, 8'd8, 8'd16);
            lr = ref_label(scene(f, xr, y), 2'd0, 8'd8, 8'd16);
            ref_eroded = ((lc == ll) && (lc == lr)) ? lc : 4'hF;
        end
    endfunction

    function [15:0] paint_col;
        input [3:0] lab;
        begin
            case (lab)
            4'd0:    paint_col = 16'hF800;
            4'd1:    paint_col = 16'h07E0;
            4'd2:    paint_col = 16'h001F;
            default: paint_col = 16'hFFE0;
            endcase
        end
    endfunction

    function [15:0] scene;
        input integer f, x, y;
        begin
            scene = C_GREY;
            if (f == 0) begin
                if (x <= 3 && y <= 3)
                    scene = C_RED;
                else if (x >= 10 && x <= 17 && y >= 2 && y <= 5)
                    scene = C_GREEN;
            end else if (f == 1) begin
                if (x >= 12 && x <= 19 && y >= 1 && y <= 3)
                    scene = C_RED;
                else if (x >= 2 && x <= 9 && y >= 5 && y <= 6)
                    scene = C_GREEN;
                else if (x == 24 && y == 6)
                    scene = C_RED;
                else if (x == 28 && y == 1)
                    scene = C_BLUE;
            end else begin
                if (x >= 5 && x <= 8 && y >= 4 && y <= 7)
                    scene = C_NRED;
            end
        end
    endfunction

    function [7:0] knob_of;
        input integer f;
        begin
            case (f)
            0:       knob_of = 8'h00;       // pass through, label mode 0
            1:       knob_of = 8'h00;       // pass through, label mode 0
            default: knob_of = 8'h04;       // paint, label mode 0
            endcase
        end
    endfunction

    function [31:0] exp_stat;
        input integer f;
        begin
            case (f)
            0:       exp_stat = 32'h0004_0302;
            1:       exp_stat = 32'h0303_0602;
            default: exp_stat = 32'h0104_0201;
            endcase
        end
    endfunction

    function [63:0] expected_word;
        input integer f, line, word;
        integer i, x;
        reg [15:0] px;
        reg [3:0]  lab;
        begin
            expected_word = 64'd0;
            for (i = 0; i < 4; i = i + 1) begin
                x  = 4*word + i;
                px = scene(f, x, line);
                if (f == 2) begin
                    lab = ref_eroded(f, x, line);
                    if (lab != 4'hF) px = paint_col(lab);
                end
                expected_word[16*i +: 16] = px;
            end
        end
    endfunction

    // =========================================================================
    //  Scoreboard
    // =========================================================================
    integer errors    = 0;
    integer o_frame   = -1;
    integer o_words   = 0;

    task fail;
        input [255:0] what;
        begin
            if (errors < 20)
                $display("FAIL t=%0t: %0s (frame %0d word %0d)", $time, what,
                         o_frame, o_words);
            errors = errors + 1;
        end
    endtask

    // word-by-word monitor on the DUT's output stream
    always @(posedge clk) begin
        if (!rst_n) begin
            o_frame = -1;
            o_words = 0;
        end else if (m_valid) begin
            if (m_sof) begin
                if ((o_frame >= 0) && (o_words != WPFR)) begin
                    fail("frame word count");
                    $display("      got %0d words, expected %0d", o_words, WPFR);
                end
                o_frame = o_frame + 1;
                o_words = 0;
            end

            if (m_sof !== (o_words == 0))                   fail("frame tag position");
            if (m_eol !== ((o_words % WPL) == (WPL-1)))     fail("line end position");

            if (m_data !== expected_word(o_frame, o_words / WPL, o_words % WPL)) begin
                fail("output data");
                $display("      got %h expected %h (frame %0d line %0d word %0d)",
                         m_data, expected_word(o_frame, o_words / WPL, o_words % WPL),
                         o_frame, o_words / WPL, o_words % WPL);
            end

            o_words = o_words + 1;
        end
    end

    // expected per-label boxes for the completed frame
    task exp_box;
        input  integer f, l;
        output [9:0] xmn, xmx, ymn, ymx;
        output       pres;
        begin
            xmn  = 10'd1023;
            xmx  = 10'd0;
            ymn  = 10'd1023;
            ymx  = 10'd0;
            pres = 1'b0;
            case (f)
            0: begin
                // red (0,0)-(3,3) loses its right column to the 1x3 erosion;
                // the duplicated edge keeps the left column and there is no
                // vertical erosion, so xmin = 0 and ymin = 0 survive
                if (l == 0) begin xmn = 10'd0;  xmx = 10'd2;  ymn = 10'd0; ymx = 10'd3; pres = 1'b1; end
                if (l == 1) begin xmn = 10'd11; xmx = 10'd16; ymn = 10'd2; ymx = 10'd5; pres = 1'b1; end
            end
            1: begin
                if (l == 0) begin xmn = 10'd13; xmx = 10'd18; ymn = 10'd1; ymx = 10'd3; pres = 1'b1; end
                if (l == 1) begin xmn = 10'd3;  xmx = 10'd8;  ymn = 10'd5; ymx = 10'd6; pres = 1'b1; end
            end
            default: begin
                if (l == 0) begin xmn = 10'd6;  xmx = 10'd7;  ymn = 10'd4; ymx = 10'd7; pres = 1'b1; end
            end
            endcase
        end
    endtask

    task check_report;
        input integer f;
        integer l;
        reg [9:0] xmn, xmx, ymn, ymx;
        reg       pres;
        begin
            for (l = 0; l < 4; l = l + 1) begin
                exp_box(f, l, xmn, xmx, ymn, ymx, pres);

                if (dut.rep_xmin[l] !== xmn) begin
                    $display("FAIL: frame %0d label %0d xmin got %0d expected %0d",
                             f, l, dut.rep_xmin[l], xmn);
                    errors = errors + 1;
                end
                if (dut.rep_xmax[l] !== xmx) begin
                    $display("FAIL: frame %0d label %0d xmax got %0d expected %0d",
                             f, l, dut.rep_xmax[l], xmx);
                    errors = errors + 1;
                end
                if (dut.rep_ymin[l] !== ymn) begin
                    $display("FAIL: frame %0d label %0d ymin got %0d expected %0d",
                             f, l, dut.rep_ymin[l], ymn);
                    errors = errors + 1;
                end
                if (dut.rep_ymax[l] !== ymx) begin
                    $display("FAIL: frame %0d label %0d ymax got %0d expected %0d",
                             f, l, dut.rep_ymax[l], ymx);
                    errors = errors + 1;
                end
                if (dut.rep_present[l] !== pres) begin
                    $display("FAIL: frame %0d label %0d present got %0d expected %0d",
                             f, l, dut.rep_present[l], pres);
                    errors = errors + 1;
                end
            end

            if (stat !== exp_stat(f)) begin
                $display("FAIL: frame %0d stat got %h expected %h", f, stat, exp_stat(f));
                errors = errors + 1;
            end
        end
    endtask

    // =========================================================================
    //  Stimulus
    // =========================================================================
    integer f;

    task drive_frame;
        input integer f;
        input integer hold_f;       // previous frame that must stay reported
        integer ll, ww, ii;
        reg [63:0] word;
        begin
            for (ll = 0; ll < LINES; ll = ll + 1) begin
                for (ww = 0; ww < WPL; ww = ww + 1) begin
                    word = 64'd0;
                    for (ii = 0; ii < 4; ii = ii + 1)
                        word[16*ii +: 16] = scene(f, 4*ww + ii, ll);

                    @(negedge clk);
                    s_valid <= 1'b1;
                    s_sof   <= (ll == 0) && (ww == 0);
                    s_eol   <= (ww == WPL-1);
                    s_data  <= word;
                end

                @(negedge clk);
                s_valid <= 1'b0;
                s_sof   <= 1'b0;
                s_eol   <= 1'b0;
                repeat (2) @(negedge clk);

                // one line of the next frame has been accepted: the frame that
                // finished before it must still be the one on stat
                if ((ll == 0) && (hold_f >= 0)) begin
                    if (stat !== exp_stat(hold_f)) begin
                        $display("FAIL: frame %0d changed stat during line 0: got %h expected %h",
                                 f, stat, exp_stat(hold_f));
                        errors = errors + 1;
                    end
                end
            end

            // let the last word of the frame leave the pipeline and the
            // frame-end merge complete before the caller reads the report
            repeat (8) @(negedge clk);
        end
    endtask

    initial begin
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        for (f = 0; f < FRAMES; f = f + 1) begin
            @(negedge clk);
            knob  = knob_of(f);
            param = 16'h1008;

            drive_frame(f, (f > 0) ? (f - 1) : -1);

            repeat (24) @(negedge clk);
            check_report(f);
        end

        repeat (24) @(negedge clk);

        if (o_frame != FRAMES - 1) begin
            $display("FAIL: saw %0d frames, expected %0d", o_frame + 1, FRAMES);
            errors = errors + 1;
        end
        if (o_words != WPFR) begin
            $display("FAIL: last frame had %0d words, expected %0d", o_words, WPFR);
            errors = errors + 1;
        end
        if (m_valid !== 1'b0) begin
            $display("FAIL: output still valid after the last frame");
            errors = errors + 1;
        end

        $display("");
        $display("frames=%0d words/frame=%0d", o_frame + 1, WPFR);
        if (errors == 0) $display("TEST PASS");
        else             $display("TEST FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL: timeout");
        $display("TEST FAIL (timeout)");
        $finish;
    end

endmodule
