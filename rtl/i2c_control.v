// =============================================================================
//  i2c_control.v — SCCB register write sequencer
//
//  Turns one "write this register" request into the byte sequence every camera
//  and HDMI transmitter on this board understands:
//
//      addr_mode = 1 (OV5640)   device id, addr[15:8], addr[7:0], data
//      addr_mode = 0 (SiI9022A) device id, addr[7:0],  data
//
//  START goes out with the device id, STOP with the data byte.  ack reports
//  whether any byte of the sequence was NACKed, and dly_max adds a wait of that
//  many clocks after the sequence (the OV5640 needs 5 ms after its software
//  reset).  Only the write direction is implemented; nothing on this board is
//  ever read back over SCCB.
// =============================================================================
`timescale 1ns / 1ps

module i2c_control #(
    parameter integer SYS_CLOCK = 50_000_000,
    parameter integer SCL_CLOCK = 400_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr_req,      // one-cycle request
    input  wire [15:0] addr,        // register address (8 or 16 bits)
    input  wire        addr_mode,   // 1 = 16-bit register address
    input  wire [ 7:0] wr_data,
    input  wire [ 7:0] dev_id,
    output reg         wr_done,     // one-cycle pulse: sequence finished
    output reg         ack,         // 1 = at least one byte was NACKed
    input  wire [31:0] dly_max,     // extra wait after the sequence, in clocks
    output wire        i2c_sclk,
    inout  wire        i2c_sdat
);

    localparam [5:0] CMD_WR  = 6'b000001,
                     CMD_STA = 6'b000010,
                     CMD_STO = 6'b001000;

    localparam [1:0] S_IDLE = 2'd0,
                     S_SEND = 2'd1,
                     S_WAIT = 2'd2,
                     S_DLY  = 2'd3;

    reg [1:0]  st;
    reg [1:0]  byte_idx;
    reg [5:0]  cmd;
    reg [ 7:0] tx_data;
    reg        go;
    reg [31:0] dly_cnt;

    wire trans_done;
    wire ack_o;

    wire [1:0] byte_last = addr_mode ? 2'd3 : 2'd2;
    wire       last_byte = (byte_idx == byte_last);

    // ---- byte source: device id, register address, register data ------------
    reg [7:0] byte_data;
    always @(*) begin
        case (byte_idx)
        2'd0:    byte_data = dev_id;
        2'd1:    byte_data = addr_mode ? addr[15:8] : addr[7:0];
        2'd2:    byte_data = addr_mode ? addr[7:0]  : wr_data;
        default: byte_data = wr_data;
        endcase
    end

    // START on the first byte, STOP on the last one
    wire [5:0] byte_cmd = CMD_WR |
                          ((byte_idx == 2'd0) ? CMD_STA : 6'd0) |
                          (last_byte          ? CMD_STO : 6'd0);

    i2c_bit_shift #(
        .SYS_CLOCK(SYS_CLOCK),
        .SCL_CLOCK(SCL_CLOCK)
    ) u_i2c_bit_shift (
        .clk       (clk),
        .rst_n     (rst_n),
        .cmd       (cmd),
        .go        (go),
        .tx_data   (tx_data),
        .trans_done(trans_done),
        .ack_o     (ack_o),
        .i2c_sclk  (i2c_sclk),
        .i2c_sdat  (i2c_sdat)
    );

    // ---- sequencer ----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            byte_idx <= 2'd0;
            cmd      <= 6'd0;
            tx_data  <= 8'd0;
            go       <= 1'b0;
            wr_done  <= 1'b0;
            ack      <= 1'b0;
            dly_cnt  <= 32'd0;
        end else begin
            case (st)
            S_IDLE: begin
                go      <= 1'b0;
                wr_done <= 1'b0;
                ack     <= 1'b0;
                if (wr_req) begin
                    byte_idx <= 2'd0;
                    st       <= S_SEND;
                end
            end

            S_SEND: begin
                cmd     <= byte_cmd;
                tx_data <= byte_data;
                go      <= 1'b1;
                st      <= S_WAIT;
            end

            S_WAIT: begin
                go <= 1'b0;
                if (trans_done) begin
                    ack <= ack | ack_o;
                    if (last_byte) begin
                        dly_cnt <= 32'd0;
                        st      <= S_DLY;
                    end else begin
                        byte_idx <= byte_idx + 2'd1;
                        st       <= S_SEND;
                    end
                end
            end

            S_DLY: begin
                if (dly_cnt <= dly_max) begin
                    dly_cnt <= dly_cnt + 32'd1;
                end else begin
                    dly_cnt <= 32'd0;
                    wr_done <= 1'b1;
                    st      <= S_IDLE;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
