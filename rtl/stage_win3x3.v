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
//  The four output pixels are computed one per clock from a shared datapath:
//  the word period is eight cam_pclk cycles, and this stage uses seven of them
//  (read, look-ahead, spans, four pixels).  The sorting network of mode 2 and
//  every arithmetic operator are therefore instantiated once per pixel, not
//  four times per word.
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

    // 1/9 is not exact in binary; 57/512 = 0.1113281 is the usual fixed-point
    //  approximation.  For a sum that is a multiple of 9 the result is exact
    //  for every code (sum = 9k, k <= 255: 513k >> 9 = k); for other sums it is
    //  the neighbouring integer, at most one LSB away from the real mean.
    function [7:0] mean9;
        input [11:0] s;
        begin mean9 = (s * 57) >> 9; end
    endfunction

    // compare-exchange, returns {high, low}
    function [15:0] sort2;
        input [7:0] a;
        input [7:0] b;
        begin sort2 = (a > b) ? {a, b} : {b, a}; end
    endfunction

    // Median of nine 8-bit values, 19 comparators (Smith's network, as used in
    // XC4000E median filters).  Verified against a full sort in the testbench.
    function [7:0] med9;
        input [7:0] a0, a1, a2, a3, a4, a5, a6, a7, a8;
        reg [7:0] p0, p1, p2, p3, p4, p5, p6, p7, p8;
        begin
            p0 = a0; p1 = a1; p2 = a2; p3 = a3; p4 = a4;
            p5 = a5; p6 = a6; p7 = a7; p8 = a8;

            {p1, p2} = sort2(p1, p2);
            {p4, p5} = sort2(p4, p5);
            {p7, p8} = sort2(p7, p8);
            {p0, p1} = sort2(p0, p1);
            {p3, p4} = sort2(p3, p4);
            {p6, p7} = sort2(p6, p7);
            {p1, p2} = sort2(p1, p2);
            {p4, p5} = sort2(p4, p5);
            {p7, p8} = sort2(p7, p8);
            {p0, p3} = sort2(p0, p3);
            {p5, p8} = sort2(p5, p8);
            {p4, p7} = sort2(p4, p7);
            {p3, p6} = sort2(p3, p6);
            {p1, p4} = sort2(p1, p4);
            {p2, p5} = sort2(p2, p5);
            {p4, p7} = sort2(p4, p7);
            {p4, p2} = sort2(p4, p2);
            {p6, p4} = sort2(p6, p4);
            {p4, p2} = sort2(p4, p2);

            med9 = p4;
        end
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

    // =========================================================================
    //  Per-pixel datapath, shared by the four pixels of the word
    // =========================================================================
    // Returns {edge-above-threshold, filtered RGB565}.  The nine window pixels
    // arrive in raster order: tl tc tr / ml mc mr / bl bc br.
    function [16:0] filt_pix;
        input [2:0]  md;
        input [15:0] tl, tc, tr;
        input [15:0] ml, mc, mr;
        input [15:0] bl, bc, br;
        input [15:0] prm;

        reg [7:0] r0, r1, r2, r3, r4, r5, r6, r7, r8;
        reg [7:0] g0, g1, g2, g3, g4, g5, g6, g7, g8;
        reg [7:0] b0, b1, b2, b3, b4, b5, b6, b7, b8;

        reg [11:0] sr, sg, sb;
        reg [7:0]  avr, avg, avb;

        reg [7:0] y0, y1, y2, y3, y4, y5, y6, y7, y8;
        reg [10:0] sx1, sx2, sy1, sy2;
        reg signed [11:0] gx, gy;
        reg [11:0] ax, ay, mag;
        reg [7:0]  gry8;

        reg [7:0]  or8, og8, ob8;
        reg        above;
        reg signed [13:0] bias;
        reg signed [13:0] v14;

        begin
            // widened channels of the nine neighbours
            r0 = w8_r(tl); r1 = w8_r(tc); r2 = w8_r(tr);
            r3 = w8_r(ml); r4 = w8_r(mc); r5 = w8_r(mr);
            r6 = w8_r(bl); r7 = w8_r(bc); r8 = w8_r(br);

            g0 = w8_g(tl); g1 = w8_g(tc); g2 = w8_g(tr);
            g3 = w8_g(ml); g4 = w8_g(mc); g5 = w8_g(mr);
            g6 = w8_g(bl); g7 = w8_g(bc); g8 = w8_g(br);

            b0 = w8_b(tl); b1 = w8_b(tc); b2 = w8_b(tr);
            b3 = w8_b(ml); b4 = w8_b(mc); b5 = w8_b(mr);
            b6 = w8_b(bl); b7 = w8_b(bc); b8 = w8_b(br);

            // 3x3 sums and the fixed-point box mean
            sr = r0 + r1 + r2 + r3 + r4 + r5 + r6 + r7 + r8;
            sg = g0 + g1 + g2 + g3 + g4 + g5 + g6 + g7 + g8;
            sb = b0 + b1 + b2 + b3 + b4 + b5 + b6 + b7 + b8;
            avr = mean9(sr);
            avg = mean9(sg);
            avb = mean9(sb);

            // Rec.601 luminance, 8-bit, rounded; only mode 1 uses these.
            y0 = (r0 * 77 + g0 * 150 + b0 * 29 + 128) >> 8;
            y1 = (r1 * 77 + g1 * 150 + b1 * 29 + 128) >> 8;
            y2 = (r2 * 77 + g2 * 150 + b2 * 29 + 128) >> 8;
            y3 = (r3 * 77 + g3 * 150 + b3 * 29 + 128) >> 8;
            y4 = (r4 * 77 + g4 * 150 + b4 * 29 + 128) >> 8;
            y5 = (r5 * 77 + g5 * 150 + b5 * 29 + 128) >> 8;
            y6 = (r6 * 77 + g6 * 150 + b6 * 29 + 128) >> 8;
            y7 = (r7 * 77 + g7 * 150 + b7 * 29 + 128) >> 8;
            y8 = (r8 * 77 + g8 * 150 + b8 * 29 + 128) >> 8;

            sx1 = y2 + (y5 << 1) + y8;
            sx2 = y0 + (y3 << 1) + y6;
            sy1 = y6 + (y7 << 1) + y8;
            sy2 = y0 + (y1 << 1) + y2;
            gx  = $signed({1'b0, sx1}) - $signed({1'b0, sx2});
            gy  = $signed({1'b0, sy1}) - $signed({1'b0, sy2});
            ax  = gx[11] ? (~gx + 12'd1) : gx;
            ay  = gy[11] ? (~gy + 12'd1) : gy;
            mag = ax + ay;                     // |Ix| + |Iy|, 0..2040

            above = 1'b0;
            bias  = {{6{prm[7]}}, prm[7:0]};

            case (md)
            3'd0, 3'd6, 3'd7: begin            // box mean + signed bias
                or8 = clamp8($signed({6'b0, avr}) + bias);
                og8 = clamp8($signed({6'b0, avg}) + bias);
                ob8 = clamp8($signed({6'b0, avb}) + bias);
            end

            3'd1: begin                        // Sobel magnitude, thresholded
                above = ({4'd0, mag} > prm);
                gry8  = (mag > 12'd255) ? 8'd255 : mag[7:0];
                if (above) begin
                    or8 = gry8;
                    og8 = gry8;
                    ob8 = gry8;
                end else begin
                    or8 = 8'd0;
                    og8 = 8'd0;
                    ob8 = 8'd0;
                end
            end

            3'd2: begin                        // median
                or8 = med9(r0, r1, r2, r3, r4, r5, r6, r7, r8);
                og8 = med9(g0, g1, g2, g3, g4, g5, g6, g7, g8);
                ob8 = med9(b0, b1, b2, b3, b4, b5, b6, b7, b8);
            end

            3'd3: begin                        // erode
                or8 = min9(r0, r1, r2, r3, r4, r5, r6, r7, r8);
                og8 = min9(g0, g1, g2, g3, g4, g5, g6, g7, g8);
                ob8 = min9(b0, b1, b2, b3, b4, b5, b6, b7, b8);
            end

            3'd4: begin                        // dilate
                or8 = max9(r0, r1, r2, r3, r4, r5, r6, r7, r8);
                og8 = max9(g0, g1, g2, g3, g4, g5, g6, g7, g8);
                ob8 = max9(b0, b1, b2, b3, b4, b5, b6, b7, b8);
            end

            default: begin                     // 5: 5*I - 4*blur, clamped
                v14 = ($signed({6'b0, r4}) * 14'sd5) -
                      ($signed({6'b0, avr}) * 14'sd4);
                or8 = clamp8(v14);
                v14 = ($signed({6'b0, g4}) * 14'sd5) -
                      ($signed({6'b0, avg}) * 14'sd4);
                og8 = clamp8(v14);
                v14 = ($signed({6'b0, b4}) * 14'sd5) -
                      ($signed({6'b0, avb}) * 14'sd4);
                ob8 = clamp8(v14);
            end
            endcase

            filt_pix = {above, or8[7:3], og8[7:2], ob8[7:3]};
        end
    endfunction

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
    //  Word sequencer: seven phases after a valid word
    // =========================================================================
    //  cycle 0  start, read all three line buffers at address wx
    //  cycle 1  row words x registered, launch read of x+1
    //  cycle 2  look-ahead pixel 0 of word x+1 registered
    //  cycle 3  spans assembled, carries reloaded, word x written back
    //  cycles 4..7  pixels 0..3 computed, one per cycle
    //  cycle 7  output word pushed into the four-word latency FIFO
    // The camera offers a word every eight clocks; seven are used, and the
    // eighth leaves room for the start of the next word.
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
    //  holding row n-3 is read at phase 0/2 and written at phase 3, so no read
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
    wire         wr_en   = (phase == 3'd3);
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
    reg [15:0] nx_top, nx_mid, nx_bot;   // pixel 0 of word x+1 (right edge)
    reg [31:0] carry_top, carry_mid, carry_bot;
    reg [95:0] sp_top, sp_mid, sp_bot;   // six-pixel spans, p-1 .. p4
    reg        cur_sof, cur_eol;

    wire [15:0] pm1_top = (wx_q == 9'd0) ? rw_top[15:0] : carry_top[31:16];
    wire [15:0] pm1_mid = (wx_q == 9'd0) ? rw_mid[15:0] : carry_mid[31:16];
    wire [15:0] pm1_bot = (wx_q == 9'd0) ? rw_bot[15:0] : carry_bot[31:16];

    wire [15:0] p4_top = (wx_q == LAST_WORD) ? rw_top[63:48] : nx_top;
    wire [15:0] p4_mid = (wx_q == LAST_WORD) ? rw_mid[63:48] : nx_mid;
    wire [15:0] p4_bot = (wx_q == LAST_WORD) ? rw_bot[63:48] : nx_bot;

    wire [95:0] span_top = {p4_top, rw_top[63:0], pm1_top};
    wire [95:0] span_mid = {p4_mid, rw_mid[63:0], pm1_mid};
    wire [95:0] span_bot = {p4_bot, rw_bot[63:0], pm1_bot};

    // clamp/duplicate: row -1 is row 0, row H is row H-1
    wire [95:0] span_top_eff = top_clamp_q ? span_mid : span_top;
    wire [95:0] span_bot_eff = bot_clamp_q ? span_mid : span_bot;

    // spans are {p4, p3, p2, p1, p0, p-1}; pixel i uses offsets i, i+1, i+2
    reg [15:0] w_tl, w_tc, w_tr;
    reg [15:0] w_ml, w_mc, w_mr;
    reg [15:0] w_bl, w_bc, w_br;
    always @(*) begin
        case (phase[1:0])
        2'd0: begin
            w_tl = sp_top[15:0];  w_tc = sp_top[31:16]; w_tr = sp_top[47:32];
            w_ml = sp_mid[15:0];  w_mc = sp_mid[31:16]; w_mr = sp_mid[47:32];
            w_bl = sp_bot[15:0];  w_bc = sp_bot[31:16]; w_br = sp_bot[47:32];
        end
        2'd1: begin
            w_tl = sp_top[31:16]; w_tc = sp_top[47:32]; w_tr = sp_top[63:48];
            w_ml = sp_mid[31:16]; w_mc = sp_mid[47:32]; w_mr = sp_mid[63:48];
            w_bl = sp_bot[31:16]; w_bc = sp_bot[47:32]; w_br = sp_bot[63:48];
        end
        2'd2: begin
            w_tl = sp_top[47:32]; w_tc = sp_top[63:48]; w_tr = sp_top[79:64];
            w_ml = sp_mid[47:32]; w_mc = sp_mid[63:48]; w_mr = sp_mid[79:64];
            w_bl = sp_bot[47:32]; w_bc = sp_bot[63:48]; w_br = sp_bot[79:64];
        end
        default: begin
            w_tl = sp_top[63:48]; w_tc = sp_top[79:64]; w_tr = sp_top[95:80];
            w_ml = sp_mid[63:48]; w_mc = sp_mid[79:64]; w_mr = sp_mid[95:80];
            w_bl = sp_bot[63:48]; w_bc = sp_bot[79:64]; w_br = sp_bot[95:80];
        end
        endcase
    end

    wire [2:0]  mode = knob[2:0];
    wire [16:0] fpix = filt_pix(mode, w_tl, w_tc, w_tr,
                                w_ml, w_mc, w_mr,
                                w_bl, w_bc, w_br, param);
    wire        pix_changed = (fpix[15:0] != w_mc);

    // =========================================================================
    //  Output: four-word aligner so the total latency is two lines + 4 words
    // =========================================================================
    reg [66:0] osr [0:OUT_DEPTH-1];      // {sof, eol, data}
    reg [2:0]  osr_fill;
    reg [15:0] pix0_q, pix1_q, pix2_q;
    reg [2:0]  wchg, wedge;
    integer    k;

    wire [63:0] new_word = {fpix[15:0], pix2_q, pix1_q, pix0_q};
    wire [66:0] osr_in   = {cur_sof, cur_eol, new_word};
    wire        word_done = busy && (phase == 3'd7);
    wire        osr_emit  = word_done && (osr_fill == OUT_FULL);

    reg [15:0] stat_edge, stat_chg;
    reg [31:0] stat_q;
    reg        stat_seen;

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
            nx_top     <= 16'd0;
            nx_mid     <= 16'd0;
            nx_bot     <= 16'd0;
            carry_top  <= 32'd0;
            carry_mid  <= 32'd0;
            carry_bot  <= 32'd0;
            sp_top     <= 96'd0;
            sp_mid     <= 96'd0;
            sp_bot     <= 96'd0;
            cur_sof    <= 1'b0;
            cur_eol    <= 1'b0;
            pix0_q     <= 16'd0;
            pix1_q     <= 16'd0;
            pix2_q     <= 16'd0;
            wchg       <= 3'd0;
            wedge      <= 3'd0;
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
                nx_top <= win_top[15:0];
                nx_mid <= win_mid[15:0];
                nx_bot <= win_bot[15:0];
            end
            3'd3: begin
                sp_top    <= span_top_eff;
                sp_mid    <= span_mid;
                sp_bot    <= span_bot_eff;
                carry_top <= rw_top[63:32];
                carry_mid <= rw_mid[63:32];
                carry_bot <= rw_bot[63:32];
            end
            3'd4: begin
                pix0_q <= fpix[15:0];
                wchg   <= pix_changed ? 3'd1 : 3'd0;
                wedge  <= {2'b00, fpix[16]};
            end
            3'd5: begin
                pix1_q <= fpix[15:0];
                wchg   <= wchg + (pix_changed ? 3'd1 : 3'd0);
                wedge  <= wedge + {2'b00, fpix[16]};
            end
            3'd6: begin
                pix2_q <= fpix[15:0];
                wchg   <= wchg + (pix_changed ? 3'd1 : 3'd0);
                wedge  <= wedge + {2'b00, fpix[16]};
            end
            3'd7: begin
                osr[0] <= osr_in;
                for (k = 1; k < OUT_DEPTH; k = k + 1)
                    osr[k] <= osr[k-1];
                if (osr_fill != OUT_FULL)
                    osr_fill <= osr_fill + 3'd1;

                // statistic: the frame tag latches the frame just finished
                if (cur_sof) begin
                    if (stat_seen)
                        stat_q <= {stat_edge, stat_chg};
                    else
                        stat_seen <= 1'b1;
                    stat_edge <= {13'd0, wedge + {2'b00, fpix[16]}};
                    stat_chg  <= {13'd0, wchg + (pix_changed ? 3'd1 : 3'd0)};
                end else begin
                    stat_edge <= sat3(stat_edge, wedge + {2'b00, fpix[16]});
                    stat_chg  <= sat3(stat_chg, wchg +
                                               (pix_changed ? 3'd1 : 3'd0));
                end

                // the line ring advances once per line, after the last write
                if (line_end_q)
                    wr <= (wr == 2'd2) ? 2'd0 : (wr + 2'd1);
            end
            default: ;
            endcase
        end
    end

endmodule
