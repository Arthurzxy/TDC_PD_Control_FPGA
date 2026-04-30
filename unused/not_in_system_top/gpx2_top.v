//==============================================================================
// gpx2_top.v
//------------------------------------------------------------------------------
// Module: GPX2 TDC Top-Level Interface
// 模块说明：GPX2 芯片控制与 4 路 LVDS 数据接收顶层
//
// Purpose:
// 中文说明：
//   负责 GPX2 的 SPI 配置、LCLK/SDO/FRAME 接收、每通道小缓存、轮询仲裁，
//   并把原始事件安全送到 sys_clk 域。
//   Top-level module for interfacing with the GPX2 Time-to-Digital Converter (TDC)
//   chip. Handles SPI configuration, LVDS data capture, multi-channel arbitration,
//   and cross-clock domain transfer to the system clock domain.
//
// Architecture Overview:
//   1. SPI Configuration Engine (gpx2_spi_cfg)
//      - Configures GPX2 registers via SPI at startup
//      - Triggered by start_cfg, signals done/error when complete
//
//   2. Clock Generation
//      - IBUFDS: Converts differential LCLKOUT to single-ended
//      - BUFIO: Fast I/O clock for IDDR primitives
//      - BUFR: Logic clock for receiver state machines
//      - OBUFDS: Drives LCLKIN back to GPX2 (reference clock)
//
//   3. LVDS Data Receivers (4 channels, gpx2_lvds_rx)
//      - Each channel has dedicated SDO and FRAME differential inputs
//      - IBUFDS converts differential to single-ended
//      - IDDR samples DDR data (2 bits per cycle)
//      - Frame detection and bit assembly produce 44-bit events
//
//   4. Pending Memory (per-channel buffering)
//      - Each channel has PEND_DEPTH=4 event buffer
//      - Handles burst events without loss
//      - Overflow flag when buffer full
//
//   5. Round-Robin Arbitration
//      - Fair readout across all 4 channels
//      - Prevents single-channel starvation
//
//   6. Async FIFO (cross-clock domain)
//      - Transfers events from lclk_logic to sys_clk domain
//      - 46-bit width: {ch[1:0], event[43:0]}
//      - Provides ready/backpressure via event_valid/event_ready
//
// Data Format:
// 中文说明：
//   当前输出的是原始事件而非直方图，便于先保证高速链路稳定，
//   上位机再根据通道语义做后处理。
//   - event_ch[1:0]:     Channel number (0-3)
//   - event_refid[23:0]: Reference ID (from GPX2)
//   - event_tstop[19:0]: Time-of-stop measurement (from GPX2)
//   - event_overflow:    Sticky overflow flag
//
// Clock Domains:
// 中文说明：
//   - lclk_logic：真正的数据接收域
//   - sys_clk：配置、上传和状态域
//   - sys_clk:    System clock domain (configuration, FIFO read)
//   - lclk_logic: GPX2 data clock domain (LVDS capture, arbitration)
//
// Related Documents:
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.2
//   - GPX2 Datasheet
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module gpx2_top #(
    parameter integer NUM_CH      = 4,      // Number of GPX2 channels (fixed at 4)
    parameter integer REFID_BITS  = 24,    // Reference ID width (GPX2 config)
    parameter integer TSTOP_BITS  = 20,    // Time-of-stop width (GPX2 config)
    parameter integer USE_DDR     = 1,     // 1=DDR mode, 0=SDR mode
    parameter integer EVENT_BITS  = REFID_BITS + TSTOP_BITS,  // Total event bits (44)
    parameter integer PEND_DEPTH  = 4,     // Pending buffer depth per channel
    parameter integer IDELAY_TAPS = 16     // Fixed IDELAY taps for SDO/FRAME inputs
)(
    input  wire                    sys_clk,
    input  wire                    sys_rst,
    input  wire                    idelay_refclk,
    input  wire                    start_cfg,
    output wire                    cfg_done,
    output wire                    cfg_error,

    output wire                    gpx2_ssn,
    output wire                    gpx2_sck,
    output wire                    gpx2_mosi,
    input  wire                    gpx2_miso,

    input  wire                    gpx2_lclkout_p,
    input  wire                    gpx2_lclkout_n,
    output wire                    gpx2_lclkin_p,
    output wire                    gpx2_lclkin_n,
    input  wire                    lclk_in,

    input  wire [NUM_CH-1:0]       gpx2_sdo_p,
    input  wire [NUM_CH-1:0]       gpx2_sdo_n,
    input  wire [NUM_CH-1:0]       gpx2_frame_p,
    input  wire [NUM_CH-1:0]       gpx2_frame_n,

    output reg                     event_valid,
    input  wire                    event_ready,
    output reg  [1:0]              event_ch,
    output reg  [REFID_BITS-1:0]   event_refid,
    output reg  [TSTOP_BITS-1:0]   event_tstop,
    output reg                     event_overflow
);

    wire cfg_busy;                 // SPI configuration in progress
    wire lclk_in_se;               // Single-ended GPX2 clock (from IBUFDS)
    wire lclk_io;                  // Fast I/O clock (from BUFIO) for IDDR
    wire lclk_logic;               // Logic clock (from BUFR) for state machines
    wire rst_lclk;                 // Reset synchronized to lclk_logic domain
    wire rst_lclk_req;             // Combined reset request before sync release
    wire idelayctrl_rdy;           // IDELAYCTRL calibrated and ready
    wire af_full;                  // Async FIFO full flag
    wire af_empty;                 // Async FIFO empty flag
    wire af_almost_full;           // Async FIFO almost full watermark
    wire af_wr_rst_busy;           // Async FIFO write reset in progress
    wire af_rd_rst_busy;           // Async FIFO read reset in progress
    wire af_rd_valid;              // Async FIFO read data valid

    reg  af_rd_en;                 // Async FIFO read enable (sys_clk domain)

    // 每通道带一个小深度缓存，用来吸收短时间突发，避免同拍多事件直接丢失。
    reg  [EVENT_BITS-1:0]   pend_mem [0:NUM_CH*PEND_DEPTH-1];  // Event storage
    reg  [2:0]              pend_count [0:NUM_CH-1];   // Events queued per channel
    reg  [1:0]              pend_wr_ptr [0:NUM_CH-1];   // Write pointer (2 bits for depth 4)
    reg  [1:0]              pend_rd_ptr [0:NUM_CH-1];   // Read pointer (2 bits for depth 4)

    // 轮询仲裁保证 4 路通道公平出队，避免高频通道长期饿死低频通道。
    reg  [1:0]              rr_ptr_lclk;                // RR pointer: next channel to check
    reg                     af_wr_en_lclk;              // FIFO write enable
    reg  [EVENT_BITS+2-1:0] af_wr_data_lclk;            // FIFO data: {ch[1:0], event[43:0]}
    reg  [1:0]              wr_sel_idx;                 // Channel selected for FIFO write
    reg                     wr_sel_valid;               // Selected channel has data
    reg  [NUM_CH-1:0]       wr_sel_oh;                  // One-hot form of wr_sel_idx

    // sys_rst 和 IDELAY ready 都要先进入 lclk 侧同步，才能安全释放接收逻辑复位。
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_lclk_ff;
    (* ASYNC_REG = "TRUE" *) reg [1:0] idelay_rdy_lclk_ff;

    //--------------------------------------------------------------------------
    // Overflow Flag Synchronization (lclk_logic -> sys_clk domain)
    //--------------------------------------------------------------------------
    reg                     overflow_lclk;              // Set on buffer overflow
    (* ASYNC_REG = "TRUE" *) reg overflow_sys_sync1;   // Sync stage 1
    (* ASYNC_REG = "TRUE" *) reg overflow_sys_sync2;   // Sync stage 2

    //--------------------------------------------------------------------------
    // Channel Event Interface (from gpx2_lvds_rx instances)
    //--------------------------------------------------------------------------
    wire [NUM_CH-1:0]             ch_event_valid_lclk;  // Event valid per channel
    wire [NUM_CH*EVENT_BITS-1:0]  ch_event_data_lclk;   // Packed event data
    wire [EVENT_BITS+2-1:0]       af_rd_data;           // FIFO read: {ch, event}
    wire                          drain_fire;           // Selected channel can drain this cycle
    wire [NUM_CH-1:0]             drain_hit;            // One-hot channel drain strobes

    integer i, mem_idx;           // Loop variables

    //--------------------------------------------------------------------------
    // Derived Signals
    //--------------------------------------------------------------------------
    // FIFO read is valid when not empty and not in reset
    assign af_rd_valid = ~af_empty & ~af_rd_rst_busy;
    // lclk domain reset is bit 2 of the sync chain (3-stage for metastability)
    assign rst_lclk = rst_lclk_ff[2];
    // 只有“系统复位结束 + IDELAYCTRL 就绪”两个条件都满足后，GPX2 接收链才允许启动。
    assign rst_lclk_req = sys_rst | ~idelay_rdy_lclk_ff[1];
    // drain_fire 表示“这一拍真的把选中的通道写进了异步 FIFO”，
    // 后面的计数和读指针都以它为准，避免空判。
    assign drain_fire = wr_sel_valid && !af_full && !af_wr_rst_busy;
    assign drain_hit  = wr_sel_oh & {NUM_CH{drain_fire}};

    //--------------------------------------------------------------------------
    // SPI Configuration Instance
    // Configures GPX2 registers on start_cfg trigger
    //--------------------------------------------------------------------------
    gpx2_spi_cfg u_cfg (
        .clk   (sys_clk),
        .rst   (sys_rst),
        .start (start_cfg),
        .done  (cfg_done),
        .busy  (cfg_busy),
        .error (cfg_error),
        .ssn   (gpx2_ssn),
        .sck   (gpx2_sck),
        .mosi  (gpx2_mosi),
        .miso  (gpx2_miso)
    );

    //--------------------------------------------------------------------------
    // IDELAY 的目的不是改协议，而是给板级时序留一个可控的固定延时旋钮，
    // 用来补偿 GPX2 转发时钟与数据线之间的到达偏差。
    //--------------------------------------------------------------------------
    (* IODELAY_GROUP = "GPX2_IODELAY" *)
    IDELAYCTRL u_idelayctrl (
        .RDY    (idelayctrl_rdy),
        .REFCLK (idelay_refclk),
        .RST    (sys_rst)
    );

    //==========================================================================
    // Clock Buffer Instances
    //==========================================================================
    // GPX2 outputs its clock on LCLKOUT differential pair. We buffer it:
    //   1. IBUFDS: Convert differential to single-ended
    //   2. BUFIO:  Fast I/O clock for IDDR primitives (no division)
    //   3. BUFR:   Logic clock for state machines (can divide if needed)
    // We also drive LCLKIN back to GPX2 (optional, depends on clock scheme).
    //==========================================================================

    //--------------------------------------------------------------------------
    // Differential Clock Input Buffer
    // DIFF_TERM enables internal 100-ohm termination for signal integrity
    //--------------------------------------------------------------------------
    IBUFDS #(
        .DIFF_TERM("TRUE"),         // Enable internal differential termination
        .IBUF_LOW_PWR("FALSE")      // High-performance mode for LVDS
    ) u_ibufds_lclk (
        .I  (gpx2_lclkout_p),       // Differential + input
        .IB (gpx2_lclkout_n),       // Differential - input
        .O  (lclk_in_se)             // Single-ended output
    );

    //--------------------------------------------------------------------------
    // BUFIO: Fast I/O Clock Buffer
    // Drives IDDR clock inputs directly, minimal delay for capturing DDR data
    //--------------------------------------------------------------------------
    BUFIO u_bufio_lclk (
        .I (lclk_in_se),
        .O (lclk_io)                 // Fast clock for IDDR primitives
    );

    //--------------------------------------------------------------------------
    // BUFR: Logic Clock Buffer (optional division)
    // Used for receiver state machines. Division factor = 1 (no division).
    //--------------------------------------------------------------------------
    BUFR #(
        .BUFR_DIVIDE("1"),          // No clock division
        .SIM_DEVICE ("7SERIES")     // Target device family
    ) u_bufr_lclk (
        .I   (lclk_in_se),           // Input clock
        .CE  (1'b1),                 // Clock enable always on
        .CLR (1'b0),                 // No clear
        .O   (lclk_logic)             // Output clock for logic
    );

    //--------------------------------------------------------------------------
    // Differential Clock Output Buffer
    // Drives LCLKIN to GPX2 (reference clock input)
    //--------------------------------------------------------------------------
    OBUFDS #(
        .IOSTANDARD("LVDS_25")      // LVDS 2.5V I/O standard
    ) u_obufds_lclkin (
        .I  (lclk_in),               // Clock from FPGA fabric
        .O  (gpx2_lclkin_p),         // Differential + output
        .OB (gpx2_lclkin_n)          // Differential - output
    );

    //==========================================================================
    // Reset Synchronization to lclk_logic Domain
    //==========================================================================
    // sys_rst is asynchronous. We sync it to lclk_logic using a 3-stage
    // shift register to ensure metastability-free release.
    //==========================================================================
    always @(posedge lclk_logic) begin
            // 这里保持同步链自由运行，Vivado 会更容易把它识别成标准 CDC 结构。
            idelay_rdy_lclk_ff <= {idelay_rdy_lclk_ff[0], idelayctrl_rdy};
            rst_lclk_ff        <= {rst_lclk_ff[1:0], rst_lclk_req};
        end

    //==========================================================================
    // LVDS Receiver Instances (4 Channels)
    //==========================================================================
    // Each channel has:
    //   - IBUFDS for SDO (serial data output from GPX2)
    //   - IBUFDS for FRAME (packet marker from GPX2)
    //   - gpx2_lvds_rx instance for DDR sampling and event assembly
    //==========================================================================

    //==========================================================================
    // LVDS Receiver Instances (4 Channels)
    //==========================================================================
    // Each channel has:
    //   - IBUFDS for SDO (serial data output from GPX2)
    //   - IBUFDS for FRAME (packet marker from GPX2)
    //   - gpx2_lvds_rx instance for DDR sampling and event assembly
    //==========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < NUM_CH; gi = gi + 1) begin : G_RX
            wire sdo_se_raw;       // Single-ended SDO from IBUFDS
            wire frame_se_raw;     // Single-ended FRAME from IBUFDS
            wire sdo_se;           // Delayed SDO into IDDR
            wire frame_se;         // Delayed FRAME into IDDR

            //------------------------------------------------------------------
            // SDO Differential Input Buffer
            // Converts LVDS differential pair to single-ended signal
            //------------------------------------------------------------------
            IBUFDS #(
                .DIFF_TERM("TRUE"),       // Internal 100-ohm termination
                .IBUF_LOW_PWR("FALSE")    // High-performance mode
            ) u_ibufds_sdo (
                .I  (gpx2_sdo_p[gi]),
                .IB (gpx2_sdo_n[gi]),
                .O  (sdo_se_raw)
            );

            //------------------------------------------------------------------
            // FRAME Differential Input Buffer
            // Same configuration as SDO buffer
            //------------------------------------------------------------------
            IBUFDS #(
                .DIFF_TERM("TRUE"),
                .IBUF_LOW_PWR("FALSE")
            ) u_ibufds_frame (
                .I  (gpx2_frame_p[gi]),
                .IB (gpx2_frame_n[gi]),
                .O  (frame_se_raw)
            );

            // Fixed IDELAY shifts the incoming data deeper into the eye opened by
            // the forwarded LCLKOUT. All channels use the same tap count so the
            // host-side board bring-up only has one timing knob to validate.
            (* IODELAY_GROUP = "GPX2_IODELAY" *)
            IDELAYE2 #(
                .CINVCTRL_SEL          ("FALSE"),
                .DELAY_SRC             ("IDATAIN"),
                .HIGH_PERFORMANCE_MODE ("TRUE"),
                .IDELAY_TYPE           ("FIXED"),
                .IDELAY_VALUE          (IDELAY_TAPS),
                .PIPE_SEL              ("FALSE"),
                .REFCLK_FREQUENCY      (200.0),
                .SIGNAL_PATTERN        ("DATA")
            ) u_idelay_sdo (
                .C           (1'b0),
                .CE          (1'b0),
                .CINVCTRL    (1'b0),
                .CNTVALUEIN  (5'b0),
                .DATAIN      (1'b0),
                .IDATAIN     (sdo_se_raw),
                .INC         (1'b0),
                .LD          (1'b0),
                .LDPIPEEN    (1'b0),
                .REGRST      (1'b0),
                .DATAOUT     (sdo_se),
                .CNTVALUEOUT ()
            );

            (* IODELAY_GROUP = "GPX2_IODELAY" *)
            IDELAYE2 #(
                .CINVCTRL_SEL          ("FALSE"),
                .DELAY_SRC             ("IDATAIN"),
                .HIGH_PERFORMANCE_MODE ("TRUE"),
                .IDELAY_TYPE           ("FIXED"),
                .IDELAY_VALUE          (IDELAY_TAPS),
                .PIPE_SEL              ("FALSE"),
                .REFCLK_FREQUENCY      (200.0),
                .SIGNAL_PATTERN        ("DATA")
            ) u_idelay_frame (
                .C           (1'b0),
                .CE          (1'b0),
                .CINVCTRL    (1'b0),
                .CNTVALUEIN  (5'b0),
                .DATAIN      (1'b0),
                .IDATAIN     (frame_se_raw),
                .INC         (1'b0),
                .LD          (1'b0),
                .LDPIPEEN    (1'b0),
                .REGRST      (1'b0),
                .DATAOUT     (frame_se),
                .CNTVALUEOUT ()
            );

            //------------------------------------------------------------------
            // LVDS Receiver Instance
            // Performs DDR sampling and event assembly for this channel
            //------------------------------------------------------------------
            gpx2_lvds_rx #(
                .REFID_BITS (REFID_BITS),
                .TSTOP_BITS (TSTOP_BITS),
                .USE_DDR    (USE_DDR)
            ) u_rx (
                .lclk_io    (lclk_io),
                .lclk_logic (lclk_logic),
                .rst_lclk   (rst_lclk),
                .sdo_in     (sdo_se),
                .frame_in   (frame_se),
                .event_valid(ch_event_valid_lclk[gi]),
                .event_data (ch_event_data_lclk[gi*EVENT_BITS +: EVENT_BITS])
            );
        end
    endgenerate

    //==========================================================================
    // Round-Robin Arbitration (Combinational)
    //==========================================================================
    // 这里显式写 4 路优先级而不是通用 for-loop，是为了减小组合锥深度，
    // 让 250 MHz 的 lclk_logic 更容易过时序。
    //==========================================================================
    always @(*) begin
        wr_sel_valid = 1'b0;
        wr_sel_idx   = 2'd0;
        wr_sel_oh    = {NUM_CH{1'b0}};

        case (rr_ptr_lclk)
            2'd0: begin
                if (pend_count[0] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd0;
                    wr_sel_oh    = 4'b0001;
                end else if (pend_count[1] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd1;
                    wr_sel_oh    = 4'b0010;
                end else if (pend_count[2] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd2;
                    wr_sel_oh    = 4'b0100;
                end else if (pend_count[3] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd3;
                    wr_sel_oh    = 4'b1000;
                end
            end
            2'd1: begin
                if (pend_count[1] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd1;
                    wr_sel_oh    = 4'b0010;
                end else if (pend_count[2] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd2;
                    wr_sel_oh    = 4'b0100;
                end else if (pend_count[3] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd3;
                    wr_sel_oh    = 4'b1000;
                end else if (pend_count[0] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd0;
                    wr_sel_oh    = 4'b0001;
                end
            end
            2'd2: begin
                if (pend_count[2] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd2;
                    wr_sel_oh    = 4'b0100;
                end else if (pend_count[3] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd3;
                    wr_sel_oh    = 4'b1000;
                end else if (pend_count[0] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd0;
                    wr_sel_oh    = 4'b0001;
                end else if (pend_count[1] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd1;
                    wr_sel_oh    = 4'b0010;
                end
            end
            default: begin
                if (pend_count[3] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd3;
                    wr_sel_oh    = 4'b1000;
                end else if (pend_count[0] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd0;
                    wr_sel_oh    = 4'b0001;
                end else if (pend_count[1] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd1;
                    wr_sel_oh    = 4'b0010;
                end else if (pend_count[2] != 3'd0) begin
                    wr_sel_valid = 1'b1;
                    wr_sel_idx   = 2'd2;
                    wr_sel_oh    = 4'b0100;
                end
            end
        endcase
    end

    //==========================================================================
    // Pending Buffer Management (lclk_logic domain)
    //==========================================================================
    // Manages per-channel event buffers:
    //   - Stores incoming events from gpx2_lvds_rx
    //   - Drains events to async FIFO when selected by round-robin
    //   - Tracks buffer occupancy with pend_count
    //   - Sets overflow flag if buffer full on new arrival
    //==========================================================================
    always @(posedge lclk_logic) begin
        if (rst_lclk) begin
            // Reset all arbitration state
            rr_ptr_lclk     <= 2'd0;
            af_wr_en_lclk   <= 1'b0;
            af_wr_data_lclk <= {(EVENT_BITS+2){1'b0}};
            overflow_lclk   <= 1'b0;
            // Reset per-channel buffers
            for (i = 0; i < NUM_CH; i = i + 1) begin
                pend_count[i]  <= 3'd0;
                pend_wr_ptr[i] <= 2'd0;
                pend_rd_ptr[i] <= 2'd0;
            end
            // Clear pending memory
            for (mem_idx = 0; mem_idx < NUM_CH*PEND_DEPTH; mem_idx = mem_idx + 1)
                pend_mem[mem_idx] <= {EVENT_BITS{1'b0}};
        end else begin
            // Default: no FIFO write
            af_wr_en_lclk <= 1'b0;

            // 先做出队：把本拍仲裁选中的一路写入异步 FIFO。
            if (drain_fire) begin
                af_wr_en_lclk   <= 1'b1;
                // Pack: {channel[1:0], event[43:0]}
                case (wr_sel_idx)
                    2'd0: af_wr_data_lclk <= {2'd0, pend_mem[0*PEND_DEPTH + pend_rd_ptr[0]]};
                    2'd1: af_wr_data_lclk <= {2'd1, pend_mem[1*PEND_DEPTH + pend_rd_ptr[1]]};
                    2'd2: af_wr_data_lclk <= {2'd2, pend_mem[2*PEND_DEPTH + pend_rd_ptr[2]]};
                    default: af_wr_data_lclk <= {2'd3, pend_mem[3*PEND_DEPTH + pend_rd_ptr[3]]};
                endcase
                // Advance read pointer (wraps at PEND_DEPTH)
                pend_rd_ptr[wr_sel_idx] <= pend_rd_ptr[wr_sel_idx] + 1'b1;
                // Decrement count if no simultaneous arrival on this channel
                if (!ch_event_valid_lclk[wr_sel_idx])
                    pend_count[wr_sel_idx] <= pend_count[wr_sel_idx] - 1'b1;
                // Advance round-robin pointer to next channel
                rr_ptr_lclk <= wr_sel_idx + 1'b1;
            end

            // 再做入队：把各通道本拍新到的事件写进各自 pending buffer。
            for (i = 0; i < NUM_CH; i = i + 1) begin
                if (ch_event_valid_lclk[i]) begin
                    // Check if buffer is full
                    if ((pend_count[i] == PEND_DEPTH) &&
                        !drain_hit[i]) begin
                        // Buffer full and not being drained this cycle -> overflow
                        overflow_lclk <= 1'b1;
                    end else begin
                        // Store event in pending buffer
                        pend_mem[i*PEND_DEPTH + pend_wr_ptr[i]] <=
                            ch_event_data_lclk[i*EVENT_BITS +: EVENT_BITS];
                        // Advance write pointer
                        pend_wr_ptr[i] <= pend_wr_ptr[i] + 1'b1;
                        // Increment count if not being drained simultaneously
                        if (!drain_hit[i])
                            pend_count[i] <= pend_count[i] + 1'b1;
                    end
                end
            end
        end
    end

    //==========================================================================
    // Async FIFO Instance
    //==========================================================================
    // Cross-clock domain bridge from lclk_logic to sys_clk.
    // Width: 46 bits = {ch[1:0], event[43:0]}
    // Provides backpressure via full/almost_full flags.
    //==========================================================================
    async_fifo_46b u_af (
        .wr_clk      (lclk_logic),          // Write domain: GPX2 clock
        .rst         (sys_rst),             // Async reset
        .wr_en       (af_wr_en_lclk),       // Write enable
        .din         (af_wr_data_lclk),     // Write data {ch, event}
        .full        (af_full),             // FIFO full flag
        .almost_full (af_almost_full),      // Almost full watermark
        .wr_rst_busy (af_wr_rst_busy),      // Write side reset busy
        .rd_clk      (sys_clk),             // Read domain: system clock
        .rd_en       (af_rd_en),            // Read enable
        .dout        (af_rd_data),          // Read data {ch, event}
        .empty       (af_empty),           // FIFO empty flag
        .rd_rst_busy (af_rd_rst_busy)      // Read side reset busy
    );

    //==========================================================================
    // Event Output Interface (sys_clk domain)
    //==========================================================================
    // Reads from async FIFO and presents events to the system.
    // Uses valid/ready handshaking for backpressure support.
    // Synchronizes overflow flag from lclk_logic domain.
    //==========================================================================
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            // Reset output interface
            af_rd_en       <= 1'b0;
            event_valid    <= 1'b0;
            event_ch       <= 2'd0;
            event_refid    <= {REFID_BITS{1'b0}};
            event_tstop    <= {TSTOP_BITS{1'b0}};
            overflow_sys_sync1 <= 1'b0;
            overflow_sys_sync2 <= 1'b0;
            event_overflow <= 1'b0;
        end else begin
            // Default: no read
            af_rd_en       <= 1'b0;
            // Synchronize overflow flag (2-stage for metastability)
            overflow_sys_sync1 <= overflow_lclk;
            overflow_sys_sync2 <= overflow_sys_sync1;
            // Sticky overflow flag - set and stays set until reset
            if (overflow_sys_sync2)
                event_overflow <= 1'b1;

            // Read FIFO when:
            //   - FIFO has data (af_rd_valid)
            //   - Output is not holding valid data, OR system accepted previous data
            if (!event_valid || event_ready) begin
                if (af_rd_valid) begin
                    af_rd_en       <= 1'b1;          // Request next FIFO read
                    event_valid    <= 1'b1;          // Signal valid data
                    // Unpack FIFO data: {ch[1:0], refid[23:0], tstop[19:0]}
                    event_ch       <= af_rd_data[EVENT_BITS+1:EVENT_BITS];
                    event_refid    <= af_rd_data[EVENT_BITS-1 -: REFID_BITS];
                    event_tstop    <= af_rd_data[TSTOP_BITS-1:0];
                end else begin
                    // No data available
                    event_valid <= 1'b0;
                end
            end
        end
    end

endmodule
