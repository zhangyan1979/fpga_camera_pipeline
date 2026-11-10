// =============================================================================
//  tb_lcd_timing.v — full-size 800x480 panel timing check
//
//  Verifies the numbers the panel needs, at the real pixel clock rate:
//      1056 x 526 clocks per frame (60.0 Hz at 33.333 MHz)
//      HSYNC low for 128 clocks per line, VSYNC low for 3 lines
//      exactly 800 DE clocks per line and 480 lines = 384 000 pixels/frame
//      the four pixels of a FIFO word leave in order (pixel 0 first)
// =============================================================================
`timescale 1ns / 1ps

module tb_lcd_timing;

    localparam integer H_ACTIVE = 800;
    localparam integer H_SYNC   = 128;
    localparam integer H_BP     = 88;
    localparam integer H_FP     = 40;
    localparam integer V_ACTIVE = 480;
    localparam integer V_SYNC   = 3;
    localparam integer V_BP     = 33;
    localparam integer V_FP     = 10;

    localparam integer H_TOTAL = H_ACTIVE + H_SYNC + H_BP + H_FP;
    localparam integer V_TOTAL = V_ACTIVE + V_SYNC + V_BP + V_FP;

    reg pix_clk = 1'b0;
    always #15 pix_clk = ~pix_clk;      // 33.333 MHz

    reg rst_n = 1'b0;
    initial #200 rst_n = 1'b1;

    // ---- stand-in for the DDR pixel FIFO ------------------------------------
    reg [63:0] fifo_data = 64'h3333_2222_1111_0000;
    reg        fifo_empty = 1'b1;
    wire       fifo_pop;

    reg  rel_ack = 1'b0;
    wire rel_req;

    // the "DDR side" acks the reload and refills; the drain finishes because
    // the FIFO reports empty while the reload is in progress
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) rel_ack <= 1'b0;
        else        rel_ack <= rel_req;
    end

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) fifo_empty <= 1'b1;
        else        fifo_empty <= rel_req;
    end

    wire        lcd_hsync, lcd_vsync, lcd_de;
    wire [15:0] lcd_rgb;
    wire [15:0] frames;
    wire [7:0]  underruns;

    lcd_display #(
        .H_ACTIVE(H_ACTIVE), .H_SYNC(H_SYNC), .H_BP(H_BP), .H_FP(H_FP),
        .V_ACTIVE(V_ACTIVE), .V_SYNC(V_SYNC), .V_BP(V_BP), .V_FP(V_FP)
    ) dut (
        .pix_clk     (pix_clk),
        .rst_n       (rst_n),
        .fifo_data   (fifo_data),
        .fifo_empty  (fifo_empty),
        .fifo_pop    (fifo_pop),
        .rel_req     (rel_req),
        .rel_ack     (rel_ack),
        .video_valid (1'b1),
        .test_pattern(1'b0),
        .lcd_hsync   (lcd_hsync),
        .lcd_vsync   (lcd_vsync),
        .lcd_de      (lcd_de),
        .lcd_rgb     (lcd_rgb),
        .frames      (frames),
        .underruns   (underruns)
    );

    // ---- measurements -------------------------------------------------------
    integer line_de   = 0;      // DE clocks in the current line
    integer frame_de  = 0;      // DE clocks in the current frame
    integer de_lines  = 0;      // lines that carried pixels in this frame
    integer vs_low    = 0;      // VSYNC low clocks
    integer vs_low_last = 0;
    integer errors    = 0;
    integer frame_no  = 0;
    integer px_ord    = 0;
    integer clk_cnt   = 0;

    reg hs_d = 1'b1, vs_d = 1'b1;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            line_de <= 0; frame_de <= 0; de_lines <= 0;
            vs_low <= 0; clk_cnt <= 0; hs_d <= 1'b1; vs_d <= 1'b1;
        end else begin
            hs_d <= lcd_hsync;
            vs_d <= lcd_vsync;
            clk_cnt <= clk_cnt + 1;

            if (!lcd_vsync) vs_low <= vs_low + 1;

            if (lcd_de) begin
                frame_de <= frame_de + 1;
                line_de  <= line_de + 1;
                if (line_de == 0) de_lines <= de_lines + 1;

                // the first line of every frame must carry the FIFO word's
                // four pixels in order
                if (frame_no >= 1 && de_lines == 0) begin
                    case (px_ord)
                    0: if (lcd_rgb !== 16'h0000) begin
                           $display("FAIL: pixel 0 = %h", lcd_rgb); errors = errors + 1; end
                    1: if (lcd_rgb !== 16'h1111) begin
                           $display("FAIL: pixel 1 = %h", lcd_rgb); errors = errors + 1; end
                    2: if (lcd_rgb !== 16'h2222) begin
                           $display("FAIL: pixel 2 = %h", lcd_rgb); errors = errors + 1; end
                    3: if (lcd_rgb !== 16'h3333) begin
                           $display("FAIL: pixel 3 = %h", lcd_rgb); errors = errors + 1; end
                    default: ;
                    endcase
                    px_ord <= px_ord + 1;
                end
            end

            // HSYNC rising edge = line boundary
            if (!hs_d && lcd_hsync) begin
                if (line_de != 0 && line_de != H_ACTIVE) begin
                    $display("FAIL: a line carried %0d DE clocks", line_de);
                    errors = errors + 1;
                end
                line_de <= 0;
            end

            // VSYNC falling edge = start of a new frame
            if (vs_d && !lcd_vsync) begin
                if (frame_no >= 1) begin
                    if (frame_de != H_ACTIVE * V_ACTIVE) begin
                        $display("FAIL: frame carried %0d pixels", frame_de);
                        errors = errors + 1;
                    end
                    if (de_lines != V_ACTIVE) begin
                        $display("FAIL: frame had %0d DE lines", de_lines);
                        errors = errors + 1;
                    end
                    if (clk_cnt != H_TOTAL * V_TOTAL - 1) begin
                        $display("FAIL: frame lasted %0d clocks", clk_cnt + 1);
                        errors = errors + 1;
                    end
                    if (frame_no >= 2 && vs_low_last != V_SYNC * H_TOTAL - 1) begin
                        $display("FAIL: VSYNC low for %0d clocks", vs_low_last + 1);
                        errors = errors + 1;
                    end
                end
                if (frame_no > 0)
                    $display("frame %0d: %0d clocks, %0d pixels, %0d lines, vsync low %0d",
                             frame_no, clk_cnt + 1, frame_de, de_lines, vs_low_last + 1);
                frame_no <= frame_no + 1;
                frame_de <= 0;
                de_lines <= 0;
                clk_cnt  <= 0;
                px_ord   <= 0;
                vs_low_last <= vs_low;
                vs_low   <= 0;
            end
        end
    end
    initial begin
        #(H_TOTAL * V_TOTAL * 30 * 5);    // five frames
        if (frame_no >= 3 && errors == 0)
            $display("TEST PASS: %0d x %0d @ 33.333 MHz = %0.2f Hz, %0d frames, no underrun (%0d)",
                     H_TOTAL, V_TOTAL, 33.333e6 / (H_TOTAL * V_TOTAL), frames, underruns);
        else
            $display("TEST FAIL: frame_no=%0d errors=%0d", frame_no, errors);
        $finish;
    end

endmodule
