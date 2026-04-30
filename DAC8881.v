//==============================================================================
// DAC8881.v
//------------------------------------------------------------------------------
// Module: DAC8881 16-bit SPI DAC Driver
//
// Purpose:
//   Single-channel 16-bit DAC driver for TEC (Thermoelectric Cooler) control.
//   Simple SPI interface with single transaction per update.
//
// Architecture:
//   - FSM-based SPI bit-bang engine
//   - 16-bit data transmitted MSB first
//   - 32 clock cycles per transaction
//
// SPI Protocol:
//   - CS asserted LOW during transmission
//   - Clock: LOW on even cycles, HIGH on odd cycles
//   - Data: MSB first, 16 bits
//
// Timing:
//   - Clock: 20 MHz typical (clk input)
//   - 32 clock cycles per update
//
// Clock Domain:
//   - clk (typically 20 MHz)
//
// Interfaces:
//   - start: Trigger to begin update
//   - datain[15:0]: DAC value
//   - SPI outputs: dac8881_clk, dac8881_din, dac8881_cs
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

module DAC8881(
    //==========================================================================
    // Clock and Control
    //==========================================================================
    input clk,              // 20 MHz clock input
    input start,            // Trigger to begin DAC update

    //==========================================================================
    // DAC Data Input
    //==========================================================================
    input [15:0] datain,    // 16-bit DAC value

    //==========================================================================
    // SPI Interface to DAC8881
    //==========================================================================
    output reg dac8881_clk,  // SPI clock output
    output reg dac8881_din,   // SPI data output (MOSI)
    output reg dac8881_cs     // Chip select (active LOW)
);

    //--------------------------------------------------------------------------
    // Internal State
    //--------------------------------------------------------------------------
    reg busy;               // Transaction in progress
    reg [7:0] k;            // Clock cycle counter (0-32)
    reg [15:0] data;        // Latched data value

    //--------------------------------------------------------------------------
    // SPI Transaction Engine
    //--------------------------------------------------------------------------
    // Sequence:
    //   1. Latch data on start trigger
    //   2. Transmit 16 bits MSB first
    //   3. Complete transaction, release busy
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (start & (!busy)) begin
            // Start new transaction: latch input data
            k     <= 8'd0;
            busy  <= 1'd1;
            data  <= datain;
        end else begin
            if (k < 32) begin
                k      <= k + 8'd1;
                dac8881_cs <= 1'd0;      // CS LOW during transmission
            end else begin
                dac8881_cs <= 1'd1;      // CS HIGH after complete
                busy  <= 1'd0;           // Release busy flag
            end

            // SPI clock: LOW on even k, HIGH on odd k
            case (k)
                0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32:
                    dac8881_clk <= 1'd0;
                default:
                    dac8881_clk <= 1'd1;
            endcase

            // Data bit shifting: MSB first
            case (k)
                0:  dac8881_din <= data[15];   // data[15] (MSB)
                2:  dac8881_din <= data[14];
                4:  dac8881_din <= data[13];
                6:  dac8881_din <= data[12];
                8:  dac8881_din <= data[11];
                10: dac8881_din <= data[10];
                12: dac8881_din <= data[9];
                14: dac8881_din <= data[8];
                16: dac8881_din <= data[7];
                18: dac8881_din <= data[6];
                20: dac8881_din <= data[5];
                22: dac8881_din <= data[4];
                24: dac8881_din <= data[3];
                26: dac8881_din <= data[2];
                28: dac8881_din <= data[1];
                30: dac8881_din <= data[0];    // data[0] (LSB)
                32: dac8881_din <= 1'd0;       // End transmission
            endcase
        end
    end

endmodule