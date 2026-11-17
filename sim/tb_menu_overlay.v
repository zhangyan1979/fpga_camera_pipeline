// =============================================================================
//  tb_menu_overlay.v — rectangles and one glyph pixel of menu_overlay
//
//  The numbers are the same ones ps/app/menu_geom.h uses for hit testing.
// =============================================================================
`timescale 1ns / 1ps

module tb_menu_overlay;

    reg  [10:0] x;
    reg  [ 9:0] y;
    reg         in_active;
    reg         menu_on;
    reg  [ 2:0] stage;
    reg  [ 2:0] knob;
    reg  [15:0] param;
    wire        menu_hit;
    wire [15:0] menu_rgb;

    integer errors;

    menu_overlay dut (
        .x         (x),
        .y         (y),
        .in_active (in_active),
        .menu_on   (menu_on),
        .stage     (stage),
        .knob      (knob),
        .param     (param),
        .menu_hit  (menu_hit),
        .menu_rgb  (menu_rgb)
    );

    task expect;
        input        hit;
        input [15:0] rgb;
        input [8*48-1:0] what;
        begin
            #1;
            if (menu_hit !== hit || (hit && menu_rgb !== rgb)) begin
                $display("FAIL: %0s at (%0d,%0d) hit=%b rgb=%h, expected hit=%b rgb=%h",
                         what, x, y, menu_hit, menu_rgb, hit, rgb);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors    = 0;
        in_active = 1'b1;
        menu_on   = 1'b0;
        stage     = 3'd0;
        knob      = 3'd0;
        param     = 16'h0000;

        x = 11'd400; y = 10'd240;
        expect(1'b0, 16'h0000, "closed centre");

        x = 11'd780; y = 10'd220;
        expect(1'b1, 16'h4A69, "closed tab");

        x = 11'd775; y = 10'd220;
        expect(1'b0, 16'h0000, "left of tab");

        x = 11'd780; y = 10'd100;
        expect(1'b0, 16'h0000, "above tab");

        in_active = 1'b0;
        x = 11'd780; y = 10'd220;
        expect(1'b0, 16'h0000, "tab in blanking");
        in_active = 1'b1;

        menu_on = 1'b1;
        stage   = 3'd0;
        knob    = 3'd0;
        param   = 16'h0000;

        x = 11'd400; y = 10'd240;
        expect(1'b0, 16'h0000, "open, left of panel");

        x = 11'd519; y = 10'd100;
        expect(1'b0, 16'h0000, "open, x=519");

        x = 11'd520; y = 10'd100;
        expect(1'b1, 16'h1082, "open margin");

        x = 11'd600; y = 10'd20;
        expect(1'b1, 16'h2104, "title fill");

        x = 11'd530; y = 10'd50;
        expect(1'b1, 16'h04D8, "stage 0 highlighted");

        stage = 3'd1;
        expect(1'b1, 16'h2945, "stage 0 dim when stage is 1");

        x = 11'd530; y = 10'd100;
        expect(1'b1, 16'h04D8, "stage 1 highlighted");

        stage = 3'd3;
        x = 11'd530; y = 10'd180;
        expect(1'b1, 16'h04D8, "hist button");

        knob = 3'd5;
        x = 11'd597; y = 10'd282;
        expect(1'b1, 16'h1082, "hist mode 5 hidden");

        x = 11'd530; y = 10'd250;
        expect(1'b1, 16'h04D8, "hist reserved knob marks mode 0");

        stage = 3'd1;
        knob  = 3'd5;
        x = 11'd597; y = 10'd282;
        expect(1'b1, 16'h04D8, "lut mode 5 shown");

        knob = 3'd6;
        x = 11'd662; y = 10'd282;
        expect(1'b1, 16'h1082, "lut mode 6 hidden");

        stage = 3'd4;
        knob  = 3'd7;
        x = 11'd730; y = 10'd282;
        expect(1'b1, 16'h04D8, "segment mode 7 shown");

        param = 16'h0000;
        x = 11'd642; y = 10'd364;
        expect(1'b1, 16'hFFFF, "hex 0 glyph");

        param = 16'h1000;
        expect(1'b1, 16'h1082, "hex 1 is not the 0 glyph there");

        menu_on = 1'b0;
        expect(1'b0, 16'h0000, "value pixel hidden when closed");

        if (errors == 0)
            $display("TEST PASS");
        else
            $display("TEST FAIL: %0d", errors);
        $finish;
    end

endmodule
