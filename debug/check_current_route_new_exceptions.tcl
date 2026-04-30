# Apply only the new timing exceptions on the current routed design and
# regenerate a timing summary. This does not reroute or resynthesize; it is a
# quick check for whether the debug/reset exceptions address the reported WNS.
#
# Usage:
#   vivado -mode batch -source debug/check_current_route_new_exceptions.tcl <project.xpr>

if {[llength $argv] >= 1} {
    open_project [lindex $argv 0]
} elseif {[catch {current_project}]} {
    error "Usage: vivado -mode batch -source debug/check_current_route_new_exceptions.tcl <project.xpr>"
}
open_run impl_1

set_false_path \
    -from [get_cells -quiet -hier {*dbg_ft_rx_data_hold_ft_reg[*] *dbg_ft_ctrl_hold_ft_reg[*] *dbg_ad5686_data1_hold_ft_reg[*] *dbg_ad5686_data2_hold_ft_reg[*]}] \
    -to   [get_pins  -quiet -hier {*dbg_ft_rx_data_sys_reg[*]/D *dbg_ft_ctrl_sys_reg[*]/D *dbg_ad5686_data1_sys_reg[*]/D *dbg_ad5686_data2_sys_reg[*]/D}]

set_false_path -to [get_pins -quiet -hier *ack_sync1_reg/D]
set_false_path -to [get_pins -quiet -hier *req_sync1_reg/D]
set_false_path -to [get_pins -quiet -hier {*data_sync1_reg[*]/D}]
set_false_path -to [get_pins -quiet -hier {*sync_ff1_reg[*]/D}]
set_false_path -to [get_pins -quiet -hier {*rst_lclk_ff_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*gate_rst_sync_ff_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*cfg_done_lclk_ff_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*ft_hb_sync_sys_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*ft_hb_sync_20m_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*dbg_ft_rx_toggle_sync_sys_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*dbg_ad5686_toggle_sync_sys_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier {*sys_locked_sync_20m_reg[0]/D}]
set_false_path -to [get_pins -quiet -hier *pixel1_sync1_reg/D]
set_false_path -to [get_pins -quiet -hier *pixel2_sync1_reg/D]
set_false_path -to [get_pins -quiet -hier *ava_sync1_reg/D]

set_false_path \
    -from [get_cells -quiet -hier {rst_sync_ff_reg[2] ft_rst_sync_ff_reg[2] clk20_rst_sync_ff_reg[2] *gate_rst_sync_ff_reg[2]}]

set out_dir [file normalize [file join [file dirname [info script]] timing_check]]
file mkdir $out_dir

report_timing_summary \
    -max_paths 20 \
    -report_unconstrained \
    -warn_on_violation \
    -file [file join $out_dir current_route_with_new_exceptions.rpt]

puts "INFO: wrote [file join $out_dir current_route_with_new_exceptions.rpt]"
