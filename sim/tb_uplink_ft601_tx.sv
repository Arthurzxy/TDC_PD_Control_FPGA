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

module tb_uplink_ft601_tx;
    reg clk = 1'b0;
    reg rst = 1'b1;

    always #5 clk = ~clk;

    reg photon_valid = 1'b0;
    wire photon_ready;
    reg [31:0] photon_data = 32'd0;
    reg photon_last = 1'b0;

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
    wire [31:0] rx_data;
    wire [3:0] rx_be;
    wire rx_valid;
    wire [2:0] dbg_state;

    integer cap_count = 0;
    integer error_count = 0;
    reg [31:0] cap_data [0:127];

    uplink_packet_builder #(
        .DATA_WIDTH(32),
        .PHOTON_EVENTS_PER_PKT(1),
        .COLLECT_TIMEOUT_CYC(32)
    ) u_uplink (
        .clk(clk), .rst(rst),
        .photon_valid(photon_valid), .photon_ready(photon_ready),
        .photon_data(photon_data), .photon_last(photon_last),
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
        .rx_data(rx_data),
        .rx_be(rx_be),
        .rx_valid(rx_valid),
        .rx_ready(1'b1),
        .dbg_state(dbg_state)
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

    task automatic send_photon;
        begin
            send_word(32'hA55A_F00D, 1'b0);
            send_word({8'h01, 8'h00, 16'd7}, 1'b0);
            send_word({16'd9, 16'd78}, 1'b0);
            send_word(32'd625, 1'b0);
            send_word(32'h0000_0649, 1'b1);
        end
    endtask

    always @(negedge clk) begin
        if (!rst)
            ft_txe_n <= (($time / 10) % 11 == 5) ? 1'b1 : 1'b0;
    end

    always @(posedge clk) begin
        if (rst)
            ft_txe_n_q <= 1'b0;
        else
            ft_txe_n_q <= ft_txe_n;
    end

    always @(posedge clk) begin
        if (!rst && !ft_wr_n) begin
            if (ft_data === 32'hzzzz_zzzz || ft_be === 4'hz) begin
                $display("TEST FAILED: FT601 bus is tri-stated during WR_N low");
                error_count = error_count + 1;
            end
            if (ft_be !== 4'hF) begin
                $display("TEST FAILED: FT601 BE=%h", ft_be);
                error_count = error_count + 1;
            end
            if (ft_txe_n_q !== 1'b0) begin
                $display("TEST FAILED: WR_N low while TXE_N is high");
                error_count = error_count + 1;
            end
            if (ft_rd_n !== 1'b1 || ft_oe_n !== 1'b1) begin
                $display("TEST FAILED: read controls active during TX rd=%b oe=%b", ft_rd_n, ft_oe_n);
                error_count = error_count + 1;
            end
            cap_data[cap_count] = ft_data;
            cap_count = cap_count + 1;
        end
    end

    task automatic check_ft_words;
        begin
            if (cap_count != 9) begin
                $display("TEST FAILED: expected 9 FT601 writes, got %0d", cap_count);
                error_count = error_count + 1;
            end
            if (cap_data[0] != 32'hA5_04_01_04 ||
                cap_data[1][15:0] != 16'd5 ||
                cap_data[2][31:16] != 16'd1) begin
                $display("TEST FAILED: bad FT601 packet header %08x %08x %08x",
                         cap_data[0], cap_data[1], cap_data[2]);
                error_count = error_count + 1;
            end
            if (cap_data[4] != 32'hA55A_F00D ||
                cap_data[5] != {8'h01, 8'h00, 16'd7} ||
                cap_data[6] != {16'd9, 16'd78} ||
                cap_data[7] != 32'd625 ||
                cap_data[8] != 32'h0000_0649) begin
                $display("TEST FAILED: bad FT601 payload %08x %08x %08x %08x %08x",
                         cap_data[4], cap_data[5], cap_data[6], cap_data[7], cap_data[8]);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        send_photon();

        repeat (400) @(posedge clk);
        check_ft_words();

        if (error_count == 0) begin
            $display("TEST PASSED");
            $fdisplay($fopen("tb_uplink_ft601_tx.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_uplink_ft601_tx.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
