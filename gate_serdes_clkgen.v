//==============================================================================
// gate_serdes_clkgen.v
// Generate a 100 MHz word clock and a 500 MHz serial clock from the
// differential reference input. The 500 MHz DDR PHY yields 1 ns output steps.
//==============================================================================

`timescale 1ns/1ps

module gate_serdes_clkgen (
    input  wire ref_clk_in,
    input  wire rst,
    output wire clk_div,
    output wire clk_ser,
    output wire locked
);

`ifndef SYNTHESIS
    assign clk_div = ref_clk_in;
    assign clk_ser = ref_clk_in;
    assign locked  = ~rst;
`else
    wire clkfb_mmcm;
    wire clkfb_bufg;
    wire clk_div_mmcm;
    wire clk_ser_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKFBOUT_MULT_F  (10.0),
        .CLKFBOUT_PHASE   (0.0),
        .CLKIN1_PERIOD    (10.0),
        .CLKOUT0_DIVIDE_F (2.0),
        .CLKOUT1_DIVIDE   (10),
        .CLKOUT2_DIVIDE   (1),
        .CLKOUT3_DIVIDE   (1),
        .CLKOUT4_DIVIDE   (1),
        .CLKOUT5_DIVIDE   (1),
        .CLKOUT6_DIVIDE   (1),
        .DIVCLK_DIVIDE    (1),
        .REF_JITTER1      (0.010),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKFBOUT  (clkfb_mmcm),
        .CLKFBOUTB (),
        .CLKOUT0   (clk_ser_mmcm),
        .CLKOUT0B  (),
        .CLKOUT1   (clk_div_mmcm),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .CLKFBIN   (clkfb_bufg),
        .CLKIN1    (ref_clk_in),
        .PWRDWN    (1'b0),
        .RST       (rst),
        .LOCKED    (locked)
    );

    BUFG u_clkfb_bufg (
        .I (clkfb_mmcm),
        .O (clkfb_bufg)
    );

    BUFG u_clkser_bufg (
        .I (clk_ser_mmcm),
        .O (clk_ser)
    );

    BUFG u_clkdiv_bufg (
        .I (clk_div_mmcm),
        .O (clk_div)
    );
`endif

endmodule
