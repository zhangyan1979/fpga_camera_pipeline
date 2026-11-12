// =============================================================================
//  fb_ddr.v — DDR3 frame buffer engine (AXI4 master -> PS S_AXI_HP0)
//
//  Two 800x480 RGB565 frame stores live in DDR:
//
//      FB_BASE            buffer 0   768 000 bytes
//      FB_BASE + FB_BYTES buffer 1   768 000 bytes
//
//  WRITE  camera word stream -> DDR.  The camera fills buffer A while the panel
//         reads buffer B and vice versa.  Bit 64 of every FIFO word is the
//         "first word of a frame" tag inserted by ov5640_capture: when it reaches
//         the head of the FIFO the engine switches to the other buffer, resets
//         its burst counter and starts writing at offset 0, then writes exactly
//         BURSTS_PER_FRAME bursts (96 000 words).  Words beyond that, or words
//         arriving while frozen, are dropped.  Because the tag travels with the
//         data there is no clock-domain timing race at the frame boundary.
//
//  READ   DDR -> display word stream.  The panel asks for a reload once per
//         display frame at the start of vertical blanking (rel_req).  The engine
//         finishes the burst in flight, points the read address at the most
//         recently completed camera buffer, acknowledges (rel_ack) and waits for
//         the panel to drop rel_req - it is busy draining the stale prefetch at
//         that time - before refilling the display FIFO.  All of it happens in
//         the ~1.4 ms blanking interval, so the buffer switch is atomic and the
//         picture never tears.
//
//  Both engines share one AXI4 master and alternate 128-byte bursts (16 beats of
//  64 bits), the maximum AXI3 burst the HP port accepts.  AXI clock = 50 MHz
//  (PS FCLK0): 400 MB/s of headroom for the ~70 MB/s the video path needs.
// =============================================================================
`timescale 1ns / 1ps

module fb_ddr #(
    parameter [31:0]  FB_BASE    = 32'h0180_0000,
    parameter integer H_ACTIVE   = 800,
    parameter integer V_ACTIVE   = 480,
    parameter integer BEATS      = 16,          // 16 x 8 bytes = 128 bytes
    parameter integer CAM_LEVEL  = 24,          // start a write burst at this occupancy
    parameter integer DISP_LEVEL = 32           // keep the display FIFO at or below this
) (
    input  wire        clk,             // AXI clock, 50 MHz (PS FCLK0)
    input  wire        rst_n,           // asynchronous, active low
    // AXI4 master
    output wire [ 3:0] m_axi_awid,
    output reg  [31:0] m_axi_awaddr,
    output wire [ 7:0] m_axi_awlen,
    output wire [ 2:0] m_axi_awsize,
    output wire [ 1:0] m_axi_awburst,
    output wire [ 0:0] m_axi_awlock,
    output wire [ 3:0] m_axi_awcache,
    output wire [ 2:0] m_axi_awprot,
    output wire [ 3:0] m_axi_awqos,
    output wire [ 3:0] m_axi_awregion,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [ 7:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [ 1:0] m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [ 3:0] m_axi_arid,
    output reg  [31:0] m_axi_araddr,
    output wire [ 7:0] m_axi_arlen,
    output wire [ 2:0] m_axi_arsize,
    output wire [ 1:0] m_axi_arburst,
    output wire [ 0:0] m_axi_arlock,
    output wire [ 3:0] m_axi_arcache,
    output wire [ 2:0] m_axi_arprot,
    output wire [ 3:0] m_axi_arqos,
    output wire [ 3:0] m_axi_arregion,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire [ 1:0] m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output reg         m_axi_rready,
    // camera word stream: [64] = first word of a frame, [63:0] = 4 RGB565 pixels
    input  wire [64:0] cam_data,
    input  wire        cam_empty,
    output wire        cam_pop,
    input  wire [ 7:0] cam_level,
    // display word stream (write side of the display FIFO)
    output reg  [63:0] disp_data,
    output reg         disp_push,
    input  wire        disp_full,
    input  wire [ 7:0] disp_level,
    // display reload handshake (pixel clock domain)
    input  wire        rel_req,
    output reg         rel_ack,
    // operating mode
    input  wire        freeze,
    // status
    output reg         frame_seen,      // at least one camera frame is in DDR
    output reg  [15:0] cam_frames,      // camera frames seen (AXI clock domain)
    output reg  [ 7:0] axi_errs,        // saturating
    output reg         frame_new        // one-cycle pulse per camera frame
);

    // ---- frame geometry -----------------------------------------------------
    localparam integer WORDS_PER_FRAME  = (H_ACTIVE * V_ACTIVE) / 4;   // 96 000
    localparam integer BURSTS_PER_FRAME = WORDS_PER_FRAME / BEATS;     // 6 000
    localparam integer FB_BYTES         = H_ACTIVE * V_ACTIVE * 2;     // 768 000
    localparam [31:0]  FB_BASE_1        = FB_BASE + FB_BYTES;

    // ---- write engine -------------------------------------------------------
    localparam [2:0] W_IDLE = 3'd0,
                     W_TAG  = 3'd1,
                     W_ADDR = 3'd2,
                     W_DATA = 3'd3,
                     W_RESP = 3'd4;

    // ---- read engine --------------------------------------------------------
    localparam [1:0] R_IDLE = 2'd0,
                     R_ADDR = 2'd1,
                     R_DATA = 2'd2;

    // ---- shared bookkeeping -------------------------------------------------
    reg         wr_buf;             // buffer the camera is filling
    reg         rd_candidate;       // buffer that has just been completed
    reg         first_tag;          // no frame has been completed yet
    reg         wr_err_pulse, rd_err_pulse;
    wire [31:0] wr_base = wr_buf ? FB_BASE_1 : FB_BASE;

    // ---- AXI constant attributes --------------------------------------------
    assign m_axi_awid     = 4'd0;
    assign m_axi_awlen    = BEATS - 1;
    assign m_axi_awsize   = 3'd3;              // 8 bytes per beat
    assign m_axi_awburst  = 2'b01;             // INCR
    assign m_axi_awlock   = 1'b0;
    assign m_axi_awcache  = 4'b0010;
    assign m_axi_awprot   = 3'b000;
    assign m_axi_awqos    = 4'd0;
    assign m_axi_awregion = 4'd0;
    assign m_axi_wstrb    = 8'hFF;
    assign m_axi_bready   = 1'b1;

    assign m_axi_arid     = 4'd0;
    assign m_axi_arlen    = BEATS - 1;
    assign m_axi_arsize   = 3'd3;
    assign m_axi_arburst  = 2'b01;
    assign m_axi_arlock   = 1'b0;
    assign m_axi_arcache  = 4'b0010;
    assign m_axi_arprot   = 3'b000;
    assign m_axi_arqos    = 4'd0;
    assign m_axi_arregion = 4'd0;

    // =========================================================================
    //  Write engine: camera words -> DDR
    // =========================================================================
    reg [2:0]  w_state;
    reg [4:0]  w_beat;
    reg [12:0] w_bursts;
    reg        w_frame_done;

    wire cam_tag = cam_data[64];

    // a beat takes the word at the head of the show-ahead FIFO, so the data being
    // written is always the word being popped
    assign m_axi_wdata  = cam_data[63:0];
    assign m_axi_wvalid = (w_state == W_DATA) && !cam_empty;
    assign m_axi_wlast  = (w_state == W_DATA) && (w_beat == BEATS - 1);

    // a word is popped when it is written, or when it has to be thrown away
    assign cam_pop = ((w_state == W_DATA) && m_axi_wvalid && m_axi_wready) ||
                     ((w_state == W_IDLE) && !cam_empty &&
                      (freeze || (w_frame_done && !cam_tag)));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_state       <= W_IDLE;
            w_beat        <= 5'd0;
            w_bursts      <= 13'd0;
            w_frame_done  <= 1'b0;
            m_axi_awaddr  <= FB_BASE;
            m_axi_awvalid <= 1'b0;
            cam_frames    <= 16'd0;
            frame_new     <= 1'b0;
            frame_seen    <= 1'b0;
            wr_buf        <= 1'b0;
            rd_candidate  <= 1'b0;
            first_tag     <= 1'b1;
            wr_err_pulse  <= 1'b0;
        end else begin
            frame_new    <= 1'b0;
            wr_err_pulse <= 1'b0;

            case (w_state)
            W_IDLE: begin
                if (cam_empty) begin
                    // nothing to do
                end else if (freeze) begin
                    // frozen: throw the stream away and do not switch buffers, so
                    // the frame the panel is reading stays untouched
                    w_frame_done <= 1'b1;      // after unfreezing, wait for a tag
                end else if (cam_tag) begin
                    // a new frame starts here.  The first tag only arms the engine
                    // (frame 0 still goes to buffer 0); from the second tag on, the
                    // buffer that just finished becomes readable.
                    if (!first_tag) begin
                        rd_candidate <= wr_buf;
                        wr_buf       <= ~wr_buf;
                        frame_seen   <= 1'b1;
                    end else begin
                        first_tag <= 1'b0;
                    end
                    w_bursts     <= 13'd0;
                    w_frame_done <= 1'b0;
                    cam_frames   <= cam_frames + 16'd1;
                    frame_new    <= 1'b1;
                    w_state      <= W_TAG;
                end else if (!w_frame_done && cam_level >= CAM_LEVEL) begin
                    m_axi_awaddr  <= wr_base + ({{19{1'b0}}, w_bursts} << 7);
                    m_axi_awvalid <= 1'b1;
                    w_beat        <= 5'd0;
                    w_state       <= W_ADDR;
                end
            end

            W_TAG: begin
                // wr_base has settled; the tagged word is still at the FIFO head
                if (freeze) begin
                    w_state <= W_IDLE;         // drain instead of starting a frame
                end else if (cam_level >= CAM_LEVEL) begin
                    m_axi_awaddr  <= wr_base + ({{19{1'b0}}, w_bursts} << 7);
                    m_axi_awvalid <= 1'b1;
                    w_beat        <= 5'd0;
                    w_state       <= W_ADDR;
                end
            end

            W_ADDR: begin
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    w_state       <= W_DATA;
                end
            end

            W_DATA: begin
                if (m_axi_wvalid && m_axi_wready) begin
                    if (w_beat == BEATS - 1) begin
                        w_beat  <= 5'd0;
                        w_state <= W_RESP;
                    end else begin
                        w_beat <= w_beat + 5'd1;
                    end
                end
            end

            W_RESP: begin
                if (m_axi_bvalid) begin
                    if (m_axi_bresp != 2'b00) wr_err_pulse <= 1'b1;
                    if (w_bursts == BURSTS_PER_FRAME - 1) begin
                        w_frame_done <= 1'b1;
                        w_state      <= W_IDLE;
                    end else begin
                        w_bursts <= w_bursts + 13'd1;
                        w_state  <= W_IDLE;
                    end
                end
            end

            default: w_state <= W_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Read engine: DDR -> display words
    // =========================================================================
    reg [1:0]  r_state;
    reg [4:0]  r_beat;
    reg [12:0] r_bursts;
    reg [31:0] rd_base;
    reg        rel_s1, rel_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rel_s1 <= 1'b0;
            rel_s2 <= 1'b0;
        end else begin
            rel_s1 <= rel_req;
            rel_s2 <= rel_s1;
        end
    end

    // the reload is serviced while rel_req is high; new bursts only start after
    // the panel has finished draining and dropped rel_req
    wire rel_pending = rel_s2 && !rel_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state       <= R_IDLE;
            r_beat        <= 5'd0;
            r_bursts      <= 13'd0;
            rd_base       <= FB_BASE;
            m_axi_araddr  <= FB_BASE;
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;
            disp_data     <= 64'd0;
            disp_push     <= 1'b0;
            rel_ack       <= 1'b0;
            rd_err_pulse  <= 1'b0;
        end else begin
            disp_push    <= 1'b0;
            rd_err_pulse <= 1'b0;

            if (!rel_s2) rel_ack <= 1'b0;

            case (r_state)
            R_IDLE: begin
                m_axi_rready <= 1'b0;
                if (rel_pending) begin
                    // atomic retarget - no burst is in flight in this state
                    rd_base  <= rd_candidate ? FB_BASE_1 : FB_BASE;
                    r_bursts <= 13'd0;
                    rel_ack  <= 1'b1;
                end else if (!rel_s2 && frame_seen &&
                             r_bursts != BURSTS_PER_FRAME &&
                             disp_level <= DISP_LEVEL - BEATS) begin
                    m_axi_araddr  <= rd_base + ({{19{1'b0}}, r_bursts} << 7);
                    m_axi_arvalid <= 1'b1;
                    r_beat        <= 5'd0;
                    r_state       <= R_ADDR;
                end
            end

            R_ADDR: begin
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b1;
                    r_state       <= R_DATA;
                end
            end

            R_DATA: begin
                // a pending reload finishes the burst and discards the data
                m_axi_rready <= rel_pending ? 1'b1 : ~disp_full;
                if (m_axi_rvalid && m_axi_rready) begin
                    if (!rel_pending) begin
                        disp_data <= m_axi_rdata;
                        disp_push <= 1'b1;
                        if (m_axi_rresp != 2'b00) rd_err_pulse <= 1'b1;
                    end
                    if (m_axi_rlast) begin
                        m_axi_rready <= 1'b0;
                        r_bursts     <= r_bursts + 13'd1;
                        r_state      <= R_IDLE;
                    end
                end
            end

            default: r_state <= R_IDLE;
            endcase
        end
    end

    // both error pulses fold into one saturating counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            axi_errs <= 8'd0;
        else if ((wr_err_pulse || rd_err_pulse) && axi_errs != 8'hFF)
            axi_errs <= axi_errs + 8'd1;
    end

endmodule
