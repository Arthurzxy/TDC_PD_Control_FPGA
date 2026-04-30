`timescale 1ns/1ps

module tb_gpx2_spi_config;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg miso = 1'b0;

    wire config_done;
    wire config_error;
    wire busy;
    wire ssn;
    wire sck;
    wire mosi;

    integer error_count = 0;
    integer txn_idx = -1;
    integer byte_idx = 0;
    integer bit_idx = 7;
    reg [7:0] rx_shift = 8'd0;
    reg [7:0] miso_shift = 8'd0;
    reg seen_done = 1'b0;

    always #5 clk = ~clk;

    gpx2_spi_config #(
        .SPI_DIV(2),
        .SYS_CLK_HZ(1_000_000),
        .POST_INIT_WAIT_US(2)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .config_done(config_done),
        .config_error(config_error),
        .busy(busy),
        .ssn(ssn),
        .sck(sck),
        .mosi(mosi),
        .miso(miso)
    );

    function automatic [7:0] cfg_byte(input integer idx);
        begin
            case (idx)
                0:  cfg_byte = 8'h3F;
                1:  cfg_byte = 8'h4F;
                2:  cfg_byte = 8'h24;
                3:  cfg_byte = 8'hD4;
                4:  cfg_byte = 8'h30;
                5:  cfg_byte = 8'h00;
                6:  cfg_byte = 8'hC0;
                7:  cfg_byte = 8'h53;
                8:  cfg_byte = 8'hA1;
                9:  cfg_byte = 8'h13;
                10: cfg_byte = 8'h00;
                11: cfg_byte = 8'h0A;
                12: cfg_byte = 8'hCC;
                13: cfg_byte = 8'hCC;
                14: cfg_byte = 8'hF1;
                15: cfg_byte = 8'h7D;
                default: cfg_byte = 8'h00;
            endcase
        end
    endfunction

    task automatic check_byte(input integer txn, input integer bidx, input [7:0] observed);
        reg [7:0] expected;
        begin
            expected = 8'h00;
            if (txn == 0) begin
                expected = 8'h30;
            end else if (txn == 1) begin
                expected = (bidx == 0) ? 8'h80 : cfg_byte(bidx - 1);
            end else if (txn == 2) begin
                expected = (bidx == 0) ? 8'h40 : 8'h00;
            end else if (txn == 3) begin
                expected = 8'h18;
            end else begin
                $display("TEST FAILED: unexpected SPI transaction %0d byte %0d = %02x", txn, bidx, observed);
                error_count = error_count + 1;
            end

            if (observed !== expected) begin
                $display("TEST FAILED: SPI txn %0d byte %0d expected %02x got %02x",
                         txn, bidx, expected, observed);
                error_count = error_count + 1;
            end
        end
    endtask

    always @(negedge ssn) begin
        txn_idx = txn_idx + 1;
        byte_idx = 0;
        bit_idx = 7;
        rx_shift = 8'd0;
    end

    always @(*) begin
        if (!ssn && txn_idx == 2 && byte_idx >= 1 && byte_idx <= 17) begin
            miso_shift = cfg_byte(byte_idx - 1);
            miso = miso_shift[bit_idx];
        end else begin
            miso_shift = 8'd0;
            miso = 1'b0;
        end
    end

    always @(posedge sck) begin
        if (!ssn) begin
            rx_shift[bit_idx] = mosi;
            if (bit_idx == 0) begin
                check_byte(txn_idx, byte_idx, rx_shift);
                byte_idx = byte_idx + 1;
                bit_idx = 7;
                rx_shift = 8'd0;
            end else begin
                bit_idx = bit_idx - 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst)
            seen_done <= 1'b0;
        else if (config_done)
            seen_done <= 1'b1;
    end

    always @(posedge ssn) begin
        if (!rst && txn_idx >= 0) begin
            if ((txn_idx == 0 || txn_idx == 3) && byte_idx != 1) begin
                $display("TEST FAILED: transaction %0d expected 1 byte, got %0d", txn_idx, byte_idx);
                error_count = error_count + 1;
            end
            if ((txn_idx == 1 || txn_idx == 2) && byte_idx != 18) begin
                $display("TEST FAILED: transaction %0d expected 18 bytes, got %0d", txn_idx, byte_idx);
                error_count = error_count + 1;
            end
        end
    end

    initial begin
        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        repeat (3000) @(posedge clk);

        if (!seen_done || config_error || busy) begin
            $display("TEST FAILED: seen_done=%b error=%b busy=%b", seen_done, config_error, busy);
            error_count = error_count + 1;
        end
        if (txn_idx != 3) begin
            $display("TEST FAILED: expected 4 SPI transactions, got %0d", txn_idx + 1);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("TEST PASSED");
            $fdisplay($fopen("tb_gpx2_spi_config.result", "w"), "TEST PASSED");
        end else begin
            $display("TEST FAILED with %0d errors", error_count);
            $fdisplay($fopen("tb_gpx2_spi_config.result", "w"), "TEST FAILED");
        end
        $finish;
    end
endmodule
