//==============================================================================
// pulse_interval_sched.v
// Convert coarse/fine delay and width parameters into a single 1 ns interval.
// One coarse cycle is 10 ns, so there are 10 steps per coarse count.
//==============================================================================

`timescale 1ns/1ps

module pulse_interval_sched (
    input  wire       enable,
    input  wire [3:0] delay_coarse,
    input  wire [4:0] delay_fine,
    input  wire [2:0] width_coarse,
    input  wire [4:0] width_fine,
    output wire       interval_valid,
    output wire [8:0] rise_step,
    output wire [8:0] fall_step
);

    localparam [8:0] STEPS_PER_COARSE = 9'd10;

    function [3:0] clamp_fine_10;
        input [4:0] fine_in;
        begin
            if (fine_in > 5'd9)
                clamp_fine_10 = 4'd9;
            else
                clamp_fine_10 = fine_in[3:0];
        end
    endfunction

    function [8:0] calc_delay_steps;
        input [3:0] coarse_in;
        input [4:0] fine_in;
        begin
            calc_delay_steps = (coarse_in * STEPS_PER_COARSE) + clamp_fine_10(fine_in);
        end
    endfunction

    function [8:0] calc_width_steps;
        input [2:0] coarse_in;
        input [4:0] fine_in;
        reg   [8:0] total_steps;
        begin
            total_steps = (coarse_in * STEPS_PER_COARSE) + clamp_fine_10(fine_in);
            if (total_steps == 9'd0)
                calc_width_steps = 9'd1;
            else
                calc_width_steps = total_steps;
        end
    endfunction

    wire [8:0] delay_steps;
    wire [8:0] width_steps;

    assign interval_valid = enable;
    assign delay_steps    = calc_delay_steps(delay_coarse, delay_fine);
    assign width_steps    = calc_width_steps(width_coarse, width_fine);
    assign rise_step      = delay_steps;
    assign fall_step      = delay_steps + width_steps;

endmodule
