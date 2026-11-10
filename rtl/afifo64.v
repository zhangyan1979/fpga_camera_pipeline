// =============================================================================
//  afifo64.v — dual-clock 64-bit "show-ahead" FIFO
//
//  Used twice:
//    * camera PCLK (42 MHz)  -> AXI clock (50 MHz): packed camera words
//    * AXI clock (50 MHz)    -> panel pixel clock (33.3 MHz): display words
//
//  Show-ahead (first-word-fall-through): rd_data is valid while rd_empty is
//  low, and one rd_en pops it - no read-latency bookkeeping on the consumer
//  side.  The memory is distributed RAM, which makes the asynchronous read
//  possible; 128 x 64 bits = 8 Kbit = ~128 LUT6 per instance.
//
//  Pointers are Gray coded and synchronized with 2 flops each way; the
//  full/empty decisions are made in the producer/consumer domain using the
//  synchronized copy, which is the standard, safe construction.
//
//  wr_level / rd_level report the occupancy in words as seen from each side
//  (they trail by the synchroniser latency, which is what the burst engines
//  want: never show a level that is too high on the producer side).
// =============================================================================
`timescale 1ns / 1ps

module afifo64 #(
    parameter integer AW = 7,           // 128 words
    parameter integer W  = 64
) (
    // write side
    input  wire          wr_clk,
    input  wire          wr_rstn,
    input  wire [W-1:0]  wr_data,
    input  wire          wr_en,
    output wire          wr_full,
    output wire [AW:0]   wr_level,
    // read side
    input  wire          rd_clk,
    input  wire          rd_rstn,
    output wire [W-1:0]  rd_data,
    input  wire          rd_en,
    output wire          rd_empty,
    output wire [AW:0]   rd_level
);

    localparam DEPTH = (1 << AW);

    (* ram_style = "distributed" *) reg [W-1:0] mem [0:DEPTH-1];

    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] rgray_s1, rgray_s2;      // read pointer in the write domain
    reg [AW:0] wgray_s1, wgray_s2;      // write pointer in the read domain

    wire [AW:0] wbin_nxt  = wbin + 1'b1;
    wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [AW:0] rbin_nxt  = rbin + 1'b1;
    wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    function [AW:0] g2b;
        input [AW:0] g;
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i - 1)
                g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    // ---- write side ---------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rstn) begin
        if (!wr_rstn) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else if (wr_en && !wr_full) begin
            mem[wbin[AW-1:0]] <= wr_data;
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
        end
    end

    always @(posedge wr_clk or negedge wr_rstn) begin
        if (!wr_rstn) begin
            rgray_s1 <= {(AW+1){1'b0}};
            rgray_s2 <= {(AW+1){1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    assign wr_full  = (wgray_nxt == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
    assign wr_level = wbin - g2b(rgray_s2);

    // ---- read side ----------------------------------------------------------
    assign rd_data  = mem[rbin[AW-1:0]];
    assign rd_empty = (rgray == wgray_s2);

    always @(posedge rd_clk or negedge rd_rstn) begin
        if (!rd_rstn) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else if (rd_en && !rd_empty) begin
            rbin  <= rbin_nxt;
            rgray <= rgray_nxt;
        end
    end

    always @(posedge rd_clk or negedge rd_rstn) begin
        if (!rd_rstn) begin
            wgray_s1 <= {(AW+1){1'b0}};
            wgray_s2 <= {(AW+1){1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    assign rd_level = g2b(wgray_s2) - rbin;

endmodule
