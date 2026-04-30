#============================================================
# gate_gen_top_eval.xdc
# Standalone evaluation constraints for gate_gen_top_eval_top
# 1 ns internal-OR architecture
#============================================================

#============================================================
# System clock
#============================================================
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]
set_property PACKAGE_PIN AD23 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]

#============================================================
# Reset
#============================================================
set_property PACKAGE_PIN A25 [get_ports sys_rst]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst]

#============================================================
# Differential reference input
#============================================================
create_clock -period 10.000 -name ref_in_clk [get_ports ref_in_p]
set_property PACKAGE_PIN AE5 [get_ports ref_in_p]
set_property PACKAGE_PIN AF5 [get_ports ref_in_n]
set_property IOSTANDARD LVDS [get_ports {ref_in_p ref_in_n}]
set_property DIFF_TERM TRUE [get_ports {ref_in_p ref_in_n}]

# sys_clk is a host/control domain. The gate-generation path is locked to ref_in
# and its MMCM-generated derivatives.
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks ref_in_clk]

#============================================================
# Differential pixel1 input
#============================================================
set_property PACKAGE_PIN AH2 [get_ports pixel1_in_p]
set_property PACKAGE_PIN AJ2 [get_ports pixel1_in_n]
set_property IOSTANDARD LVDS [get_ports {pixel1_in_p pixel1_in_n}]
set_property DIFF_TERM TRUE [get_ports {pixel1_in_p pixel1_in_n}]

#============================================================
# Differential pixel2 input
#============================================================
set_property PACKAGE_PIN AJ1 [get_ports pixel2_in_p]
set_property PACKAGE_PIN AK1 [get_ports pixel2_in_n]
set_property IOSTANDARD LVDS [get_ports {pixel2_in_p pixel2_in_n}]
set_property DIFF_TERM TRUE [get_ports {pixel2_in_p pixel2_in_n}]

#============================================================
# Mirrored differential gate outputs in HP bank 34
#============================================================
set_property PACKAGE_PIN AG4 [get_ports gate_out_hp_p]
set_property PACKAGE_PIN AG3 [get_ports gate_out_hp_n]
set_property IOSTANDARD LVDS [get_ports {gate_out_hp_p gate_out_hp_n}]

set_property PACKAGE_PIN AC2 [get_ports gate_out_ext_p]
set_property PACKAGE_PIN AC1 [get_ports gate_out_ext_n]
set_property IOSTANDARD LVDS [get_ports {gate_out_ext_p gate_out_ext_n}]
