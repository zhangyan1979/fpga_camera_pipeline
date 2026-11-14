// =============================================================================
//  stage_lut.v — point operations through one lookup table per channel
//
//  Every point operation is "one output pixel depends on one input pixel": the
//  op does not need its neighbours, so it can be applied to the four pixels of a
//  word independently.  Built as arithmetic, a chain of them costs one
//  multiplier/comparator per channel per pixel (twelve of everything here), and
//  each new curve is another arithmetic chain.  Built as a table, the same
//  hardware evaluates any monotone curve at all: only the table contents change
//  (Bailey, Design for Embedded Image Processing on FPGAs, 2e, sec. 7.1.3).
//
//  Pipeline (fixed latency, LAT = 3 words, whatever the mode):
//
//      word in --+--> [1] RGB565 -> 8 bit expand --+
//                |                                +--> [2] table / curve --+
//                |                                                       +-> [3] 8->5/6/5 requantise --+--> word out
//                +-------- {sof, eol, valid} travel inside every register ---+
//
//  Each pipeline register is a single concatenated {data, mode, param, tags}
//  vector, never separate flops for the tags: that is what keeps the frame tag
//  on the first word of the frame and the line end on the last word of a line.
//
//  The control word also travels with the data.  param/knob are frame-stable
//  (stage_mux re-latches them on the emitted frame tag) but a stage with latency
//  would otherwise apply the next frame's setting to the words still inside its
//  pipeline, so the value sampled at the input frame tag is carried alongside
//  the pixels and no word can ever be mapped with another frame's setting.
//
//  Encoding (also in docs/stage_lut.md):
//
//    knob[2:0]  0 identity (bit-exact passthrough)
//               1 brightness/contrast: param[3:0] gain (1..15, 8 = unity),
//                 param[7:4] offset (unsigned, biased by 8: 8 = no offset)
//               2 gamma 0.7 (fixed 256-entry table)
//               3 threshold on luminance: param[7:0] level, white if y > level
//               4 false colour: luminance -> blue/cyan/yellow/red ramp
//               5 invert (255 - v per channel)
//               6,7 reserved, identity
//    stat[15:0]  pixels whose luminance is above param[7:0] (saturates)
//    stat[23:16] frame mean luminance (8-bit)
//    stat[31:24] fully saturated pixels, R=31 G=63 B=31 (saturates at 255)
//
//  Statistics are measured on the *input* pixels, so they are comparable across
//  modes, and are published on the next frame tag: the value on the output is
//  always the frame that just finished, which is what stage_mux samples.
//
//  Channel expansion is bit replication (5->8 {v,v[4:2]}, 6->8 {v,v[5:4]}) and
//  the return to 5/6/5 is truncation of the top bits.  Those two are inverse, so
//  identity is bit-exact; rounding on the way back would break that.
// =============================================================================
`timescale 1ns / 1ps

module stage_lut #(
    parameter integer WORDS_PER_LINE  = 200,
    parameter integer LINES_PER_FRAME = 480
) (
    input  wire        clk,          // cam_pclk
    input  wire        rst_n,        // asynchronous, active low
    // ---- input stream, four RGB565 pixels per word --------------------------
    input  wire [63:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,
    input  wire        s_eol,
    // ---- output stream, delayed by LAT words --------------------------------
    output wire [63:0] m_data,
    output wire        m_valid,
    output wire        m_sof,
    output wire        m_eol,
    // ---- control, frame-stable ----------------------------------------------
    input  wire [15:0] param,
    input  wire [ 7:0] knob,
    // ---- statistic of the frame that just finished --------------------------
    output wire [31:0] stat
);

    localparam integer LAT = 3;
    localparam integer PIX_PER_FRAME = WORDS_PER_LINE * LINES_PER_FRAME * 4;
    // mean luminance accumulator: PIX_PER_FRAME * 255 has to fit
    localparam integer SUMAW = $clog2(PIX_PER_FRAME * 256);

    localparam [2:0] MODE_IDENTITY  = 3'd0;
    localparam [2:0] MODE_BRIGHT    = 3'd1;
    localparam [2:0] MODE_GAMMA     = 3'd2;
    localparam [2:0] MODE_THRESHOLD = 3'd3;
    localparam [2:0] MODE_FALSE     = 3'd4;
    localparam [2:0] MODE_INVERT    = 3'd5;

    // =========================================================================
    //  The luminance curve: one 256-entry table, shared by all three channels
    // =========================================================================
    // y = (R + 2G + B) / 4, the cheapest luma that still weights green twice.
    // One adder chain per pixel, no multiplier: with twelve channels in flight
    // per word a weighted luma would be twelve multipliers on its own.
    //
    // The table is indexed by the expanded 8-bit channel value and returns the
    // 8-bit result, so a single table serves R, G and B and the requantiser in
    // stage 3 decides the final width.

    // mode 2: 255 * (v/255)^0.7, rounded.  A table because v^0.7 is not
    // expressible in cheap integer arithmetic; 256 x 8 bits is exact.
    function [7:0] gamma_curve;
        input [7:0] v;
        reg   [7:0] g;
        begin
            case (v)
            8'd0  : g = 8'd0  ; 8'd1  : g = 8'd5  ; 8'd2  : g = 8'd9  ; 8'd3  : g = 8'd11 ;
            8'd4  : g = 8'd14 ; 8'd5  : g = 8'd16 ; 8'd6  : g = 8'd18 ; 8'd7  : g = 8'd21 ;
            8'd8  : g = 8'd23 ; 8'd9  : g = 8'd25 ; 8'd10 : g = 8'd26 ; 8'd11 : g = 8'd28 ;
            8'd12 : g = 8'd30 ; 8'd13 : g = 8'd32 ; 8'd14 : g = 8'd33 ; 8'd15 : g = 8'd35 ;
            8'd16 : g = 8'd37 ; 8'd17 : g = 8'd38 ; 8'd18 : g = 8'd40 ; 8'd19 : g = 8'd41 ;
            8'd20 : g = 8'd43 ; 8'd21 : g = 8'd44 ; 8'd22 : g = 8'd46 ; 8'd23 : g = 8'd47 ;
            8'd24 : g = 8'd49 ; 8'd25 : g = 8'd50 ; 8'd26 : g = 8'd52 ; 8'd27 : g = 8'd53 ;
            8'd28 : g = 8'd54 ; 8'd29 : g = 8'd56 ; 8'd30 : g = 8'd57 ; 8'd31 : g = 8'd58 ;
            8'd32 : g = 8'd60 ; 8'd33 : g = 8'd61 ; 8'd34 : g = 8'd62 ; 8'd35 : g = 8'd64 ;
            8'd36 : g = 8'd65 ; 8'd37 : g = 8'd66 ; 8'd38 : g = 8'd67 ; 8'd39 : g = 8'd69 ;
            8'd40 : g = 8'd70 ; 8'd41 : g = 8'd71 ; 8'd42 : g = 8'd72 ; 8'd43 : g = 8'd73 ;
            8'd44 : g = 8'd75 ; 8'd45 : g = 8'd76 ; 8'd46 : g = 8'd77 ; 8'd47 : g = 8'd78 ;
            8'd48 : g = 8'd79 ; 8'd49 : g = 8'd80 ; 8'd50 : g = 8'd82 ; 8'd51 : g = 8'd83 ;
            8'd52 : g = 8'd84 ; 8'd53 : g = 8'd85 ; 8'd54 : g = 8'd86 ; 8'd55 : g = 8'd87 ;
            8'd56 : g = 8'd88 ; 8'd57 : g = 8'd89 ; 8'd58 : g = 8'd90 ; 8'd59 : g = 8'd92 ;
            8'd60 : g = 8'd93 ; 8'd61 : g = 8'd94 ; 8'd62 : g = 8'd95 ; 8'd63 : g = 8'd96 ;
            8'd64 : g = 8'd97 ; 8'd65 : g = 8'd98 ; 8'd66 : g = 8'd99 ; 8'd67 : g = 8'd100;
            8'd68 : g = 8'd101; 8'd69 : g = 8'd102; 8'd70 : g = 8'd103; 8'd71 : g = 8'd104;
            8'd72 : g = 8'd105; 8'd73 : g = 8'd106; 8'd74 : g = 8'd107; 8'd75 : g = 8'd108;
            8'd76 : g = 8'd109; 8'd77 : g = 8'd110; 8'd78 : g = 8'd111; 8'd79 : g = 8'd112;
            8'd80 : g = 8'd113; 8'd81 : g = 8'd114; 8'd82 : g = 8'd115; 8'd83 : g = 8'd116;
            8'd84 : g = 8'd117; 8'd85 : g = 8'd118; 8'd86 : g = 8'd119; 8'd87 : g = 8'd120;
            8'd88 : g = 8'd121; 8'd89 : g = 8'd122; 8'd90 : g = 8'd123; 8'd91 : g = 8'd124;
            8'd92 : g = 8'd125; 8'd93 : g = 8'd126; 8'd94 : g = 8'd127; 8'd95 : g = 8'd128;
            8'd96 : g = 8'd129; 8'd97 : g = 8'd130; 8'd98 : g = 8'd131; 8'd99 : g = 8'd131;
            8'd100: g = 8'd132; 8'd101: g = 8'd133; 8'd102: g = 8'd134; 8'd103: g = 8'd135;
            8'd104: g = 8'd136; 8'd105: g = 8'd137; 8'd106: g = 8'd138; 8'd107: g = 8'd139;
            8'd108: g = 8'd140; 8'd109: g = 8'd141; 8'd110: g = 8'd142; 8'd111: g = 8'd142;
            8'd112: g = 8'd143; 8'd113: g = 8'd144; 8'd114: g = 8'd145; 8'd115: g = 8'd146;
            8'd116: g = 8'd147; 8'd117: g = 8'd148; 8'd118: g = 8'd149; 8'd119: g = 8'd150;
            8'd120: g = 8'd150; 8'd121: g = 8'd151; 8'd122: g = 8'd152; 8'd123: g = 8'd153;
            8'd124: g = 8'd154; 8'd125: g = 8'd155; 8'd126: g = 8'd156; 8'd127: g = 8'd157;
            8'd128: g = 8'd157; 8'd129: g = 8'd158; 8'd130: g = 8'd159; 8'd131: g = 8'd160;
            8'd132: g = 8'd161; 8'd133: g = 8'd162; 8'd134: g = 8'd163; 8'd135: g = 8'd163;
            8'd136: g = 8'd164; 8'd137: g = 8'd165; 8'd138: g = 8'd166; 8'd139: g = 8'd167;
            8'd140: g = 8'd168; 8'd141: g = 8'd168; 8'd142: g = 8'd169; 8'd143: g = 8'd170;
            8'd144: g = 8'd171; 8'd145: g = 8'd172; 8'd146: g = 8'd173; 8'd147: g = 8'd173;
            8'd148: g = 8'd174; 8'd149: g = 8'd175; 8'd150: g = 8'd176; 8'd151: g = 8'd177;
            8'd152: g = 8'd178; 8'd153: g = 8'd178; 8'd154: g = 8'd179; 8'd155: g = 8'd180;
            8'd156: g = 8'd181; 8'd157: g = 8'd182; 8'd158: g = 8'd182; 8'd159: g = 8'd183;
            8'd160: g = 8'd184; 8'd161: g = 8'd185; 8'd162: g = 8'd186; 8'd163: g = 8'd186;
            8'd164: g = 8'd187; 8'd165: g = 8'd188; 8'd166: g = 8'd189; 8'd167: g = 8'd190;
            8'd168: g = 8'd190; 8'd169: g = 8'd191; 8'd170: g = 8'd192; 8'd171: g = 8'd193;
            8'd172: g = 8'd194; 8'd173: g = 8'd194; 8'd174: g = 8'd195; 8'd175: g = 8'd196;
            8'd176: g = 8'd197; 8'd177: g = 8'd197; 8'd178: g = 8'd198; 8'd179: g = 8'd199;
            8'd180: g = 8'd200; 8'd181: g = 8'd201; 8'd182: g = 8'd201; 8'd183: g = 8'd202;
            8'd184: g = 8'd203; 8'd185: g = 8'd204; 8'd186: g = 8'd204; 8'd187: g = 8'd205;
            8'd188: g = 8'd206; 8'd189: g = 8'd207; 8'd190: g = 8'd208; 8'd191: g = 8'd208;
            8'd192: g = 8'd209; 8'd193: g = 8'd210; 8'd194: g = 8'd211; 8'd195: g = 8'd211;
            8'd196: g = 8'd212; 8'd197: g = 8'd213; 8'd198: g = 8'd214; 8'd199: g = 8'd214;
            8'd200: g = 8'd215; 8'd201: g = 8'd216; 8'd202: g = 8'd217; 8'd203: g = 8'd217;
            8'd204: g = 8'd218; 8'd205: g = 8'd219; 8'd206: g = 8'd220; 8'd207: g = 8'd220;
            8'd208: g = 8'd221; 8'd209: g = 8'd222; 8'd210: g = 8'd223; 8'd211: g = 8'd223;
            8'd212: g = 8'd224; 8'd213: g = 8'd225; 8'd214: g = 8'd226; 8'd215: g = 8'd226;
            8'd216: g = 8'd227; 8'd217: g = 8'd228; 8'd218: g = 8'd228; 8'd219: g = 8'd229;
            8'd220: g = 8'd230; 8'd221: g = 8'd231; 8'd222: g = 8'd231; 8'd223: g = 8'd232;
            8'd224: g = 8'd233; 8'd225: g = 8'd234; 8'd226: g = 8'd234; 8'd227: g = 8'd235;
            8'd228: g = 8'd236; 8'd229: g = 8'd237; 8'd230: g = 8'd237; 8'd231: g = 8'd238;
            8'd232: g = 8'd239; 8'd233: g = 8'd239; 8'd234: g = 8'd240; 8'd235: g = 8'd241;
            8'd236: g = 8'd242; 8'd237: g = 8'd242; 8'd238: g = 8'd243; 8'd239: g = 8'd244;
            8'd240: g = 8'd244; 8'd241: g = 8'd245; 8'd242: g = 8'd246; 8'd243: g = 8'd247;
            8'd244: g = 8'd247; 8'd245: g = 8'd248; 8'd246: g = 8'd249; 8'd247: g = 8'd249;
            8'd248: g = 8'd250; 8'd249: g = 8'd251; 8'd250: g = 8'd251; 8'd251: g = 8'd252;
            8'd252: g = 8'd253; 8'd253: g = 8'd254; 8'd254: g = 8'd254; 8'd255: g = 8'd255;
            default: g = 8'd255;
            endcase
            gamma_curve = g;
        end
    endfunction

    // mode 1: out = clamp((v * gain) / 8 + offset).  gain 8 is unity and offset 8
    // is zero: both fields are biased, so the neutral word is 0x88, in the middle
    // of the range the console walks with + and -.
    function [7:0] affine;
        input [7:0] v;
        input [3:0] gain;
        input [3:0] offs;
        reg [11:0]       prod;
        reg signed [10:0] sum;
        begin
            prod = v * gain;                                    // <= 3825
            sum  = $signed({1'b0, prod[11:3]}) + $signed({1'b0, offs}) - 11'sd8;
            if (sum < 11'sd0)       affine = 8'd0;
            else if (sum > 11'sd255) affine = 8'd255;
            else                     affine = sum[7:0];
        end
    endfunction

    // mode 4: blue -> cyan -> yellow -> red.  Three linear segments, so the
    // ramp is generated rather than tabulated: a smooth curve has no detail to
    // preserve, and 3 comparators beat a 256 x 16 ROM replicated per pixel.
    function [23:0] false_colour;
        input [7:0] y;
        reg [4:0] pr;
        reg [5:0] pg;
        reg [4:0] pb;
        reg [6:0] t;
        begin
            if (y < 8'd64) begin
                pr = 5'd0;
                pg = y[5:0];
                pb = 5'd31;
            end else if (y < 8'd192) begin
                t  = y - 8'd64;                 // 0 .. 127
                pr = t[6:2];                    // 0 .. 31
                pg = 6'd63;
                pb = 5'd31 - t[6:2];            // 31 .. 0
            end else begin
                t  = y - 8'd192;                // 0 .. 63
                pr = 5'd31;
                pg = 6'd63 - t[5:0];            // 63 .. 0
                pb = 5'd0;
            end
            false_colour = {pr, pr[4:2], pg, pg[5:4], pb, pb[4:2]};
        end
    endfunction

    // =========================================================================
    //  The table stage: 96 bits of 8-bit channels in, 96 bits out
    // =========================================================================
    function [95:0] map_word;
        input [95:0] rgb;           // {r8,g8,b8} per pixel, pixel 0 in [23:0]
        input [ 2:0] mode;
        input [15:0] par;
        integer      i;
        reg [95:0]   acc;
        reg [ 7:0]   r, g, b, y;
        reg [ 7:0]   nr, ng, nb;
        begin
            acc = 96'd0;
            for (i = 0; i < 4; i = i + 1) begin
                r = rgb[i*24 + 16 +: 8];
                g = rgb[i*24 +  8 +: 8];
                b = rgb[i*24 +  0 +: 8];
                y = ({2'b00, r} + {1'b0, g, 1'b0} + {2'b00, b}) >> 2;
                case (mode)
                MODE_BRIGHT: begin
                    nr = affine(r, par[3:0], par[7:4]);
                    ng = affine(g, par[3:0], par[7:4]);
                    nb = affine(b, par[3:0], par[7:4]);
                end
                MODE_GAMMA: begin
                    nr = gamma_curve(r);
                    ng = gamma_curve(g);
                    nb = gamma_curve(b);
                end
                MODE_THRESHOLD: begin
                    // a threshold is a point operation like any other: the whole
                    // 16-bit pixel becomes white or black on the luma compare
                    nr = (y > par[7:0]) ? 8'hFF : 8'h00;
                    ng = nr;
                    nb = nr;
                end
                MODE_FALSE: begin
                    {nr, ng, nb} = false_colour(y);
                end
                MODE_INVERT: begin
                    nr = ~r;
                    ng = ~g;
                    nb = ~b;
                end
                default: begin
                    nr = r;
                    ng = g;
                    nb = b;
                end
                endcase
                acc[i*24 +: 24] = {nr, ng, nb};
            end
            map_word = acc;
        end
    endfunction

    // =========================================================================
    //  The control word travels with the pixels
    // =========================================================================
    // param/knob are frame-stable, but stage_mux re-latches them on the *emitted*
    // frame tag, LAT words after that tag entered this stage.  A word must be
    // mapped with the setting its own frame was started with, so the value is
    // sampled at the input frame tag and carried down the pipeline with the
    // pixels instead of being read from the port at map time.
    reg  [18:0] ctl_frame;      // {knob[2:0], param} of the frame in progress

    // the frame tag takes the value on the wire in the same cycle, so the first
    // word of the frame and every word after it carry one setting
    wire [18:0] ctl_in = (s_valid && s_sof) ? {knob[2:0], param} : ctl_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  ctl_frame <= 19'd0;
        else if (s_valid && s_sof)   ctl_frame <= {knob[2:0], param};
    end

    // =========================================================================
    //  Stage 1: unpack the word and expand each channel to 8 bits
    // =========================================================================
    wire [95:0] exp_rgb;        // {r8,g8,b8} per pixel
    wire [31:0] exp_y;          // luminance per pixel
    wire [ 3:0] exp_above;      // luminance above the mode-3 level
    wire [ 3:0] exp_sat;        // pixel is R=31 G=63 B=31

    genvar gp;
    generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_expand
        wire [4:0] r5 = s_data[gp*16 + 11 +: 5];
        wire [5:0] g6 = s_data[gp*16 +  5 +: 6];
        wire [4:0] b5 = s_data[gp*16 +  0 +: 5];
        wire [7:0] r8 = {r5, r5[4:2]};
        wire [7:0] g8 = {g6, g6[5:4]};
        wire [7:0] b8 = {b5, b5[4:2]};
        wire [9:0] ysum = {2'b00, r8} + {1'b0, g8, 1'b0} + {2'b00, b8};

        assign exp_rgb[gp*24 +: 24] = {r8, g8, b8};
        assign exp_y[gp*8 +: 8]     = ysum[9:2];
        // the level is the one carried with this word, so the statistic and the
        // mode-3 picture always agree on what the threshold was
        assign exp_above[gp]        = (ysum[9:2] > ctl_in[7:0]);
        assign exp_sat[gp]          = (r5 == 5'h1F) && (g6 == 6'h3F) && (b5 == 5'h1F);
    end
    endgenerate

    // =========================================================================
    //  Pipeline: one register per stage, {data, tags} in a single vector
    // =========================================================================
    reg [117:0] sr1;            // {expanded 8-bit rgb 96, mode 3, param 16, tags}
    reg [ 98:0] sr2;            // {mapped 8-bit rgb 96, tags}
    reg [ 66:0] sr3;            // {requantised word 64, tags}

    wire [95:0] sr1_rgb  = sr1[117:22];
    wire [ 2:0] sr1_mode = sr1[21:19];
    wire [15:0] sr1_par  = sr1[18:3];
    wire [95:0] sr2_rgb  = sr2[98:3];

    wire [95:0] map_rgb  = map_word(sr1_rgb, sr1_mode, sr1_par);

    // stage 3: requantise to 5/6/5 and pack four pixels back into a word
    // truncation, not rounding: (expand, truncate) is the identity on 5 and 6
    // bits, which is what makes mode 0 bit-exact
    wire [63:0] req_word;

    genvar gq;
    generate
    for (gq = 0; gq < 4; gq = gq + 1) begin : g_quant
        wire [7:0] qr = sr2_rgb[gq*24 + 16 +: 8];
        wire [7:0] qg = sr2_rgb[gq*24 +  8 +: 8];
        wire [7:0] qb = sr2_rgb[gq*24 +  0 +: 8];

        assign req_word[gq*16 +: 16] = {qr[7:3], qg[7:2], qb[7:3]};
    end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr1 <= 118'd0;
            sr2 <= 99'd0;
            sr3 <= 67'd0;
        end else begin
            sr1 <= {exp_rgb, ctl_in, s_sof, s_eol, s_valid};
            sr2 <= {map_rgb, sr1[2], sr1[1], sr1[0]};
            sr3 <= {req_word, sr2[2], sr2[1], sr2[0]};
        end
    end

    assign m_data  = sr3[66:3];
    assign m_valid = sr3[0];
    assign m_eol   = sr3[1];
    assign m_sof   = sr3[2];

    // =========================================================================
    //  Statistics: measured on the input pixels, published on the frame tag
    // =========================================================================
    // The mean divides by the contract's fixed frame size: a short frame (a
    // stage hand-over cuts one) reports a proportionally dark mean, but the
    // accumulators are reloaded with the tag word at every frame tag, so nothing
    // carries over from one frame to the next.
    reg [15:0]      acc_above;
    reg [ 7:0]      acc_sat;
    reg [SUMAW-1:0] acc_sum;
    reg [15:0]      stat_above;
    reg [ 7:0]      stat_sat;
    reg [SUMAW-1:0] stat_sum;

    wire [2:0]  above_n = {2'b00, exp_above[0]} + {2'b00, exp_above[1]}
                        + {2'b00, exp_above[2]} + {2'b00, exp_above[3]};
    wire [2:0]  sat_n   = {2'b00, exp_sat[0]} + {2'b00, exp_sat[1]}
                        + {2'b00, exp_sat[2]} + {2'b00, exp_sat[3]};
    wire [9:0]  y_n     = {2'b00, exp_y[7:0]} + {2'b00, exp_y[15:8]}
                        + {2'b00, exp_y[23:16]} + {2'b00, exp_y[31:24]};

    wire [16:0]     above_next = {1'b0, acc_above} + {14'd0, above_n};
    wire [ 8:0]     sat_next   = {1'b0, acc_sat} + {6'd0, sat_n};
    wire [SUMAW:0]  sum_next   = {1'b0, acc_sum} + {{(SUMAW-9){1'b0}}, y_n};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_above  <= 16'd0;
            acc_sat    <= 8'd0;
            acc_sum    <= {SUMAW{1'b0}};
            stat_above <= 16'd0;
            stat_sat   <= 8'd0;
            stat_sum   <= {SUMAW{1'b0}};
        end else if (s_valid && s_sof) begin
            // publish the frame that just finished, then start the next one;
            // the frame tag is itself a valid word, so it counts too
            stat_above <= acc_above;
            stat_sat   <= acc_sat;
            stat_sum   <= acc_sum;
            acc_above  <= {13'd0, above_n};
            acc_sat    <= {5'd0, sat_n};
            acc_sum    <= {{(SUMAW-10){1'b0}}, y_n};
        end else if (s_valid) begin
            // both counters saturate rather than wrap; the sum wraps only if a
            // frame is longer than the contract's 96 000 words
            acc_above <= above_next[16] ? 16'hFFFF : above_next[15:0];
            acc_sat   <= sat_next[8]    ? 8'hFF    : sat_next[7:0];
            acc_sum   <= sum_next[SUMAW-1:0];
        end
    end

    // the mean is a division by a constant, done once per frame; the quotient
    // cannot exceed 255, so the 8-bit slice is the whole value
    wire [7:0] mean_y = stat_sum / PIX_PER_FRAME;

    assign stat = {stat_sat, mean_y, stat_above};

endmodule
