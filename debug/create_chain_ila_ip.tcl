# Create full-chain ILA IPs for GPX2 photon-event bring-up.
#
# Usage from an opened Vivado project:
#   source debug/create_chain_ila_ip.tcl
#
# Expected output:
#   ip/ila_chain_sys/ila_chain_sys.xci
#   ip/ila_chain_ft/ila_chain_ft.xci
#
# After sourcing this script, add both XCI files to sources_1 if Vivado does
# not do so automatically, then rerun synthesis through bitstream so the .bit
# and .ltx match.

if {[llength $argv] >= 1 && [catch {current_project}]} {
    open_project [lindex $argv 0]
}

set script_dir [file normalize [file dirname [info script]]]
set src_dir    [file normalize [file join $script_dir ..]]
set ip_dir     [file normalize [file join $src_dir ip]]

file mkdir $ip_dir

proc create_or_update_ila {module_name widths data_depth} {
    global ip_dir

    set xci_path [file join $ip_dir $module_name ${module_name}.xci]
    if {[file exists $xci_path]} {
        puts "INFO: $module_name already exists: $xci_path"
        read_ip $xci_path
    } else {
        create_ip -name ila -vendor xilinx.com -library ip -version 6.2 \
            -module_name $module_name -dir $ip_dir
    }

    set ip_obj [get_ips $module_name]
    set cfg [list \
        CONFIG.C_DATA_DEPTH $data_depth \
        CONFIG.C_NUM_OF_PROBES [llength $widths] \
        CONFIG.C_TRIGIN_EN false \
        CONFIG.C_TRIGOUT_EN false \
        CONFIG.ALL_PROBE_SAME_MU true \
        CONFIG.ALL_PROBE_SAME_MU_CNT 1 \
    ]

    for {set i 0} {$i < [llength $widths]} {incr i} {
        lappend cfg CONFIG.C_PROBE${i}_WIDTH [lindex $widths $i]
    }

    set_property -dict $cfg $ip_obj
    generate_target all [get_files $xci_path]
    export_ip_user_files -of_objects [get_files $xci_path] -no_script -sync -force -quiet
    puts "INFO: created $module_name at $xci_path"
}

# sys_clk ILA probes:
# 0 gpx2_stream_data[31:0]
# 1 gpx2_sys_ft_din[45:0]
# 2 GPX2/sys FIFO control[15:0]
# 3 photon_valid_count[31:0]
# 4 laser_count[31:0]
# 5 detector_count[31:0]
# 6 counter_count_sys[31:0]
# 7 gate_cfg_sys[48:0]
# 8 gate_ram_wr_data_sys[35:0]
# 9 gate_ram_wr_addr_sys[13:0]
# 10 gate control compact[31:0]
# 11 nb6_cfg_sys[18:0]
# 12 NB6 compact[31:0]
# ft_clk ILA probes:
# 0 ft_rx_data[31:0]
# 1 command/control compact[31:0]
# 2 ad5686_cfg_ft[63:0]
# 3 gate_cfg_ft[48:0]
# 4 gate_ram_cfg_ft[49:0]
# 5 pkt_tx_data[31:0]
# 6 tx_fifo_din[35:0]
# 7 tx_fifo_dout[35:0]
# 8 upload/FT control compact[31:0]
# 9 uptime_seconds_ft[31:0]
# 10 counter_count_ft[31:0]
# 11 {temp_avg_ft,status_flags_ft}[31:0]
# 12 usb_drop_count_ft[31:0]
# 13 gpx2_sys_ft_dout[45:0]
# 14 packet BE + ft ready compact[31:0]
# 15 tx_fifo_dout data copy[31:0]
# 16 tx_fifo_dout BE copy[3:0]
#
# Keep debug depth modest. Larger depths push the ILA trace-memory readback path
# into timing violations on this -1 Kintex-7 build.
create_or_update_ila ila_chain_sys {32 46 16 32 32 32 32 49 36 14 32 19 32} 1024
create_or_update_ila ila_chain_ft {32 32 64 49 50 32 36 36 32 32 32 32 32 46 32 32 4} 1024

update_compile_order -fileset sources_1
puts "INFO: chain ILA IP setup complete."
