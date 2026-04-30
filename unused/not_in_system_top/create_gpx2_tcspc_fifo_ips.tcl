# Create GPX2 TCSPC FIFO Generator IPs and add photon-mode sources.
# Usage:
#   $env:VIVADO_BIN -mode batch -source create_gpx2_tcspc_fifo_ips.tcl
# or in an open Vivado Tcl console:
#   source create_gpx2_tcspc_fifo_ips.tcl

set script_dir [file normalize [file dirname [info script]]]
set project_file [file normalize [file join $script_dir .. .. TDC_PC_Ver2.0.xpr]]

if {[catch {current_project}]} {
    open_project $project_file
}

proc add_source_if_needed {path} {
    set norm_path [file normalize $path]
    if {[llength [get_files -quiet $norm_path]] == 0} {
        add_files -fileset sources_1 -norecurse $norm_path
    }
}

foreach src {
    gpx2_spi_config.v
    timestamp_extend.v
    event_merger.v
    tcspc_event_processor.v
    photon_event_streamer.v
    photon_packet_builder.v
    gpx2_tcspc_event_top.v
} {
    add_source_if_needed [file join $script_dir $src]
}

proc create_fifo_if_missing {module_name common_clock width depth almost_full} {
    set existing [get_ips -quiet $module_name]
    if {[llength $existing] != 0} {
        puts "IP already exists: $module_name"
        return
    }

    create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 -module_name $module_name
    set ip [get_ips $module_name]

    if {$common_clock} {
        set impl Common_Clock_Block_RAM
    } else {
        set impl Independent_Clocks_Block_RAM
    }

    set_property -dict [list \
        CONFIG.INTERFACE_TYPE {Native} \
        CONFIG.Fifo_Implementation $impl \
        CONFIG.Performance_Options {First_Word_Fall_Through} \
        CONFIG.Input_Data_Width $width \
        CONFIG.Output_Data_Width $width \
        CONFIG.Input_Depth $depth \
        CONFIG.Reset_Pin {true} \
        CONFIG.Reset_Type {Asynchronous_Reset} \
        CONFIG.Enable_Reset_Synchronization {true} \
        CONFIG.Use_Dout_Reset {false} \
        CONFIG.Full_Flags_Reset_Value {0} \
        CONFIG.Almost_Full_Flag $almost_full \
        CONFIG.Valid_Flag {false} \
        CONFIG.Data_Count {false} \
        CONFIG.Write_Data_Count {false} \
        CONFIG.Read_Data_Count {false} \
    ] $ip

    generate_target all [get_files [get_property IP_FILE $ip]]
    puts "Created FIFO IP: $module_name width=$width depth=$depth"
}

create_fifo_if_missing gpx2_raw_fifo_ch1 0 32 8192 true
create_fifo_if_missing gpx2_raw_fifo_ch2 0 32 16384 true
create_fifo_if_missing gpx2_raw_fifo_ch3 0 32 1024 true
create_fifo_if_missing gpx2_raw_fifo_ch4 0 32 4096 true

create_fifo_if_missing gpx2_ext_fifo_ch1 1 128 1024 false
create_fifo_if_missing gpx2_ext_fifo_ch2 1 128 1024 false
create_fifo_if_missing gpx2_ext_fifo_ch3 1 128 1024 false
create_fifo_if_missing gpx2_ext_fifo_ch4 1 128 1024 false

create_fifo_if_missing gpx2_photon_fifo_128 1 128 4096 false

update_compile_order -fileset sources_1

puts "GPX2 TCSPC sources/IPs are ready."
puts "Expected new IPs: gpx2_raw_fifo_ch1..ch4, gpx2_ext_fifo_ch1..ch4, gpx2_photon_fifo_128."
puts "Next step: rerun synth_1 through write_bitstream so .bit and .ltx match."
