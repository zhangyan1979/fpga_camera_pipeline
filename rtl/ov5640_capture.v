// =============================================================================
//  ov5640_capture.v — OV5640 DVP receiver + 4-pixel packer
//
//  The OV5640 is configured (see ov5640_init_table_rgb.v) for
//      800 x 480, RGB565, DVP, 2 bytes per pixel, HREF high during active
//      pixels, VSYNC pulse at the frame start, PCLK ~42 MHz.
//
//  This module
//    * pairs the two bytes of every pixel into a 16-bit RGB565 value,
//    * clips the picture to 800 x 480 (dummy pixels/lines are dropped),
//    * packs 4 pixels into one 64-bit word (pixel 0 in bits [15:0]) so the DDR
//      side moves 8 bytes per beat,
//    * restarts the word alignment on every line so a frame is always
//      200 words x 480 lines = 96 000 words (768 000 bytes),
//    * flags the first word of every frame (word_first).  That tag is what the
//      DDR engine uses to switch frame buffers - it travels through the FIFO
//      with the pixel data, so no clock-domain timing race can ever move the
//      frame boundary.
//
//  All logic runs in the camera PCLK domain.
// =============================================================================
`timescale 1ns / 1ps

module ov5640_capture #(
    parameter integer H_ACTIVE = 800,
    parameter integer V_ACTIVE = 480
) (
    input  wire        pclk,
    input  wire        rst_n,       // asynchronous, active low
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  data,

    // 64-bit packed pixel stream, one word per 4 pixels
    output reg  [63:0] word,
    output reg         word_valid,
    output reg         word_first,  // this word is the first of a frame

    // status
    output reg  [15:0] frame_cnt,
    output reg  [11:0] x_cnt,       // active pixels seen in the current line
    output reg  [11:0] y_cnt,       // active lines seen in the current frame
    output reg         line_active
);

    // ---- input registers (the DVP bus is synchronous to PCLK) ---------------
    reg        vs_d, href_d, href_d2, href_d3;
    reg [7:0]  data_d;

    always @(posedge pclk) begin
        vs_d    <= vsync;
        href_d  <= href;
        href_d2 <= href_d;
        href_d3 <= href_d2;
        data_d  <= data;
    end

    wire vs_rise  = vsync & ~vs_d;          // start of a frame
    wire line_end = ~href_d2 & href_d3;     // end of a line, late enough that the
                                            // last pixel of the line is still taken

    // ---- byte pairing -------------------------------------------------------
    reg [11:0] byte_cnt;                    // bytes seen in the current line
    reg [7:0]  byte_hi;
    reg [15:0] pixel;
    reg        pixel_valid;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt    <= 12'd0;
            byte_hi     <= 8'd0;
            pixel       <= 16'd0;
            pixel_valid <= 1'b0;
        end else if (href_d) begin
            byte_cnt <= byte_cnt + 12'd1;
            if (!byte_cnt[0]) begin
                byte_hi     <= data_d;
                pixel_valid <= 1'b0;
            end else begin
                pixel       <= {byte_hi, data_d};
                pixel_valid <= 1'b1;
            end
        end else begin
            byte_cnt    <= 12'd0;
            pixel_valid <= 1'b0;
        end
    end

    // ---- geometry clipping --------------------------------------------------
    wire pix_in = pixel_valid && (x_cnt < H_ACTIVE) && (y_cnt < V_ACTIVE);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt       <= 12'd0;
            y_cnt       <= 12'd0;
            line_active <= 1'b0;
        end else if (vs_rise) begin
            x_cnt       <= 12'd0;
            y_cnt       <= 12'd0;
            line_active <= 1'b0;
        end else if (line_end) begin
            x_cnt       <= 12'd0;
            y_cnt       <= (y_cnt == V_ACTIVE) ? y_cnt : y_cnt + 12'd1;
            line_active <= 1'b0;
        end else if (pix_in) begin
            x_cnt       <= x_cnt + 12'd1;
            line_active <= 1'b1;
        end
    end

    // ---- 4-pixel packer -----------------------------------------------------
    reg [1:0]  pack_idx;
    reg [63:0] pack_acc;
    reg        tag_pending;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pack_idx    <= 2'd0;
            pack_acc    <= 64'd0;
            word        <= 64'd0;
            word_valid  <= 1'b0;
            word_first  <= 1'b0;
            tag_pending <= 1'b0;
        end else if (vs_rise) begin
            // a new frame starts: drop a partial word and tag the next one
            pack_idx    <= 2'd0;
            word_valid  <= 1'b0;
            word_first  <= 1'b0;
            tag_pending <= 1'b1;
        end else if (line_end) begin
            // keep the words of a line word aligned
            pack_idx   <= 2'd0;
            word_valid <= 1'b0;
            word_first <= 1'b0;
        end else if (pix_in) begin
            if (pack_idx == 2'd3) begin
                word        <= {pixel, pack_acc[63:16]};
                word_valid  <= 1'b1;
                word_first  <= tag_pending;
                tag_pending <= 1'b0;
                pack_idx    <= 2'd0;
            end else begin
                pack_acc   <= {pixel, pack_acc[63:16]};
                word_valid <= 1'b0;
                word_first <= 1'b0;
                pack_idx   <= pack_idx + 2'd1;
            end
        end else begin
            word_valid <= 1'b0;
            word_first <= 1'b0;
        end
    end

    // ---- frame counter ------------------------------------------------------
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) frame_cnt <= 16'd0;
        else if (vs_rise) frame_cnt <= frame_cnt + 16'd1;
    end

endmodule
