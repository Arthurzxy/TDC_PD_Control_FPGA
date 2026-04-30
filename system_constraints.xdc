# Compact CDC constraints replace the previously expanded per-bit false_path lists.
# See the CDC section below for the active wildcard rules.

set_property IOSTANDARD LVDS_25 [get_ports {{gpx2_sdo_p[*]} {gpx2_sdo_n[*]} {gpx2_frame_p[*]} {gpx2_frame_n[*]}}]
set_property DIFF_TERM true [get_ports {{gpx2_sdo_p[*]} {gpx2_sdo_n[*]} {gpx2_frame_p[*]} {gpx2_frame_n[*]}}]
set_property IOSTANDARD LVCMOS33 [get_ports {{ft_data[*]} {ft_be[*]} ft_txe_n ft_rxf_n ft_wr_n ft_rd_n ft_oe_n ft_siwu_n}]
set_property ASYNC_REG true [get_cells -quiet -hier *pixel1_sync1_reg*]
set_property ASYNC_REG true [get_cells -quiet -hier *pixel1_sync2_reg*]
set_property ASYNC_REG true [get_cells -quiet -hier *pixel2_sync1_reg*]
set_property ASYNC_REG true [get_cells -quiet -hier *pixel2_sync2_reg*]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# The board feeds a 20 MHz oscillator into sys_clk_20M.
create_clock -period 50.000 -name sys_clk_20M [get_ports sys_clk_20M]

# Explicitly define the generated clock on clk_wiz_1's output so Vivado
# correctly propagates the 100 MHz sys_clk and computes the downstream MMCM
# VCO frequencies within the legal 600??200 MHz range. Without this the
# auto-generated clock object may be missing, causing DRC PDRC-34 errors.
create_generated_clock -name clk_out1_clk_wiz_1 -source [get_pins clk_pll_100M/inst/mmcm_adv_inst/CLKIN1] -multiply_by 5 [get_pins clk_pll_100M/inst/mmcm_adv_inst/CLKOUT0]
set_property PACKAGE_PIN AD23 [get_ports sys_clk_20M]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_20M]

# Board bring-up defaults to the FT601 66.67 MHz mode. Tighten this back to
# 10.000 ns only after the PCB has proven stable at full speed.
create_clock -period 15.000 -name ft_clk [get_ports ft_clk]
set_property PACKAGE_PIN AG29 [get_ports ft_clk]
set_property IOSTANDARD LVCMOS33 [get_ports ft_clk]

create_clock -period 10.000 -name gate_ref_clk [get_ports gate_ref_in_p]
set_property PACKAGE_PIN AE5 [get_ports gate_ref_in_p]
set_property PACKAGE_PIN AF5 [get_ports gate_ref_in_n]
set_property IOSTANDARD LVDS [get_ports gate_ref_in_p]
set_property IOSTANDARD LVDS [get_ports gate_ref_in_n]
set_property DIFF_TERM TRUE [get_ports gate_ref_in_p]
set_property DIFF_TERM TRUE [get_ports gate_ref_in_n]

create_clock -period 4.000 -name gpx2_lclk_in [get_ports gpx2_lclkout_p]
set_property PACKAGE_PIN F20 [get_ports gpx2_lclkout_p]
set_property PACKAGE_PIN E20 [get_ports gpx2_lclkout_n]
set_property IOSTANDARD LVDS_25 [get_ports gpx2_lclkout_p]
set_property IOSTANDARD LVDS_25 [get_ports gpx2_lclkout_n]
set_property DIFF_TERM TRUE [get_ports gpx2_lclkout_p]
set_property DIFF_TERM TRUE [get_ports gpx2_lclkout_n]

set_property PACKAGE_PIN A25 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

set_property PACKAGE_PIN K25 [get_ports gpx2_ssn]
set_property PACKAGE_PIN L27 [get_ports gpx2_sck]
set_property PACKAGE_PIN L26 [get_ports gpx2_mosi]
set_property PACKAGE_PIN L25 [get_ports gpx2_miso]
set_property IOSTANDARD LVCMOS33 [get_ports gpx2_ssn]
set_property IOSTANDARD LVCMOS33 [get_ports gpx2_sck]
set_property IOSTANDARD LVCMOS33 [get_ports gpx2_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports gpx2_miso]

