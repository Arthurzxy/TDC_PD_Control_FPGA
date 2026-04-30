//==============================================================================
// Counter.v
//------------------------------------------------------------------------------
// Module: SPAD Event Counter with 1-Second Window
// 模块说明：SPAD 雪崩脉冲计数器
//
// Purpose:
// 中文说明：
//   该模块把外部异步的 SPAD avalanche 脉冲同步到 FPGA 时钟域，并统计 1 秒窗口
//   内的上升沿次数，输出 count/s。此前旧版本在低速时钟域直接采样异步脉冲，容易漏计；
//   当前版本改为先同步、再边沿检测。
//   Counts SPAD (Single Photon Avalanche Diode) avalanche events over a
//   1-second window and reports the count rate for status monitoring.
//
// Architecture:
//   - Synchronizer chain for asynchronous input (ava signal)
//   - Rising edge detection for event counting
//   - 1-second accumulation window
//   - Output is events per second (Hz)
//
// Timing:
//   - WINDOW_CYCLES = CLK_FREQ_HZ (1 second at full clock speed)
//   - Count rolls over each second with fresh count value
//
// Parameters:
//   - CLK_FREQ_HZ: System clock frequency (default: 100 MHz)
//
// Clock Domain:
//   - clk (typically system clock)
//
// Interfaces:
//   - ava: Asynchronous avalanche input from SPAD
//   - count[31:0]: Events per second output
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module Counter #(
    parameter integer CLK_FREQ_HZ = 100_000_000   // System clock frequency in Hz
)(
    //==========================================================================
    // Clock and Reset
    //==========================================================================
    input  wire        clk,                // System clock
    input  wire        rst,                // Active-high reset

    //==========================================================================
    // Counter Interface
    //==========================================================================
    input  wire        ava,                // Asynchronous avalanche input
    output reg  [31:0] count               // Events per second output
);

    //--------------------------------------------------------------------------
    // Window Configuration
    //--------------------------------------------------------------------------
    // 1-second window = CLK_FREQ_HZ cycles
    localparam [31:0] WINDOW_CYCLES = CLK_FREQ_HZ - 1;

    //--------------------------------------------------------------------------
    // Internal State
    //--------------------------------------------------------------------------
    reg [31:0] tick_cnt;                   // Window counter (0 to WINDOW_CYCLES)
    reg [31:0] count_accum;                // Event accumulator for current window
    (* ASYNC_REG = "TRUE" *) reg ava_sync1; // Synchronizer stage 1
    (* ASYNC_REG = "TRUE" *) reg ava_sync2; // Synchronizer stage 2
    reg        ava_sync3;                  // Synchronizer stage 3 (for edge detect)

    wire ava_rise;                          // Detected rising edge
    wire [31:0] count_accum_next;           // Next accumulator value

    //--------------------------------------------------------------------------
    // Edge Detection
    //--------------------------------------------------------------------------
    // Rising edge: ava_sync2 HIGH and ava_sync3 LOW
    assign ava_rise = ava_sync2 & ~ava_sync3;
    // Next accumulator value: add 1 if edge detected
    assign count_accum_next = count_accum + {{31{1'b0}}, ava_rise};

    //==========================================================================
    // Counter Logic
    //==========================================================================
    // Synchronizes asynchronous input and counts events over 1-second window.
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            tick_cnt    <= 32'd0;
            count_accum <= 32'd0;
            count       <= 32'd0;
            ava_sync1   <= 1'b0;
            ava_sync2   <= 1'b0;
            ava_sync3   <= 1'b0;
        end else begin
            // Synchronizer chain: prevent metastability.
            // 三拍结构里前两拍用于同步，第三拍只用于做沿检测。
            ava_sync1 <= ava;
            ava_sync2 <= ava_sync1;
            ava_sync3 <= ava_sync2;

            // Window management
            if (tick_cnt == WINDOW_CYCLES) begin
                // End of 1-second window: output count and reset
                tick_cnt    <= 32'd0;
                count       <= count_accum_next;  // Include any edge in final cycle
                count_accum <= 32'd0;             // Reset for next window
            end else begin
                // Continue counting
                tick_cnt    <= tick_cnt + 1'b1;
                count_accum <= count_accum_next;
            end
        end
    end

endmodule
