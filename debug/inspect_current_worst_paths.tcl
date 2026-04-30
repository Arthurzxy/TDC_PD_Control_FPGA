# Print object names for the current routed worst timing paths, including paths
# that report_timing_summary may display as <hidden>.
#
# Usage:
#   vivado -mode batch -source debug/inspect_current_worst_paths.tcl <project.xpr>

if {[llength $argv] >= 1} {
    open_project [lindex $argv 0]
} elseif {[catch {current_project}]} {
    error "Usage: vivado -mode batch -source debug/inspect_current_worst_paths.tcl <project.xpr>"
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
set_false_path -from [get_cells -quiet -hier {rst_sync_ff_reg[2] ft_rst_sync_ff_reg[2] clk20_rst_sync_ff_reg[2] *gate_rst_sync_ff_reg[2]}]

set out_dir [file normalize [file join [file dirname [info script]] timing_check]]
file mkdir $out_dir
set out_file [file join $out_dir current_worst_paths_objects.txt]
set fp [open $out_file w]

set paths [get_timing_paths -max_paths 20 -nworst 20 -setup]
set idx 0
foreach p $paths {
    incr idx
    puts $fp "PATH $idx"
    foreach prop {SLACK STARTPOINT_PIN ENDPOINT_PIN STARTPOINT_CELL ENDPOINT_CELL STARTPOINT_CLOCK ENDPOINT_CLOCK LOGIC_LEVELS} {
        catch {puts $fp "  $prop = [get_property $prop $p]"}
    }
    puts $fp ""
}
close $fp
puts "INFO: wrote $out_file"
