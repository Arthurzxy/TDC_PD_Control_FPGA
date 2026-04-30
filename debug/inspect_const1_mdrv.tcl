# Inspect the post-synthesis net that triggers MDRV-1 during opt_design.
#
# Usage:
#   vivado -mode batch -source debug/inspect_const1_mdrv.tcl <project.xpr>

if {[llength $argv] >= 1} {
    open_project [lindex $argv 0]
} elseif {[catch {current_project}]} {
    error "Usage: vivado -mode batch -source debug/inspect_const1_mdrv.tcl <project.xpr>"
}

open_run synth_1

set out_dir [file normalize [file join [file dirname [info script]] timing_check]]
file mkdir $out_dir
set out_file [file join $out_dir const1_mdrv_inspect.txt]
set fp [open $out_file w]

puts $fp "=== Nets matching *const1* ==="
foreach n [get_nets -quiet -hier *const1*] {
    puts $fp ""
    puts $fp "NET: $n"
    puts $fp "DRIVER_PINS:"
    foreach p [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}] {
        puts $fp "  $p  cell=[get_cells -quiet -of_objects $p] ref=[get_property REF_NAME [get_cells -quiet -of_objects $p]]"
    }
    puts $fp "LOAD_PINS:"
    foreach p [get_pins -quiet -of_objects $n -filter {DIRECTION == IN}] {
        puts $fp "  $p  cell=[get_cells -quiet -of_objects $p] ref=[get_property REF_NAME [get_cells -quiet -of_objects $p]]"
    }
}

puts $fp ""
puts $fp "=== MDRV DRC ==="
catch {report_drc -checks {MDRV-1} -verbose} drc_text
puts $fp $drc_text

close $fp
puts "INFO: wrote $out_file"
