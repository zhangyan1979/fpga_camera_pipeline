// =============================================================================
//  tb_stage_contract.v — checks the stage slot itself, without any algorithm
//
//  Three dummy stages are pure delays with a distinguishing XOR mask:
//
//      stage 1   latency 0   mask 0
//      stage 2   latency 2   mask 0x0000_0000_0000_FFFF
//      stage 3   latency 5   mask 0xFFFF_FFFF_0000_0000
//
//  The testbench drives a synthetic word stream (WPL words per line, LINES lines
//  per frame, FRAMES frames) into stage_mux and checks, word by word:
//
//    * nothing is emitted before the first frame tag (warm-up gating),
//    * every word carries the pattern of the frame and column it is meant to be,
//      XORed with the mask of the stage that is supposed to be driving,
//    * the frame tag is on the first word and the line end on the last word of
//      every line - i.e. the tags survived the stage latency,
//    * a frame contains exactly WORDS_PER_LINE * LINES words, except for the one
//      frame that is cut when the mode changes to a stage with a different
//      latency (documented in stage_mux.v),
//    * selecting stage 1 (latency 0, mask 0) is bit-identical to bypass,
//    * a control write in the middle of a frame does not take effect until the
//      next frame tag,
//    * the selected stage's statistic reaches the control clock domain, and the
//      parameters only change at a frame tag.
// =============================================================================
`timescale 1ns / 1ps

module tb_stage_contract;

    localparam integer WPL    = 4;          // words per line
    localparam integer LINES  = 3;          // lines per frame
    localparam integer WPFR   = WPL * LINES;
    localparam integer FRAMES = 8;

    localparam [63:0] M1 = 64'd0;
    localparam [63:0] M2 = 64'h0000_0000_0000_FFFF;
    localparam [63:0] M3 = 64'hFFFF_FFFF_0000_0000;

    localparam [31:0] ST1 = 32'h1111_0001;
    localparam [31:0] ST2 = 32'h2222_0002;
    localparam [31:0] ST3 = 32'h3333_0003;

    // ---- clocks -------------------------------------------------------------
    reg clk      = 1'b0;                    // camera pixel clock, 100 MHz
    reg clk_ctrl = 1'b0;                    // AXI clock, deliberately unrelated
    always #5  clk      = ~clk;
    always #17 clk_ctrl = ~clk_ctrl;

    reg rst_n      = 1'b0;
    reg rst_ctrl_n = 1'b0;

    // ---- source -------------------------------------------------------------
    reg  [63:0] src_data  = 64'd0;
    reg         src_valid = 1'b0;
    reg         src_sof   = 1'b0;
    wire        src_eol;
    wire [ 8:0] src_wx;
    wire [ 8:0] src_wy;

    img_geom #(.WORDS_PER_LINE(WPL)) u_geom (
        .clk  (clk),
        .rst_n(rst_n),
        .sof  (src_sof),
        .valid(src_valid),
        .eol  (src_eol),
        .wx   (src_wx),
        .wy   (src_wy)
    );

    // ---- control ------------------------------------------------------------
    reg [2:0]  sel   = 3'd0;
    reg [15:0] param = 16'h1234;
    reg [ 7:0] knob  = 8'h5A;

    // ---- stages -------------------------------------------------------------
    wire [63:0] s1_data, s2_data, s3_data;
    wire        s1_valid, s2_valid, s3_valid;
    wire        s1_sof, s2_sof, s3_sof;
    wire        s1_eol, s2_eol, s3_eol;

    stg_delay #(.LAT(0), .XOR_MASK(M1)) u_s1 (
        .clk(clk), .rst_n(rst_n),
        .s_data(src_data), .s_valid(src_valid), .s_sof(src_sof), .s_eol(src_eol),
        .m_data(s1_data), .m_valid(s1_valid), .m_sof(s1_sof), .m_eol(s1_eol)
    );

    stg_delay #(.LAT(2), .XOR_MASK(M2)) u_s2 (
        .clk(clk), .rst_n(rst_n),
        .s_data(src_data), .s_valid(src_valid), .s_sof(src_sof), .s_eol(src_eol),
        .m_data(s2_data), .m_valid(s2_valid), .m_sof(s2_sof), .m_eol(s2_eol)
    );

    stg_delay #(.LAT(5), .XOR_MASK(M3)) u_s3 (
        .clk(clk), .rst_n(rst_n),
        .s_data(src_data), .s_valid(src_valid), .s_sof(src_sof), .s_eol(src_eol),
        .m_data(s3_data), .m_valid(s3_valid), .m_sof(s3_sof), .m_eol(s3_eol)
    );

    // ---- mux under test -----------------------------------------------------
    wire [63:0] m_data;
    wire        m_valid, m_sof, m_eol;
    wire [15:0] stage_param;
    wire [ 7:0] stage_knob;
    wire [31:0] stat;

    stage_mux #(.NUM_STAGES(3)) u_mux (
        .clk       (clk),
        .rst_n     (rst_n),
        .s_data    (src_data),
        .s_valid   (src_valid),
        .s_sof     (src_sof),
        .s_eol     (src_eol),
        .st_data   ({s3_data, s2_data, s1_data}),
        .st_valid  ({s3_valid, s2_valid, s1_valid}),
        .st_sof    ({s3_sof, s2_sof, s1_sof}),
        .st_eol    ({s3_eol, s2_eol, s1_eol}),
        .st_stat   ({ST3, ST2, ST1}),
        .sel       (sel),
        .param     (param),
        .knob      (knob),
        .clk_ctrl  (clk_ctrl),
        .rst_ctrl_n(rst_ctrl_n),
        .m_data    (m_data),
        .m_valid   (m_valid),
        .m_sof     (m_sof),
        .m_eol     (m_eol),
        .s_param   (stage_param),
        .s_knob    (stage_knob),
        .stat      (stat)
    );

    // ---- expected pattern ---------------------------------------------------
    function [63:0] pat;
        input integer f;
        input integer l;
        input integer w;
        integer base;
        begin
            base = f * 4096 + l * 256 + w;
            pat  = {32'hA500_0000 + base, 32'h5A00_0000 + base};
        end
    endfunction

    function [63:0] mask_of;
        input [2:0] s;
        begin
            case (s)
            3'd1:    mask_of = M1;
            3'd2:    mask_of = M2;
            3'd3:    mask_of = M3;
            default: mask_of = 64'd0;       // bypass
            endcase
        end
    endfunction

    function integer lat_of;
        input [2:0] s;
        begin
            case (s)
            3'd2:    lat_of = 2;
            3'd3:    lat_of = 5;
            default: lat_of = 0;
            endcase
        end
    endfunction

    // ---- scoreboard ---------------------------------------------------------
    integer qr = 0, qw = 0;
    reg [63:0] mask_q [0:63];
    integer    lat_q  [0:63];

    integer wcnt = 0;               // words in the frame being emitted
    integer fcnt = 0;               // frame index being emitted
    integer frames_done = 0;
    integer prev_mask_seen = 0;     // 1 once a frame has been scored
    reg [63:0] cur_mask = 64'd0;
    reg [63:0] prev_mask = 64'd0;
    integer errors = 0;
    integer words_out = 0;
    integer words_before_tag = 0;
    integer max_cut = 0;

    task fail;
        input [255:0] what;
        begin
            if (errors < 20) $display("FAIL t=%0t: %0s (frame %0d word %0d)", $time, what, fcnt, wcnt);
            errors = errors + 1;
        end
    endtask

    // parameters must be stable for a whole frame: they may only change on the
    // cycle of a frame tag (and the tb sees the change one cycle later)
    reg        sof_d;
    reg [15:0] par_prev;
    reg [ 7:0] knb_prev;
    reg        par_seen;

    always @(posedge clk) begin
        sof_d <= m_sof;
        if (par_seen && !m_sof && !sof_d) begin
            if (stage_param !== par_prev) fail("parameter changed mid-frame");
            if (stage_knob  !== knb_prev) fail("knob changed mid-frame");
        end
        par_prev <= stage_param;
        knb_prev <= stage_knob;
        if (m_sof) par_seen <= 1'b1;
    end

    // word-level checking
    always @(posedge clk) begin
        if (m_valid) begin
            if (frames_done == 0 && !m_sof) words_before_tag = words_before_tag + 1;

            if (m_sof) begin
                // close the frame that just ended
                if (prev_mask_seen) begin
                    if (wcnt != WPFR) begin
                        if (wcnt >= WPFR - 8 && mask_q[qr] != cur_mask) begin
                            // documented: the frame cut by a latency change
                            if (WPFR - wcnt > max_cut) max_cut = WPFR - wcnt;
                        end else begin
                            fail("frame length");
                            $display("      got %0d words, expected %0d", wcnt, WPFR);
                        end
                    end
                end

                prev_mask      = cur_mask;
                prev_mask_seen = 1;
                cur_mask       = mask_q[qr];
                qr             = qr + 1;
                wcnt           = 0;
                fcnt           = frames_done;
                frames_done    = frames_done + 1;
            end

            if (!m_sof && wcnt == 0) fail("word without a frame tag at frame start");

            if (m_data !== (pat(fcnt, wcnt / WPL, wcnt % WPL) ^ cur_mask)) begin
                fail("word data");
                $display("      got %h expected %h (mask %h)", m_data,
                         pat(fcnt, wcnt / WPL, wcnt % WPL) ^ cur_mask, cur_mask);
            end

            if (m_sof !== (wcnt == 0))                    fail("frame tag position");
            if (m_eol !== ((wcnt % WPL) == (WPL - 1)))     fail("line end position");

            wcnt      = wcnt + 1;
            words_out = words_out + 1;
        end
    end

    // ---- source -------------------------------------------------------------
    integer f, l, w;

    initial begin
        repeat (6) @(negedge clk);
        rst_n      = 1'b1;
        rst_ctrl_n = 1'b1;
        repeat (3) @(negedge clk);

        for (f = 0; f < FRAMES; f = f + 1) begin
            for (l = 0; l < LINES; l = l + 1) begin
                for (w = 0; w < WPL; w = w + 1) begin
                    @(negedge clk);
                    src_valid <= 1'b1;
                    src_sof   <= (l == 0) && (w == 0);
                    src_data  <= pat(f, l, w);

                    // what the mux should be receiving for the frame that this
                    // tag starts: recorded in tag order, read by the scoreboard
                    if ((l == 0) && (w == 0)) begin
                        mask_q[qw] = mask_of(sel);
                        lat_q[qw]  = lat_of(sel);
                        qw         = qw + 1;
                    end

                    // deliberate control changes
                    if ((f == 1) && (l == 1) && (w == 1)) sel <= 3'd2;  // mid-frame
                    if ((f == 3) && (l == 2) && (w == 0)) sel <= 3'd3;
                    if ((f == 5) && (l == 1) && (w == 1)) begin
                        param <= 16'hBEEF;                          // mid-frame
                        knob  <= 8'h3C;
                    end
                    if ((f == 6) && (l == 0) && (w == 0)) sel <= 3'd1;
                end
                @(negedge clk);
                src_valid <= 1'b0;
                src_sof   <= 1'b0;
                repeat (2) @(negedge clk);
            end
            repeat (3) @(negedge clk);
        end

        // let the last frame drain
        repeat (40) @(negedge clk);

        $display("");
        $display("words out=%0d frames=%0d queued=%0d", words_out, frames_done, qw);
        $display("words before first tag=%0d (must be 0)", words_before_tag);
        $display("largest documented frame cut=%0d words", max_cut);
        $display("last stat=%h (expected %h for stage 1)", stat, ST1);
        $display("stage param=%h knob=%h", stage_param, stage_knob);

        if (words_before_tag != 0) begin
            $display("FAIL: emitted words before the first frame tag");
            errors = errors + 1;
        end
        if (stat !== ST1) begin
            $display("FAIL: statistic did not follow the selected stage");
            errors = errors + 1;
        end
        if (stage_param !== 16'hBEEF || stage_knob !== 8'h3C) begin
            $display("FAIL: parameter did not reach the stage at the frame tag");
            errors = errors + 1;
        end
        if (frames_done < FRAMES) begin
            $display("FAIL: only %0d of %0d frames came through", frames_done, FRAMES);
            errors = errors + 1;
        end
        if (max_cut > 5) begin
            $display("FAIL: frame cut larger than the largest stage latency");
            errors = errors + 1;
        end

        if (errors == 0) $display("TEST PASS");
        else             $display("TEST FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #400_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

// =============================================================================
//  stg_delay — dummy stage: a pure word delay with a distinguishing XOR mask
// =============================================================================
module stg_delay #(
    parameter integer LAT      = 1,
    parameter [63:0]  XOR_MASK = 64'd0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,
    input  wire        s_eol,
    output wire [63:0] m_data,
    output wire        m_valid,
    output wire        m_sof,
    output wire        m_eol
);

    generate
    if (LAT == 0) begin : g_thru
        assign m_data  = s_data ^ XOR_MASK;
        assign m_valid = s_valid;
        assign m_sof   = s_sof;
        assign m_eol   = s_eol;
    end else begin : g_delay
        reg [66:0] sr [0:LAT-1];
        integer i;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (i = 0; i < LAT; i = i + 1) sr[i] <= 67'd0;
            end else begin
                sr[0] <= {s_data, s_sof, s_eol, s_valid};
                for (i = 1; i < LAT; i = i + 1) sr[i] <= sr[i-1];
            end
        end

        assign m_data  = sr[LAT-1][66:3] ^ XOR_MASK;
        assign m_sof   = sr[LAT-1][2];
        assign m_eol   = sr[LAT-1][1];
        assign m_valid = sr[LAT-1][0];
    end
    endgenerate

endmodule
