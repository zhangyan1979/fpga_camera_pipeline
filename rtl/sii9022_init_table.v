// =============================================================================
//  sii9022_init_table.v — SiI9022A HDMI transmitter register table (42 entries)
//
//  Every entry is {8-bit register address, 8-bit value}; the sequence below is
//  the vendor RGB-input / embedded-sync set-up that puts 800x480 RGB565 with
//  DE/HSYNC/VSYNC out over TMDS.  sii9022_init.v walks it one entry per I2C
//  write, device id 0x72, retrying whatever the sink NACKs.
//
//  The ROM is inferred as distributed RAM: 256 x 16 bits, no block RAM.
// =============================================================================
`timescale 1ns / 1ps

module sii9022_init_table #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 8
) (
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output reg  [DATA_WIDTH-1:0] q
);

    reg [DATA_WIDTH-1:0] rom [0:2**ADDR_WIDTH-1];

    initial begin
        rom[0] = 16'hc7_00;
        rom[1] = 16'hBC_01;
        rom[2] = 16'hBD_00;
        rom[3] = 16'hBE_01;
        rom[4] = 16'h00_02;
        rom[5] = 16'h01_3A;
        rom[6] = 16'h02_70;
        rom[7] = 16'h03_17;
        rom[8] = 16'h04_98;
        rom[9] = 16'h05_08;
        rom[10] = 16'h06_65;
        rom[11] = 16'h07_04;
        rom[12] = 16'h08_60;
        rom[13] = 16'h09_00;          //  ---RGB input
        rom[14] = 16'h0A_00;          // ---RGB output
        rom[15] = 16'h0B_00;          //Set AVI
        rom[16] = 16'h0C_00;
        rom[17] = 16'h0D_00;
        rom[18] = 16'h0E_00;
        rom[19] = 16'h0F_00;
        rom[20] = 16'h10_00;
        rom[21] = 16'h11_00;
        rom[22] = 16'h12_00;
        rom[23] = 16'h13_00;
        rom[24] = 16'h14_00;
        rom[25] = 16'h15_00;
        rom[26] = 16'h16_00;
        rom[27] = 16'h17_00;
        rom[28] = 16'h18_00;
        rom[29] = 16'h19_00;          // ---enable color convert, must do it here
        rom[30] = 16'h1E_00;
        rom[31] = 16'h60_04;          // ---embeded sync select
        rom[32] = 16'h62_00;          // ---HBIT_2_HSYNC L
        rom[33] = 16'h63_00;          // ---embede enable and HBIT_2_HSYNC M //bit6=1 for DE
        rom[34] = 16'h64_00;          // ---FIELD2_OFST L
        rom[35] = 16'h65_04;          // ---FIELD2_OFST M
        rom[36] = 16'h66_00;          // ---HWIDTH L
        rom[37] = 16'h67_00;          // ---HWIDTH M
        rom[38] = 16'h68_00;          // ---VBIT_2_VSYNC
        rom[39] = 16'h69_00;          // ---VWIDTH
        rom[40] = 16'hbf_c0;          // ---VWIDTH
        rom[41] = 16'h1A_00;          //Enable TMDS
    end

    always @(posedge clk) begin
        q <= rom[addr];
    end

endmodule
