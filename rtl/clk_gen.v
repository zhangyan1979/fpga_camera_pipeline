// =============================================================================
//  clk_gen.v — MMCM: 50 MHz (PS FCLK0) -> 33.333 MHz panel pixel clock
//                                      -> 24.000 MHz OV5640 XVCLK
//
//  VCO = 50 MHz x 24 = 1200 MHz
//      CLKOUT0 = 1200 / 36 = 33.333 MHz   (800x480 panel, 60.0 Hz)
//      CLKOUT1 = 1200 / 50 = 24.000 MHz   (OV5640 XVCLK, table tuned for 24 MHz)
//
//  locked stays low until the MMCM has locked; the top gates every domain reset
//  with it, so no logic runs on an unstable clock.
// =============================================================================
`timescale 1ns / 1ps

module clk_gen (
    input  wire clk50,
    input  wire rst,        // active high (MMCM RST)
    output wire clk_pix,
    output wire clk_cam,
    output wire locked
);

    wire clkfb;
    wire clkfb_buf;
    wire clk_pix_i;
    wire clk_cam_i;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (24.0),
        .CLKFBOUT_PHASE     (0.0),
        .DIVCLK_DIVIDE      (1),
        .CLKIN1_PERIOD      (20.0),
        .CLKOUT0_DIVIDE_F   (36.0),
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .CLKOUT1_DIVIDE     (50),
        .CLKOUT1_DUTY_CYCLE (0.5),
        .CLKOUT1_PHASE      (0.0),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1  (clk50),
        .CLKFBIN (clkfb_buf),
        .RST     (rst),
        .PWRDWN  (1'b0),
        .CLKFBOUT(clkfb),
        .CLKOUT0 (clk_pix_i),
        .CLKOUT1 (clk_cam_i),
        .LOCKED  (locked)
    );

    BUFG u_bufg_fb  (.I(clkfb),     .O(clkfb_buf));
    BUFG u_bufg_pix (.I(clk_pix_i), .O(clk_pix));
    BUFG u_bufg_cam (.I(clk_cam_i), .O(clk_cam));

endmodule