set_property PACKAGE_PIN D17 [get_ports gpx2_lclkin_p]
set_property PACKAGE_PIN D18 [get_ports gpx2_lclkin_n]
set_property IOSTANDARD LVDS_25 [get_ports gpx2_lclkin_p]
set_property IOSTANDARD LVDS_25 [get_ports gpx2_lclkin_n]

set_property PACKAGE_PIN C17 [get_ports {gpx2_sdo_p[0]}]
set_property PACKAGE_PIN B17 [get_ports {gpx2_sdo_n[0]}]
set_property PACKAGE_PIN J17 [get_ports {gpx2_frame_p[0]}]
set_property PACKAGE_PIN H17 [get_ports {gpx2_frame_n[0]}]
set_property PACKAGE_PIN G18 [get_ports {gpx2_sdo_p[1]}]
set_property PACKAGE_PIN F18 [get_ports {gpx2_sdo_n[1]}]
set_property PACKAGE_PIN K18 [get_ports {gpx2_frame_p[1]}]
set_property PACKAGE_PIN J18 [get_ports {gpx2_frame_n[1]}]
set_property PACKAGE_PIN A16 [get_ports {gpx2_sdo_p[2]}]
set_property PACKAGE_PIN A17 [get_ports {gpx2_sdo_n[2]}]
set_property PACKAGE_PIN B18 [get_ports {gpx2_frame_p[2]}]
set_property PACKAGE_PIN A18 [get_ports {gpx2_frame_n[2]}]
set_property PACKAGE_PIN H20 [get_ports {gpx2_sdo_p[3]}]
set_property PACKAGE_PIN G20 [get_ports {gpx2_sdo_n[3]}]
set_property PACKAGE_PIN K19 [get_ports {gpx2_frame_p[3]}]
set_property PACKAGE_PIN K20 [get_ports {gpx2_frame_n[3]}]

