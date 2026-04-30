//==============================================================================
// gpx2_lvds_rx.v
//------------------------------------------------------------------------------
// Module: GPX2 LVDS Data Receiver
//
// Purpose:
//   Receives serialized event data from a single GPX2 TDC channel via LVDS.
//   Performs DDR/SDR sampling, frame detection, and bit-assembly to produce
//   complete event records (REFID + TSTOP).
//
// Architecture:
//   - IDDR primitive for DDR sampling (or SDR falling-edge sampling)
//   - Frame-based packet detection (FRAME signal delineates event boundaries)
//   - Shift register for bit assembly
//   - Event output: 44-bit {REFID[23:0], TSTOP[19:0]}
//
// Timing:
//   - lclk_io: Fast I/O clock for IDDR sampling (BUFIO)
//   - lclk_logic: Logic clock for state machine (BUFR-divided or same)
//   - GPX2 outputs data synchronously with LCLKOUT (same as LCLKIN)
//
// Data Format (44 bits per event):
//   | REFID[23:0] | TSTOP[19:0] |
//   |   24 bits   |   20 bits   |
//   MSB first in serial stream
//
// DDR Mode (USE_DDR=1):
//   - Data captured on both rising and falling edges of LCLK
//   - 2 bits per clock cycle
//   - Frame signal also DDR-sampled
//
// SDR Mode (USE_DDR=0):
//   - Data captured on falling edge only (per GPX2 datasheet for SDR mode)
//   - 1 bit per clock cycle
//
// Related Documents:
//   - GPX2 Datasheet Section: LVDS Serial Output Interface
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.3
//
// Clock Domain:
//   - lclk_logic (GPX2 output clock domain)
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module gpx2_lvds_rx #(
    parameter integer REFID_BITS = 24,   // Reference ID width (default 24 bits)
    parameter integer TSTOP_BITS = 20,   // Time-of-stop width (default 20 bits)
    parameter integer USE_DDR    = 1,    // 1=DDR mode, 0=SDR mode
    parameter integer EVENT_BITS = REFID_BITS + TSTOP_BITS  // Total event width (44 bits)
)(
    input  wire                  lclk_io,      // Fast I/O clock for IDDR (from BUFIO)
    input  wire                  lclk_logic,   // Logic clock for state machine (from BUFR)
    input  wire                  rst_lclk,     // Reset synchronized to lclk_logic domain

    input  wire                  sdo_in,       // Serial data input (single-ended, from IBUFDS)
    input  wire                  frame_in,     // Frame marker input (single-ended, from IBUFDS)

    output reg                   event_valid,  // Pulse: valid event data available
    output reg  [EVENT_BITS-1:0] event_data    // Captured event: {REFID, TSTOP}
);

    //==========================================================================
    // DDR/SDR Sampling Selection
    //==========================================================================
    // GPX2 outputs serial data synchronized to LCLKOUT (same as LCLKIN input).
    //
    // DDR Mode (USE_DDR=1):
    //   - Data and frame are clocked on BOTH edges of LCLK
    //   - IDDR primitive captures rising-edge data (Q1) and falling-edge data (Q2)
    //   - 2 bits per clock cycle, double throughput
    //
    // SDR Mode (USE_DDR=0):
    //   - Data and frame are clocked on FALLING edge only (per datasheet)
    //   - Simple register sampling on negedge lclk_logic
    //   - 1 bit per clock cycle
    //==========================================================================
    wire sdo_rise, sdo_fall;    // DDR: data captured on rising/falling edges
    wire frm_rise, frm_fall;    // DDR: frame captured on rising/falling edges

    generate
        if (USE_DDR) begin : G_DDR
            wire sdo_q1, sdo_q2;
            wire frm_q1, frm_q2;
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .SRTYPE("SYNC")
            ) u_iddr_sdo (
                .C  (lclk_io),
                .CE (1'b1),
                .D  (sdo_in),
                .R  (1'b0),
                .S  (1'b0),
                .Q1 (sdo_q1),
                .Q2 (sdo_q2)
            );

            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .SRTYPE("SYNC")
            ) u_iddr_frm (
                .C  (lclk_io),
                .CE (1'b1),
                .D  (frame_in),
                .R  (1'b0),
                .S  (1'b0),
                .Q1 (frm_q1),
                .Q2 (frm_q2)
            );
            assign sdo_rise = sdo_q1;
            assign sdo_fall = sdo_q2;
            assign frm_rise = frm_q1;
            assign frm_fall = frm_q2;
        end else begin : G_SDR
            // SDR: sample on falling edge per datasheet
            reg sdo_r, frm_r;
            always @(negedge lclk_logic) begin
                if (rst_lclk) begin
                    sdo_r <= 1'b0;
                    frm_r <= 1'b0;
                end else begin
                    sdo_r <= sdo_in;
                    frm_r <= frame_in;
                end
            end
            assign sdo_rise = 1'b0;
            assign sdo_fall = sdo_r;
            assign frm_rise = 1'b0;
            assign frm_fall = frm_r;
        end
    endgenerate

    //==========================================================================
    // Event Capture State Machine
    //==========================================================================
    // Detects FRAME rising edge and captures EVENT_BITS serial data.
    //
    // GPX2 LVDS Protocol:
    //   - FRAME signal goes HIGH at start of each event
    //   - First data bit (MSB) is sampled on same clock edge as FRAME rising
    //   - Remaining bits follow sequentially
    //   - Total bits = REFID_BITS + TSTOP_BITS (default 44 bits)
    //
    // DDR Mode Processing:
    //   - Each lclk_logic cycle delivers 2 bits: {fall_bit, rise_bit}
    //   - Loop processes bits in order: [1-n] index selects fall then rise
    //   - Frame detection checks both edges
    //
    // State Variables:
    //   - shreg:     Shift register accumulating event bits
    //   - bit_cnt:   Count of bits captured so far
    //   - capturing: Flag indicating active event capture
    //   - prev_frm:  Previous frame bit for edge detection
    //==========================================================================

    reg [EVENT_BITS-1:0] shreg;                         // Shift register for bit assembly
    reg [$clog2(EVENT_BITS+1)-1:0] bit_cnt;             // Bits captured counter
    reg capturing;                                       // Active capture flag
    reg prev_frm_bit;                                    // Previous frame value for edge detect

    // Next-state variables for combinatorial logic within sequential block
    reg [EVENT_BITS-1:0] shreg_next;
    reg [$clog2(EVENT_BITS+1)-1:0] bit_cnt_next;
    reg capturing_next;
    reg prev_frm_bit_next;
    reg event_valid_next;
    reg [EVENT_BITS-1:0] event_data_next;

    // Bit packing: DDR mode yields 2 bits/cycle, SDR yields 1 bit/cycle.
    // The loop below indexes [1-n], so bit 1 is processed first.
    // DDR order is rising-edge bit first, then falling-edge bit.
    // SDR uses the falling-edge sample as its only processed bit.
    wire [1:0] sdo_bits = (USE_DDR != 0) ? {sdo_rise, sdo_fall} : {sdo_fall, 1'b0};
    wire [1:0] frm_bits = (USE_DDR != 0) ? {frm_rise, frm_fall} : {frm_fall, 1'b0};

    // Function to determine bits per clock cycle
    function integer step_bits;
        input integer use_ddr;
        begin
            step_bits = (use_ddr != 0) ? 2 : 1;
        end
    endfunction

    integer n;          // Loop index for bit processing
    reg frm_b;          // Current frame bit being processed
    reg sdo_b;          // Current data bit being processed

    //--------------------------------------------------------------------------
    // Main State Machine (posedge lclk_logic)
    //--------------------------------------------------------------------------
    // Processes incoming bits one at a time within each clock cycle.
    // For DDR mode, the inner loop runs twice per cycle.
    //--------------------------------------------------------------------------

    always @(posedge lclk_logic) begin
        if (rst_lclk) begin
            shreg        <= {EVENT_BITS{1'b0}};
            bit_cnt      <= 0;
            capturing    <= 1'b0;
            event_valid  <= 1'b0;
            event_data   <= {EVENT_BITS{1'b0}};
            prev_frm_bit <= 1'b0;
        end else begin
            shreg_next        = shreg;
            bit_cnt_next      = bit_cnt;
            capturing_next    = capturing;
            prev_frm_bit_next = prev_frm_bit;
            event_valid_next  = 1'b0;
            event_data_next   = event_data;

            for (n = 0; n < step_bits(USE_DDR); n = n + 1) begin
                frm_b = frm_bits[1-n];
                sdo_b = sdo_bits[1-n];

                if (!event_valid_next) begin
                    if (!capturing_next) begin
                        if ((prev_frm_bit_next == 1'b0) && (frm_b == 1'b1)) begin
                            capturing_next = 1'b1;
                            shreg_next     = {EVENT_BITS{1'b0}};
                            shreg_next     = {shreg_next[EVENT_BITS-2:0], sdo_b};
                            if (EVENT_BITS == 1) begin
                                capturing_next  = 1'b0;
                                event_valid_next = 1'b1;
                                event_data_next  = shreg_next;
                                bit_cnt_next     = 0;
                            end else begin
                                bit_cnt_next = 1;
                            end
                        end
                    end else begin
                        shreg_next = {shreg_next[EVENT_BITS-2:0], sdo_b};
                        if (bit_cnt_next == EVENT_BITS-1) begin
                            capturing_next   = 1'b0;
                            event_valid_next = 1'b1;
                            event_data_next  = shreg_next;
                            bit_cnt_next     = 0;
                        end else begin
                            bit_cnt_next = bit_cnt_next + 1'b1;
                        end
                    end
                end

                prev_frm_bit_next = frm_b;
            end

            shreg        <= shreg_next;
            bit_cnt      <= bit_cnt_next;
            capturing    <= capturing_next;
            prev_frm_bit <= prev_frm_bit_next;
            event_valid  <= event_valid_next;
            event_data   <= event_data_next;
        end
    end
endmodule
