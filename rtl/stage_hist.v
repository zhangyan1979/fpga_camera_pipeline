// =============================================================================
//  stage_hist.v — streaming histogram, histogram equalisation, auto exposure
//
//  Four RGB565 pixels per word arrive one word every eight cam_pclk cycles, so
//  the 256-bin luminance histogram is updated by a four-phase read-modify-write
//  engine: one pixel per phase.  The BRAM read of one phase and the BRAM write
//  of an earlier phase can hit the same bin (two consecutive pixels of equal
//  luminance), which a plain read-modify-write would lose; the count being
//  written is held in a register and forwarded to the next phase (Bailey 2e,
//  fig. 8.3).  The histogram lives in one BRAM18.
//
//  A completed histogram is scanned and cleared during the vertical blanking,
//  and the statistics and the 256-entry mapping are latched then: frame N is
//  accumulated while the map and the statistics of frame N-1 are the ones in
//  use, so no consumer ever sees a half-built histogram.
//
//  knob[2:0] / param and the stat layout are documented in
//  docs/stage_hist.md, together with the luminance formula and the estimates.
// =============================================================================
`timescale 1ns / 1ps

module stage_hist #(
    parameter integer WORDS_PER_LINE = 200,
    parameter integer LINES          = 480
) (
    input  wire        clk,             // cam_pclk
    input  wire        rst_n,           // asynchronous, active low
    // ---- input stream: four RGB565 pixels per word, pixel 0 in [15:0] -------
    input  wire [63:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,
    input  wire        s_eol,
    // ---- output stream, delayed by five clocks ------------------------------
    output reg  [63:0] m_data,
    output reg         m_valid,
    output reg         m_sof,
    output reg         m_eol,
    // ---- control, held for a whole frame by stage_mux -----------------------
    input  wire [15:0] param,           // mode 1: strength, mode 2: target level
    input  wire [ 7:0] knob,            // [2:0] mode
    // ---- statistic of the frame just finished -------------------------------
    output wire [31:0] stat
);

    // =========================================================================
    //  Parameters
    // =========================================================================
    localparam integer TOTAL_PIXELS = WORDS_PER_LINE * LINES * 4;

    // 255 * cum / TOTAL_PIXELS is a constant multiply because the frame size is
    // fixed by the stage contract: choose the shift so the multiplier is small.
    localparam integer MAP_SHIFT = 18;
    localparam integer MAP_MUL   = ((255 << MAP_SHIFT) + (TOTAL_PIXELS / 2)) /
                                   TOTAL_PIXELS;

    localparam [7:0] SAT_Y = 8'd250;    // Y of a saturated pixel (white is 250)

    // FSM states
    localparam [2:0] S_CLEAR = 3'd0,
                     S_IDLE  = 3'd1,
                     S_WORD  = 3'd2,
                     S_SCAN  = 3'd3,
                     S_MEAN  = 3'd4,
                     S_SATP  = 3'd5;

    // =========================================================================
    //  Luminance: Y = (77*R5 + 75*G6 + 29*B5) >> 5, shifts and adds only
    // =========================================================================
    // The 5/6/5 channel values are used directly, so the weights already carry
    // the 8-to-6-bit scaling; the maximum is (77*31+75*63+29*31)>>5 = 250, and
    // the result is monotonic in every channel.
    function [7:0] lum;
        input [15:0] p;
        reg [15:0] r, g, b, acc;
        begin
            r   = {11'd0, p[15:11]};
            g   = {10'd0, p[10:5]};
            b   = {11'd0, p[4:0]};
            acc = (r << 6) + (r << 3) + (r << 2) + r
                + (g << 6) + (g << 3) + (g << 1) + g
                + (b << 4) + (b << 3) + (b << 2) + b;
            lum = acc[12:5];
        end
    endfunction

    // RGB565 grey from an 8-bit luminance
    function [15:0] grey565;
        input [7:0] y;
        begin
            grey565 = {y[7:3], y[7:2], y[7:3]};
        end
    endfunction

    // =========================================================================
    //  State and data path registers
    // =========================================================================
    reg [2:0]  state;
    reg [2:0]  ph;              // 1..4 in S_WORD, 0 while accepting a word
    reg [63:0] din_r;           // the word being accumulated
    reg        last_r;          // the accepted word is the last of the frame
    reg [8:0]  lcnt;            // line index inside the frame
    reg [8:0]  clr_cnt;         // post-reset histogram clear
    reg [8:0]  fin_cnt;         // finalise scan cycle, 0..256
    reg [7:0]  fin_bin;         // bin whose count is in hist_q this cycle

    // =========================================================================
    //  Histogram: one BRAM18, write port + registered read port
    // =========================================================================
    reg  [15:0] hist_ram [0:255];
    reg  [15:0] hist_q;
    reg  [ 7:0] hist_ra;
    reg         hist_we;
    reg  [ 7:0] hist_wa;
    reg  [15:0] hist_wd;

    // read-modify-write accumulator and its forwarding registers
    reg  [ 7:0] wr_bin;
    reg  [ 7:0] wr_bin_q;
    reg  [15:0] wr_data_q;
    reg         wr_vld_q;

    // =========================================================================
    //  Finalise accumulators and statistics
    // =========================================================================
    reg [19:0] tail;        // pixels above the bin being processed
    reg [27:0] sum;         // sum of the tail values = sum(bin * count)
    reg [7:0]  p99;
    reg [19:0] sat_cnt;
    reg [7:0]  mean_r;
    reg [31:0] stat_r;
    reg        final_done;

    // =========================================================================
    //  Equalisation map: 256 x 8 distributed RAM, written once per frame
    // =========================================================================
    reg  [7:0] map_ram [0:255];
    reg  [7:0] map_str;         // strength used to build the loaded map
    reg        map_valid_r;

    // =========================================================================
    //  Control registers
    // =========================================================================
    reg [7:0]  knob_r;
    reg [15:0] par_r;           // parameter latched for the current frame
    reg [7:0]  frame_str;       // strength actually applied to this frame

    // =========================================================================
    //  Serial divider (used twice per frame: mean, then saturation percent)
    // =========================================================================
    reg [31:0] div_dend;
    reg [31:0] div_rem;
    reg [31:0] div_quo;
    reg [5:0]  div_cnt;

    // =========================================================================
    //  Output pipeline
    // =========================================================================
    reg [2:0]  tag_sr [0:3];
    reg [31:0] grey_r;

    // =========================================================================
    //  Input-side phase engine
    // =========================================================================
    wire in_tag  = s_valid & s_sof;
    wire in_last = s_valid & s_eol & (lcnt == (LINES - 1));

    // A frame tag during finalisation means the blanking was shorter than the
    // scan; the word is still accepted (the picture must not lose words) and the
    // statistics of that frame are abandoned.
    wire abort  = ((state == S_SCAN) || (state == S_MEAN) ||
                   (state == S_SATP) || (state == S_CLEAR)) &&
                  s_valid && s_sof;
    wire accept = ((state == S_IDLE) || abort) && s_valid;
    wire proc   = accept || (state == S_WORD);

    wire [2:0]  ph_now   = accept ? 3'd0 : ph;
    wire [63:0] word_now = accept ? s_data : din_r;

    reg [15:0] pix;
    always @(*) begin
        case (ph_now)
        3'd0:    pix = word_now[15:0];
        3'd1:    pix = word_now[31:16];
        3'd2:    pix = word_now[47:32];
        3'd3:    pix = word_now[63:48];
        default: pix = 16'd0;
        endcase
    end

    wire [7:0] y_now = lum(pix);    // bin of the pixel this phase

    // hist_q is the count read one cycle ago, i.e. for the bin written now.  If
    // the previous write went to that same bin, the read is stale and the value
    // just written must be forwarded instead (Bailey fig. 8.3).
    wire        fwd    = wr_vld_q && (wr_bin_q == wr_bin);
    wire [15:0] base   = fwd ? wr_data_q : hist_q;
    wire [15:0] wr_acc = (base == 16'hFFFF) ? 16'hFFFF : base + 16'd1;

    wire [7:0] scan_ra = 8'd255 - fin_cnt[7:0];

    always @(*) begin
        hist_ra = 8'd0;
        hist_we = 1'b0;
        hist_wa = 8'd0;
        hist_wd = 16'd0;

        if (proc && (ph_now <= 3'd3)) begin
            hist_ra = y_now;
        end else if (state == S_SCAN) begin
            hist_ra = scan_ra;
        end

        if (state == S_WORD) begin
            hist_we = 1'b1;
            hist_wa = wr_bin;
            hist_wd = wr_acc;
        end else if ((state == S_SCAN) && (fin_cnt != 9'd0)) begin
            hist_we = 1'b1;
            hist_wa = fin_bin;          // clear the bin just read
            hist_wd = 16'd0;
        end else if (state == S_CLEAR) begin
            hist_we = 1'b1;
            hist_wa = clr_cnt[7:0];
            hist_wd = 16'd0;
        end
    end

    always @(posedge clk) begin
        if (hist_we) hist_ram[hist_wa] <= hist_wd;
        hist_q <= hist_ram[hist_ra];
    end

    // =========================================================================
    //  Finalise arithmetic
    // =========================================================================
    // The scan is one read per clock.  Its data arrives one cycle later, so the
    // bin processed now is 256 - fin_cnt and the address presented now is
    // 255 - fin_cnt.  Read and clear addresses always differ by one, so the
    // clear can share the cycle without a read-during-write ambiguity.
    wire [19:0] tail_n = tail + {4'd0, hist_q};
    wire [26:0] tail_x100 = (tail << 6) + (tail << 5) + (tail << 2);
    wire [27:0] sum_n = sum + {8'd0, tail};
    wire [19:0] sat_n = sat_cnt + ((fin_bin >= SAT_Y) ? {4'd0, hist_q} : 20'd0);

    // cumulative count at this bin, and its full-scale equalisation value
    wire [19:0] cum  = TOTAL_PIXELS - tail;
    wire [31:0] eq_w = (cum * MAP_MUL + (1 << (MAP_SHIFT - 1))) >> MAP_SHIFT;
    wire [7:0]  eq   = (eq_w > 32'd255) ? 8'd255 : eq_w[7:0];

    // blend towards the equalised value: strength 0 leaves the bin alone,
    // strength 255 is (almost exactly) the full cumulative mapping
    wire signed [9:0]  map_diff  = $signed({2'b00, eq}) -
                                   $signed({2'b00, fin_bin});
    wire signed [18:0] map_prod  = map_diff * $signed({1'b0, par_r[7:0]});
    wire signed [18:0] map_rnd   = map_prod + 19'sd128;
    wire signed [9:0]  map_delta = map_rnd >>> 8;
    wire signed [9:0]  map_sum   = $signed({2'b00, fin_bin}) + map_delta;
    wire [7:0]         map_val   = map_sum[7:0];

    // =========================================================================
    //  Serial divider signals
    // =========================================================================
    wire [31:0] rem_sh  = {div_rem[30:0], div_dend[31]};
    wire [31:0] rem_sub = rem_sh - TOTAL_PIXELS;
    wire        div_ge  = (rem_sh >= TOTAL_PIXELS);

    wire div_load_mean = (state == S_SCAN) && (fin_cnt == 9'd256) && !accept;
    wire div_load_sat  = (state == S_MEAN) && (div_cnt == 6'd32) && !accept;
    wire div_run       = (((state == S_MEAN) || (state == S_SATP)) &&
                          (div_cnt < 6'd32) && !accept);

    assign stat = stat_r;

    // =========================================================================
    //  Control: mode and parameter are latched on the input frame tag
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            knob_r      <= 8'd0;
            par_r       <= 16'd0;
            frame_str   <= 8'd0;
            stat_r      <= 32'd0;
            map_str     <= 8'd0;
            map_valid_r <= 1'b0;
        end else begin
            if (accept && in_tag) begin
                knob_r    <= knob;
                par_r     <= param;
                frame_str <= (knob[2:0] == 3'd1) ? map_str : 8'd0;
            end

            if ((state == S_SATP) && (div_cnt == 6'd32) && !accept) begin
                stat_r      <= {frame_str, div_quo[7:0], mean_r, p99};
                map_str     <= par_r[7:0];
                map_valid_r <= 1'b1;
            end
        end
    end

    // =========================================================================
    //  Read-modify-write accumulator
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bin    <= 8'd0;
            wr_bin_q  <= 8'd0;
            wr_data_q <= 16'd0;
            wr_vld_q  <= 1'b0;
        end else if (proc) begin
            wr_bin <= y_now;
            if (state == S_WORD) begin
                wr_bin_q  <= wr_bin;
                wr_data_q <= wr_acc;
                wr_vld_q  <= 1'b1;
            end else begin
                // first phase of a word: the last write of the previous word is
                // long finished, so it must never be forwarded across words
                wr_vld_q  <= 1'b0;
            end
        end
    end

    // =========================================================================
    //  Equalisation map write port
    // =========================================================================
    always @(posedge clk) begin
        if ((state == S_SCAN) && (fin_cnt != 9'd0))
            map_ram[fin_bin] <= map_val;
    end

    // =========================================================================
    //  Main phase / finalise FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_CLEAR;
            ph         <= 3'd0;
            din_r      <= 64'd0;
            last_r     <= 1'b0;
            lcnt       <= 9'd0;
            clr_cnt    <= 9'd0;
            fin_cnt    <= 9'd0;
            fin_bin    <= 8'd0;
            tail       <= 20'd0;
            sum        <= 28'd0;
            p99        <= 8'd0;
            sat_cnt    <= 20'd0;
            mean_r     <= 8'd0;
            final_done <= 1'b0;
        end else begin
            final_done <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_CLEAR: begin
                if (accept) begin
                    state  <= S_WORD;
                    ph     <= 3'd1;
                    din_r  <= s_data;
                    last_r <= in_last;
                end else if (clr_cnt == 9'd255) begin
                    state <= S_IDLE;
                end else begin
                    clr_cnt <= clr_cnt + 9'd1;
                end
            end
            // -----------------------------------------------------------------
            S_IDLE: begin
                if (s_valid) begin
                    state  <= S_WORD;
                    ph     <= 3'd1;
                    din_r  <= s_data;
                    last_r <= in_last;
                end
            end
            // -----------------------------------------------------------------
            S_WORD: begin
                if (ph == 3'd4) begin
                    ph <= 3'd0;
                    if (last_r) begin
                        state   <= S_SCAN;
                        fin_cnt <= 9'd0;
                        fin_bin <= 8'd255;
                        tail    <= 20'd0;
                        sum     <= 28'd0;
                        p99     <= 8'd0;
                        sat_cnt <= 20'd0;
                    end else begin
                        state <= S_IDLE;
                    end
                end else begin
                    ph <= ph + 3'd1;
                end
            end
            // -----------------------------------------------------------------
            S_SCAN: begin
                if (accept) begin
                    state  <= S_WORD;
                    ph     <= 3'd1;
                    din_r  <= s_data;
                    last_r <= in_last;
                end else begin
                    if (fin_cnt != 9'd0) begin
                        tail    <= tail_n;
                        sum     <= sum_n;
                        p99     <= (tail_x100 <= TOTAL_PIXELS) ? fin_bin : p99;
                        sat_cnt <= sat_n;
                        if (fin_bin != 8'd0) fin_bin <= fin_bin - 8'd1;
                    end
                    if (fin_cnt == 9'd256) begin
                        state <= S_MEAN;
                    end else begin
                        fin_cnt <= fin_cnt + 9'd1;
                    end
                end
            end
            // -----------------------------------------------------------------
            S_MEAN: begin
                if (accept) begin
                    state  <= S_WORD;
                    ph     <= 3'd1;
                    din_r  <= s_data;
                    last_r <= in_last;
                end else if (div_cnt == 6'd32) begin
                    mean_r <= div_quo[7:0];
                    state  <= S_SATP;
                end
            end
            // -----------------------------------------------------------------
            S_SATP: begin
                if (accept) begin
                    state  <= S_WORD;
                    ph     <= 3'd1;
                    din_r  <= s_data;
                    last_r <= in_last;
                end else if (div_cnt == 6'd32) begin
                    state      <= S_IDLE;
                    final_done <= 1'b1;
                end
            end
            default: state <= S_IDLE;
            endcase

            // line index for the end-of-frame detection; only accepted words
            // move it, so a word that is dropped upstream cannot desynchronise
            // the phase engine from the geometry
            if (accept) begin
                if (s_sof)      lcnt <= 9'd0;
                else if (s_eol) lcnt <= lcnt + 9'd1;
            end
        end
    end

    // =========================================================================
    //  Divider: 32 restoring steps, quotient of interest is in div_quo[7:0]
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_dend <= 32'd0;
            div_rem  <= 32'd0;
            div_quo  <= 32'd0;
            div_cnt  <= 6'd0;
        end else if (div_load_mean) begin
            div_dend <= {4'd0, sum_n};   // sum_n is the final weighted sum
            div_rem  <= 32'd0;
            div_quo  <= 32'd0;
            div_cnt  <= 6'd0;
        end else if (div_load_sat) begin
            div_dend <= (sat_cnt << 6) + (sat_cnt << 5) + (sat_cnt << 2);
            div_rem  <= 32'd0;
            div_quo  <= 32'd0;
            div_cnt  <= 6'd0;
        end else if (div_run) begin
            div_dend <= {div_dend[30:0], 1'b0};
            div_rem  <= div_ge ? rem_sub : rem_sh;
            div_quo  <= {div_quo[30:0], div_ge};
            div_cnt  <= div_cnt + 6'd1;
        end
    end

    // =========================================================================
    //  Output: the word, its tags and the mapped pixels all leave together
    // =========================================================================
    // The accumulator takes five clocks per word (phase 0 = the accepting
    // clock, phases 1..4 in S_WORD).  The tag shift register is four deep and
    // the last stage is registered out, so m_sof / m_eol / m_valid land on the
    // same clock as the word they belong to - the tags can never drift.
    wire [7:0]  map_rd = map_ram[y_now];
    wire [7:0]  map_y  = map_valid_r ? map_rd : y_now;
    wire [63:0] map_word = {grey565(grey_r[31:24]), grey565(grey_r[23:16]),
                            grey565(grey_r[15:8]),  grey565(grey_r[7:0])};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            grey_r <= 32'd0;
        else if (proc && (ph_now <= 3'd3))
            grey_r[ph_now * 8 +: 8] <= map_y;
    end

    integer ti;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ti = 0; ti < 4; ti = ti + 1) tag_sr[ti] <= 3'd0;
            m_data  <= 64'd0;
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
            m_eol   <= 1'b0;
        end else begin
            tag_sr[0] <= {s_sof & s_valid, s_eol & s_valid, s_valid};
            tag_sr[1] <= tag_sr[0];
            tag_sr[2] <= tag_sr[1];
            tag_sr[3] <= tag_sr[2];

            // {sof, eol, valid} is the bit order of one tag_sr entry
            m_valid <= tag_sr[3][0];
            m_sof   <= tag_sr[3][2];
            m_eol   <= tag_sr[3][1];

            if ((state == S_WORD) && (ph == 3'd4))
                m_data <= (knob_r[2:0] == 3'd1) ? map_word : din_r;
        end
    end

endmodule