set_property PACKAGE_PIN Y25 [get_ports {ft_data[0]}]
set_property PACKAGE_PIN Y26 [get_ports {ft_data[1]}]
set_property PACKAGE_PIN Y28 [get_ports {ft_data[2]}]
set_property PACKAGE_PIN Y29 [get_ports {ft_data[3]}]
set_property PACKAGE_PIN AA25 [get_ports {ft_data[4]}]
set_property PACKAGE_PIN AA26 [get_ports {ft_data[5]}]
set_property PACKAGE_PIN AA27 [get_ports {ft_data[6]}]
set_property PACKAGE_PIN AA28 [get_ports {ft_data[7]}]
set_property PACKAGE_PIN AB24 [get_ports {ft_data[8]}]
set_property PACKAGE_PIN AB25 [get_ports {ft_data[9]}]
set_property PACKAGE_PIN AB27 [get_ports {ft_data[10]}]
set_property PACKAGE_PIN AB28 [get_ports {ft_data[11]}]
set_property PACKAGE_PIN AC24 [get_ports {ft_data[12]}]
set_property PACKAGE_PIN AC25 [get_ports {ft_data[13]}]
set_property PACKAGE_PIN AC26 [get_ports {ft_data[14]}]
set_property PACKAGE_PIN AC27 [get_ports {ft_data[15]}]
set_property PACKAGE_PIN AC30 [get_ports {ft_data[16]}]
set_property PACKAGE_PIN AE30 [get_ports {ft_data[17]}]
set_property PACKAGE_PIN AF30 [get_ports {ft_data[18]}]
set_property PACKAGE_PIN AG30 [get_ports {ft_data[19]}]
set_property PACKAGE_PIN AH30 [get_ports {ft_data[20]}]
set_property PACKAGE_PIN AK30 [get_ports {ft_data[21]}]
set_property PACKAGE_PIN AC29 [get_ports {ft_data[22]}]
set_property PACKAGE_PIN AD29 [get_ports {ft_data[23]}]
set_property PACKAGE_PIN AE29 [get_ports {ft_data[24]}]
set_property PACKAGE_PIN AH29 [get_ports {ft_data[25]}]
set_property PACKAGE_PIN AJ29 [get_ports {ft_data[26]}]
set_property PACKAGE_PIN AK29 [get_ports {ft_data[27]}]
set_property PACKAGE_PIN AD28 [get_ports {ft_data[28]}]
set_property PACKAGE_PIN AE28 [get_ports {ft_data[29]}]
set_property PACKAGE_PIN AF28 [get_ports {ft_data[30]}]
set_property PACKAGE_PIN AG28 [get_ports {ft_data[31]}]
set_property PACKAGE_PIN AJ28 [get_ports {ft_be[0]}]
set_property PACKAGE_PIN AK28 [get_ports {ft_be[1]}]
set_property PACKAGE_PIN AD27 [get_ports {ft_be[2]}]
set_property PACKAGE_PIN AF27 [get_ports {ft_be[3]}]
set_property PACKAGE_PIN AG27 [get_ports ft_txe_n]
set_property PACKAGE_PIN AH27 [get_ports ft_rxf_n]
set_property PACKAGE_PIN AD26 [get_ports ft_wr_n]
set_property PACKAGE_PIN AE26 [get_ports ft_rd_n]
set_property PACKAGE_PIN AF26 [get_ports ft_oe_n]
set_property PACKAGE_PIN AJ27 [get_ports ft_siwu_n]
set_property PULLTYPE PULLUP [get_ports ft_wr_n]
set_property PULLTYPE PULLUP [get_ports ft_rd_n]
set_property PULLTYPE PULLUP [get_ports ft_oe_n]
set_property PULLTYPE PULLUP [get_ports ft_siwu_n]

# FT601 board-control pins are routed through the FPGA on this PCB.
# Fill in the package pins from the schematic before rebuilding.
# Bring-up default should keep FT601 alive in 1-channel 245 FIFO mode:
#   ft_reset_n  = 1
#   ft_wakeup_n = 1
#   ft_gpio1    = 0
#   ft_gpio0    = 0
# Example template:
set_property PACKAGE_PIN AH26 [get_ports ft_reset_n]
set_property PACKAGE_PIN AJ26 [get_ports ft_wakeup_n]
set_property PACKAGE_PIN AK26 [get_ports ft_gpio0]
set_property PACKAGE_PIN AE25 [get_ports ft_gpio1]
set_property IOSTANDARD LVCMOS33 [get_ports ft_reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports ft_wakeup_n]
set_property IOSTANDARD LVCMOS33 [get_ports ft_gpio0]
set_property IOSTANDARD LVCMOS33 [get_ports ft_gpio1]

set_property PACKAGE_PIN P24 [get_ports flash_spi_d0]
set_property PACKAGE_PIN R25 [get_ports flash_spi_d1]
set_property PACKAGE_PIN U19 [get_ports flash_spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports flash_spi_d0]
set_property IOSTANDARD LVCMOS33 [get_ports flash_spi_d1]
set_property IOSTANDARD LVCMOS33 [get_ports flash_spi_cs_n]

set_property PACKAGE_PIN M24 [get_ports ad5686_clk]
set_property PACKAGE_PIN M27 [get_ports ad5686_din]
set_property PACKAGE_PIN M25 [get_ports ad5686_cs]
set_property IOSTANDARD LVCMOS33 [get_ports ad5686_clk]
set_property IOSTANDARD LVCMOS33 [get_ports ad5686_din]
set_property IOSTANDARD LVCMOS33 [get_ports ad5686_cs]

