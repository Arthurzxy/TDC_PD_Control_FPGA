`timescale 1ns/1ps

module gpx2_ft601_chain_dut #(
    parameter integer NUM_CH = 4,
    parameter integer EVENT_BITS = 30,
    parameter integer PHOTON_EVENTS_PER_PKT = 3,
    parameter integer COLLECT_TIMEOUT_CYC = 4096
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire [NUM_CH-1:0]     gpx2_sdo,
    input  wire [NUM_CH-1:0]     gpx2_frame,

    inout  wire [31:0]           ft_data,
    inout  wire [3:0]            ft_be,
    input  wire                  ft_txe_n,
    input  wire                  ft_rxf_n,
    output wire                  ft_wr_n,
    output wire                  ft_rd_n,
    output wire                  ft_oe_n,
    output wire                  ft_siwu_n,

    output wire [31:0]           laser_count,
    output wire [31:0]           detector_count,
    output wire [31:0]           photon_valid_count,
    output wire [31:0]           line_count,
    output wire [31:0]           pixel_count,
    output wire [31:0]           dt_overflow_count,
    output wire [31:0]           no_laser_count,
    output wire [2:0]            ft_dbg_state
);
    wire [NUM_CH-1:0] rx_valid;
    wire [EVENT_BITS-1:0] rx_data [0:NUM_CH-1];
    wire [NUM_CH-1:0] raw_ready;
    wire [NUM_CH-1:0] ext_valid;
    wire [NUM_CH-1:0] ext_ready;
    wire [127:0] ext_event [0:NUM_CH-1];

    wire merged_valid;
    wire merged_ready;
    wire [127:0] merged_event;

    wire photon_valid;
    wire photon_ready;
    wire [127:0] photon_event;

    wire stream_valid;
    wire stream_ready;
    wire [31:0] stream_data;
    wire stream_last;

    wire [31:0] tx_data;
    wire [3:0] tx_be;
    wire tx_valid;
    wire tx_ready;
    wire [31:0] rx_usb_data;
    wire [3:0] rx_usb_be;
    wire rx_usb_valid;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_CH; gi = gi + 1) begin : G_RX_EXT
            gpx2_lvds_rx #(
                .REFID_BITS(16),
                .TSTOP_BITS(14),
                .USE_DDR(1),
                .EVENT_BITS(EVENT_BITS)
            ) u_rx (
                .lclk_io(clk),
                .lclk_logic(clk),
                .rst_lclk(rst),
                .sdo_in(gpx2_sdo[gi]),
                .frame_in(gpx2_frame[gi]),
                .event_valid(rx_valid[gi]),
                .event_data(rx_data[gi])
            );

            timestamp_extend u_ext (
                .clk(clk),
                .rst(rst),
                .raw_valid(rx_valid[gi]),
                .raw_ready(raw_ready[gi]),
                .raw_event({gi[1:0], rx_data[gi]}),
                .ext_valid(ext_valid[gi]),
                .ext_ready(ext_ready[gi]),
                .ext_event(ext_event[gi])
            );
        end
    endgenerate

    event_merger #(
        .DETECTOR_WAIT_CYCLES(6)
    ) u_merger (
        .clk(clk), .rst(rst),
        .ch0_valid(ext_valid[0]), .ch0_data(ext_event[0]), .ch0_ready(ext_ready[0]),
        .ch1_valid(ext_valid[1]), .ch1_data(ext_event[1]), .ch1_ready(ext_ready[1]),
        .ch2_valid(ext_valid[2]), .ch2_data(ext_event[2]), .ch2_ready(ext_ready[2]),
        .ch3_valid(ext_valid[3]), .ch3_data(ext_event[3]), .ch3_ready(ext_ready[3]),
        .out_valid(merged_valid), .out_data(merged_event), .out_ready(merged_ready)
    );

    tcspc_event_processor u_tcspc (
        .clk(clk), .rst(rst),
        .in_valid(merged_valid), .in_ready(merged_ready), .in_event(merged_event),
        .photon_valid(photon_valid), .photon_ready(photon_ready), .photon_event(photon_event),
        .laser_count(laser_count), .detector_count(detector_count),
        .photon_valid_count(photon_valid_count), .dt_overflow_count(dt_overflow_count),
        .no_laser_count(no_laser_count), .line_count(line_count), .pixel_count(pixel_count)
    );

    photon_event_streamer u_streamer (
        .clk(clk), .rst(rst),
        .photon_valid(photon_valid), .photon_ready(photon_ready), .photon_event(photon_event),
        .out_valid(stream_valid), .out_data(stream_data), .out_ready(stream_ready), .out_last(stream_last)
    );

    uplink_packet_builder #(
        .DATA_WIDTH(32),
        .PHOTON_EVENTS_PER_PKT(PHOTON_EVENTS_PER_PKT),
        .COLLECT_TIMEOUT_CYC(COLLECT_TIMEOUT_CYC)
    ) u_uplink (
        .clk(clk), .rst(rst),
        .photon_valid(stream_valid), .photon_ready(stream_ready),
        .photon_data(stream_data), .photon_last(stream_last),
        .status_valid(1'b0), .status_flags(16'd0), .uptime_seconds(32'd0),
        .temp_avg(16'd0), .counter_1s(32'd0), .tdc_drop_count(32'd0), .usb_drop_count(32'd0),
        .ack_valid(1'b0), .ack_ready(), .ack_cmd_id(8'd0), .ack_status(8'd0), .ack_data(32'd0),
        .tx_data(tx_data), .tx_be(tx_be), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    ft601_fifo_if u_ft601 (
        .ft_clk(clk),
        .sys_clk(clk),
        .rst(rst),
        .ft_data(ft_data),
        .ft_be(ft_be),
        .ft_txe_n(ft_txe_n),
        .ft_rxf_n(ft_rxf_n),
        .ft_wr_n(ft_wr_n),
        .ft_rd_n(ft_rd_n),
        .ft_oe_n(ft_oe_n),
        .ft_siwu_n(ft_siwu_n),
        .tx_data(tx_data),
        .tx_be(tx_be),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .rx_data(rx_usb_data),
        .rx_be(rx_usb_be),
        .rx_valid(rx_usb_valid),
        .rx_ready(1'b1),
        .dbg_state(ft_dbg_state)
    );
endmodule
