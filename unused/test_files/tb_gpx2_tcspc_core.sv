`timescale 1ns/1ps

module tb_gpx2_tcspc_core;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg         ch0_valid = 1'b0;
    reg [127:0] ch0_data  = 128'd0;
    wire        ch0_ready;
    reg         ch1_valid = 1'b0;
    reg [127:0] ch1_data  = 128'd0;
    wire        ch1_ready;
    reg         ch2_valid = 1'b0;
    reg [127:0] ch2_data  = 128'd0;
    wire        ch2_ready;
    reg         ch3_valid = 1'b0;
    reg [127:0] ch3_data  = 128'd0;
    wire        ch3_ready;

    wire        merged_valid;
    wire        merged_ready;
    wire [127:0] merged_event;

    wire        photon_valid;
    wire        photon_ready;
    wire [127:0] photon_event;

    wire        out_valid;
    wire [31:0] out_data;
    reg         out_ready = 1'b1;
    wire        out_last;

    wire [31:0] laser_count;
    wire [31:0] detector_count;
    wire [31:0] photon_valid_count;
    wire [31:0] dt_overflow_count;
    wire [31:0] no_laser_count;
    wire [31:0] line_count;
    wire [31:0] pixel_count;

    integer accepted_words = 0;
    integer error_count = 0;
    integer cyc = 0;
    reg prev_valid = 1'b0;
    reg prev_ready = 1'b0;
    reg prev_last = 1'b0;
    reg [31:0] prev_data = 32'd0;

    event_merger u_merger (
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
        .out_valid(out_valid), .out_data(out_data), .out_ready(out_ready), .out_last(out_last)
    );

    function automatic [127:0] make_ext_event(input [1:0] ch, input [63:0] ts);
        begin
            make_ext_event = {ch, ts, 16'd0, 14'd0, 32'd0};
        end
    endfunction

    task automatic send_event(input [1:0] ch, input [63:0] ts);
        begin
            @(negedge clk);
            case (ch)
                2'd0: begin ch0_data = make_ext_event(ch, ts); ch0_valid = 1'b1; end
                2'd1: begin ch1_data = make_ext_event(ch, ts); ch1_valid = 1'b1; end
                2'd2: begin ch2_data = make_ext_event(ch, ts); ch2_valid = 1'b1; end
                default: begin ch3_data = make_ext_event(ch, ts); ch3_valid = 1'b1; end
            endcase
            do begin
                @(posedge clk);
            end while (!((ch == 2'd0 && ch0_ready) ||
                         (ch == 2'd1 && ch1_ready) ||
                         (ch == 2'd2 && ch2_ready) ||
                         (ch == 2'd3 && ch3_ready)));
            @(negedge clk);
            case (ch)
                2'd0: ch0_valid = 1'b0;
                2'd1: ch1_valid = 1'b0;
                2'd2: ch2_valid = 1'b0;
                default: ch3_valid = 1'b0;
            endcase
        end
    endtask

    task automatic expect_word(input integer idx, input [31:0] got);
        reg [31:0] exp;
        begin
            case (idx)
                0: exp = 32'hA55A_F00D;
                1: exp = 32'h0100_0001;
                2: exp = 32'h0001_004E;
                3: exp = 32'd625;
                4: exp = 32'd1625;
                5: exp = 32'hA55A_F00D;
                6: exp = 32'h0100_0001;
                7: exp = 32'h0001_00BB;
                8: exp = 32'd1500;
                9: exp = 32'd15000;
                10: exp = 32'hA55A_F00D;
                11: exp = 32'h0100_0002;
                12: exp = 32'h0002_01D4;
                13: exp = 32'd3750;
                14: exp = 32'd29750;
                default: exp = 32'hDEAD_BEEF;
            endcase
            if (got !== exp) begin
                $display("TEST FAILED: word %0d got %08x expected %08x", idx, got, exp);
                error_count = error_count + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst)
            cyc <= cyc + 1;
        out_ready <= !((cyc >= 25 && cyc <= 28) || (cyc >= 70 && cyc <= 72));

        if (prev_valid && !prev_ready) begin
            if (!out_valid || out_data !== prev_data || out_last !== prev_last) begin
                $display("TEST FAILED: stream changed while out_ready=0");
                error_count = error_count + 1;
            end
        end

        if (out_valid && out_ready) begin
            expect_word(accepted_words, out_data);
            if (((accepted_words % 5) == 4) && !out_last) begin
                $display("TEST FAILED: missing out_last on word %0d", accepted_words);
                error_count = error_count + 1;
            end
            if (((accepted_words % 5) != 4) && out_last) begin
                $display("TEST FAILED: unexpected out_last on word %0d", accepted_words);
                error_count = error_count + 1;
            end
            accepted_words = accepted_words + 1;
        end

        prev_valid <= out_valid;
        prev_ready <= out_ready;
        prev_data  <= out_data;
        prev_last  <= out_last;
    end

    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        send_event(2'd2, 64'd0);
        send_event(2'd3, 64'd1);
        send_event(2'd1, 64'd1000);
        send_event(2'd0, 64'd1625);

        send_event(2'd1, 64'd13500);
        send_event(2'd0, 64'd15000);

        send_event(2'd2, 64'd25000);
        send_event(2'd3, 64'd25001);
        send_event(2'd3, 64'd25002);
        send_event(2'd1, 64'd26000);
        send_event(2'd0, 64'd29750);

        repeat (120) @(posedge clk);

        if (accepted_words != 15) begin
            $display("TEST FAILED: accepted_words=%0d expected 15", accepted_words);
            error_count = error_count + 1;
        end
        if (laser_count != 3 || detector_count != 3 || photon_valid_count != 3) begin
            $display("TEST FAILED: counters laser=%0d detector=%0d photon=%0d",
                     laser_count, detector_count, photon_valid_count);
            error_count = error_count + 1;
        end
        if (dt_overflow_count != 0 || no_laser_count != 0) begin
            $display("TEST FAILED: drop counters overflow=%0d no_laser=%0d",
                     dt_overflow_count, no_laser_count);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("TEST PASSED");
            $fdisplay($fopen("tb_gpx2_tcspc_core.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_gpx2_tcspc_core.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