# Assumption for integration: counter input is moved to the previous spare
# differential pair so the gate-test pixel2 pins stay unchanged.
set_property PACKAGE_PIN AD2 [get_ports counter_ava_p]
set_property PACKAGE_PIN AD1 [get_ports counter_ava_n]
set_property IOSTANDARD LVDS [get_ports counter_ava_p]
set_property IOSTANDARD LVDS [get_ports counter_ava_n]
set_property DIFF_TERM TRUE [get_ports counter_ava_p]
set_property DIFF_TERM TRUE [get_ports counter_ava_n]

set_property PACKAGE_PIN M28 [get_ports dac8881_clk]
set_property PACKAGE_PIN L23 [get_ports dac8881_din]
set_property PACKAGE_PIN M29 [get_ports dac8881_cs]
set_property IOSTANDARD LVCMOS33 [get_ports dac8881_clk]
set_property IOSTANDARD LVCMOS33 [get_ports dac8881_din]
set_property IOSTANDARD LVCMOS33 [get_ports dac8881_cs]

set_property PACKAGE_PIN M23 [get_ports temp_adc_sdo]
set_property PACKAGE_PIN M22 [get_ports temp_adc_sclk]
set_property PACKAGE_PIN M19 [get_ports temp_adc_cs]
set_property PACKAGE_PIN M20 [get_ports temp_adc_cv]
set_property IOSTANDARD LVCMOS33 [get_ports temp_adc_sdo]
set_property IOSTANDARD LVCMOS33 [get_ports temp_adc_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports temp_adc_cs]
set_property IOSTANDARD LVCMOS33 [get_ports temp_adc_cv]

set_property PACKAGE_PIN L22 [get_ports gate_in_outside]
set_property PACKAGE_PIN K29 [get_ports gate_out]
set_property PACKAGE_PIN N22 [get_ports latch_enable]
set_property IOSTANDARD LVCMOS33 [get_ports gate_in_outside]
set_property IOSTANDARD LVCMOS33 [get_ports gate_out]
set_property IOSTANDARD LVCMOS33 [get_ports latch_enable]

set_property PACKAGE_PIN W26 [get_ports nb6l295_en]
set_property PACKAGE_PIN W23 [get_ports nb6l295_sdin]
set_property PACKAGE_PIN W22 [get_ports nb6l295_sclk]
set_property PACKAGE_PIN W24 [get_ports nb6l295_sload]
set_property IOSTANDARD LVCMOS33 [get_ports nb6l295_en]
set_property IOSTANDARD LVCMOS33 [get_ports nb6l295_sdin]
set_property IOSTANDARD LVCMOS33 [get_ports nb6l295_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports nb6l295_sload]

set_property PACKAGE_PIN AH2 [get_ports gate_pixel_in_p]
set_property PACKAGE_PIN AJ2 [get_ports gate_pixel_in_n]
set_property IOSTANDARD LVDS [get_ports gate_pixel_in_p]
set_property IOSTANDARD LVDS [get_ports gate_pixel_in_n]
set_property DIFF_TERM TRUE [get_ports gate_pixel_in_p]
set_property DIFF_TERM TRUE [get_ports gate_pixel_in_n]

set_property PACKAGE_PIN AJ1 [get_ports gate_pixel2_in_p]
set_property PACKAGE_PIN AK1 [get_ports gate_pixel2_in_n]
set_property IOSTANDARD LVDS [get_ports gate_pixel2_in_p]
set_property IOSTANDARD LVDS [get_ports gate_pixel2_in_n]
set_property DIFF_TERM TRUE [get_ports gate_pixel2_in_p]
set_property DIFF_TERM TRUE [get_ports gate_pixel2_in_n]

set_property PACKAGE_PIN AG4 [get_ports gate_out_hp_p]
set_property PACKAGE_PIN AG3 [get_ports gate_out_hp_n]
set_property IOSTANDARD LVDS [get_ports gate_out_hp_p]
set_property IOSTANDARD LVDS [get_ports gate_out_hp_n]

set_property PACKAGE_PIN AC2 [get_ports gate_out_ext_p]
set_property PACKAGE_PIN AC1 [get_ports gate_out_ext_n]
set_property IOSTANDARD LVDS [get_ports gate_out_ext_p]
set_property IOSTANDARD LVDS [get_ports gate_out_ext_n]

