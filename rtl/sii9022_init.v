// =============================================================================
//  sii9022_init.v — SiI9022A HDMI transmitter set-up over the PL I2C bus
//
//  After the one-second delay the top applies (the sink needs time to appear),
//  writes the 42-entry register table in sii9022_init_table.v.  The part answers
//  on device id 0x72 with an 8-bit register address, so every write is
//  device id, register, data.  If no HDMI sink is attached the writes NACK and
//  are simply retried - the RGB panel output is unaffected.
// =============================================================================
`timescale 1ns / 1ps

module sii9022_init (
    input  wire clk,
    input  wire rst_n,
    input  wire go,             // one-cycle start request
    output wire i2c_sclk,
    inout  wire i2c_sdat
);

    localparam integer LUT_SIZE = 42;
    localparam [7:0]   DEV_ID   = 8'h72;

    localparam [1:0] S_IDLE = 2'd0,
                     S_REQ  = 2'd1,
                     S_WAIT = 2'd2;

    reg  [7:0] cnt;
    reg  [1:0] st;
    reg        wr_req;

    wire [15:0] lut;
    wire [ 7:0] lut_addr = lut[15:8];
    wire [ 7:0] lut_data = lut[7:0];
    wire        wr_done;
    wire        nack;

    // ---- register table -----------------------------------------------------
    sii9022_init_table u_table (
        .clk (clk),
        .addr(cnt),
        .q   (lut)
    );

    // ---- SCCB byte engine ---------------------------------------------------
    i2c_control u_i2c_control (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_req   (wr_req),
        .addr     ({8'd0, lut_addr}),
        .addr_mode(1'b0),           // 8-bit register address
        .wr_data  (lut_data),
        .dev_id   (DEV_ID),
        .wr_done  (wr_done),
        .ack      (nack),
        .dly_max  (32'd0),
        .i2c_sclk (i2c_sclk),
        .i2c_sdat (i2c_sdat)
    );

    // ---- sequencer: one SCCB write per table entry, retry on NACK -----------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= S_IDLE;
            cnt    <= 8'd0;
            wr_req <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                if (go) begin
                    cnt <= 8'd0;
                    st  <= S_REQ;
                end
            end

            S_REQ: begin
                wr_req <= 1'b1;
                st     <= S_WAIT;
            end

            S_WAIT: begin
                wr_req <= 1'b0;
                if (wr_done) begin
                    if (nack) begin
                        st <= S_REQ;                // same register again
                    end else if (cnt == LUT_SIZE - 1) begin
                        cnt <= 8'd0;
                        st  <= S_IDLE;
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
