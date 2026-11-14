// =============================================================================
//  stage_seg.v — colour segmentation and per-label bounding boxes
//
//  Four RGB565 pixels per word are converted to an intensity-independent
//  chroma pair (YCoCg, normalised by Y), tested against four rectangular boxes
//  in the normalised chroma plane and labelled 0..3 (background = 15).  A
//  horizontal 1x3 erosion removes one- and two-pixel runs, and a small
//  label-addressed RAM block keeps xmin/xmax/ymin/ymax for every label.
//
//  knobs and parameters (all frame-stable, supplied by stage_mux):
//    knob[1:0]  mode: rotates the four boxes through labels 0..3, so the
//               console chooses which colour is reported as label 0 in stat
//    knob[2]    1 = paint the detected pixels in a flat per-label colour,
//               0 = pass the camera word through unchanged (bit exact)
//    param[7:0]   box half-width in the normalised chroma plane, Q4 (1.0 = 16)
//    param[15:8]  minimum luminance Y; darker pixels are forced to background
//
//  stat[7:0]   = number of non-empty labels, 0..4
//  stat[15:8]  = label-0 box width in pixels, saturated at 255
//  stat[23:16] = label-0 box height in pixels, saturated at 255
//  stat[31:24] = label-0 centre x in 4-pixel units, (xmin+xmax)>>3
//
//  Colour conversion (shifts and adds only for the colour transform):
//    R={r5,3'b0}  G={g6,2'b0}  B={b5,3'b0}
//    Y  = (R + 2G + B) / 4
//    Co = R - B
//    Cg = G - (R + B)/2
//  R, G and B are multiples of 4, so Y is always even.  A 128x16 reciprocal
//  ROM indexed by Y/2 returns floor(65536/Y); the normalised chroma is
//    co_n = (Co * rec) >> 12   and   cg_n = (Cg * rec) >> 12
//  i.e. Q4 fixed point (16 = 1.0).  No divider: 8 multipliers (one Co and one
//  Cg per pixel) and four copies of the small ROM.  The floor in rec and in
//  the final shift cost less than 1.1 LSB of Q4 (< 0.07 in normalised units);
//  the RGB565 expansion dominates the error.
//
//  Box test: a pixel is label l when
//    |co_n - centre_co[l]| <= param[7:0]  and
//    |cg_n - centre_cg[l]| <= param[7:0]
//  with the four centres taken from the fixed list red, green, blue, yellow
//  rotated by knob[1:0].  Labels are assigned in increasing order (label 0 has
//  priority) so overlapping boxes are deterministic.
//
//  Erosion: pixel i of a line survives when its label equals the labels of
//  i-1 and i+1 (a centred 1x3 window).  The missing neighbour at the left and
//  right edge of the line is replaced by duplication of the edge pixel, so a
//  box that touches the left or top edge keeps its xmin/ymin.  There is no
//  vertical component, so isolated single-pixel noise on a vertical edge
//  survives; the 3x3 stage of another tier can be composed later.  The filter
//  is always on: replace the four er* terms with a_lab[0..3] to bypass it.
//
//  Bounding boxes (Bailey 13.1): one 4-entry RAM per pixel lane, addressed by
//  the pixel label, holds {xmin,xmax,ymin,ymax}.  Four lanes are needed because
//  four pixels are classified per clock; they are merged into the report when
//  the last line of a frame has been written.  A "seen" bit per lane/label is
//  the RAM-efficient equivalent of initialising xmin/ymin to 1023 and xmax/ymax
//  to zero at the frame tag: the first pixel of a label writes min=max=pixel.
//  The frame tag (m_sof) clears all seen bits; after the last pixel of the
//  frame the four lanes are merged into rep_* and reported while the next
//  frame accumulates.
//
//  Latency: four word slots (RGB unpack, normalise, label, eroder/output).  The
//  eroder holds a word until the next word supplies the right neighbour of its
//  last pixel, and flushes the last word of each line on the following clock,
//  which the camera's horizontal blanking absorbs.  Tags and data travel in
//  the same registers, so the output word count and the tag positions are
//  exact: 200 words per line, 96 000 words per frame.
//
//  No stalls, no line buffers, no initial values, one clock domain.
// =============================================================================
`timescale 1ns / 1ps

module stage_seg #(
    parameter integer WORDS_PER_LINE = 200,
    parameter integer LINES          = 480
) (
    input  wire        clk,
    input  wire        rst_n,           // asynchronous, active low
    // input stream: four RGB565 pixels, pixel 0 in bits [15:0]
    input  wire [63:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,
    input  wire        s_eol,
    // output stream, delayed by the stage's own latency
    output wire [63:0] m_data,
    output wire        m_valid,
    output wire        m_sof,
    output wire        m_eol,
    // control, held for a whole frame by stage_mux
    input  wire [15:0] param,
    input  wire [ 7:0] knob,
    // one statistic for the console, sampled once per frame by stage_mux
    output wire [31:0] stat
);

    localparam [3:0] LAB_BG = 4'hF;

    // =========================================================================
    //  RGB565 expansion and YCoCg colour transform (combinational)
    // =========================================================================
    // The 5/6/5 fields are left-aligned into 8 bits (low bits zero).  This
    // keeps R, G, B and therefore Y on a 4-unit grid, which halves the
    // reciprocal table; it costs at most 7/255 in the RGB value itself.
    function [7:0] r8_of;
        input [15:0] p;
        begin
            r8_of = {p[15:11], 3'b000};
        end
    endfunction

    function [7:0] g8_of;
        input [15:0] p;
        begin
            g8_of = {p[10:5], 2'b00};
        end
    endfunction

    function [7:0] b8_of;
        input [15:0] p;
        begin
            b8_of = {p[4:0], 3'b000};
        end
    endfunction

    integer i;

    reg [ 7:0] w_y  [0:3];
    reg signed [ 8:0] w_co [0:3];
    reg signed [ 9:0] w_cg [0:3];

    reg [7:0]  u_r;
    reg [7:0]  u_g;
    reg [7:0]  u_b;
    reg [9:0]  u_sum;
    reg [8:0]  u_rb;

    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            u_r   = r8_of(s_data[16*i +: 16]);
            u_g   = g8_of(s_data[16*i +: 16]);
            u_b   = b8_of(s_data[16*i +: 16]);
            u_sum = {2'b00, u_r} + {1'b0, u_g, 1'b0} + {2'b00, u_b};
            u_rb  = {1'b0, u_r} + {1'b0, u_b};
            w_y[i]  = u_sum[9:2];
            w_co[i] = $signed({1'b0, u_r}) - $signed({1'b0, u_b});
            w_cg[i] = $signed({1'b0, u_g}) - $signed({1'b0, u_rb[8:1]});
        end
    end

    // =========================================================================
    //  Pipeline stage 1: RGB unpacked, Y/Co/Cg registered
    // =========================================================================
    reg [63:0] r1_data;
    reg        r1_valid, r1_sof, r1_eol;
    reg [ 7:0] r1_y  [0:3];
    reg signed [ 8:0] r1_co [0:3];
    reg signed [ 9:0] r1_cg [0:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_data  <= 64'd0;
            r1_valid <= 1'b0;
            r1_sof   <= 1'b0;
            r1_eol   <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                r1_y[i]  <= 8'd0;
                r1_co[i] <= 9'sd0;
                r1_cg[i] <= 10'sd0;
            end
        end else begin
            r1_data  <= s_data;
            r1_valid <= s_valid;
            r1_sof   <= s_sof;
            r1_eol   <= s_eol;
            for (i = 0; i < 4; i = i + 1) begin
                r1_y[i]  <= w_y[i];
                r1_co[i] <= w_co[i];
                r1_cg[i] <= w_cg[i];
            end
        end
    end

    // =========================================================================
    //  Reciprocal ROM: floor(65536 / Y) for every possible Y
    // =========================================================================
    // Y is always even (R, G, B are multiples of 4), so index Y/2 and store
    // floor(32768 / (Y/2)) = floor(65536 / Y).  Y = 0 has no reciprocal and is
    // forced to background by the luminance test.
    function [15:0] rec_of;
        input [6:0] y2;
        begin
            case (y2)
            7'd1: rec_of = 16'd32768;  7'd2: rec_of = 16'd16384;  7'd3: rec_of = 16'd10922;
            7'd4: rec_of = 16'd8192;  7'd5: rec_of = 16'd6553;  7'd6: rec_of = 16'd5461;
            7'd7: rec_of = 16'd4681;  7'd8: rec_of = 16'd4096;  7'd9: rec_of = 16'd3640;
            7'd10: rec_of = 16'd3276;  7'd11: rec_of = 16'd2978;  7'd12: rec_of = 16'd2730;
            7'd13: rec_of = 16'd2520;  7'd14: rec_of = 16'd2340;  7'd15: rec_of = 16'd2184;
            7'd16: rec_of = 16'd2048;  7'd17: rec_of = 16'd1927;  7'd18: rec_of = 16'd1820;
            7'd19: rec_of = 16'd1724;  7'd20: rec_of = 16'd1638;  7'd21: rec_of = 16'd1560;
            7'd22: rec_of = 16'd1489;  7'd23: rec_of = 16'd1424;  7'd24: rec_of = 16'd1365;
            7'd25: rec_of = 16'd1310;  7'd26: rec_of = 16'd1260;  7'd27: rec_of = 16'd1213;
            7'd28: rec_of = 16'd1170;  7'd29: rec_of = 16'd1129;  7'd30: rec_of = 16'd1092;
            7'd31: rec_of = 16'd1057;  7'd32: rec_of = 16'd1024;  7'd33: rec_of = 16'd992;
            7'd34: rec_of = 16'd963;  7'd35: rec_of = 16'd936;  7'd36: rec_of = 16'd910;
            7'd37: rec_of = 16'd885;  7'd38: rec_of = 16'd862;  7'd39: rec_of = 16'd840;
            7'd40: rec_of = 16'd819;  7'd41: rec_of = 16'd799;  7'd42: rec_of = 16'd780;
            7'd43: rec_of = 16'd762;  7'd44: rec_of = 16'd744;  7'd45: rec_of = 16'd728;
            7'd46: rec_of = 16'd712;  7'd47: rec_of = 16'd697;  7'd48: rec_of = 16'd682;
            7'd49: rec_of = 16'd668;  7'd50: rec_of = 16'd655;  7'd51: rec_of = 16'd642;
            7'd52: rec_of = 16'd630;  7'd53: rec_of = 16'd618;  7'd54: rec_of = 16'd606;
            7'd55: rec_of = 16'd595;  7'd56: rec_of = 16'd585;  7'd57: rec_of = 16'd574;
            7'd58: rec_of = 16'd564;  7'd59: rec_of = 16'd555;  7'd60: rec_of = 16'd546;
            7'd61: rec_of = 16'd537;  7'd62: rec_of = 16'd528;  7'd63: rec_of = 16'd520;
            7'd64: rec_of = 16'd512;  7'd65: rec_of = 16'd504;  7'd66: rec_of = 16'd496;
            7'd67: rec_of = 16'd489;  7'd68: rec_of = 16'd481;  7'd69: rec_of = 16'd474;
            7'd70: rec_of = 16'd468;  7'd71: rec_of = 16'd461;  7'd72: rec_of = 16'd455;
            7'd73: rec_of = 16'd448;  7'd74: rec_of = 16'd442;  7'd75: rec_of = 16'd436;
            7'd76: rec_of = 16'd431;  7'd77: rec_of = 16'd425;  7'd78: rec_of = 16'd420;
            7'd79: rec_of = 16'd414;  7'd80: rec_of = 16'd409;  7'd81: rec_of = 16'd404;
            7'd82: rec_of = 16'd399;  7'd83: rec_of = 16'd394;  7'd84: rec_of = 16'd390;
            7'd85: rec_of = 16'd385;  7'd86: rec_of = 16'd381;  7'd87: rec_of = 16'd376;
            7'd88: rec_of = 16'd372;  7'd89: rec_of = 16'd368;  7'd90: rec_of = 16'd364;
            7'd91: rec_of = 16'd360;  7'd92: rec_of = 16'd356;  7'd93: rec_of = 16'd352;
            7'd94: rec_of = 16'd348;  7'd95: rec_of = 16'd344;  7'd96: rec_of = 16'd341;
            7'd97: rec_of = 16'd337;  7'd98: rec_of = 16'd334;  7'd99: rec_of = 16'd330;
            7'd100: rec_of = 16'd327;  7'd101: rec_of = 16'd324;  7'd102: rec_of = 16'd321;
            7'd103: rec_of = 16'd318;  7'd104: rec_of = 16'd315;  7'd105: rec_of = 16'd312;
            7'd106: rec_of = 16'd309;  7'd107: rec_of = 16'd306;  7'd108: rec_of = 16'd303;
            7'd109: rec_of = 16'd300;  7'd110: rec_of = 16'd297;  7'd111: rec_of = 16'd295;
            7'd112: rec_of = 16'd292;  7'd113: rec_of = 16'd289;  7'd114: rec_of = 16'd287;
            7'd115: rec_of = 16'd284;  7'd116: rec_of = 16'd282;  7'd117: rec_of = 16'd280;
            7'd118: rec_of = 16'd277;  7'd119: rec_of = 16'd275;  7'd120: rec_of = 16'd273;
            7'd121: rec_of = 16'd270;  7'd122: rec_of = 16'd268;  7'd123: rec_of = 16'd266;
            7'd124: rec_of = 16'd264;  7'd125: rec_of = 16'd262;
            default: rec_of = 16'd0;
            endcase
        end
    endfunction

    reg [15:0] w_rec [0:3];

    // =========================================================================
    //  Pipeline stage 2: normalise by Y (multiply by the reciprocal)
    // =========================================================================
    // The product must be computed in a wide enough context: Verilog sizes a
    // multiply to the largest operand unless the destination is wider, so the
    // 9x17 product would otherwise be truncated before the shift.
    reg signed [25:0] prod_co;
    reg signed [25:0] prod_cg;
    reg signed [12:0] w_co_n [0:3];
    reg signed [12:0] w_cg_n [0:3];
    reg               w_lum  [0:3];

    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            w_rec[i]  = rec_of(r1_y[i][7:1]);
            prod_co   = $signed(r1_co[i]) * $signed({1'b0, w_rec[i]});
            prod_cg   = $signed(r1_cg[i]) * $signed({1'b0, w_rec[i]});
            w_co_n[i] = prod_co >>> 12;
            w_cg_n[i] = prod_cg >>> 12;
            // Y = 0 has no chroma; the minimum-luminance parameter also lets a
            // dark, noisy background fall out before the box test.
            w_lum[i]  = (r1_y[i] != 8'd0) && (r1_y[i] >= param[15:8]);
        end
    end

    reg [63:0] r2_data;
    reg        r2_valid, r2_sof, r2_eol;
    reg signed [12:0] r2_co_n [0:3];
    reg signed [12:0] r2_cg_n [0:3];
    reg               r2_lum  [0:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_data  <= 64'd0;
            r2_valid <= 1'b0;
            r2_sof   <= 1'b0;
            r2_eol   <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                r2_co_n[i] <= 13'sd0;
                r2_cg_n[i] <= 13'sd0;
                r2_lum[i]  <= 1'b0;
            end
        end else begin
            r2_data  <= r1_data;
            r2_valid <= r1_valid;
            r2_sof   <= r1_sof;
            r2_eol   <= r1_eol;
            for (i = 0; i < 4; i = i + 1) begin
                r2_co_n[i] <= w_co_n[i];
                r2_cg_n[i] <= w_cg_n[i];
                r2_lum[i]  <= w_lum[i];
            end
        end
    end

    // =========================================================================
    //  Box centres: four fixed boxes, rotated through the labels by knob[1:0]
    // =========================================================================
    //  box 0 red   (co,cg) = ( 63,-32)
    //  box 1 green          = (  0, 31)
    //  box 2 blue           = (-64,-32)
    //  box 3 yellow         = ( 21, 10)
    //  (values are the exact Q4 results of the conversion above for saturated
    //   RGB565 red, green, blue and yellow)
    reg signed [12:0] cco0, cco1, cco2, cco3;
    reg signed [12:0] ccg0, ccg1, ccg2, ccg3;

    always @(*) begin
        case (knob[1:0])
        2'd0: begin
            cco0 =  13'sd63; ccg0 = -13'sd32;
            cco1 =  13'sd0;  ccg1 =  13'sd31;
            cco2 = -13'sd64; ccg2 = -13'sd32;
            cco3 =  13'sd21; ccg3 =  13'sd10;
        end
        2'd1: begin
            cco0 =  13'sd0;  ccg0 =  13'sd31;
            cco1 = -13'sd64; ccg1 = -13'sd32;
            cco2 =  13'sd21; ccg2 =  13'sd10;
            cco3 =  13'sd63; ccg3 = -13'sd32;
        end
        2'd2: begin
            cco0 = -13'sd64; ccg0 = -13'sd32;
            cco1 =  13'sd21; ccg1 =  13'sd10;
            cco2 =  13'sd63; ccg2 = -13'sd32;
            cco3 =  13'sd0;  ccg3 =  13'sd31;
        end
        default: begin
            cco0 =  13'sd21; ccg0 =  13'sd10;
            cco1 =  13'sd63; ccg1 = -13'sd32;
            cco2 =  13'sd0;  ccg2 =  13'sd31;
            cco3 = -13'sd64; ccg3 = -13'sd32;
        end
        endcase
    end

    function seg_in_box;
        input signed [12:0] co;
        input signed [12:0] cg;
        input signed [12:0] cco;
        input signed [12:0] ccg;
        input signed [12:0] tol;
        begin
            seg_in_box = (co >= (cco - tol)) && (co <= (cco + tol)) &&
                         (cg >= (ccg - tol)) && (cg <= (ccg + tol));
        end
    endfunction

    wire signed [12:0] w_tol = $signed({5'b00000, param[7:0]});

    // =========================================================================
    //  Pipeline stage 3: label assignment (label 0 has priority)
    // =========================================================================
    reg [3:0] w_lab [0:3];

    always @(*) begin
        for (i = 0; i < 4; i = i + 1) begin
            w_lab[i] = LAB_BG;
            if (r2_lum[i]) begin
                if      (seg_in_box(r2_co_n[i], r2_cg_n[i], cco0, ccg0, w_tol)) w_lab[i] = 4'd0;
                else if (seg_in_box(r2_co_n[i], r2_cg_n[i], cco1, ccg1, w_tol)) w_lab[i] = 4'd1;
                else if (seg_in_box(r2_co_n[i], r2_cg_n[i], cco2, ccg2, w_tol)) w_lab[i] = 4'd2;
                else if (seg_in_box(r2_co_n[i], r2_cg_n[i], cco3, ccg3, w_tol)) w_lab[i] = 4'd3;
            end
        end
    end

    reg [63:0] r3_data;
    reg        r3_valid, r3_sof, r3_eol;
    reg [3:0]  r3_lab [0:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r3_data  <= 64'd0;
            r3_valid <= 1'b0;
            r3_sof   <= 1'b0;
            r3_eol   <= 1'b0;
            for (i = 0; i < 4; i = i + 1) r3_lab[i] <= LAB_BG;
        end else begin
            r3_data  <= r2_data;
            r3_valid <= r2_valid;
            r3_sof   <= r2_sof;
            r3_eol   <= r2_eol;
            for (i = 0; i < 4; i = i + 1) r3_lab[i] <= w_lab[i];
        end
    end

    // =========================================================================
    //  Eroder and output stage
    // =========================================================================
    // A word is held in A until the next word supplies the right neighbour of
    // its last pixel (centred 1x3 window).  At the end of a line the right
    // neighbour does not exist, so the last pixel is duplicated; the word is
    // flushed on the following clock and the horizontal blanking absorbs it.
    reg [3:0]  a_lab [0:3];
    reg [63:0] a_data;
    reg        a_sof, a_eol, a_valid;
    reg [3:0]  a_left;          // last pixel of the word before A
    reg        a_left_ok;       // that pixel is in the same line

    wire [3:0] right_ctx = a_eol ? a_lab[3] : r3_lab[0];
    wire [3:0] left_ctx  = a_left_ok ? a_left : a_lab[0];

    wire [3:0] er0 = (a_lab[0] == left_ctx  && a_lab[0] == a_lab[1]) ? a_lab[0] : LAB_BG;
    wire [3:0] er1 = (a_lab[1] == a_lab[0]  && a_lab[1] == a_lab[2]) ? a_lab[1] : LAB_BG;
    wire [3:0] er2 = (a_lab[2] == a_lab[1]  && a_lab[2] == a_lab[3]) ? a_lab[2] : LAB_BG;
    wire [3:0] er3 = (a_lab[3] == a_lab[2]  && a_lab[3] == right_ctx) ? a_lab[3] : LAB_BG;

    reg [63:0] e_data;
    reg        e_valid, e_sof, e_eol;
    reg [3:0]  e_lab [0:3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_lab[0] <= LAB_BG; a_lab[1] <= LAB_BG;
            a_lab[2] <= LAB_BG; a_lab[3] <= LAB_BG;
            a_data   <= 64'd0;
            a_sof    <= 1'b0;
            a_eol    <= 1'b0;
            a_valid  <= 1'b0;
            a_left   <= LAB_BG;
            a_left_ok<= 1'b0;
            e_data   <= 64'd0;
            e_valid  <= 1'b0;
            e_sof    <= 1'b0;
            e_eol    <= 1'b0;
            e_lab[0] <= LAB_BG; e_lab[1] <= LAB_BG;
            e_lab[2] <= LAB_BG; e_lab[3] <= LAB_BG;
        end else begin
            e_valid <= 1'b0;

            if (r3_valid) begin
                if (a_valid) begin
                    e_data  <= a_data;
                    e_sof   <= a_sof;
                    e_eol   <= a_eol;
                    e_valid <= 1'b1;
                    e_lab[0] <= er0; e_lab[1] <= er1;
                    e_lab[2] <= er2; e_lab[3] <= er3;
                end
                a_lab[0] <= r3_lab[0]; a_lab[1] <= r3_lab[1];
                a_lab[2] <= r3_lab[2]; a_lab[3] <= r3_lab[3];
                a_data   <= r3_data;
                a_sof    <= r3_sof;
                a_eol    <= r3_eol;
                a_valid  <= 1'b1;
                a_left   <= a_lab[3];
                a_left_ok<= a_valid && !a_eol && !r3_sof;
            end else if (a_valid && a_eol) begin
                // last word of a line: no right neighbour, duplicate the edge
                e_data  <= a_data;
                e_sof   <= a_sof;
                e_eol   <= a_eol;
                e_valid <= 1'b1;
                e_lab[0] <= er0; e_lab[1] <= er1;
                e_lab[2] <= er2; e_lab[3] <= er3;
                a_valid <= 1'b0;
            end
        end
    end

    // =========================================================================
    //  Pixel output: pass through, or paint detected pixels flat
    // =========================================================================
    function [15:0] paint_col;
        input [3:0] lab;
        begin
            case (lab)
            4'd0:    paint_col = 16'hF800;      // red
            4'd1:    paint_col = 16'h07E0;      // green
            4'd2:    paint_col = 16'h001F;      // blue
            default: paint_col = 16'hFFE0;      // yellow
            endcase
        end
    endfunction

    wire [15:0] p0 = (e_lab[0] == LAB_BG) ? e_data[15:0]  : paint_col(e_lab[0]);
    wire [15:0] p1 = (e_lab[1] == LAB_BG) ? e_data[31:16] : paint_col(e_lab[1]);
    wire [15:0] p2 = (e_lab[2] == LAB_BG) ? e_data[47:32] : paint_col(e_lab[2]);
    wire [15:0] p3 = (e_lab[3] == LAB_BG) ? e_data[63:48] : paint_col(e_lab[3]);
    wire [63:0] painted = {p3, p2, p1, p0};

    assign m_data  = knob[2] ? painted : e_data;
    assign m_valid = e_valid;
    assign m_sof   = e_sof;
    assign m_eol   = e_eol;

    // =========================================================================
    //  Geometry on the output stream (pixel x = 4*m_wx + lane)
    // =========================================================================
    wire       m_eol_i;
    wire [8:0] m_wx, m_wy;

    img_geom #(
        .WORDS_PER_LINE(WORDS_PER_LINE)
    ) u_geom (
        .clk  (clk),
        .rst_n(rst_n),
        .sof  (m_sof),
        .valid(m_valid),
        .eol  (m_eol_i),
        .wx   (m_wx),
        .wy   (m_wy)
    );

    // =========================================================================
    //  Per-label bounding boxes: four parallel label-addressed RAM lanes
    // =========================================================================
    wire [9:0] l0_xmin, l0_xmax, l0_ymin, l0_ymax;
    wire [9:0] l1_xmin, l1_xmax, l1_ymin, l1_ymax;
    wire [9:0] l2_xmin, l2_xmax, l2_ymin, l2_ymax;
    wire [9:0] l3_xmin, l3_xmax, l3_ymin, l3_ymax;
    wire       l0_pres, l1_pres, l2_pres, l3_pres;

    wire [10:0] x_word  = {m_wx, 2'b00};
    wire [9:0]  x_lane0 = x_word[9:0];
    wire [9:0]  x_lane1 = x_word[9:0] + 10'd1;
    wire [9:0]  x_lane2 = x_word[9:0] + 10'd2;
    wire [9:0]  x_lane3 = x_word[9:0] + 10'd3;

    wire [1:0] merge_idx;
    wire       merging;

    seg_bbox_lane u_lane0 (
        .clk(clk), .rst_n(rst_n),
        .new_frame(m_sof), .valid(m_valid),
        .x(x_lane0), .y({1'b0, m_wy}), .label(e_lab[0]),
        .merge_en(merging), .merge_idx(merge_idx),
        .merge_xmin(l0_xmin), .merge_xmax(l0_xmax),
        .merge_ymin(l0_ymin), .merge_ymax(l0_ymax),
        .merge_present(l0_pres)
    );

    seg_bbox_lane u_lane1 (
        .clk(clk), .rst_n(rst_n),
        .new_frame(m_sof), .valid(m_valid),
        .x(x_lane1), .y({1'b0, m_wy}), .label(e_lab[1]),
        .merge_en(merging), .merge_idx(merge_idx),
        .merge_xmin(l1_xmin), .merge_xmax(l1_xmax),
        .merge_ymin(l1_ymin), .merge_ymax(l1_ymax),
        .merge_present(l1_pres)
    );

    seg_bbox_lane u_lane2 (
        .clk(clk), .rst_n(rst_n),
        .new_frame(m_sof), .valid(m_valid),
        .x(x_lane2), .y({1'b0, m_wy}), .label(e_lab[2]),
        .merge_en(merging), .merge_idx(merge_idx),
        .merge_xmin(l2_xmin), .merge_xmax(l2_xmax),
        .merge_ymin(l2_ymin), .merge_ymax(l2_ymax),
        .merge_present(l2_pres)
    );

    seg_bbox_lane u_lane3 (
        .clk(clk), .rst_n(rst_n),
        .new_frame(m_sof), .valid(m_valid),
        .x(x_lane3), .y({1'b0, m_wy}), .label(e_lab[3]),
        .merge_en(merging), .merge_idx(merge_idx),
        .merge_xmin(l3_xmin), .merge_xmax(l3_xmax),
        .merge_ymin(l3_ymin), .merge_ymax(l3_ymax),
        .merge_present(l3_pres)
    );

    // =========================================================================
    //  Frame-end merge: four lanes x the selected label -> report registers
    // =========================================================================
    function [9:0] min2;
        input [9:0] a, b;
        begin
            min2 = (a < b) ? a : b;
        end
    endfunction

    function [9:0] max2;
        input [9:0] a, b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    wire [9:0] mxmin = min2(min2(l0_xmin, l1_xmin), min2(l2_xmin, l3_xmin));
    wire [9:0] mxmax = max2(max2(l0_xmax, l1_xmax), max2(l2_xmax, l3_xmax));
    wire [9:0] mymin = min2(min2(l0_ymin, l1_ymin), min2(l2_ymin, l3_ymin));
    wire [9:0] mymax = max2(max2(l0_ymax, l1_ymax), max2(l2_ymax, l3_ymax));
    wire       mpres = l0_pres | l1_pres | l2_pres | l3_pres;

    wire frame_end = m_valid && m_eol_i && (m_wy == (LINES - 1));
    reg  frame_end_d;

    // completed frame, exposed through stat and kept while the next frame runs
    reg [9:0] rep_xmin [0:3];
    reg [9:0] rep_xmax [0:3];
    reg [9:0] rep_ymin [0:3];
    reg [9:0] rep_ymax [0:3];
    reg [3:0] rep_present;

    reg [1:0] merge_idx_r;
    reg       merging_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_end_d <= 1'b0;
            merging_r   <= 1'b0;
            merge_idx_r <= 2'd0;
            rep_present <= 4'd0;
            for (i = 0; i < 4; i = i + 1) begin
                rep_xmin[i] <= 10'd0;
                rep_xmax[i] <= 10'd0;
                rep_ymin[i] <= 10'd0;
                rep_ymax[i] <= 10'd0;
            end
        end else begin
            frame_end_d <= frame_end;

            if (frame_end_d) begin
                merging_r   <= 1'b1;
                merge_idx_r <= 2'd0;
            end else if (merging_r) begin
                rep_xmin[merge_idx_r] <= mxmin;
                rep_xmax[merge_idx_r] <= mxmax;
                rep_ymin[merge_idx_r] <= mymin;
                rep_ymax[merge_idx_r] <= mymax;
                rep_present[merge_idx_r] <= mpres;

                if (merge_idx_r == 2'd3) merging_r <= 1'b0;
                merge_idx_r <= merge_idx_r + 2'd1;
            end
        end
    end

    assign merging   = merging_r;
    assign merge_idx = merge_idx_r;

    // =========================================================================
    //  Statistic
    // =========================================================================
    wire [7:0] n_labels = {7'd0, rep_present[0]} + {7'd0, rep_present[1]} +
                          {7'd0, rep_present[2]} + {7'd0, rep_present[3]};

    wire [9:0] w0 = rep_present[0] ? (rep_xmax[0] - rep_xmin[0] + 10'd1) : 10'd0;
    wire [9:0] h0 = rep_present[0] ? (rep_ymax[0] - rep_ymin[0] + 10'd1) : 10'd0;
    wire [10:0] cxsum = {1'b0, rep_xmin[0]} + {1'b0, rep_xmax[0]};

    wire [7:0] stat_w  = (w0 > 10'd255) ? 8'd255 : w0[7:0];
    wire [7:0] stat_h  = (h0 > 10'd255) ? 8'd255 : h0[7:0];
    wire [7:0] stat_cx = rep_present[0] ? cxsum[10:3] : 8'd0;

    assign stat = {stat_cx, stat_h, stat_w, n_labels};

endmodule

// =============================================================================
//  seg_bbox_lane — one pixel lane of the per-label bounding-box store
//
//  A four-entry RAM addressed by the pixel label holds {xmin,xmax,ymin,ymax};
//  one lane owns every fourth pixel, so four lanes can update in parallel.  A
//  seen bit per label removes the need to pre-load the RAM at the frame tag:
//  the first pixel of a label writes min = max = that pixel.  The same RAM port
//  is addressed by merge_idx when the four lanes are read back at frame end.
// =============================================================================
module seg_bbox_lane (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        new_frame,       // m_sof of the output stream
    input  wire        valid,
    input  wire [ 9:0] x,
    input  wire [ 9:0] y,
    input  wire [ 3:0] label,
    input  wire        merge_en,
    input  wire [ 1:0] merge_idx,
    output wire [ 9:0] merge_xmin,
    output wire [ 9:0] merge_xmax,
    output wire [ 9:0] merge_ymin,
    output wire [ 9:0] merge_ymax,
    output wire        merge_present
);

    reg [39:0] mem [0:3];
    reg [3:0]  seen;

    wire       is_lab = (label <= 4'd3);
    wire [1:0] addr   = label[1:0];
    wire [1:0] raddr  = merge_en ? merge_idx : addr;
    wire [39:0] rd    = mem[raddr];

    wire [9:0] rd_xmin = rd[39:30];
    wire [9:0] rd_xmax = rd[29:20];
    wire [9:0] rd_ymin = rd[19:10];
    wire [9:0] rd_ymax = rd[9:0];

    wire [9:0] nxmin = (new_frame || !seen[addr]) ? x : ((x < rd_xmin) ? x : rd_xmin);
    wire [9:0] nxmax = (new_frame || !seen[addr]) ? x : ((x > rd_xmax) ? x : rd_xmax);
    wire [9:0] nymin = (new_frame || !seen[addr]) ? y : ((y < rd_ymin) ? y : rd_ymin);
    wire [9:0] nymax = (new_frame || !seen[addr]) ? y : ((y > rd_ymax) ? y : rd_ymax);

    reg [3:0] seen_nxt;

    always @(*) begin
        seen_nxt = new_frame ? 4'd0 : seen;
        if (valid && is_lab) seen_nxt[addr] = 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seen <= 4'd0;
        end else if (valid) begin
            seen <= seen_nxt;
            if (is_lab) begin
                if (new_frame || !seen[addr])
                    mem[addr] <= {x, x, y, y};
                else
                    mem[addr] <= {nxmin, nxmax, nymin, nymax};
            end
        end
    end

    assign merge_xmin = seen[merge_idx] ? rd_xmin : 10'h3FF;
    assign merge_xmax = seen[merge_idx] ? rd_xmax : 10'h000;
    assign merge_ymin = seen[merge_idx] ? rd_ymin : 10'h3FF;
    assign merge_ymax = seen[merge_idx] ? rd_ymax : 10'h000;
    assign merge_present = seen[merge_idx];

endmodule
