`timescale 1ns/1ps

module gpx2_tcspc_event_top #(
    parameter integer NUM_CH = 4,
    parameter integer SYS_CLK_HZ = 100_000_000,
    parameter integer IDELAY_TAPS = 16
)(
    input  wire              sys_clk,
    input  wire              sys_rst,
    input  wire              idelay_refclk,
    input  wire              start_cfg,
    output wire              cfg_done,
    output wire              cfg_error,

    output wire              gpx2_ssn,
    output wire              gpx2_sck,
    output wire              gpx2_mosi,
    input  wire              gpx2_miso,

    input  wire              gpx2_lclkout_p,
    input  wire              gpx2_lclkout_n,
    output wire              gpx2_lclkin_p,
    output wire              gpx2_lclkin_n,
    input  wire              lclk_in,

    input  wire [NUM_CH-1:0] gpx2_sdo_p,
    input  wire [NUM_CH-1:0] gpx2_sdo_n,
    input  wire [NUM_CH-1:0] gpx2_frame_p,
    input  wire [NUM_CH-1:0] gpx2_frame_n,

    output wire              out_valid,
    output wire [31:0]       out_data,
    input  wire              out_ready,
    output wire              out_last,

    output reg               event_overflow,
    output wire [31:0]       photon_valid_count,
    output wire [31:0]       laser_count,
    output wire [31:0]       detector_count
);

    localparam integer EVENT_BITS = 30;

    wire cfg_busy;
    wire lclk_in_se;
    wire lclk_io;
    wire lclk_logic;
    wire rst_lclk;
    wire idelayctrl_rdy;
    wire rst_lclk_req;

    wire [3:0]       rx_valid_lclk;
    wire [EVENT_BITS-1:0] rx_data_lclk [0:3];
    wire [31:0]      raw_din [0:3];
    wire [31:0]      raw_dout [0:3];
    wire [3:0]       raw_full;
    wire [3:0]       raw_empty;
    wire [3:0]       raw_almost_full;
    wire [3:0]       raw_wr_rst_busy;
    wire [3:0]       raw_rd_rst_busy;
    wire [3:0]       raw_wr_en;
    wire [3:0]       raw_rd_en;
    wire [3:0]       raw_valid_sys;
    wire [3:0]       raw_ready_sys;

    wire [127:0]     ext_data [0:3];
    wire [3:0]       ext_valid;
    wire [3:0]       ext_ready;
    wire [127:0]     ext_fifo_dout [0:3];
    wire [3:0]       ext_fifo_full;
    wire [3:0]       ext_fifo_empty;
    wire [3:0]       ext_fifo_wr_en;
    wire [3:0]       ext_fifo_rd_en;

    wire             merged_valid;
    wire             merged_ready;
    wire [127:0]     merged_event;

    wire             photon_valid;
    wire             photon_ready;
    wire [127:0]     photon_event;
    wire [127:0]     photon_fifo_dout;
    wire             photon_fifo_full;
    wire             photon_fifo_empty;
    wire             photon_fifo_wr_en;
    wire             photon_fifo_rd_en;
    wire             streamer_photon_ready;

    wire [31:0] dt_overflow_count;
    wire [31:0] no_laser_count;
    wire [31:0] line_count;
    wire [31:0] pixel_count;

    assign rst_lclk_req = sys_rst | ~idelayctrl_rdy;

    gpx2_spi_config #(
        .SPI_DIV(4),
        .SYS_CLK_HZ(SYS_CLK_HZ),
        .POST_INIT_WAIT_US(200)
    ) u_cfg (
        .clk         (sys_clk),
        .rst         (sys_rst),
        .start       (start_cfg),
        .config_done (cfg_done),
        .config_error(cfg_error),
        .busy        (cfg_busy),
        .ssn         (gpx2_ssn),
        .sck         (gpx2_sck),
        .mosi        (gpx2_mosi),
        .miso        (gpx2_miso)
    );

    (* IODELAY_GROUP = "GPX2_IODELAY" *)
    IDELAYCTRL u_idelayctrl (
        .REFCLK(idelay_refclk),
        .RST   (sys_rst),
        .RDY   (idelayctrl_rdy)
    );

    IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS")) u_lclkout_ibufds (
        .I (gpx2_lclkout_p),
        .IB(gpx2_lclkout_n),
        .O (lclk_in_se)
    );

    BUFIO u_lclk_bufio (
        .I(lclk_in_se),
        .O(lclk_io)
    );

    BUFR #(
        .BUFR_DIVIDE("BYPASS"),
        .SIM_DEVICE("7SERIES")
    ) u_lclk_bufr (
        .I  (lclk_in_se),
        .CE (1'b1),
        .CLR(1'b0),
        .O  (lclk_logic)
    );

    OBUFDS #(.IOSTANDARD("LVDS")) u_lclkin_obufds (
        .I (lclk_in),
        .O (gpx2_lclkin_p),
        .OB(gpx2_lclkin_n)
    );

    (* ASYNC_REG = "TRUE" *) reg [2:0] rst_lclk_ff;
    always @(posedge lclk_logic or posedge rst_lclk_req) begin
        if (rst_lclk_req)
            rst_lclk_ff <= 3'b111;
        else
            rst_lclk_ff <= {rst_lclk_ff[1:0], 1'b0};
    end
    assign rst_lclk = rst_lclk_ff[2];

    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_done_lclk_ff;
    wire cfg_done_lclk;
    always @(posedge lclk_logic) begin
        if (rst_lclk)
            cfg_done_lclk_ff <= 3'b000;
        else
            cfg_done_lclk_ff <= {cfg_done_lclk_ff[1:0], cfg_done};
    end
    assign cfg_done_lclk = cfg_done_lclk_ff[2];

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : G_RX
            localparam [1:0] CH_ID = gi;
            wire sdo_se;
            wire frame_se;
            wire sdo_delayed;
            wire frame_delayed;

            IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS")) u_sdo_ibufds (
                .I (gpx2_sdo_p[gi]),
                .IB(gpx2_sdo_n[gi]),
                .O (sdo_se)
            );
            IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("LVDS")) u_frame_ibufds (
                .I (gpx2_frame_p[gi]),
                .IB(gpx2_frame_n[gi]),
                .O (frame_se)
            );

            (* IODELAY_GROUP = "GPX2_IODELAY" *)
            IDELAYE2 #(
                .IDELAY_TYPE("FIXED"),
                .IDELAY_VALUE(IDELAY_TAPS),
                .DELAY_SRC("IDATAIN"),
                .SIGNAL_PATTERN("DATA"),
                .REFCLK_FREQUENCY(200.0),
                .HIGH_PERFORMANCE_MODE("TRUE")
            ) u_sdo_idelay (
                .C(1'b0), .CE(1'b0), .INC(1'b0), .LD(1'b0), .LDPIPEEN(1'b0),
                .REGRST(1'b0), .CINVCTRL(1'b0), .CNTVALUEIN(5'd0),
                .DATAIN(1'b0), .IDATAIN(sdo_se), .DATAOUT(sdo_delayed),
                .CNTVALUEOUT()
            );

            (* IODELAY_GROUP = "GPX2_IODELAY" *)
            IDELAYE2 #(
                .IDELAY_TYPE("FIXED"),
                .IDELAY_VALUE(IDELAY_TAPS),
                .DELAY_SRC("IDATAIN"),
                .SIGNAL_PATTERN("DATA"),
                .REFCLK_FREQUENCY(200.0),
                .HIGH_PERFORMANCE_MODE("TRUE")
            ) u_frame_idelay (
                .C(1'b0), .CE(1'b0), .INC(1'b0), .LD(1'b0), .LDPIPEEN(1'b0),
                .REGRST(1'b0), .CINVCTRL(1'b0), .CNTVALUEIN(5'd0),
                .DATAIN(1'b0), .IDATAIN(frame_se), .DATAOUT(frame_delayed),
                .CNTVALUEOUT()
            );

            gpx2_lvds_rx #(
                .REFID_BITS(16),
                .TSTOP_BITS(14),
                .USE_DDR(1),
                .EVENT_BITS(EVENT_BITS)
            ) u_rx (
                .lclk_io    (lclk_io),
                .lclk_logic (lclk_logic),
                .rst_lclk   (rst_lclk | ~cfg_done_lclk),
                .sdo_in     (sdo_delayed),
                .frame_in   (frame_delayed),
                .event_valid(rx_valid_lclk[gi]),
                .event_data (rx_data_lclk[gi])
            );

            assign raw_din[gi]  = {CH_ID, rx_data_lclk[gi][29:14], rx_data_lclk[gi][13:0]};
            assign raw_wr_en[gi] = rx_valid_lclk[gi] && !raw_full[gi] && !raw_wr_rst_busy[gi] && cfg_done_lclk;
        end
    endgenerate

    gpx2_raw_fifo_ch1 u_raw_fifo_ch1 (
        .wr_clk(lclk_logic), .rd_clk(sys_clk), .rst(sys_rst),
        .din(raw_din[0]), .wr_en(raw_wr_en[0]), .rd_en(raw_rd_en[0]),
        .dout(raw_dout[0]), .full(raw_full[0]), .almost_full(raw_almost_full[0]),
        .empty(raw_empty[0]), .wr_rst_busy(raw_wr_rst_busy[0]), .rd_rst_busy(raw_rd_rst_busy[0])
    );
    gpx2_raw_fifo_ch2 u_raw_fifo_ch2 (
        .wr_clk(lclk_logic), .rd_clk(sys_clk), .rst(sys_rst),
        .din(raw_din[1]), .wr_en(raw_wr_en[1]), .rd_en(raw_rd_en[1]),
        .dout(raw_dout[1]), .full(raw_full[1]), .almost_full(raw_almost_full[1]),
        .empty(raw_empty[1]), .wr_rst_busy(raw_wr_rst_busy[1]), .rd_rst_busy(raw_rd_rst_busy[1])
    );
    gpx2_raw_fifo_ch3 u_raw_fifo_ch3 (
        .wr_clk(lclk_logic), .rd_clk(sys_clk), .rst(sys_rst),
        .din(raw_din[2]), .wr_en(raw_wr_en[2]), .rd_en(raw_rd_en[2]),
        .dout(raw_dout[2]), .full(raw_full[2]), .almost_full(raw_almost_full[2]),
        .empty(raw_empty[2]), .wr_rst_busy(raw_wr_rst_busy[2]), .rd_rst_busy(raw_rd_rst_busy[2])
    );
    gpx2_raw_fifo_ch4 u_raw_fifo_ch4 (
        .wr_clk(lclk_logic), .rd_clk(sys_clk), .rst(sys_rst),
        .din(raw_din[3]), .wr_en(raw_wr_en[3]), .rd_en(raw_rd_en[3]),
        .dout(raw_dout[3]), .full(raw_full[3]), .almost_full(raw_almost_full[3]),
        .empty(raw_empty[3]), .wr_rst_busy(raw_wr_rst_busy[3]), .rd_rst_busy(raw_rd_rst_busy[3])
    );

    assign raw_valid_sys[0] = ~raw_empty[0] & ~raw_rd_rst_busy[0];
    assign raw_valid_sys[1] = ~raw_empty[1] & ~raw_rd_rst_busy[1];
    assign raw_valid_sys[2] = ~raw_empty[2] & ~raw_rd_rst_busy[2];
    assign raw_valid_sys[3] = ~raw_empty[3] & ~raw_rd_rst_busy[3];
    assign raw_rd_en = raw_valid_sys & raw_ready_sys;

    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : G_EXT
            timestamp_extend u_timestamp_extend (
                .clk       (sys_clk),
                .rst       (sys_rst),
                .raw_valid (raw_valid_sys[gi]),
                .raw_ready (raw_ready_sys[gi]),
                .raw_event (raw_dout[gi]),
                .ext_valid (ext_valid[gi]),
                .ext_ready (ext_ready[gi]),
                .ext_event (ext_data[gi])
            );
            assign ext_ready[gi]     = ~ext_fifo_full[gi];
            assign ext_fifo_wr_en[gi] = ext_valid[gi] & ext_ready[gi];
        end
    endgenerate

    gpx2_ext_fifo_ch1 u_ext_fifo_ch1 (
        .clk(sys_clk), .rst(sys_rst), .din(ext_data[0]), .wr_en(ext_fifo_wr_en[0]),
        .rd_en(ext_fifo_rd_en[0]), .dout(ext_fifo_dout[0]), .full(ext_fifo_full[0]), .empty(ext_fifo_empty[0])
    );
    gpx2_ext_fifo_ch2 u_ext_fifo_ch2 (
        .clk(sys_clk), .rst(sys_rst), .din(ext_data[1]), .wr_en(ext_fifo_wr_en[1]),
        .rd_en(ext_fifo_rd_en[1]), .dout(ext_fifo_dout[1]), .full(ext_fifo_full[1]), .empty(ext_fifo_empty[1])
    );
    gpx2_ext_fifo_ch3 u_ext_fifo_ch3 (
        .clk(sys_clk), .rst(sys_rst), .din(ext_data[2]), .wr_en(ext_fifo_wr_en[2]),
        .rd_en(ext_fifo_rd_en[2]), .dout(ext_fifo_dout[2]), .full(ext_fifo_full[2]), .empty(ext_fifo_empty[2])
    );
    gpx2_ext_fifo_ch4 u_ext_fifo_ch4 (
        .clk(sys_clk), .rst(sys_rst), .din(ext_data[3]), .wr_en(ext_fifo_wr_en[3]),
        .rd_en(ext_fifo_rd_en[3]), .dout(ext_fifo_dout[3]), .full(ext_fifo_full[3]), .empty(ext_fifo_empty[3])
    );

    event_merger u_event_merger (
        .clk(sys_clk), .rst(sys_rst),
        .ch0_valid(~ext_fifo_empty[0]), .ch0_data(ext_fifo_dout[0]), .ch0_ready(ext_fifo_rd_en[0]),
        .ch1_valid(~ext_fifo_empty[1]), .ch1_data(ext_fifo_dout[1]), .ch1_ready(ext_fifo_rd_en[1]),
        .ch2_valid(~ext_fifo_empty[2]), .ch2_data(ext_fifo_dout[2]), .ch2_ready(ext_fifo_rd_en[2]),
        .ch3_valid(~ext_fifo_empty[3]), .ch3_data(ext_fifo_dout[3]), .ch3_ready(ext_fifo_rd_en[3]),
        .out_valid(merged_valid), .out_data(merged_event), .out_ready(merged_ready)
    );

    tcspc_event_processor u_tcspc (
        .clk(sys_clk), .rst(sys_rst),
        .in_valid(merged_valid), .in_ready(merged_ready), .in_event(merged_event),
        .photon_valid(photon_valid), .photon_ready(photon_ready), .photon_event(photon_event),
        .laser_count(laser_count), .detector_count(detector_count),
        .photon_valid_count(photon_valid_count), .dt_overflow_count(dt_overflow_count),
        .no_laser_count(no_laser_count), .line_count(line_count), .pixel_count(pixel_count)
    );

    assign photon_ready = ~photon_fifo_full;
    assign photon_fifo_wr_en = photon_valid & photon_ready;

    gpx2_photon_fifo_128 u_photon_fifo (
        .clk(sys_clk), .rst(sys_rst), .din(photon_event), .wr_en(photon_fifo_wr_en),
        .rd_en(photon_fifo_rd_en), .dout(photon_fifo_dout), .full(photon_fifo_full), .empty(photon_fifo_empty)
    );

    assign photon_fifo_rd_en = ~photon_fifo_empty & streamer_photon_ready;

    photon_event_streamer u_streamer (
        .clk(sys_clk), .rst(sys_rst),
        .photon_valid(~photon_fifo_empty), .photon_ready(streamer_photon_ready),
        .photon_event(photon_fifo_dout),
        .out_valid(out_valid), .out_data(out_data), .out_ready(out_ready), .out_last(out_last)
    );

    always @(posedge sys_clk) begin
        if (sys_rst)
            event_overflow <= 1'b0;
        else if (|ext_fifo_full ||
                 photon_fifo_full)
            event_overflow <= 1'b1;
    end

endmodule
