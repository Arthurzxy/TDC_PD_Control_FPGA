//==============================================================================
// pulse_gen_coarse.v
// Reusable coarse pulse generator with explicit rise/fall events
//
// Description:
//   Step-2 pulse generator for the gate control path. This version still works
//   at coarse clock-cycle granularity, but it separates the pulse generation
//   into:
//     1. coarse rise event scheduling
//     2. coarse fall event scheduling
//     3. output pulse register update
//
//   This structure is kept intentionally explicit so later versions can attach
//   fine-delay logic to the rise and fall paths independently.
//
// Behavioral definition:
//   - enable=0: ignore trigger, keep output low
//   - busy=1: ignore any new trigger
//   - delay=0: generate the rise event on the accepted trigger clock edge
//   - width=0: still output a minimum 1-clock pulse
//
// Timing definition:
//   - A trigger is sampled on clk rising edge
//   - If delay=N (>0), rise_event occurs N clocks later
//   - If width=M (>0), fall_event occurs M clocks after rise_event
//   - If width=0, fall_event occurs 1 clock after rise_event
//==============================================================================

`timescale 1ns/1ps

module pulse_gen_coarse #(
    parameter integer DELAY_BITS = 8,
    parameter integer WIDTH_BITS = 7
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  trigger,
    input  wire                  enable,
    input  wire [DELAY_BITS-1:0] delay,
    input  wire [WIDTH_BITS-1:0] width,
    output reg                   pulse_out,
    output wire                  busy,
    output reg                   rise_event,
    output reg                   fall_event
);

    localparam integer COUNT_BITS =
        (DELAY_BITS >= WIDTH_BITS) ? DELAY_BITS : WIDTH_BITS;

    reg                          rise_pending;
    reg                          fall_pending;
    reg  [COUNT_BITS-1:0]        rise_counter;
    reg  [COUNT_BITS-1:0]        fall_counter;
    reg  [DELAY_BITS-1:0]        latched_delay;
    reg  [WIDTH_BITS-1:0]        latched_width;
    reg  [WIDTH_BITS-1:0]        latched_width_eff;

    wire [WIDTH_BITS-1:0]        width_eff;
    wire [COUNT_BITS-1:0]        delay_ext;
    wire [COUNT_BITS-1:0]        width_eff_ext;
    wire                         accept_trigger;

    assign width_eff      = (width == {WIDTH_BITS{1'b0}}) ?
                            {{(WIDTH_BITS-1){1'b0}}, 1'b1} : width;
    assign delay_ext      = {{(COUNT_BITS-DELAY_BITS){1'b0}}, delay};
    assign width_eff_ext  = {{(COUNT_BITS-WIDTH_BITS){1'b0}}, width_eff};
    assign busy           = rise_pending | fall_pending;
    assign accept_trigger = trigger && enable && !busy;

    always @(posedge clk) begin
        if (rst) begin
            pulse_out         <= 1'b0;
            rise_event        <= 1'b0;
            fall_event        <= 1'b0;
            rise_pending      <= 1'b0;
            fall_pending      <= 1'b0;
            rise_counter      <= {COUNT_BITS{1'b0}};
            fall_counter      <= {COUNT_BITS{1'b0}};
            latched_delay     <= {DELAY_BITS{1'b0}};
            latched_width     <= {WIDTH_BITS{1'b0}};
            latched_width_eff <= {{(WIDTH_BITS-1){1'b0}}, 1'b1};
        end else begin
            rise_event <= 1'b0;
            fall_event <= 1'b0;

            if (accept_trigger) begin
                latched_delay     <= delay;
                latched_width     <= width;
                latched_width_eff <= width_eff;

                if (delay == {DELAY_BITS{1'b0}}) begin
                    pulse_out    <= 1'b1;
                    rise_event   <= 1'b1;
                    rise_pending <= 1'b0;
                    fall_pending <= 1'b1;
                    rise_counter <= {COUNT_BITS{1'b0}};
                    fall_counter <= width_eff_ext - 1'b1;
                end else begin
                    pulse_out    <= 1'b0;
                    rise_pending <= 1'b1;
                    fall_pending <= 1'b0;
                    rise_counter <= delay_ext - 1'b1;
                    fall_counter <= {COUNT_BITS{1'b0}};
                end
            end else begin
                if (rise_pending) begin
                    if (rise_counter == {COUNT_BITS{1'b0}}) begin
                        pulse_out    <= 1'b1;
                        rise_event   <= 1'b1;
                        rise_pending <= 1'b0;
                        fall_pending <= 1'b1;
                        fall_counter <= {{(COUNT_BITS-WIDTH_BITS){1'b0}},
                                         latched_width_eff} - 1'b1;
                    end else begin
                        rise_counter <= rise_counter - 1'b1;
                    end
                end

                if (fall_pending) begin
                    if (fall_counter == {COUNT_BITS{1'b0}}) begin
                        pulse_out    <= 1'b0;
                        fall_event   <= 1'b1;
                        fall_pending <= 1'b0;
                    end else begin
                        fall_counter <= fall_counter - 1'b1;
                    end
                end
            end
        end
    end

endmodule
