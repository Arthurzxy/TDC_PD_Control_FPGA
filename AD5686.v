//==============================================================================
// AD5686.v
//------------------------------------------------------------------------------
// Module: AD5686 4-Channel 16-bit DAC Driver
//
// Purpose:
//   Serial SPI interface driver for AD5686 quad 16-bit DAC.
//   Updates all 4 channels in a single transaction when triggered.
//
// Architecture:
//   - FSM-based SPI bit-bang engine
//   - Sequential update of all 4 DAC channels
//   - Channel addressing encoded in command bits
//   - 24-bit SPI frame: 8-bit command + 16-bit data per channel
//
// SPI Protocol:
//   - Command byte: [A1:A0][DACC:DACA][0:0][CMD2:CMD0]
//   - Channel addresses: 00=A, 01=B, 10=C, 11=D
//   - Data follows MSB first
//
// Timing:
//   - Clock: 20 MHz typical (clk input)
//   - 348 clock cycles for complete 4-channel update
//   - CS asserted LOW during transmission
//
// Clock Domain:
//   - clk (typically 20 MHz, shared with ADC/TEC control)
//
// Interfaces:
//   - start: Trigger to begin update sequence
//   - data1-4_in: 16-bit values for channels A-D
//   - SPI outputs: dac_clk, dac_din, dac_cs
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

