//==============================================================================
// Temp_control.v
//------------------------------------------------------------------------------
// Module: Temperature Sampling and Preprocessing Controller
// 模块说明：温度采样与预处理模块
//
// Purpose:
// 中文说明：
//   该模块位于 20 MHz 慢速控制域，用于周期性启动 ADC 采样，并把采到的温度值
//   做滑动平均后送给 TEC_PID。这样可以把瞬时噪声过滤掉，避免 PID 直接跟踪抖动数据。
//   Manages ADC sampling schedule and temperature averaging for TEC PID control.
//   Triggers periodic ADC conversions and provides moving-average filtered
//   temperature to the PID controller.
//
// Architecture:
//   - Periodic ADC start trigger (configurable period)
//   - Delayed data capture after ADC conversion time
//   - Moving average filter (configurable depth)
//   - Periodic PID update trigger
//
// Timing:
// 中文说明：
//   - ADC_PERIOD_CYCLES 决定采样周期
//   - ADC_VALID_DELAY_CYCLES 用来补偿 ADC 转换延迟，避免在启动采样同拍就取数
//   - PID_PERIOD_CYCLES 决定 TEC 闭环更新频率
//   - ADC_PERIOD_CYCLES: Interval between ADC samples (default: 200k cycles)
//   - PID_PERIOD_CYCLES: Interval between PID updates (default: 20M cycles = 1s)
//   - ADC_VALID_DELAY_CYCLES: Delay for ADC conversion completion (default: 40)
//
// Parameters:
//   - CLK_FREQ_HZ: System clock frequency (default: 20 MHz)
//   - AVG_DEPTH: Moving average depth (default: 50 samples)
//
// Clock Domain:
//   - clk (typically 20 MHz)
//
// Interfaces:
//   - temp_current[15:0]: Raw temperature from ADC
//   - PID_start: Trigger for TEC_PID update
//   - ADC_start: Trigger for ADC conversion
//   - temp[15:0]: Averaged temperature output
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module Temp_control #(
    parameter integer CLK_FREQ_HZ           = 20_000_000,   // System clock frequency
    parameter integer ADC_PERIOD_CYCLES     = 200_000,      // ADC sampling interval (10 Hz @ 20MHz)
    parameter integer PID_PERIOD_CYCLES     = 20_000_000,   // PID update interval (1 Hz @ 20MHz)
    parameter integer ADC_VALID_DELAY_CYCLES = 40,          // ADC conversion delay
    parameter integer AVG_DEPTH             = 50            // Moving average depth
)(
    //==========================================================================
    // Clock and Reset
    //==========================================================================
    input  wire        clk,                // System clock
    input  wire        rst,                // Active-high reset

    //==========================================================================
    // Temperature Interface
    //==========================================================================
    input  wire [15:0] temp_current,       // Raw temperature from ADC
    output reg         PID_start,          // Trigger PID update
    output reg         ADC_start,          // Trigger ADC conversion
    output reg  [15:0] temp                // Averaged temperature output
);

    // 平均窗口较小时也至少保留 1 位地址宽度，避免综合出 0 位向量。
    localparam integer WR_PTR_W = (AVG_DEPTH <= 2) ? 1 : $clog2(AVG_DEPTH);

    //==========================================================================
    // Internal State
    //==========================================================================
    reg [31:0] pid_cnt;                    // PID period counter
    reg [31:0] adc_cnt;                    // ADC period counter
    reg [31:0] adc_valid_cnt;              // ADC valid delay counter
    reg        adc_wait_data;              // Waiting for ADC conversion
    reg [15:0] sample_mem [0:AVG_DEPTH-1]; // Circular buffer for averaging
    reg [WR_PTR_W-1:0] wr_ptr;             // Write pointer for circular buffer
    reg [31:0] temp_total;                 // Running sum for average
    reg [31:0] temp_total_next;            // One-cycle helper for average update
    integer i;                             // Loop variable for init

    initial begin
        pid_cnt         = 32'd0;
        adc_cnt         = 32'd0;
        adc_valid_cnt   = 32'd0;
        adc_wait_data   = 1'b0;
        wr_ptr          = {WR_PTR_W{1'b0}};
        temp_total      = 32'd0;
        temp_total_next = 32'd0;
        temp            = 16'd0;
        PID_start       = 1'b0;
        ADC_start       = 1'b0;
        for (i = 0; i < AVG_DEPTH; i = i + 1)
            sample_mem[i] = 16'd0;
    end

    //==========================================================================
    // Timing and Averaging Logic
    //==========================================================================
    // The module maintains a moving average of temperature readings:
    //   1. Trigger ADC conversion every ADC_PERIOD_CYCLES
    //   2. Wait ADC_VALID_DELAY_CYCLES for conversion to complete
    //   3. Update circular buffer and running sum
    //   4. Trigger PID update every PID_PERIOD_CYCLES
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            // Reset all counters and state
            pid_cnt        <= 32'd0;
            adc_cnt        <= 32'd0;
            adc_valid_cnt  <= 32'd0;
            adc_wait_data  <= 1'b0;
            wr_ptr         <= {WR_PTR_W{1'b0}};
            temp_total     <= 32'd0;
            temp_total_next<= 32'd0;
            temp           <= 16'd0;
            PID_start      <= 1'b0;
            ADC_start      <= 1'b0;
        end else begin
            // Default: no triggers
            PID_start <= 1'b0;
            ADC_start <= 1'b0;

            // PID period counter: trigger PID every PID_PERIOD_CYCLES
            if (pid_cnt == PID_PERIOD_CYCLES - 1) begin
                pid_cnt   <= 32'd0;
                PID_start <= 1'b1;           // Trigger PID update
            end else begin
                pid_cnt <= pid_cnt + 1'b1;
            end

            // ADC period counter: trigger ADC every ADC_PERIOD_CYCLES
            if (adc_cnt == ADC_PERIOD_CYCLES - 1) begin
                adc_cnt        <= 32'd0;
                adc_valid_cnt  <= 32'd0;
                adc_wait_data  <= 1'b1;       // Wait for conversion
                ADC_start      <= 1'b1;       // Trigger ADC conversion
            end else begin
                adc_cnt <= adc_cnt + 1'b1;
            end

            // ADC valid delay: wait for conversion to complete.
            // 当前版本按 ADC_Ctrl 的固定转换延迟取数；如果后续 ADC 驱动升级出
            // 显式 data_valid，这里可以直接替换成 valid 握手。
            if (adc_wait_data) begin
                if (adc_valid_cnt == ADC_VALID_DELAY_CYCLES - 1) begin
                    // Conversion complete: update average
                    adc_wait_data <= 1'b0;
                    // Update running sum: subtract oldest sample and add newest.
                    // temp_total_next keeps the arithmetic explicit for the same
                    // cycle average update below.
                    temp_total_next = temp_total - sample_mem[wr_ptr] + temp_current;
                    temp_total      <= temp_total_next;
                    // Store new sample in circular buffer
                    sample_mem[wr_ptr] <= temp_current;
                    // Advance write pointer
                    if (wr_ptr == AVG_DEPTH - 1)
                        wr_ptr <= {WR_PTR_W{1'b0}};
                    else
                        wr_ptr <= wr_ptr + 1'b1;

                    // If PID happens to trigger on the same cycle as the sample
                    // capture, expose the fresh average instead of the previous sum.
                    if (PID_start)
                        temp <= temp_total_next / AVG_DEPTH;
                end else begin
                    // Wait for ADC conversion
                    adc_valid_cnt <= adc_valid_cnt + 1'b1;
                end
            end

            // Update temperature output when PID triggers and no fresh sample was
            // committed in this cycle.
            if (PID_start && !(adc_wait_data && (adc_valid_cnt == ADC_VALID_DELAY_CYCLES - 1)))
                temp <= temp_total / AVG_DEPTH;  // Moving average
        end
    end

endmodule
