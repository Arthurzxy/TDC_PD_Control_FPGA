//==============================================================================
// TEC_PID.v
//------------------------------------------------------------------------------
// Module: TEC (Thermoelectric Cooler) PID Controller
// 模块说明：TEC 温控 PI 控制器
//
// Purpose:
// 中文说明：
//   该模块根据“目标温度 - 实际温度”的误差，计算 TEC 驱动 DAC 的输出值。
//   当前实现本质上是 PI 控制：比例项负责快速响应，积分项负责消除静差。
//   为了避免温差太大时积分项失控，代码里增加了积分冻结和限幅。
//   Implements a PI (Proportional-Integral) controller for TEC temperature
//   regulation. Drives a DAC (DAC8881) to control TEC current based on
//   temperature error.
//
// Architecture:
//   - Proportional term: P = (2/3) * error
//   - Integral term: I = integral(error) / 20, with anti-windup clamping
//   - Output: Y = Y0 - 16*P - 16*I
//   - Output clamped to DAC range [DAC_MIN, DAC_MAX]
//
// Parameters:
//   - PID_RANGE: Error threshold for integral freeze (±7000)
//   - Y0: Base output value (64000, ~1.95V for DAC8881)
//   - I_LIMIT: Integral anti-windup limit (57600)
//   - DAC_MIN/DAC_MAX: Output clamping range
//
// Timing:
//   - Triggered by 'start' pulse from Temp_control
//   - Outputs 'start_DAC' pulse when DAC update is ready
//
// Clock Domain:
//   - clk (typically 20 MHz)
//
// Interfaces:
//   - Temp[15:0]: Current temperature reading
//   - Temp_set[15:0]: Target temperature setpoint
//   - daout[15:0]: DAC output value
//   - start_DAC: Trigger for DAC8881 update
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module TEC_PID(
    //==========================================================================
    // Clock and Control
    //==========================================================================
    input  wire        clk,            // System clock (typically 20 MHz)
    input  wire        start,          // PID update trigger (from Temp_control)

    //==========================================================================
    // Temperature Inputs
    //==========================================================================
    input  wire [15:0] Temp,           // Current temperature reading
    input  wire [15:0] Temp_set,        // Target temperature setpoint

    //==========================================================================
    // DAC Output Interface
    //==========================================================================
    output reg  [15:0] daout,          // DAC output value for TEC control
    output reg         start_DAC       // Trigger DAC8881 update
);

    //==========================================================================
    // PID Controller Parameters
    //==========================================================================
    // Error threshold for integral freeze.
    // 当误差过大时先靠比例项粗调，暂时冻结积分项，防止积分饱和后回不来。
    localparam signed [16:0] PID_RANGE = 17'sd7000;
    // Base output value (~1.95V at DAC8881, middle of range for cooling/heating)
    localparam signed [33:0] Y0        = 34'sd64000;
    // Integral anti-windup limit (clamps integral accumulator)
    localparam signed [28:0] I_LIMIT   = 29'sd57600;
    // DAC output limits
    localparam [15:0]        DAC_MIN   = 16'd1000;   // Minimum DAC value
    localparam [15:0]        DAC_MAX   = 16'd52000;  // Maximum DAC value

    //--------------------------------------------------------------------------
    // PID State Variables
    //--------------------------------------------------------------------------
    reg signed [16:0] error_reg;       // Current error (Temp_set - Temp)
    reg signed [28:0] integ_reg;       // Integral accumulator
    reg signed [33:0] p_term;          // Proportional term
    reg signed [33:0] i_term;          // Integral term (for debug)
    reg signed [33:0] y_term;          // Output term (for debug)
    reg signed [33:0] y_calc;          // Calculated output before clamping
    reg               start_d1;        // Delayed start for edge detection

    wire start_pulse;                  // Edge-detected start signal

    // Start pulse: detect rising edge of start signal.
    // Temp_control 只给一个单拍 start，因此这里做边沿检测最稳。
    assign start_pulse = start & ~start_d1;

    //==========================================================================
    // PID Control Logic
    //==========================================================================
    // Control equation:
    //   error = Temp_set - Temp
    //   P = (2/3) * error
    //   I = integral(error) / 20
    //   Y = Y0 - 16*P - 16*I
    //
    // Anti-windup:
    //   - Integral accumulator clamped to ±I_LIMIT
    //   - Integration frozen when |error| > PID_RANGE
    //==========================================================================
    always @(posedge clk) begin
        start_d1  <= start;
        start_DAC <= 1'b0;            // Default: no DAC update

        if (start_pulse) begin
            // Calculate error (setpoint - measured)
            error_reg <= $signed({1'b0, Temp_set}) - $signed({1'b0, Temp});

            // Integral update with anti-windup.
            // 误差超出 PID_RANGE 时冻结积分；正常范围内再按误差积分并做上下限钳位。
            if (($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) > PID_RANGE) begin
                // Large positive error: freeze integral (prevent overshoot)
                integ_reg <= integ_reg;
            end else if (($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) < -PID_RANGE) begin
                // Large negative error: freeze integral
                integ_reg <= integ_reg;
            end else begin
                // Normal operation: accumulate error with clamping
                if (integ_reg + ($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) > I_LIMIT)
                    integ_reg <= I_LIMIT;
                else if (integ_reg + ($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) < -I_LIMIT)
                    integ_reg <= -I_LIMIT;
                else
                    integ_reg <= integ_reg + ($signed({1'b0, Temp_set}) - $signed({1'b0, Temp}));
            end

            // Calculate PID terms.
            // 这里把算式显式展开，便于后续直接观察 p_term / i_term / y_term，
            // 也确保调试寄存器和真正 DAC 输出走的是同一条运算路径。
            p_term <= (($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) * 2) / 3;
            i_term <= integ_reg / 20;
            y_calc = Y0
                   - (16 * ((($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) * 2) / 3))
                   - (16 * (integ_reg / 20));
            y_term <= y_calc;

            // Output clamping.
            // TEC 驱动不能直接放开到全范围，因此最终仍需限制到 DAC 可接受且系统安全的区间。
            if (($signed({1'b0, Temp_set}) - $signed({1'b0, Temp})) > PID_RANGE) begin
                // Large positive error (too cold): minimum output (max cooling)
                daout <= DAC_MIN;
            end else if (y_calc < DAC_MIN) begin
                daout <= DAC_MIN;
            end else if (y_calc > DAC_MAX) begin
                daout <= DAC_MAX;
            end else begin
                daout <= y_calc[15:0];
            end

            // Trigger DAC update
            start_DAC <= 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Initial Values (for simulation)
    //--------------------------------------------------------------------------
    initial begin
        error_reg = 17'sd0;
        integ_reg = 29'sd0;
        p_term    = 34'sd0;
        i_term    = 34'sd0;
        y_term    = Y0;
        y_calc    = Y0;
        daout     = 16'd32000;       // Middle value (~50% TEC power)
        start_DAC = 1'b0;
        start_d1  = 1'b0;
    end

endmodule
