// =============================================================================
//  ov5640_top.v — ACZ702 camera pipeline: OV5640 -> DDR3 -> TFT/HDMI
//
//      OV5640 --DVP--> capture --> 64-bit FIFO --> DDR3 (2 frame buffers)
//                                                      |   AXI4 master -> HP0
//      panel  <-- 33.3 MHz timing <-- FIFO <-- read engine
//
//  The PS is only needed for its DDR3 controller and its clocks: FCLK0 = 50 MHz
//  feeds the whole AXI side, and two AXI GPIOs carry a 32-bit control word out
//  and two 32-bit status words back, so the bare-metal application can report
//  frame rates and switch modes over the serial console.
//
//  Control word (PS -> PL)                  Status words (PL -> PS)
//    ctrl[0]      test pattern              status_cam[0]     camera init done
//    ctrl[1]      freeze frame              status_cam[1]     camera streaming
//    ctrl[7:2]    reserved                  status_cam[15:8]  camera fps
//    ctrl[15:8]   backlight duty 0..255     status_cam[31:16] camera frames
//    ctrl[31:16]  reserved
//                                           status_disp[15:0]  panel frames
//                                           status_disp[23:16] frames with a
//                                                              missing pixel
//                                           status_disp[31:24] AXI error count
//
//  The 16-bit panel value is {R[4:0], G[5:0], B[4:0]} straight onto the TFT RGB
//  pins, which the SiI9022A (same pins) also converts to HDMI.
// =============================================================================
`timescale 1ns / 1ps

module ov5640_top #(
    parameter integer H_ACTIVE = 800,
    parameter integer V_ACTIVE = 480,
    parameter integer HDMI_INIT = 1,
    parameter [31:0]  FB_BASE   = 32'h0180_0000
) (
    // ---- PS side ------------------------------------------------------------
    input  wire        clk50,           // PS FCLK0, 50 MHz
    input  wire        aresetn,         // PS FCLK_RESET0_N
    input  wire [31:0] ctrl,            // AXI GPIO from the PS
    output wire [31:0] status_cam,
    output wire [31:0] status_disp,
    // ---- AXI4 master -> S_AXI_HP0 -------------------------------------------
    output wire [ 3:0] m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [ 7:0] m_axi_awlen,
    output wire [ 2:0] m_axi_awsize,
    output wire [ 1:0] m_axi_awburst,
    output wire [ 0:0] m_axi_awlock,
    output wire [ 3:0] m_axi_awcache,
    output wire [ 2:0] m_axi_awprot,
    output wire [ 3:0] m_axi_awqos,
    output wire [ 3:0] m_axi_awregion,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [ 7:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [ 3:0] m_axi_bid,
    input  wire [ 1:0] m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [ 3:0] m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [ 7:0] m_axi_arlen,
    output wire [ 2:0] m_axi_arsize,
    output wire [ 1:0] m_axi_arburst,
    output wire [ 0:0] m_axi_arlock,
    output wire [ 3:0] m_axi_arcache,
    output wire [ 2:0] m_axi_arprot,
    output wire [ 3:0] m_axi_arqos,
    output wire [ 3:0] m_axi_arregion,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [ 3:0] m_axi_rid,
    input  wire [63:0] m_axi_rdata,
    input  wire [ 1:0] m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    // ---- camera (OV5640 DVP header) -----------------------------------------
    output wire        camera_sclk,
    inout  wire        camera_sdat,
    output wire        camera_xclk,
    input  wire        camera_pclk,
    input  wire        camera_href,
    input  wire        camera_vsync,
    input  wire [7:0]  camera_data,
    // ---- TFT / HDMI RGB interface -------------------------------------------
    output wire [15:0] lcd_rgb,
    output wire        lcd_hsync,
    output wire        lcd_vsync,
    output wire        lcd_de,
    output wire        lcd_pclk,
    output wire        lcd_bl,
    // ---- HDMI transmitter I2C (PL I2C: T10 / R14) ---------------------------
    output wire        hdmi_sclk,
    inout  wire        hdmi_sdat,
    // ---- board --------------------------------------------------------------
    output wire        led
);

    localparam integer FB_BYTES = H_ACTIVE * V_ACTIVE * 2;

    // =========================================================================
    //  Clocks and resets
    // =========================================================================
    reg [1:0] arst_sync;
    always @(posedge clk50 or negedge aresetn) begin
        if (!aresetn) arst_sync <= 2'b00;
        else          arst_sync <= {arst_sync[0], 1'b1};
    end

    wire rst50_n = arst_sync[1];

    (* keep = "true" *) wire pll_locked;
    wire clk_pix;
    wire clk_cam;

    clk_gen u_clk (
        .clk50  (clk50),
        .reset  (~rst50_n),
        .clk_pix(clk_pix),
        .clk_cam(clk_cam),
        .locked (pll_locked)
    );

    wire sys_rst_n = rst50_n & pll_locked;

    // pixel-clock domain reset
    reg [2:0] prst;
    always @(posedge clk_pix or negedge aresetn) begin
        if (!aresetn) prst <= 3'b000;
        else          prst <= {prst[1:0], 1'b1};
    end
    wire pix_rst_n = prst[2] & pll_locked;

    // camera PCLK domain reset (the camera only produces PCLK once it is
    // powered and configured, so this simply follows the board reset)
    wire cam_pclk_buf;

    BUFG u_bufg_pclk (
        .I(camera_pclk),
        .O(cam_pclk_buf)
    );

    reg [2:0] crst;
    always @(posedge cam_pclk_buf or negedge aresetn) begin
        if (!aresetn) crst <= 3'b000;
        else          crst <= {crst[1:0], 1'b1};
    end
    wire cam_rst_n = crst[2];

    assign camera_xclk = clk_cam;

    // =========================================================================
    //  OV5640 register initialisation (I2C on the camera header, PL bit-banged)
    // =========================================================================
    wire cam_init_done;

    camera_init #(
        .CAMERA_TYPE    ("ov5640"),
        .IMAGE_TYPE     (0),            // 0 = RGB, 1 = JPEG
        .IMAGE_WIDTH    (H_ACTIVE),
        .IMAGE_HEIGHT   (V_ACTIVE),
        .IMAGE_FLIP_EN  (0),
        .IMAGE_MIRROR_EN(0)
    ) u_cam_cfg (
        .Clk          (clk50),
        .Rst_n        (sys_rst_n),
        .Init_Done    (cam_init_done),
        .camera_rst_n (),
        .camera_pwdn  (),
        .i2c_sclk     (camera_sclk),
        .i2c_sdat     (camera_sdat)
    );

    // =========================================================================
    //  DVP capture -> 64-bit packed words (PCLK domain)
    // =========================================================================
    wire [63:0] cam_word;
    wire        cam_word_valid;
    wire        cam_word_first;
    wire [15:0] cam_frame_cnt;
    wire [11:0] cam_x, cam_y;
    wire        cam_line_active;

    ov5640_capture #(
        .H_ACTIVE(H_ACTIVE),
        .V_ACTIVE(V_ACTIVE)
    ) u_capture (
        .pclk       (cam_pclk_buf),
        .rst_n      (cam_rst_n),
        .vsync      (camera_vsync),
        .href       (camera_href),
        .data       (camera_data),
        .word       (cam_word),
        .word_valid (cam_word_valid),
        .word_first (cam_word_first),
        .frame_cnt  (cam_frame_cnt),
        .x_cnt      (cam_x),
        .y_cnt      (cam_y),
        .line_active(cam_line_active)
    );

    // =========================================================================
    //  Camera -> AXI clock FIFO
    // =========================================================================
    // bit 64 travels with the pixels: "this word starts a camera frame"
    wire [64:0] camf_data;
    wire        camf_empty;
    wire        camf_pop;
    wire [7:0]  camf_rd_level;

    afifo64 #(.AW(7), .W(65)) u_cam_fifo (
        .wr_clk  (cam_pclk_buf),
        .wr_rstn (cam_rst_n),
        .wr_data ({cam_word_first, cam_word}),
        .wr_en   (cam_word_valid),
        .wr_full (),
        .wr_level(),
        .rd_clk  (clk50),
        .rd_rstn (sys_rst_n),
        .rd_data (camf_data),
        .rd_en   (camf_pop),
        .rd_empty(camf_empty),
        .rd_level(camf_rd_level)
    );

    // =========================================================================
    //  DDR3 frame buffer engine
    // =========================================================================
    wire [63:0] disf_data;
    wire        disf_push;
    wire        disf_full;
    wire [7:0]  disf_wr_level;
    wire        rel_ack;
    wire        frame_seen;
    wire [15:0] cam_frames_axi;
    wire [7:0]  axi_errs;
    wire        frame_new;
    wire        rel_req;
    wire        test_pattern = ctrl[0];
    wire        freeze       = ctrl[1];

    fb_ddr #(
        .FB_BASE    (FB_BASE),
        .H_ACTIVE   (H_ACTIVE),
        .V_ACTIVE   (V_ACTIVE),
        .BEATS      (16),
        .CAM_LEVEL  (24),
        .DISP_LEVEL (32)
    ) u_fb (
        .clk           (clk50),
        .rstn          (sys_rst_n),
        .m_axi_awid    (m_axi_awid),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awqos   (m_axi_awqos),
        .m_axi_awregion(m_axi_awregion),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_arid    (m_axi_arid),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arqos   (m_axi_arqos),
        .m_axi_arregion(m_axi_arregion),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rid     (m_axi_rid),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready),
        .cam_data      (camf_data),
        .cam_empty     (camf_empty),
        .cam_pop       (camf_pop),
        .cam_level     (camf_rd_level),
        .disp_data     (disf_data),
        .disp_push     (disf_push),
        .disp_full     (disf_full),
        .disp_level    (disf_wr_level),
        .rel_req       (rel_req),
        .rel_ack       (rel_ack),
        .freeze        (freeze),
        .frame_seen    (frame_seen),
        .cam_frames    (cam_frames_axi),
        .axi_errs      (axi_errs),
        .frame_new     (frame_new)
    );

    // =========================================================================
    //  AXI clock -> pixel clock FIFO
    // =========================================================================
    wire [63:0] pixf_data;
    wire        pixf_empty;
    wire        pixf_pop;

    afifo64 #(.AW(7), .W(64)) u_disp_fifo (
        .wr_clk  (clk50),
        .wr_rstn (sys_rst_n),
        .wr_data (disf_data),
        .wr_en   (disf_push),
        .wr_full (disf_full),
        .wr_level(disf_wr_level),
        .rd_clk  (clk_pix),
        .rd_rstn (pix_rst_n),
        .rd_data (pixf_data),
        .rd_en   (pixf_pop),
        .rd_empty(pixf_empty),
        .rd_level()
    );

    // frame_seen is a level in the AXI domain
    reg [1:0] fseen_sync;
    always @(posedge clk_pix or negedge pix_rst_n) begin
        if (!pix_rst_n) fseen_sync <= 2'b00;
        else            fseen_sync <= {fseen_sync[0], frame_seen};
    end
    wire video_valid = fseen_sync[1];

    // =========================================================================
    //  Panel
    // =========================================================================
    wire [15:0] disp_frames;
    wire [7:0]  disp_underruns;

    lcd_display #(
        .H_ACTIVE(H_ACTIVE),
        .V_ACTIVE(V_ACTIVE)
    ) u_lcd (
        .pix_clk     (clk_pix),
        .rst_n       (pix_rst_n),
        .fifo_data   (pixf_data),
        .fifo_empty  (pixf_empty),
        .fifo_pop    (pixf_pop),
        .rel_req     (rel_req),
        .rel_ack     (rel_ack),
        .video_valid (video_valid),
        .test_pattern(test_pattern),
        .lcd_hsync   (lcd_hsync),
        .lcd_vsync   (lcd_vsync),
        .lcd_de      (lcd_de),
        .lcd_rgb     (lcd_rgb),
        .frames      (disp_frames),
        .underruns   (disp_underruns)
    );

    assign lcd_pclk = clk_pix;

    // ---- backlight: 8-bit PWM at 195 kHz, default full scale ----------------
    reg [7:0] bl_cnt;
    always @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) bl_cnt <= 8'd0;
        else            bl_cnt <= bl_cnt + 8'd1;
    end
    assign lcd_bl = (bl_cnt < ctrl[15:8]);

    // =========================================================================
    //  Camera statistics (AXI clock domain) and status words
    // =========================================================================
    reg [26:0] sec_cnt;
    reg [7:0]  fps_cnt;
    reg [7:0]  cam_fps;
    reg        cam_streaming;

    always @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sec_cnt       <= 27'd0;
            fps_cnt       <= 8'd0;
            cam_fps       <= 8'd0;
            cam_streaming <= 1'b0;
        end else begin
            if (frame_new)
                fps_cnt <= fps_cnt + 8'd1;

            if (sec_cnt == 27'd49_999_999) begin
                sec_cnt       <= 27'd0;
                cam_fps       <= fps_cnt;
                cam_streaming <= (fps_cnt != 8'd0);
                fps_cnt       <= 8'd0;
            end else begin
                sec_cnt <= sec_cnt + 27'd1;
            end
        end
    end

    // pixel-domain counters into the AXI clock domain (levels, sampled)
    reg [15:0] dfrm_s1, dfrm_s2;
    reg [7:0]  und_s1,  und_s2;

    always @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dfrm_s1 <= 16'd0;
            dfrm_s2 <= 16'd0;
            und_s1  <= 8'd0;
            und_s2  <= 8'd0;
        end else begin
            dfrm_s1 <= disp_frames;
            dfrm_s2 <= dfrm_s1;
            und_s1  <= disp_underruns;
            und_s2  <= und_s1;
        end
    end

    assign status_cam = {cam_frames_axi, cam_fps, 6'd0, cam_streaming, cam_init_done};
    assign status_disp = {axi_errs, und_s2, dfrm_s2};

    // =========================================================================
    //  Board LED: slow blink while video is running, fast blink otherwise
    // =========================================================================
    reg [25:0] led_cnt;
    always @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) led_cnt <= 26'd0;
        else            led_cnt <= led_cnt + 26'd1;
    end

    assign led = cam_streaming ? led_cnt[25] : led_cnt[22];

    // =========================================================================
    //  HDMI transmitter (SiI9022A) set-up over the PL I2C bus
    // =========================================================================
    generate
    if (HDMI_INIT != 0) begin : g_hdmi
        reg [26:0] hdmi_dly;
        reg        hdmi_go;
        reg        hdmi_started;

        // one single-cycle start pulse, one second after the PL comes out of reset
        always @(posedge clk50 or negedge sys_rst_n) begin
            if (!sys_rst_n) begin
                hdmi_dly     <= 27'd0;
                hdmi_go      <= 1'b0;
                hdmi_started <= 1'b0;
            end else begin
                hdmi_go <= 1'b0;
                if (!hdmi_started) begin
                    if (hdmi_dly == 27'd49_999_999) begin
                        hdmi_go      <= 1'b1;
                        hdmi_started <= 1'b1;
                    end else begin
                        hdmi_dly <= hdmi_dly + 27'd1;
                    end
                end
            end
        end

        SiI9022_Init u_hdmi (
            .Clk       (clk50),
            .Rst_n     (sys_rst_n),
            .Go        (hdmi_go),
            .device_id (16'h0072),
            .Init_Done (),
            .i2c_sclk  (hdmi_sclk),
            .i2c_sdat  (hdmi_sdat)
        );
    end else begin : g_no_hdmi
        assign hdmi_sclk = 1'b1;
        assign hdmi_sdat = 1'bz;
    end
    endgenerate



endmodule
