// =============================================================================
//  tb_sccb.v — SCCB write-path test (i2c_control + i2c_bit_shift)
//
//  The slave model below acknowledges every byte and records what it receives,
//  so the test can check
//
//    * the byte sequence of a 16-bit-address write (OV5640): id, addr high,
//      addr low, data, with START on the first byte and STOP on the last one,
//    * the byte sequence of an 8-bit-address write (SiI9022A): id, addr, data,
//    * the NACK report when the slave does not acknowledge,
//    * the extra dly_max wait after the byte sequence,
//    * the SCL period against the configured 400 kHz.
// =============================================================================
`timescale 1ns / 1ps

module tb_sccb;

    localparam integer SYS_CLOCK = 50_000_000;
    localparam integer SCL_CLOCK = 400_000;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz, the rate SYS_CLOCK describes

    reg         rst_n     = 1'b0;
    reg         wr_req    = 1'b0;
    reg  [15:0] addr      = 16'h3008;
    reg         addr_mode = 1'b1;
    reg  [ 7:0] wr_data   = 8'h82;
    reg  [ 7:0] dev_id    = 8'h78;
    reg  [31:0] dly_max   = 32'd0;

    wire        wr_done;
    wire        nack;
    wire        sclk;

    tri         sdat;
    assign (weak1, weak0) sdat = 1'b1;          // bus pull-up

    i2c_control #(
        .SYS_CLOCK(SYS_CLOCK),
        .SCL_CLOCK(SCL_CLOCK)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_req   (wr_req),
        .addr     (addr),
        .addr_mode(addr_mode),
        .wr_data  (wr_data),
        .dev_id   (dev_id),
        .wr_done  (wr_done),
        .ack      (nack),
        .dly_max  (dly_max),
        .i2c_sclk (sclk),
        .i2c_sdat (sdat)
    );

    // =========================================================================
    //  Slave model: shift in bytes on the SCL rises, ACK on the 9th clock
    // =========================================================================
    reg        ack_en  = 1'b1;          // 0 = slave never acknowledges
    reg        ack_low = 1'b0;
    assign sdat = ack_low ? 1'b0 : 1'bz;

    reg  [3:0] clk_cnt = 4'd0;          // clocks completed in the current byte
    reg  [7:0] shreg   = 8'd0;
    reg        in_frame = 1'b0;
    reg  [7:0] rx [0:15];
    integer    nbytes     = 0;
    reg        start_seen = 1'b0;
    reg        stop_seen  = 1'b0;

    reg        sclk_d = 1'b1;
    reg        sdat_d = 1'b1;
    integer    scl_rise_t = 0;
    integer    scl_period = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            sclk_d     <= 1'b1;
            sdat_d     <= 1'b1;
            clk_cnt    <= 4'd0;
            in_frame   <= 1'b0;
            ack_low    <= 1'b0;
            nbytes     <= 0;
            start_seen <= 1'b0;
            stop_seen  <= 1'b0;
        end else begin
            sclk_d <= sclk;
            sdat_d <= sdat;

            // START (SDA falls on a free bus) and STOP (SDA rises in a frame),
            // both while SCL is high.  The acknowledge-bit fall of SDA happens
            // inside a frame and must not be taken for a START.
            if (sclk && sclk_d) begin
                if (sdat_d && !sdat && !in_frame) begin
                    in_frame   <= 1'b1;
                    start_seen <= 1'b1;
                    clk_cnt    <= 4'd0;
                end else if (!sdat_d && sdat && in_frame) begin
                    in_frame  <= 1'b0;
                    stop_seen <= 1'b1;
                end
            end

            if (sclk && !sclk_d) begin              // SCL rising edge
                if (scl_period == 0 && scl_rise_t != 0)
                    scl_period <= $time - scl_rise_t;
                scl_rise_t <= $time;

                if (in_frame) begin
                    if (clk_cnt < 4'd8) begin
                        shreg   <= {shreg[6:0], sdat};
                        clk_cnt <= clk_cnt + 4'd1;
                    end else begin
                        clk_cnt <= 4'd9;            // 9th clock: acknowledge
                        if (ack_en) ack_low <= 1'b1;
                    end
                end
            end

            if (!sclk && sclk_d) begin              // SCL falling edge
                if (clk_cnt == 4'd9) begin          // acknowledge clock done
                    ack_low    <= 1'b0;
                    rx[nbytes] <= shreg;
                    nbytes     <= nbytes + 1;
                    clk_cnt    <= 4'd0;
                end
            end
        end
    end

    // =========================================================================
    //  Test
    // =========================================================================
    integer errors = 0;
    integer t_req  = 0;
    integer cycles = 0;

    task expect_byte;
        input integer idx;
        input [7:0]   val;
        begin
            if (rx[idx] !== val) begin
                $display("FAIL: byte %0d = %h, expected %h", idx, rx[idx], val);
                errors = errors + 1;
            end
        end
    endtask

    task run_write;
        input [15:0] a;
        input        mode;
        input [ 7:0] id;
        input [ 7:0] d;
        input [31:0] dly;
        input        ack_enable;
        begin
            addr = a; addr_mode = mode; dev_id = id; wr_data = d; dly_max = dly;
            ack_en = ack_enable;
            nbytes = 0; start_seen = 0; stop_seen = 0; scl_period = 0;
            @(posedge clk);
            t_req = $time;
            wr_req = 1'b1;
            @(posedge clk);
            wr_req = 1'b0;
            @(posedge wr_done);
            cycles = ($time - t_req) / 20;
            @(posedge clk);
        end
    endtask

    initial begin
        $display("=== SCCB write-path test ===");
        #200 rst_n = 1'b1;
        #200;

        // ---- 16-bit register address (OV5640), acknowledged ------------------
        run_write(16'h3008, 1'b1, 8'h78, 8'h82, 32'd0, 1'b1);
        if (nbytes != 4) begin
            $display("FAIL: 16-bit write sent %0d bytes, expected 4", nbytes);
            errors = errors + 1;
        end
        expect_byte(0, 8'h78);
        expect_byte(1, 8'h30);
        expect_byte(2, 8'h08);
        expect_byte(3, 8'h82);
        if (!start_seen || !stop_seen) begin
            $display("FAIL: 16-bit write without START (%b) or STOP (%b)", start_seen, stop_seen);
            errors = errors + 1;
        end
        if (nack !== 1'b0) begin
            $display("FAIL: 16-bit write reported a NACK");
            errors = errors + 1;
        end
        if (scl_period < 2400 || scl_period > 2560) begin
            $display("FAIL: SCL period %0d ns, expected ~2480 ns", scl_period);
            errors = errors + 1;
        end
        $display("16-bit write: %0d bytes, SCL period %0d ns, %0d clocks",
                 nbytes, scl_period, cycles);

        // ---- 8-bit register address (SiI9022A), acknowledged ----------------
        run_write(16'h000A, 1'b0, 8'h72, 8'h00, 32'd0, 1'b1);
        if (nbytes != 3) begin
            $display("FAIL: 8-bit write sent %0d bytes, expected 3", nbytes);
            errors = errors + 1;
        end
        expect_byte(0, 8'h72);
        expect_byte(1, 8'h0A);
        expect_byte(2, 8'h00);
        if (nack !== 1'b0) begin
            $display("FAIL: 8-bit write reported a NACK");
            errors = errors + 1;
        end
        $display("8-bit write:  %0d bytes, byte order checked", nbytes);

        // ---- not acknowledged: the sequence still completes, ack reports it --
        run_write(16'h3008, 1'b1, 8'h78, 8'h82, 32'd0, 1'b0);
        if (nack !== 1'b1) begin
            $display("FAIL: NACK was not reported");
            errors = errors + 1;
        end
        $display("NACK report:   ack=%b", nack);

        // ---- extra post-sequence delay --------------------------------------
        run_write(16'h3103, 1'b1, 8'h78, 8'h03, 32'd2000, 1'b1);
        if (cycles < 2000) begin
            $display("FAIL: dly_max=2000 finished in %0d clocks", cycles);
            errors = errors + 1;
        end
        $display("dly_max=2000:  sequence took %0d clocks", cycles);

        if (errors == 0) $display("TEST PASS");
        else             $display("TEST FAIL: %0d errors", errors);
        $finish;
    end

    // ---- temporary trace ----------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && (sclk !== sclk_d)) begin
            $display("t=%0t sclk %b->%b sdat=%b inframe=%b clkcnt=%0d shreg=%02h ack_low=%b | dut ctl=%0d bidx=%0d bitst=%0d ph=%0d bit=%0d",
                     $time, sclk_d, sclk, sdat, in_frame, clk_cnt, shreg, ack_low,
                     dut.st, dut.byte_idx,
                     dut.u_i2c_bit_shift.st, dut.u_i2c_bit_shift.phase,
                     dut.u_i2c_bit_shift.bit_cnt);
        end
        if (rst_n && (sdat !== sdat_d)) begin
            $display("t=%0t sdat %b->%b sclk=%b inframe=%b clkcnt=%0d | dut ctl=%0d bitst=%0d ph=%0d oe=%b o=%b",
                     $time, sdat_d, sdat, sclk, in_frame, clk_cnt,
                     dut.st, dut.u_i2c_bit_shift.st, dut.u_i2c_bit_shift.phase,
                     dut.u_i2c_bit_shift.sdat_oe, dut.u_i2c_bit_shift.sdat_o);
        end
    end

endmodule
