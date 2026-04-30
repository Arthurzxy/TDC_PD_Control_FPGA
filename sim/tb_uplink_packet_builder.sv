`timescale 1ns/1ps

module tb_uplink_packet_builder;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg         photon_valid = 1'b0;
    wire        photon_ready;
    reg [31:0]  photon_data = 32'd0;
    reg         photon_last = 1'b0;

    reg         status_valid = 1'b0;
    reg [15:0]  status_flags = 16'h55AA;
    reg [31:0]  uptime_seconds = 32'h0000_0102;
    reg [15:0]  temp_avg = 16'h0123;
    reg [31:0]  counter_1s = 32'h0000_4567;
    reg [31:0]  tdc_drop_count = 32'h0000_0008;
    reg [31:0]  usb_drop_count = 32'h0000_0009;

    reg         ack_valid = 1'b0;
    wire        ack_ready;
    reg [7:0]   ack_cmd_id = 8'h10;
    reg [7:0]   ack_status = 8'h01;
    reg [31:0]  ack_data = 32'hCAFE_BABE;

    wire [31:0] tx_data;
    wire [3:0]  tx_be;
    wire        tx_valid;
    reg         tx_ready = 1'b1;

    integer out_count = 0;
    integer error_count = 0;
    integer pkt04_count = 0;
    integer pkt02_count = 0;
    integer pkt03_count = 0;
    reg [31:0] out_mem [0:255];

    uplink_packet_builder #(
        .DATA_WIDTH(32),
        .PHOTON_EVENTS_PER_PKT(2),
        .COLLECT_TIMEOUT_CYC(12)
    ) dut (
        .clk(clk), .rst(rst),
        .photon_valid(photon_valid), .photon_ready(photon_ready),
        .photon_data(photon_data), .photon_last(photon_last),
        .status_valid(status_valid), .status_flags(status_flags),
        .uptime_seconds(uptime_seconds), .temp_avg(temp_avg),
        .counter_1s(counter_1s), .tdc_drop_count(tdc_drop_count),
        .usb_drop_count(usb_drop_count),
        .ack_valid(ack_valid), .ack_ready(ack_ready),
        .ack_cmd_id(ack_cmd_id), .ack_status(ack_status), .ack_data(ack_data),
        .tx_data(tx_data), .tx_be(tx_be), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    task automatic send_word(input [31:0] word, input last);
        begin
            @(negedge clk);
            photon_data = word;
            photon_last = last;
            photon_valid = 1'b1;
            do @(posedge clk); while (!photon_ready);
            @(negedge clk);
            photon_valid = 1'b0;
            photon_last = 1'b0;
        end
    endtask

    task automatic send_photon(input [15:0] line_id, input [15:0] pixel_id, input [15:0] bin_index, input [31:0] dt);
        begin
            send_word(32'hA55A_F00D, 1'b0);
            send_word({8'h01, 8'h00, line_id}, 1'b0);
            send_word({pixel_id, bin_index}, 1'b0);
            send_word(dt, 1'b0);
            send_word(32'h1000_0000 + dt, 1'b1);
        end
    endtask

    always @(posedge clk) begin
        if (tx_valid && tx_ready) begin
            if (tx_be != 4'hF) begin
                $display("TEST FAILED: tx_be=%h", tx_be);
                error_count = error_count + 1;
            end
            out_mem[out_count] = tx_data;
            out_count = out_count + 1;
        end
    end

    task automatic parse_output;
        integer idx;
        integer payload_words;
        reg [7:0] pkt_type;
        begin
            idx = 0;
            while (idx + 3 < out_count) begin
                if (out_mem[idx][31:24] != 8'hA5 || out_mem[idx][7:0] != 8'd4) begin
                    $display("TEST FAILED: bad header0 at %0d: %08x", idx, out_mem[idx]);
                    error_count = error_count + 1;
                    idx = idx + 1;
                end else begin
                    pkt_type = out_mem[idx][23:16];
                    payload_words = out_mem[idx+1][15:0];
                    if (pkt_type == 8'h04) begin
                        pkt04_count = pkt04_count + 1;
                        if (payload_words != 10 || out_mem[idx+2][31:16] != 2) begin
                            $display("TEST FAILED: photon header payload=%0d items=%0d", payload_words, out_mem[idx+2][31:16]);
                            error_count = error_count + 1;
                        end
                        if (out_mem[idx+4] != 32'hA55A_F00D || out_mem[idx+9] != 32'hA55A_F00D) begin
                            $display("TEST FAILED: photon payload markers missing at %0d", idx);
                            error_count = error_count + 1;
                        end
                    end else if (pkt_type == 8'h02) begin
                        pkt02_count = pkt02_count + 1;
                        if (payload_words != 6 || out_mem[idx+4] != 32'h0000_55AA) begin
                            $display("TEST FAILED: status packet payload=%0d word0=%08x", payload_words, out_mem[idx+4]);
                            error_count = error_count + 1;
                        end
                    end else if (pkt_type == 8'h03) begin
                        pkt03_count = pkt03_count + 1;
                        if (payload_words != 3 || out_mem[idx+4] != 32'h0000_1001 || out_mem[idx+5] != 32'hCAFE_BABE) begin
                            $display("TEST FAILED: ack packet payload=%0d word0=%08x word1=%08x", payload_words, out_mem[idx+4], out_mem[idx+5]);
                            error_count = error_count + 1;
                        end
                    end else begin
                        $display("TEST FAILED: unexpected packet type %02x", pkt_type);
                        error_count = error_count + 1;
                    end
                    idx = idx + 4 + payload_words;
                end
            end
            if (idx != out_count) begin
                $display("TEST FAILED: trailing words idx=%0d out_count=%0d", idx, out_count);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        @(negedge clk);
        status_valid = 1'b1;
        ack_valid = 1'b1;
        @(negedge clk);
        status_valid = 1'b0;
        ack_valid = 1'b0;

        send_photon(16'd1, 16'd2, 16'd78, 32'd625);
        send_photon(16'd1, 16'd3, 16'd187, 32'd1500);
        send_photon(16'd2, 16'd4, 16'd468, 32'd3750);
        send_photon(16'd2, 16'd5, 16'd79, 32'd632);

        repeat (300) @(posedge clk);
        parse_output();

        if (pkt04_count < 2) begin
            $display("TEST FAILED: photon packet count=%0d", pkt04_count);
            error_count = error_count + 1;
        end
        if (pkt02_count != 1) begin
            $display("TEST FAILED: status packet count=%0d", pkt02_count);
            error_count = error_count + 1;
        end
        if (pkt03_count != 1) begin
            $display("TEST FAILED: ack packet count=%0d", pkt03_count);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("TEST PASSED");
            $fdisplay($fopen("tb_uplink_packet_builder.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_uplink_packet_builder.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
