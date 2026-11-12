// =============================================================================
//  tb_pipeline.v — end-to-end self-checking testbench for the video path
//
//      camera model --> ov5640_capture --> FIFO --> fb_ddr --> FIFO
//                        --> lcd_display --> scoreboard
//
//  An AXI4 slave model holds the two frame buffers, so the real address
//  generation, burst handling, double buffering and the reload handshake are
//  all exercised.  The geometry is reduced (64x32) purely for simulation speed;
//  every module is parameterised, and the full-size timing is checked
//  separately in tb_lcd_timing.v.
//
//  Each camera frame carries a frame id inside its pixel pattern.  For every
//  displayed frame the scoreboard collects the frame ids that are consistent
//  with *all* the pixels it saw: exactly one must survive, which proves that
//  the displayed frame is one whole camera frame (no tearing, no shift).
// =============================================================================
`timescale 1ns / 1ps

module tb_pipeline;

    localparam integer H = 64;
    localparam integer V = 32;

    // panel timing (small, same structure as 1056x526)
    localparam integer HS = 8, HB = 8, HF = 8;
    localparam integer VS = 1, VB = 2, VF = 1;

    // camera model timing
    localparam integer CH_BLANK = 32;
    localparam integer CV_BLANK = 20;
    localparam integer VS_W     = 2;

    localparam [31:0] FB_BASE = 32'h0180_0000;
    localparam integer FB_BYTES  = H * V * 2;           // 4096
    localparam integer MEM_WORDS = (2 * FB_BYTES) / 8;  // 1024

    // ---- clocks -------------------------------------------------------------
    reg clk50 = 1'b0, pclk = 1'b0, pix = 1'b0;
    always #10   clk50 = ~clk50;      // 50 MHz
    always #12   pclk  = ~pclk;       // 41.7 MHz
    always #15   pix   = ~pix;        // 33.3 MHz

    reg aresetn = 1'b0;
    reg freeze  = 1'b0;

    initial begin
        #200      aresetn = 1'b1;
        #1_800_000 freeze = 1'b1;      // freeze for half a millisecond
        #2_300_000 freeze = 1'b0;
    end

    // AXI master wires of the DUT (declared early so the slave model can use them)
    wire [ 3:0] dut_awid;
    wire [31:0] dut_awaddr;
    wire [ 7:0] dut_awlen;
    wire [ 2:0] dut_awsize;
    wire [ 1:0] dut_awburst;
    wire [ 0:0] dut_awlock;
    wire [ 3:0] dut_awcache;
    wire [ 2:0] dut_awprot;
    wire [ 3:0] dut_awqos;
    wire [ 3:0] dut_awregion;
    wire        dut_awvalid;
    wire [63:0] dut_wdata;
    wire [ 7:0] dut_wstrb;
    wire        dut_wlast, dut_wvalid;
    wire        dut_bready;
    wire [ 3:0] dut_arid;
    wire [31:0] dut_araddr;
    wire [ 7:0] dut_arlen;
    wire [ 2:0] dut_arsize;
    wire [ 1:0] dut_arburst;
    wire [ 0:0] dut_arlock;
    wire [ 3:0] dut_arcache;
    wire [ 2:0] dut_arprot;
    wire [ 3:0] dut_arqos;
    wire [ 3:0] dut_arregion;
    wire        dut_arvalid;
    wire        dut_rready;

    // =========================================================================
    //  Camera model: DVP with realistic blanking, RGB565, 2 bytes per pixel
    // =========================================================================
    reg        cam_vsync = 1'b0;
    reg        cam_href  = 1'b0;
    reg  [7:0] cam_data  = 8'h00;

    reg [4:0] cam_frm  = 5'd0;
    reg [5:0] cam_line = 6'd0;
    reg [7:0] cam_col  = 8'd0;
    reg [5:0] cam_vb   = 6'd0;
    reg [3:0] cam_ph   = 4'd0;

    wire [5:0]  model_x  = cam_col[6:1];
    wire [15:0] model_px = {model_x, cam_line[4:0], cam_frm};

    always @(posedge pclk or negedge aresetn) begin
        if (!aresetn) begin
            cam_vsync <= 1'b0;
            cam_href  <= 1'b0;
            cam_data  <= 8'h00;
            cam_frm   <= 5'd0;
            cam_line  <= 6'd0;
            cam_col   <= 8'd0;
            cam_vb    <= 6'd0;
            cam_ph    <= 4'd0;
        end else begin
            case (cam_ph)
            4'd0: begin                          // vsync pulse
                cam_vsync <= 1'b1;
                cam_href  <= 1'b0;
                if (cam_col == VS_W - 1) begin
                    cam_col   <= 8'd0;
                    cam_line  <= 6'd0;
                    cam_ph    <= 4'd1;
                    cam_vsync <= 1'b0;
                end else begin
                    cam_col <= cam_col + 8'd1;
                end
            end

            4'd1: begin                          // active lines
                cam_vsync <= 1'b0;
                if (cam_col < 2*H) begin
                    cam_href <= 1'b1;
                    cam_data <= cam_col[0] ? model_px[7:0] : model_px[15:8];
                end else begin
                    cam_href <= 1'b0;
                end

                if (cam_col == 2*H + CH_BLANK - 1) begin
                    cam_col <= 8'd0;
                    if (cam_line == V - 1) begin
                        cam_line <= 6'd0;
                        cam_ph   <= 4'd2;
                    end else begin
                        cam_line <= cam_line + 6'd1;
                    end
                end else begin
                    cam_col <= cam_col + 8'd1;
                end
            end

            default: begin                       // vertical blank
                cam_vsync <= 1'b0;
                cam_href  <= 1'b0;
                if (cam_vb == CV_BLANK - 1) begin
                    cam_vb  <= 6'd0;
                    cam_col <= 8'd0;
                    cam_frm <= cam_frm + 5'd1;
                    cam_ph  <= 4'd0;
                end else begin
                    cam_vb <= cam_vb + 6'd1;
                end
            end
            endcase
        end
    end

    // =========================================================================
    //  AXI4 slave model (two frame buffers)
    // =========================================================================
    reg [63:0] mem [0:MEM_WORDS-1];

    integer camw = 0;
    always @(posedge pclk) if (u_cap.word_valid) begin
        if (camw < 4) $display("  camstream word %0d = %h", camw, u_cap.word);
        camw = camw + 1;
    end
    always @(posedge pclk) if (u_cap.vs_rise) $display("  vs_rise: camw so far=%0d", camw);

    integer i;
    initial for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 64'hDEAD_0000_0000_0000 | i;

    reg        aw_act  = 1'b0;
    reg [31:0] aw_addr = 32'd0;
    reg [7:0]  aw_len  = 8'd0;
    reg [7:0]  w_cnt   = 8'd0;
    reg        bvalid  = 1'b0;
    reg        ar_act  = 1'b0;
    reg [31:0] ar_addr = 32'd0;
    reg [7:0]  ar_len  = 8'd0;
    reg [7:0]  r_cnt   = 8'd0;
    reg [2:0]  r_wait  = 3'd0;
    reg        rvalid  = 1'b0;

    wire awready = ~aw_act;
    wire wready  = aw_act;
    wire arready = ~ar_act;
    wire rready  = dut_rready;
    wire [63:0] rdata = (ar_addr >= FB_BASE) ?
                        mem[(ar_addr - FB_BASE) / 8 + r_cnt] : 64'd0;
    wire        rlast = (r_cnt == ar_len);

    integer wr_words = 0;
    integer rd_words = 0;

    always @(posedge clk50 or negedge aresetn) begin
        if (!aresetn) begin
            aw_act <= 1'b0;
            bvalid <= 1'b0;
            ar_act <= 1'b0;
            rvalid <= 1'b0;
            w_cnt  <= 8'd0;
            r_cnt  <= 8'd0;
            r_wait <= 3'd0;
        end else begin
            if (dut_awvalid && awready) begin
                aw_act  <= 1'b1;
                aw_addr <= dut_awaddr;
                aw_len  <= dut_awlen;
                w_cnt   <= 8'd0;
            end

            if (dut_wvalid && wready) begin
                mem[(aw_addr - FB_BASE) / 8 + w_cnt] <= dut_wdata;
                wr_words <= wr_words + 1;
                if (w_cnt == aw_len) begin
                    aw_act <= 1'b0;
                    bvalid <= 1'b1;
                end else begin
                    w_cnt <= w_cnt + 8'd1;
                end
            end

            if (bvalid && dut_bready) bvalid <= 1'b0;

            if (dut_arvalid && arready) begin
                ar_act  <= 1'b1;
                ar_addr <= dut_araddr;
                ar_len  <= dut_arlen;
                r_cnt   <= 8'd0;
                r_wait  <= 3'd3;
                rvalid  <= 1'b0;
            end

            if (ar_act && r_wait != 0)
                r_wait <= r_wait - 3'd1;
            else if (ar_act)
                rvalid <= 1'b1;

            if (rvalid && rready) begin
                rd_words <= rd_words + 1;
                if (rlast) begin
                    ar_act <= 1'b0;
                    rvalid <= 1'b0;
                end else begin
                    r_cnt <= r_cnt + 8'd1;
                end
            end
        end
    end

    // =========================================================================
    //  DUT: capture -> FIFO -> fb_ddr -> FIFO -> lcd_display
    // =========================================================================
    wire [63:0] cam_word;
    wire        cam_word_valid;
    wire        cam_word_first;

    ov5640_capture #(.H_ACTIVE(H), .V_ACTIVE(V)) u_cap (
        .pclk      (pclk),
        .rst_n     (aresetn),
        .vsync     (cam_vsync),
        .href      (cam_href),
        .data      (cam_data),
        .word      (cam_word),
        .word_valid(cam_word_valid),
        .word_first(cam_word_first)
    );

    wire [64:0] camf_data;
    wire        camf_empty, camf_pop;
    wire [7:0]  camf_level;

    afifo #(.AW(7), .W(65)) u_cfifo (
        .wr_clk  (pclk),
        .wr_rst_n(aresetn),
        .wr_data ({cam_word_first, cam_word}),
        .wr_en   (cam_word_valid),
        .wr_full (),
        .wr_level(),
        .rd_clk  (clk50),
        .rd_rst_n(aresetn),
        .rd_data (camf_data),
        .rd_en   (camf_pop),
        .rd_empty(camf_empty),
        .rd_level(camf_level)
    );

    wire [63:0] disf_data;
    wire        disf_push, disf_full;
    wire [7:0]  disf_level;
    wire        rel_ack, frame_seen, frame_new;
    wire [15:0] cam_frames_axi;
    wire [7:0]  axi_errs;
    wire        rel_req;



    fb_ddr #(
        .FB_BASE    (FB_BASE),
        .H_ACTIVE   (H),
        .V_ACTIVE   (V),
        .BEATS      (16),
        .CAM_LEVEL  (24),
        .DISP_LEVEL (32)
    ) u_fb (
        .clk           (clk50),
        .rst_n         (aresetn),
        .m_axi_awid    (dut_awid),
        .m_axi_awaddr  (dut_awaddr),
        .m_axi_awlen   (dut_awlen),
        .m_axi_awsize  (dut_awsize),
        .m_axi_awburst (dut_awburst),
        .m_axi_awlock  (dut_awlock),
        .m_axi_awcache (dut_awcache),
        .m_axi_awprot  (dut_awprot),
        .m_axi_awqos   (dut_awqos),
        .m_axi_awregion(dut_awregion),
        .m_axi_awvalid (dut_awvalid),
        .m_axi_awready (awready),
        .m_axi_wdata   (dut_wdata),
        .m_axi_wstrb   (dut_wstrb),
        .m_axi_wlast   (dut_wlast),
        .m_axi_wvalid  (dut_wvalid),
        .m_axi_wready  (wready),
        .m_axi_bresp   (2'b00),
        .m_axi_bvalid  (bvalid),
        .m_axi_bready  (dut_bready),
        .m_axi_arid    (dut_arid),
        .m_axi_araddr  (dut_araddr),
        .m_axi_arlen   (dut_arlen),
        .m_axi_arsize  (dut_arsize),
        .m_axi_arburst (dut_arburst),
        .m_axi_arlock  (dut_arlock),
        .m_axi_arcache (dut_arcache),
        .m_axi_arprot  (dut_arprot),
        .m_axi_arqos   (dut_arqos),
        .m_axi_arregion(dut_arregion),
        .m_axi_arvalid (dut_arvalid),
        .m_axi_arready (arready),
        .m_axi_rdata   (rdata),
        .m_axi_rresp   (2'b00),
        .m_axi_rlast   (rlast),
        .m_axi_rvalid  (rvalid),
        .m_axi_rready  (dut_rready),
        .cam_data      (camf_data),
        .cam_empty     (camf_empty),
        .cam_pop       (camf_pop),
        .cam_level     (camf_level),
        .disp_data     (disf_data),
        .disp_push     (disf_push),
        .disp_full     (disf_full),
        .disp_level    (disf_level),
        .rel_req       (rel_req),
        .rel_ack       (rel_ack),
        .freeze        (freeze),
        .frame_seen    (frame_seen),
        .cam_frames    (cam_frames_axi),
        .axi_errs      (axi_errs),
        .frame_new     (frame_new)
    );

    wire [63:0] pixf_data;
    wire        pixf_empty, pixf_pop;

    afifo #(.AW(7), .W(64)) u_dfifo (
        .wr_clk  (clk50),
        .wr_rst_n(aresetn),
        .wr_data (disf_data),
        .wr_en   (disf_push),
        .wr_full (disf_full),
        .wr_level(disf_level),
        .rd_clk  (pix),
        .rd_rst_n(aresetn),
        .rd_data (pixf_data),
        .rd_en   (pixf_pop),
        .rd_empty(pixf_empty),
        .rd_level()
    );

    reg [1:0] fseen_sync;
    always @(posedge pix or negedge aresetn) begin
        if (!aresetn) fseen_sync <= 2'b00;
        else          fseen_sync <= {fseen_sync[0], frame_seen};
    end

    wire        lcd_hsync, lcd_vsync, lcd_de;
    wire [15:0] lcd_rgb;
    wire [15:0] disp_frames;
    wire [7:0]  disp_underruns;

    lcd_display #(
        .H_ACTIVE(H), .H_SYNC(HS), .H_BP(HB), .H_FP(HF),
        .V_ACTIVE(V), .V_SYNC(VS), .V_BP(VB), .V_FP(VF)
    ) u_lcd (
        .pix_clk     (pix),
        .rst_n       (aresetn),
        .fifo_data   (pixf_data),
        .fifo_empty  (pixf_empty),
        .fifo_pop    (pixf_pop),
        .rel_req     (rel_req),
        .rel_ack     (rel_ack),
        .video_valid (fseen_sync[1]),
        .test_pattern(1'b0),
        .lcd_hsync   (lcd_hsync),
        .lcd_vsync   (lcd_vsync),
        .lcd_de      (lcd_de),
        .lcd_rgb     (lcd_rgb),
        .frames      (disp_frames),
        .underruns   (disp_underruns)
    );

    // =========================================================================
    //  Scoreboard: every displayed frame must be one whole camera frame
    // =========================================================================
    integer npx       = 0;
    integer good_frames = 0;
    integer bad_frames  = 0;
    integer scored_px   = 0;
    reg [31:0] cand     = 32'hFFFF_FFFF;
    reg        vs_d     = 1'b0;
    reg        score_en = 1'b0;
    integer    f, k, nf;
    integer    dbg_px = 0;
    integer    frozen_id = -1;
    integer    freeze_checked = 0;
    integer    frozen_changes = 0;
    reg        freeze_d = 1'b0;
    integer    f_dbg = 0;

    always @(posedge pix or negedge aresetn) begin
        if (!aresetn) begin
            npx      <= 0;
            cand     <= 32'hFFFF_FFFF;
            vs_d     <= 1'b0;
            score_en <= 1'b0;
        end else begin
            vs_d <= lcd_vsync;

            if (lcd_de) begin
                if (dbg_px < 12 && score_en) begin
                    dbg_px <= dbg_px + 1;
                    $display("  px[%0d] rgb=%h expect f00=%h f01=%h", npx, lcd_rgb,
                             {npx[5:0], npx[10:6], 5'd0}, {npx[5:0], npx[10:6], 5'd1});
                end
                npx <= npx + 1;
                if (score_en) begin
                    for (f = 0; f < 32; f = f + 1)
                        if ({npx[5:0], npx[10:6], f[4:0]} != lcd_rgb)
                            cand[f] <= 1'b0;
                    scored_px <= scored_px + 1;
                end
            end

            // freeze release clears the bookkeeping
            freeze_d <= freeze;
            if (freeze_d && !freeze) begin
                frozen_id = -1;
                frozen_changes = 0;
            end

            if (vs_d && !lcd_vsync) begin      // start of a new display frame
                if (score_en) begin
                    if (npx != H * V) begin
                        $display("FAIL: frame carried %0d pixels, expected %0d", npx, H * V);
                        bad_frames <= bad_frames + 1;
                    end else begin
                        k = 0;
                        nf = -1;
                        for (f = 0; f < 32; f = f + 1)
                            if (cand[f]) begin
                                k = k + 1;
                                nf = f;
                            end
                        if (k == 1) begin
                            good_frames <= good_frames + 1;
                            if (freeze) begin
                                if (frozen_id < 0) begin
                                    frozen_id = nf;         // first frame after the request
                                end else if (nf != frozen_id) begin
                                    if (frozen_changes == 0) begin
                                        frozen_id = nf;     // one switch is allowed: the
                                        frozen_changes = 1; // reload already in flight
                                    end else begin
                                        $display("FAIL: frozen frame changed %0d -> %0d", frozen_id, nf);
                                        bad_frames <= bad_frames + 1;
                                    end
                                end
                                freeze_checked = freeze_checked + 1;
                            end
                        end else begin
                            $display("FAIL t=%0t: %0d candidates survived; fseen=%b rel=%b rd_cand=%b wr_buf=%b r_bursts=%0d", $time, k, frame_seen, rel_ack, u_fb.rd_candidate, u_fb.wr_buf, u_fb.r_bursts);
                            bad_frames <= bad_frames + 1;
                        end
                    end
                end
                npx      <= 0;
                cand     <= 32'hFFFF_FFFF;
                score_en <= fseen_sync[1];
                dbg_px   <= 0;
            end
        end
    end

    // =========================================================================
    //  Run
    // =========================================================================
    initial begin
        $display("=== video pipeline testbench (H=%0d V=%0d) ===", H, V);
        #3_000_000;                        // ~15 camera frames
        $display("capture: x=%0d y=%0d words=%0d", u_cap.x_cnt, u_cap.y_cnt, camw);
        $display("DDR buffer 0: %h %h %h %h", mem[0], mem[1], mem[2], mem[3]);
        $display("DDR buffer 1: %h %h %h %h", mem[FB_BYTES/8], mem[FB_BYTES/8+1],
                 mem[FB_BYTES/8+2], mem[FB_BYTES/8+3]);
        $display("displayed frames=%0d scored pixels=%0d good=%0d bad=%0d",
                 disp_frames, scored_px, good_frames, bad_frames);
        $display("ddr words: written=%0d read=%0d", wr_words, rd_words);
        $display("underrun frames=%0d axi errors=%0d freeze checks=%0d", disp_underruns, axi_errs, freeze_checked);
        if (bad_frames == 0 && good_frames >= 5 && disp_underruns == 0 && freeze_checked >= 2 &&
            axi_errs == 0 && scored_px >= good_frames * H * V)
            $display("TEST PASS");
        else
            $display("TEST FAIL");
        $finish;
    end

endmodule
