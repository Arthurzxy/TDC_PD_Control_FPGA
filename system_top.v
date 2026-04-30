//==============================================================================
// system_top.v
//------------------------------------------------------------------------------
// Module: FPGA System Top-Level Integration
// 模块说明：整板 FPGA 顶层集成模块
//
// Purpose:
// 中文说明：
//   本模块是整板统一入口，负责把 GPX2、FT601、Gate、温控、DAC、Flash
//   等子模块接到一起，并完成多时钟域之间的数据/配置协调。
//   Master integration module for the multi-chip TDC measurement platform.
//   Instantiates and connects all peripheral controllers, manages clock domains,
//   and handles command/data flow between FT601 USB and internal modules.
//
// Architecture Overview:
//   This module serves as the top-level wrapper connecting:
//   1. GPX2 TDC Interface (gpx2_top) - Time-to-Digital Converter data capture
//   2. FT601 USB3.0 Interface (ft601_fifo_if) - Host communication
//   3. Command Dispatcher (cmd_dispatcher) - Host command parsing
//   4. Packet Builder (packet_builder) - Data packet formatting
//   5. Gate Generator (gate_gen_top) - Precision timing gate generation
//   6. AD5686 DAC - Multi-channel DAC for bias/control
//   7. DAC8881 - Single-channel DAC for TEC control
//   8. NB6L295 - Programmable delay chip
//   9. ADS8370 ADC Controller - Temperature sensing
//   10. TEC PID - Temperature control loop
//   11. Counter - SPAD event counting
//   12. Flash Store - Configuration persistence
//
// Clock Domains:
// 中文说明：
//   - sys_clk：高速主控域，负责 GPX2、Flash、主状态机
//   - ft_clk：USB 通信域，负责上下位机收发
//   - clk_20m：慢速模拟控制域，负责 ADC / TEC / DAC8881
//   - gate_clk_div：Gate 逻辑域
//   - gpx2_lclk：GPX2 源同步接收域
//   - sys_clk: Main system clock for GPX2 and most logic
//   - ft_clk: FT601 clock (66.67 MHz or 100 MHz, sourced by FT601)
//   - clk_20m: 20 MHz clock for ADC/TEC control
//   - gate_clk_div: Divided clock for gate generator
//   - gpx2_lclk: GPX2 data clock from chip
//
// Data Path (Uplink):
// 中文说明：
//   GPX2 原始事件 -> 异步 FIFO -> packet_builder -> FT601
//   GPX2 LVDS -> gpx2_top -> async FIFO -> packet_builder -> tx_fifo_36b -> ft601
//
// Command Path (Downlink):
// 中文说明：
//   FT601 命令 -> cmd_dispatcher -> CDC 原子跨域 -> 各功能模块
//   FT601 RX -> cmd_dispatcher -> CDC bridges -> target modules
//
// Related Documents:
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md (complete project documentation)
//   - GPX2 Datasheet
//   - FT601 Datasheet
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module system_top #(
    parameter integer NUM_CH      = 4,         // Number of GPX2 TDC channels
    parameter integer REFID_BITS  = 24,        // GPX2 reference ID width
    parameter integer TSTOP_BITS  = 20,        // GPX2 time-of-stop width
    parameter integer FT_DATA_W   = 32         // FT601 data width (32-bit)
)(
    input  wire                    sys_clk_20M,
    input  wire                    sys_rst_n,

    output wire                    gpx2_ssn,
    output wire                    gpx2_sck,
    output wire                    gpx2_mosi,
    input  wire                    gpx2_miso,
    input  wire                    gpx2_lclkout_p,
    input  wire                    gpx2_lclkout_n,
    output wire                    gpx2_lclkin_p,
    output wire                    gpx2_lclkin_n,
    input  wire [NUM_CH-1:0]       gpx2_sdo_p,
    input  wire [NUM_CH-1:0]       gpx2_sdo_n,
    input  wire [NUM_CH-1:0]       gpx2_frame_p,
    input  wire [NUM_CH-1:0]       gpx2_frame_n,

    // FT601 drives `ft_clk`; the board-side FT601 configuration chooses
    // whether this runs at 66.67 MHz or 100 MHz.
    input  wire                    ft_clk,
    inout  wire [FT_DATA_W-1:0]    ft_data,
    inout  wire [3:0]              ft_be,
    input  wire                    ft_txe_n,
    input  wire                    ft_rxf_n,
    output wire                    ft_wr_n,
    output wire                    ft_rd_n,
    output wire                    ft_oe_n,
    output wire                    ft_siwu_n,
    output wire                    ft_reset_n,
    output wire                    ft_wakeup_n,
    output wire                    ft_gpio0,
    output wire                    ft_gpio1,
    // User flash access shares the configuration flash. `CCLK_0` is driven by
    // STARTUPE2 inside the flash store module, so only D0/D1/CS# appear here.
    output wire                    flash_spi_d0,
    input  wire                    flash_spi_d1,
    output wire                    flash_spi_cs_n,

    output wire                    ad5686_clk,
    output wire                    ad5686_din,
    output wire                    ad5686_cs,

    input  wire                    counter_ava_p,
    input  wire                    counter_ava_n,

    output wire                    dac8881_clk,
    output wire                    dac8881_din,
    output wire                    dac8881_cs,

    input  wire                    gate_in_outside,
    output wire                    gate_out,
    output wire                    latch_enable,
    output wire                    gate_out_hp_p,
    output wire                    gate_out_hp_n,
    output wire                    gate_out_ext_p,
    output wire                    gate_out_ext_n,

    output wire                    nb6l295_en,
    output wire                    nb6l295_sdin,
    output wire                    nb6l295_sclk,
    output wire                    nb6l295_sload,

    input  wire                    temp_adc_sdo,
    output wire                    temp_adc_sclk,
    output wire                    temp_adc_cs,
    output wire                    temp_adc_cv,

    input  wire                    gate_ref_in_p,
    input  wire                    gate_ref_in_n,
    input  wire                    gate_pixel_in_p,
    input  wire                    gate_pixel_in_n,
    input  wire                    gate_pixel2_in_p,
    input  wire                    gate_pixel2_in_n
);

    // 关键宽度参数集中在顶层，后续协议或配置字扩展时便于统一维护。
    localparam integer GPX2_FIFO_W          = REFID_BITS + TSTOP_BITS + 2;
    localparam integer GATE_CFG_W           = 49;
    localparam integer AD5686_CFG_W         = 64;
    localparam integer NB6_CFG_W            = 19;
    localparam integer FLASH_PARAM_W        = GATE_CFG_W + 16 + NB6_CFG_W + AD5686_CFG_W;
    localparam integer DBG_FT_CMD_CTRL_W    = 18;
    localparam integer DBG_FT_CMD_DATA_W    = 160;
    localparam integer DBG_ANALOG_CTRL_W    = 12;
    localparam integer DBG_ANALOG_DATA_W    = 128;
    localparam integer DBG_FT_UPLOAD_CTRL_W = 16;
    localparam integer DBG_FT_UPLOAD_DATA_W = 164;
    localparam integer DBG_SYS_COUNT_CTRL_W = 8;
    localparam integer DBG_SYS_COUNT_DATA_W = 32;
    localparam integer FT_STATUS_TICK_CYCLES = 27'd66_666_665;
    localparam [GATE_CFG_W-1:0] GATE_CFG_DEFAULT = {
        1'b0,
        5'd10,
        3'd0,
        5'd0,
        4'd0,
        5'd10,
        3'd0,
        5'd0,
        4'd0,
        1'b0,
        1'b0,
        12'd1
    };

    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_sync_ff;
    (* ASYNC_REG = "TRUE" *) reg [2:0] ft_rst_sync_ff;
    (* ASYNC_REG = "TRUE" *) reg [2:0] clk20_rst_sync_ff;
    reg                    ft_hb_toggle;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ft_hb_sync_sys;
    reg [15:0]             ft_hb_timeout_sys;
    reg                    ft_clk_alive_sys;
    reg                    ft_clk_lost_sys;
    reg [31:0]             raw20m_hb_counter;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sys_locked_sync_20m;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ft_hb_sync_20m;
    localparam [17:0]       FT_RESET_HOLD_CYCLES = 18'd200000; // 10 ms at 20 MHz
    reg [17:0]             ft_reset_hold_cnt;
    reg                    ft_reset_release;
    wire      sys_rst;
    wire      ft_rst;
    wire      clk_20m_rst;
    // `sys_clk` is created by clk_wiz_1 from the external 20 MHz oscillator.
    // Keep these nets explicit so timing/debug sees a single, named clock path.
    wire      sys_clk;
    wire      sys_clk_pll_reset;
    wire      sys_clk_pll_locked;


    // Differential clock input buffer

    // BUFG-buffered 20 MHz for fabric logic (ILA, synchronizers). The MMCM
    // still uses the direct IBUF output via the dedicated clock route, but the
    // ILA BRAM and other non-MMCM loads need low-skew global distribution.
    wire      sys_clk_20M_bufg;
    BUFG bufg_sys_clk_20M (
        .I(sys_clk_20M),
        .O(sys_clk_20M_bufg)
    );

    wire      clk_20m;
    wire      clk_200m;
    wire      pll_locked;
    wire      gpx2_lclk_250m;
    wire      gpx2_lclk_locked;

    wire                    gpx2_stream_valid;
    wire                    gpx2_stream_ready;
    wire [31:0]             gpx2_stream_data;
    wire                    gpx2_stream_last;
    wire                    gpx2_cfg_done;
    wire                    gpx2_cfg_error;
    wire                    gpx2_event_overflow;
    wire [31:0]             gpx2_photon_valid_count;
    wire [31:0]             gpx2_laser_count;
    wire [31:0]             gpx2_detector_count;

    wire [GPX2_FIFO_W-1:0]  gpx2_sys_ft_din;
    wire [GPX2_FIFO_W-1:0]  gpx2_sys_ft_dout;
    wire                    gpx2_sys_ft_full;
    wire                    gpx2_sys_ft_empty;
    wire                    gpx2_sys_ft_almost_full;
    wire                    gpx2_sys_ft_wr_rst_busy;
    wire                    gpx2_sys_ft_rd_rst_busy;
    wire                    gpx2_sys_ft_wr_en;
    wire                    gpx2_sys_ft_rd_en;

    wire [31:0]             ft_rx_data;
    wire                    ft_rx_valid;
    wire                    ft_rx_ready;
    wire                    ft_rx_fire;
    wire                    ft_tx_ready;
    wire [2:0]              ft601_dbg_state;
    wire [1:0]              cmd_dbg_state;
    wire [7:0]              cmd_dbg_cmd_id;
    wire [3:0]              cmd_dbg_payload_len;
    wire [3:0]              cmd_dbg_payload_idx;

    wire                    ad5686_start_ft;
    wire [15:0]             ad5686_data1_ft;
    wire [15:0]             ad5686_data2_ft;
    wire [15:0]             ad5686_data3_ft;
    wire [15:0]             ad5686_data4_ft;
    wire [23:0]             gate_hold_off_time_ft;
    wire                    nb6l295_start_ft;
    wire [8:0]              nb6l295_delay_a_ft;
    wire [8:0]              nb6l295_delay_b_ft;
    wire                    nb6l295_enable_ft;
    wire [15:0]             tec_temp_set_ft;
    wire                    tec_temp_set_valid_ft;
    wire                    gpx2_start_cfg_ft;
    wire [11:0]             gate_div_ratio_ft;
    wire                    gate_sig2_enable_ft;
    wire                    gate_sig3_enable_ft;
    wire [3:0]              gate_sig2_delay_coarse_ft;
    wire [4:0]              gate_sig2_delay_fine_ft;
    wire [2:0]              gate_sig2_width_coarse_ft;
    wire [4:0]              gate_sig2_width_fine_ft;
    wire [3:0]              gate_sig3_delay_coarse_ft;
    wire [4:0]              gate_sig3_delay_fine_ft;
    wire [2:0]              gate_sig3_width_coarse_ft;
    wire [4:0]              gate_sig3_width_fine_ft;
    wire                    gate_pixel_mode_ft;
    wire                    gate_cfg_valid_ft;
    wire                    gate_pixel_reset_ft;
    wire                    gate_ram_wr_en_ft;
    wire [13:0]             gate_ram_wr_addr_ft;
    wire [35:0]             gate_ram_wr_data_ft;

    wire [AD5686_CFG_W-1:0] ad5686_cfg_ft;
    reg  [AD5686_CFG_W-1:0] ad5686_cfg_20m;
    wire [AD5686_CFG_W-1:0] ad5686_cfg_ft_20m;
    wire [AD5686_CFG_W-1:0] ad5686_cfg_flash_20m;
    reg  [15:0]             tec_temp_set_20m;
    wire [15:0]             tec_temp_set_ft_20m;
    wire [15:0]             tec_temp_set_flash_20m;
    reg                     ad5686_start_20m;
    wire                    ad5686_start_ft_20m;
    wire                    ad5686_start_flash_20m;
    wire                    tec_temp_set_ft_valid_20m;
    wire                    tec_temp_set_flash_valid_20m;

    wire [NB6_CFG_W-1:0]    nb6_cfg_ft;
    reg  [NB6_CFG_W-1:0]    nb6_cfg_sys;
    wire [NB6_CFG_W-1:0]    nb6_cfg_ft_sys;
    wire                    ad5686_cmd_ready;
    reg [31:0]              dbg_ft_rx_data_hold_ft;
    reg [17:0]              dbg_ft_ctrl_hold_ft;
    reg [15:0]              dbg_ad5686_data1_hold_ft;
    reg [15:0]              dbg_ad5686_data2_hold_ft;
    reg                     dbg_ft_rx_toggle_ft;
    reg                     dbg_ad5686_toggle_ft;
    (* ASYNC_REG = "TRUE" *) reg [2:0] dbg_ft_rx_toggle_sync_sys;
    (* ASYNC_REG = "TRUE" *) reg [2:0] dbg_ad5686_toggle_sync_sys;
    reg [31:0]              dbg_ft_rx_data_sys;
    reg [17:0]              dbg_ft_ctrl_sys;
    reg [15:0]              dbg_ad5686_data1_sys;
    reg [15:0]              dbg_ad5686_data2_sys;
    reg                     dbg_ft_rx_event_sys;
    reg                     dbg_ad5686_event_sys;
    wire                    dbg_ft_rx_toggle_edge_sys;
    wire                    dbg_ad5686_toggle_edge_sys;
    wire                    nb6_cmd_ready;
    wire                    tec_temp_cmd_ready;
    wire                    gpx2_cfg_cmd_ready;
    wire                    gate_cfg_cmd_ready;
    wire                    gate_pixel_cmd_ready;
    wire                    gate_ram_cmd_ready;
    wire                    gate_cfg_cmd_ready_raw;
    wire                    gate_pixel_cmd_ready_raw;
    wire                    gate_ram_cmd_ready_raw;
    wire                    flash_cmd_ready_ft;
    wire                    nb6l295_start_ft_sys;
    reg                     nb6l295_start_sys;
    wire                    gpx2_start_cfg_sys;
    wire                    flash_save_req_ft;
    wire                    flash_load_req_ft;
    wire                    flash_busy_ft;
    wire                    flash_error_ft;
    wire                    flash_save_cdc_ready_ft;
    wire                    flash_load_cdc_ready_ft;

    wire [GATE_CFG_W-1:0]   gate_cfg_ft;
    reg  [GATE_CFG_W-1:0]   gate_cfg_sys;
    wire [GATE_CFG_W-1:0]   gate_cfg_ft_gate;
    wire [GATE_CFG_W-1:0]   gate_cfg_flash_gate;
    wire                    gate_cfg_ft_valid_gate;
    wire                    gate_cfg_flash_valid_gate;
    wire                    gate_pixel_reset_sys;
    wire                    gate_pixel_reset_core;
    wire                    gate_ram_wr_en_sys;
    wire [49:0]             gate_ram_cfg_ft;
    wire [49:0]             gate_ram_cfg_sys;
    wire                    gate_ram_wr_en_core;
    wire [13:0]             gate_ram_wr_addr_core;
    wire [35:0]             gate_ram_wr_data_core;
    wire                    flash_gate_ram_valid_sys;
    wire                    flash_gate_ram_ready_sys;
    wire                    flash_gate_ram_valid_gate;
    wire [50:0]             flash_gate_ram_cfg_gate;
    wire                    flash_gate_ram_last_gate;
    wire [13:0]             flash_gate_ram_wr_addr_gate;
    wire [35:0]             flash_gate_ram_wr_data_gate;

    wire                    gate_sig2_enable_sys;
    wire                    gate_sig3_enable_sys;
    wire [11:0]             gate_div_ratio_sys;
    wire [3:0]              gate_sig2_delay_coarse_sys;
    wire [4:0]              gate_sig2_delay_fine_sys;
    wire [2:0]              gate_sig2_width_coarse_sys;
    wire [4:0]              gate_sig2_width_fine_sys;
    wire [3:0]              gate_sig3_delay_coarse_sys;
    wire [4:0]              gate_sig3_delay_fine_sys;
    wire [2:0]              gate_sig3_width_coarse_sys;
    wire [4:0]              gate_sig3_width_fine_sys;
    wire                    gate_pixel_mode_sys;
    wire [13:0]             gate_ram_wr_addr_sys;
    wire [35:0]             gate_ram_wr_data_sys;

    wire [15:0]             ad5686_data1_20m;
    wire [15:0]             ad5686_data2_20m;
    wire [15:0]             ad5686_data3_20m;
    wire [15:0]             ad5686_data4_20m;
    wire [8:0]              nb6l295_delay_a_sys;
    wire [8:0]              nb6l295_delay_b_sys;
    wire                    nb6l295_enable_sys;

    wire                    counter_ava_se;
    wire [31:0]             counter_count_sys;
    wire [15:0]             temp_avg_20m;
    wire [15:0]             temp_adc_data;
    wire                    pid_start;
    wire                    adc_start;
    wire [15:0]             tec_dac_out;
    wire                    tec_dac_start;

    wire [31:0]             counter_count_ft;
    wire [15:0]             temp_avg_ft;
    wire [4:0]              status_sys_bits_ft;

    wire                    gate_ref_clk;
    wire                    gate_pixel1_se;
    wire                    gate_pixel2_se;
    wire                    gate_clk_div;
    wire                    gate_clk_ser;

    wire                    gate_clk_locked;
    wire                    gate_core_rst_async;
    wire                    gate_core_rst;
    wire [9:0]              gate_word;
    wire [13:0]             gate_current_pixel;
    (* ASYNC_REG = "TRUE" *) reg [2:0] gate_rst_sync_ff;

    reg [26:0]              slow_timer_ft;
    reg                     slow_tick_ft;
    reg [31:0]              uptime_seconds_ft;
    reg                     status_valid_ft;
    reg [15:0]              status_flags_ft;
    reg [31:0]              usb_drop_count_ft;
    wire                    ack_valid_ft;
    wire                    ack_ready_ft;
    wire [7:0]              ack_cmd_id_ft;
    wire [7:0]              ack_status_ft;
    wire [31:0]             ack_data_ft;

    wire [31:0]             pkt_tx_data;
    wire [3:0]              pkt_tx_be;
    wire                    pkt_tx_valid;
    wire                    pkt_tx_ready;
    wire                    packet_event_ready_wire;
    wire [35:0]             tx_fifo_din;
    wire [35:0]             tx_fifo_dout;
    wire                    tx_fifo_wr_en;
    wire                    tx_fifo_rd_en;
    wire                    tx_fifo_full;
    wire                    tx_fifo_empty;
    wire [FLASH_PARAM_W-1:0] flash_param_bundle_ft;
    wire [FLASH_PARAM_W-1:0] flash_param_bundle_sys;
    wire [FLASH_PARAM_W-1:0] flash_param_loaded_sys;
    wire [AD5686_CFG_W-1:0]  flash_ad5686_cfg_sys;
    wire [NB6_CFG_W-1:0]     flash_nb6_cfg_sys;
    wire [15:0]              flash_tec_temp_set_sys;
    wire [GATE_CFG_W-1:0]    flash_gate_cfg_sys;
    wire                     flash_save_req_sys;
    wire                     flash_load_req_sys;
    wire                     flash_load_valid_sys;
    wire                     flash_busy_sys;
    wire                     flash_error_sys;
    wire [1:0]               flash_status_ft;
    wire                     flash_ad5686_cfg_ready_sys;
    wire                     flash_tec_cfg_ready_sys;
    wire                     flash_gate_cfg_ready_sys;
    wire [13:0]              flash_pixel_rd_addr_sys;
    wire [35:0]              pixel_shadow_rd_data_sys;
    wire [13:0]              flash_pixel_load_addr_sys;
    wire [35:0]              flash_pixel_load_data_sys;
    wire                     flash_pixel_wr_en_sys;
    wire [13:0]              flash_pixel_wr_addr_sys;
    wire [35:0]              flash_pixel_wr_data_sys;

    // Keep these structured observation buses available for optional future
    // debug, but do not mark them for automatic ILA insertion in the default
    // build. The previous mark_debug + XDC create_debug_core flow inserted
    // several large ILAs and dominated timing closure.
    wire [DBG_FT_CMD_CTRL_W-1:0] dbg_ft_cmd_ctrl_bus;
    wire [DBG_FT_CMD_DATA_W-1:0] dbg_ft_cmd_data_bus;
    wire [DBG_ANALOG_CTRL_W-1:0] dbg_analog_ctrl_bus;
    wire [DBG_ANALOG_DATA_W-1:0] dbg_analog_data_bus;
    wire [DBG_FT_UPLOAD_CTRL_W-1:0] dbg_ft_upload_ctrl_bus;
    wire [DBG_FT_UPLOAD_DATA_W-1:0] dbg_ft_upload_data_bus;
    wire [DBG_SYS_COUNT_CTRL_W-1:0] dbg_sys_count_ctrl_bus;
    wire [DBG_SYS_COUNT_DATA_W-1:0] dbg_sys_count_data_bus;

    // Keep clk_wiz_1 running whenever the 20 MHz board oscillator is present.
    // dbg_hub uses sys_clk and Vivado 2024.2 does not allow a 20 MHz hub clock,
    // so tying the PLL reset low avoids losing JTAG debug while sys_rst_n is
    // asserted. Fabric logic still uses sys_rst_n for its own reset.
    assign sys_clk_pll_reset = 1'b0;

    clk_wiz_1 clk_pll_100M (
    // Clock out ports
    .clk_out1(sys_clk),     // output clk_out1
    // Status and control signals
    .reset(sys_clk_pll_reset), // input reset
    .locked(sys_clk_pll_locked),       // output locked
   // Clock in ports
    .clk_in1(sys_clk_20M)      // input clk_in1
    );

    ila_cmd_new ila_cmd_1 (
	// Always-on monitor. Clock it from sys_clk so Hardware Manager can arm it
	// even when FT601 suspends and stops ft_clk. FT-domain multi-bit signals
	// are shown as event snapshots, not live asynchronous buses.
	.clk(sys_clk), // input wire clk

	.probe0(dbg_ft_rx_data_sys),       // [31:0] last accepted FT RX word
	.probe1(dbg_ft_rx_event_sys),      // [0:0]  one sys_clk pulse per RX word snapshot
	.probe2(ft_clk_lost_sys),          // [0:0]  FT clock timeout indicator
	.probe3(dbg_ad5686_data1_sys),     // [15:0] last AD5686 value 1 snapshot
	.probe4(dbg_ad5686_data2_sys),     // [15:0] last AD5686 value 2 snapshot
	.probe5(dbg_ad5686_event_sys),     // [0:0]  one sys_clk pulse per AD5686 command
	.probe6(ft_clk_alive_sys),         // [0:0]  FT clock heartbeat observed
	// probe7[17:0] = {
	//   ft_rxf_n, ft_txe_n, ft_rd_n, ft_oe_n, ft_wr_n,
	//   ft_rx_valid, ft_rx_ready, ft_rx_fire, ft601_dbg_state[2:0],
	//   ad5686_start_ft, ack_valid_ft, ack_ready_ft,
	//   pkt_tx_valid, pkt_tx_ready, tx_fifo_empty, ft_tx_ready
	// }
	.probe7(dbg_ft_ctrl_sys)      // [17:0] FT control snapshot at last RX word
    );

    // Keep one always-on debug core in the 20 MHz domain so JTAG debug
    // does not depend on clk_wiz/sys_clk or FT601/ft_clk being alive first.
    // This isolates the first board-level questions:
    //   1) Is the external 20 MHz oscillator reaching the FPGA?
    //   2) Does clk_wiz ever assert LOCKED?
    //   3) Does the FT601 clock domain toggle at all?


    assign dbg_ft_cmd_ctrl_bus = {
        ft_rxf_n,
        ft_txe_n,
        ft_rd_n,
        ft_oe_n,
        ft_wr_n,
        ft_rx_valid,
        ft_rx_ready,
        ft_rx_fire,
        ft601_dbg_state,
        ad5686_start_ft,
        ack_valid_ft,
        ack_ready_ft,
        pkt_tx_valid,
        pkt_tx_ready,
        tx_fifo_empty,
        ft_tx_ready
    };

    assign ft_rx_fire = ft_rx_valid & ft_rx_ready;

    assign dbg_ft_cmd_data_bus = {
        ack_data_ft,
        ack_status_ft,
        ack_cmd_id_ft,
        tec_temp_set_ft,
        ad5686_cfg_ft,
        ft_rx_data
    };

    ila_cmd_exec u_ila_cmd_exec (
        .clk(ft_clk),
        .probe0(cmd_dbg_state),
        .probe1(ft_rx_data),
        .probe2(ft_rx_valid),
        .probe3(ft_rx_ready),
        .probe4(ft_rx_fire),
        .probe5(ad5686_cmd_ready),
        .probe6(ack_ready_ft),
        .probe7(ack_valid_ft),
        .probe8(cmd_dbg_cmd_id),
        .probe9(ack_status_ft),
        .probe10({8'd0, cmd_dbg_payload_idx, cmd_dbg_payload_len, ack_status_ft, ack_cmd_id_ft}),
        .probe11(ad5686_start_ft),
        .probe12(ft_rxf_n),
        .probe13(ft_rd_n),
        .probe14(ft_oe_n),
        .probe15(ft_wr_n),
        .probe16(ft_txe_n),
        .probe17(pkt_tx_valid),
        .probe18(pkt_tx_ready),
        .probe19(tx_fifo_wr_en),
        .probe20(tx_fifo_rd_en),
        .probe21(tx_fifo_empty),
        .probe22(ft_tx_ready),
        .probe23(pkt_tx_data),
        .probe24(tx_fifo_dout)
    );

    assign dbg_analog_ctrl_bus = {
        clk_20m_rst,
        ad5686_start_ft_20m,
        ad5686_start_flash_20m,
        ad5686_start_20m,
        tec_temp_set_ft_valid_20m,
        tec_temp_set_flash_valid_20m,
        adc_start,
        pid_start,
        tec_dac_start,
        ad5686_cs,
        dac8881_cs,
        temp_adc_cs
    };

    assign dbg_analog_data_bus = {
        tec_dac_out,
        temp_avg_20m,
        temp_adc_data,
        tec_temp_set_20m,
        ad5686_cfg_20m
    };

    assign dbg_ft_upload_ctrl_bus = {
        slow_tick_ft,
        status_valid_ft,
        packet_event_ready_wire,
        ~gpx2_sys_ft_empty,
        pkt_tx_valid,
        pkt_tx_ready,
        tx_fifo_wr_en,
        tx_fifo_rd_en,
        tx_fifo_full,
        tx_fifo_empty,
        ft_tx_ready,
        ft_txe_n,
        ack_valid_ft,
        ack_ready_ft,
        flash_busy_ft,
        flash_error_ft
    };

    assign dbg_ft_upload_data_bus = {
        tx_fifo_din,
        usb_drop_count_ft,
        uptime_seconds_ft,
        counter_count_ft,
        temp_avg_ft,
        status_flags_ft
    };

    // Full-chain debug ILAs for GPX2 photon-event bring-up.
    //
    // u_ila_chain_sys: sys_clk side. Use it to confirm GPX2 configuration,
    // photon stream creation, sys->ft FIFO writes, and key parameters after CDC.
    //
    // u_ila_chain_ft: ft_clk side. Use it to confirm host command decoding,
    // packet building, upload FIFO flow, and FT601 write-side handshakes.
    //
    // Create the matching Vivado IPs with:
    //   source debug/create_chain_ila_ip.tcl
    ila_chain_sys u_ila_chain_sys (
        .clk(sys_clk),
        .probe0(gpx2_stream_data),
        .probe1(gpx2_sys_ft_din),
        .probe2({
            4'd0,
            gpx2_start_cfg_sys,
            gpx2_cfg_done,
            gpx2_cfg_error,
            gpx2_lclk_locked,
            gpx2_event_overflow,
            gpx2_stream_valid,
            gpx2_stream_ready,
            gpx2_stream_last,
            gpx2_sys_ft_wr_en,
            gpx2_sys_ft_full,
            gpx2_sys_ft_almost_full
        }),
        .probe3(gpx2_photon_valid_count),
        .probe4(gpx2_laser_count),
        .probe5(gpx2_detector_count),
        .probe6(counter_count_sys),
        .probe7(gate_cfg_sys),
        .probe8(gate_ram_wr_data_sys),
        .probe9(gate_ram_wr_addr_sys),
        .probe10({
            gate_ram_wr_en_sys,
            gate_pixel_mode_sys,
            gate_pixel_reset_sys,
            gate_sig2_enable_sys,
            gate_div_ratio_sys,
            gate_sig2_delay_coarse_sys,
            gate_sig2_delay_fine_sys,
            gate_sig2_width_coarse_sys,
            gate_sig3_delay_coarse_sys
        }),
        .probe11(nb6_cfg_sys),
        .probe12({
            12'd0,
            nb6l295_start_sys,
            nb6l295_enable_sys,
            nb6l295_delay_a_sys,
            nb6l295_delay_b_sys
        })
    );

    ila_chain_ft u_ila_chain_ft (
        .clk(ft_clk),
        .probe0(ft_rx_data),
        .probe1({
            cmd_dbg_state,
            cmd_dbg_cmd_id,
            cmd_dbg_payload_len,
            cmd_dbg_payload_idx,
            ft_rx_valid,
            ft_rx_ready,
            ft_rx_fire,
            ad5686_start_ft,
            nb6l295_start_ft,
            tec_temp_set_valid_ft,
            gpx2_start_cfg_ft,
            gate_cfg_valid_ft,
            gate_pixel_reset_ft,
            gate_ram_wr_en_ft,
            flash_save_req_ft,
            flash_load_req_ft,
            ft_rxf_n,
            ft_rd_n,
            ft_oe_n
        }),
        .probe2(ad5686_cfg_ft),
        .probe3(gate_cfg_ft),
        .probe4(gate_ram_cfg_ft),
        .probe5(pkt_tx_data),
        .probe6(tx_fifo_din),
        .probe7(tx_fifo_dout),
        .probe8({13'd0, ft601_dbg_state, dbg_ft_upload_ctrl_bus}),
        .probe9(uptime_seconds_ft),
        .probe10(counter_count_ft),
        .probe11({temp_avg_ft, status_flags_ft}),
        .probe12(usb_drop_count_ft),
        .probe13(gpx2_sys_ft_dout),
        .probe14({27'd0, pkt_tx_be, ft_tx_ready}),
        .probe15(tx_fifo_dout[31:0]),
        .probe16(tx_fifo_dout[35:32])
    );

    assign dbg_sys_count_ctrl_bus = {
        ft_hb_sync_sys[1],
        ft_rst,
        sys_rst,
        counter_ava_se,
        gpx2_stream_valid,
        gpx2_stream_ready,
        gpx2_sys_ft_full,
        gpx2_event_overflow
    };

    assign dbg_sys_count_data_bus = counter_count_sys;
    assign dbg_ft_rx_toggle_edge_sys = dbg_ft_rx_toggle_sync_sys[2] ^ dbg_ft_rx_toggle_sync_sys[1];
    assign dbg_ad5686_toggle_edge_sys = dbg_ad5686_toggle_sync_sys[2] ^ dbg_ad5686_toggle_sync_sys[1];

    // Start every clock domain in reset so internal logic stays quiescent
    // until its local clock has actually toggled a few cycles after config.
    initial begin
        rst_sync_ff       = 3'b111;
        ft_rst_sync_ff    = 3'b111;
        clk20_rst_sync_ff = 3'b111;
        ft_hb_toggle      = 1'b0;
        ft_hb_sync_sys    = 2'b00;
        ft_hb_timeout_sys = 16'd0;
        ft_clk_alive_sys  = 1'b0;
        ft_clk_lost_sys   = 1'b1;
        raw20m_hb_counter = 32'd0;
        sys_locked_sync_20m = 2'b00;
        ft_hb_sync_20m    = 2'b00;
        ft_reset_hold_cnt = 18'd0;
        ft_reset_release  = 1'b0;
        dbg_ft_rx_data_hold_ft = 32'd0;
        dbg_ft_ctrl_hold_ft = 18'd0;
        dbg_ad5686_data1_hold_ft = 16'd0;
        dbg_ad5686_data2_hold_ft = 16'd0;
        dbg_ft_rx_toggle_ft = 1'b0;
        dbg_ad5686_toggle_ft = 1'b0;
        dbg_ft_rx_toggle_sync_sys = 3'b000;
        dbg_ad5686_toggle_sync_sys = 3'b000;
        dbg_ft_rx_data_sys = 32'd0;
        dbg_ft_ctrl_sys = 18'd0;
        dbg_ad5686_data1_sys = 16'd0;
        dbg_ad5686_data2_sys = 16'd0;
        dbg_ft_rx_event_sys = 1'b0;
        dbg_ad5686_event_sys = 1'b0;
    end

    // 外部低有效复位进入板级后，先在各个时钟域同步，再作为内部高有效复位使用。
    assign sys_rst     = rst_sync_ff[2];
    assign ft_rst      = ft_rst_sync_ff[2];
    assign clk_20m_rst = clk20_rst_sync_ff[2];

    // This PCB routes FT601 reset/mode sideband pins through the FPGA. Drive the
    // intended mode first, then release FT601 reset after FPGA configuration so
    // the bridge samples stable GPIO[1:0] values.
    // GPIO1:0 = 2'b00 selects 1-channel 245 synchronous FIFO mode.
    assign ft_reset_n  = ft_reset_release;
    assign ft_wakeup_n = 1'b1;
    assign ft_gpio0    = 1'b0;
    assign ft_gpio1    = 1'b0;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rst_sync_ff <= 3'b111;
        else
            rst_sync_ff <= {rst_sync_ff[1:0], 1'b0};
    end

    always @(posedge ft_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            ft_rst_sync_ff <= 3'b111;
        else
            ft_rst_sync_ff <= {ft_rst_sync_ff[1:0], 1'b0};
    end

    // Cross a free-running FT-domain heartbeat into sys_clk so we can debug
    // whether the FT601 clock is actually reaching the FPGA without depending
    // on a debug hub that also lives in the FT clock domain.
    always @(posedge ft_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            ft_hb_toggle <= 1'b0;
        else
            ft_hb_toggle <= ~ft_hb_toggle;
    end

    always @(posedge ft_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dbg_ft_rx_data_hold_ft    <= 32'd0;
            dbg_ft_ctrl_hold_ft       <= 18'd0;
            dbg_ad5686_data1_hold_ft  <= 16'd0;
            dbg_ad5686_data2_hold_ft  <= 16'd0;
            dbg_ft_rx_toggle_ft       <= 1'b0;
            dbg_ad5686_toggle_ft      <= 1'b0;
        end else begin
            if (ft_rx_fire) begin
                dbg_ft_rx_data_hold_ft <= ft_rx_data;
                dbg_ft_ctrl_hold_ft    <= dbg_ft_cmd_ctrl_bus;
                dbg_ft_rx_toggle_ft    <= ~dbg_ft_rx_toggle_ft;
            end

            if (ad5686_start_ft) begin
                dbg_ad5686_data1_hold_ft <= ad5686_data1_ft;
                dbg_ad5686_data2_hold_ft <= ad5686_data2_ft;
                dbg_ad5686_toggle_ft     <= ~dbg_ad5686_toggle_ft;
            end
        end
    end

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ft_hb_sync_sys <= 2'b00;
            ft_hb_timeout_sys <= 16'd0;
            ft_clk_alive_sys <= 1'b0;
            ft_clk_lost_sys <= 1'b1;
            dbg_ft_rx_toggle_sync_sys <= 3'b000;
            dbg_ad5686_toggle_sync_sys <= 3'b000;
            dbg_ft_rx_data_sys <= 32'd0;
            dbg_ft_ctrl_sys <= 18'd0;
            dbg_ad5686_data1_sys <= 16'd0;
            dbg_ad5686_data2_sys <= 16'd0;
            dbg_ft_rx_event_sys <= 1'b0;
            dbg_ad5686_event_sys <= 1'b0;
        end else begin
            ft_hb_sync_sys <= {ft_hb_sync_sys[0], ft_hb_toggle};

            if (ft_hb_sync_sys[1] ^ ft_hb_sync_sys[0]) begin
                ft_hb_timeout_sys <= 16'd0;
                ft_clk_alive_sys  <= 1'b1;
                ft_clk_lost_sys   <= 1'b0;
            end else if (ft_hb_timeout_sys != 16'hFFFF) begin
                ft_hb_timeout_sys <= ft_hb_timeout_sys + 1'b1;
            end else begin
                ft_clk_alive_sys <= 1'b0;
                ft_clk_lost_sys  <= 1'b1;
            end

            dbg_ft_rx_toggle_sync_sys <= {dbg_ft_rx_toggle_sync_sys[1:0], dbg_ft_rx_toggle_ft};
            dbg_ad5686_toggle_sync_sys <= {dbg_ad5686_toggle_sync_sys[1:0], dbg_ad5686_toggle_ft};

            dbg_ft_rx_event_sys  <= dbg_ft_rx_toggle_edge_sys;
            dbg_ad5686_event_sys <= dbg_ad5686_toggle_edge_sys;

            if (dbg_ft_rx_toggle_edge_sys) begin
                dbg_ft_rx_data_sys <= dbg_ft_rx_data_hold_ft;
                dbg_ft_ctrl_sys    <= dbg_ft_ctrl_hold_ft;
            end

            if (dbg_ad5686_toggle_edge_sys) begin
                dbg_ad5686_data1_sys <= dbg_ad5686_data1_hold_ft;
                dbg_ad5686_data2_sys <= dbg_ad5686_data2_hold_ft;
            end
        end
    end

    always @(posedge sys_clk_20M_bufg or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            raw20m_hb_counter   <= 32'd0;
            sys_locked_sync_20m <= 2'b00;
            ft_hb_sync_20m      <= 2'b00;
        end else begin
            raw20m_hb_counter   <= raw20m_hb_counter + 1'b1;
            sys_locked_sync_20m <= {sys_locked_sync_20m[0], sys_clk_pll_locked};
            ft_hb_sync_20m      <= {ft_hb_sync_20m[0], ft_hb_toggle};
        end
    end

    always @(posedge sys_clk_20M_bufg or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ft_reset_hold_cnt <= 18'd0;
            ft_reset_release  <= 1'b0;
        end else if (!ft_reset_release) begin
            if (ft_reset_hold_cnt == FT_RESET_HOLD_CYCLES) begin
                ft_reset_release <= 1'b1;
            end else begin
                ft_reset_hold_cnt <= ft_reset_hold_cnt + 1'b1;
            end
        end
    end

    sys_aux_clk_gen u_sys_aux_clk_gen (
        .clk_in  (sys_clk),
        .rst     (sys_rst),
        .clk_20m (clk_20m),
        .clk_200m(clk_200m),
        .locked  (pll_locked)
    );

    always @(posedge clk_20m or negedge sys_rst_n) begin
        if (!sys_rst_n)
            clk20_rst_sync_ff <= 3'b111;
        else
            clk20_rst_sync_ff <= {clk20_rst_sync_ff[1:0], 1'b0};
    end

    gpx2_lclk_gen u_gpx2_lclk_gen (
        .clk_in  (sys_clk),
        .rst     (sys_rst),
        .clk_out (gpx2_lclk_250m),
        .locked  (gpx2_lclk_locked)
    );

    gpx2_tcspc_event_top #(
        .NUM_CH      (NUM_CH),
        .SYS_CLK_HZ  (100_000_000),
        .IDELAY_TAPS (16)
    ) u_gpx2 (
        .sys_clk       (sys_clk),
        .sys_rst       (sys_rst),
        .idelay_refclk (clk_200m),
        .start_cfg     (gpx2_start_cfg_sys),
        .cfg_done      (gpx2_cfg_done),
        .cfg_error     (gpx2_cfg_error),
        .gpx2_ssn      (gpx2_ssn),
        .gpx2_sck      (gpx2_sck),
        .gpx2_mosi     (gpx2_mosi),
        .gpx2_miso     (gpx2_miso),
        .gpx2_lclkout_p(gpx2_lclkout_p),
        .gpx2_lclkout_n(gpx2_lclkout_n),
        .gpx2_lclkin_p (gpx2_lclkin_p),
        .gpx2_lclkin_n (gpx2_lclkin_n),
        .lclk_in       (gpx2_lclk_250m),
        .gpx2_sdo_p    (gpx2_sdo_p),
        .gpx2_sdo_n    (gpx2_sdo_n),
        .gpx2_frame_p  (gpx2_frame_p),
        .gpx2_frame_n  (gpx2_frame_n),
        .out_valid     (gpx2_stream_valid),
        .out_data      (gpx2_stream_data),
        .out_ready     (gpx2_stream_ready),
        .out_last      (gpx2_stream_last),
        .event_overflow(gpx2_event_overflow),
        .photon_valid_count(gpx2_photon_valid_count),
        .laser_count   (gpx2_laser_count),
        .detector_count(gpx2_detector_count)
    );

    // GPX2 输出的是“通道号 + refid + tstop”原始事件，先在 sys_clk 域压成统一字宽，
    // 再通过异步 FIFO 送到 ft_clk 域做上传打包。
    assign gpx2_sys_ft_din   = {13'd0, gpx2_stream_last, gpx2_stream_data};
    assign gpx2_stream_ready = ~gpx2_sys_ft_full & ~gpx2_sys_ft_wr_rst_busy;
    assign gpx2_sys_ft_wr_en = gpx2_stream_valid & gpx2_stream_ready;

    async_fifo_46b u_gpx2_sys_ft_fifo (
        .wr_clk      (sys_clk),
        .rst         (sys_rst),
        .wr_en       (gpx2_sys_ft_wr_en),
        .din         (gpx2_sys_ft_din),
        .full        (gpx2_sys_ft_full),
        .almost_full (gpx2_sys_ft_almost_full),
        .wr_rst_busy (gpx2_sys_ft_wr_rst_busy),
        .rd_clk      (ft_clk),
        .rd_en       (gpx2_sys_ft_rd_en),
        .dout        (gpx2_sys_ft_dout),
        .empty       (gpx2_sys_ft_empty),
        .rd_rst_busy (gpx2_sys_ft_rd_rst_busy)
    );

    // FT601 接口模块只处理芯片时序，不负责命令协议和数据协议。
    ft601_fifo_if #(
        .DATA_WIDTH (FT_DATA_W),
        .BE_WIDTH   (4)
    ) u_ft601 (
        .ft_clk    (ft_clk),
        .sys_clk   (sys_clk),
        .rst       (ft_rst),
        .ft_data   (ft_data),
        .ft_be     (ft_be),
        .ft_txe_n  (ft_txe_n),
        .ft_rxf_n  (ft_rxf_n),
        .ft_wr_n   (ft_wr_n),
        .ft_rd_n   (ft_rd_n),
        .ft_oe_n   (ft_oe_n),
        .ft_siwu_n (ft_siwu_n),
        .tx_data   (tx_fifo_dout[31:0]),
        .tx_be     (tx_fifo_dout[35:32]),
        .tx_valid  (~tx_fifo_empty),
        .tx_ready  (ft_tx_ready),
        .rx_data   (ft_rx_data),
        .rx_be     (),
        .rx_valid  (ft_rx_valid),
        .rx_ready  (ft_rx_ready),
        .dbg_state (ft601_dbg_state)
    );

    // 命令解码器把上位机发来的 0xBB 帧解析成各模块的配置请求。
    cmd_dispatcher u_cmd_dispatcher (
        .clk                  (ft_clk),
        .rst                  (ft_rst),
        .rx_data              (ft_rx_data),
        .rx_valid             (ft_rx_valid),
        .rx_ready             (ft_rx_ready),
        .ad5686_ready         (ad5686_cmd_ready),
        .nb6l295_ready        (nb6_cmd_ready),
        .tec_temp_ready       (tec_temp_cmd_ready),
        .gpx2_cfg_ready       (gpx2_cfg_cmd_ready),
        .gate_cfg_ready       (gate_cfg_cmd_ready),
        .gate_pixel_ready     (gate_pixel_cmd_ready),
        .gate_ram_ready       (gate_ram_cmd_ready),
        .flash_ready          (flash_cmd_ready_ft),
        .ack_ready            (ack_ready_ft),
        .ad5686_start         (ad5686_start_ft),
        .ad5686_data1         (ad5686_data1_ft),
        .ad5686_data2         (ad5686_data2_ft),
        .ad5686_data3         (ad5686_data3_ft),
        .ad5686_data4         (ad5686_data4_ft),
        .gate_hold_off_time   (gate_hold_off_time_ft),
        .nb6l295_start        (nb6l295_start_ft),
        .nb6l295_delay_a      (nb6l295_delay_a_ft),
        .nb6l295_delay_b      (nb6l295_delay_b_ft),
        .nb6l295_enable       (nb6l295_enable_ft),
        .tec_temp_set         (tec_temp_set_ft),
        .tec_temp_set_valid   (tec_temp_set_valid_ft),
        .gpx2_start_cfg       (gpx2_start_cfg_ft),
        .gate_div_ratio       (gate_div_ratio_ft),
        .gate_sig2_enable     (gate_sig2_enable_ft),
        .gate_sig3_enable     (gate_sig3_enable_ft),
        .gate_sig2_delay_coarse(gate_sig2_delay_coarse_ft),
        .gate_sig2_delay_fine (gate_sig2_delay_fine_ft),
        .gate_sig2_width_coarse(gate_sig2_width_coarse_ft),
        .gate_sig2_width_fine (gate_sig2_width_fine_ft),
        .gate_sig3_delay_coarse(gate_sig3_delay_coarse_ft),
        .gate_sig3_delay_fine (gate_sig3_delay_fine_ft),
        .gate_sig3_width_coarse(gate_sig3_width_coarse_ft),
        .gate_sig3_width_fine (gate_sig3_width_fine_ft),
        .gate_pixel_mode      (gate_pixel_mode_ft),
        .gate_cfg_valid       (gate_cfg_valid_ft),
        .gate_pixel_reset     (gate_pixel_reset_ft),
        .gate_ram_wr_en       (gate_ram_wr_en_ft),
        .gate_ram_wr_addr     (gate_ram_wr_addr_ft),
        .gate_ram_wr_data     (gate_ram_wr_data_ft),
        .flash_save_req       (flash_save_req_ft),
        .flash_load_req       (flash_load_req_ft),
        .ack_valid            (ack_valid_ft),
        .ack_cmd_id           (ack_cmd_id_ft),
        .ack_status           (ack_status_ft),
        .ack_data             (ack_data_ft),
        .dbg_state            (cmd_dbg_state),
        .dbg_cmd_id           (cmd_dbg_cmd_id),
        .dbg_payload_len      (cmd_dbg_payload_len),
        .dbg_payload_idx      (cmd_dbg_payload_idx)
    );

    assign ad5686_cfg_ft = {ad5686_data1_ft, ad5686_data2_ft, ad5686_data3_ft, ad5686_data4_ft};
    assign nb6_cfg_ft    = {nb6l295_enable_ft, nb6l295_delay_b_ft, nb6l295_delay_a_ft};
    assign gate_cfg_ft   = {
        gate_pixel_mode_ft,
        gate_sig3_width_fine_ft,
        gate_sig3_width_coarse_ft,
        gate_sig3_delay_fine_ft,
        gate_sig3_delay_coarse_ft,
        gate_sig2_width_fine_ft,
        gate_sig2_width_coarse_ft,
        gate_sig2_delay_fine_ft,
        gate_sig2_delay_coarse_ft,
        gate_sig3_enable_ft,
        gate_sig2_enable_ft,
        gate_div_ratio_ft
    };
    assign gate_ram_cfg_ft = {gate_ram_wr_addr_ft, gate_ram_wr_data_ft};
    assign flash_param_bundle_ft = {gate_cfg_ft, tec_temp_set_ft, nb6_cfg_ft, ad5686_cfg_ft};
    assign {flash_gate_cfg_sys, flash_tec_temp_set_sys, flash_nb6_cfg_sys, flash_ad5686_cfg_sys} =
        flash_param_loaded_sys;
    assign {flash_gate_ram_last_gate, flash_gate_ram_wr_addr_gate, flash_gate_ram_wr_data_gate} =
        flash_gate_ram_cfg_gate;
    assign gate_ram_wr_en_core   = flash_gate_ram_valid_gate | gate_ram_wr_en_sys;
    assign gate_ram_wr_addr_core = flash_gate_ram_valid_gate ? flash_gate_ram_wr_addr_gate : gate_ram_wr_addr_sys;
    assign gate_ram_wr_data_core = flash_gate_ram_valid_gate ? flash_gate_ram_wr_data_gate : gate_ram_wr_data_sys;
    assign gate_pixel_reset_core = gate_pixel_reset_sys | flash_gate_ram_last_gate;

    // 这一组 cdc_cfg_update 统一采用 request/ack 原子跨域，
    // 适合多位配置总线，避免直接双触发同步造成配置撕裂。
    cdc_cfg_update #(.WIDTH(AD5686_CFG_W)) u_ad5686_cfg_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (ad5686_start_ft),
        .src_data  (ad5686_cfg_ft),
        .src_ready (ad5686_cmd_ready),
        .dst_clk   (clk_20m),
        .dst_rst   (clk_20m_rst),
        .dst_valid (ad5686_start_ft_20m),
        .dst_data  (ad5686_cfg_ft_20m)
    );

    cdc_cfg_update #(.WIDTH(AD5686_CFG_W)) u_flash_ad5686_cfg_sync (
        .src_clk   (sys_clk),
        .src_rst   (sys_rst),
        .src_valid (flash_load_valid_sys),
        .src_data  (flash_ad5686_cfg_sys),
        .src_ready (flash_ad5686_cfg_ready_sys),
        .dst_clk   (clk_20m),
        .dst_rst   (clk_20m_rst),
        .dst_valid (ad5686_start_flash_20m),
        .dst_data  (ad5686_cfg_flash_20m)
    );

    cdc_cfg_update #(.WIDTH(16)) u_tec_temp_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (tec_temp_set_valid_ft),
        .src_data  (tec_temp_set_ft),
        .src_ready (tec_temp_cmd_ready),
        .dst_clk   (clk_20m),
        .dst_rst   (clk_20m_rst),
        .dst_valid (tec_temp_set_ft_valid_20m),
        .dst_data  (tec_temp_set_ft_20m)
    );

    cdc_cfg_update #(.WIDTH(16)) u_flash_tec_temp_sync (
        .src_clk   (sys_clk),
        .src_rst   (sys_rst),
        .src_valid (flash_load_valid_sys),
        .src_data  (flash_tec_temp_set_sys),
        .src_ready (flash_tec_cfg_ready_sys),
        .dst_clk   (clk_20m),
        .dst_rst   (clk_20m_rst),
        .dst_valid (tec_temp_set_flash_valid_20m),
        .dst_data  (tec_temp_set_flash_20m)
    );

    cdc_cfg_update #(.WIDTH(NB6_CFG_W)) u_nb6_cfg_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (nb6l295_start_ft),
        .src_data  (nb6_cfg_ft),
        .src_ready (nb6_cmd_ready),
        .dst_clk   (sys_clk),
        .dst_rst   (sys_rst),
        .dst_valid (nb6l295_start_ft_sys),
        .dst_data  (nb6_cfg_ft_sys)
    );

    cdc_cfg_update #(.WIDTH(1)) u_gpx2_cfg_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (gpx2_start_cfg_ft),
        .src_data  (1'b1),
        .src_ready (gpx2_cfg_cmd_ready),
        .dst_clk   (sys_clk),
        .dst_rst   (sys_rst),
        .dst_valid (gpx2_start_cfg_sys),
        .dst_data  ()
    );

    cdc_cfg_update #(.WIDTH(GATE_CFG_W)) u_gate_cfg_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (gate_cfg_valid_ft),
        .src_data  (gate_cfg_ft),
        .src_ready (gate_cfg_cmd_ready_raw),
        .dst_clk   (gate_clk_div),
        .dst_rst   (gate_core_rst),
        .dst_valid (gate_cfg_ft_valid_gate),
        .dst_data  (gate_cfg_ft_gate)
    );

    cdc_cfg_update #(.WIDTH(GATE_CFG_W)) u_flash_gate_cfg_sync (
        .src_clk   (sys_clk),
        .src_rst   (sys_rst),
        .src_valid (flash_load_valid_sys),
        .src_data  (flash_gate_cfg_sys),
        .src_ready (flash_gate_cfg_ready_sys),
        .dst_clk   (gate_clk_div),
        .dst_rst   (gate_core_rst),
        .dst_valid (gate_cfg_flash_valid_gate),
        .dst_data  (gate_cfg_flash_gate)
    );

    cdc_cfg_update #(.WIDTH(1)) u_gate_pixel_reset_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (gate_pixel_reset_ft),
        .src_data  (1'b1),
        .src_ready (gate_pixel_cmd_ready_raw),
        .dst_clk   (gate_clk_div),
        .dst_rst   (gate_core_rst),
        .dst_valid (gate_pixel_reset_sys),
        .dst_data  ()
    );

    cdc_cfg_update #(.WIDTH(50)) u_gate_ram_cfg_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (gate_ram_wr_en_ft),
        .src_data  (gate_ram_cfg_ft),
        .src_ready (gate_ram_cmd_ready_raw),
        .dst_clk   (gate_clk_div),
        .dst_rst   (gate_core_rst),
        .dst_valid (gate_ram_wr_en_sys),
        .dst_data  (gate_ram_cfg_sys)
    );

    cdc_cfg_update #(.WIDTH(51)) u_flash_gate_ram_sync (
        .src_clk   (sys_clk),
        .src_rst   (sys_rst),
        .src_valid (flash_gate_ram_valid_sys),
        .src_data  ({flash_pixel_load_addr_sys == 14'h3FFF, flash_pixel_load_addr_sys, flash_pixel_load_data_sys}),
        .src_ready (flash_gate_ram_ready_sys),
        .dst_clk   (gate_clk_div),
        .dst_rst   (gate_core_rst),
        .dst_valid (flash_gate_ram_valid_gate),
        .dst_data  (flash_gate_ram_cfg_gate)
    );

    cdc_cfg_update #(.WIDTH(FLASH_PARAM_W)) u_flash_save_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (flash_save_req_ft),
        .src_data  (flash_param_bundle_ft),
        .src_ready (flash_save_cdc_ready_ft),
        .dst_clk   (sys_clk),
        .dst_rst   (sys_rst),
        .dst_valid (flash_save_req_sys),
        .dst_data  (flash_param_bundle_sys)
    );

    cdc_cfg_update #(.WIDTH(1)) u_flash_load_sync (
        .src_clk   (ft_clk),
        .src_rst   (ft_rst),
        .src_valid (flash_load_req_ft),
        .src_data  (1'b1),
        .src_ready (flash_load_cdc_ready_ft),
        .dst_clk   (sys_clk),
        .dst_rst   (sys_rst),
        .dst_valid (flash_load_req_sys),
        .dst_data  ()
    );

    // Flash 分成两个逻辑区域：
    // 1. 小参数区：保存 DAC、NB6、TEC、Gate 默认配置
    // 2. 像素镜像区：保存整幅 pixel_param_ram 参数表
    flash_board_store #(
        .PARAM_BITS      (FLASH_PARAM_W),
        .PIXEL_ADDR_BITS (14)
    ) u_flash_params (
        .clk             (sys_clk),
        .rst             (sys_rst),
        .save_req        (flash_save_req_sys),
        .load_req        (flash_load_req_sys),
        .params_in       (flash_param_bundle_sys),
        .load_valid      (flash_load_valid_sys),
        .params_out      (flash_param_loaded_sys),
        .pixel_load_valid(flash_gate_ram_valid_sys),
        .pixel_load_addr (flash_pixel_load_addr_sys),
        .pixel_load_data (flash_pixel_load_data_sys),
        .pixel_load_ready(flash_gate_ram_ready_sys),
        .pixel_rd_addr   (flash_pixel_rd_addr_sys),
        .pixel_rd_data   (pixel_shadow_rd_data_sys),
        .pixel_wr_en     (flash_pixel_wr_en_sys),
        .pixel_wr_addr   (flash_pixel_wr_addr_sys),
        .pixel_wr_data   (flash_pixel_wr_data_sys),
        .busy            (flash_busy_sys),
        .error           (flash_error_sys),
        .flash_cs_n      (flash_spi_cs_n),
        .flash_d0        (flash_spi_d0),
        .flash_d1        (flash_spi_d1)
    );

    // 影子 RAM 在 sys_clk 域再保存一份像素表，Flash 保存/恢复都基于它进行，
    // 不需要深入 gate_gen_top 内部实现。
    pixel_param_ram_36b u_pixel_shadow_ram (
        .clka   (gate_clk_div),
        .wea    (gate_ram_wr_en_sys),
        .addra  (gate_ram_wr_addr_sys),
        .dina   (gate_ram_wr_data_sys),
        .douta  (),
        .clkb   (sys_clk),
        .enb    (1'b1),
        .web    (flash_pixel_wr_en_sys),
        .addrb  (flash_pixel_wr_en_sys ? flash_pixel_wr_addr_sys : flash_pixel_rd_addr_sys),
        .dinb   (flash_pixel_wr_data_sys),
        .doutb  (pixel_shadow_rd_data_sys)
    );

    cdc_bus_sync #(.WIDTH(2)) u_flash_status_sync (
        .clk (ft_clk),
        .rst (ft_rst),
        .din ({flash_busy_sys, flash_error_sys}),
        .dout(flash_status_ft)
    );

    assign flash_busy_ft      = flash_status_ft[1];
    assign flash_error_ft     = flash_status_ft[0];
    assign gate_cfg_cmd_ready = gate_cfg_cmd_ready_raw & ~flash_busy_ft;
    assign gate_pixel_cmd_ready = gate_pixel_cmd_ready_raw & ~flash_busy_ft;
    assign gate_ram_cmd_ready = gate_ram_cmd_ready_raw & ~flash_busy_ft;
    assign flash_cmd_ready_ft = ~flash_busy_ft & flash_save_cdc_ready_ft & flash_load_cdc_ready_ft;

    // 20 MHz 域统一仲裁两类配置来源：
    // - 上位机实时下发
    // - Flash 上电恢复默认值
    always @(posedge clk_20m) begin
        if (clk_20m_rst) begin
            ad5686_cfg_20m <= {AD5686_CFG_W{1'b0}};
            ad5686_start_20m <= 1'b0;
            tec_temp_set_20m <= 16'd0;
        end else begin
            ad5686_start_20m <= 1'b0;

            if (ad5686_start_ft_20m) begin
                ad5686_cfg_20m   <= ad5686_cfg_ft_20m;
                ad5686_start_20m <= 1'b1;
            end else if (ad5686_start_flash_20m) begin
                ad5686_cfg_20m   <= ad5686_cfg_flash_20m;
                ad5686_start_20m <= 1'b1;
            end

            if (tec_temp_set_ft_valid_20m)
                tec_temp_set_20m <= tec_temp_set_ft_20m;
            else if (tec_temp_set_flash_valid_20m)
                tec_temp_set_20m <= tec_temp_set_flash_20m;
        end
    end

    // NB6L295 工作在 sys_clk 域，因此由这里统一接受在线命令和 Flash 恢复。
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            nb6_cfg_sys      <= {NB6_CFG_W{1'b0}};
            nb6l295_start_sys <= 1'b0;
        end else begin
            nb6l295_start_sys <= 1'b0;

            if (nb6l295_start_ft_sys) begin
                nb6_cfg_sys       <= nb6_cfg_ft_sys;
                nb6l295_start_sys <= 1'b1;
            end else if (flash_load_valid_sys) begin
                nb6_cfg_sys       <= flash_nb6_cfg_sys;
                nb6l295_start_sys <= 1'b1;
            end
        end
    end

    // Gate 配置最终只在 gate 时钟域生效，保证下游逻辑看到的是同拍稳定参数。
    // gate_core_rst 在本地域同步释放，既满足功能要求，也方便时序/CDC 工具识别。
    always @(posedge gate_clk_div) begin
        if (gate_core_rst) begin
            gate_cfg_sys <= GATE_CFG_DEFAULT;
        end else begin
            if (gate_cfg_ft_valid_gate)
                gate_cfg_sys <= gate_cfg_ft_gate;
            else if (gate_cfg_flash_valid_gate)
                gate_cfg_sys <= gate_cfg_flash_gate;
        end
    end

    assign {ad5686_data1_20m, ad5686_data2_20m, ad5686_data3_20m, ad5686_data4_20m} = ad5686_cfg_20m;
    assign {nb6l295_enable_sys, nb6l295_delay_b_sys, nb6l295_delay_a_sys} = nb6_cfg_sys;
    assign {
        gate_pixel_mode_sys,
        gate_sig3_width_fine_sys,
        gate_sig3_width_coarse_sys,
        gate_sig3_delay_fine_sys,
        gate_sig3_delay_coarse_sys,
        gate_sig2_width_fine_sys,
        gate_sig2_width_coarse_sys,
        gate_sig2_delay_fine_sys,
        gate_sig2_delay_coarse_sys,
        gate_sig3_enable_sys,
        gate_sig2_enable_sys,
        gate_div_ratio_sys
    } = gate_cfg_sys;
    assign {gate_ram_wr_addr_sys, gate_ram_wr_data_sys} = gate_ram_cfg_sys;

    AD5686 u_ad5686 (
        .clk      (clk_20m),
        .start    (ad5686_start_20m),
        .data1_in (ad5686_data1_20m),
        .data2_in (ad5686_data2_20m),
        .data3_in (ad5686_data3_20m),
        .data4_in (ad5686_data4_20m),
        .dac_clk  (ad5686_clk),
        .dac_din  (ad5686_din),
        .dac_cs   (ad5686_cs)
    );

    IBUFDS #(
        .DIFF_TERM   ("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD  ("LVDS")
    ) u_counter_ibuf (
        .I  (counter_ava_p),
        .IB (counter_ava_n),
        .O  (counter_ava_se)
    );

    Counter #(
        .CLK_FREQ_HZ(100_000_000)
    ) u_counter (
        .clk  (sys_clk),
        .rst  (sys_rst),
        .ava  (counter_ava_se),
        .count(counter_count_sys)
    );

    NB6L295_extend u_nb6l295 (
        .clk     (sys_clk),
        .start   (nb6l295_start_sys),
        .delay_a (nb6l295_delay_a_sys),
        .delay_b (nb6l295_delay_b_sys),
        .enable  (nb6l295_enable_sys),
        .enable_input(1'b0),
        .en      (nb6l295_en),
        .SDIN    (nb6l295_sdin),
        .SCLK    (nb6l295_sclk),
        .SLOAD   (nb6l295_sload)
    );

    ADC_Ctrl u_temp_adc (
        .clkin  (clk_20m),
        .Start  (adc_start),
        .SDI    (temp_adc_sdo),
        .SCLK   (temp_adc_sclk),
        .CS     (temp_adc_cs),
        .CONVST (temp_adc_cv),
        .SB     (),
        .FS     (),
        .ADC    (temp_adc_data)
    );

    Temp_control u_temp_ctrl (
        .clk         (clk_20m),
        .rst         (clk_20m_rst),
        .temp_current(temp_adc_data),
        .PID_start   (pid_start),
        .ADC_start   (adc_start),
        .temp        (temp_avg_20m)
    );

    TEC_PID u_tec_pid (
        .clk      (clk_20m),
        .start    (pid_start),
        .Temp     (temp_avg_20m),
        .Temp_set (tec_temp_set_20m),
        .daout    (tec_dac_out),
        .start_DAC(tec_dac_start)
    );

    DAC8881 u_dac8881 (
        .clk         (clk_20m),
        .start       (tec_dac_start),
        .datain      (tec_dac_out),
        .dac8881_clk (dac8881_clk),
        .dac8881_din (dac8881_din),
        .dac8881_cs  (dac8881_cs)
    );

    cdc_bus_sync #(.WIDTH(32)) u_counter_ft_sync (
        .clk (ft_clk),
        .rst (ft_rst),
        .din (counter_count_sys),
        .dout(counter_count_ft)
    );

    cdc_bus_sync #(.WIDTH(16)) u_temp_ft_sync (
        .clk (ft_clk),
        .rst (ft_rst),
        .din (temp_avg_20m),
        .dout(temp_avg_ft)
    );

    cdc_bus_sync #(.WIDTH(5)) u_status_bits_sync (
        .clk (ft_clk),
        .rst (ft_rst),
        .din ({gpx2_lclk_locked, gate_clk_locked, gpx2_event_overflow, gpx2_cfg_error, gpx2_cfg_done}),
        .dout(status_sys_bits_ft)
    );

    IBUFGDS #(
        .DIFF_TERM   ("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD  ("LVDS")
    ) u_gate_ref_ibuf (
        .I  (gate_ref_in_p),
        .IB (gate_ref_in_n),
        .O  (gate_ref_clk)
    );

    IBUFDS #(
        .DIFF_TERM   ("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD  ("LVDS")
    ) u_gate_pixel1_ibuf (
        .I  (gate_pixel_in_p),
        .IB (gate_pixel_in_n),
        .O  (gate_pixel1_se)
    );

    IBUFDS #(
        .DIFF_TERM   ("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD  ("LVDS")
    ) u_gate_pixel2_ibuf (
        .I  (gate_pixel2_in_p),
        .IB (gate_pixel2_in_n),
        .O  (gate_pixel2_se)
    );

    gate_serdes_clkgen u_gate_clkgen (
        .ref_clk_in(gate_ref_clk),
        .rst       (sys_rst),
        .clk_div   (gate_clk_div),
        .clk_ser   (gate_clk_ser),
        .locked    (gate_clk_locked)
    );

    assign gate_core_rst_async = sys_rst | ~gate_clk_locked;

    always @(posedge gate_clk_div) begin
        // Keep the gate-domain reset local to gate_clk_div so methodology sees
        // an ordinary synchronizer chain instead of LUT-driven async preset
        // logic. Assertion is still fast (one local cycle) and release remains
        // three-stage synchronized after the MMCM reports LOCKED.
        if (gate_core_rst_async)
            gate_rst_sync_ff <= 3'b111;
        else
            gate_rst_sync_ff <= {gate_rst_sync_ff[1:0], 1'b0};
    end

    assign gate_core_rst = gate_rst_sync_ff[2];

    gate_gen_top #(
        .PIXEL_ADDR_BITS(14),
        .PIXEL_X_BITS   (7),
        .DIV_BITS       (12)
    ) u_gate_gen (
        .sys_clk           (gate_clk_div),
        .sys_rst           (gate_core_rst),
        .clk_div           (gate_clk_div),
        .pixel1_in         (gate_pixel1_se),
        .pixel2_in         (gate_pixel2_se),
        .gate_word         (gate_word),
        .div_ratio         (gate_div_ratio_sys),
        .sig2_enable       (gate_sig2_enable_sys),
        .sig3_enable       (gate_sig3_enable_sys),
        .sig2_delay_coarse (gate_sig2_delay_coarse_sys),
        .sig2_delay_fine   (gate_sig2_delay_fine_sys),
        .sig2_width_coarse (gate_sig2_width_coarse_sys),
        .sig2_width_fine   (gate_sig2_width_fine_sys),
        .sig3_delay_coarse (gate_sig3_delay_coarse_sys),
        .sig3_delay_fine   (gate_sig3_delay_fine_sys),
        .sig3_width_coarse (gate_sig3_width_coarse_sys),
        .sig3_width_fine   (gate_sig3_width_fine_sys),
        .pixel_mode        (gate_pixel_mode_sys),
        .pixel_reset       (gate_pixel_reset_core),
        .ram_wr_en         (gate_ram_wr_en_core),
        .ram_wr_addr       (gate_ram_wr_addr_core),
        .ram_wr_data       (gate_ram_wr_data_core),
        .current_pixel     (gate_current_pixel)
    );

    gate_phy_lvds u_gate_phy_hp (
        .clk_ser    (gate_clk_ser),
        .clk_div    (gate_clk_div),
        .rst        (gate_core_rst),
        .par_word   (gate_word),
        .gate_out_p (gate_out_hp_p),
        .gate_out_n (gate_out_hp_n)
    );

    gate_phy_lvds u_gate_phy_ext (
        .clk_ser    (gate_clk_ser),
        .clk_div    (gate_clk_div),
        .rst        (gate_core_rst),
        .par_word   (gate_word),
        .gate_out_p (gate_out_ext_p),
        .gate_out_n (gate_out_ext_n)
    );

    assign gate_out     = gate_word[0];
    assign latch_enable = 1'b1;

    // 慢速状态信息默认每秒打一包，供上位机监控温度、计数和链路状态。
    always @(posedge ft_clk) begin
        if (ft_rst) begin
            slow_timer_ft     <= 27'd0;
            slow_tick_ft      <= 1'b0;
            uptime_seconds_ft <= 32'd0;
            status_valid_ft   <= 1'b0;
            status_flags_ft   <= 16'd0;
            usb_drop_count_ft <= 32'd0;
        end else begin
            slow_tick_ft    <= 1'b0;
            status_valid_ft <= 1'b0;

            if (pkt_tx_valid && !pkt_tx_ready)
                usb_drop_count_ft <= usb_drop_count_ft + 1'b1;

            if (slow_timer_ft == FT_STATUS_TICK_CYCLES) begin
                slow_timer_ft     <= 27'd0;
                slow_tick_ft      <= 1'b1;
                uptime_seconds_ft <= uptime_seconds_ft + 1'b1;
                status_flags_ft   <= {
                    8'd0,
                    flash_busy_ft,
                    status_sys_bits_ft[4],
                    gate_clk_locked,
                    flash_error_ft,
                    (tx_fifo_full | (ft_txe_n & ~tx_fifo_empty)),
                    status_sys_bits_ft[2],
                    status_sys_bits_ft[1],
                    status_sys_bits_ft[0]
                };
                status_valid_ft <= 1'b1;
            end else begin
                slow_timer_ft <= slow_timer_ft + 1'b1;
            end
        end
    end

    // 只有当 packet_builder 明确给出 ready 时，才从事件 FIFO 继续读，形成完整回压链。
    assign gpx2_sys_ft_rd_en = (~gpx2_sys_ft_empty) && (~gpx2_sys_ft_rd_rst_busy) && packet_event_ready_wire;

    // 上传协议目前以“原始时间戳上传”为主，上位机再完成分像素和直方图处理。
    uplink_packet_builder #(
        .DATA_WIDTH         (FT_DATA_W),
        .PHOTON_EVENTS_PER_PKT(16),
        .COLLECT_TIMEOUT_CYC(1024)
    ) u_packet_builder (
        .clk            (ft_clk),
        .rst            (ft_rst),
        .photon_valid   (~gpx2_sys_ft_empty),
        .photon_ready   (packet_event_ready_wire),
        .photon_data    (gpx2_sys_ft_dout[31:0]),
        .photon_last    (gpx2_sys_ft_dout[32]),
        .status_valid   (status_valid_ft),
        .status_flags   (status_flags_ft),
        .uptime_seconds (uptime_seconds_ft),
        .temp_avg       (temp_avg_ft),
        .counter_1s     (counter_count_ft),
        .tdc_drop_count (32'd0),
        .usb_drop_count (usb_drop_count_ft),
        .ack_valid      (ack_valid_ft),
        .ack_ready      (ack_ready_ft),
        .ack_cmd_id     (ack_cmd_id_ft),
        .ack_status     (ack_status_ft),
        .ack_data       (ack_data_ft),
        .tx_data        (pkt_tx_data),
        .tx_be          (pkt_tx_be),
        .tx_valid       (pkt_tx_valid),
        .tx_ready       (pkt_tx_ready)
    );

    assign tx_fifo_din   = {pkt_tx_be, pkt_tx_data};
    assign pkt_tx_ready  = ~tx_fifo_full;
    assign tx_fifo_wr_en = pkt_tx_valid & pkt_tx_ready;
    assign tx_fifo_rd_en = (~tx_fifo_empty) & ft_tx_ready;

    tx_fifo_36b u_tx_fifo (
        .clk   (ft_clk),
        .rst   (ft_rst),
        .din   (tx_fifo_din),
        .wr_en (tx_fifo_wr_en),
        .rd_en (tx_fifo_rd_en),
        .dout  (tx_fifo_dout),
        .full  (tx_fifo_full),
        .empty (tx_fifo_empty)
    );

endmodule

module cdc_bus_sync #(
    parameter integer WIDTH = 1
)(
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] din,
    output reg  [WIDTH-1:0] dout
);
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_ff1;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_ff2;

    always @(posedge clk) begin
        // Two plain synchronizer stages keep status snapshots simple and let
        // Vivado recognize the chain as CDC-safe.
        sync_ff1 <= din;
        sync_ff2 <= sync_ff1;

        if (rst) begin
            dout     <= {WIDTH{1'b0}};
        end else begin
            dout     <= sync_ff2;
        end
    end
endmodule

module cdc_pulse_sync (
    input  wire src_clk,
    input  wire src_rst,
    input  wire src_pulse,
    input  wire dst_clk,
    input  wire dst_rst,
    output reg  dst_pulse
);
    reg src_toggle;
    (* ASYNC_REG = "TRUE" *) reg dst_sync1;
    (* ASYNC_REG = "TRUE" *) reg dst_sync2;
    reg dst_sync3;

    always @(posedge src_clk) begin
        if (src_rst)
            src_toggle <= 1'b0;
        else if (src_pulse)
            src_toggle <= ~src_toggle;
    end

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_sync1 <= 1'b0;
            dst_sync2 <= 1'b0;
            dst_sync3 <= 1'b0;
            dst_pulse <= 1'b0;
        end else begin
            dst_sync1 <= src_toggle;
            dst_sync2 <= dst_sync1;
            dst_sync3 <= dst_sync2;
            dst_pulse <= dst_sync2 ^ dst_sync3;
        end
    end
endmodule

module gpx2_lclk_gen (
    input  wire clk_in,
    input  wire rst,
    output wire clk_out,
    output wire locked
);
`ifndef SYNTHESIS
    assign clk_out = clk_in;
    assign locked  = ~rst;
`else
    wire clkfb_mmcm;
    wire clkfb_bufg;
    wire clk_out_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH       ("OPTIMIZED"),
        .CLKFBOUT_MULT_F (10.0),
        .CLKFBOUT_PHASE  (0.0),
        .CLKIN1_PERIOD   (10.0),
        .CLKOUT0_DIVIDE_F(4.0),
        .DIVCLK_DIVIDE   (1),
        .REF_JITTER1     (0.010),
        .STARTUP_WAIT    ("FALSE")
    ) u_mmcm (
        .CLKFBOUT (clkfb_mmcm),
        .CLKOUT0  (clk_out_mmcm),
        .CLKFBIN  (clkfb_bufg),
        .CLKIN1   (clk_in),
        .PWRDWN   (1'b0),
        .RST      (rst),
        .LOCKED   (locked),
        .CLKFBOUTB(),
        .CLKOUT0B (),
        .CLKOUT1  (),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  ()
    );

    BUFG u_clkfb_bufg (
        .I (clkfb_mmcm),
        .O (clkfb_bufg)
    );

    BUFG u_clkout_bufg (
        .I (clk_out_mmcm),
        .O (clk_out)
    );
`endif
endmodule

module sys_aux_clk_gen (
    input  wire clk_in,
    input  wire rst,
    output wire clk_20m,
    output wire clk_200m,
    output wire locked
);

    wire clkfb_mmcm;
    wire clkfb_bufg;
    wire clk20_mmcm;
    wire clk200_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH      ("OPTIMIZED"),
        .CLKFBOUT_MULT_F(10.0),
        .CLKFBOUT_PHASE (0.0),
        .CLKIN1_PERIOD  (10.0),
        .CLKOUT0_DIVIDE_F(50.0),
        .CLKOUT1_DIVIDE (5),
        .DIVCLK_DIVIDE  (1),
        .REF_JITTER1    (0.010),
        .STARTUP_WAIT   ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clkfb_bufg),
        .RST      (rst),
        .PWRDWN   (1'b0),
        .CLKFBOUT (clkfb_mmcm),
        .CLKOUT0  (clk20_mmcm),
        .CLKOUT1  (clk200_mmcm),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked)
    );

    BUFG u_clkfb_bufg (
        .I(clkfb_mmcm),
        .O(clkfb_bufg)
    );

    BUFG u_clk20_bufg (
        .I(clk20_mmcm),
        .O(clk_20m)
    );

    BUFG u_clk200_bufg (
        .I(clk200_mmcm),
        .O(clk_200m)
    );
endmodule
