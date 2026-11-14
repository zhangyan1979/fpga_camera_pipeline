// =============================================================================
//  ov5640_top.v — ACZ702 camera pipeline: OV5640 -> DDR3 -> TFT/HDMI
//
//      OV5640 --DVP--> capture --> 64-bit FIFO --> DDR3 (2 frame buffers)
//                                                      |   AXI4 master -> HP0
//      panel  <-- 33.3 MHz timing <-- FIFO <-- read engine
//
//  The PS only supplies the DDR3 controller and the clocks: FCLK0 = 50 MHz feeds
//  the whole AXI side, and two AXI GPIOs carry a 32-bit control word out and two
//  32-bit status words back, so the bare-metal application can report frame rates
//  and switch modes over the serial console.
//
//  Control word (PS -> PL)                  Status words (PL -> PS)
//    ctrl[0]      test pattern              status_cam[0]      camera init done
//    ctrl[1]      freeze frame              status_cam[1]      camera streaming
//    ctrl[4:2]    processing stage          status_cam[7:2]    reserved
//    ctrl[7:5]    stage mode                status_cam[15:8]   camera fps
//    ctrl[15:8]   backlight duty 0..255     status_cam[31:16]  camera frames
//    ctrl[31:16]  stage parameter
//                                           status_disp[15:0]  panel frames
//    stage 0 = bypass (raw camera words)    status_disp[23:16] frames with a
//    stage 1..7 = populated slots                         missing pixel
//                                           status_disp[31:24] AXI error count
//
//                                           status_ext[31:0]   the selected
//                                                              stage's statistic
//
//  Stages are word-stream processors sitting between ov5640_capture and the
//  camera -> AXI FIFO.  One is selected into the frame-buffer path; see
//  docs/stage_contract.md for the interface and the invariants a stage must
//  keep (96 000 words per frame, 200 words per line, the frame tag delayed with
//  the data).
//
//  The 16-bit panel value is {R[4:0], G[5:0], B[4:0]} straight onto the TFT RGB
//  pins, which the SiI9022A (same pins) also converts to HDMI.
// =============================================================================
`timescale 1ns / 1ps

module ov5640_top #(
    parameter integer H_ACTIVE = 800,
    parameter integer V_ACTIVE = 480,
    parameter [31:0]  FB_BASE  = 32'h0180_0000
) (
    // ---- PS side ------------------------------------------------------------
    input  wire        clk50,           // PS FCLK0, 50 MHz
    input  wire        aresetn,         // PS FCLK_RESET0_N
    input  wire [31:0] ctrl,            // AXI GPIO from the PS
    output wire [31:0] status_cam,
    output wire [31:0] status_disp,
    output wire [31:0] status_ext,      // statistic of the selected stage
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
    input  wire [ 7:0] camera_data,
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

    localparam [26:0] HDMI_DELAY = 27'd50_000_000;   // 1 s at 50 MHz

    // one word carries four pixels, so a line is H_ACTIVE / 4 words
    localparam integer WORDS_PER_LINE = H_ACTIVE / 4;

    // =========================================================================
    //  Clocks and resets
    // =========================================================================
    // AXI domain: synchronised release of the PS reset
    reg [1:0] rst50_sync;
    always @(posedge clk50 or negedge aresetn) begin
        if (!aresetn) rst50_sync <= 2'b00;
        else          rst50_sync <= {rst50_sync[0], 1'b1};
    end
    wire rst50_n = rst50_sync[1];

    wire clk_pix;
    wire clk_cam;
    wire mmcm_locked;

    clk_gen u_clk_gen (
        .clk50  (clk50),
        .rst    (~rst50_n),
        .clk_pix(clk_pix),
        .clk_cam(clk_cam),
        .locked (mmcm_locked)
    );

    wire sys_rst_n = rst50_n & mmcm_locked;

    // pixel domain: released once the MMCM is locked
    reg [2:0] rst_pix_sync;
    always @(posedge clk_pix or negedge aresetn) begin
        if (!aresetn) rst_pix_sync <= 3'b000;
        else          rst_pix_sync <= {rst_pix_sync[1:0], 1'b1};
    end
    wire pix_rst_n = rst_pix_sync[2] & mmcm_locked;

    // camera PCLK domain: the sensor only produces PCLK once it is powered and
    // configured, so this follows the board reset.  M17 is not a clock-capable
    // pin, which is why the clock goes through an explicit BUFG here.
    wire cam_pclk;
    BUFG u_bufg_cam_pclk (
        .I(camera_pclk),
        .O(cam_pclk)
    );

    reg [2:0] rst_cam_sync;
    always @(posedge cam_pclk or negedge aresetn) begin
        if (!aresetn) rst_cam_sync <= 3'b000;
        else          rst_cam_sync <= {rst_cam_sync[1:0], 1'b1};
    end
    wire cam_rst_n = rst_cam_sync[2];

    assign camera_xclk = clk_cam;

    // =========================================================================
    //  OV5640 register initialisation (SCCB on the camera header)
    // =========================================================================
    wire cam_init_done;

    ov5640_init #(
        .IMAGE_WIDTH    (H_ACTIVE),
        .IMAGE_HEIGHT   (V_ACTIVE),
        .IMAGE_FLIP_EN  (1'b0),
        .IMAGE_MIRROR_EN(1'b0)
    ) u_ov5640_init (
        .clk      (clk50),
        .rst_n    (sys_rst_n),
        .init_done(cam_init_done),
        .i2c_sclk (camera_sclk),
        .i2c_sdat (camera_sdat)
    );

    // =========================================================================
    //  DVP capture -> 64-bit packed words (camera PCLK domain)
    // =========================================================================
    wire [63:0] cam_word;
    wire        cam_word_valid;
    wire        cam_word_first;

    ov5640_capture #(
        .H_ACTIVE(H_ACTIVE),
        .V_ACTIVE(V_ACTIVE)
    ) u_capture (
        .pclk      (cam_pclk),
        .rst_n     (cam_rst_n),
        .vsync     (camera_vsync),
        .href      (camera_href),
        .data      (camera_data),
        .word      (cam_word),
        .word_valid(cam_word_valid),
        .word_first(cam_word_first)
    );

    // =========================================================================
    //  Processing stage slot (camera PCLK domain)
    // =========================================================================
    // A stage is a word-stream processor: 64 bits = four RGB565 pixels, plus the
    // frame tag and the line-end marker, all delayed together by the stage's own
    // latency.  Stages run in parallel and stage_mux selects one into the
    // frame-buffer path, so a control write compares two algorithms on the same
    // live picture and a broken stage cannot stall the others.
    wire        cam_weol;
    wire [ 8:0] cam_wx;
    wire [ 8:0] cam_wy;

    img_geom #(
        .WORDS_PER_LINE(WORDS_PER_LINE)
    ) u_geom (
        .clk  (cam_pclk),
        .rst_n(cam_rst_n),
        .sof  (cam_word_first),
        .valid(cam_word_valid),
        .eol  (cam_weol),
        .wx   (cam_wx),
        .wy   (cam_wy)
    );

    wire [63:0] stage_word;
    wire        stage_valid;
    wire        stage_sof;
    wire        stage_eol;
    wire [31:0] stage_stat;

    // the parameters stage_mux hands to the selected stage, frame-stable
    wire [15:0] stage_param;
    wire [ 7:0] stage_knob;

    // ---- slot 1: point operations through a lookup table (sel = 1) ----------
    wire [63:0] lut_data;
    wire        lut_valid;
    wire        lut_sof;
    wire        lut_eol;
    wire [31:0] lut_stat;

    stage_lut #(
        .WORDS_PER_LINE (WORDS_PER_LINE),
        .LINES_PER_FRAME(V_ACTIVE)
    ) u_stage_lut (
        .clk    (cam_pclk),
        .rst_n  (cam_rst_n),
        .s_data (cam_word),
        .s_valid(cam_word_valid),
        .s_sof  (cam_word_first),
        .s_eol  (cam_weol),
        .m_data (lut_data),
        .m_valid(lut_valid),
        .m_sof  (lut_sof),
        .m_eol  (lut_eol),
        .param  (stage_param),
        .knob   (stage_knob),
        .stat   (lut_stat)
    );

    // a slot that is not populated is fed the raw stream, so any ctrl[4:2]
    // value is safe and the picture never depends on an unwritten stage
    stage_mux #(
        .NUM_STAGES(4)
    ) u_stage_mux (
        .clk       (cam_pclk),
        .rst_n     (cam_rst_n),
        .s_data    (cam_word),
        .s_valid   (cam_word_valid),
        .s_sof     (cam_word_first),
        .s_eol     (cam_weol),
        .st_data   ({cam_word,       cam_word,       cam_word,       lut_data}),
        .st_valid  ({cam_word_valid, cam_word_valid, cam_word_valid, lut_valid}),
        .st_sof    ({cam_word_first, cam_word_first, cam_word_first, lut_sof}),
        .st_eol    ({cam_weol,       cam_weol,       cam_weol,       lut_eol}),
        .st_stat   ({32'd0,          32'd0,          32'd0,           lut_stat}),
        .sel       (ctrl[4:2]),
        .param     (ctrl[31:16]),
        .knob      ({5'd0, ctrl[7:5]}),
        .clk_ctrl  (clk50),
        .rst_ctrl_n(sys_rst_n),
        .m_data    (stage_word),
        .m_valid   (stage_valid),
        .m_sof     (stage_sof),
        .m_eol     (stage_eol),
        .s_param   (stage_param),
        .s_knob    (stage_knob),
        .stat      (stage_stat)
    );

    // =========================================================================
    //  Camera -> AXI clock FIFO
    // =========================================================================
    // bit 64 travels with the pixels: "this word starts a camera frame"
    wire [64:0] camf_data;
    wire        camf_empty;
    wire        camf_pop;
    wire [7:0]  camf_level;

    afifo #(
        .AW(7),
        .W (65)
    ) u_cam_fifo (
        .wr_clk  (cam_pclk),
        .wr_rst_n(cam_rst_n),
        .wr_data ({stage_sof, stage_word}),
        .wr_en   (stage_valid),
        .wr_full (),
        .wr_level(),
        .rd_clk  (clk50),
        .rd_rst_n(sys_rst_n),
        .rd_data (camf_data),
        .rd_en   (camf_pop),
        .rd_empty(camf_empty),
        .rd_level(camf_level)
    );

    // =========================================================================
    //  DDR3 frame buffer engine
    // =========================================================================
    wire [63:0] disf_data;
    wire        disf_push;
    wire        disf_full;
    wire [7:0]  disf_level;
    wire        rel_req;
    wire        rel_ack;
    wire        frame_seen;
    wire        frame_new;
    wire [15:0] cam_frames;
    wire [ 7:0] axi_errs;

    wire test_pattern = ctrl[0];
    wire freeze       = ctrl[1];

    fb_ddr #(
        .FB_BASE   (FB_BASE),
        .H_ACTIVE  (H_ACTIVE),
        .V_ACTIVE  (V_ACTIVE),
        .BEATS     (16),
        .CAM_LEVEL (24),
        .DISP_LEVEL(32)
    ) u_fb_ddr (
        .clk           (clk50),
        .rst_n         (sys_rst_n),
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
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready),
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
        .cam_frames    (cam_frames),
        .axi_errs      (axi_errs),
        .frame_new     (frame_new)
    );

    // =========================================================================
    //  AXI clock -> pixel clock FIFO
    // =========================================================================
    wire [63:0] pixf_data;
    wire        pixf_empty;
    wire        pixf_pop;

    afifo #(
        .AW(7),
        .W (64)
    ) u_disp_fifo (
        .wr_clk  (clk50),
        .wr_rst_n(sys_rst_n),
        .wr_data (disf_data),
        .wr_en   (disf_push),
        .wr_full (disf_full),
        .wr_level(disf_level),
        .rd_clk  (clk_pix),
        .rd_rst_n(pix_rst_n),
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
    wire [ 7:0] disp_underruns;

    lcd_display #(
        .H_ACTIVE(H_ACTIVE),
        .V_ACTIVE(V_ACTIVE)
    ) u_lcd_display (
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

    // =========================================================================
    //  Backlight: 8-bit PWM at 195 kHz, duty from ctrl[15:8]
    // =========================================================================
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
    reg [ 7:0] fps_cnt;
    reg [ 7:0] cam_fps;
    reg        cam_streaming;

    always @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sec_cnt       <= 27'd0;
            fps_cnt       <= 8'd0;
            cam_fps       <= 8'd0;
            cam_streaming <= 1'b0;
        end else begin
            if (frame_new) fps_cnt <= fps_cnt + 8'd1;

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
    reg [15:0] disp_frames_s1, disp_frames_s2;
    reg [ 7:0] underruns_s1,   underruns_s2;

    always @(posedge clk50 or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            disp_frames_s1 <= 16'd0;
            disp_frames_s2 <= 16'd0;
            underruns_s1   <= 8'd0;
            underruns_s2   <= 8'd0;
        end else begin
            disp_frames_s1 <= disp_frames;
            disp_frames_s2 <= disp_frames_s1;
            underruns_s1   <= disp_underruns;
            underruns_s2   <= underruns_s1;
        end
    end

    assign status_cam  = {cam_frames, cam_fps, 6'd0, cam_streaming, cam_init_done};
    assign status_disp = {axi_errs, underruns_s2, disp_frames_s2};
    assign status_ext  = stage_stat;

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
                if (hdmi_dly == HDMI_DELAY - 27'd1) begin
                    hdmi_go      <= 1'b1;
                    hdmi_started <= 1'b1;
                end else begin
                    hdmi_dly <= hdmi_dly + 27'd1;
                end
            end
        end
    end

    sii9022_init u_sii9022_init (
        .clk     (clk50),
        .rst_n   (sys_rst_n),
        .go      (hdmi_go),
        .i2c_sclk(hdmi_sclk),
        .i2c_sdat(hdmi_sdat)
    );

endmodule
