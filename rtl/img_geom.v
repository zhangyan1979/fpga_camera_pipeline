// =============================================================================
//  img_geom.v — word-stream geometry: end of line, word column, line index
//
//  Image-processing stages frequently need the coordinates of the word they are
//  looking at (border handling, region statistics, dead zones).  They must not
//  take them from outside, because the stage delays the stream: the coordinates
//  have to be regenerated on the delayed stream, exactly like the frame tag.
//
//  A line is a fixed number of words, so one counter is enough: this module
//  turns (sof, valid) into eol / wx / wy.  Instantiating it on a stage's output
//  reproduces the geometry that stage saw at its input, provided the stage kept
//  the word count per line - which is what the stage contract requires.
//
//  Coordinates are word coordinates (one word = 4 pixels): pixel x of pixel i
//  within a word is 4*wx + i.  WORDS_PER_LINE must fit in 9 bits (512) and the
//  frame in 9 lines bits (512 lines); both hold for 200 x 480.
//
//  This is a pure function of the stream, so it needs no frame-synchronised
//  reset: the counters roll over on the line end and are forced to the origin by
//  the frame tag.
// =============================================================================
`timescale 1ns / 1ps

module img_geom #(
    parameter integer WORDS_PER_LINE = 200
) (
    input  wire       clk,
    input  wire       rst_n,        // asynchronous, active low
    input  wire       sof,          // this word is the first of a frame
    input  wire       valid,        // this word is valid
    output wire       eol,          // this word is the last of a line
    output wire [8:0] wx,           // word index within the line
    output wire [8:0] wy            // line index within the frame
);

    localparam [8:0] LAST_WORD = WORDS_PER_LINE - 1;

    reg [8:0] x;
    reg [8:0] y;

    // the frame tag forces the position to the origin, so the tag word is word 0
    // of line 0 whatever the stream did before it
    wire       cur_sof = sof && valid;
    wire [8:0] cx      = cur_sof ? 9'd0 : x;
    wire       last    = valid && (cx == LAST_WORD);

    assign eol = last;
    assign wx  = cx;
    assign wy  = cur_sof ? 9'd0 : y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 9'd0;
            y <= 9'd0;
        end else if (!valid) begin
            // blanking: hold the position
        end else if (last) begin
            x <= 9'd0;
            y <= cur_sof ? 9'd0 : (y + 9'd1);
        end else begin
            x <= cx + 9'd1;
            y <= cur_sof ? 9'd0 : y;
        end
    end

endmodule
