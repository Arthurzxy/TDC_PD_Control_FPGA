//==============================================================================
// gate_interval_merge.v
// Merge two source intervals into up to two OR windows.
//==============================================================================

`timescale 1ns/1ps

module gate_interval_merge (
    input  wire       sig2_valid,
    input  wire [8:0] sig2_rise_step,
    input  wire [8:0] sig2_fall_step,
    input  wire       sig3_valid,
    input  wire [8:0] sig3_rise_step,
    input  wire [8:0] sig3_fall_step,
    output reg  [1:0] win_count,
    output reg        win0_valid,
    output reg  [8:0] win0_rise_step,
    output reg  [8:0] win0_fall_step,
    output reg        win1_valid,
    output reg  [8:0] win1_rise_step,
    output reg  [8:0] win1_fall_step
);

    reg       first_valid;
    reg [8:0] first_rise;
    reg [8:0] first_fall;
    reg       second_valid;
    reg [8:0] second_rise;
    reg [8:0] second_fall;

    always @* begin
        win_count     = 2'd0;
        win0_valid    = 1'b0;
        win0_rise_step = 9'd0;
        win0_fall_step = 9'd0;
        win1_valid    = 1'b0;
        win1_rise_step = 9'd0;
        win1_fall_step = 9'd0;

        first_valid  = 1'b0;
        first_rise   = 9'd0;
        first_fall   = 9'd0;
        second_valid = 1'b0;
        second_rise  = 9'd0;
        second_fall  = 9'd0;

        if (sig2_valid && sig3_valid) begin
            if ((sig2_rise_step < sig3_rise_step) ||
                ((sig2_rise_step == sig3_rise_step) && (sig2_fall_step <= sig3_fall_step))) begin
                first_valid  = 1'b1;
                first_rise   = sig2_rise_step;
                first_fall   = sig2_fall_step;
                second_valid = 1'b1;
                second_rise  = sig3_rise_step;
                second_fall  = sig3_fall_step;
            end else begin
                first_valid  = 1'b1;
                first_rise   = sig3_rise_step;
                first_fall   = sig3_fall_step;
                second_valid = 1'b1;
                second_rise  = sig2_rise_step;
                second_fall  = sig2_fall_step;
            end
        end else if (sig2_valid) begin
            first_valid = 1'b1;
            first_rise  = sig2_rise_step;
            first_fall  = sig2_fall_step;
        end else if (sig3_valid) begin
            first_valid = 1'b1;
            first_rise  = sig3_rise_step;
            first_fall  = sig3_fall_step;
        end

        if (!first_valid) begin
            win_count = 2'd0;
        end else if (!second_valid) begin
            win_count      = 2'd1;
            win0_valid     = 1'b1;
            win0_rise_step = first_rise;
            win0_fall_step = first_fall;
        end else if (second_rise <= first_fall) begin
            win_count      = 2'd1;
            win0_valid     = 1'b1;
            win0_rise_step = first_rise;
            win0_fall_step = (second_fall > first_fall) ? second_fall : first_fall;
        end else begin
            win_count      = 2'd2;
            win0_valid     = 1'b1;
            win0_rise_step = first_rise;
            win0_fall_step = first_fall;
            win1_valid     = 1'b1;
            win1_rise_step = second_rise;
            win1_fall_step = second_fall;
        end
    end

endmodule
