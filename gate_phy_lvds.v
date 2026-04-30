//==============================================================================
// gate_phy_lvds.v
// 10:1 DDR LVDS output PHY using cascaded OSERDESE2 primitives.
// One 10-bit word represents one 10 ns reference cycle at 1 ns resolution.
//==============================================================================

`timescale 1ns/1ps

module gate_phy_lvds (
    input  wire       clk_ser,
    input  wire       clk_div,
    input  wire       rst,
    input  wire [9:0] par_word,
    output wire       gate_out_p,
    output wire       gate_out_n
);

`ifndef SYNTHESIS
    reg [9:0] active_word;
    reg [3:0] bit_index;
    reg       serial_out;

    assign gate_out_p = serial_out;
    assign gate_out_n = ~serial_out;

    always @(posedge clk_ser or negedge clk_ser or posedge rst) begin
        if (rst) begin
            active_word <= 10'b0;
            bit_index   <= 4'd0;
            serial_out <= 1'b0;
        end else begin
            if (bit_index == 4'd0) begin
                active_word <= par_word;
                serial_out  <= par_word[0];
            end else begin
                serial_out <= active_word[bit_index];
            end

            if (bit_index == 4'd9)
                bit_index <= 4'd0;
            else
                bit_index <= bit_index + 1'b1;
        end
    end
`else
    wire shift_slave_1;
    wire shift_slave_2;
    wire ser_oq;

    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("BUF"),
        .DATA_WIDTH    (10),
        .INIT_OQ       (1'b0),
        .INIT_TQ       (1'b0),
        .SERDES_MODE   ("SLAVE"),
        .SRVAL_OQ      (1'b0),
        .SRVAL_TQ      (1'b0),
        .TRISTATE_WIDTH(1)
    ) u_oserdes_slave (
        .OFB       (),
        .OQ        (),
        .SHIFTOUT1 (shift_slave_1),
        .SHIFTOUT2 (shift_slave_2),
        .TBYTEOUT  (),
        .TFB       (),
        .TQ        (),
        .CLK       (clk_ser),
        .CLKDIV    (clk_div),
        .D1        (1'b0),
        .D2        (1'b0),
        .D3        (par_word[8]),
        .D4        (par_word[9]),
        .D5        (1'b0),
        .D6        (1'b0),
        .D7        (1'b0),
        .D8        (1'b0),
        .OCE       (1'b1),
        .RST       (rst),
        .SHIFTIN1  (1'b0),
        .SHIFTIN2  (1'b0),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("BUF"),
        .DATA_WIDTH    (10),
        .INIT_OQ       (1'b0),
        .INIT_TQ       (1'b0),
        .SERDES_MODE   ("MASTER"),
        .SRVAL_OQ      (1'b0),
        .SRVAL_TQ      (1'b0),
        .TRISTATE_WIDTH(1)
    ) u_oserdes_master (
        .OFB       (),
        .OQ        (ser_oq),
        .SHIFTOUT1 (),
        .SHIFTOUT2 (),
        .TBYTEOUT  (),
        .TFB       (),
        .TQ        (),
        .CLK       (clk_ser),
        .CLKDIV    (clk_div),
        .D1        (par_word[0]),
        .D2        (par_word[1]),
        .D3        (par_word[2]),
        .D4        (par_word[3]),
        .D5        (par_word[4]),
        .D6        (par_word[5]),
        .D7        (par_word[6]),
        .D8        (par_word[7]),
        .OCE       (1'b1),
        .RST       (rst),
        .SHIFTIN1  (shift_slave_1),
        .SHIFTIN2  (shift_slave_2),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0)
    );

    OBUFDS #(
        .IOSTANDARD ("LVDS")
    ) u_obufds (
        .I  (ser_oq),
        .O  (gate_out_p),
        .OB (gate_out_n)
    );
`endif

endmodule
