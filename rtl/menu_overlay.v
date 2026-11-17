// =============================================================================
//  menu_overlay.v — popup control panel drawn over the camera picture
//
//  The PS owns the touch protocol and the hit test.  This block only paints.
//  With menu_on low the picture is untouched except a 24x80 tab on the right
//  edge.  With menu_on high an opaque panel covers x >= 520.  stage, knob and
//  param are the values already in the control word; they are latched by the
//  caller on a panel frame boundary so a label does not change mid-frame.
//
//  Rectangles match ps/app/menu_geom.h.  sim/tb_menu_overlay.v checks both the
//  rectangles and one pixel of the '0' glyph.
// =============================================================================
`timescale 1ns / 1ps

module menu_overlay (
    input  wire [10:0] x,
    input  wire [ 9:0] y,
    input  wire        in_active,
    input  wire        menu_on,
    input  wire [ 2:0] stage,
    input  wire [ 2:0] knob,
    input  wire [15:0] param,
    output reg         menu_hit,
    output reg  [15:0] menu_rgb
);

    localparam [15:0] C_BG    = 16'h1082;
    localparam [15:0] C_TITLE = 16'h2104;
    localparam [15:0] C_BTN   = 16'h2945;
    localparam [15:0] C_HI    = 16'h04D8;
    localparam [15:0] C_TEXT  = 16'hFFFF;
    localparam [15:0] C_TAB   = 16'h4A69;

    integer i;
    integer s;
    integer n;
    reg     text_on;

    function [7:0] glyph_row;
        input [7:0] ch;
        input [2:0] row;
        reg [63:0] g;
        begin
            case (ch)
            "0": g = 64'h3C666E7666663C00;
            "1": g = 64'h1838181818187E00;
            "2": g = 64'h3C66060C18307E00;
            "3": g = 64'h3C66061C06663C00;
            "4": g = 64'h0C1C3C6C7E0C0C00;
            "5": g = 64'h7E607C0606663C00;
            "6": g = 64'h1C30607C66663C00;
            "7": g = 64'h7E060C1830303000;
            "8": g = 64'h3C66663C66663C00;
            "9": g = 64'h3C66663E060C3800;
            "A": g = 64'h183C66667E666600;
            "B": g = 64'h7C66667C66667C00;
            "C": g = 64'h3C66606060663C00;
            "D": g = 64'h786C6666666C7800;
            "E": g = 64'h7E60607C60607E00;
            "F": g = 64'h7E60607C60606000;
            "G": g = 64'h3C66606E66663C00;
            "H": g = 64'h6666667E66666600;
            "I": g = 64'h7E18181818187E00;
            "J": g = 64'h0606060666663C00;
            "K": g = 64'h666C78706C666600;
            "L": g = 64'h6060606060607E00;
            "M": g = 64'h63777F6B63636300;
            "N": g = 64'h66767E7E6E666600;
            "O": g = 64'h3C66666666663C00;
            "P": g = 64'h7C66667C60606000;
            "Q": g = 64'h3C66666A66663A00;
            "R": g = 64'h7C66667C6C666600;
            "S": g = 64'h3C66603C06663C00;
            "T": g = 64'h7E18181818181800;
            "U": g = 64'h6666666666663C00;
            "V": g = 64'h66666666663C1800;
            "W": g = 64'h6363636B7F776300;
            "X": g = 64'h66663C183C666600;
            "Y": g = 64'h6666663C18181800;
            "Z": g = 64'h7E060C1830607E00;
            "+": g = 64'h0018187E18180000;
            "-": g = 64'h0000007E00000000;
            default: g = 64'h0;
            endcase
            case (row)
            3'd0: glyph_row = g[63:56];
            3'd1: glyph_row = g[55:48];
            3'd2: glyph_row = g[47:40];
            3'd3: glyph_row = g[39:32];
            3'd4: glyph_row = g[31:24];
            3'd5: glyph_row = g[23:16];
            3'd6: glyph_row = g[15:8];
            default: glyph_row = g[7:0];
            endcase
        end
    endfunction

    function glyph_pixel;
        input [7:0] ch;
        input [2:0] row;
        input [2:0] col;
        reg [7:0] bits;
        begin
            bits = glyph_row(ch, row);
            glyph_pixel = bits[3'd7 - col];
        end
    endfunction

    function is_glyph;
        input [10:0] px;
        input [ 9:0] py;
        input [10:0] ox;
        input [ 9:0] oy;
        input [ 7:0] ch;
        reg [3:0] dx;
        reg [3:0] dy;
        begin
            is_glyph = 1'b0;
            if (ch != 8'd0 && ch != " " &&
                px >= ox && px < ox + 11'd8 &&
                py >= oy && py < oy + 10'd8) begin
                dx = px - ox;
                dy = py - oy;
                is_glyph = glyph_pixel(ch, dy[2:0], dx[2:0]);
            end
        end
    endfunction

    function [7:0] take_char;
        input [63:0] s;
        input [3:0]  idx;
        begin
            case (idx)
            4'd0: take_char = s[63:56];
            4'd1: take_char = s[55:48];
            4'd2: take_char = s[47:40];
            4'd3: take_char = s[39:32];
            4'd4: take_char = s[31:24];
            4'd5: take_char = s[23:16];
            4'd6: take_char = s[15:8];
            4'd7: take_char = s[7:0];
            default: take_char = 8'd0;
            endcase
        end
    endfunction

    function [7:0] stage_ch;
        input [2:0] which;
        input [3:0] idx;
        reg [63:0] s;
        begin
            case (which)
            3'd0: s = "BYPASS  ";
            3'd1: s = "LUT     ";
            3'd2: s = "WIN3X3  ";
            3'd3: s = "HIST    ";
            3'd4: s = "SEGMENT ";
            default: s = "        ";
            endcase
            stage_ch = take_char(s, idx);
        end
    endfunction

    function [7:0] title_ch;
        input [3:0] idx;
        begin
            title_ch = take_char("MENU    ", idx);
        end
    endfunction

    function [4:0] mode_phrase;
        input [2:0] st;
        input [2:0] kn;
        begin
            mode_phrase = 5'd0;
            case (st)
            3'd1: case (kn)
                  3'd1: mode_phrase = 5'd2;
                  3'd2: mode_phrase = 5'd3;
                  3'd3: mode_phrase = 5'd4;
                  3'd4: mode_phrase = 5'd5;
                  3'd5: mode_phrase = 5'd6;
                  default: mode_phrase = 5'd1;
                  endcase
            3'd2: case (kn)
                  3'd1: mode_phrase = 5'd8;
                  3'd2: mode_phrase = 5'd9;
                  3'd3: mode_phrase = 5'd10;
                  3'd4: mode_phrase = 5'd11;
                  3'd5: mode_phrase = 5'd12;
                  default: mode_phrase = 5'd7;
                  endcase
            3'd3: case (kn)
                  3'd1: mode_phrase = 5'd14;
                  3'd2: mode_phrase = 5'd15;
                  default: mode_phrase = 5'd13;
                  endcase
            3'd4: case (kn)
                  3'd0: mode_phrase = 5'd16;
                  3'd1: mode_phrase = 5'd17;
                  3'd2: mode_phrase = 5'd18;
                  3'd3: mode_phrase = 5'd19;
                  3'd4: mode_phrase = 5'd20;
                  3'd5: mode_phrase = 5'd21;
                  3'd6: mode_phrase = 5'd22;
                  default: mode_phrase = 5'd23;
                  endcase
            default: mode_phrase = 5'd0;
            endcase
        end
    endfunction

    function [7:0] phrase_ch;
        input [4:0] id;
        input [3:0] idx;
        reg [63:0] s;
        begin
            case (id)
            5'd0:  s = "RAW     ";
            5'd1:  s = "IDENT   ";
            5'd2:  s = "BRIGHT  ";
            5'd3:  s = "GAMMA   ";
            5'd4:  s = "THRESH  ";
            5'd5:  s = "FALSE   ";
            5'd6:  s = "INVERT  ";
            5'd7:  s = "BOX     ";
            5'd8:  s = "SOBEL   ";
            5'd9:  s = "MEDIAN  ";
            5'd10: s = "ERODE   ";
            5'd11: s = "DILATE  ";
            5'd12: s = "SHARP   ";
            5'd13: s = "HIST    ";
            5'd14: s = "EQUAL   ";
            5'd15: s = "EXPOSE  ";
            5'd16: s = "RED     ";
            5'd17: s = "GREEN   ";
            5'd18: s = "BLUE    ";
            5'd19: s = "YELLOW  ";
            5'd20: s = "PRED    ";
            5'd21: s = "PGRN    ";
            5'd22: s = "PBLU    ";
            5'd23: s = "PYEL    ";
            default: s = "        ";
            endcase
            phrase_ch = take_char(s, idx);
        end
    endfunction

    /* Reserved knobs alias an earlier mode, so the menu does not offer them:
     *   lut / win3x3 : 6 and 7 repeat mode 0
     *   histogram    : 3..7 repeat mode 0
     *   bypass       : no knob changes the picture
     *   segment      : all eight values are a colour rotation plus paint */
    function knob_live;
        input [2:0] st;
        input [2:0] kn;
        begin
            case (st)
            3'd1, 3'd2: knob_live = (kn <= 3'd5);
            3'd3:       knob_live = (kn <= 3'd2);
            3'd4:       knob_live = 1'b1;
            default:    knob_live = 1'b0;
            endcase
        end
    endfunction

    function [2:0] knob_mark;
        input [2:0] st;
        input [2:0] kn;
        begin
            knob_mark = knob_live(st, kn) ? kn : 3'd0;
        end
    endfunction

    function [7:0] hex_ch;
        input [3:0] nib;
        begin
            if (nib < 4'd10)
                hex_ch = "0" + nib;
            else
                hex_ch = "A" + (nib - 4'd10);
        end
    endfunction

    function [3:0] hex_nib;
        input [15:0] value;
        input [3:0]  digit;
        begin
            case (digit)
            4'd0: hex_nib = value[15:12];
            4'd1: hex_nib = value[11:8];
            4'd2: hex_nib = value[7:4];
            4'd3: hex_nib = value[3:0];
            default: hex_nib = 4'd0;
            endcase
        end
    endfunction

    always @(*) begin
        menu_hit = 1'b0;
        menu_rgb = 16'd0;
        text_on  = 1'b0;

        if (in_active && !menu_on) begin
            if (x >= 11'd776 && x < 11'd800 && y >= 10'd200 && y < 10'd280) begin
                menu_hit = 1'b1;
                menu_rgb = C_TAB;
            end
        end else if (in_active && menu_on && x >= 11'd520) begin
            menu_hit = 1'b1;
            menu_rgb = C_BG;

            if (y >= 10'd8 && y < 10'd40)
                menu_rgb = C_TITLE;

            for (s = 0; s < 5; s = s + 1) begin
                if (x >= 11'd528 && x < 11'd792 &&
                    y >= (10'd48 + s * 40) && y < (10'd48 + s * 40 + 36))
                    menu_rgb = (stage == s[2:0]) ? C_HI : C_BTN;
            end

            for (n = 0; n < 8; n = n + 1) begin
                if (knob_live(stage, n[2:0]) &&
                    x >= (11'd528 + (n % 4) * 67) &&
                    x <  (11'd528 + (n % 4) * 67 + 63) &&
                    y >= (10'd248 + (n / 4) * 32) &&
                    y <  (10'd248 + (n / 4) * 32 + 28))
                    menu_rgb = (knob_mark(stage, knob) == n[2:0]) ? C_HI : C_BTN;
            end

            if (x >= 11'd528 && x < 11'd600 && y >= 10'd344 && y < 10'd392)
                menu_rgb = C_BTN;
            if (x >= 11'd712 && x < 11'd792 && y >= 10'd344 && y < 10'd392)
                menu_rgb = C_BTN;

            for (i = 0; i < 8; i = i + 1) begin
                if (is_glyph(x, y, 11'd528 + i * 8, 10'd16, title_ch(i[3:0])))
                    text_on = 1'b1;
                if (is_glyph(x, y, 11'd528 + i * 8, 10'd312,
                             phrase_ch(mode_phrase(stage, knob), i[3:0])))
                    text_on = 1'b1;
                if (i < 4 &&
                    is_glyph(x, y, 11'd640 + i * 8, 10'd364,
                             hex_ch(hex_nib(param, i[3:0]))))
                    text_on = 1'b1;
            end

            for (s = 0; s < 5; s = s + 1)
                for (i = 0; i < 8; i = i + 1)
                    if (is_glyph(x, y, 11'd536 + i * 8, 10'd62 + s * 40,
                                 stage_ch(s[2:0], i[3:0])))
                        text_on = 1'b1;

            for (n = 0; n < 8; n = n + 1)
                if (knob_live(stage, n[2:0]) &&
                    is_glyph(x, y,
                             11'd528 + (n % 4) * 67 + 27,
                             10'd248 + (n / 4) * 32 + 10,
                             "0" + n[2:0]))
                    text_on = 1'b1;

            if (is_glyph(x, y, 11'd560, 10'd364, "-"))
                text_on = 1'b1;
            if (is_glyph(x, y, 11'd748, 10'd364, "+"))
                text_on = 1'b1;

            if (text_on)
                menu_rgb = C_TEXT;
        end
    end

endmodule
