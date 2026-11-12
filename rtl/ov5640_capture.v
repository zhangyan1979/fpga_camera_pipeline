// =============================================================================
//  ov5640_capture.v — OV5640 DVP receiver + 4-pixel packer
//
//  The OV5640 is configured (see ov5640_init_table_rgb.v) for H_ACTIVE x
//  V_ACTIVE RGB565 on the DVP bus: two bytes per pixel, HREF high during the
//  active pixels, a VSYNC pulse at the start of a frame, PCLK ~42 MHz.
//
//  This module
//    * pairs the two bytes of every pixel into a 16-bit RGB565 value,
//    * clips the picture to H_ACTIVE x V_ACTIVE (dummy pixels/lines dropped),
//    * packs four pixels into one 64-bit word (pixel 0 in bits [15:0]) so the
//      DDR side moves eight bytes per beat,
//    * restarts the word alignment at every line end and frame start, so a frame
//      is always (H_ACTIVE/4) words x V_ACTIVE lines,
//    * flags the first word of every frame (word_first).  That tag travels
//      through the FIFO with the pixel data, so the DDR engine can switch frame
//      buffers without any clock-domain timing race.
//
//  H_ACTIVE must be a multiple of 4 - the packer only emits whole words.
//  Everything here runs in the camera PCLK domain.
// =============================================================================
`timescale 1ns / 1ps

module ov5640_capture #(
    parameter integer H_ACTIVE = 800,
    parameter integer V_ACTIVE = 480
) (
    input  wire          pclk,
    input  wire          rst_n,      // asynchronous, active low
    input  wire          vsync,
    input  wire          href,
    input  wire [ 7:0]   data,
    // 64-bit packed pixel stream, one word per four pixels
    output reg  [63:0]   word,
    output reg           word_valid,
    output reg           word_first   // this word starts a camera frame
);

    localparam integer XW = $clog2(H_ACTIVE + 1);
    localparam integer YW = $clog2(V_ACTIVE + 1);

    // ---- input pipeline registers (the DVP bus is synchronous to PCLK) ------
    reg          vs_d;
    reg          href_d, href_d2, href_d3;
    reg  [ 7:0]  data_d;

    always @(posedge pclk) begin
        vs_d    <= vsync;
        href_d  <= href;
        href_d2 <= href_d;
        href_d3 <= href_d2;
        data_d  <= data;
    end

    wire vs_rise = vsync & ~vs_d;       // start of a frame

    // End of a line is detected two PCLK cycles late on purpose: href falls one
    // cycle before the last byte pair has been assembled into a pixel, so an
    // immediate line-end reset would drop the last pixel of every line.
    wire line_end = ~href_d2 & href_d3;

    // ---- byte pairing -------------------------------------------------------
    reg          byte_parity;           // even byte = high half, odd = low half
    reg  [ 7:0]  byte_hi;
    reg  [15:0]  pixel;
    reg          pixel_valid;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            byte_parity <= 1'b0;
            byte_hi     <= 8'd0;
            pixel       <= 16'd0;
            pixel_valid <= 1'b0;
        end else if (href_d) begin
            byte_parity <= ~byte_parity;
            if (!byte_parity) begin
                byte_hi     <= data_d;
                pixel_valid <= 1'b0;
            end else begin
                pixel       <= {byte_hi, data_d};
                pixel_valid <= 1'b1;
            end
        end else begin
            byte_parity <= 1'b0;
            pixel_valid <= 1'b0;
        end
    end

    // ---- geometry clipping --------------------------------------------------
    reg [XW-1:0] x_cnt;                 // active pixels in the current line
    reg [YW-1:0] y_cnt;                 // active lines in the current frame

    wire pix_in = pixel_valid && (x_cnt < H_ACTIVE) && (y_cnt < V_ACTIVE);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= {XW{1'b0}};
            y_cnt <= {YW{1'b0}};
        end else if (vs_rise) begin
            x_cnt <= {XW{1'b0}};
            y_cnt <= {YW{1'b0}};
        end else if (line_end) begin
            x_cnt <= {XW{1'b0}};
            if (y_cnt != V_ACTIVE) y_cnt <= y_cnt + 1'b1;
        end else if (pix_in) begin
            x_cnt <= x_cnt + 1'b1;
        end
    end

    // ---- 4-pixel packer -----------------------------------------------------
    reg [ 1:0]  pack_idx;
    reg [63:0]  pack_acc;
    reg         tag_pending;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            pack_idx    <= 2'd0;
            pack_acc    <= 64'd0;
            word        <= 64'd0;
            word_valid  <= 1'b0;
            word_first  <= 1'b0;
            tag_pending <= 1'b0;
        end else if (vs_rise) begin
            // a new frame starts: drop the partial word and tag the next one
            pack_idx    <= 2'd0;
            word_valid  <= 1'b0;
            word_first  <= 1'b0;
            tag_pending <= 1'b1;
        end else if (line_end) begin
            // keep every line word-aligned, whatever the camera's line length
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

endmodule
