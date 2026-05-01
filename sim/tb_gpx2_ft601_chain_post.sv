`timescale 1ns/1ps

module tb_gpx2_ft601_chain_post;
    localparam integer NUM_CH = 4;
`ifdef GPX2_CHAIN_CLK_HALF_NS
    localparam real CLK_HALF_NS = `GPX2_CHAIN_CLK_HALF_NS;
`else
    localparam real CLK_HALF_NS = 2.0;
`endif

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [NUM_CH-1:0] sdo = 4'd0;
    reg [NUM_CH-1:0] frame = 4'd0;

    wire [31:0] ft_data;
    wire [3:0] ft_be;
    reg ft_txe_n = 1'b0;
    reg ft_txe_n_q = 1'b0;
    reg ft_rxf_n = 1'b1;
    wire ft_wr_n;
    wire ft_rd_n;
    wire ft_oe_n;
    wire ft_siwu_n;
    wire [31:0] laser_count;
    wire [31:0] detector_count;
    wire [31:0] photon_valid_count;
    wire [31:0] line_count;
    wire [31:0] pixel_count;
    wire [31:0] dt_overflow_count;
    wire [31:0] no_laser_count;
    wire [2:0] ft_dbg_state;

    integer cap_count = 0;
    integer error_count = 0;
    reg [31:0] cap_data [0:255];

    always #(CLK_HALF_NS) clk = ~clk;

    gpx2_ft601_chain_dut dut (
        .clk(clk),
        .rst(rst),
        .gpx2_sdo(sdo),
        .gpx2_frame(frame),
        .ft_data(ft_data),
        .ft_be(ft_be),
        .ft_txe_n(ft_txe_n),
        .ft_rxf_n(ft_rxf_n),
        .ft_wr_n(ft_wr_n),
        .ft_rd_n(ft_rd_n),
        .ft_oe_n(ft_oe_n),
        .ft_siwu_n(ft_siwu_n),
        .laser_count(laser_count),
        .detector_count(detector_count),
        .photon_valid_count(photon_valid_count),
        .line_count(line_count),
        .pixel_count(pixel_count),
        .dt_overflow_count(dt_overflow_count),
        .no_laser_count(no_laser_count),
        .ft_dbg_state(ft_dbg_state)
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
                $display("TEST FAILED: FT601 WR_N low while sampled TXE_N high");
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

        repeat (1400) @(posedge clk);

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
            $fdisplay($fopen("tb_gpx2_ft601_chain_post.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_gpx2_ft601_chain_post.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
