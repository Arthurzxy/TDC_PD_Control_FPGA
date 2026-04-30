//==============================================================================
// gate_wave_encoder_2win.v
// Pre-encode up to two merged windows into 500ps serialized words.
//==============================================================================

`timescale 1ns/1ps

module gate_wave_encoder_2win #(
    parameter integer MAX_STEPS = 304,
    parameter integer WORD_WIDTH = 8
)(
    input  wire       clk_div,
    input  wire       rst,
    input  wire       ref_start,
    input  wire [1:0] win_count,
    input  wire       win0_valid,
    input  wire [8:0] win0_rise_step,
    input  wire [8:0] win0_fall_step,
    input  wire       win1_valid,
    input  wire [8:0] win1_rise_step,
    input  wire [8:0] win1_fall_step,
    output wire [7:0] ser_word,
    output reg        frame_busy,
    output reg        frame_start_pulse,
    output reg        frame_done
);

    localparam integer WORD_COUNT = MAX_STEPS / WORD_WIDTH;

    reg [MAX_STEPS-1:0] prep_frame_bits;
    reg [MAX_STEPS-1:0] active_frame_bits;
    reg [5:0]           prep_word_count;
    reg [5:0]           active_word_count;
    reg [5:0]           active_word_index;
    integer             i;
    integer             highest_step;

    wire [8:0] active_base;

    assign active_base = {active_word_index, 3'b000};
    assign ser_word = frame_busy ? active_frame_bits[active_base +: WORD_WIDTH] : prep_frame_bits[WORD_WIDTH-1:0];

    always @* begin
        prep_frame_bits = {MAX_STEPS{1'b0}};
        for (i = 0; i < MAX_STEPS; i = i + 1) begin
            if (win0_valid && (i >= win0_rise_step) && (i < win0_fall_step))
                prep_frame_bits[i] = 1'b1;
            if (win1_valid && (i >= win1_rise_step) && (i < win1_fall_step))
                prep_frame_bits[i] = 1'b1;
        end

        prep_word_count = 6'd0;
        highest_step = -1;

        if (win1_valid && (win1_fall_step > 9'd0))
            highest_step = win1_fall_step - 1;
        else if (win0_valid && (win0_fall_step > 9'd0))
            highest_step = win0_fall_step - 1;

        if ((win_count != 2'd0) && (highest_step >= 0))
            prep_word_count = (highest_step / WORD_WIDTH) + 1;
    end

    always @(posedge clk_div) begin
        if (rst) begin
            active_frame_bits  <= {MAX_STEPS{1'b0}};
            active_word_count  <= 6'd0;
            active_word_index  <= 6'd0;
            frame_busy         <= 1'b0;
            frame_start_pulse  <= 1'b0;
            frame_done         <= 1'b0;
        end else begin
            frame_start_pulse <= 1'b0;
            frame_done        <= 1'b0;

            if (frame_busy) begin
                if (active_word_index + 1 < active_word_count) begin
                    active_word_index <= active_word_index + 1'b1;
                end else begin
                    active_word_index <= 6'd0;
                    active_word_count <= 6'd0;
                    frame_busy        <= 1'b0;
                    frame_done        <= 1'b1;
                end
            end else if (ref_start && (prep_word_count != 6'd0)) begin
                active_frame_bits <= prep_frame_bits;
                active_word_count <= prep_word_count;
                active_word_index <= 6'd1;
                frame_busy        <= (prep_word_count > 6'd1);
                frame_start_pulse <= 1'b1;
                if (prep_word_count == 6'd1)
                    frame_done <= 1'b1;
            end
        end
    end

endmodule
