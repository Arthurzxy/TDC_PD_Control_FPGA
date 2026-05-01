# Vivado post-synthesis simulation for GPX2 DDR capture through FT601 TX.
# Usage:
#   $env:VIVADO_BIN -mode batch -source sim/run_gpx2_ft601_post_synth_sim.tcl

set script_dir [file normalize [file dirname [info script]]]
set src_dir    [file normalize [file join $script_dir ..]]
set work_dir   [file normalize [file join $script_dir xsim_gpx2_ft601_post_synth]]
set proj_name  gpx2_ft601_post_synth_sim
set part_name  xc7k325tffg900-1

file mkdir $work_dir
set ::env(TEMP) $work_dir
set ::env(TMP)  $work_dir
cd $work_dir

create_project $proj_name $work_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sources_1 [list \
    [file join $src_dir gpx2_lvds_rx.v] \
    [file join $src_dir timestamp_extend.v] \
    [file join $src_dir event_merger.v] \
    [file join $src_dir tcspc_event_processor.v] \
    [file join $src_dir photon_event_streamer.v] \
    [file join $src_dir uplink_packet_builder.v] \
    [file join $src_dir ft601_fifo_if.v] \
    [file join $script_dir ila_ft601_stub.v] \
    [file join $script_dir gpx2_ft601_chain_dut.sv] \
]
add_files -fileset sim_1 [list \
    [file join $script_dir tb_gpx2_ft601_chain_post.sv] \
]
set_property file_type SystemVerilog [get_files [file join $script_dir gpx2_ft601_chain_dut.sv]]
set_property file_type SystemVerilog [get_files [file join $script_dir tb_gpx2_ft601_chain_post.sv]]
set_property top gpx2_ft601_chain_dut [get_filesets sources_1]
set_property top tb_gpx2_ft601_chain_post [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synth_1 failed"
    puts [get_property STATUS [get_runs synth_1]]
    exit 1
}

open_run synth_1 -name synth_1
file mkdir [file join $work_dir reports]
report_utilization -file [file join $work_dir reports post_synth_utilization.rpt]
report_timing_summary -file [file join $work_dir reports post_synth_timing_summary.rpt]
report_drc -file [file join $work_dir reports post_synth_drc.rpt]

launch_simulation -simset sim_1 -mode post-synthesis -type functional

set sim_dir [file join $work_dir $proj_name.sim sim_1 synth func xsim]
set result_file [file join $sim_dir tb_gpx2_ft601_chain_post.result]
set sim_log [file join $sim_dir simulate.log]
if {![file exists $result_file]} {
    set alt_result [lindex [glob -nocomplain [file join $work_dir $proj_name.sim sim_1 * * xsim tb_gpx2_ft601_chain_post.result]] 0]
    if {$alt_result ne ""} {
        set result_file $alt_result
        set sim_log [file join [file dirname $alt_result] simulate.log]
    }
}
if {[file exists $result_file]} {
    set fp [open $result_file r]
    set log_text [read $fp]
    close $fp
    if {[string first "TEST FAILED" $log_text] >= 0} {
        error "Post-synthesis simulation self-check failed. See $result_file and $sim_log"
    }
    if {[string first "TEST PASSED" $log_text] < 0} {
        error "Post-synthesis simulation completed without TEST PASSED. See $result_file and $sim_log"
    }
} else {
    error "Post-synthesis simulation result file not found under $work_dir"
}

puts "TEST PASSED: GPX2 to FT601 post-synthesis simulation."
