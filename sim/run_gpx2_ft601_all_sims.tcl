# Runs the GPX2/TCSPC/FT601 behavioral simulation suite.
# Usage:
#   $env:VIVADO_BIN -mode batch -source sim/run_gpx2_ft601_all_sims.tcl

set script_dir [file normalize [file dirname [info script]]]
set sim_scripts [list \
    run_gpx2_spi_config_sim.tcl \
    run_gpx2_lvds_rx_ddr_sim.tcl \
    run_gpx2_processing_to_uplink_sim.tcl \
    run_uplink_ft601_tx_sim.tcl \
    run_gpx2_lvds_to_ft601_e2e_sim.tcl \
]

foreach sim_script $sim_scripts {
    puts "============================================================"
    puts "Running [file join $script_dir $sim_script]"
    puts "============================================================"
    source [file join $script_dir $sim_script]
    if {![catch {current_project}]} {
        close_project
    }
}

puts "TEST PASSED: all GPX2/FT601 simulations completed."
