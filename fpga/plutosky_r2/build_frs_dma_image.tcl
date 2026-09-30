# Build a separate FRS receiver variant from a disposable CLG400 vendor XPR.
# This replaces the ADC-DMA payload with packed FRS audio records; it does not
# edit the vendor archive or any SD-card files.
#
# Required environment:
#   FRS_VENDOR_XPR=work/.../frs_clg400_probe.xpr
#   FRS_ADI_IP_REPO=work/.../library
# Optional:
#   FRS_TEST_MODE=0|1 (default 0: live AD9363; 1: on-channel channel-4 FM IQ)

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {![info exists ::env(FRS_VENDOR_XPR)]} {
  error "Set FRS_VENDOR_XPR to a disposable frs_clg400_probe.xpr under work/."
}
if {![info exists ::env(FRS_ADI_IP_REPO)]} {
  error "Set FRS_ADI_IP_REPO to the staged ADI IP catalog under work/."
}
set source_xpr [file normalize $::env(FRS_VENDOR_XPR)]
set adi_repo [file normalize $::env(FRS_ADI_IP_REPO)]
set work_root [file normalize [file join $repo_root work]]
if {![string match "${work_root}/*" $source_xpr] ||
    [file tail $source_xpr] ne "frs_clg400_probe.xpr"} {
  error "Refusing to modify anything except a frs_clg400_probe.xpr under work/."
}
if {![file isdirectory $adi_repo]} { error "ADI IP repo not found: $adi_repo" }

# Keep the staged ADI catalog immutable and make a per-build overlay for the
# CLG400 RX source-synchronous clock topology. The helper asserts the expected
# legacy ADI source fragments before modifying only the disposable copy.
source [file join $script_dir apply_clg400_bufio_capture.tcl]
set adi_repo [frs_make_clg400_bufio_catalog $adi_repo $work_root]
puts "FRS_ADI_IP_OVERLAY=$adi_repo"

set test_mode 0
if {[info exists ::env(FRS_TEST_MODE)]} {
  set test_mode $::env(FRS_TEST_MODE)
}
if {$test_mode ni {0 1}} { error "FRS_TEST_MODE must be 0 or 1." }

open_project $source_xpr
if {![string match -nocase "xc7z020clg400-*" [get_property PART [current_project]]]} {
  error "Expected an XC7Z020 CLG400 project; found [get_property PART [current_project]]."
}
set_property ip_repo_paths [list $adi_repo] [current_project]
update_ip_catalog -rebuild
source [file join $script_dir add_frs_sources.tcl]

set candidate_dir [file join $work_root frs_clg400_image_[clock seconds]_[pid]]
save_project_as frs_clg400_frs $candidate_dir
set candidate_xpr [file join $candidate_dir frs_clg400_frs.xpr]
close_project

open_project $candidate_xpr
set bd_files [get_files -all -quiet -filter {NAME =~ "*/system.bd"}]
if {[llength $bd_files] != 1} { error "Expected one system.bd; got $bd_files" }
set bd_file [lindex $bd_files 0]
open_bd_design $bd_file

# The selected CLG400 legacy project uses IDELAY startup tap 23 and enables
# the SSI clock path. Do not silently build against the unrelated CLG484/R2
# configuration (or a BD whose RX clock bypasses the dedicated I/O path).
set ad9361_cell [get_bd_cells -quiet axi_ad9361]
if {[llength $ad9361_cell] != 1} { error "Expected one axi_ad9361 block-design cell." }
foreach {parameter expected} {ADC_INIT_DELAY 23 USE_SSI_CLK 1} {
  set actual [get_property CONFIG.$parameter $ad9361_cell]
  if {$actual ne $expected} {
    error "CLG400 profile mismatch: axi_ad9361 CONFIG.$parameter=$actual, expected $expected."
  }
}

set required_pins [list \
  axi_ad9361/l_clk \
  axi_ad9361/adc_data_i0 axi_ad9361/adc_data_q0 \
  axi_ad9361/adc_valid_i0 axi_ad9361/adc_valid_q0 \
  axi_ad9361/adc_enable_i0 axi_ad9361/adc_enable_q0 \
  sys_ps7/FCLK_CLK0 sys_rstgen/peripheral_aresetn]
foreach pin $required_pins {
  if {[llength [get_bd_pins -quiet $pin]] != 1} {
    error "Required system.bd pin missing: $pin"
  }
}

set cpack_if [get_bd_intf_pins -quiet util_ad9361_adc_pack/packed_fifo_wr]
set dma_if [get_bd_intf_pins -quiet axi_ad9361_adc_dma/fifo_wr]
if {[llength $cpack_if] != 1 || [llength $dma_if] != 1} {
  error "Could not locate the existing ADC packer-to-DMA FIFO interface."
}
set old_net [get_bd_intf_nets -quiet -of_objects $cpack_if]
if {[llength $old_net] != 1} { error "Expected one packed FIFO interface net." }
set dma_fifo_clk [get_bd_pins axi_ad9361_adc_dma/fifo_wr_clk]
set old_clk_net [get_bd_nets -quiet -of_objects $dma_fifo_clk]
if {[llength $old_clk_net] != 1} { error "Expected one existing DMA FIFO clock net." }

