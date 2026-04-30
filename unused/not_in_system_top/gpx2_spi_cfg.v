//==============================================================================
// gpx2_spi_cfg.v
//------------------------------------------------------------------------------
// Module: GPX2 SPI Configuration Sequencer
//
// Purpose:
//   Implements a finite-state machine (FSM) to configure the GPX2 TDC chip
//   via SPI interface. This module sends a predetermined sequence of register
//   writes to initialize the GPX2 for LVDS data capture.
//
// Architecture:
//   - SPI bit-bang engine with CPOL=0, CPHA=1 timing
//   - Three-phase configuration sequence: POWER -> WRITE_CONFIG -> INIT
//   - Fixed configuration data (17 registers, cfg[0..16])
//
// Timing:
//   - SCK frequency = sys_clk / (2 * SPI_DIV)
//   - Default SPI_DIV=4 gives SCK = sys_clk/8, safe for GPX2 (<50MHz)
//
// Protocol:
//   - Opcode format: 8-bit command + address/data
//   - OPC_POWER (0x30): Power-on reset
//   - OPC_WCFG0 (0x80): Write config starting at address 0 (auto-increment)
//   - OPC_INIT (0x18): Start measurement
//
// Related Documents:
//   - GPX2 Datasheet Figure 23-30 for register definitions
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.4
//
// Clock Domain:
//   - sys_clk (synchronous to system clock)
//
// Interfaces:
//   - Input: start (trigger configuration sequence)
//   - Output: done (configuration complete), error (reserved), busy
//   - SPI: ssn (active-low chip select), sck, mosi, miso
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module gpx2_spi_cfg #(
    parameter integer SPI_DIV           = 4,    // Clock divider ratio: SCK = sys_clk/(2*SPI_DIV)
                                                // GPX2 requires SCK < 50MHz
    parameter [1:0]   LVDS_VALID_ADJUST = 2'b11 // Addr7[5:4], datasheet Figure 29:
                                                // 00=-160ps, 01=0ps, 10=+160ps, 11=+320ps
)(
    input  wire clk,
    input  wire rst,

    input  wire start,
    output reg  done,
    output reg  busy,
    output reg  error,

    output reg  ssn,
    output reg  sck,
    output reg  mosi,
    input  wire miso
);

    //==========================================================================
    // GPX2 Opcodes (Command Bytes)
    //==========================================================================
    // These opcodes are defined in the GPX2 datasheet for SPI communication.
    // Each opcode initiates a specific operation when written to the SPI interface.
    localparam [7:0] OPC_POWER = 8'h30;  // Power-on reset command
    localparam [7:0] OPC_INIT  = 8'h18;  // Initialize measurement command
    localparam [7:0] OPC_WCFG0 = 8'h80;  // Write config starting at addr 0 (auto-increment)

    //==========================================================================
    // Configuration Registers (17 bytes: addr 0-16)
    //==========================================================================
    // Configuration values based on GPX2 datasheet Figures 23-30.
    // These registers control:
    //   - Pin enables (STOP1-4, REFCLK, LVDS_OUT)
    //   - Hit enables and channel combining
    //   - Resolution mode (HIGH_RESOLUTION)
    //   - Output format (REFID/TSTOP bit widths, DDR mode)
    //   - REFCLK period configuration
    //   - LVDS timing and test patterns
    //
    // IMPORTANT: cfg[3..5] (REFCLK_DIVISIONS) must match actual REFCLK period.
    //            Default value assumes REFCLK period = 100000ps (10MHz).
    //            Formula: divisions = REFCLK_period_in_ps (LSB = 1ps)
    reg [7:0] cfg [0:16];

    integer i;

    //--------------------------------------------------------------------------
    // Configuration Register Initialization
    //--------------------------------------------------------------------------
    // This combinational block defines the GPX2 register values.
    // See GPX2 datasheet for detailed bit field definitions.
    always @(*) begin
        // Addr0: PIN_ENA Register (Figure 23)
        // Bit mapping: D7=RSTIDX, D6=DISABLE, D5=LVDS_OUT, D4=REFCLK, D3-D0=STOP4-1
        // Value 0x3F enables all 4 STOP channels + REFCLK + LVDS output
        cfg[0]  = 8'b0011_1111;

        // Addr1: HIT_ENA + CHANNEL_COMBINE + HIGH_RESOLUTION (Figure 24)
        // D7-D6: HIGH_RESOLUTION = 10 (4x interpolation, ~30ps LSB)
        // D5-D4: CHANNEL_COMBINE = 00 (independent channels)
        // D3-D0: HIT_ENA1-4 = 1111 (all hits enabled)
        cfg[1]  = 8'b10_00_1111;

        // Addr2: Output Format Register (Figure 25)
        // D7: BLOCKWISE_FIFO_READ = 0
        // D6: COMMON_FIFO_READ = 0
        // D5: LVDS_DOUBLE_DATA_RATE = 1 (DDR mode for higher bandwidth)
        // D4-D3: STOP_DATA_BITWIDTH = 11 (20-bit TSTOP field)
        // D2-D0: REF_INDEX_BITWIDTH = 101 (24-bit REFID field)
        cfg[2]  = 8'b0_0_1_11_101;  // = 0x3D

        // Addr3-5: REFCLK_DIVISIONS (Figure 27)
        // 24-bit value representing REFCLK period in picoseconds (LSB = 1ps).
        // Example: 10MHz REFCLK -> period = 100ns = 100000ps = 0x0186A0
        //          cfg[5][2:0] = 0, cfg[4] = 0x86, cfg[3] = 0xA0
        // WARNING: These values MUST be updated for your actual REFCLK frequency!
        cfg[3]  = 8'hA0;  // Low byte of divisions
        cfg[4]  = 8'h86;  // Mid byte
        cfg[5]  = 8'h01;  // Upper bits [2:0] only, high nibble fixed to 0000
                           // Note: Addr5 only uses low 3 bits for upper divisions

        // Addr6: Fixed Bits + LVDS_TEST_PATTERN (Figure 23)
        // D7-D5: Fixed = 110 (required by datasheet)
        // D4: LVDS_TEST_PATTERN = 0 (normal operation, not test pattern)
        // D3-D0: Reserved = 0
        cfg[6]  = 8'b1100_0000;

        // Addr7: LVDS_DATA_VALID_ADJUST + REFCLK_BY_XOSC (Figure 29)
        // D7: Reserved = 0
        // D6: Fixed = 1 (required)
        // D5-D4: LVDS_DATA_VALID_ADJUST sets the source-side data delay. Default
        //        is +320ps to increase hold margin at the FPGA receiver.
        // D3-D0: Fixed = 0011 (required)
        // REFCLK_BY_XOSC = 0 (use external REFCLK, not internal XOSC)
        cfg[7]  = {1'b0, 1'b1, LVDS_VALID_ADJUST, 4'b0011};

        // Addr8-15: Reserved/Fixed Values (Figure 23)
        // These are manufacturer-recommended fixed values from GPX2 datasheet.
        cfg[8]  = 8'hA1;
        cfg[9]  = 8'h13;
        cfg[10] = 8'h00;
        cfg[11] = 8'h0A;
        cfg[12] = 8'hCC;
        cfg[13] = 8'hCC;
        cfg[14] = 8'hF1;
        cfg[15] = 8'h7D;

        // Addr16: CMOS_INPUT Configuration (Figure 30)
        // D0: CMOS_INPUT = 0 (LVDS differential input mode)
        // D7-D1: Reserved = 0
        cfg[16] = 8'h00;
    end

    //==========================================================================
    // SPI Bit-Bang Engine
    //==========================================================================
    // Implements SPI master with CPOL=0, CPHA=1 timing:
    //   - SCK idles LOW (CPOL=0)
    //   - MOSI changes on rising edge, sampled on falling edge (CPHA=1)
    //   - GPX2 samples MOSI on falling edge of SCK
    //
    // Clock generation:
    //   - div_cnt counts from 0 to SPI_DIV-1 for each half-cycle
    //   - SCK toggles when div_cnt wraps, giving period = 2*SPI_DIV*clk_period
    //
    // Data shifting:
    //   - shifter holds current byte being transmitted
    //   - bit_idx counts from 7 down to 0 (MSB first)
    //   - byte_done pulses high when all 8 bits are transmitted
    //==========================================================================

    reg [15:0] div_cnt;       // Clock divider counter for SCK generation
    reg        sck_en;        // SCK enable (active during transmission)

    reg [7:0]  shifter;       // MOSI data shift register
    reg [2:0]  bit_idx;      // Current bit position (7=MSB, 0=LSB)

    reg [7:0]  seq_byte;      // Byte to be loaded into shifter
    reg        load_byte;     // Pulse: load seq_byte into shifter
    reg        byte_done;     // Pulse: 8-bit transmission complete

    //==========================================================================
    // Configuration FSM States
    //==========================================================================
    // ST_IDLE:  Waiting for start command
    // ST_POWER: Sending OPC_POWER (0x30) - power-on reset sequence
    // ST_WOPC:  Sending opcode for config write (0x80)
    // ST_WDATA: Sending 17 config bytes (cfg[0] to cfg[16])
    // ST_INIT:  Sending OPC_INIT (0x18) - start measurement
    // ST_DONE:  Transmission complete
    //==========================================================================
    localparam ST_IDLE   = 0;
    localparam ST_POWER  = 1;
    localparam ST_WOPC   = 2;
    localparam ST_WDATA  = 3;
    localparam ST_INIT   = 4;
    localparam ST_DONE   = 5;

    reg [2:0] state;          // Current FSM state
    reg [5:0] cfg_idx;        // Config byte index (0-16)

    //--------------------------------------------------------------------------
    // SCK Clock Generator
    //--------------------------------------------------------------------------
    // Generates SCK by dividing sys_clk. SCK toggles every SPI_DIV cycles.
    // When sck_en=0, SCK is held LOW (CPOL=0 idle state).
    always @(posedge clk) begin
        if (rst) begin
            div_cnt <= 0;
            sck     <= 1'b0;
        end else if (sck_en) begin
            if (div_cnt == SPI_DIV-1) begin
                div_cnt <= 0;
                sck     <= ~sck;
            end else begin
                div_cnt <= div_cnt + 1;
            end
        end else begin
            div_cnt <= 0;
            sck     <= 1'b0;
        end
    end

    //--------------------------------------------------------------------------
    // MOSI Data Shifter
    //--------------------------------------------------------------------------
    // Manages serial data output with CPHA=1 timing:
    //   - On load_byte: load new byte, output MSB immediately
    //   - On SCK rising edge: prepare next bit on MOSI
    //   - On SCK falling edge: decrement bit_idx, signal done at bit_idx=0
    always @(posedge clk) begin
        if (rst) begin
            shifter   <= 8'h00;
            bit_idx   <= 3'd7;
            mosi      <= 1'b0;
            byte_done <= 1'b0;
        end else begin
            byte_done <= 1'b0;

            if (load_byte) begin
                // Load new byte and set up MSB on MOSI
                shifter <= seq_byte;
                bit_idx <= 3'd7;
                mosi    <= seq_byte[7];  // Output MSB immediately
            end else if (sck_en) begin
                // Detect rising edge: div_cnt wraps AND sck==0 means next tick is rising
                if (div_cnt == SPI_DIV-1 && sck == 1'b0) begin
                    // Rising edge: prepare next bit (CPHA=1 timing)
                    if (bit_idx != 3'd0) begin
                        mosi <= shifter[bit_idx-1];  // Shift out next bit
                    end
                end

                // Detect falling edge: div_cnt wraps AND sck==1
                if (div_cnt == SPI_DIV-1 && sck == 1'b1) begin
                    // Falling edge: GPX2 samples MOSI here
                    if (bit_idx == 3'd0) begin
                        byte_done <= 1'b1;  // Byte transmission complete
                    end else begin
                        bit_idx <= bit_idx - 1'b1;  // Move to next bit
                    end
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Main Configuration Sequence FSM
    //--------------------------------------------------------------------------
    // Executes the GPX2 initialization sequence:
    //   1. POWER command (0x30): Trigger power-on reset
    //   2. WRITE_CONFIG (0x80 + addr): Write all 17 config registers
    //   3. INIT command (0x18): Start measurement mode
    //
    // SSN is deasserted (HIGH) between commands to create separate transactions.
    // This ensures GPX2 recognizes each command properly.
    always @(posedge clk) begin
        if (rst) begin
            ssn      <= 1'b1;           // SSN inactive (HIGH)
            sck_en   <= 1'b0;           // SCK disabled
            done     <= 1'b0;
            busy     <= 1'b0;
            error    <= 1'b0;
            state    <= ST_IDLE;
            cfg_idx  <= 6'd0;
            load_byte<= 1'b0;
            seq_byte <= 8'h00;
        end else begin
            load_byte <= 1'b0;          // Default: no byte load
            done      <= 1'b0;          // Default: not done

            case (state)
                //------------------------------------------------------------------
                // ST_IDLE: Wait for start command
                //------------------------------------------------------------------
                ST_IDLE: begin
                    busy   <= 1'b0;     // Not busy when idle
                    error  <= 1'b0;
                    ssn    <= 1'b1;     // SSN inactive
                    sck_en <= 1'b0;     // SCK disabled
                    cfg_idx<= 6'd0;     // Reset config index
                    if (start) begin
                        // Start configuration sequence
                        busy     <= 1'b1;
                        ssn      <= 1'b0;       // Assert SSN (active LOW)
                        sck_en   <= 1'b1;       // Enable SCK
                        seq_byte <= OPC_POWER;   // First: power-on reset
                        load_byte<= 1'b1;       // Load into shifter
                        state    <= ST_POWER;
                    end
                end

                //------------------------------------------------------------------
                // ST_POWER: Send power-on reset command (0x30)
                //------------------------------------------------------------------
                ST_POWER: begin
                    if (byte_done) begin
                        // Power command sent, deassert SSN briefly
                        ssn    <= 1'b1;       // End transaction
                        sck_en <= 1'b0;       // Stop clock
                        state  <= ST_WOPC;    // Next: write config opcode
                    end
                end

                //------------------------------------------------------------------
                // ST_WOPC: Send write-config opcode (0x80)
                //------------------------------------------------------------------
                ST_WOPC: begin
                    // Start new transaction for config write
                    ssn      <= 1'b0;               // Assert SSN
                    sck_en   <= 1'b1;               // Enable SCK
                    seq_byte <= OPC_WCFG0;          // Write config @ addr 0
                    load_byte<= 1'b1;
                    cfg_idx  <= 6'd0;
                    state    <= ST_WDATA;
                end

                //------------------------------------------------------------------
                // ST_WDATA: Send 17 configuration bytes (cfg[0] to cfg[16])
                //------------------------------------------------------------------
                ST_WDATA: begin
                    if (byte_done) begin
                        if (cfg_idx == 6'd0) begin
                            // Opcode sent, now send cfg[0]
                            seq_byte  <= cfg[0];
                            load_byte <= 1'b1;
                            cfg_idx   <= 6'd1;
                        end else if (cfg_idx <= 16) begin
                            // Continue sending cfg[cfg_idx]
                            seq_byte  <= cfg[cfg_idx];
                            load_byte <= 1'b1;
                            cfg_idx   <= cfg_idx + 1'b1;
                        end else begin
                            // All 17 config bytes sent
                            ssn    <= 1'b1;       // End transaction
                            sck_en <= 1'b0;
                            state  <= ST_INIT;    // Next: init command
                        end
                    end
                end

                //------------------------------------------------------------------
                // ST_INIT: Send INIT command (0x18) to start measurement
                //------------------------------------------------------------------
                ST_INIT: begin
                    ssn      <= 1'b0;       // Assert SSN
                    sck_en   <= 1'b1;       // Enable SCK
                    seq_byte <= OPC_INIT;   // Init measurement
                    load_byte<= 1'b1;
                    state    <= ST_DONE;
                end

                //------------------------------------------------------------------
                // ST_DONE: Wait for final byte to complete
                //------------------------------------------------------------------
                ST_DONE: begin
                    if (byte_done) begin
                        ssn    <= 1'b1;       // Deassert SSN
                        sck_en <= 1'b0;       // Stop clock
                        done   <= 1'b1;       // Signal completion
                        busy   <= 1'b0;       // No longer busy
                        state  <= ST_IDLE;    // Return to idle
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
