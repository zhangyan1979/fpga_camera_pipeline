// =============================================================================
//  stage_win3x3.v — 3x3 window filters: box mean, Sobel, median, morphology
//
//  A camera-side processing stage (see docs/stage_contract.md).  One 64-bit
//  word carries four RGB565 pixels, pixel 0 in bits [15:0].  The stage caches
//  three complete lines and produces, for every word (x, y), the filtered word
//  (x, y) built from the 3x3 neighbourhood of each of its four pixels.
//
//  Latency is two whole lines plus four words: the output word stream is the
//  input word stream delayed by 2*WORDS_PER_LINE + 4 words (404 for a 200-word
//  line).  A three-line cache is needed because the row being written is two
//  lines ahead of the row being emitted; two cached rows plus the current
//  input would only give a one-line latency.
//
//  Border policy: clamp / duplicate.  Row -1 is row 0, row H is row H-1,
//  column -1 is column 0 and column W is column W-1, so a 3x3 window at a
//  corner is the corner pixel repeated.
//
//  Word granularity is four pixels, so the window for the four pixels of
//  word x spans input columns 4x-1 .. 4x+4.  Each row therefore keeps a
//  32-bit (two pixel) carry of the previous word; the last pixel of that
//  carry (bits [31:16]) is column 4x-1 and the low half lets the six-pixel
//  span be assembled with a single mux.  At x = 0 the carry is replaced by
//  {p0, p0} and at x = WORDS_PER_LINE-1 the right-hand pixel p4 is replaced
//  by p3, which is the column clamp.
//
//  Per-pixel pipeline.  A word arrives every eight cam_pclk cycles.  The
//  arithmetic is too deep for one 42 MHz clock, so the four pixels pass
//  through three pipeline stages, one pixel per cycle, overlapping:
//
//      phase 2  3  4  5  6  7
//      P1:   p0 p1 p2 p3
//      P2:      p0 p1 p2 p3
//      P3:         p0 p1 p2 p3
//
//    P1  window select, channel widening, the three 9-value sums, the nine
//        luminance values, and comparators 1..12 of the 19-comparator median
//        network.  Everything is registered at the phase edge.
//    P2  the box-mean product (sum*57), comparators 13..19 of the median
//        network, min/max of the same (partially sorted) values, and the
//        Sobel gradients and magnitude, all from the P1 registers.
//    P3  the mean shift/bias/clamp, the sharpen 5*I-4*mean, the Sobel gate,
//        the mode mux and the RGB565 packing, then the per-pixel changed and
//        above-threshold flags.
//
//  This keeps every combinational cone inside one phase, and the 32-bit
//  statistic accumulator only ever sees registered per-pixel flags.  The
//  output word, its tags and the statistic are assembled in phase 7 exactly as
//  before, so the external latency is unchanged.
//
//  knob[2:0]  mode, applied to all three channels (widened as needed)
//    0  3x3 box mean: (sum9 * 57) >> 9, then + signed bias, clamp
//    1  Sobel magnitude on luminance, thresholded, replicated as grey RGB565
//    2  3x3 median (19-comparator network, per channel)
//    3  3x3 erode (min)          4  3x3 dilate (max)
//    5  sharpen: 5*I - 4*blur, clamped
//    6,7 reserved, behave as mode 0
//
//  param[15:0]
//    mode 0/6/7: the low byte is a signed bias added to every mean channel
//    mode 1    : edge threshold; |Ix| + |Iy| must exceed it
//    other     : ignored
//
//  stat[31:0], updated at this stage's own frame tag (so it reports the frame
//  that has just finished):
//    [31:16] pixels whose |Ix|+|Iy| exceeded param in the frame (mode 1 only,
//            0 in every other mode), saturating at 0xFFFF
//    [15:0]  pixels whose filtered RGB565 differs from the centre pixel,
//            saturating at 0xFFFF
// =============================================================================
`timescale 1ns / 1ps

module stage_win3x3 #(
    parameter integer WORDS_PER_LINE = 200
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
    output wire        m_eol,
    input  wire [15:0] param,
    input  wire [ 7:0] knob,
    output wire [31:0] stat
);

    localparam integer AW        = $clog2(WORDS_PER_LINE);
    localparam [8:0]   LAST_WORD = WORDS_PER_LINE - 1;
    localparam integer OUT_DEPTH = 4;
    localparam [2:0]   OUT_FULL  = OUT_DEPTH;

    // =========================================================================
    //  Small arithmetic helpers
    // =========================================================================
    // RGB565 -> 8-bit channel: replicate the missing LSBs so 5/6-bit codes
    // scale to the full 0..255 range before averaging.
    function [7:0] w8_r;
        input [15:0] p;
        begin w8_r = {p[15:11], p[15:13]}; end
    endfunction

    function [7:0] w8_g;
        input [15:0] p;
        begin w8_g = {p[10:5], p[10:9]}; end
    endfunction

    function [7:0] w8_b;
        input [15:0] p;
        begin w8_b = {p[4:0], p[4:2]}; end
    endfunction

    function [7:0] clamp8;
        input signed [13:0] v;
        begin
            if (v < 14'sd0)        clamp8 = 8'd0;
            else if (v > 14'sd255) clamp8 = 8'd255;
            else                   clamp8 = v[7:0];
        end
    endfunction

    // compare-exchange, returns {high, low}
    function [15:0] sort2;
        input [7:0] a;
        input [7:0] b;
        begin sort2 = (a > b) ? {a, b} : {b, a}; end
    endfunction

    function [7:0] min8;
        input [7:0] a;
        input [7:0] b;
        begin min8 = (a < b) ? a : b; end
    endfunction

    function [7:0] max8;
        input [7:0] a;
        input [7:0] b;
        begin max8 = (a > b) ? a : b; end
    endfunction

    function [7:0] min9;
        input [7:0] a0, a1, a2, a3, a4, a5, a6, a7, a8;
        reg [7:0] m01, m23, m45, m67, m03, m47;
        begin
            m01 = min8(a0, a1);
            m23 = min8(a2, a3);
            m45 = min8(a4, a5);
            m67 = min8(a6, a7);
            m03 = min8(m01, m23);
            m47 = min8(m45, m67);
            min9 = min8(min8(m03, m47), a8);
        end
    endfunction

    function [7:0] max9;
        input [7:0] a0, a1, a2, a3, a4, a5, a6, a7, a8;
        reg [7:0] m01, m23, m45, m67, m03, m47;
        begin
            m01 = max8(a0, a1);
            m23 = max8(a2, a3);
            m45 = max8(a4, a5);
            m67 = max8(a6, a7);
            m03 = max8(m01, m23);
            m47 = max8(m45, m67);
            max9 = max8(max8(m03, m47), a8);
        end
    endfunction

    function [15:0] sat3;
        input [15:0] a;
        input [2:0]  b;
        reg [15:0] s;
        begin
            s = a + {13'd0, b};
            sat3 = (s < a) ? 16'hFFFF : s;
        end
    endfunction

    // sign-extended bias for the box mean (param[7:0] is two's complement)
    wire signed [13:0] bias = {{6{param[7]}}, param[7:0]};

    // mode select, frame-stable (stage_mux re-latches knob on the frame tag)
    wire [2:0] mode = knob[2:0];

    // =========================================================================
    //  Word geometry: word column and line index of the word being written
    // =========================================================================
    //  The line buffers are addressed by wx, never by a free-running pointer,
    //  so horizontal blanking cannot move a pixel: wx simply holds while valid
    //  is low.
    wire        in_eol;
    wire [ 8:0] in_wx;
    wire [ 8:0] in_wy;

    img_geom #(
        .WORDS_PER_LINE(WORDS_PER_LINE)
    ) u_geom_in (
        .clk  (clk),
        .rst_n(rst_n),
        .sof  (s_sof),
        .valid(s_valid),
        .eol  (in_eol),
        .wx   (in_wx),
        .wy   (in_wy)
    );

    // =========================================================================
    //  Word sequencer
    // =========================================================================
    //  cycle 0  start, read all three line buffers at address wx
    //  cycle 1  row words x registered, read of x+1 launched
    //  cycle 2  spans assembled, P1(p0) evaluated, word x written back
    //  cycle 3  P2(p0) and P1(p1)
    //  cycle 4  P3(p0), P2(p1), P1(p2)
    //  cycle 5  P3(p1), P2(p2), P1(p3)
    //  cycle 6  P3(p2), P2(p3)
    //  cycle 7  P3(p3), output word assembled, statistic updated
    reg        busy;
    reg [2:0]  phase;
    wire       start = s_valid && !busy;

    reg [8:0]  wx_q;
    reg        line_end_q;
    reg        top_clamp_q;
    reg        bot_clamp_q;
    reg [63:0] wd_data;
    reg        wd_sof;
    reg        wd_eol;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            phase <= 3'd0;
        end else if (start) begin
            busy  <= 1'b1;
            phase <= 3'd1;
        end else if (busy) begin
            if (phase == 3'd7) begin
                busy  <= 1'b0;
                phase <= 3'd0;
            end else begin
                phase <= phase + 3'd1;
            end
        end
    end

    // =========================================================================
    //  Three line buffers, each WORDS_PER_LINE x {sof, eol, 64-bit data}
    // =========================================================================
    //  One BRAM18 each at 200 x 66 (Vivado rounds to 256 x 72).  The buffer
    //  holding row n-3 is read at phase 0/1 and written at phase 2, so no read
    //  and write of the same address ever meet in one clock.
    reg [65:0] lb0 [0:WORDS_PER_LINE-1];
    reg [65:0] lb1 [0:WORDS_PER_LINE-1];
    reg [65:0] lb2 [0:WORDS_PER_LINE-1];

    reg [65:0] lb_d0, lb_d1, lb_d2;

    reg [AW-1:0] raddr;
    always @(*) begin
        if (start)
            raddr = in_wx[AW-1:0];
        else if (phase == 3'd1)
            raddr = (wx_q == LAST_WORD) ? {AW{1'b0}}
                                        : (wx_q[AW-1:0] + 1'b1);
        else
            raddr = {AW{1'b0}};
    end

    reg [1:0]    wr;                    // buffer written by the current line
    wire         wr_en   = (phase == 3'd2);
    wire [AW-1:0] wr_addr = wx_q[AW-1:0];
    wire [65:0]  wr_data  = {wd_sof, wd_eol, wd_data};

    always @(posedge clk) begin
        if (wr_en) begin
            case (wr)
            2'd0: lb0[wr_addr] <= wr_data;
            2'd1: lb1[wr_addr] <= wr_data;
            default: lb2[wr_addr] <= wr_data;
            endcase
        end
        lb_d0 <= lb0[raddr];
        lb_d1 <= lb1[raddr];
        lb_d2 <= lb2[raddr];
    end

    // buffer index -> window row.  wr holds (row n-3); (wr+1)%3 holds row n-2,
    // which is the row being emitted, and (wr+2)%3 holds row n-1.
    reg [65:0] win_top, win_mid, win_bot;
    always @(*) begin
        case (wr)
        2'd0: begin win_top = lb_d0; win_mid = lb_d1; win_bot = lb_d2; end
        2'd1: begin win_top = lb_d1; win_mid = lb_d2; win_bot = lb_d0; end
        default: begin win_top = lb_d2; win_mid = lb_d0; win_bot = lb_d1; end
        endcase
    end

    // =========================================================================
    //  Window registers and the two-pixel carries
    // =========================================================================
    reg [65:0] rw_top, rw_mid, rw_bot;   // word x of the three window rows
    reg [31:0] carry_top, carry_mid, carry_bot;
    reg [95:0] sp_top, sp_mid, sp_bot;   // six-pixel spans, p-1 .. p4
    reg        cur_sof, cur_eol;

    wire [15:0] pm1_top = (wx_q == 9'd0) ? rw_top[15:0] : carry_top[31:16];
    wire [15:0] pm1_mid = (wx_q == 9'd0) ? rw_mid[15:0] : carry_mid[31:16];
    wire [15:0] pm1_bot = (wx_q == 9'd0) ? rw_bot[15:0] : carry_bot[31:16];

    wire [15:0] p4_top = (wx_q == LAST_WORD) ? rw_top[63:48] : win_top[15:0];
    wire [15:0] p4_mid = (wx_q == LAST_WORD) ? rw_mid[63:48] : win_mid[15:0];
    wire [15:0] p4_bot = (wx_q == LAST_WORD) ? rw_bot[63:48] : win_bot[15:0];

    wire [95:0] span_top = {p4_top, rw_top[63:0], pm1_top};
    wire [95:0] span_mid = {p4_mid, rw_mid[63:0], pm1_mid};
    wire [95:0] span_bot = {p4_bot, rw_bot[63:0], pm1_bot};

    // clamp/duplicate: row -1 is row 0, row H is row H-1
    wire [95:0] span_top_eff = top_clamp_q ? span_mid : span_top;
    wire [95:0] span_bot_eff = bot_clamp_q ? span_mid : span_bot;

    // =========================================================================
    //  P1: window select, channel widening, 9-sums, luminance, median 1..12
    // =========================================================================
    //  pipeline pixel index 0..3 during phases 2..5
    wire [1:0] p1_idx = phase - 3'd2;

    //  pixel 0 still has to use the spans as they are assembled in phase 2;
    //  pixels 1..3 use the registered copy.
    wire [95:0] p1v_top = (phase == 3'd2) ? span_top_eff : sp_top;
    wire [95:0] p1v_mid = (phase == 3'd2) ? span_mid     : sp_mid;
    wire [95:0] p1v_bot = (phase == 3'd2) ? span_bot_eff : sp_bot;

    reg [15:0] w1_tl, w1_tc, w1_tr;
    reg [15:0] w1_ml, w1_mc, w1_mr;
    reg [15:0] w1_bl, w1_bc, w1_br;

    always @(*) begin
        case (p1_idx)
        2'd0: begin
            w1_tl = p1v_top[15:0];  w1_tc = p1v_top[31:16]; w1_tr = p1v_top[47:32];
            w1_ml = p1v_mid[15:0];  w1_mc = p1v_mid[31:16]; w1_mr = p1v_mid[47:32];
            w1_bl = p1v_bot[15:0];  w1_bc = p1v_bot[31:16]; w1_br = p1v_bot[47:32];
        end
        2'd1: begin
            w1_tl = p1v_top[31:16]; w1_tc = p1v_top[47:32]; w1_tr = p1v_top[63:48];
            w1_ml = p1v_mid[31:16]; w1_mc = p1v_mid[47:32]; w1_mr = p1v_mid[63:48];
            w1_bl = p1v_bot[31:16]; w1_bc = p1v_bot[47:32]; w1_br = p1v_bot[63:48];
        end
        2'd2: begin
            w1_tl = p1v_top[47:32]; w1_tc = p1v_top[63:48]; w1_tr = p1v_top[79:64];
            w1_ml = p1v_mid[47:32]; w1_mc = p1v_mid[63:48]; w1_mr = p1v_mid[79:64];
            w1_bl = p1v_bot[47:32]; w1_bc = p1v_bot[63:48]; w1_br = p1v_bot[79:64];
        end
        default: begin
            w1_tl = p1v_top[63:48]; w1_tc = p1v_top[79:64]; w1_tr = p1v_top[95:80];
            w1_ml = p1v_mid[63:48]; w1_mc = p1v_mid[79:64]; w1_mr = p1v_mid[95:80];
            w1_bl = p1v_bot[63:48]; w1_bc = p1v_bot[79:64]; w1_br = p1v_bot[95:80];
        end
        endcase
    end

    reg [7:0] c1_r0, c1_r1, c1_r2, c1_r3, c1_r4, c1_r5, c1_r6, c1_r7, c1_r8;
    reg [7:0] c1_g0, c1_g1, c1_g2, c1_g3, c1_g4, c1_g5, c1_g6, c1_g7, c1_g8;
    reg [7:0] c1_b0, c1_b1, c1_b2, c1_b3, c1_b4, c1_b5, c1_b6, c1_b7, c1_b8;
    reg [11:0] c1_sr, c1_sg, c1_sb;
    reg [7:0] c1_y0, c1_y1, c1_y2, c1_y3, c1_y4, c1_y5, c1_y6, c1_y7, c1_y8;
    reg [15:0] c1_ctr;

    always @(*) begin
        c1_r0 = w8_r(w1_tl); c1_r1 = w8_r(w1_tc); c1_r2 = w8_r(w1_tr);
        c1_r3 = w8_r(w1_ml); c1_r4 = w8_r(w1_mc); c1_r5 = w8_r(w1_mr);
        c1_r6 = w8_r(w1_bl); c1_r7 = w8_r(w1_bc); c1_r8 = w8_r(w1_br);

        c1_g0 = w8_g(w1_tl); c1_g1 = w8_g(w1_tc); c1_g2 = w8_g(w1_tr);
        c1_g3 = w8_g(w1_ml); c1_g4 = w8_g(w1_mc); c1_g5 = w8_g(w1_mr);
        c1_g6 = w8_g(w1_bl); c1_g7 = w8_g(w1_bc); c1_g8 = w8_g(w1_br);

        c1_b0 = w8_b(w1_tl); c1_b1 = w8_b(w1_tc); c1_b2 = w8_b(w1_tr);
        c1_b3 = w8_b(w1_ml); c1_b4 = w8_b(w1_mc); c1_b5 = w8_b(w1_mr);
        c1_b6 = w8_b(w1_bl); c1_b7 = w8_b(w1_bc); c1_b8 = w8_b(w1_br);

        // sums and luminance use the original (unsorted) channels
        c1_sr = c1_r0 + c1_r1 + c1_r2 + c1_r3 + c1_r4 +
                c1_r5 + c1_r6 + c1_r7 + c1_r8;
        c1_sg = c1_g0 + c1_g1 + c1_g2 + c1_g3 + c1_g4 +
                c1_g5 + c1_g6 + c1_g7 + c1_g8;
        c1_sb = c1_b0 + c1_b1 + c1_b2 + c1_b3 + c1_b4 +
                c1_b5 + c1_b6 + c1_b7 + c1_b8;

        c1_y0 = (c1_r0 * 77 + c1_g0 * 150 + c1_b0 * 29 + 128) >> 8;
        c1_y1 = (c1_r1 * 77 + c1_g1 * 150 + c1_b1 * 29 + 128) >> 8;
        c1_y2 = (c1_r2 * 77 + c1_g2 * 150 + c1_b2 * 29 + 128) >> 8;
        c1_y3 = (c1_r3 * 77 + c1_g3 * 150 + c1_b3 * 29 + 128) >> 8;
        c1_y4 = (c1_r4 * 77 + c1_g4 * 150 + c1_b4 * 29 + 128) >> 8;
        c1_y5 = (c1_r5 * 77 + c1_g5 * 150 + c1_b5 * 29 + 128) >> 8;
        c1_y6 = (c1_r6 * 77 + c1_g6 * 150 + c1_b6 * 29 + 128) >> 8;
        c1_y7 = (c1_r7 * 77 + c1_g7 * 150 + c1_b7 * 29 + 128) >> 8;
        c1_y8 = (c1_r8 * 77 + c1_g8 * 150 + c1_b8 * 29 + 128) >> 8;

        // median network comparators 1..12 of 19 (Smith's network)
        {c1_r1, c1_r2} = sort2(c1_r1, c1_r2);
        {c1_r4, c1_r5} = sort2(c1_r4, c1_r5);
        {c1_r7, c1_r8} = sort2(c1_r7, c1_r8);
        {c1_r0, c1_r1} = sort2(c1_r0, c1_r1);
        {c1_r3, c1_r4} = sort2(c1_r3, c1_r4);
        {c1_r6, c1_r7} = sort2(c1_r6, c1_r7);
        {c1_r1, c1_r2} = sort2(c1_r1, c1_r2);
        {c1_r4, c1_r5} = sort2(c1_r4, c1_r5);
        {c1_r7, c1_r8} = sort2(c1_r7, c1_r8);
        {c1_r0, c1_r3} = sort2(c1_r0, c1_r3);
        {c1_r5, c1_r8} = sort2(c1_r5, c1_r8);
        {c1_r4, c1_r7} = sort2(c1_r4, c1_r7);

        {c1_g1, c1_g2} = sort2(c1_g1, c1_g2);
        {c1_g4, c1_g5} = sort2(c1_g4, c1_g5);
        {c1_g7, c1_g8} = sort2(c1_g7, c1_g8);
        {c1_g0, c1_g1} = sort2(c1_g0, c1_g1);
        {c1_g3, c1_g4} = sort2(c1_g3, c1_g4);
        {c1_g6, c1_g7} = sort2(c1_g6, c1_g7);
        {c1_g1, c1_g2} = sort2(c1_g1, c1_g2);
        {c1_g4, c1_g5} = sort2(c1_g4, c1_g5);
        {c1_g7, c1_g8} = sort2(c1_g7, c1_g8);
        {c1_g0, c1_g3} = sort2(c1_g0, c1_g3);
        {c1_g5, c1_g8} = sort2(c1_g5, c1_g8);
        {c1_g4, c1_g7} = sort2(c1_g4, c1_g7);

        {c1_b1, c1_b2} = sort2(c1_b1, c1_b2);
        {c1_b4, c1_b5} = sort2(c1_b4, c1_b5);
        {c1_b7, c1_b8} = sort2(c1_b7, c1_b8);
        {c1_b0, c1_b1} = sort2(c1_b0, c1_b1);
        {c1_b3, c1_b4} = sort2(c1_b3, c1_b4);
        {c1_b6, c1_b7} = sort2(c1_b6, c1_b7);
        {c1_b1, c1_b2} = sort2(c1_b1, c1_b2);
        {c1_b4, c1_b5} = sort2(c1_b4, c1_b5);
        {c1_b7, c1_b8} = sort2(c1_b7, c1_b8);
        {c1_b0, c1_b3} = sort2(c1_b0, c1_b3);
        {c1_b5, c1_b8} = sort2(c1_b5, c1_b8);
        {c1_b4, c1_b7} = sort2(c1_b4, c1_b7);

        c1_ctr = w1_mc;
    end

    // =========================================================================
    //  P2: box product, median 13..19, min/max, Sobel gradients
    // =========================================================================
    reg [7:0] p1_r0, p1_r1, p1_r2, p1_r3, p1_r4, p1_r5, p1_r6, p1_r7, p1_r8;
    reg [7:0] p1_g0, p1_g1, p1_g2, p1_g3, p1_g4, p1_g5, p1_g6, p1_g7, p1_g8;
    reg [7:0] p1_b0, p1_b1, p1_b2, p1_b3, p1_b4, p1_b5, p1_b6, p1_b7, p1_b8;
    reg [11:0] p1_sr, p1_sg, p1_sb;
    reg [7:0] p1_y0, p1_y1, p1_y2, p1_y3, p1_y4, p1_y5, p1_y6, p1_y7, p1_y8;
    reg [15:0] p1_ctr;

    reg [17:0] p2_pr, p2_pg, p2_pb;
    reg [7:0] p2_med_r, p2_med_g, p2_med_b;
    reg [7:0] p2_min_r, p2_min_g, p2_min_b;
    reg [7:0] p2_max_r, p2_max_g, p2_max_b;
    reg [11:0] p2_mag;
    reg        p2_above;
    reg [15:0] p2_ctr;

    reg [17:0] c2_pr, c2_pg, c2_pb;
    reg [7:0] c2_med_r, c2_med_g, c2_med_b;
    reg [7:0] c2_min_r, c2_min_g, c2_min_b;
    reg [7:0] c2_max_r, c2_max_g, c2_max_b;
    reg [11:0] c2_mag;
    reg        c2_above;
    reg [15:0] c2_ctr;

    reg [7:0] qr0, qr1, qr2, qr3, qr4, qr5, qr6, qr7, qr8;
    reg [7:0] qg0, qg1, qg2, qg3, qg4, qg5, qg6, qg7, qg8;
    reg [7:0] qb0, qb1, qb2, qb3, qb4, qb5, qb6, qb7, qb8;
    reg [10:0] sy1, sy2, sx1, sx2;
    reg signed [11:0] gx, gy;
    reg [11:0] ax, ay;

    always @(*) begin
        // 1/9 is not exact in binary: 57/512 = 0.1113281.  The product is
        // registered here and shifted in P3; it is exact for sums that are
        // multiples of 9 and at most one LSB away otherwise.
        c2_pr = p1_sr * 57;
        c2_pg = p1_sg * 57;
        c2_pb = p1_sb * 57;

        qr0 = p1_r0; qr1 = p1_r1; qr2 = p1_r2; qr3 = p1_r3; qr4 = p1_r4;
        qr5 = p1_r5; qr6 = p1_r6; qr7 = p1_r7; qr8 = p1_r8;
        qg0 = p1_g0; qg1 = p1_g1; qg2 = p1_g2; qg3 = p1_g3; qg4 = p1_g4;
        qg5 = p1_g5; qg6 = p1_g6; qg7 = p1_g7; qg8 = p1_g8;
        qb0 = p1_b0; qb1 = p1_b1; qb2 = p1_b2; qb3 = p1_b3; qb4 = p1_b4;
        qb5 = p1_b5; qb6 = p1_b6; qb7 = p1_b7; qb8 = p1_b8;

        // comparators 13..19: the remaining levels of the same network
        {qr3, qr6} = sort2(qr3, qr6);
        {qr1, qr4} = sort2(qr1, qr4);
        {qr2, qr5} = sort2(qr2, qr5);
        {qr4, qr7} = sort2(qr4, qr7);
        {qr4, qr2} = sort2(qr4, qr2);
        {qr6, qr4} = sort2(qr6, qr4);
        {qr4, qr2} = sort2(qr4, qr2);

        {qg3, qg6} = sort2(qg3, qg6);
        {qg1, qg4} = sort2(qg1, qg4);
        {qg2, qg5} = sort2(qg2, qg5);
        {qg4, qg7} = sort2(qg4, qg7);
        {qg4, qg2} = sort2(qg4, qg2);
        {qg6, qg4} = sort2(qg6, qg4);
        {qg4, qg2} = sort2(qg4, qg2);

        {qb3, qb6} = sort2(qb3, qb6);
        {qb1, qb4} = sort2(qb1, qb4);
        {qb2, qb5} = sort2(qb2, qb5);
        {qb4, qb7} = sort2(qb4, qb7);
        {qb4, qb2} = sort2(qb4, qb2);
        {qb6, qb4} = sort2(qb6, qb4);
        {qb4, qb2} = sort2(qb4, qb2);

        c2_med_r = qr4;
        c2_med_g = qg4;
        c2_med_b = qb4;

        // min/max are invariant under the compare-exchanges already applied,
        // so they can be taken from the partially sorted values.
        c2_min_r = min9(p1_r0, p1_r1, p1_r2, p1_r3, p1_r4,
                        p1_r5, p1_r6, p1_r7, p1_r8);
        c2_min_g = min9(p1_g0, p1_g1, p1_g2, p1_g3, p1_g4,
                        p1_g5, p1_g6, p1_g7, p1_g8);
        c2_min_b = min9(p1_b0, p1_b1, p1_b2, p1_b3, p1_b4,
                        p1_b5, p1_b6, p1_b7, p1_b8);
        c2_max_r = max9(p1_r0, p1_r1, p1_r2, p1_r3, p1_r4,
                        p1_r5, p1_r6, p1_r7, p1_r8);
        c2_max_g = max9(p1_g0, p1_g1, p1_g2, p1_g3, p1_g4,
                        p1_g5, p1_g6, p1_g7, p1_g8);
        c2_max_b = max9(p1_b0, p1_b1, p1_b2, p1_b3, p1_b4,
                        p1_b5, p1_b6, p1_b7, p1_b8);

        // Sobel gradients and 1-norm magnitude
        sx1 = p1_y2 + (p1_y5 << 1) + p1_y8;
        sx2 = p1_y0 + (p1_y3 << 1) + p1_y6;
        sy1 = p1_y6 + (p1_y7 << 1) + p1_y8;
        sy2 = p1_y0 + (p1_y1 << 1) + p1_y2;
        gx  = $signed({1'b0, sx1}) - $signed({1'b0, sx2});
        gy  = $signed({1'b0, sy1}) - $signed({1'b0, sy2});
        ax  = gx[11] ? (~gx + 12'd1) : gx;
        ay  = gy[11] ? (~gy + 12'd1) : gy;
        c2_mag   = ax + ay;                 // 0..2040
        c2_above = ({4'd0, c2_mag} > param);

        c2_ctr = p1_ctr;
    end

    // =========================================================================
    //  P3: mean, sharpen, Sobel gate, mode mux, RGB565 packing
    // =========================================================================
    reg [8:0]  mean_r, mean_g, mean_b;
    reg [7:0]  c3_mr, c3_mg, c3_mb;        // box mean + bias
    reg [7:0]  c3_sr, c3_sg, c3_sb;        // sharpen
    reg [7:0]  c3_qr, c3_qg, c3_qb;        // selected by knob
    reg [7:0]  c3_grey;
    reg [7:0]  c3_ctr_r, c3_ctr_g, c3_ctr_b;
    reg [15:0] c3_pix;
    reg        c3_chg;
    reg        c3_abv;

    always @(*) begin
        mean_r = p2_pr[17:9];               // (sum * 57) >> 9, 0..255
        mean_g = p2_pg[17:9];
        mean_b = p2_pb[17:9];

        c3_mr = clamp8($signed({5'b0, mean_r}) + bias);
        c3_mg = clamp8($signed({5'b0, mean_g}) + bias);
        c3_mb = clamp8($signed({5'b0, mean_b}) + bias);

        c3_ctr_r = w8_r(p2_ctr);
        c3_ctr_g = w8_g(p2_ctr);
        c3_ctr_b = w8_b(p2_ctr);

        c3_sr = clamp8(($signed({6'b0, c3_ctr_r}) * 14'sd5) -
                       ($signed({6'b0, mean_r})   * 14'sd4));
        c3_sg = clamp8(($signed({6'b0, c3_ctr_g}) * 14'sd5) -
                       ($signed({6'b0, mean_g})   * 14'sd4));
        c3_sb = clamp8(($signed({6'b0, c3_ctr_b}) * 14'sd5) -
                       ($signed({6'b0, mean_b})   * 14'sd4));

        c3_grey = (p2_mag > 12'd255) ? 8'd255 : p2_mag[7:0];

        case (mode)
        3'd0, 3'd6, 3'd7: begin
            c3_qr = c3_mr;
            c3_qg = c3_mg;
            c3_qb = c3_mb;
        end
        3'd1: begin
            if (p2_above) begin
                c3_qr = c3_grey;
                c3_qg = c3_grey;
                c3_qb = c3_grey;
            end else begin
                c3_qr = 8'd0;
                c3_qg = 8'd0;
                c3_qb = 8'd0;
            end
        end
        3'd2: begin
            c3_qr = p2_med_r;
            c3_qg = p2_med_g;
            c3_qb = p2_med_b;
        end
        3'd3: begin
            c3_qr = p2_min_r;
            c3_qg = p2_min_g;
            c3_qb = p2_min_b;
        end
        3'd4: begin
            c3_qr = p2_max_r;
            c3_qg = p2_max_g;
            c3_qb = p2_max_b;
        end
        default: begin
            c3_qr = c3_sr;
            c3_qg = c3_sg;
            c3_qb = c3_sb;
        end
        endcase

        c3_pix = {c3_qr[7:3], c3_qg[7:2], c3_qb[7:3]};
        c3_chg = (c3_pix != p2_ctr);
        c3_abv = (mode == 3'd1) && p2_above;
    end

    // =========================================================================
    //  Output: four-word aligner so the total latency is two lines + 4 words
    // =========================================================================
    reg [66:0] osr [0:OUT_DEPTH-1];      // {sof, eol, data}
    reg [2:0]  osr_fill;
    reg [15:0] pix0_q, pix1_q, pix2_q;
    reg        chg0_q, chg1_q, chg2_q;
    reg        abv0_q, abv1_q, abv2_q;
    integer    k;

    wire [63:0] new_word = {c3_pix, pix2_q, pix1_q, pix0_q};
    wire [66:0] osr_in   = {cur_sof, cur_eol, new_word};
    wire        word_done = busy && (phase == 3'd7);
    wire        osr_emit  = word_done && (osr_fill == OUT_FULL);

    reg [15:0] stat_edge, stat_chg;
    reg [31:0] stat_q;
    reg        stat_seen;

    // one word's worth of per-pixel flags, 0..4 (explicit width: a bare sum of
    // 1-bit flags would be truncated by the surrounding concatenation)
    wire [2:0] word_chg = chg0_q + chg1_q + chg2_q + c3_chg;
    wire [2:0] word_abv = abv0_q + abv1_q + abv2_q + c3_abv;

    assign m_data  = osr[OUT_DEPTH-1][63:0];
    assign m_valid = osr_emit;
    assign m_sof   = osr_emit && osr[OUT_DEPTH-1][65];
    assign m_eol   = osr_emit && osr[OUT_DEPTH-1][64];
    assign stat    = stat_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wx_q       <= 9'd0;
            line_end_q <= 1'b0;
            top_clamp_q <= 1'b0;
            bot_clamp_q <= 1'b0;
            wd_data    <= 64'd0;
            wd_sof     <= 1'b0;
            wd_eol     <= 1'b0;
            wr         <= 2'd0;
            rw_top     <= 66'd0;
            rw_mid     <= 66'd0;
            rw_bot     <= 66'd0;
            carry_top  <= 32'd0;
            carry_mid  <= 32'd0;
            carry_bot  <= 32'd0;
            sp_top     <= 96'd0;
            sp_mid     <= 96'd0;
            sp_bot     <= 96'd0;
            cur_sof    <= 1'b0;
            cur_eol    <= 1'b0;
            p1_r0 <= 8'd0; p1_r1 <= 8'd0; p1_r2 <= 8'd0; p1_r3 <= 8'd0;
            p1_r4 <= 8'd0; p1_r5 <= 8'd0; p1_r6 <= 8'd0; p1_r7 <= 8'd0;
            p1_r8 <= 8'd0;
            p1_g0 <= 8'd0; p1_g1 <= 8'd0; p1_g2 <= 8'd0; p1_g3 <= 8'd0;
            p1_g4 <= 8'd0; p1_g5 <= 8'd0; p1_g6 <= 8'd0; p1_g7 <= 8'd0;
            p1_g8 <= 8'd0;
            p1_b0 <= 8'd0; p1_b1 <= 8'd0; p1_b2 <= 8'd0; p1_b3 <= 8'd0;
            p1_b4 <= 8'd0; p1_b5 <= 8'd0; p1_b6 <= 8'd0; p1_b7 <= 8'd0;
            p1_b8 <= 8'd0;
            p1_sr <= 12'd0; p1_sg <= 12'd0; p1_sb <= 12'd0;
            p1_y0 <= 8'd0; p1_y1 <= 8'd0; p1_y2 <= 8'd0; p1_y3 <= 8'd0;
            p1_y4 <= 8'd0; p1_y5 <= 8'd0; p1_y6 <= 8'd0; p1_y7 <= 8'd0;
            p1_y8 <= 8'd0;
            p1_ctr <= 16'd0;
            p2_pr <= 18'd0; p2_pg <= 18'd0; p2_pb <= 18'd0;
            p2_med_r <= 8'd0; p2_med_g <= 8'd0; p2_med_b <= 8'd0;
            p2_min_r <= 8'd0; p2_min_g <= 8'd0; p2_min_b <= 8'd0;
            p2_max_r <= 8'd0; p2_max_g <= 8'd0; p2_max_b <= 8'd0;
            p2_mag <= 12'd0;
            p2_above <= 1'b0;
            p2_ctr <= 16'd0;
            pix0_q <= 16'd0; pix1_q <= 16'd0; pix2_q <= 16'd0;
            chg0_q <= 1'b0; chg1_q <= 1'b0; chg2_q <= 1'b0;
            abv0_q <= 1'b0; abv1_q <= 1'b0; abv2_q <= 1'b0;
            osr_fill   <= 3'd0;
            stat_edge  <= 16'd0;
            stat_chg   <= 16'd0;
            stat_q     <= 32'd0;
            stat_seen  <= 1'b0;
            for (k = 0; k < OUT_DEPTH; k = k + 1)
                osr[k] <= 67'd0;
        end else begin
            if (start) begin
                wx_q        <= in_wx;
                line_end_q  <= in_eol;
                top_clamp_q <= (in_wy == 9'd2);
                bot_clamp_q <= (in_wy == 9'd1);
                wd_data     <= s_data;
                wd_sof      <= s_sof;
                wd_eol      <= s_eol;
            end

            case (phase)
            3'd1: begin
                rw_top  <= win_top;
                rw_mid  <= win_mid;
                rw_bot  <= win_bot;
                cur_sof <= win_mid[65];
                cur_eol <= win_mid[64];
            end
            3'd2: begin
                sp_top    <= span_top_eff;
                sp_mid    <= span_mid;
                sp_bot    <= span_bot_eff;
                carry_top <= rw_top[63:32];
                carry_mid <= rw_mid[63:32];
                carry_bot <= rw_bot[63:32];
            end
            default: ;
            endcase

            // ---- per-pixel pipeline -------------------------------------
            if ((phase >= 3'd2) && (phase <= 3'd5)) begin
                p1_r0 <= c1_r0; p1_r1 <= c1_r1; p1_r2 <= c1_r2;
                p1_r3 <= c1_r3; p1_r4 <= c1_r4; p1_r5 <= c1_r5;
                p1_r6 <= c1_r6; p1_r7 <= c1_r7; p1_r8 <= c1_r8;
                p1_g0 <= c1_g0; p1_g1 <= c1_g1; p1_g2 <= c1_g2;
                p1_g3 <= c1_g3; p1_g4 <= c1_g4; p1_g5 <= c1_g5;
                p1_g6 <= c1_g6; p1_g7 <= c1_g7; p1_g8 <= c1_g8;
                p1_b0 <= c1_b0; p1_b1 <= c1_b1; p1_b2 <= c1_b2;
                p1_b3 <= c1_b3; p1_b4 <= c1_b4; p1_b5 <= c1_b5;
                p1_b6 <= c1_b6; p1_b7 <= c1_b7; p1_b8 <= c1_b8;
                p1_sr <= c1_sr; p1_sg <= c1_sg; p1_sb <= c1_sb;
                p1_y0 <= c1_y0; p1_y1 <= c1_y1; p1_y2 <= c1_y2;
                p1_y3 <= c1_y3; p1_y4 <= c1_y4; p1_y5 <= c1_y5;
                p1_y6 <= c1_y6; p1_y7 <= c1_y7; p1_y8 <= c1_y8;
                p1_ctr <= c1_ctr;
            end
            if ((phase >= 3'd3) && (phase <= 3'd6)) begin
                p2_pr <= c2_pr; p2_pg <= c2_pg; p2_pb <= c2_pb;
                p2_med_r <= c2_med_r; p2_med_g <= c2_med_g;
                p2_med_b <= c2_med_b;
                p2_min_r <= c2_min_r; p2_min_g <= c2_min_g;
                p2_min_b <= c2_min_b;
                p2_max_r <= c2_max_r; p2_max_g <= c2_max_g;
                p2_max_b <= c2_max_b;
                p2_mag   <= c2_mag;
                p2_above <= c2_above;
                p2_ctr   <= c2_ctr;
            end
            if (phase == 3'd4) begin
                pix0_q <= c3_pix; chg0_q <= c3_chg; abv0_q <= c3_abv;
            end
            if (phase == 3'd5) begin
                pix1_q <= c3_pix; chg1_q <= c3_chg; abv1_q <= c3_abv;
            end
            if (phase == 3'd6) begin
                pix2_q <= c3_pix; chg2_q <= c3_chg; abv2_q <= c3_abv;
            end

            // ---- output word, statistic and line ring at phase 7 ---------
            if (word_done) begin
                osr[0] <= osr_in;
                for (k = 1; k < OUT_DEPTH; k = k + 1)
                    osr[k] <= osr[k-1];
                if (osr_fill != OUT_FULL)
                    osr_fill <= osr_fill + 3'd1;

                if (cur_sof) begin
                    if (stat_seen)
                        stat_q <= {stat_edge, stat_chg};
                    else
                        stat_seen <= 1'b1;
                    stat_edge <= {13'd0, word_abv};
                    stat_chg  <= {13'd0, word_chg};
                end else begin
                    stat_edge <= sat3(stat_edge, word_abv);
                    stat_chg  <= sat3(stat_chg, word_chg);
                end

                // the line ring advances once per line, after the last write
                if (line_end_q)
                    wr <= (wr == 2'd2) ? 2'd0 : (wr + 2'd1);
            end
        end
    end

endmodule