#----------------------------------------------------------------------------
# Bring-up I/O timing model
# These delays are provisional board-level budgets for implementation/debug.
# Replace them with measured or datasheet-derived interface timing before
# final signoff. The intent here is to cover the main synchronous peripherals
# and remove TIMING-18 noise from clearly modeled interfaces.
#----------------------------------------------------------------------------

# Source-synchronous FT601 FIFO interface. In 245 mode FT601 also drives
# ft_be during FPGA read cycles, so model it on the input side as well.
set_input_delay -clock [get_clocks ft_clk] -max 3.500 [get_ports {{ft_data[*]} {ft_be[*]} ft_txe_n ft_rxf_n}]
set_input_delay -clock [get_clocks ft_clk] -min 0.500 [get_ports {{ft_data[*]} {ft_be[*]} ft_txe_n ft_rxf_n}]
set_output_delay -clock [get_clocks ft_clk] -max 3.000 [get_ports {{ft_data[*]} {ft_be[*]} ft_wr_n ft_rd_n ft_oe_n ft_siwu_n}]
set_output_delay -clock [get_clocks ft_clk] -min -0.500 [get_ports {{ft_data[*]} {ft_be[*]} ft_wr_n ft_rd_n ft_oe_n ft_siwu_n}]

# Source-synchronous GPX2 LVDS receive interface relative to the forwarded
# lclk. DDR capture needs both edge relationships modeled.
#
# Bring-up assumption:
# - gpx2_spi_cfg programs LVDS_DATA_VALID_ADJUST = +320 ps
# - gpx2_top inserts fixed IDELAY on every SDO/FRAME lane
# - after those two knobs are applied, the effective external launch offset is
#   modeled as a narrow 0.75 ns .. 0.80 ns window around the forwarded LCLK
#   for bring-up timing closure
#
# This is still a bring-up model, not final signoff timing. After lab capture
# of LCLKOUT/SDO/FRAME on the real PCB, update these numbers with measured
# device + board skew.
set_input_delay -clock [get_clocks gpx2_lclk_in] -max 0.800 [get_ports {{gpx2_sdo_p[*]} {gpx2_frame_p[*]}}]
set_input_delay -clock [get_clocks gpx2_lclk_in] -min 0.750 [get_ports {{gpx2_sdo_p[*]} {gpx2_frame_p[*]}}]
set_input_delay -clock [get_clocks gpx2_lclk_in] -clock_fall -max -add_delay 0.800 [get_ports {{gpx2_sdo_p[*]} {gpx2_frame_p[*]}}]
set_input_delay -clock [get_clocks gpx2_lclk_in] -clock_fall -min -add_delay 0.750 [get_ports {{gpx2_sdo_p[*]} {gpx2_frame_p[*]}}]

# These slow serial/control links are driven by internally generated strobes
# rather than a board-visible reference clock. Until dedicated virtual clocks
# are added for each device, keep them out of generic sys_clk signoff timing so
# the real synchronous interfaces dominate bring-up closure.
set_false_path -from [get_ports flash_spi_d1]
set_false_path -to [get_ports {flash_spi_d0 flash_spi_cs_n}]
set_false_path -from [get_ports gpx2_miso]
set_false_path -to [get_ports {gpx2_ssn gpx2_sck gpx2_mosi}]
set_false_path -to [get_ports {nb6l295_en nb6l295_sclk nb6l295_sdin nb6l295_sload}]
set_false_path -to [get_ports gate_out]

# Explicitly mark asynchronous external sources so they are not mistaken for
# synchronous sys_clk or gate_ref_clk interfaces.
set_false_path -from [get_ports sys_rst_n]
set_false_path -from [get_ports {counter_ava_p counter_ava_n}]
set_false_path -from [get_ports {gate_pixel_in_p gate_pixel_in_n gate_pixel2_in_p gate_pixel2_in_n}]

