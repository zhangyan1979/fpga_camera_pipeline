// =============================================================================
//  afifo.v — dual-clock show-ahead FIFO (Gray-coded pointers)
//
//  Used twice in the video path:
//    * camera PCLK (~42 MHz) -> AXI clock (50 MHz): 65-bit packed camera words
//    * AXI clock (50 MHz)    -> panel pixel clock (33.333 MHz): 64-bit words
//
//  Show-ahead (first-word fall-through): rd_data is valid while rd_empty is low,
//  and one rd_en pops it, so the consumer needs no read-latency bookkeeping.  The
//  memory is distributed RAM, which is what makes the asynchronous read possible
//  (128 x 64 = 8 Kbit, about 128 LUT6 per instance).
//
//  Pointers are Gray coded and synchronized with two flops each way; full is
//  decided in the write domain and empty in the read domain, from the
//  synchronized copy of the other pointer - the standard safe construction.
//  See docs/afifo_gray_pointers.md for why Gray code is used and how full/empty
//  are derived.
//
//  wr_level / rd_level report the occupancy in words as seen from each side.
//  They trail by the synchronizer latency, which is the safe direction for the
//  burst engines: the producer never sees a level that is too high and the
//  consumer never sees one that is too low.
// =============================================================================
`timescale 1ns / 1ps

module afifo #(
    parameter integer AW = 7,           // depth = 2**AW words
    parameter integer W  = 64
) (
    // write side
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire [W-1:0] wr_data,
    input  wire         wr_en,
    output wire         wr_full,
    output wire [AW:0]  wr_level,
    // read side
    input  wire         rd_clk,
    input  wire         rd_rst_n,
    output wire [W-1:0] rd_data,
    input  wire         rd_en,
    output wire         rd_empty,
    output wire [AW:0]  rd_level
);

    localparam integer DEPTH = 1 << AW;
    localparam integer PTR_W = AW + 1;

    (* ram_style = "distributed" *) reg [W-1:0] mem [0:DEPTH-1];

    reg [PTR_W-1:0] wbin, wgray, rbin, rgray;
    reg [PTR_W-1:0] rgray_s1, rgray_s2;     // read pointer in the write domain
    reg [PTR_W-1:0] wgray_s1, wgray_s2;     // write pointer in the read domain

    wire [PTR_W-1:0] wbin_nxt  = wbin + 1'b1;
    wire [PTR_W-1:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [PTR_W-1:0] rbin_nxt  = rbin + 1'b1;
    wire [PTR_W-1:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    function [PTR_W-1:0] gray2bin;
        input [PTR_W-1:0] gray;
        integer i;
        begin
            gray2bin[PTR_W-1] = gray[PTR_W-1];
            for (i = PTR_W-2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ gray[i];
        end
    endfunction

    // ---- write side ---------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin  <= {PTR_W{1'b0}};
            wgray <= {PTR_W{1'b0}};
        end else if (wr_en && !wr_full) begin
            mem[wbin[AW-1:0]] <= wr_data;
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rgray_s1 <= {PTR_W{1'b0}};
            rgray_s2 <= {PTR_W{1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    assign wr_full  = (wgray_nxt == {~rgray_s2[PTR_W-1:PTR_W-2], rgray_s2[PTR_W-3:0]});
    assign wr_level = wbin - gray2bin(rgray_s2);

    // ---- read side ----------------------------------------------------------
    assign rd_data  = mem[rbin[AW-1:0]];
    assign rd_empty = (rgray == wgray_s2);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin  <= {PTR_W{1'b0}};
            rgray <= {PTR_W{1'b0}};
        end else if (rd_en && !rd_empty) begin
            rbin  <= rbin_nxt;
            rgray <= rgray_nxt;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wgray_s1 <= {PTR_W{1'b0}};
            wgray_s2 <= {PTR_W{1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    assign rd_level = gray2bin(wgray_s2) - rbin;

endmodule