module AD5686(
    //==========================================================================
    // Clock and Control
    //==========================================================================
    input clk,              // 20 MHz clock input
    input start,            // Trigger to begin DAC update sequence

    //==========================================================================
    // DAC Data Inputs (16-bit per channel)
    //==========================================================================
    input [15:0] data1_in,  // Channel A data
    input [15:0] data2_in,  // Channel B data
    input [15:0] data3_in,  // Channel C data
    input [15:0] data4_in,  // Channel D data

    //==========================================================================
    // SPI Interface to AD5686
    //==========================================================================
    output reg dac_clk,      // SPI clock output
    output reg dac_din,      // SPI data output (MOSI)
    output reg dac_cs        // Chip select (active LOW)
);

    //--------------------------------------------------------------------------
    // Internal State
    //--------------------------------------------------------------------------
    reg busy;               // Transaction in progress
    reg [15:0] k;           // Clock cycle counter (0-348)
    reg [15:0] data1;       // Latched channel A data
    reg [15:0] data2;       // Latched channel B data
    reg [15:0] data3;       // Latched channel C data
    reg [15:0] data4;       // Latched channel D data

    //--------------------------------------------------------------------------
    // SPI Transaction Engine
    //--------------------------------------------------------------------------
    // Sequence:
    //   1. Latch data on start trigger
    //   2. Send 24 bits for Channel A (cmd 0x00 + data1)
    //   3. CS high gap (cycles 48-99)
    //   4. Send 24 bits for Channel B (cmd 0x10 + data2)
    //   5. CS high gap (cycles 148-199)
    //   6. Send 24 bits for Channel C (cmd 0x20 + data3)
    //   7. CS high gap (cycles 248-299)
    //   8. Send 24 bits for Channel D (cmd 0x30 + data4)
    //   9. Complete, release busy
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (start & (!busy)) begin
            // Start new transaction: latch input data
            k     <= 16'd0;
            busy  <= 1'd1;
            data1 <= data1_in;
            data2 <= data2_in;
            data3 <= data3_in;
            data4 <= data4_in;
        end else begin
            // CS high gaps between channels (50 cycles each)
            if ((k >= 48 && k < 100) || (k >= 148 && k < 200) ||
                (k >= 248 && k < 300)) begin
                k      <= k + 16'd1;
                dac_cs <= 1'd1;      // CS HIGH during gaps
            end else if (k < 348) begin
                k      <= k + 16'd1;
                dac_cs <= 1'd0;      // CS LOW during transmission
            end else begin
                dac_cs <= 1'd1;      // CS HIGH after complete
                busy  <= 1'd0;       // Release busy flag
            end

            // SPI clock generation: LOW on even k, HIGH on odd k
            case (k[0])
                1'd0: dac_clk <= 1'd1;
                1'd1: dac_clk <= 1'd0;
            endcase

            // Data bit shifting: MSB first per channel
            // Command format: [A1:A0=channel][DACC:DACA=11][0:0][CMD=01]
            case (k)
                // Channel A: cmd 0x00 (address 00) + data1[15:0]
                0:  dac_din <= 1'd0;        // cmd[7]
                2:  dac_din <= 1'd0;        // cmd[6]
                4:  dac_din <= 1'd1;        // cmd[5] = DACC
                6:  dac_din <= 1'd1;        // cmd[4] = DACA
                8:  dac_din <= 1'd0;        // cmd[3]
                10: dac_din <= 1'd0;        // cmd[2]
                12: dac_din <= 1'd0;        // cmd[1]
                14: dac_din <= 1'd1;        // cmd[0] = write command
                16: dac_din <= data1[15];   // data1[15]
                18: dac_din <= data1[14];
                20: dac_din <= data1[13];
                22: dac_din <= data1[12];
                24: dac_din <= data1[11];
                26: dac_din <= data1[10];
                28: dac_din <= data1[9];
                30: dac_din <= data1[8];
                32: dac_din <= data1[7];
                34: dac_din <= data1[6];
                36: dac_din <= data1[5];
                38: dac_din <= data1[4];
                40: dac_din <= data1[3];
                42: dac_din <= data1[2];
                44: dac_din <= data1[1];
                46: dac_din <= data1[0];    // data1[0]
                48: dac_din <= 1'd0;        // End channel A

                // Channel B: cmd 0x10 (address 01) + data2[15:0]
                100: dac_din <= 1'd0;       // cmd[7]
                102: dac_din <= 1'd0;       // cmd[6]
                104: dac_din <= 1'd1;       // cmd[5] = DACC
                106: dac_din <= 1'd1;       // cmd[4] = DACA
                108: dac_din <= 1'd0;       // cmd[3]
                110: dac_din <= 1'd1;       // cmd[2] = A0=1
                112: dac_din <= 1'd0;       // cmd[1]
                114: dac_din <= 1'd0;       // cmd[0]
                116: dac_din <= data2[15];  // data2[15]
                118: dac_din <= data2[14];
                120: dac_din <= data2[13];
                122: dac_din <= data2[12];
                124: dac_din <= data2[11];
                126: dac_din <= data2[10];
                128: dac_din <= data2[9];
                130: dac_din <= data2[8];
                132: dac_din <= data2[7];
                134: dac_din <= data2[6];
                136: dac_din <= data2[5];
                138: dac_din <= data2[4];
                140: dac_din <= data2[3];
                142: dac_din <= data2[2];
                144: dac_din <= data2[1];
                146: dac_din <= data2[0];   // data2[0]
                148: dac_din <= 1'd0;       // End channel B

                // Channel C: cmd 0x20 (address 10) + data3[15:0]
                200: dac_din <= 1'd0;       // cmd[7]
                202: dac_din <= 1'd0;       // cmd[6]
                204: dac_din <= 1'd1;       // cmd[5] = DACC
                206: dac_din <= 1'd1;       // cmd[4] = DACA
                208: dac_din <= 1'd0;       // cmd[3]
                210: dac_din <= 1'd1;       // cmd[2] = A1=1
                212: dac_din <= 1'd0;       // cmd[1]
                214: dac_din <= 1'd0;       // cmd[0]
                216: dac_din <= data3[15];  // data3[15]
                218: dac_din <= data3[14];
                220: dac_din <= data3[13];
                222: dac_din <= data3[12];
                224: dac_din <= data3[11];
                226: dac_din <= data3[10];
                228: dac_din <= data3[9];
                230: dac_din <= data3[8];
                232: dac_din <= data3[7];
                234: dac_din <= data3[6];
                236: dac_din <= data3[5];
                238: dac_din <= data3[4];
                240: dac_din <= data3[3];
                242: dac_din <= data3[2];
                244: dac_din <= data3[1];
                246: dac_din <= data3[0];   // data3[0]
                248: dac_din <= 1'd0;       // End channel C

                // Channel D: cmd 0x30 (address 11) + data4[15:0]
                300: dac_din <= 1'd0;       // cmd[7]
                302: dac_din <= 1'd0;       // cmd[6]
                304: dac_din <= 1'd1;       // cmd[5] = DACC
                306: dac_din <= 1'd1;       // cmd[4] = DACA
                308: dac_din <= 1'd1;       // cmd[3] = A1
                310: dac_din <= 1'd0;       // cmd[2]
                312: dac_din <= 1'd0;       // cmd[1]
                314: dac_din <= 1'd0;       // cmd[0]
                316: dac_din <= data4[15];   // data4[15]
                318: dac_din <= data4[14];
                320: dac_din <= data4[13];
                322: dac_din <= data4[12];
                324: dac_din <= data4[11];
                326: dac_din <= data4[10];
                328: dac_din <= data4[9];
                330: dac_din <= data4[8];
                332: dac_din <= data4[7];
                334: dac_din <= data4[6];
                336: dac_din <= data4[5];
                338: dac_din <= data4[4];
                340: dac_din <= data4[3];
                342: dac_din <= data4[2];
                344: dac_din <= data4[1];
                346: dac_din <= data4[0];   // data4[0]
                348: dac_din <= 1'd0;       // End channel D
            endcase
        end
    end

endmodule