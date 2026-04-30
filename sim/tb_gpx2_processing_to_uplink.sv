`timescale 1ns/1ps

module tb_gpx2_processing_to_uplink;
    reg clk = 1'b0;
    reg rst = 1'b1;

    always #5 clk = ~clk;

    localparam integer QDEPTH = 8;

    reg [127:0] q0 [0:QDEPTH-1];
    reg [127:0] q1 [0:QDEPTH-1];
    reg [127:0] q2 [0:QDEPTH-1];
    reg [127:0] q3 [0:QDEPTH-1];
    integer rd0 = 0, rd1 = 0, rd2 = 0, rd3 = 0;
    integer wr0 = 0, wr1 = 0, wr2 = 0, wr3 = 0;

    wire ch0_valid = (rd0 < wr0);
    wire ch1_valid = (rd1 < wr1);
    wire ch2_valid = (rd2 < wr2);
    wire ch3_valid = (rd3 < wr3);
    wire [127:0] ch0_data = q0[rd0];
    wire [127:0] ch1_data = q1[rd1];
    wire [127:0] ch2_data = q2[rd2];
    wire [127:0] ch3_data = q3[rd3];
    wire ch0_ready, ch1_ready, ch2_ready, ch3_ready;

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
    reg tx_ready = 1'b1;

    wire [31:0] laser_count;
    wire [31:0] detector_count;
    wire [31:0] photon_valid_count;
    wire [31:0] dt_overflow_count;
    wire [31:0] no_laser_count;
    wire [31:0] line_count;
    wire [31:0] pixel_count;

    integer out_count = 0;
    integer error_count = 0;
    reg [31:0] out_mem [0:255];

    event_merger #(
        .DETECTOR_WAIT_CYCLES(3)
    ) u_merger (
        .clk(clk), .rst(rst),
        .ch0_valid(ch0_valid), .ch0_data(ch0_data), .ch0_ready(ch0_ready),
        .ch1_valid(ch1_valid), .ch1_data(ch1_data), .ch1_ready(ch1_ready),
        .ch2_valid(ch2_valid), .ch2_data(ch2_data), .ch2_ready(ch2_ready),
        .ch3_valid(ch3_valid), .ch3_data(ch3_data), .ch3_ready(ch3_ready),
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
        .COLLECT_TIMEOUT_CYC(64)
    ) u_uplink (
        .clk(clk), .rst(rst),
        .photon_valid(stream_valid), .photon_ready(stream_ready),
        .photon_data(stream_data), .photon_last(stream_last),
        .status_valid(1'b0), .status_flags(16'd0), .uptime_seconds(32'd0),
        .temp_avg(16'd0), .counter_1s(32'd0), .tdc_drop_count(32'd0), .usb_drop_count(32'd0),
        .ack_valid(1'b0), .ack_ready(), .ack_cmd_id(8'd0), .ack_status(8'd0), .ack_data(32'd0),
        .tx_data(tx_data), .tx_be(tx_be), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    function automatic [127:0] ext_event(input [1:0] ch, input [63:0] ts);
        begin
            ext_event = {ch, ts, 16'd0, 14'd0, 32'd0};
        end
    endfunction

    task automatic preload_events;
        begin
            q2[wr2] = ext_event(2'd2, 64'd10);    wr2 = wr2 + 1;
            q2[wr2] = ext_event(2'd2, 64'd25000); wr2 = wr2 + 1;

            q3[wr3] = ext_event(2'd3, 64'd20);    wr3 = wr3 + 1;
            q3[wr3] = ext_event(2'd3, 64'd30);    wr3 = wr3 + 1;
            q3[wr3] = ext_event(2'd3, 64'd14000); wr3 = wr3 + 1;
            q3[wr3] = ext_event(2'd3, 64'd25500); wr3 = wr3 + 1;

            q1[wr1] = ext_event(2'd1, 64'd1000);  wr1 = wr1 + 1;
            q1[wr1] = ext_event(2'd1, 64'd13500); wr1 = wr1 + 1;
            q1[wr1] = ext_event(2'd1, 64'd26000); wr1 = wr1 + 1;

            q0[wr0] = ext_event(2'd0, 64'd1625);  wr0 = wr0 + 1;
            q0[wr0] = ext_event(2'd0, 64'd15000); wr0 = wr0 + 1;
            q0[wr0] = ext_event(2'd0, 64'd29750); wr0 = wr0 + 1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            if (ch0_ready && ch0_valid) rd0 <= rd0 + 1;
            if (ch1_ready && ch1_valid) rd1 <= rd1 + 1;
            if (ch2_ready && ch2_valid) rd2 <= rd2 + 1;
            if (ch3_ready && ch3_valid) rd3 <= rd3 + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst && tx_valid && tx_ready) begin
            if (tx_be != 4'hF) begin
                $display("TEST FAILED: tx_be=%h", tx_be);
                error_count = error_count + 1;
            end
            out_mem[out_count] = tx_data;
            out_count = out_count + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst)
            tx_ready <= (($time / 10) % 7 != 3);
    end

    task automatic check_packet;
        integer base;
        begin
            base = 0;
            if (out_count != 19) begin
                $display("TEST FAILED: expected 19 output words, got %0d", out_count);
                error_count = error_count + 1;
            end
            if (out_mem[base] != 32'hA5_04_01_04) begin
                $display("TEST FAILED: bad photon header0 %08x", out_mem[base]);
                error_count = error_count + 1;
            end
            if (out_mem[base+1][15:0] != 16'd15 || out_mem[base+2][31:16] != 16'd3) begin
                $display("TEST FAILED: bad payload_words/items header1=%08x header2=%08x", out_mem[base+1], out_mem[base+2]);
                error_count = error_count + 1;
            end

            if (out_mem[base+4]  != 32'hA55A_F00D ||
                out_mem[base+9]  != 32'hA55A_F00D ||
                out_mem[base+14] != 32'hA55A_F00D) begin
                $display("TEST FAILED: missing photon record markers");
                error_count = error_count + 1;
            end

            if (out_mem[base+5]  != {8'h01, 8'h00, 16'd1} || out_mem[base+6]  != {16'd2, 16'd78}  || out_mem[base+7]  != 32'd625) begin
                $display("TEST FAILED: photon0 words=%08x %08x %08x", out_mem[base+5], out_mem[base+6], out_mem[base+7]);
                error_count = error_count + 1;
            end
            if (out_mem[base+10] != {8'h01, 8'h00, 16'd1} || out_mem[base+11] != {16'd3, 16'd187} || out_mem[base+12] != 32'd1500) begin
                $display("TEST FAILED: photon1 words=%08x %08x %08x", out_mem[base+10], out_mem[base+11], out_mem[base+12]);
                error_count = error_count + 1;
            end
            if (out_mem[base+15] != {8'h01, 8'h00, 16'd2} || out_mem[base+16] != {16'd1, 16'd468} || out_mem[base+17] != 32'd3750) begin
                $display("TEST FAILED: photon2 words=%08x %08x %08x", out_mem[base+15], out_mem[base+16], out_mem[base+17]);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        preload_events();
        repeat (6) @(posedge clk);
        rst = 1'b0;

        repeat (600) @(posedge clk);

        if (laser_count != 32'd3 || detector_count != 32'd3 || photon_valid_count != 32'd3) begin
            $display("TEST FAILED: counts laser=%0d detector=%0d photon=%0d", laser_count, detector_count, photon_valid_count);
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
            $fdisplay($fopen("tb_gpx2_processing_to_uplink.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_gpx2_processing_to_uplink.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
