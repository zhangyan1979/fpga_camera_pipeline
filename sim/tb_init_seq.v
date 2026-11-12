// =============================================================================
//  tb_init_seq.v — register-load test for ov5640_init and sii9022_init
//
//  Both bring-up blocks walk a ROM table and hand each entry to the SCCB byte
//  engine, which is where a wiring mistake is easy and invisible: the sensor
//  acknowledges any well-formed byte, so a wrong register address still looks
//  like a successful init.  This test therefore puts a slave model on each bus,
//  records the bytes it receives and compares every single write with the ROM
//  the block is supposed to be reading:
//
//      ov5640_init   252 writes, 16-bit register address, device 0x78,
//                    5 ms gap after the software-reset entry
//      sii9022_init   42 writes,  8-bit register address, device 0x72
//
//  The ROMs are instantiated here as well, so no expected value is hard-coded:
//  the wire traffic must match the table bit for bit.
// =============================================================================
`timescale 1ns / 1ps

module tb_init_seq;

    localparam integer H_ACTIVE    = 800;
    localparam integer V_ACTIVE    = 480;
    localparam integer CAM_WRITES  = 252;
    localparam integer HDMI_WRITES = 42;

    // time scale: 20 ns clock period, SCCB bit = 4 * 31 clocks = 1240 ns
    reg clk = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    reg rst_n = 1'b0;

    initial begin
        #200 rst_n = 1'b1;
    end

    // =========================================================================
    //  Camera bus (OV5640): 16-bit register address, device 0x78
    // =========================================================================
    wire cam_sclk;
    tri  cam_sdat;
    assign (weak1, weak0) cam_sdat = 1'b1;

    wire        cam_done;
    wire [7:0]  cam_byte;
    wire        cam_byte_stb;
    wire        cam_start_stb;
    wire        cam_stop_stb;

    ov5640_init #(
        .IMAGE_WIDTH    (H_ACTIVE),
        .IMAGE_HEIGHT   (V_ACTIVE),
        .IMAGE_FLIP_EN  (1'b0),
        .IMAGE_MIRROR_EN(1'b0)
    ) u_ov5640_init (
        .clk      (clk),
        .rst_n    (rst_n),
        .init_done(cam_done),
        .i2c_sclk (cam_sclk),
        .i2c_sdat (cam_sdat)
    );

    sccb_slave u_cam_slave (
        .clk       (clk),
        .rst_n     (rst_n),
        .sclk      (cam_sclk),
        .sdat      (cam_sdat),
        .byte_val  (cam_byte),
        .byte_stb  (cam_byte_stb),
        .start_stb (cam_start_stb),
        .stop_stb  (cam_stop_stb)
    );

    // the camera table, read back at the same index the DUT should be using
    reg  [ 7:0] cam_tbl_idx = 8'd0;
    wire [23:0] cam_tbl_q;
    ov5640_init_table_rgb #(
        .IMAGE_WIDTH    (H_ACTIVE),
        .IMAGE_HEIGHT   (V_ACTIVE),
        .IMAGE_FLIP_EN  (1'b0),
        .IMAGE_MIRROR_EN(1'b0)
    ) u_cam_table (
        .clk (clk),
        .addr(cam_tbl_idx),
        .q   (cam_tbl_q)
    );

    // =========================================================================
    //  HDMI bus (SiI9022A): 8-bit register address, device 0x72
    // =========================================================================
    wire hdmi_sclk;
    tri  hdmi_sdat;
    assign (weak1, weak0) hdmi_sdat = 1'b1;

    reg         hdmi_go = 1'b0;
    wire [ 7:0] hdmi_byte;
    wire        hdmi_byte_stb;
    wire        hdmi_start_stb;
    wire        hdmi_stop_stb;

    sii9022_init u_hdmi_init (
        .clk     (clk),
        .rst_n   (rst_n),
        .go      (hdmi_go),
        .i2c_sclk(hdmi_sclk),
        .i2c_sdat(hdmi_sdat)
    );

    sccb_slave u_hdmi_slave (
        .clk       (clk),
        .rst_n     (rst_n),
        .sclk      (hdmi_sclk),
        .sdat      (hdmi_sdat),
        .byte_val  (hdmi_byte),
        .byte_stb  (hdmi_byte_stb),
        .start_stb (hdmi_start_stb),
        .stop_stb  (hdmi_stop_stb)
    );

    reg  [ 7:0] hdmi_tbl_idx = 8'd0;
    wire [15:0] hdmi_tbl_q;
    sii9022_init_table u_hdmi_table (
        .clk (clk),
        .addr(hdmi_tbl_idx),
        .q   (hdmi_tbl_q)
    );

    // =========================================================================
    //  Camera-side scoreboard
    // =========================================================================
    integer cam_errors  = 0;
    integer cam_writes  = 0;
    reg [1:0] cam_phase = 2'd0;             // 0 id, 1 addr hi, 2 addr lo, 3 data
    reg [7:0] cam_ah    = 8'd0;
    reg [7:0] cam_al    = 8'd0;
    integer   t_cam_stop = 0;
    integer   t_cam_go   = 0;
    integer   reset_gap  = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (cam_start_stb) begin
                cam_phase   <= 2'd0;
                cam_tbl_idx <= cam_writes[7:0];
                if (cam_writes == 2) t_cam_go = $time;
            end

            if (cam_byte_stb) begin
                case (cam_phase)
                2'd0: begin
                    if (cam_byte !== 8'h78) begin
                        $display("FAIL cam: device id %02h, expected 78", cam_byte);
                        cam_errors = cam_errors + 1;
                    end
                    cam_phase <= 2'd1;
                end
                2'd1: begin cam_ah <= cam_byte; cam_phase <= 2'd2; end
                2'd2: begin cam_al <= cam_byte; cam_phase <= 2'd3; end
                default: begin
                    // {addr hi, addr lo} and data must match table entry cam_writes
                    if ({cam_ah, cam_al} !== cam_tbl_q[23:8] || cam_byte !== cam_tbl_q[7:0]) begin
                        $display("FAIL cam: write %0d = %04h/%02h, table says %04h/%02h",
                                 cam_writes, {cam_ah, cam_al}, cam_byte,
                                 cam_tbl_q[23:8], cam_tbl_q[7:0]);
                        cam_errors = cam_errors + 1;
                    end
                    cam_writes <= cam_writes + 1;
                    cam_phase  <= 2'd0;
                end
                endcase
            end

            if (cam_stop_stb && cam_writes == 2) t_cam_stop = $time;
        end
    end

    // =========================================================================
    //  HDMI-side scoreboard
    // =========================================================================
    integer hdmi_errors = 0;
    integer hdmi_writes = 0;
    reg [1:0] hdmi_phase = 2'd0;            // 0 id, 1 addr, 2 data
    reg [7:0] hdmi_a     = 8'd0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (hdmi_start_stb) begin
                hdmi_phase   <= 2'd0;
                hdmi_tbl_idx <= hdmi_writes[7:0];
            end

            if (hdmi_byte_stb) begin
                case (hdmi_phase)
                2'd0: begin
                    if (hdmi_byte !== 8'h72) begin
                        $display("FAIL hdmi: device id %02h, expected 72", hdmi_byte);
                        hdmi_errors = hdmi_errors + 1;
                    end
                    hdmi_phase <= 2'd1;
                end
                2'd1: begin hdmi_a <= hdmi_byte; hdmi_phase <= 2'd2; end
                default: begin
                    if (hdmi_a !== hdmi_tbl_q[15:8] || hdmi_byte !== hdmi_tbl_q[7:0]) begin
                        $display("FAIL hdmi: write %0d = %02h/%02h, table says %02h/%02h",
                                 hdmi_writes, hdmi_a, hdmi_byte,
                                 hdmi_tbl_q[15:8], hdmi_tbl_q[7:0]);
                        hdmi_errors = hdmi_errors + 1;
                    end
                    hdmi_writes <= hdmi_writes + 1;
                    hdmi_phase  <= 2'd0;
                end
                endcase
            end
        end
    end

    // =========================================================================
    //  Run
    // =========================================================================
    initial begin
        $display("=== register-load test ===");
        #1_000 hdmi_go = 1'b1;              // HDMI set-up starts immediately
        #100 hdmi_go = 1'b0;

        #55_000_000;                        // camera: 21 ms wake + 252 writes + 5 ms

        if (cam_writes != CAM_WRITES) begin
            $display("FAIL cam: %0d writes, expected %0d", cam_writes, CAM_WRITES);
            cam_errors = cam_errors + 1;
        end
        if (!cam_done) begin
            $display("FAIL cam: init_done never asserted");
            cam_errors = cam_errors + 1;
        end
        if (cam_writes > 2) begin
            reset_gap = (t_cam_go - t_cam_stop) / 1000;    // ns -> us
            if (reset_gap < 5000 || reset_gap > 5500) begin
                $display("FAIL cam: %0d us after the software reset, expected ~5240 us",
                         reset_gap);
                cam_errors = cam_errors + 1;
            end
        end

        if (hdmi_writes != HDMI_WRITES) begin
            $display("FAIL hdmi: %0d writes, expected %0d", hdmi_writes, HDMI_WRITES);
            hdmi_errors = hdmi_errors + 1;
        end

        $display("camera: %0d writes, %0d us reset gap, init_done=%b",
                 cam_writes, reset_gap, cam_done);
        $display("hdmi:   %0d writes", hdmi_writes);

        if (cam_errors == 0 && hdmi_errors == 0) $display("TEST PASS");
        else                                     $display("TEST FAIL: %0d + %0d errors",
                                                          cam_errors, hdmi_errors);
        $finish;
    end

endmodule

// =============================================================================
//  sccb_slave — acknowledges every byte and reports what arrives
//
//  Bytes are shifted in on the SCL rises, the acknowledge is driven on the 9th
//  clock, START is SDA falling and STOP is SDA rising while SCL is high.  The
//  acknowledge fall must not be mistaken for a START, hence the !in_frame guard.
// =============================================================================
module sccb_slave (
    input  wire clk,            // 50 MHz sampling clock
    input  wire rst_n,
    input  wire sclk,
    inout  wire sdat,
    output reg  [7:0] byte_val,
    output reg        byte_stb,
    output reg        start_stb,
    output reg        stop_stb
);

    reg        ack_low = 1'b0;
    assign sdat = ack_low ? 1'b0 : 1'bz;

    reg  [3:0] clk_cnt  = 4'd0;
    reg  [7:0] shreg    = 8'd0;
    reg        in_frame = 1'b0;
    reg        sclk_d   = 1'b1;
    reg        sdat_d   = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            sclk_d    <= 1'b1;
            sdat_d    <= 1'b1;
            clk_cnt   <= 4'd0;
            in_frame  <= 1'b0;
            ack_low   <= 1'b0;
            byte_val  <= 8'd0;
            byte_stb  <= 1'b0;
            start_stb <= 1'b0;
            stop_stb  <= 1'b0;
        end else begin
            sclk_d    <= sclk;
            sdat_d    <= sdat;
            byte_stb  <= 1'b0;
            start_stb <= 1'b0;
            stop_stb  <= 1'b0;

            if (sclk && sclk_d) begin
                if (sdat_d && !sdat && !in_frame) begin
                    in_frame  <= 1'b1;
                    clk_cnt   <= 4'd0;
                    start_stb <= 1'b1;
                end else if (!sdat_d && sdat && in_frame) begin
                    in_frame <= 1'b0;
                    stop_stb <= 1'b1;
                end
            end

            if (sclk && !sclk_d && in_frame) begin
                if (clk_cnt < 4'd8) begin
                    shreg   <= {shreg[6:0], sdat};
                    clk_cnt <= clk_cnt + 4'd1;
                end else begin
                    clk_cnt <= 4'd9;
                    ack_low <= 1'b1;                // 9th clock: acknowledge
                end
            end

            if (!sclk && sclk_d && in_frame && clk_cnt == 4'd9) begin
                ack_low  <= 1'b0;
                byte_val <= shreg;
                byte_stb <= 1'b1;
                clk_cnt  <= 4'd0;
            end
        end
    end

endmodule