set bridge [create_bd_cell -type module -reference frs_ad9361_dma_bridge frs_capture_bridge]
set_property CONFIG.TEST_MODE $test_mode $bridge
foreach {param relpath} [list \
  DDC_TAPS fpga/coeffs/subband_q17.memh \
  NCO_TAPS fpga/coeffs/nco_q15_quarter.memh \
  BAND1_MAP fpga/coeffs/channel_map_band1.memh \
  BAND2_MAP fpga/coeffs/channel_map_band2.memh \
  PFB_TAPS fpga/coeffs/channel_modulated_q17.memh \
  AUDIO_TAPS fpga/coeffs/audio_q17.memh] {
  set absolute [file normalize [file join $repo_root $relpath]]
  if {![file exists $absolute]} { error "Missing coefficient file: $absolute" }
  set_property CONFIG.$param $absolute $bridge
}
set test_sine_lut [file normalize [file join $repo_root fpga/coeffs/test_sine_q15_1024.memh]]
if {![file exists $test_sine_lut]} { error "Missing test sine ROM: $test_sine_lut" }
set_property CONFIG.TEST_SINE_LUT $test_sine_lut $bridge

# The AD9361 user ports run on l_clk and cannot accept backpressure. The DSP
# and the DMAC FIFO writer use FCLK0=100 MHz. The bridge contains the async FIFO.
foreach {source_port bridge_port} [list \
  axi_ad9361/l_clk adc_clk \
  axi_ad9361/adc_data_i0 adc0_word \
  axi_ad9361/adc_data_q0 adc1_word \
  axi_ad9361/adc_valid_i0 valid0 \
  axi_ad9361/adc_valid_q0 valid1 \
  axi_ad9361/adc_enable_i0 enable0 \
  axi_ad9361/adc_enable_q0 enable1 \
  sys_ps7/FCLK_CLK0 dsp_clk \
  sys_rstgen/peripheral_aresetn adc_resetn \
  sys_rstgen/peripheral_aresetn dsp_resetn] {
  connect_bd_net [get_bd_pins $source_port] [get_bd_pins $bridge/$bridge_port]
}

# Preserve the DMAC's existing FIFO interface net and replace only its source.
# Vivado has no delete_bd_intf_net command; disconnecting cpack leaves the net
# attached to the DMA and allows the bridge master to be connected to it.
disconnect_bd_intf_net $old_net $cpack_if
connect_bd_intf_net [get_bd_intf_pins $bridge/fifo_wr] $dma_if
disconnect_bd_net $old_clk_net $dma_fifo_clk
connect_bd_net [get_bd_pins sys_ps7/FCLK_CLK0] $dma_fifo_clk

validate_bd_design
save_bd_design

# The vendor project arrives with AXI_AD9361 output products generated from
# its unmodified IP catalog. Merely adding our private catalog overlay to
# ip_repo_paths does not invalidate that already-generated OOC checkpoint.
# AXI_AD9361 is a nested IP owned by system.bd. Vivado rejects resetting that
# XCI directly (Nested sub-designs can only be reset by their parent). Reset
# and regenerate the parent BD in this disposable candidate instead; this
# invalidates its child IP products and forces them to be rebuilt against the
# private overlay catalog without editing vendor source inputs.
reset_target all [get_files $bd_file]
generate_target all [get_files $bd_file]

# Assert the generated sources consumed by the candidate's synthesis products
# came from the BUFIO overlay. Inspect the .gen source tree (not .ip_user_files,
# which is a separate client/export copy and can remain stale after generation).
# Also confirm the generated AXI_AD9361 component metadata points at these
# exact files. This fails closed before synth/route while leaving vendor inputs
# untouched.
set ip_shared_dir [file join $candidate_dir frs_clg400_frs.gen sources_1 bd system ipshared]
set generated_clock_files [concat \
  [glob -nocomplain [file join $ip_shared_dir * ad_data_clk.v]] \
  [glob -nocomplain [file join $ip_shared_dir * * ad_data_clk.v]]]
set generated_lvds_files [concat \
  [glob -nocomplain [file join $ip_shared_dir * axi_ad9361_lvds_if.v]] \
  [glob -nocomplain [file join $ip_shared_dir * * axi_ad9361_lvds_if.v]]]
