//==============================================================================
// gate_gen_top_func.v
// Gate Signal Generator - 功能验证版
//
// 目的：
//   验证整体架构逻辑正确性，不涉及精细时序原语
//   后续再单独设计精细延时输出单元
//
// 当前版本特性：
//   - 粗延时：10ns 步长 (1 sys_clk cycle @ 100MHz)
//   - 粗脉宽：10ns 步长
//   - 不使用 IDELAYE2/ODELAYE2
//   - 验证：像素RAM、分频、使能、OR输出
//
// Author: Refactored
// Date: 2026-03-31
//==============================================================================

`timescale 1ns/1ps

module gate_gen_top_func #(
    parameter integer PIXEL_ADDR_BITS = 14,  // 2^14 = 16384 pixels (128x128)
    parameter integer PIXEL_X_BITS    = 7,   // X pixels (default 128)
    parameter integer DELAY_BITS      = 8,   // 0-255 steps × 10ns = 0-2550ns (实际用 0-10 对应 0-100ns)
    parameter integer WIDTH_BITS      = 7,   // 0-127 steps × 10ns (实际用 0-5 对应 0-50ns)
    parameter integer DIV_BITS        = 12   // 1-4096 division ratio
)(
    //==========================================================================
    // Clock and Reset
    //==========================================================================
    input  wire        sys_clk,        // 100 MHz system clock
    input  wire        sys_rst,        // Active-high reset

    //==========================================================================
    // Reference Signal Input (Directly from external buffer)
    // 实际使用时需要前级甄别电路转为 LVDS/LVCMOS
    //==========================================================================
    input  wire        ref_in,         // Reference signal (single-ended for sim)

    //==========================================================================
    // Pixel Signal Input
    //==========================================================================
    input  wire        pixel1_in,      // Pixel X step signal
    input  wire        pixel2_in,      // Pixel Y step signal

    //==========================================================================
    // Outputs
    //==========================================================================
    output wire        sig1_out,       // Signal 1: shaped reference (to TDC)
    output wire        sig2_pulse,     // Signal 2: shaped reference (to TDC)
    output wire        sig3_pulse,     // Signal 3: shaped reference (to TDC)
    output wire        gate_out,       // Gate signal (OR of sig2 and sig3)


    //==========================================================================
    // Control Interface
    //==========================================================================
    // Global settings
    input  wire [DIV_BITS-1:0]   div_ratio,      // Frequency division ratio (1-4096)
    input  wire                  sig2_enable,    // Enable Signal 2
    input  wire                  sig3_enable,    // Enable Signal 3

    // Signal 2 parameters (direct mode)
    input  wire [DELAY_BITS-1:0] sig2_delay,     // Delay in 10ns steps (coarse)
    input  wire [WIDTH_BITS-1:0] sig2_width,     // Pulse width in 10ns steps (coarse)

    // Signal 3 parameters (direct mode)
    input  wire [DELAY_BITS-1:0] sig3_delay,     // Delay in 10ns steps (coarse)
    input  wire [WIDTH_BITS-1:0] sig3_width,     // Pulse width in 10ns steps (coarse)

    // Pixel RAM interface
    input  wire                  pixel_mode,     // 1 = use pixel RAM, 0 = use direct settings
    input  wire                  pixel_reset,    // Reset pixel counter
    input  wire                  ram_wr_en,      // RAM write enable
    input  wire [PIXEL_ADDR_BITS-1:0] ram_wr_addr, // RAM write address
    input  wire [31:0]           ram_wr_data,    // RAM write data

    //==========================================================================
    // Status Outputs
    //==========================================================================
    output wire [PIXEL_ADDR_BITS-1:0] current_pixel  // Current pixel index
);

    //==========================================================================
    // Reference Edge Detection (双触发器同步 + 边沿检测)
    //==========================================================================
    reg ref_sync1, ref_sync2, ref_sync3;
    wire ref_rising_edge;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            ref_sync1 <= 1'b0;
            ref_sync2 <= 1'b0;
            ref_sync3 <= 1'b0;
        end else begin
            ref_sync1 <= ref_in;
            ref_sync2 <= ref_sync1;
            ref_sync3 <= ref_sync2;
        end
    end
    // 使用 sync2 和 sync3 做边沿检测，避免亚稳态
    assign ref_rising_edge = ref_sync2 & ~ref_sync3;

    // Signal 1: 直接输出同步后的参考信号
    assign sig1_out = ref_sync2;

    //==========================================================================
    // Pixel Edge Detection
    //==========================================================================
    reg pixel1_sync1, pixel1_sync2, pixel1_sync3;
    reg pixel2_sync1, pixel2_sync2, pixel2_sync3;
    wire pixel1_rising_edge;
    wire pixel2_rising_edge;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            pixel1_sync1 <= 1'b0;
            pixel1_sync2 <= 1'b0;
            pixel1_sync3 <= 1'b0;
            pixel2_sync1 <= 1'b0;
            pixel2_sync2 <= 1'b0;
            pixel2_sync3 <= 1'b0;
        end else begin
            pixel1_sync1 <= pixel1_in;
            pixel1_sync2 <= pixel1_sync1;
            pixel1_sync3 <= pixel1_sync2;
            pixel2_sync1 <= pixel2_in;
            pixel2_sync2 <= pixel2_sync1;
            pixel2_sync3 <= pixel2_sync2;
        end
    end
    assign pixel1_rising_edge = pixel1_sync2 & ~pixel1_sync3;
    assign pixel2_rising_edge = pixel2_sync2 & ~pixel2_sync3;

    //==========================================================================
    // Pixel Counter (pixel1 = X step, pixel2 = Y step)
    //==========================================================================
    localparam integer PIXEL_Y_BITS = PIXEL_ADDR_BITS - PIXEL_X_BITS;
    reg [PIXEL_X_BITS-1:0] pixel_x_cnt;
    reg [PIXEL_Y_BITS-1:0] pixel_y_cnt;
    wire [PIXEL_ADDR_BITS-1:0] pixel_addr;
    reg pixel_changed;      // 标记像素刚切换（本拍）
    reg pixel_changed_d1;   // 延迟1拍（等待 BRAM 地址建立）
    reg pixel_changed_d2;   // 延迟2拍（等待 BRAM 数据输出稳定）

    always @(posedge sys_clk) begin
        if (sys_rst || pixel_reset) begin
            pixel_x_cnt    <= {PIXEL_X_BITS{1'b0}};
            pixel_y_cnt    <= {PIXEL_Y_BITS{1'b0}};
            pixel_changed  <= 1'b0;
            pixel_changed_d1 <= 1'b0;
            pixel_changed_d2 <= 1'b0;
        end else begin
            pixel_changed <= 1'b0;  // 默认清除
            
            if (pixel2_rising_edge) begin
                // Y 步进：X 归零，Y+1
                pixel_x_cnt   <= {PIXEL_X_BITS{1'b0}};
                pixel_y_cnt   <= (pixel_y_cnt == {PIXEL_Y_BITS{1'b1}}) ? 
                                 {PIXEL_Y_BITS{1'b0}} : pixel_y_cnt + 1'b1;
                pixel_changed <= 1'b1;
            end else if (pixel1_rising_edge) begin
                // X 步进
                if (pixel_x_cnt == {PIXEL_X_BITS{1'b1}}) begin
                    pixel_x_cnt <= {PIXEL_X_BITS{1'b0}};
                    pixel_y_cnt <= (pixel_y_cnt == {PIXEL_Y_BITS{1'b1}}) ? 
                                   {PIXEL_Y_BITS{1'b0}} : pixel_y_cnt + 1'b1;
                end else begin
                    pixel_x_cnt <= pixel_x_cnt + 1'b1;
                end
                pixel_changed <= 1'b1;
            end
            
            // Bug Fix 2: 对 pixel_changed 延迟2拍，等待 BRAM 读出数据稳定
            // 拍1(pixel_changed_d1): 新地址已更新到 BRAM 端口
            // 拍2(pixel_changed_d2): BRAM 同步读输出已反映新地址数据
            pixel_changed_d1 <= pixel_changed;
            pixel_changed_d2 <= pixel_changed_d1;
        end
    end
    assign pixel_addr = {pixel_y_cnt, pixel_x_cnt};
    assign current_pixel = pixel_addr;

    //==========================================================================
    // Pixel Parameter RAM
    //==========================================================================
    wire [31:0] ram_rd_data;
    
    pixel_param_ram u_pixel_ram (
        .clka   (sys_clk),
        .wea    (ram_wr_en),
        .addra  (ram_wr_addr),
        .dina   (ram_wr_data),
        .douta  (),
        
        .clkb   (sys_clk),
        .enb    (1'b1),
        .web    (1'b0),
        .addrb  (pixel_addr),
        .dinb   (32'd0),
        .doutb  (ram_rd_data)
    );

    //==========================================================================
    // Parameter Latching (解决像素切换边界问题)
    //==========================================================================
    // RAM 数据格式: {sig3_width[6:0], sig3_delay[7:0], sig2_width[6:0], sig2_delay[7:0], enable[1:0]}
    
    reg [DELAY_BITS-1:0] latched_sig2_delay;
    reg [WIDTH_BITS-1:0] latched_sig2_width;
    reg [DELAY_BITS-1:0] latched_sig3_delay;
    reg [WIDTH_BITS-1:0] latched_sig3_width;
    reg                  latched_sig2_en;
    reg                  latched_sig3_en;
    reg                  param_update_pending;
    wire                 pixel_param_load_req;
    wire                 load_pixel_params_now;
    wire                 active_sig2_en;
    wire                 active_sig3_en;
    wire [DELAY_BITS-1:0] active_sig2_delay;
    wire [WIDTH_BITS-1:0] active_sig2_width;
    wire [DELAY_BITS-1:0] active_sig3_delay;
    wire [WIDTH_BITS-1:0] active_sig3_width;

    // 检测 pixel_mode 上升沿 和 pixel_reset 下降沿（用于触发初始 pending）
    reg pixel_mode_prev;
    reg pixel_reset_prev;
    wire pixel_mode_rising  = pixel_mode  & ~pixel_mode_prev;
    wire pixel_reset_falling = ~pixel_reset & pixel_reset_prev & pixel_mode;
    assign pixel_param_load_req = pixel_mode &&
                                  (param_update_pending || pixel_mode_rising ||
                                   pixel_reset_falling || pixel_changed_d2);
    assign load_pixel_params_now = ref_rising_edge && pixel_param_load_req;

    assign active_sig2_en    = pixel_mode ? (load_pixel_params_now ? ram_rd_data[0]     : latched_sig2_en)    : sig2_enable;
    assign active_sig3_en    = pixel_mode ? (load_pixel_params_now ? ram_rd_data[1]     : latched_sig3_en)    : sig3_enable;
    assign active_sig2_delay = pixel_mode ? (load_pixel_params_now ? ram_rd_data[9:2]   : latched_sig2_delay) : sig2_delay;
    assign active_sig2_width = pixel_mode ? (load_pixel_params_now ? ram_rd_data[16:10] : latched_sig2_width) : sig2_width;
    assign active_sig3_delay = pixel_mode ? (load_pixel_params_now ? ram_rd_data[24:17] : latched_sig3_delay) : sig3_delay;
    assign active_sig3_width = pixel_mode ? (load_pixel_params_now ? ram_rd_data[31:25] : latched_sig3_width) : sig3_width;

    // 像素切换后，等待 BRAM 数据稳定（2拍），再在下一个 ref_rising_edge 锁存参数
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            latched_sig2_delay   <= 8'd0;
            latched_sig2_width   <= 7'd0;
            latched_sig3_delay   <= 8'd0;
            latched_sig3_width   <= 7'd0;
            latched_sig2_en      <= 1'b0;
            latched_sig3_en      <= 1'b0;
            param_update_pending <= 1'b1;  // 初始需要加载
            pixel_mode_prev      <= 1'b0;
            pixel_reset_prev     <= 1'b0;
        end else begin
            // 延迟寄存器更新
            pixel_mode_prev  <= pixel_mode;
            pixel_reset_prev <= pixel_reset;

            // 像素模式进入触发（pixel_mode 上升沿 或 pixel_reset 在像素模式下释放）
            // 此时 BRAM 地址为 0（或当前像素），需要加载初始参数
            if (pixel_mode_rising || pixel_reset_falling) begin
                param_update_pending <= 1'b1;
            end

            // Bug Fix 2: 使用延迟2拍的 pixel_changed_d2 触发 pending
            // 此时 BRAM 已输出新像素地址的数据，避免锁存旧数据
            if (pixel_changed_d2) begin
                param_update_pending <= 1'b1;
            end

            // 像素模式：在参考边沿锁存 BRAM 中的参数
            if (load_pixel_params_now) begin
                latched_sig2_en    <= ram_rd_data[0];
                latched_sig3_en    <= ram_rd_data[1];
                latched_sig2_delay <= ram_rd_data[9:2];
                latched_sig2_width <= ram_rd_data[16:10];
                latched_sig3_delay <= ram_rd_data[24:17];
                latched_sig3_width <= ram_rd_data[31:25];
                param_update_pending <= 1'b0;
            end

            // Bug Fix 1: 直接模式下每个时钟周期持续同步参数
            // 不再等待 ref_rising_edge，消除 1个ref周期的参数滞后
            if (!pixel_mode) begin
                latched_sig2_en    <= sig2_enable;
                latched_sig3_en    <= sig3_enable;
                latched_sig2_delay <= sig2_delay;
                latched_sig2_width <= sig2_width;
                latched_sig3_delay <= sig3_delay;
                latched_sig3_width <= sig3_width;
                param_update_pending <= 1'b0;
            end
        end
    end

    //==========================================================================
    // Frequency Divider for Signal 3
    //==========================================================================
    reg [DIV_BITS-1:0] div_cnt;
    reg                div_pulse_reg;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            div_cnt       <= {DIV_BITS{1'b0}};
            div_pulse_reg <= 1'b0;
        end 
        else begin
            div_pulse_reg <= 1'b0;  // 默认清除
            
            if (ref_rising_edge) begin
                if (div_cnt >= div_ratio - 1) begin
                    div_cnt       <= {DIV_BITS{1'b0}};
                    div_pulse_reg <= 1'b1;  // 计满时输出脉冲
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end

    //==========================================================================
    // Signal 2: Delay and Pulse Width Generator
    //==========================================================================
    // 状态机：IDLE -> DELAY -> PULSE -> IDLE
    localparam S2_IDLE  = 2'b00;
    localparam S2_DELAY = 2'b01;
    localparam S2_PULSE = 2'b10;

    reg [1:0]             sig2_state;
    reg [DELAY_BITS-1:0]  sig2_delay_cnt;
    reg [WIDTH_BITS-1:0]  sig2_width_cnt;
    reg [WIDTH_BITS-1:0]  sig2_width_cfg;
    reg                   sig2_pulse;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            sig2_state     <= S2_IDLE;
            sig2_delay_cnt <= {DELAY_BITS{1'b0}};
            sig2_width_cnt <= {WIDTH_BITS{1'b0}};
            sig2_width_cfg <= {WIDTH_BITS{1'b0}};
            sig2_pulse     <= 1'b0;
        end else begin
            case (sig2_state)
                S2_IDLE: begin
                    sig2_pulse <= 1'b0;
                    if (ref_rising_edge && active_sig2_en) begin
                        sig2_width_cfg <= active_sig2_width;
                        if (active_sig2_delay == 0) begin
                            // 零延时，直接进入脉冲状态
                            if (active_sig2_width == 0) begin
                                // 零脉宽，产生单周期脉冲
                                sig2_pulse <= 1'b1;
                                sig2_state <= S2_IDLE;
                            end else begin
                                sig2_pulse     <= 1'b1;
                                sig2_width_cnt <= active_sig2_width - 1'b1;
                                sig2_state     <= S2_PULSE;
                            end
                        end else begin
                            sig2_delay_cnt <= active_sig2_delay - 1'b1;
                            sig2_state     <= S2_DELAY;
                        end
                    end
                end
                
                S2_DELAY: begin
                    if (sig2_delay_cnt == 0) begin
                        // 延时结束，开始脉冲
                        if (sig2_width_cfg == 0) begin
                            sig2_pulse <= 1'b1;
                            sig2_state <= S2_IDLE;
                        end else begin
                            sig2_pulse     <= 1'b1;
                            sig2_width_cnt <= sig2_width_cfg - 1'b1;
                            sig2_state     <= S2_PULSE;
                        end
                    end else begin
                        sig2_delay_cnt <= sig2_delay_cnt - 1'b1;
                    end
                end
                
                S2_PULSE: begin
                    if (sig2_width_cnt == 0) begin
                        sig2_pulse <= 1'b0;
                        sig2_state <= S2_IDLE;
                    end else begin
                        sig2_width_cnt <= sig2_width_cnt - 1'b1;
                    end
                end
                
                default: begin
                    sig2_state <= S2_IDLE;
                    sig2_pulse <= 1'b0;
                end
            endcase
        end
    end

    //==========================================================================
    // Signal 3: Delay and Pulse Width Generator (Triggered by div_pulse)
    //==========================================================================
    localparam S3_IDLE  = 2'b00;
    localparam S3_DELAY = 2'b01;
    localparam S3_PULSE = 2'b10;

    reg [1:0]             sig3_state;
    reg [DELAY_BITS-1:0]  sig3_delay_cnt;
    reg [WIDTH_BITS-1:0]  sig3_width_cnt;
    reg [WIDTH_BITS-1:0]  sig3_width_cfg;
    reg                   sig3_pulse;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            sig3_state     <= S3_IDLE;
            sig3_delay_cnt <= {DELAY_BITS{1'b0}};
            sig3_width_cnt <= {WIDTH_BITS{1'b0}};
            sig3_width_cfg <= {WIDTH_BITS{1'b0}};
            sig3_pulse     <= 1'b0;
        end else begin
            case (sig3_state)
                S3_IDLE: begin
                    sig3_pulse <= 1'b0;
                    if (div_pulse_reg && active_sig3_en) begin
                        sig3_width_cfg <= active_sig3_width;
                        if (active_sig3_delay == 0) begin
                            if (active_sig3_width == 0) begin
                                sig3_pulse <= 1'b1;
                                sig3_state <= S3_IDLE;
                            end else begin
                                sig3_pulse     <= 1'b1;
                                sig3_width_cnt <= active_sig3_width - 1'b1;
                                sig3_state     <= S3_PULSE;
                            end
                        end else begin
                            sig3_delay_cnt <= active_sig3_delay - 1'b1;
                            sig3_state     <= S3_DELAY;
                        end
                    end
                end
                
                S3_DELAY: begin
                    if (sig3_delay_cnt == 0) begin
                        if (sig3_width_cfg == 0) begin
                            sig3_pulse <= 1'b1;
                            sig3_state <= S3_IDLE;
                        end else begin
                            sig3_pulse     <= 1'b1;
                            sig3_width_cnt <= sig3_width_cfg - 1'b1;
                            sig3_state     <= S3_PULSE;
                        end
                    end else begin
                        sig3_delay_cnt <= sig3_delay_cnt - 1'b1;
                    end
                end
                
                S3_PULSE: begin
                    if (sig3_width_cnt == 0) begin
                        sig3_pulse <= 1'b0;
                        sig3_state <= S3_IDLE;
                    end else begin
                        sig3_width_cnt <= sig3_width_cnt - 1'b1;
                    end
                end
                
                default: begin
                    sig3_state <= S3_IDLE;
                    sig3_pulse <= 1'b0;
                end
            endcase
        end
    end

    //==========================================================================
    // Output Logic
    //==========================================================================
    assign gate_out = sig2_pulse | sig3_pulse;

endmodule
