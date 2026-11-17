// =============================================================================
//  lcd_display.v — 800x480 panel timing + frame-buffer readout
//
//  Timing (the set the vendor tutorials use on this panel):
//      H: 128 sync + 88 back + 800 active + 40 front = 1056
//      V:   3 sync + 33 back + 480 active + 10 front =  526
//      1056 x 526 @ 33.333 MHz = 60.0 Hz, HSYNC/VSYNC negative, DE active high
//
//  Pixel source: a show-ahead 64-bit FIFO holding four RGB565 pixels per word
//  (pixel 0 in bits [15:0]).  One word is popped every four pixels and shifted
//  out of a 64-bit hold register, so the readout costs one mux and one shifter.
//
//  Buffer switch: once per display frame, at the start of vertical blanking, the
//  module raises rel_req.  The DDR engine acknowledges (rel_ack) and this module
//  drains whatever is left in the FIFO (the prefetch of the buffer it is leaving)
//  before dropping rel_req.  The DDR engine then refills the FIFO from the newly
//  completed camera buffer - hundreds of microseconds before the first active
//  pixel, so the switch never shows a partial frame.
//
//  Missing pixels (FIFO empty inside the active window) are shown as black and
//  mark the frame as "underrun"; the counter reports how many frames were hit.
//
//  The panel position is exported (px_x / px_y / px_active / frame_start) and an
//  overlay mask can tint the pixel before the RGB pins: hist_overlay.v uses that
//  to draw the live histogram over the picture without a second copy of the
//  timing generator.  With ovl_en low the datapath is bit-for-bit the original
//  single-register pixel path.
// =============================================================================
`timescale 1ns / 1ps

module lcd_display #(
    parameter integer H_ACTIVE = 800,
    parameter integer H_SYNC   = 128,
    parameter integer H_BP     = 88,
    parameter integer H_FP     = 40,
    parameter integer V_ACTIVE = 480,
    parameter integer V_SYNC   = 3,
    parameter integer V_BP     = 33,
    parameter integer V_FP     = 10
) (
    input  wire        pix_clk,
    input  wire        rst_n,           // asynchronous, active low
    // pixel FIFO (show-ahead)
    input  wire [63:0] fifo_data,
    input  wire        fifo_empty,
    output wire        fifo_pop,
    // frame-buffer switch handshake
    output reg         rel_req,
    input  wire        rel_ack,
    input  wire        video_valid,     // at least one frame is in DDR
    // mode
    input  wire        test_pattern,
    // histogram overlay, computed outside this block from px_x / px_y
    input  wire        ovl_en,
    input  wire        ovl_hit,
    // menu overlay replaces the pixel where it draws; it wins over the tint
    input  wire        menu_hit,
    input  wire [15:0] menu_rgb,
    // panel position, for the overlay generator
    output wire [10:0] px_x,
    output wire [ 9:0] px_y,
    output wire        px_active,
    output wire        frame_start,
    // panel
    output reg         lcd_hsync,
    output reg         lcd_vsync,
    output reg         lcd_de,
    output reg  [15:0] lcd_rgb,
    // status
    output reg  [15:0] frames,
    output reg  [ 7:0] underruns
);

    localparam integer H_TOTAL = H_ACTIVE + H_SYNC + H_BP + H_FP;
    localparam integer V_TOTAL = V_ACTIVE + V_SYNC + V_BP + V_FP;
    localparam integer H_START = H_SYNC + H_BP;
    localparam integer V_START = V_SYNC + V_BP;

    localparam integer BAR_W   = (H_ACTIVE >= 8) ? (H_ACTIVE / 8) : 1;

    localparam [1:0] S_RUN   = 2'd0,
                     S_WAIT  = 2'd1,
                     S_DRAIN = 2'd2;

    reg [10:0] h_cnt;
    reg [ 9:0] v_cnt;
    reg [ 1:0] st;
    reg [ 1:0] sub;             // which pixel of the 64-bit word is next
    reg [63:0] hold;            // remaining pixels of the word being shown
    reg        underrun_seen;
    reg        frame_valid;     // this frame started with a frame buffer available

    // ---- timing counters ----------------------------------------------------
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt  <= 11'd0;
            v_cnt  <= 10'd0;
            frames <= 16'd0;
        end else if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 11'd0;
            if (v_cnt == V_TOTAL - 1) begin
                v_cnt  <= 10'd0;
                frames <= frames + 16'd1;
            end else begin
                v_cnt <= v_cnt + 10'd1;
            end
        end else begin
            h_cnt <= h_cnt + 11'd1;
        end
    end

    wire h_active = (h_cnt >= H_START) && (h_cnt < H_START + H_ACTIVE);
    wire v_active = (v_cnt >= V_START) && (v_cnt < V_START + V_ACTIVE);
    wire in_active = h_active && v_active;

    wire [10:0] x = h_active ? (h_cnt - H_START) : 11'd0;
    wire [ 9:0] y = v_active ? (v_cnt - V_START) : 10'd0;

    wire frame_blank_start = (h_cnt == 11'd0) && (v_cnt == 10'd0);

    assign px_x        = x;
    assign px_y        = y;
    assign px_active   = in_active;
    assign frame_start = frame_blank_start;

    // ---- frame-buffer switch ------------------------------------------------
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_RUN;
            rel_req <= 1'b0;
        end else begin
            case (st)
            S_RUN: begin
                if (frame_blank_start && video_valid && !test_pattern) begin
                    rel_req <= 1'b1;
                    st      <= S_WAIT;
                end
            end
            S_WAIT: begin
                if (rel_ack) st <= S_DRAIN;
            end
            S_DRAIN: begin
                if (fifo_empty) begin
                    rel_req <= 1'b0;
                    st      <= S_RUN;
                end
            end
            default: st <= S_RUN;
            endcase
        end
    end

    // ---- built-in test pattern: 8 colour bars + white border -----------------
    wire [2:0] bar = (x >= 7 * BAR_W) ? 3'd7 :
                     (x >= 6 * BAR_W) ? 3'd6 :
                     (x >= 5 * BAR_W) ? 3'd5 :
                     (x >= 4 * BAR_W) ? 3'd4 :
                     (x >= 3 * BAR_W) ? 3'd3 :
                     (x >= 2 * BAR_W) ? 3'd2 :
                     (x >= 1 * BAR_W) ? 3'd1 : 3'd0;

    reg [15:0] bar_px;
    always @(*) begin
        case (bar)
        3'd0:    bar_px = 16'hF800;     // red
        3'd1:    bar_px = 16'h07E0;     // green
        3'd2:    bar_px = 16'h001F;     // blue
        3'd3:    bar_px = 16'hFFE0;     // yellow
        3'd4:    bar_px = 16'hF81F;     // magenta
        3'd5:    bar_px = 16'h07FF;     // cyan
        3'd6:    bar_px = 16'hFFFF;     // white
        default: bar_px = 16'h0000;     // black
        endcase
    end

    wire border = (x < 11'd2) || (x >= H_ACTIVE - 2) ||
                  (y < 10'd2) || (y >= V_ACTIVE - 2);
    wire [15:0] pattern_px = border ? 16'hFFFF : bar_px;

    // ---- pixel datapath -----------------------------------------------------
    wire pop_word = (st == S_DRAIN) ||
                    (in_active && !test_pattern && (sub == 2'd0) && !fifo_empty);
    assign fifo_pop = pop_word;

    wire pixel_missing = in_active && !test_pattern && video_valid &&
                         (sub == 2'd0) && fifo_empty;

    // The pixel that goes to the panel this cycle, before the overlay: the same
    // value the original single-register path produced, kept combinational so
    // the overlay blend costs no extra clock of latency against lcd_de.
    reg [15:0] px_next;
    always @(*) begin
        if (!in_active)        px_next = 16'd0;
        else if (test_pattern) px_next = pattern_px;
        else if (sub == 2'd0)  px_next = fifo_empty ? 16'd0 : fifo_data[15:0];
        else                   px_next = hold[31:16];
    end

    wire ovl_draw = ovl_en && ovl_hit;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            sub           <= 2'd0;
            hold          <= 64'd0;
            lcd_hsync     <= 1'b1;
            lcd_vsync     <= 1'b1;
            lcd_de        <= 1'b0;
            lcd_rgb       <= 16'd0;
            underrun_seen <= 1'b0;
            underruns     <= 8'd0;
            frame_valid   <= 1'b0;
        end else begin
            lcd_hsync <= (h_cnt < H_SYNC) ? 1'b0 : 1'b1;
            lcd_vsync <= (v_cnt < V_SYNC) ? 1'b0 : 1'b1;
            lcd_de    <= in_active;

            if (frame_blank_start) begin
                sub         <= 2'd0;
                frame_valid <= video_valid;
            end

            if (in_active && !test_pattern) begin
                if (sub == 2'd0) begin
                    // first pixel of a new word: pop and reload the hold register
                    sub <= 2'd1;
                    if (!fifo_empty) hold <= fifo_data;
                end else begin
                    hold <= {16'd0, hold[63:16]};
                    sub  <= (sub == 2'd3) ? 2'd0 : (sub + 2'd1);
                end
            end

            // menu pixels replace the picture.  The histogram tint keeps red
            // and blue and saturates green, and only where the menu is not drawn.
            if (menu_hit)
                lcd_rgb <= menu_rgb;
            else if (ovl_draw)
                lcd_rgb <= {px_next[15:11], 6'h3F, px_next[4:0]};
            else
                lcd_rgb <= px_next;

            // underrun bookkeeping: count the frames that should have been
            // complete but had a missing pixel
            if (pixel_missing && frame_valid) underrun_seen <= 1'b1;
            if (h_cnt == H_TOTAL - 1 && v_cnt == V_TOTAL - 1 && underrun_seen) begin
                underruns     <= (underruns == 8'hFF) ? underruns : (underruns + 8'd1);
                underrun_seen <= 1'b0;
            end
        end
    end

endmodule
