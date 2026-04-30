# Vivado batch simulation for GPX2 TCSPC core processing.
# Usage:
#   vivado -mode batch -source sim/run_gpx2_tcspc_core_sim.tcl

set script_dir [file normalize [file dirname [info script]]]
set src_dir    [file normalize [file join $script_dir ..]]
set work_dir   [file normalize [file join $script_dir xsim_gpx2_tcspc_core]]
set proj_name  gpx2_tcspc_core_sim
set part_name  xc7k325tffg900-1

if {[info exists ::env(XILINX_VIVADO)]} {
    set vivado_dir [file normalize $::env(XILINX_VIVADO)]
} else {
    set vivado_dir [file normalize [file join [file dirname [info nameofexecutable]] .. .. ..]]
}
set mingw_bin [file normalize [file join $vivado_dir tps mingw 10.0.0 win64.o nt bin]]
if {[file exists [file join $mingw_bin gcc.exe]]} {
    set ::env(PATH) "$mingw_bin;$::env(PATH)"
}

file mkdir $work_dir
set ::env(TEMP) $work_dir
set ::env(TMP)  $work_dir
cd $work_dir

create_project $proj_name $work_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -fileset sources_1 [list \
    [file join $src_dir event_merger.v] \
    [file join $src_dir tcspc_event_processor.v] \
    [file join $src_dir photon_event_streamer.v] \
]

add_files -fileset sim_1 [list \
    [file join $script_dir tb_gpx2_tcspc_core.sv] \
]
set_property file_type SystemVerilog [get_files [file join $script_dir tb_gpx2_tcspc_core.sv]]
set_property top tb_gpx2_tcspc_core [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation -simset sim_1

set sim_dir [file join $work_dir $proj_name.sim sim_1 behav xsim]
set result_file [file join $sim_dir tb_gpx2_tcspc_core.result]
set sim_log [file join $sim_dir simulate.log]
if {[file exists $result_file]} {
    set fp [open $result_file r]
    set log_text [read $fp]
    close $fp
    if {[string first "TEST FAILED" $log_text] >= 0} {
        error "Simulation self-check failed. See $result_file and $sim_log"
    }
    if {[string first "TEST PASSED" $log_text] < 0} {
        error "Simulation completed without TEST PASSED. See $result_file and $sim_log"
    }
} else {
    error "Simulation result file not found: $result_file"
}

puts "TEST PASSED: GPX2 TCSPC core simulation."
