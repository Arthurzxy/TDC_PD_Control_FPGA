//==============================================================================
// NB6L295_extend.v
//------------------------------------------------------------------------------
// Module: NB6L295 Programmable Delay Chip Driver
//
// Purpose:
//   Configures the NB6L295 dual-channel programmable delay chip via SPI.
//   Each channel has independent delay control (0-511 steps).
//
// Architecture:
//   - FSM-based SPI bit-bang engine
//   - Dual-channel configuration in single transaction
//   - 11-bit data per channel (9-bit delay + 2 control bits)
//
// SPI Protocol:
//   - Data format: 11 bits per channel
//     - data_a[10:0] = {delay_a[8:0], 1'b1, 1'b0}  // Channel A
//     - data_b[10:0] = {delay_b[8:0], 1'b1, 1'b1}  // Channel B
//   - SLOAD pulse after each channel's data
//   - Total: 54 clock cycles (22 data bits + control)
//
// Timing:
//   - Clock: System clock (clk input)
//   - 54 clock cycles per configuration
//
// Control Signals:
//   - start: Begin configuration sequence
//   - enable: Latch mode (direct enable output)
//   - en: Chip enable output
//   - SDIN/SCLK/SLOAD: SPI interface
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

module NB6L295_extend(
    //==========================================================================
    // Clock and Control
    //==========================================================================
    input clk,              // System clock
    input start,            // Trigger to begin configuration
    input enable,           // Latch mode enable (direct output control)

    //==========================================================================
    // Delay Configuration Inputs
    //==========================================================================
    input [8:0] delay_a,    // Channel A delay value (0-511 steps)
    input [8:0] delay_b,    // Channel B delay value (0-511 steps)
    input enable_input,     // Enable input (unused, for compatibility)

    //==========================================================================
    // SPI Interface to NB6L295
    //==========================================================================
    output reg en,          // Chip enable
    output reg SDIN,        // SPI data input
    output reg SCLK,        // SPI clock
    output reg SLOAD        // Load strobe (active HIGH)
);

    //--------------------------------------------------------------------------
    // Internal State
    //--------------------------------------------------------------------------
    reg [10:0] data_a;      // Channel A data: {delay, 1, 0}
    reg [10:0] data_b;      // Channel B data: {delay, 1, 1}
    reg [7:0] k;            // Clock cycle counter
    reg busy;               // Configuration in progress

    //--------------------------------------------------------------------------
    // SPI Transaction Engine
    //--------------------------------------------------------------------------
    // Sequence:
    //   1. Format data: {delay_a, 1'b1, 1'b0} and {delay_b, 1'b1, 1'b1}
    //   2. Transmit Channel A (11 bits) with SLOAD pulse
    //   3. Transmit Channel B (11 bits) with SLOAD pulse
    //   4. Complete, release busy
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (start && !busy) begin
            // Start configuration: format data words
            k      <= 8'd0;
            en     <= 1'd0;
            SDIN   <= 1'd0;
            SCLK   <= 1'd0;
            SLOAD  <= 1'd0;
            data_a <= {delay_a, 1'd1, 1'd0};  // Channel A: delay + control bits
            data_b <= {delay_b, 1'd1, 1'd1};  // Channel B: delay + control bits
            busy   <= 1'd1;
        end else if (enable) begin
            // Enable/latch mode: direct enable output
            k      <= 8'd0;
            en     <= 1'd1;
            SDIN   <= 1'd0;
            SCLK   <= 1'd0;
            SLOAD  <= 1'd0;
            data_a <= 11'd0;
            data_b <= 11'd0;
            busy   <= 1'd0;
        end else if (busy) begin
            // Configuration sequence
            if (k > 8'd54) begin
                busy <= 1'd0;           // Complete
            end else begin
                k <= k + 8'd1;          // Advance counter
            end

            // SPI clock generation: LOW on even, HIGH on odd
            // Channel A: cycles 0-22
            case (k)
                0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22:
                    SCLK <= 1'd0;
                1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21:
                    SCLK <= 1'd1;
                // Channel B: cycles 30-52
                30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52:
                    SCLK <= 1'd0;
                31, 33, 35, 37, 39, 41, 43, 45, 47, 49, 51:
                    SCLK <= 1'd1;
            endcase

            // SLOAD pulse: HIGH at cycle 23 and 53, LOW at cycle 24 and 54
            case (k)
                23, 53: SLOAD <= 1'd1;
                24, 54: SLOAD <= 1'd0;
            endcase

            // Data shifting: Channel A (cycles 0-20), then Channel B (cycles 30-50)
            case (k)
                // Channel A data: bits [0] through [10]
                0:  SDIN <= data_a[0];
                2:  SDIN <= data_a[1];
                4:  SDIN <= data_a[2];
                6:  SDIN <= data_a[3];
                8:  SDIN <= data_a[4];
                10: SDIN <= data_a[5];
                12: SDIN <= data_a[6];
                14: SDIN <= data_a[7];
                16: SDIN <= data_a[8];
                18: SDIN <= data_a[9];
                20: SDIN <= data_a[10];    // End Channel A
                // Channel B data: bits [0] through [10]
                30: SDIN <= data_b[0];
                32: SDIN <= data_b[1];
                34: SDIN <= data_b[2];
                36: SDIN <= data_b[3];
                38: SDIN <= data_b[4];
                40: SDIN <= data_b[5];
                42: SDIN <= data_b[6];
                44: SDIN <= data_b[7];
                46: SDIN <= data_b[8];
                48: SDIN <= data_b[9];
                50: SDIN <= data_b[10];   // End Channel B
            endcase
        end else begin
            // Idle state: all outputs LOW
            k      <= 8'd0;
            en     <= 1'd0;
            SDIN   <= 1'd0;
            SCLK   <= 1'd0;
            SLOAD  <= 1'd0;
        end
    end

endmodule