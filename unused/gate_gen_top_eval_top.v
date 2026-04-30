`timescale 1ns/1ps

module gate_gen_top_eval_top (
    input  wire        sys_clk,
    input  wire        sys_rst,
    input  wire        ref_in_p,
    input  wire        ref_in_n,
    input  wire        pixel1_in_p,
    input  wire        pixel1_in_n,
    input  wire        pixel2_in_p,
    input  wire        pixel2_in_n,
    output wire        gate_out_hp_p,
    output wire        gate_out_hp_n,
    output wire        gate_out_ext_p,
    output wire        gate_out_ext_n
);

    wire ref_in_clk;
    wire pixel1_in_se;
    wire pixel2_in_se;
    wire clk_div;
    wire clk_ser;
    wire clk_locked;
    wire core_rst;
    wire [9:0] gate_word;
    wire [13:0] current_pixel;

    assign core_rst = sys_rst | ~clk_locked;

    IBUFGDS #(
        .DIFF_TERM    ("TRUE"),
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS")
    ) u_ibufgds_ref (
        .I  (ref_in_p),
        .IB (ref_in_n),
        .O  (ref_in_clk)
    );

    IBUFDS #(
        .DIFF_TERM    ("TRUE"),
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS")
    ) u_ibufds_pixel1 (
        .I  (pixel1_in_p),
        .IB (pixel1_in_n),
        .O  (pixel1_in_se)
    );

    IBUFDS #(
        .DIFF_TERM    ("TRUE"),
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS")
    ) u_ibufds_pixel2 (
        .I  (pixel2_in_p),
        .IB (pixel2_in_n),
        .O  (pixel2_in_se)
    );

    gate_serdes_clkgen u_gate_serdes_clkgen (
        .ref_clk_in (ref_in_clk),
        .rst        (sys_rst),
        .clk_div    (clk_div),
        .clk_ser    (clk_ser),
        .locked     (clk_locked)
    );

    gate_gen_top #(
        .PIXEL_ADDR_BITS (14),
        .PIXEL_X_BITS    (7),
        .DIV_BITS        (12)
    ) u_gate_gen (
        .sys_clk           (sys_clk),
        .sys_rst           (core_rst),
        .clk_div           (clk_div),
        .pixel1_in         (pixel1_in_se),
        .pixel2_in         (pixel2_in_se),
        .gate_word         (gate_word),
        .div_ratio         (12'd1),
        .sig2_enable       (1'b1),
        .sig3_enable       (1'b0),
        .sig2_delay_coarse (4'd0),
        .sig2_delay_fine   (5'd2),
        .sig2_width_coarse (3'd0),
        .sig2_width_fine   (5'd4),
        .sig3_delay_coarse (4'd0),
        .sig3_delay_fine   (5'd0),
        .sig3_width_coarse (3'd0),
        .sig3_width_fine   (5'd1),
        .pixel_mode        (1'b0),
        .pixel_reset       (1'b0),
        .ram_wr_en         (1'b0),
        .ram_wr_addr       (14'd0),
        .ram_wr_data       (36'd0),
        .current_pixel     (current_pixel)
    );

    gate_phy_lvds u_gate_phy_hp (
        .clk_ser    (clk_ser),
        .clk_div    (clk_div),
        .rst        (core_rst),
        .par_word   (gate_word),
        .gate_out_p (gate_out_hp_p),
        .gate_out_n (gate_out_hp_n)
    );

    gate_phy_lvds u_gate_phy_ext (
        .clk_ser    (clk_ser),
        .clk_div    (clk_div),
        .rst        (core_rst),
        .par_word   (gate_word),
        .gate_out_p (gate_out_ext_p),
        .gate_out_n (gate_out_ext_n)
    );

endmodule
