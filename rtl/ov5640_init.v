// =============================================================================
//  ov5640_init.v — OV5640 power-up and SCCB register load
//
//  Waits 21 ms after reset (the sensor needs its power-up delay), then writes
//  the RGB565 register table in ov5640_init_table_rgb.v over SCCB, one register
//  at a time, retrying any register the sensor NACKs.  The write of table entry
//  1 (software reset) is followed by an extra 5 ms, because the sensor needs that
//  long to restart its PLL before the next register write.
//
//  Table entries are 24 bits {16-bit register address, 8-bit data}; the table
//  itself patches the frame size and the flip/mirror bits from the parameters
//  below.
//
//  Derived from the XinLuHeng reference design (see README: Provenance), without
//  the ov7725/JPEG options and without the unused camera reset/power-down pins.
// =============================================================================
`timescale 1ns / 1ps

module ov5640_init #(
    parameter [15:0] IMAGE_WIDTH     = 16'd800,
    parameter [15:0] IMAGE_HEIGHT    = 16'd480,
    parameter        IMAGE_FLIP_EN   = 1'b0,
    parameter        IMAGE_MIRROR_EN = 1'b0
) (
    input  wire clk,
    input  wire rst_n,
    output reg  init_done,      // high once every register has been written
    output wire i2c_sclk,
    inout  wire i2c_sdat
);

    localparam integer LUT_SIZE   = 252;
    localparam [20:0]  WAKE_COUNT = 21'h10_0800;    // 21.0 ms at 50 MHz
    localparam [31:0]  RESET_DLY  = 32'h0004_0000;  // 5.2 ms after entry 1

    localparam [1:0] S_IDLE = 2'd0,
                     S_REQ  = 2'd1,
                     S_WAIT = 2'd2;

    reg  [ 7:0] cnt;            // register table index
    reg  [20:0] wake_cnt;
    reg  [ 1:0] st;
    reg         wr_req;
    reg  [31:0] dly_max;

    wire [23:0] lut;
    wire [15:0] lut_reg  = lut[23:8];   // {register address high, low}
    wire [ 7:0] lut_data = lut[7:0];
    wire        wr_done;
    wire        nack;

    // ---- power-up delay -----------------------------------------------------
    wire wake_go = (wake_cnt == WAKE_COUNT - 21'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wake_cnt <= 21'd0;
        else if (wake_cnt != WAKE_COUNT)
            wake_cnt <= wake_cnt + 21'd1;
    end

    // ---- register table -----------------------------------------------------
    ov5640_init_table_rgb #(
        .IMAGE_WIDTH     (IMAGE_WIDTH),
        .IMAGE_HEIGHT    (IMAGE_HEIGHT),
        .IMAGE_FLIP_EN   (IMAGE_FLIP_EN),
        .IMAGE_MIRROR_EN (IMAGE_MIRROR_EN)
    ) u_table (
        .clk (clk),
        .addr(cnt),
        .q   (lut)
    );

    // ---- SCCB byte engine ---------------------------------------------------
    i2c_control u_i2c_control (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_req   (wr_req),
        .addr     (lut_reg),
        .addr_mode(1'b1),           // 16-bit register address
        .wr_data  (lut_data),
        .dev_id   (8'h78),
        .wr_done  (wr_done),
        .ack      (nack),
        .dly_max  (dly_max),
        .i2c_sclk (i2c_sclk),
        .i2c_sdat (i2c_sdat)
    );

    // ---- sequencer: one SCCB write per table entry, retry on NACK -----------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 8'd0;
            wr_req    <= 1'b0;
            dly_max   <= 32'd0;
            init_done <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                if (wake_go) begin
                    cnt  <= 8'd0;
                    st   <= S_REQ;
                end
            end

            S_REQ: begin
                wr_req  <= 1'b1;
                dly_max <= (cnt == 8'd1) ? RESET_DLY : 32'd0;
                st      <= S_WAIT;
            end

            S_WAIT: begin
                wr_req <= 1'b0;
                if (wr_done) begin
                    if (nack) begin
                        st <= S_REQ;                // same register again
                    end else if (cnt == LUT_SIZE - 1) begin
                        init_done <= 1'b1;
                        st        <= S_IDLE;
                    end else begin
                        cnt <= cnt + 8'd1;
                        st  <= S_REQ;
                    end
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
