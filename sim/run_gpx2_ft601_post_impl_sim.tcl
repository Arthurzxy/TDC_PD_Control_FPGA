set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ".."]]
set proj_dir [file join $script_dir "xsim_gpx2_ft601_post_impl"]

file delete -force $proj_dir
create_project gpx2_ft601_post_impl $proj_dir -part xc7k325tffg900-1

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse [list \
    [file join $root_dir "gpx2_lvds_rx.v"] \
    [file join $root_dir "timestamp_extend.v"] \
    [file join $root_dir "event_merger.v"] \
    [file join $root_dir "tcspc_event_processor.v"] \
    [file join $root_dir "photon_event_streamer.v"] \
    [file join $root_dir "uplink_packet_builder.v"] \
    [file join $root_dir "ft601_fifo_if.v"] \
    [file join $script_dir "ila_ft601_stub.v"] \
    [file join $script_dir "gpx2_ft601_chain_dut.sv"] \
]
set_property top gpx2_ft601_chain_dut [current_fileset]

add_files -fileset sim_1 -norecurse [file join $script_dir "tb_gpx2_ft601_chain_post.sv"]
set_property top tb_gpx2_ft601_chain_post [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {20us} -objects [get_filesets sim_1]
set_property verilog_define {GPX2_CHAIN_CLK_HALF_NS=5.0} [get_filesets sim_1]

set xdc_file [file join $proj_dir "gpx2_ft601_chain_post_impl.xdc"]
set fh [open $xdc_file w]
puts $fh {create_clock -period 10.000 -name gpx2_chain_clk [get_ports clk]}
close $fh
add_files -fileset constrs_1 -norecurse $xdc_file

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synth_1 did not complete"
}
if {[string match "*failed*" [string tolower [get_property STATUS [get_runs synth_1]]]]} {
    error "synth_1 failed: [get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "impl_1 did not complete"
}
if {[string match "*failed*" [string tolower [get_property STATUS [get_runs impl_1]]]]} {
    error "impl_1 failed: [get_property STATUS [get_runs impl_1]]"
}

set report_dir [file join $proj_dir "reports"]
file mkdir $report_dir
open_run impl_1
report_timing_summary -file [file join $report_dir "post_impl_timing_summary.rpt"]
report_route_status -file [file join $report_dir "post_impl_route_status.rpt"]
report_drc -file [file join $report_dir "post_impl_drc.rpt"]
report_utilization -file [file join $report_dir "post_impl_utilization.rpt"]

launch_simulation -simset sim_1 -mode post-implementation -type functional
run all
close_sim

set result_candidates [glob -nocomplain \
    [file join $proj_dir "*.sim" "sim_1" "impl" "func" "xsim" "tb_gpx2_ft601_chain_post.result"] \
    [file join $proj_dir "gpx2_ft601_post_impl.sim" "sim_1" "impl" "func" "xsim" "tb_gpx2_ft601_chain_post.result"] \
]
if {[llength $result_candidates] == 0} {
    error "Simulation result file was not generated"
}
set result_file [lindex $result_candidates 0]
set fh [open $result_file r]
set result_text [read $fh]
close $fh
if {![string match "*TEST PASSED*" $result_text]} {
    error "Post-implementation functional simulation failed: $result_text"
}

puts "TEST PASSED: GPX2 to FT601 post-implementation functional simulation."
puts "Reports: $report_dir"
