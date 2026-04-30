`timescale 1ns/1ps

module tb_ft601_cmd_dispatcher;
    localparam integer DATA_WIDTH = 32;
    localparam integer BE_WIDTH   = 4;
    localparam integer MAX_WORDS  = 256;

    reg ft_clk  = 1'b0;
    reg sys_clk = 1'b0;
    reg rst     = 1'b1;

    always #5 ft_clk  = ~ft_clk;   // 100 MHz FT601 CLK
    always #4 sys_clk = ~sys_clk;

    wire [DATA_WIDTH-1:0] ft_data;
    wire [BE_WIDTH-1:0]   ft_be;
    reg                   ft_txe_n;
    wire                  ft_rxf_n;
    wire                  ft_wr_n;
    wire                  ft_rd_n;
    wire                  ft_oe_n;
    wire                  ft_siwu_n;

    wire [DATA_WIDTH-1:0] rx_data;
    wire [BE_WIDTH-1:0]   rx_be;
    wire                  rx_valid;
    wire                  rx_ready;
    wire [2:0]            ft_dbg_state;

    reg [DATA_WIDTH-1:0] host_words [0:MAX_WORDS-1];
    reg [BE_WIDTH-1:0]   host_bes   [0:MAX_WORDS-1];
    reg [DATA_WIDTH-1:0] expected_words [0:MAX_WORDS-1];
    integer host_wr_idx;
    integer host_rd_idx;
    integer expected_total;
    integer observed_total;
    integer physical_reads;
    integer error_count;
    integer result_fd;
    integer ad5686_start_count;

    wire host_has_data = (host_rd_idx < host_wr_idx);
    assign ft_rxf_n = host_has_data ? 1'b0 : 1'b1;
    assign ft_data  = (!ft_oe_n && host_has_data) ? host_words[host_rd_idx] : {DATA_WIDTH{1'bz}};
    assign ft_be    = (!ft_oe_n && host_has_data) ? host_bes[host_rd_idx]   : {BE_WIDTH{1'bz}};

    reg [DATA_WIDTH-1:0] tx_data;
    reg [BE_WIDTH-1:0]   tx_be;
    reg                  tx_valid;
    wire                 tx_ready;

    ft601_fifo_if #(
        .DATA_WIDTH(DATA_WIDTH),
        .BE_WIDTH(BE_WIDTH)
    ) u_ft601_fifo_if (
        .ft_clk(ft_clk),
        .sys_clk(sys_clk),
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
        .rx_ready(rx_ready),
        .dbg_state(ft_dbg_state)
    );

    reg         ad5686_ready;
    reg         nb6l295_ready;
    reg         tec_temp_ready;
    reg         gpx2_cfg_ready;
    reg         gate_cfg_ready;
    reg         gate_pixel_ready;
    reg         gate_ram_ready;
    reg         flash_ready;
    reg         ack_ready;

    wire        ad5686_start;
    wire [15:0] ad5686_data1;
    wire [15:0] ad5686_data2;
    wire [15:0] ad5686_data3;
    wire [15:0] ad5686_data4;
    wire [23:0] gate_hold_off_time;
    wire        nb6l295_start;
    wire [8:0]  nb6l295_delay_a;
    wire [8:0]  nb6l295_delay_b;
    wire        nb6l295_enable;
    wire [15:0] tec_temp_set;
    wire        tec_temp_set_valid;
    wire        gpx2_start_cfg;
    wire [11:0] gate_div_ratio;
    wire        gate_sig2_enable;
    wire        gate_sig3_enable;
    wire [3:0]  gate_sig2_delay_coarse;
    wire [4:0]  gate_sig2_delay_fine;
    wire [2:0]  gate_sig2_width_coarse;
    wire [4:0]  gate_sig2_width_fine;
    wire [3:0]  gate_sig3_delay_coarse;
    wire [4:0]  gate_sig3_delay_fine;
    wire [2:0]  gate_sig3_width_coarse;
    wire [4:0]  gate_sig3_width_fine;
    wire        gate_pixel_mode;
    wire        gate_cfg_valid;
    wire        gate_pixel_reset;
    wire        gate_ram_wr_en;
    wire [13:0] gate_ram_wr_addr;
    wire [35:0] gate_ram_wr_data;
    wire        flash_save_req;
    wire        flash_load_req;
    wire        ack_valid;
    wire [7:0]  ack_cmd_id;
    wire [7:0]  ack_status;
    wire [31:0] ack_data;
    wire [1:0]  cmd_dbg_state;
    wire [7:0]  cmd_dbg_cmd_id;
    wire [3:0]  cmd_dbg_payload_len;
    wire [3:0]  cmd_dbg_payload_idx;

    cmd_dispatcher u_cmd_dispatcher (
        .clk(ft_clk),
        .rst(rst),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .ad5686_ready(ad5686_ready),
        .nb6l295_ready(nb6l295_ready),
        .tec_temp_ready(tec_temp_ready),
        .gpx2_cfg_ready(gpx2_cfg_ready),
        .gate_cfg_ready(gate_cfg_ready),
        .gate_pixel_ready(gate_pixel_ready),
        .gate_ram_ready(gate_ram_ready),
        .flash_ready(flash_ready),
        .ack_ready(ack_ready),
        .ad5686_start(ad5686_start),
        .ad5686_data1(ad5686_data1),
        .ad5686_data2(ad5686_data2),
        .ad5686_data3(ad5686_data3),
        .ad5686_data4(ad5686_data4),
        .gate_hold_off_time(gate_hold_off_time),
        .nb6l295_start(nb6l295_start),
        .nb6l295_delay_a(nb6l295_delay_a),
        .nb6l295_delay_b(nb6l295_delay_b),
        .nb6l295_enable(nb6l295_enable),
        .tec_temp_set(tec_temp_set),
        .tec_temp_set_valid(tec_temp_set_valid),
        .gpx2_start_cfg(gpx2_start_cfg),
        .gate_div_ratio(gate_div_ratio),
        .gate_sig2_enable(gate_sig2_enable),
        .gate_sig3_enable(gate_sig3_enable),
        .gate_sig2_delay_coarse(gate_sig2_delay_coarse),
        .gate_sig2_delay_fine(gate_sig2_delay_fine),
        .gate_sig2_width_coarse(gate_sig2_width_coarse),
        .gate_sig2_width_fine(gate_sig2_width_fine),
        .gate_sig3_delay_coarse(gate_sig3_delay_coarse),
        .gate_sig3_delay_fine(gate_sig3_delay_fine),
        .gate_sig3_width_coarse(gate_sig3_width_coarse),
        .gate_sig3_width_fine(gate_sig3_width_fine),
        .gate_pixel_mode(gate_pixel_mode),
        .gate_cfg_valid(gate_cfg_valid),
        .gate_pixel_reset(gate_pixel_reset),
        .gate_ram_wr_en(gate_ram_wr_en),
        .gate_ram_wr_addr(gate_ram_wr_addr),
        .gate_ram_wr_data(gate_ram_wr_data),
        .flash_save_req(flash_save_req),
        .flash_load_req(flash_load_req),
        .ack_valid(ack_valid),
        .ack_cmd_id(ack_cmd_id),
        .ack_status(ack_status),
        .ack_data(ack_data),
        .dbg_state(cmd_dbg_state),
        .dbg_cmd_id(cmd_dbg_cmd_id),
        .dbg_payload_len(cmd_dbg_payload_len),
        .dbg_payload_idx(cmd_dbg_payload_idx)
    );

    task automatic fail;
        input [1023:0] msg;
        begin
            error_count = error_count + 1;
            $display("[%0t] ERROR: %0s", $time, msg);
        end
    endtask

    task automatic check32;
        input [1023:0] name;
        input [31:0]   got;
        input [31:0]   exp;
        begin
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: %0s got 0x%08h expected 0x%08h", $time, name, got, exp);
            end
        end
    endtask

    task automatic check16;
        input [1023:0] name;
        input [15:0]   got;
        input [15:0]   exp;
        begin
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: %0s got 0x%04h expected 0x%04h", $time, name, got, exp);
            end
        end
    endtask

    task automatic check1;
        input [1023:0] name;
        input          got;
        input          exp;
        begin
            if (got !== exp) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: %0s got %0b expected %0b", $time, name, got, exp);
            end
        end
    endtask

    task automatic push_ft_word;
        input [31:0] word;
        begin
            if (host_wr_idx >= MAX_WORDS || expected_total >= MAX_WORDS) begin
                fail("testbench queue overflow");
            end else begin
                host_words[host_wr_idx] = word;
                host_bes[host_wr_idx]   = 4'hf;
                host_wr_idx             = host_wr_idx + 1;
                expected_words[expected_total] = word;
                expected_total          = expected_total + 1;
                $display("[%0t] HOST->FPGA enqueue word[%0d] = 0x%08h", $time, expected_total - 1, word);
            end
        end
    endtask

    task automatic push_header;
        input [7:0] cmd_id;
        input [3:0] payload_len;
        begin
            push_ft_word({8'hbb, cmd_id, 12'h000, payload_len});
        end
    endtask

    task automatic wait_cycles;
        input integer cycles;
        integer i;
        begin
            for (i = 0; i < cycles; i = i + 1) begin
                @(posedge ft_clk);
            end
        end
    endtask

    task automatic wait_for_ad5686;
        input [15:0] e1;
        input [15:0] e2;
        input [15:0] e3;
        input [15:0] e4;
        integer timeout;
        begin
            timeout = 0;
            while (ad5686_start !== 1'b1 && timeout < 500) begin
                @(negedge ft_clk);
                timeout = timeout + 1;
            end
            if (ad5686_start !== 1'b1) begin
                fail("timeout waiting for ad5686_start");
            end else begin
                check16("ad5686_data1", ad5686_data1, e1);
                check16("ad5686_data2", ad5686_data2, e2);
                check16("ad5686_data3", ad5686_data3, e3);
                check16("ad5686_data4", ad5686_data4, e4);
                $display("[%0t] PASS: AD5686 command decoded", $time);
            end
        end
    endtask

    task automatic wait_for_gate_div;
        input [11:0] exp_ratio;
        integer timeout;
        begin
            timeout = 0;
            while (!gate_cfg_valid && timeout < 500) begin
                @(negedge ft_clk);
                timeout = timeout + 1;
            end
            if (!gate_cfg_valid) begin
                fail("timeout waiting for gate_cfg_valid");
            end else begin
                if (gate_div_ratio !== exp_ratio) begin
                    error_count = error_count + 1;
                    $display("[%0t] ERROR: gate_div_ratio got 0x%03h expected 0x%03h", $time, gate_div_ratio, exp_ratio);
                end else begin
                    $display("[%0t] PASS: GATE_DIV command decoded", $time);
                end
            end
        end
    endtask

    task automatic wait_for_tec;
        input [15:0] exp_temp;
        integer timeout;
        begin
            timeout = 0;
            while (!tec_temp_set_valid && timeout < 500) begin
                @(negedge ft_clk);
                timeout = timeout + 1;
            end
            if (!tec_temp_set_valid) begin
                fail("timeout waiting for tec_temp_set_valid");
            end else begin
                check16("tec_temp_set", tec_temp_set, exp_temp);
                $display("[%0t] PASS: TEC command decoded", $time);
            end
        end
    endtask

    task automatic wait_for_gate_sig2;
        input [3:0] exp_delay_coarse;
        input [4:0] exp_delay_fine;
        input [2:0] exp_width_coarse;
        input [4:0] exp_width_fine;
        integer timeout;
        begin
            while (gate_cfg_valid) begin
                @(negedge ft_clk);
            end
            timeout = 0;
            while (!gate_cfg_valid && timeout < 500) begin
                @(negedge ft_clk);
                timeout = timeout + 1;
            end
            if (!gate_cfg_valid) begin
                fail("timeout waiting for gate_sig2 gate_cfg_valid");
            end else begin
                if (gate_sig2_delay_coarse !== exp_delay_coarse ||
                    gate_sig2_delay_fine   !== exp_delay_fine   ||
                    gate_sig2_width_coarse !== exp_width_coarse ||
                    gate_sig2_width_fine   !== exp_width_fine) begin
                    error_count = error_count + 1;
                    $display("[%0t] ERROR: GATE_SIG2 fields dc=%0d df=%0d wc=%0d wf=%0d",
                             $time, gate_sig2_delay_coarse, gate_sig2_delay_fine,
                             gate_sig2_width_coarse, gate_sig2_width_fine);
                end else begin
                    $display("[%0t] PASS: GATE_SIG2 command decoded", $time);
                end
            end
        end
    endtask

    task automatic wait_until_observed_all;
        integer timeout;
        begin
            timeout = 0;
            while (observed_total < expected_total && timeout < 1000) begin
                @(negedge ft_clk);
                timeout = timeout + 1;
            end
            if (observed_total != expected_total) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: observed %0d accepted words, expected %0d",
                         $time, observed_total, expected_total);
            end
        end
    endtask

    task automatic wait_no_ad5686_start_delta;
        input integer cycles;
        input integer start_count_before;
        begin
            wait_cycles(cycles);
            if (ad5686_start_count != start_count_before) begin
                error_count = error_count + 1;
                $display("[%0t] ERROR: ad5686_start asserted while only repeated headers were received", $time);
            end else begin
                $display("[%0t] PASS: repeated headers did not dispatch as AD5686 payload", $time);
            end
        end
    endtask

    always @(posedge ft_clk) begin
        if (!rst && !ft_oe_n && !ft_rd_n && host_has_data) begin
            $display("[%0t] FT601 model read word[%0d] = 0x%08h", $time, host_rd_idx, host_words[host_rd_idx]);
            physical_reads = physical_reads + 1;
            #1 host_rd_idx = host_rd_idx + 1;
        end
    end

    always @(negedge ft_clk) begin
        if (!rst && rx_valid && rx_ready) begin
            if (observed_total >= expected_total) begin
                fail("DUT produced more rx handshakes than queued host words");
            end else begin
                check32("rx_data sequence", rx_data, expected_words[observed_total]);
                $display("[%0t] RX accepted word[%0d] = 0x%08h", $time, observed_total, rx_data);
                observed_total = observed_total + 1;
            end
        end
    end

    always @(posedge ft_clk) begin
        if (rst) begin
            ad5686_start_count <= 0;
        end else if (ad5686_start) begin
            ad5686_start_count <= ad5686_start_count + 1;
        end
    end

    initial begin
        $timeformat(-9, 1, " ns", 12);
        ft_txe_n         = 1'b1;
        tx_data          = 32'd0;
        tx_be            = 4'hf;
        tx_valid         = 1'b0;
        ad5686_ready     = 1'b1;
        nb6l295_ready    = 1'b1;
        tec_temp_ready   = 1'b1;
        gpx2_cfg_ready   = 1'b1;
        gate_cfg_ready   = 1'b1;
        gate_pixel_ready = 1'b1;
        gate_ram_ready   = 1'b1;
        flash_ready      = 1'b1;
        ack_ready        = 1'b1;
        host_wr_idx      = 0;
        host_rd_idx      = 0;
        expected_total   = 0;
        observed_total   = 0;
        physical_reads   = 0;
        error_count      = 0;
        ad5686_start_count = 0;

        wait_cycles(8);
        rst = 1'b0;
        wait_cycles(4);

        $display("[%0t] TEST 0: repeated headers must not be used as AD5686 payload", $time);
        push_header(8'h01, 4'd2);
        push_header(8'h01, 4'd2);
        push_header(8'h01, 4'd2);
        wait_until_observed_all();
        wait_no_ad5686_start_delta(20, 0);
        wait_cycles(8);

        $display("[%0t] TEST 1: single AD5686 command, all words are unique", $time);
        push_header(8'h01, 4'd2);
        push_ft_word(32'h1111_2222);
        push_ft_word(32'h3333_4444);
        wait_for_ad5686(16'h1111, 16'h2222, 16'h3333, 16'h4444);
        wait_until_observed_all();
        wait_cycles(8);

        $display("[%0t] TEST 2: back-to-back commands exercise ft601_fifo_if buffering", $time);
        push_header(8'h20, 4'd1);
        push_ft_word(32'h0000_0abc);
        push_header(8'h21, 4'd1);
        push_ft_word({15'd0, 5'd19, 3'd5, 5'd7, 4'd3});
        wait_for_gate_div(12'habc);
        wait_for_gate_sig2(4'd3, 5'd7, 3'd5, 5'd19);
        wait_until_observed_all();
        wait_cycles(8);

        $display("[%0t] TEST 3: dispatcher stalls while FT601 keeps draining into local FIFO", $time);
        ad5686_ready = 1'b0;
        push_header(8'h01, 4'd2);
        push_ft_word(32'ha1a2_a3a4);
        push_ft_word(32'ha5a6_a7a8);
        push_header(8'h04, 4'd1);
        push_ft_word(32'h0000_1357);
        wait_cycles(40);
        check1("ad5686_start while ad5686_ready is low", ad5686_start, 1'b0);
        ad5686_ready = 1'b1;
        wait_for_ad5686(16'ha1a2, 16'ha3a4, 16'ha5a6, 16'ha7a8);
        wait_for_tec(16'h1357);
        wait_until_observed_all();
        wait_cycles(20);

        if (host_rd_idx != host_wr_idx) begin
            error_count = error_count + 1;
            $display("[%0t] ERROR: FT601 model still has unread physical words rd=%0d wr=%0d",
                     $time, host_rd_idx, host_wr_idx);
        end

        if (physical_reads != host_wr_idx) begin
            error_count = error_count + 1;
            $display("[%0t] ERROR: physical read count %0d expected %0d", $time, physical_reads, host_wr_idx);
        end

        if (error_count == 0) begin
            $display("[%0t] TEST PASSED: FT601 RX words advanced correctly and commands decoded", $time);
            result_fd = $fopen("tb_ft601_cmd_dispatcher.result", "w");
            $fdisplay(result_fd, "TEST PASSED");
            $fclose(result_fd);
        end else begin
            $display("[%0t] TEST FAILED: %0d error(s)", $time, error_count);
            result_fd = $fopen("tb_ft601_cmd_dispatcher.result", "w");
            $fdisplay(result_fd, "TEST FAILED: %0d error(s)", error_count);
            $fclose(result_fd);
            $fatal(1);
        end
        $finish;
    end
endmodule

module ila_ft601 (
    input        clk,
    input [2:0]  probe0,
    input [31:0] probe1,
    input [3:0]  probe2,
    input        probe3,
    input        probe4,
    input        probe5,
    input        probe6,
    input        probe7,
    input [31:0] probe8,
    input [3:0]  probe9,
    input        probe10,
    input        probe11,
    input [31:0] probe12,
    input [3:0]  probe13,
    input        probe14,
    input        probe15
);
endmodule