if {[llength $generated_clock_files] != 1} {
  error "Expected one generated ADI clock source in synthesis outputs under $ip_shared_dir; found: $generated_clock_files"
}
if {[llength $generated_lvds_files] != 1} {
  error "Expected one generated AXI_AD9361 LVDS source in synthesis outputs under $ip_shared_dir; found: $generated_lvds_files"
}
set generated_clock_file [lindex $generated_clock_files 0]
set generated_lvds_file [lindex $generated_lvds_files 0]
set component_xml [file join $candidate_dir frs_clg400_frs.gen sources_1 bd system ip system_axi_ad9361_0 system_axi_ad9361_0.xml]
if {![file isfile $component_xml]} {
  error "Generated AXI_AD9361 synthesis metadata is missing: $component_xml"
}
set xml_fd [open $component_xml r]
set component_description [read $xml_fd]
close $xml_fd
foreach generated_source [list $generated_clock_file $generated_lvds_file] {
  set source_relative [string range $generated_source [expr {[string length $ip_shared_dir] + 1}] end]
  set metadata_reference "../../ipshared/$source_relative"
  if {[string first $metadata_reference $component_description] < 0} {
    error "Generated AXI_AD9361 metadata does not reference synthesis source $generated_source"
  }
}
set clock_fd [open $generated_clock_file r]
set clock_source [read $clock_fd]
close $clock_fd
set lvds_fd [open $generated_lvds_file r]
set lvds_source [read $lvds_fd]
close $lvds_fd
set bufio_count [regexp -all -- {(?m)^\s*BUFIO\s+i_rx_clk_bufio\s*\(} $clock_source]
set clk_io_port_count [regexp -all -- {(?m)^\s*output\s+clk_io\s*\);} $clock_source]
set rx_clk_io_count [regexp -all -- {\.rx_clk\s*\(\s*l_clk_io\s*\)} $lvds_source]
set stale_rx_clk_count [regexp -all -- {\.rx_clk\s*\(\s*l_clk\s*\)} $lvds_source]
if {$bufio_count != 1 || $clk_io_port_count != 1 ||
    $rx_clk_io_count != 2 || $stale_rx_clk_count != 0} {
  error "Generated AXI_AD9361 sources do not use the required BUFIO RX capture clock: BUFIO=$bufio_count clk_io_ports=$clk_io_port_count RX_l_clk_io=$rx_clk_io_count RX_l_clk=$stale_rx_clk_count"
}
puts "Verified generated AXI_AD9361 RX IDDRs use the BUFIO capture clock."
update_compile_order -fileset sources_1

# Disable the unrelated ZC702 package-pin map, retain the CLG400 board pins,
# and add the current provisional radio timing model for reporting.
set zc702_xdcs [get_files -all -quiet -filter {NAME =~ "*projects/common/zc702/zc702_system_constr.xdc"}]
if {[llength $zc702_xdcs] != 1} { error "Expected one generic ZC702 XDC." }
set_property IS_ENABLED false $zc702_xdcs
set timing_xdc [file join $script_dir clg400_ad936x_provisional_io_timing.xdc]
# Repeated candidate generation may retain the timing XDC in the saved project.
# Remove only this named constraint file, if present, before adding the current
# copy; all unrelated constraints remain untouched.
set stale_timing_xdcs [get_files -all -quiet -filter {NAME =~ "*clg400_ad936x_provisional_io_timing.xdc"}]
if {[llength $stale_timing_xdcs]} {
  remove_files $stale_timing_xdcs
}
add_files -fileset constrs_1 -norecurse $timing_xdc
set timing_file [get_files -all -quiet $timing_xdc]
set_property IS_ENABLED true $timing_file
set_property PROCESSING_ORDER LATE $timing_file

set out_dir [file join $candidate_dir reports]
file mkdir $out_dir
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "FRS_SYNTH_STATUS=$synth_status"
if {![string match "*Complete!*" $synth_status]} { error "FRS synthesis failed." }
open_run synth_1
report_utilization -file [file join $out_dir frs_synth_utilization.rpt]
report_timing_summary -check_timing_verbose -file [file join $out_dir frs_synth_timing.rpt]
close_design

reset_run impl_1
# This is a physical hold repair pass, not an XDC exception or min-delay
# relaxation. It lets Vivado add routing/LUT delay on genuine hold paths.
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithAggressiveHoldFix [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "FRS_IMPL_STATUS=$impl_status"
if {![string match "*Complete!*" $impl_status]} { error "FRS implementation failed." }
open_run impl_1
report_timing_summary -check_timing_verbose -report_unconstrained -max_paths 50 \
  -file [file join $out_dir frs_impl_timing.rpt]
report_drc -file [file join $out_dir frs_impl_drc.rpt]
report_utilization -file [file join $out_dir frs_impl_utilization.rpt]
report_power -file [file join $out_dir frs_impl_power.rpt]
close_design

set bitfile [file join [get_property DIRECTORY [get_runs impl_1]] system_top.bit]
puts "FRS_BITSTREAM=$bitfile"
puts "FRS_CANDIDATE_XPR=$candidate_xpr"
puts "FRS_CAPTURE_FORMAT=two 21-bit channel/audio records per 64-bit DMA word; count=2 in bits 63:62"
close_project