# Mark the gate pixel input synchronizers from the reused gate core so Vivado
# classifies them as proper CDC chains without requiring RTL changes there.

# Prefer point-to-point CDC cuts over a global asynchronous clock group so the
# async FIFO IP keeps its own set_max_delay -datapath_only constraints active.
# These false paths stop timing analysis only at the first synchronizer stage.
# `sys_clk` is the generated clock coming out of clk_wiz_1, whose resolved
# clock name in timing reports is `clk_out1_clk_wiz_1`. Use the real clock
# object name here so the asynchronous CDC cut actually takes effect.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks gate_ref_clk] -group [list [get_clocks -include_generated_clocks clk_out1_clk_wiz_1] [get_clocks -include_generated_clocks ft_clk] [get_clocks -include_generated_clocks gpx2_lclk_in]]

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

# Debug snapshot buses intentionally cross ft_clk -> sys_clk only for ILA
# observation. The toggle flags are synchronized separately; do not time the
# multi-bit debug payload as a synchronous data path.
set_false_path \
    -from [get_cells -quiet -hier {*dbg_ft_rx_data_hold_ft_reg[*] *dbg_ft_ctrl_hold_ft_reg[*] *dbg_ad5686_data1_hold_ft_reg[*] *dbg_ad5686_data2_hold_ft_reg[*]}] \
    -to   [get_pins  -quiet -hier {*dbg_ft_rx_data_sys_reg[*]/D *dbg_ft_ctrl_sys_reg[*]/D *dbg_ad5686_data1_sys_reg[*]/D *dbg_ad5686_data2_sys_reg[*]/D}]

# Reset release is slow-control behavior. Cutting only reset pins avoids the
# huge synchronous reset fanout from dominating setup timing while keeping data
# paths timed normally.
set_false_path \
    -from [get_cells -quiet -hier {rst_sync_ff_reg[2] ft_rst_sync_ff_reg[2] clk20_rst_sync_ff_reg[2] *gate_rst_sync_ff_reg[2]}]

# ILA debug-core constraints removed ??they referenced nets that were
# optimized away because the dbg_* buses lacked mark_debug attributes.
# After re-synthesis with mark_debug=true on the dbg_* wires, re-source
# debug/add_system_ila.tcl to re-insert the ILAs.
# Default implementation disables the large post-synth auto-ILA flow below.
# It is kept only as an optional debug recipe for dedicated debug builds.
# Debug hub clock: use the 100 MHz MMCM output (sys_clk) so JTAG can enumerate
# ILAs even without the FT601 connected.  ft_clk is absent when the USB cable
# is unplugged, which made the hub invisible to the hardware manager.

set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets sys_clk]

