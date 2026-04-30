//==============================================================================
// pulse_gen_rtl.v
// 可复用脉冲生成模块（纯 RTL 版本）
//
// 功能：
//   收到 trigger 后，等待 delay 个时钟周期，输出高电平持续 width 个时钟周期
//
// 时序行为（delay=2, width=3 示例）：
//   clk:      _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
//   trigger:  _____|‾|_______________________
//   state:    IDLE |  DELAY  |    PULSE    |IDLE
//   counter:       | 1  | 0  | 2  | 1  | 0 |
//   pulse_out:_____|________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____
//                  ^        ^              ^
//                  |        |              |
//             trigger    delay=2后      width=3后
//             到来       脉冲上升沿     脉冲下降沿
//
// 边界策略：
//   - enable=0 时：不响应 trigger，pulse_out 保持低
//   - delay=0 时：trigger 的下一个时钟沿立即输出高电平（不经过 S_DELAY）
//   - width=0 时：输出最小 1 个时钟周期的脉冲
//   - 脉冲未结束时新 trigger 到来：忽略新 trigger（busy=1 时不响应）
//
// 接口预留：
//   - 参数输入为 delay / width，单位为时钟周期
//   - 后续可扩展为 coarse + fine 结构
//
// 注意：counter 使用 DELAY_BITS 位宽，要求 WIDTH_BITS <= DELAY_BITS
//
// Author: Refactored
// Date: 2026-03-31
//==============================================================================

`timescale 1ns/1ps

module pulse_gen_rtl #(
    parameter integer DELAY_BITS = 8,   // delay 计数器位宽
    parameter integer WIDTH_BITS = 7    // width 计数器位宽
)(
    input  wire                    clk,
    input  wire                    rst,
    
    // 触发和使能
    input  wire                    trigger,    // 单周期触发脉冲
    input  wire                    enable,     // 使能信号
    
    // 参数输入（在 trigger 到来时锁存）
    input  wire [DELAY_BITS-1:0]   delay,      // 延时，单位：时钟周期
    input  wire [WIDTH_BITS-1:0]   width,      // 脉宽，单位：时钟周期
    
    // 输出
    output reg                     pulse_out,  // 脉冲输出
    output wire                    busy        // 正在生成脉冲（用于外部判断是否可接受新 trigger）
);

    //==========================================================================
    // 状态机定义
    //==========================================================================
    localparam [1:0] S_IDLE  = 2'b00;  // 空闲，等待 trigger
    localparam [1:0] S_DELAY = 2'b01;  // 延时阶段，计数递减
    localparam [1:0] S_PULSE = 2'b10;  // 脉冲输出阶段
    
    reg [1:0] state;
    reg [1:0] next_state;
    
    //==========================================================================
    // 计数器（DELAY 和 PULSE 阶段共用）
    // 注意：使用 DELAY_BITS 位宽，要求 WIDTH_BITS <= DELAY_BITS
    //==========================================================================
    reg [DELAY_BITS-1:0] counter;
    
    //==========================================================================
    // 参数锁存寄存器
    // 在 trigger 时刻锁存，避免脉冲生成过程中参数变化导致行为异常
    //==========================================================================
    reg [DELAY_BITS-1:0] latched_delay;
    reg [WIDTH_BITS-1:0] latched_width;
    
    //==========================================================================
    // busy 信号：非 IDLE 状态都是 busy
    //==========================================================================
    assign busy = (state != S_IDLE);
    
    //==========================================================================
    // 状态转移逻辑（组合逻辑）
    //==========================================================================
    always @(*) begin
        // 默认保持当前状态
        next_state = state;
        
        case (state)
            S_IDLE: begin
                if (trigger && enable) begin
                    // 收到有效 trigger
                    if (delay == 0) begin
                        // delay=0，跳过延时阶段，直接进入脉冲阶段
                        next_state = S_PULSE;
                    end else begin
                        next_state = S_DELAY;
                    end
                end
            end
            
            S_DELAY: begin
                if (counter == 0) begin
                    // 延时结束，进入脉冲阶段
                    next_state = S_PULSE;
                end
            end
            
            S_PULSE: begin
                if (counter == 0) begin
                    // 脉冲结束，回到空闲
                    next_state = S_IDLE;
                end
            end
            
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end
    
    //==========================================================================
    // 状态寄存器和计数器更新（时序逻辑）
    //==========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            counter       <= {DELAY_BITS{1'b0}};
            latched_delay <= {DELAY_BITS{1'b0}};
            latched_width <= {WIDTH_BITS{1'b0}};
            pulse_out     <= 1'b0;
        end else begin
            // 状态转移
            state <= next_state;
            
            case (state)
                S_IDLE: begin
                    pulse_out <= 1'b0;
                    
                    if (trigger && enable) begin
                        // 锁存参数
                        latched_delay <= delay;
                        latched_width <= width;
                        
                        if (delay == 0) begin
                            // delay=0：跳过 S_DELAY，直接进入 S_PULSE
                            // 此时 pulse_out 在本周期末拉高，下周期生效
                            // width=0 时，强制最小 1 周期脉冲
                            pulse_out <= 1'b1;
                            if (width == 0) begin
                                counter <= {DELAY_BITS{1'b0}};  // counter=0，下周期结束
                            end else begin
                                // width-1：因为 pulse_out 在本周期已经拉高，占用 1 个周期
                                counter <= {{(DELAY_BITS-WIDTH_BITS){1'b0}}, width} - 1'b1;
                            end
                        end else begin
                            // 有延时：装载 delay-1
                            // 原因：trigger 到来的这个周期已经过去，进入 S_DELAY 时已是下一周期
                            // 所以实际等待周期数 = delay，计数器从 delay-1 递减到 0
                            counter <= delay - 1'b1;
                        end
                    end
                end
                
                S_DELAY: begin
                    pulse_out <= 1'b0;
                    
                    if (counter > 0) begin
                        counter <= counter - 1'b1;
                    end else begin
                        // counter=0：延时结束，下周期进入 S_PULSE
                        // 装载 width-1（width=0 时，counter=0 表示输出 1 周期脉冲）
                        pulse_out <= 1'b1;
                        if (latched_width == 0) begin
                            counter <= {DELAY_BITS{1'b0}};
                        end else begin
                            counter <= {{(DELAY_BITS-WIDTH_BITS){1'b0}}, latched_width} - 1'b1;
                        end
                    end
                end
                
                S_PULSE: begin
                    if (counter > 0) begin
                        pulse_out <= 1'b1;
                        counter   <= counter - 1'b1;
                    end else begin
                        // 脉冲结束
                        pulse_out <= 1'b0;
                    end
                end
                
                default: begin
                    state     <= S_IDLE;
                    pulse_out <= 1'b0;
                    counter   <= {DELAY_BITS{1'b0}};
                end
            endcase
        end
    end

endmodule
