`timescale 1ns/1ps

module tb_gpx2_lvds_rx_ddr;
    reg lclk = 1'b0;
    reg rst  = 1'b1;
    reg sdo_in = 1'b0;
    reg frame_in = 1'b0;

    wire event_valid;
    wire [29:0] event_data;

    integer error_count = 0;

    always #2 lclk = ~lclk;

    gpx2_lvds_rx #(
        .REFID_BITS(16),
        .TSTOP_BITS(14),
        .USE_DDR(1),
        .EVENT_BITS(30)
    ) dut (
        .lclk_io(lclk),
        .lclk_logic(lclk),
        .rst_lclk(rst),
        .sdo_in(sdo_in),
        .frame_in(frame_in),
        .event_valid(event_valid),
        .event_data(event_data)
    );

    task automatic drive_ddr_event(input [29:0] ev);
        integer bit_idx;
        integer edge_idx;
        begin
            bit_idx = 29;
            for (edge_idx = 0; edge_idx < 15; edge_idx = edge_idx + 1) begin
                @(negedge lclk);
                #0.5;
                sdo_in = ev[bit_idx];
                frame_in = (edge_idx < 4);
                @(posedge lclk);
                #0.5;
                sdo_in = ev[bit_idx-1];
                frame_in = (edge_idx < 4);
                bit_idx = bit_idx - 2;
            end
            @(negedge lclk);
            #0.5;
            frame_in = 1'b0;
            sdo_in = 1'b0;
        end
    endtask

    task automatic expect_event(input [29:0] expected);
        integer timeout;
        begin
            timeout = 0;
            while (!event_valid && timeout < 80) begin
                @(posedge lclk);
                timeout = timeout + 1;
            end
            if (!event_valid) begin
                $display("TEST FAILED: timeout waiting for event %08x", expected);
                error_count = error_count + 1;
            end else if (event_data !== expected) begin
                $display("TEST FAILED: expected %08x got %08x", expected, event_data);
                error_count = error_count + 1;
            end else begin
                $display("RX event OK: %08x", event_data);
            end
            @(posedge lclk);
        end
    endtask

    initial begin
        repeat (8) @(posedge lclk);
        rst = 1'b0;
        repeat (24) @(posedge lclk);

        fork
            drive_ddr_event({16'h1234, 14'h02A5});
            expect_event({16'h1234, 14'h02A5});
        join

        repeat (8) @(posedge lclk);

        fork
            drive_ddr_event({16'hFEDC, 14'h1555});
            expect_event({16'hFEDC, 14'h1555});
        join

        repeat (20) @(posedge lclk);

        if (error_count == 0) begin
            $display("TEST PASSED");
            $fdisplay($fopen("tb_gpx2_lvds_rx_ddr.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_gpx2_lvds_rx_ddr.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