#----------------------------------------------------------------------------
# Board-revision pin placeholder block
#----------------------------------------------------------------------------
# The RTL top-level ports are real board I/O ports. Keep this section as the
# single place to update if the schematic pinout changes. The current active
# PACKAGE_PIN constraints above are for the present board revision; the lines
# below are intentionally commented placeholders so they cannot accidentally
# override a known-good pinout.
#
# GPX2 SPI / clocks / LVDS:
# set_property PACKAGE_PIN <TODO_GPX2_SSN>      [get_ports gpx2_ssn]
# set_property PACKAGE_PIN <TODO_GPX2_SCK>      [get_ports gpx2_sck]
# set_property PACKAGE_PIN <TODO_GPX2_MOSI>     [get_ports gpx2_mosi]
# set_property PACKAGE_PIN <TODO_GPX2_MISO>     [get_ports gpx2_miso]
# set_property PACKAGE_PIN <TODO_GPX2_LCLKOUT_P>[get_ports gpx2_lclkout_p]
# set_property PACKAGE_PIN <TODO_GPX2_LCLKOUT_N>[get_ports gpx2_lclkout_n]
# set_property PACKAGE_PIN <TODO_GPX2_LCLKIN_P> [get_ports gpx2_lclkin_p]
# set_property PACKAGE_PIN <TODO_GPX2_LCLKIN_N> [get_ports gpx2_lclkin_n]
# set_property PACKAGE_PIN <TODO_GPX2_SDO1_P>   [get_ports {gpx2_sdo_p[0]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO1_N>   [get_ports {gpx2_sdo_n[0]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME1_P> [get_ports {gpx2_frame_p[0]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME1_N> [get_ports {gpx2_frame_n[0]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO2_P>   [get_ports {gpx2_sdo_p[1]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO2_N>   [get_ports {gpx2_sdo_n[1]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME2_P> [get_ports {gpx2_frame_p[1]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME2_N> [get_ports {gpx2_frame_n[1]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO3_P>   [get_ports {gpx2_sdo_p[2]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO3_N>   [get_ports {gpx2_sdo_n[2]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME3_P> [get_ports {gpx2_frame_p[2]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME3_N> [get_ports {gpx2_frame_n[2]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO4_P>   [get_ports {gpx2_sdo_p[3]}]
# set_property PACKAGE_PIN <TODO_GPX2_SDO4_N>   [get_ports {gpx2_sdo_n[3]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME4_P> [get_ports {gpx2_frame_p[3]}]
# set_property PACKAGE_PIN <TODO_GPX2_FRAME4_N> [get_ports {gpx2_frame_n[3]}]
#
# FT601 245 synchronous FIFO:
# set_property PACKAGE_PIN <TODO_FT_CLK>        [get_ports ft_clk]
# set_property PACKAGE_PIN <TODO_FT_TXE_N>      [get_ports ft_txe_n]
# set_property PACKAGE_PIN <TODO_FT_RXF_N>      [get_ports ft_rxf_n]
# set_property PACKAGE_PIN <TODO_FT_WR_N>       [get_ports ft_wr_n]
# set_property PACKAGE_PIN <TODO_FT_RD_N>       [get_ports ft_rd_n]
# set_property PACKAGE_PIN <TODO_FT_OE_N>       [get_ports ft_oe_n]
# set_property PACKAGE_PIN <TODO_FT_SIWU_N>     [get_ports ft_siwu_n]
# set_property PACKAGE_PIN <TODO_FT_RESET_N>    [get_ports ft_reset_n]
# set_property PACKAGE_PIN <TODO_FT_WAKEUP_N>   [get_ports ft_wakeup_n]
# set_property PACKAGE_PIN <TODO_FT_GPIO0>      [get_ports ft_gpio0]
# set_property PACKAGE_PIN <TODO_FT_GPIO1>      [get_ports ft_gpio1]
# set_property PACKAGE_PIN <TODO_FT_DATA0>      [get_ports {ft_data[0]}]
# set_property PACKAGE_PIN <TODO_FT_DATA31>     [get_ports {ft_data[31]}]
# set_property PACKAGE_PIN <TODO_FT_BE0>        [get_ports {ft_be[0]}]
# set_property PACKAGE_PIN <TODO_FT_BE3>        [get_ports {ft_be[3]}]
#
# Slow control / measurement I/O:
# set_property PACKAGE_PIN <TODO_FLASH_D0>      [get_ports flash_spi_d0]
# set_property PACKAGE_PIN <TODO_FLASH_D1>      [get_ports flash_spi_d1]
# set_property PACKAGE_PIN <TODO_FLASH_CS_N>    [get_ports flash_spi_cs_n]
# set_property PACKAGE_PIN <TODO_COUNTER_P>     [get_ports counter_ava_p]
# set_property PACKAGE_PIN <TODO_COUNTER_N>     [get_ports counter_ava_n]
# set_property PACKAGE_PIN <TODO_TEMP_SDO>      [get_ports temp_adc_sdo]
# set_property PACKAGE_PIN <TODO_TEMP_SCLK>     [get_ports temp_adc_sclk]
# set_property PACKAGE_PIN <TODO_TEMP_CS>       [get_ports temp_adc_cs]
# set_property PACKAGE_PIN <TODO_TEMP_CV>       [get_ports temp_adc_cv]
