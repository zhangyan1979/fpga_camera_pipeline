// =============================================================================
//  stage_mux.v — selects one image-processing stage into the frame-buffer path
//
//  Every stage sees the same raw word stream from ov5640_capture and runs in
//  parallel with every other stage; this block picks one of them (or the raw
//  stream, sel = 0).  Keeping the stages parallel rather than chained is what
//  makes the slot useful for teaching: one control write compares two algorithms
//  on the same live picture, and a stage cannot break the pipeline for the
//  others.
//
//  A stage is a module with this interface (see docs/stage_contract.md):
//
//      input  clk, rst_n, s_valid, s_sof, s_eol, [63:0] s_data
//      output                m_valid, m_sof, m_eol, [63:0] m_data
//      input  [15:0] param, [7:0] knob           (held for a whole frame)
//      output [31:0] stat                        (free-form, sampled per frame)
//
//  What this block owes the stage, so that no stage has to repeat it:
//
//    * frame-stable parameters.  ctrl[] lives in the AXI clock domain and may
//      change at any time, so sel / param / knob are synchronised here and then
//      latched on the frame tag.  A stage never sees a parameter move in the
//      middle of a frame and needs no CDC of its own.
//
//    * a hand-over that cannot tear a frame.  Stages have different latencies,
//      so a different stage is at a different word of the stream at the same
//      instant.  When the selection changes, the mux stops emitting at the frame
//      tag and stays silent until the newly selected stage produces its own
//      frame tag - that tag then starts the next frame from a known word 0.
//      While it is silent the previous stage's remaining words are dropped; with
//      a real camera the vertical blanking between frames is far longer than any
//      stage latency, so the old stage has already caught up and nothing is
//      lost.  (With no blanking at all, up to the latency difference would be
//      missing from the last line of one frame; fb_ddr's fixed word count makes
//      even that harmless, because it stops writing at 96 000 words.)
//
//    * warm-up gating.  Right after reset a stage's pipeline is full of junk
//      that carries no frame tag.  Those words are dropped, so the frame-buffer
//      engine still sees exactly one tagged word per frame and its burst counter
//      cannot drift.
//
//  The statistic is the one multi-bit value that travels back the other way:
//  stages drive it combinationally, this block snapshots it once per frame and
//  moves it across with a toggle handshake, so the PS never reads a torn value.
// =============================================================================
`timescale 1ns / 1ps

module stage_mux #(
    parameter integer NUM_STAGES = 1,       // number of populated stage slots
    parameter integer SEL_W      = 3
) (
    input  wire                     clk,          // camera pixel clock
    input  wire                     rst_n,        // asynchronous, active low
    // raw word stream from the capture block
    input  wire [63:0]              s_data,
    input  wire                     s_valid,
    input  wire                     s_sof,
    input  wire                     s_eol,
    // stage outputs, flattened; slot k-1 carries stage k (k = 1 .. NUM_STAGES)
    input  wire [NUM_STAGES*64-1:0] st_data,
    input  wire [NUM_STAGES-1:0]    st_valid,
    input  wire [NUM_STAGES-1:0]    st_sof,
    input  wire [NUM_STAGES-1:0]    st_eol,
    input  wire [NUM_STAGES*32-1:0] st_stat,
    // control, AXI clock domain (quasi-static)
    input  wire [SEL_W-1:0]         sel,
    input  wire [15:0]              param,
    input  wire [ 7:0]              knob,
    input  wire                     clk_ctrl,
    input  wire                     rst_ctrl_n,
    // selected stream into the camera -> AXI FIFO
    output wire [63:0]              m_data,
    output wire                     m_valid,
    output wire                     m_sof,
    output wire                     m_eol,
    // frame-stable parameters for the stages
    output wire [15:0]              s_param,
    output wire [ 7:0]              s_knob,
    // statistic of the selected stage, AXI clock domain
    output reg  [31:0]              stat
);

    // =========================================================================
    //  Control into the camera clock domain
    // =========================================================================
    reg [SEL_W-1:0] sel_s1, sel_s2;
    reg [15:0]      par_s1, par_s2;
    reg [ 7:0]      knb_s1, knb_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel_s1 <= {SEL_W{1'b0}};
            sel_s2 <= {SEL_W{1'b0}};
            par_s1 <= 16'd0;
            par_s2 <= 16'd0;
            knb_s1 <= 8'd0;
            knb_s2 <= 8'd0;
        end else begin
            sel_s1 <= sel;
            sel_s2 <= sel_s1;
            par_s1 <= param;
            par_s2 <= par_s1;
            knb_s1 <= knob;
            knb_s2 <= knb_s1;
        end
    end

    // =========================================================================
    //  Selection and frame-boundary hand-over
    // =========================================================================
    // active  stage driving the picture
    // target  stage requested for the next frame, waiting for its frame tag
    // sel_now stage whose stream is being looked at this cycle: the requested
    //         one while a change is in flight, the active one otherwise
    reg [SEL_W-1:0] active;
    reg [SEL_W-1:0] target;
    reg             pending;
    reg [15:0]      par_l;          // parameters latched for the frame
    reg [ 7:0]      knb_l;

    wire [SEL_W-1:0] sel_now = (s_valid && s_sof) ? sel_s2
                             : pending           ? target
                             :                     active;

    // selected stream (combinational, from sel_now)
    reg [63:0] v_data;
    reg        v_valid;
    reg        v_sof;
    reg        v_eol;
    reg [31:0] v_stat;
    integer    k;

    always @(*) begin
        v_data  = s_data;
        v_valid = s_valid;
        v_sof   = s_sof;
        v_eol   = s_eol;
        v_stat  = 32'd0;

        if ((sel_now != {SEL_W{1'b0}}) && (sel_now <= NUM_STAGES)) begin
            k       = sel_now - 1;
            v_data  = st_data[k*64 +: 64];
            v_valid = st_valid[k];
            v_sof   = st_sof[k];
            v_eol   = st_eol[k];
            v_stat  = st_stat[k*32 +: 32];
        end
    end

    wire v_tag = v_valid && v_sof;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active  <= {SEL_W{1'b0}};
            target  <= {SEL_W{1'b0}};
            pending <= 1'b0;
        end else if (s_valid && s_sof) begin
            // a frame is offered: decide which stage drives it
            if (sel_s2 == active) begin
                pending <= 1'b0;                    // nothing to do (or cancelled)
            end else if (v_tag) begin
                // the requested stage is already at its own frame tag, so the
                // hand-over completes in this same cycle
                active  <= sel_s2;
                pending <= 1'b0;
            end else begin
                target  <= sel_s2;
                pending <= 1'b1;
            end
        end else if (pending && v_tag) begin
            // the requested stage has reached the frame tag: hand over
            active  <= target;
            pending <= 1'b0;
        end
    end

    assign s_param = par_l;
    assign s_knob  = knb_l;

    // Parameters follow the frame that is actually being emitted: they are
    // re-latched on the emitted frame tag, so a stage never sees a parameter
    // move while it is producing the words of a frame.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            par_l <= 16'd0;
            knb_l <= 8'd0;
        end else if (m_sof) begin
            par_l <= par_s2;
            knb_l <= knb_s2;
        end
    end

    // =========================================================================
    //  Output: silent while a hand-over is in flight, and until the first tag
    // =========================================================================
    // While the change is in flight the stream being looked at is not yet the
    // one that will drive the picture, so nothing may be emitted: otherwise the
    // old stage's frame tag would start a frame that is then abandoned.
    reg  warm;
    wire warm_now = warm | v_tag;
    wire suppress = ((s_valid && s_sof) && (sel_s2 != active) && !v_tag) ||
                    (pending && !v_tag);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) warm <= 1'b0;
        else        warm <= warm_now;
    end

    assign m_data  = v_data;
    assign m_valid = v_valid && !suppress && warm_now;
    assign m_sof   = v_sof   && !suppress && warm_now;
    assign m_eol   = v_eol   && !suppress && warm_now;

    // =========================================================================
    //  Statistic: snapshot at the frame tag, hand over with a toggle handshake
    // =========================================================================
    // The snapshot is taken one cycle after the offered tag so that sel_l has
    // already switched when the selection changes: the value reported belongs to
    // the stage that is about to drive the picture.
    reg        sof_d;
    reg [31:0] stat_frame;
    reg        stat_tog;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sof_d      <= 1'b0;
            stat_frame <= 32'd0;
            stat_tog   <= 1'b0;
        end else begin
            sof_d <= s_valid && s_sof;
            if (sof_d) begin
                stat_frame <= v_stat;
                stat_tog   <= ~stat_tog;
            end
        end
    end

    // the payload is stable for a whole frame, so two flops on the toggle suffice
    reg t1, t2, t3;

    always @(posedge clk_ctrl or negedge rst_ctrl_n) begin
        if (!rst_ctrl_n) begin
            t1   <= 1'b0;
            t2   <= 1'b0;
            t3   <= 1'b0;
            stat <= 32'd0;
        end else begin
            t1 <= stat_tog;
            t2 <= t1;
            t3 <= t2;
            if (t2 != t3) stat <= stat_frame;
        end
    end

endmodule
