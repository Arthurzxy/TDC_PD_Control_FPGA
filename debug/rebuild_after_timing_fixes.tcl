# Rebuild the project after RTL/XDC timing fixes and write a fresh timing report.
#
# Usage:
#   vivado -mode batch -source debug/rebuild_after_timing_fixes.tcl <project.xpr>

if {[llength $argv] >= 1} {
    open_project [lindex $argv 0]
} elseif {[catch {current_project}]} {
    error "Usage: vivado -mode batch -source debug/rebuild_after_timing_fixes.tcl <project.xpr>"
}

# Some old files were moved out of sources_1 during cleanup but remain in the
# project file. Remove missing references only in this batch session so the
# rebuild can use the current, live source set without editing the .xpr.
foreach f [get_files -quiet] {
    set n [get_property NAME $f]
    if {![file exists $n]} {
        puts "INFO: removing missing project file reference for this run: $n"
        remove_files $f
    }
}

update_compile_order -fileset sources_1

reset_run synth_1
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set out_dir [file normalize [file join [file dirname [info script]] timing_check]]
file mkdir $out_dir

open_run impl_1
report_timing_summary \
    -max_paths 30 \
    -report_unconstrained \
    -warn_on_violation \
    -file [file join $out_dir rebuilt_timing_summary.rpt]
report_route_status \
    -file [file join $out_dir rebuilt_route_status.rpt]

puts "INFO: wrote [file join $out_dir rebuilt_timing_summary.rpt]"
puts "INFO: wrote [file join $out_dir rebuilt_route_status.rpt]"
