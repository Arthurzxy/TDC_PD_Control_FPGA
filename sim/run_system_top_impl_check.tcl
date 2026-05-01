set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ".."]]
set project_file [file normalize [file join $root_dir ".." ".." "TDC_PC_Ver2.0.xpr"]]
set report_dir [file join $root_dir "reports" "system_top_impl"]

file mkdir $report_dir
open_project $project_file

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synth_1 did not complete: $synth_status"
}
if {[string match "*failed*" [string tolower $synth_status]]} {
    error "synth_1 failed: $synth_status"
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "impl_1 did not complete: $impl_status"
}

open_run impl_1
report_timing_summary -file [file join $report_dir "system_top_timing_summary.rpt"] -max_paths 20 -report_unconstrained
report_clock_interaction -file [file join $report_dir "system_top_clock_interaction.rpt"]
report_route_status -file [file join $report_dir "system_top_route_status.rpt"]
report_drc -file [file join $report_dir "system_top_drc.rpt"]
report_utilization -file [file join $report_dir "system_top_utilization.rpt"]
report_methodology -file [file join $report_dir "system_top_methodology.rpt"]

set setup_paths [get_timing_paths -quiet -max_paths 1 -setup]
set hold_paths  [get_timing_paths -quiet -max_paths 1 -hold]
set wns "NA"
set whs "NA"
if {[llength $setup_paths] > 0} {
    set wns [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
}

puts "SYSTEM_TOP_IMPL_STATUS: $impl_status"
puts "SYSTEM_TOP_IMPL_WNS: $wns"
puts "SYSTEM_TOP_IMPL_WHS: $whs"
puts "SYSTEM_TOP_IMPL_REPORTS: $report_dir"

if {[string match "*failed*" [string tolower $impl_status]]} {
    error "impl_1 failed: $impl_status"
}

puts "TEST PASSED: system_top implementation completed with current XDC."
