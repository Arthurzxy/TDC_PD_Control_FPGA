//==============================================================================
// gate_gen_top.v
//------------------------------------------------------------------------------
// Module: 1ns-Resolution Dual-Channel Gate Generator with Pixel Mode
//
// Purpose:
//   Generates precision timing gate signals with configurable delay and width.
//   Supports two operating modes:
//   1. Static mode: Fixed delay/width from input ports
//   2. Pixel mode: Per-pixel parameters loaded from internal RAM
//
// Architecture:
//   - Pixel tracking: Counts pixel positions from external inputs
//   - Parameter RAM: 16Kx36-bit dual-port RAM for per-pixel timing
//   - CDC synchronization: Safe parameter updates across clock domains
//   - Pulse scheduling: Converts delay/width to step counts
//   - Gate word encoding: 10-bit output per reference cycle
//
// Output Format (gate_word[9:0]):
//   - Each bit represents one 1ns step within a 10-step reference cycle
//   - Bit N set means gate HIGH during step N
//   - Two channels (sig2, sig3) are OR'ed together
//
// Timing Parameters:
//   - delay_coarse: Coarse delay in reference cycles (0-15)
//   - delay_fine: Fine delay in 1ns steps (0-31)
//   - width_coarse: Coarse width in reference cycles (0-7)
//   - width_fine: Fine width in 1ns steps (0-31)
//
// Clock Domains:
//   - sys_clk: System clock for parameter updates and RAM access
//   - clk_div: Divided reference clock for gate timing
//
// Related Documents:
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.12
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module gate_gen_top #(
    parameter integer PIXEL_ADDR_BITS = 14,    // Pixel RAM address width (16K pixels)
    parameter integer PIXEL_X_BITS    = 7,     // X coordinate width (128 pixels)
    parameter integer DIV_BITS        = 12     // Divider ratio width (up to 4096)
)(
    //==========================================================================
    // Clock and Reset
    //==========================================================================
    input  wire                       sys_clk,         // System clock (parameter domain)
    input  wire                       sys_rst,         // System reset (active high)
    input  wire                       clk_div,         // Divided reference clock for timing

    //==========================================================================
    // Pixel Inputs (asynchronous from external)
    //==========================================================================
    input  wire                       pixel1_in,       // Pixel clock input 1 (column advance)
    input  wire                       pixel2_in,       // Pixel clock input 2 (row advance/newline)

    //==========================================================================
    // Gate Output
    //==========================================================================
    output wire [9:0]                 gate_word,       // 10-bit gate word per reference cycle

    //==========================================================================
    // Configuration Inputs (sys_clk domain)
    //==========================================================================
    input  wire [DIV_BITS-1:0]        div_ratio,       // Reference divider ratio
    input  wire                       sig2_enable,     // Signal 2 enable (static mode)
    input  wire                       sig3_enable,     // Signal 3 enable (static mode)
    input  wire [3:0]                 sig2_delay_coarse,  // Signal 2 coarse delay (reference cycles)
    input  wire [4:0]                 sig2_delay_fine,    // Signal 2 fine delay (1ns steps)
    input  wire [2:0]                 sig2_width_coarse,  // Signal 2 coarse width
    input  wire [4:0]                 sig2_width_fine,    // Signal 2 fine width (1ns steps)
    input  wire [3:0]                 sig3_delay_coarse,  // Signal 3 coarse delay
    input  wire [4:0]                 sig3_delay_fine,    // Signal 3 fine delay
    input  wire [2:0]                 sig3_width_coarse,  // Signal 3 coarse width
    input  wire [4:0]                 sig3_width_fine,    // Signal 3 fine width
    input  wire                       pixel_mode,      // 1=pixel mode (RAM), 0=static mode
    input  wire                       pixel_reset,     // Reset pixel counter

    //==========================================================================
    // RAM Write Interface (for pixel parameter loading)
    //==========================================================================
    input  wire                       ram_wr_en,       // RAM write enable
    input  wire [PIXEL_ADDR_BITS-1:0] ram_wr_addr,    // RAM write address
    input  wire [35:0]                ram_wr_data,    // RAM write data

    //==========================================================================
    // Status Output
    //==========================================================================
    output wire [PIXEL_ADDR_BITS-1:0] current_pixel   // Current pixel address
);

    //==========================================================================
    // Local Parameters
    //==========================================================================
    // Derive Y coordinate width from total address width minus X width
    localparam integer PIXEL_Y_BITS = PIXEL_ADDR_BITS - PIXEL_X_BITS;
    // Number of 1ns steps per reference cycle (10ns at 100MHz reference)
    localparam [8:0]   WORD_STEPS   = 9'd10;

    //==========================================================================
    // Pixel Input Synchronizers
    //==========================================================================
    // Triple synchronizers for metastability protection on asynchronous inputs
    reg pixel1_sync1, pixel1_sync2, pixel1_sync3;
    reg pixel2_sync1, pixel2_sync2, pixel2_sync3;

    // Edge detection signals
    wire pixel1_rising_edge;   // Column advance (pixel1 rising)
    wire pixel2_rising_edge;   // Row advance / newline (pixel2 rising)

    //==========================================================================
    // Pixel Position Tracking
    //==========================================================================
    reg [PIXEL_X_BITS-1:0] pixel_x_cnt;      // Column counter (0 to 127)
    reg [PIXEL_Y_BITS-1:0] pixel_y_cnt;      // Row counter
    reg pixel_changed;                        // Pixel position changed this cycle
    reg pixel_changed_d1, pixel_changed_d2;  // Delayed change flags for parameter load

    wire [PIXEL_ADDR_BITS-1:0] pixel_addr;   // Combined address = {y_cnt, x_cnt}
    wire [35:0] ram_rd_data;                  // Parameter RAM read data

    //==========================================================================
    // Latched Timing Parameters
    //==========================================================================
    // These are the active timing parameters, updated from:
    //   - Static inputs when pixel_mode=0
    //   - RAM when pixel_mode=1 and pixel changes
    reg       latched_sig2_en;
    reg [3:0] latched_sig2_delay_coarse;
    reg [4:0] latched_sig2_delay_fine;
    reg [2:0] latched_sig2_width_coarse;
    reg [4:0] latched_sig2_width_fine;
    reg       latched_sig3_en;
    reg [3:0] latched_sig3_delay_coarse;
    reg [4:0] latched_sig3_delay_fine;
    reg [2:0] latched_sig3_width_coarse;
    reg [4:0] latched_sig3_width_fine;

    // Parameter update control
    reg       param_update_pending;           // Flag: RAM read needed
    reg [1:0] pixel_load_delay;               // Delay counter for RAM latency
    reg       pixel_mode_prev;                // Previous pixel_mode for edge detection
    reg       pixel_reset_prev;                // Previous pixel_reset for edge detection

    // Update request signals
    wire pixel_mode_rising;                   // pixel_mode transition 0->1
    wire pixel_reset_falling;                 // pixel_reset transition 1->0
    wire pixel_param_update_req;               // Request parameter update
    wire pixel_param_load_req;                 // Load parameters from RAM

    (* ASYNC_REG = "TRUE" *) reg [35:0] cfg_sync1;
    (* ASYNC_REG = "TRUE" *) reg [35:0] cfg_sync2;
    (* ASYNC_REG = "TRUE" *) reg [DIV_BITS-1:0] div_ratio_sync1;
    (* ASYNC_REG = "TRUE" *) reg [DIV_BITS-1:0] div_ratio_sync2;
    reg [DIV_BITS-1:0] div_count;

    reg       sig2_active;
    reg [8:0] sig2_rise_rem;
    reg [8:0] sig2_fall_rem;
    reg       sig3_active;
    reg [8:0] sig3_rise_rem;
    reg [8:0] sig3_fall_rem;

    wire [DIV_BITS-1:0] div_ratio_safe;
    wire                sig2_trigger;
    wire                sig3_trigger;

    wire       sig2_sched_valid;
    wire [8:0] sig2_rise_step;
    wire [8:0] sig2_fall_step;
    wire       sig3_sched_valid;
    wire [8:0] sig3_rise_step;
    wire [8:0] sig3_fall_step;

    wire       sig2_accept;
    wire       sig3_accept;
    wire       sig2_src_valid;
    wire       sig3_src_valid;
    wire [8:0] sig2_src_rise;
    wire [8:0] sig2_src_fall;
    wire [8:0] sig3_src_rise;
    wire [8:0] sig3_src_fall;
    wire [9:0] sig2_word;
    wire [9:0] sig3_word;

    function [9:0] build_word;
        input       valid_in;
        input [8:0] rise_in;
        input [8:0] fall_in;
        integer idx;
        begin
            build_word = 10'b0;
            if (valid_in) begin
                for (idx = 0; idx < 10; idx = idx + 1) begin
                    if ((idx >= rise_in) && (idx < fall_in))
                        build_word[idx] = 1'b1;
                end
            end
        end
    endfunction

    function [8:0] dec_word_steps;
        input [8:0] value_in;
        begin
            if (value_in > WORD_STEPS)
                dec_word_steps = value_in - WORD_STEPS;
            else
                dec_word_steps = 9'd0;
        end
    endfunction

    assign pixel1_rising_edge   = pixel1_sync2 & ~pixel1_sync3;
    assign pixel2_rising_edge   = pixel2_sync2 & ~pixel2_sync3;
    assign pixel_mode_rising    = pixel_mode & ~pixel_mode_prev;
    assign pixel_reset_falling  = ~pixel_reset & pixel_reset_prev & pixel_mode;
    assign pixel_param_update_req = pixel_mode_rising || (pixel_mode && pixel_reset) ||
                                    pixel_reset_falling || pixel_changed_d2;
    assign pixel_param_load_req   = pixel_mode && param_update_pending;
    assign pixel_addr           = {pixel_y_cnt, pixel_x_cnt};
    assign current_pixel        = pixel_addr;

    assign div_ratio_safe = (div_ratio_sync2 == {DIV_BITS{1'b0}})
        ? {{(DIV_BITS-1){1'b0}}, 1'b1}
        : div_ratio_sync2;

    assign sig2_trigger = 1'b1;
    assign sig3_trigger = (div_count == {DIV_BITS{1'b0}});

    assign sig2_accept = sig2_trigger && sig2_sched_valid && !sig2_active;
    assign sig3_accept = sig3_trigger && sig3_sched_valid && !sig3_active;

    assign sig2_src_valid = sig2_accept || sig2_active;
    assign sig2_src_rise  = sig2_accept ? sig2_rise_step : sig2_rise_rem;
    assign sig2_src_fall  = sig2_accept ? sig2_fall_step : sig2_fall_rem;
    assign sig3_src_valid = sig3_accept || sig3_active;
    assign sig3_src_rise  = sig3_accept ? sig3_rise_step : sig3_rise_rem;
    assign sig3_src_fall  = sig3_accept ? sig3_fall_step : sig3_fall_rem;

    assign sig2_word = build_word(sig2_src_valid, sig2_src_rise, sig2_src_fall);
    assign sig3_word = build_word(sig3_src_valid, sig3_src_rise, sig3_src_fall);
    assign gate_word = sig2_word | sig3_word;

    always @(posedge sys_clk) begin
        if (sys_rst) begin
            pixel1_sync1 <= 1'b0;
            pixel1_sync2 <= 1'b0;
            pixel1_sync3 <= 1'b0;
            pixel2_sync1 <= 1'b0;
            pixel2_sync2 <= 1'b0;
            pixel2_sync3 <= 1'b0;
            pixel_x_cnt  <= {PIXEL_X_BITS{1'b0}};
            pixel_y_cnt  <= {PIXEL_Y_BITS{1'b0}};
            pixel_changed <= 1'b0;
            pixel_changed_d1 <= 1'b0;
            pixel_changed_d2 <= 1'b0;
            latched_sig2_en           <= 1'b0;
            latched_sig2_delay_coarse <= 4'd0;
            latched_sig2_delay_fine   <= 5'd0;
            latched_sig2_width_coarse <= 3'd0;
            latched_sig2_width_fine   <= 5'd1;
            latched_sig3_en           <= 1'b0;
            latched_sig3_delay_coarse <= 4'd0;
            latched_sig3_delay_fine   <= 5'd0;
            latched_sig3_width_coarse <= 3'd0;
            latched_sig3_width_fine   <= 5'd1;
            param_update_pending      <= 1'b1;
            pixel_load_delay          <= 2'd0;
            pixel_mode_prev           <= 1'b0;
            pixel_reset_prev          <= 1'b0;
        end else begin
            pixel1_sync1 <= pixel1_in;
            pixel1_sync2 <= pixel1_sync1;
            pixel1_sync3 <= pixel1_sync2;
            pixel2_sync1 <= pixel2_in;
            pixel2_sync2 <= pixel2_sync1;
            pixel2_sync3 <= pixel2_sync2;

            if (pixel_reset) begin
                pixel_x_cnt      <= {PIXEL_X_BITS{1'b0}};
                pixel_y_cnt      <= {PIXEL_Y_BITS{1'b0}};
                pixel_changed    <= 1'b0;
                pixel_changed_d1 <= 1'b0;
                pixel_changed_d2 <= 1'b0;
            end else begin
                pixel_changed <= 1'b0;

                if (pixel2_rising_edge) begin
                    pixel_x_cnt   <= {PIXEL_X_BITS{1'b0}};
                    pixel_y_cnt   <= (pixel_y_cnt == {PIXEL_Y_BITS{1'b1}})
                        ? {PIXEL_Y_BITS{1'b0}}
                        : pixel_y_cnt + 1'b1;
                    pixel_changed <= 1'b1;
                end else if (pixel1_rising_edge) begin
                    if (pixel_x_cnt == {PIXEL_X_BITS{1'b1}}) begin
                        pixel_x_cnt <= {PIXEL_X_BITS{1'b0}};
                        pixel_y_cnt <= (pixel_y_cnt == {PIXEL_Y_BITS{1'b1}})
                            ? {PIXEL_Y_BITS{1'b0}}
                            : pixel_y_cnt + 1'b1;
                    end else begin
                        pixel_x_cnt <= pixel_x_cnt + 1'b1;
                    end
                    pixel_changed <= 1'b1;
                end

                pixel_changed_d1 <= pixel_changed;
                pixel_changed_d2 <= pixel_changed_d1;
            end

            pixel_mode_prev  <= pixel_mode;
            pixel_reset_prev <= pixel_reset;

            if (pixel_param_update_req) begin
                param_update_pending <= 1'b1;
                pixel_load_delay     <= 2'd2;
            end else if (pixel_param_load_req) begin
                if (pixel_load_delay != 2'd0) begin
                    pixel_load_delay <= pixel_load_delay - 1'b1;
                end else begin
                    latched_sig2_en           <= ram_rd_data[0];
                    latched_sig2_delay_coarse <= ram_rd_data[5:2];
                    latched_sig2_delay_fine   <= ram_rd_data[10:6];
                    latched_sig2_width_coarse <= ram_rd_data[13:11];
                    latched_sig2_width_fine   <= ram_rd_data[18:14];
                    latched_sig3_en           <= ram_rd_data[1];
                    latched_sig3_delay_coarse <= ram_rd_data[22:19];
                    latched_sig3_delay_fine   <= ram_rd_data[27:23];
                    latched_sig3_width_coarse <= ram_rd_data[30:28];
                    latched_sig3_width_fine   <= ram_rd_data[35:31];
                    param_update_pending      <= 1'b0;
                end
            end

            if (!pixel_mode) begin
                latched_sig2_en           <= sig2_enable;
                latched_sig2_delay_coarse <= sig2_delay_coarse;
                latched_sig2_delay_fine   <= sig2_delay_fine;
                latched_sig2_width_coarse <= sig2_width_coarse;
                latched_sig2_width_fine   <= sig2_width_fine;
                latched_sig3_en           <= sig3_enable;
                latched_sig3_delay_coarse <= sig3_delay_coarse;
                latched_sig3_delay_fine   <= sig3_delay_fine;
                latched_sig3_width_coarse <= sig3_width_coarse;
                latched_sig3_width_fine   <= sig3_width_fine;
                param_update_pending      <= 1'b0;
                pixel_load_delay          <= 2'd0;
            end
        end
    end

    pixel_param_ram_36b u_pixel_ram (
        .clka   (sys_clk),
        .wea    (ram_wr_en),
        .addra  (ram_wr_addr),
        .dina   (ram_wr_data),
        .douta  (),
        .clkb   (sys_clk),
        .enb    (1'b1),
        .web    (1'b0),
        .addrb  (pixel_addr),
        .dinb   (36'd0),
        .doutb  (ram_rd_data)
    );

    always @(posedge clk_div) begin
        if (sys_rst) begin
            cfg_sync1       <= 36'd0;
            cfg_sync2       <= 36'd0;
            div_ratio_sync1 <= {{(DIV_BITS-1){1'b0}}, 1'b1};
            div_ratio_sync2 <= {{(DIV_BITS-1){1'b0}}, 1'b1};
            div_count       <= {DIV_BITS{1'b0}};
            sig2_active     <= 1'b0;
            sig2_rise_rem   <= 9'd0;
            sig2_fall_rem   <= 9'd0;
            sig3_active     <= 1'b0;
            sig3_rise_rem   <= 9'd0;
            sig3_fall_rem   <= 9'd0;
        end else begin
            cfg_sync1 <= {
                latched_sig3_width_fine,
                latched_sig3_width_coarse,
                latched_sig3_delay_fine,
                latched_sig3_delay_coarse,
                latched_sig3_en,
                latched_sig2_width_fine,
                latched_sig2_width_coarse,
                latched_sig2_delay_fine,
                latched_sig2_delay_coarse,
                latched_sig2_en
            };
            cfg_sync2 <= cfg_sync1;
            div_ratio_sync1 <= div_ratio;
            div_ratio_sync2 <= div_ratio_sync1;

            if (div_count >= div_ratio_safe - 1'b1)
                div_count <= {DIV_BITS{1'b0}};
            else
                div_count <= div_count + 1'b1;

            sig2_active   <= sig2_src_valid && (sig2_src_fall > WORD_STEPS);
            sig2_rise_rem <= dec_word_steps(sig2_src_rise);
            sig2_fall_rem <= dec_word_steps(sig2_src_fall);
            sig3_active   <= sig3_src_valid && (sig3_src_fall > WORD_STEPS);
            sig3_rise_rem <= dec_word_steps(sig3_src_rise);
            sig3_fall_rem <= dec_word_steps(sig3_src_fall);
        end
    end

    pulse_interval_sched u_sig2_sched (
        .enable         (cfg_sync2[0]),
        .delay_coarse   (cfg_sync2[4:1]),
        .delay_fine     (cfg_sync2[9:5]),
        .width_coarse   (cfg_sync2[12:10]),
        .width_fine     (cfg_sync2[17:13]),
        .interval_valid (sig2_sched_valid),
        .rise_step      (sig2_rise_step),
        .fall_step      (sig2_fall_step)
    );

    pulse_interval_sched u_sig3_sched (
        .enable         (cfg_sync2[18]),
        .delay_coarse   (cfg_sync2[22:19]),
        .delay_fine     (cfg_sync2[27:23]),
        .width_coarse   (cfg_sync2[30:28]),
        .width_fine     (cfg_sync2[35:31]),
        .interval_valid (sig3_sched_valid),
        .rise_step      (sig3_rise_step),
        .fall_step      (sig3_fall_step)
    );

endmodule
