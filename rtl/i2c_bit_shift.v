// =============================================================================
//  i2c_bit_shift.v — SCCB/I2C byte engine (open-drain, 4-phase bit timing)
//
//  Handles one byte at a time: START, eight data bits, the acknowledge bit and
//  optionally a STOP.  The bit period is four quarter phases of SCL_DIV+1 clocks
//  each (data setup, SCL rise, SCL high, SCL fall), so SCL runs at
//
//      SYS_CLOCK / (4 * (SCL_DIV + 1))  =  ~400 kHz at 50 MHz
//
//  cmd bits select START / WRITE / STOP for the byte; ack_o is the sensor's
//  acknowledge for the byte just sent (1 = NACK).  Only the master-write
//  direction is implemented - the OV5640 and the SiI9022A are never read here.
// =============================================================================
`timescale 1ns / 1ps

module i2c_bit_shift #(
    parameter integer SYS_CLOCK = 50_000_000,
    parameter integer SCL_CLOCK = 400_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [5:0] cmd,          // START / WRITE / STOP for this byte
    input  wire       go,           // one-cycle request, taken while idle
    input  wire [7:0] tx_data,
    output reg        trans_done,   // one-cycle pulse: byte finished
    output reg        ack_o,        // 1 = the target NACKed the byte
    output wire       i2c_sclk,
    inout  wire       i2c_sdat
);

    localparam [5:0] CMD_WR  = 6'b000001,
                     CMD_STA = 6'b000010,
                     CMD_STO = 6'b001000;

    localparam integer SCL_DIV = SYS_CLOCK / SCL_CLOCK / 4 - 1;
    localparam integer DIV_W   = $clog2(SCL_DIV + 1);

    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_WRITE = 3'd2,
                     S_ACK   = 3'd3,
                     S_STOP  = 3'd4;

    reg [2:0]       st;
    reg [1:0]       phase;          // quarter phase of the SCL period
    reg [DIV_W-1:0] div_cnt;
    reg [2:0]       bit_cnt;
    reg             sdat_o;
    reg             sdat_oe;
    reg             sclk;

    assign i2c_sclk = sclk;
    assign i2c_sdat = sdat_oe ? sdat_o : 1'bz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            phase      <= 2'd0;
            div_cnt    <= {DIV_W{1'b0}};
            bit_cnt    <= 3'd0;
            sdat_o     <= 1'b1;
            sdat_oe    <= 1'b1;
            sclk       <= 1'b1;
            ack_o      <= 1'b0;
            trans_done <= 1'b0;
        end else if (st == S_IDLE) begin
            // bus free: SDA released.  SCL is left where the last byte put it:
            // high after a STOP, low between the bytes of one write (raising it
            // here would add a spurious clock between bytes).
            trans_done <= 1'b0;
            sdat_oe    <= 1'b1;
            if (go) begin
                phase   <= 2'd0;
                div_cnt <= {DIV_W{1'b0}};
                bit_cnt <= 3'd0;
                st      <= (cmd & CMD_STA) ? S_START : S_WRITE;
            end
        end else if (div_cnt == SCL_DIV) begin
            div_cnt <= {DIV_W{1'b0}};
            phase   <= phase + 2'd1;
            case (st)
            S_START: begin                  // START: SDA falls while SCL is high
                case (phase)
                2'd0: begin sdat_o <= 1'b1; sdat_oe <= 1'b1; end
                2'd1: sclk <= 1'b1;
                2'd2: sdat_o <= 1'b0;
                2'd3: begin
                    sclk    <= 1'b0;
                    bit_cnt <= 3'd0;
                    st      <= S_WRITE;
                end
                endcase
            end

            S_WRITE: begin                  // data valid while SCL is low
                case (phase)
                2'd0: begin
                    sdat_o  <= tx_data[3'd7 - bit_cnt];
                    sdat_oe <= 1'b1;
                    sclk    <= 1'b0;
                end
                2'd1: sclk <= 1'b1;
                2'd2: sclk <= 1'b1;
                2'd3: begin
                    sclk <= 1'b0;
                    if (bit_cnt == 3'd7) st <= S_ACK;
                    else                 bit_cnt <= bit_cnt + 3'd1;
                end
                endcase
            end

            S_ACK: begin                    // release SDA, sample it on the 9th clock
                case (phase)
                2'd0: begin sdat_oe <= 1'b0; sclk <= 1'b0; end
                2'd1: sclk <= 1'b1;
                2'd2: begin ack_o <= i2c_sdat; sclk <= 1'b1; end
                2'd3: begin
                    sclk <= 1'b0;
                    if (cmd & CMD_STO) begin
                        st <= S_STOP;
                    end else begin
                        trans_done <= 1'b1;
                        st         <= S_IDLE;
                    end
                end
                endcase
            end

            S_STOP: begin                   // STOP: SDA rises while SCL is high
                case (phase)
                2'd0: begin sdat_o <= 1'b0; sdat_oe <= 1'b1; end
                2'd1: sclk <= 1'b1;
                2'd2: sdat_o <= 1'b1;
                2'd3: begin
                    sclk       <= 1'b1;
                    trans_done <= 1'b1;
                    st         <= S_IDLE;
                end
                endcase
            end

            default: st <= S_IDLE;
            endcase
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
    end

endmodule
