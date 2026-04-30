`timescale 1ns/1ps

module ila_ft601(
    input wire clk,
    input wire [2:0] probe0,
    input wire [31:0] probe1,
    input wire [3:0] probe2,
    input wire probe3,
    input wire probe4,
    input wire probe5,
    input wire probe6,
    input wire probe7,
    input wire [31:0] probe8,
    input wire [3:0] probe9,
    input wire probe10,
    input wire probe11,
    input wire [31:0] probe12,
    input wire [3:0] probe13,
    input wire probe14,
    input wire probe15
);
endmodule

module tb_gpx2_lvds_to_ft601_e2e;
    localparam integer NUM_CH = 4;
    localparam integer EVENT_BITS = 30;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [NUM_CH-1:0] sdo = 4'd0;
    reg [NUM_CH-1:0] frame = 4'd0;

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
    wire [31:0] laser_count;
    wire [31:0] detector_count;
    wire [31:0] photon_valid_count;
    wire [31:0] dt_overflow_count;
    wire [31:0] no_laser_count;
    wire [31:0] line_count;
    wire [31:0] pixel_count;

    wire stream_valid;
    wire stream_ready;
    wire [31:0] stream_data;
    wire stream_last;

    wire [31:0] tx_data;
    wire [3:0] tx_be;
    wire tx_valid;
    wire tx_ready;

    wire [31:0] ft_data;
    wire [3:0] ft_be;
    reg ft_txe_n = 1'b0;
    reg ft_rxf_n = 1'b1;
    reg ft_txe_n_q = 1'b0;
    wire ft_wr_n;
    wire ft_rd_n;
    wire ft_oe_n;
    wire ft_siwu_n;
    wire [31:0] rx_usb_data;
    wire [3:0] rx_usb_be;
    wire rx_usb_valid;
    wire [2:0] dbg_state;

    integer cap_count = 0;
    integer error_count = 0;
    reg [31:0] cap_data [0:255];

    always #2 clk = ~clk;

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
                .sdo_in(sdo[gi]),
                .frame_in(frame[gi]),
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
        .PHOTON_EVENTS_PER_PKT(3),
        .COLLECT_TIMEOUT_CYC(4096)
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
        .dbg_state(dbg_state)
    );

    function automatic [29:0] raw_from_timestamp(input [63:0] ts);
        reg [15:0] ref_index;
        reg [13:0] stop_result;
        begin
            ref_index = ts / 64'd12500;
            stop_result = ts % 64'd12500;
            raw_from_timestamp = {ref_index, stop_result};
        end
    endfunction

    task automatic drive_ddr_event(input integer ch, input [63:0] ts);
        reg [29:0] ev;
        integer bit_ptr;
        integer edge_idx;
        begin
            ev = raw_from_timestamp(ts);
            bit_ptr = 29;
            for (edge_idx = 0; edge_idx < 15; edge_idx = edge_idx + 1) begin
                @(negedge clk);
                #0.2;
                sdo[ch] = ev[bit_ptr];
                frame[ch] = (edge_idx < 4);
                @(posedge clk);
                #0.2;
                sdo[ch] = ev[bit_ptr - 1];
                frame[ch] = (edge_idx < 4);
                bit_ptr = bit_ptr - 2;
            end
            @(negedge clk);
            #0.2;
            sdo[ch] = 1'b0;
            frame[ch] = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    always @(negedge clk) begin
        if (!rst)
            ft_txe_n <= ((($time / 4) % 13) == 4 || (($time / 4) % 13) == 5) ? 1'b1 : 1'b0;
    end

    always @(posedge clk) begin
        if (rst)
            ft_txe_n_q <= 1'b0;
        else
            ft_txe_n_q <= ft_txe_n;
    end

    always @(posedge clk) begin
        if (!rst && !ft_wr_n) begin
            if (ft_txe_n_q) begin
                $display("TEST FAILED: FT601 WR_N low while TXE_N high");
                error_count = error_count + 1;
            end
            if (ft_data === 32'hzzzz_zzzz || ft_be === 4'hz) begin
                $display("TEST FAILED: FT601 write bus is high-Z");
                error_count = error_count + 1;
            end
            if (ft_be !== 4'hF) begin
                $display("TEST FAILED: FT601 byte enable %h", ft_be);
                error_count = error_count + 1;
            end
            if (ft_rd_n !== 1'b1 || ft_oe_n !== 1'b1) begin
                $display("TEST FAILED: FT601 RX controls active during TX rd=%b oe=%b", ft_rd_n, ft_oe_n);
                error_count = error_count + 1;
            end
            cap_data[cap_count] = ft_data;
            cap_count = cap_count + 1;
        end
    end

    task automatic check_packet;
        begin
            if (cap_count != 19) begin
                $display("TEST FAILED: expected 19 FT601 writes, got %0d", cap_count);
                error_count = error_count + 1;
            end
            if (cap_data[0] != 32'hA5_04_01_04 ||
                cap_data[1][15:0] != 16'd15 ||
                cap_data[2][31:16] != 16'd3) begin
                $display("TEST FAILED: bad photon packet header %08x %08x %08x",
                         cap_data[0], cap_data[1], cap_data[2]);
                error_count = error_count + 1;
            end

            if (cap_data[4]  != 32'hA55A_F00D ||
                cap_data[9]  != 32'hA55A_F00D ||
                cap_data[14] != 32'hA55A_F00D) begin
                $display("TEST FAILED: missing photon markers");
                error_count = error_count + 1;
            end

            if (cap_data[5]  != {8'h01, 8'h00, 16'd1} || cap_data[6]  != {16'd2, 16'd78}  || cap_data[7]  != 32'd625  || cap_data[8]  != 32'd1625) begin
                $display("TEST FAILED: photon0 payload %08x %08x %08x %08x", cap_data[5], cap_data[6], cap_data[7], cap_data[8]);
                error_count = error_count + 1;
            end
            if (cap_data[10] != {8'h01, 8'h00, 16'd1} || cap_data[11] != {16'd3, 16'd187} || cap_data[12] != 32'd1500 || cap_data[13] != 32'd15000) begin
                $display("TEST FAILED: photon1 payload %08x %08x %08x %08x", cap_data[10], cap_data[11], cap_data[12], cap_data[13]);
                error_count = error_count + 1;
            end
            if (cap_data[15] != {8'h01, 8'h00, 16'd2} || cap_data[16] != {16'd1, 16'd468} || cap_data[17] != 32'd3750 || cap_data[18] != 32'd29750) begin
                $display("TEST FAILED: photon2 payload %08x %08x %08x %08x", cap_data[15], cap_data[16], cap_data[17], cap_data[18]);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        repeat (12) @(posedge clk);
        rst = 1'b0;
        repeat (20) @(posedge clk);

        drive_ddr_event(2, 64'd10);
        drive_ddr_event(3, 64'd20);
        drive_ddr_event(3, 64'd30);
        drive_ddr_event(1, 64'd1000);
        drive_ddr_event(0, 64'd1625);
        drive_ddr_event(1, 64'd5000);
        drive_ddr_event(1, 64'd13500);
        drive_ddr_event(3, 64'd14000);
        drive_ddr_event(0, 64'd15000);
        drive_ddr_event(2, 64'd25000);
        drive_ddr_event(3, 64'd25500);
        drive_ddr_event(1, 64'd26000);
        drive_ddr_event(0, 64'd29750);
        drive_ddr_event(1, 64'd31000);
        drive_ddr_event(1, 64'd32000);

        repeat (1200) @(posedge clk);

        if (laser_count != 32'd6 || detector_count != 32'd3 || photon_valid_count != 32'd3) begin
            $display("TEST FAILED: counts laser=%0d detector=%0d photon=%0d",
                     laser_count, detector_count, photon_valid_count);
            error_count = error_count + 1;
        end
        if (line_count != 32'd2 || pixel_count != 32'd4 || no_laser_count != 32'd0 || dt_overflow_count != 32'd0) begin
            $display("TEST FAILED: markers/errors line=%0d pixel=%0d no_laser=%0d overflow=%0d",
                     line_count, pixel_count, no_laser_count, dt_overflow_count);
            error_count = error_count + 1;
        end
        check_packet();

        if (error_count == 0) begin
            $display("TEST PASSED");
            $fdisplay($fopen("tb_gpx2_lvds_to_ft601_e2e.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_gpx2_lvds_to_ft601_e2e.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
