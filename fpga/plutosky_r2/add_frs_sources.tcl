# Source this from an OPEN Vivado project only. It adds the portable FRS RTL
# and its coefficient memories to sources_1 without changing the project top,
# block design, constraints, ports, or vendor receive path. The
# legacy-named frs_plutosky_r2_stream module will then be available as an RTL module
# reference for a later, explicitly reviewed BD integration step.

if {[current_project -quiet] eq ""} {
  error "Open the OpenSourceSDRLab CLG400 Vivado project before sourcing this hook."
}
set part [get_property PART [current_project]]
if {![string match -nocase "xc7z020clg400-*" $part]} {
  error "Expected an XC7Z020 CLG400 project; current project part is '$part'."
}

set hook_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $hook_dir ../..]]
set rtl_rel [list \
  fpga/iq_test_source.sv \
  fpga/axis_iq_mux.sv \
  fpga/band_ddc_decimator.sv \
  fpga/sparse_channelizer.sv \
  fpga/axis_rr_merge2_iq.sv \
  fpga/complex_squelch.sv \
  fpga/quadrature_demod.sv \
  fpga/fm_deemphasis.sv \
  fpga/audio_fir_decimator.sv \
  fpga/frs_channel_audio.sv \
  fpga/frs_multi_channel_audio.sv \
  fpga/frs_receive_core.sv \
  fpga/frs_ad9361_rx_adapter.sv \
  fpga/plutosky_r2/frs_plutosky_r2_stream.sv]
set coeff_rel [list \
  fpga/coeffs/subband_q17.memh \
  fpga/coeffs/nco_q15_quarter.memh \
  fpga/coeffs/channel_map_band1.memh \
  fpga/coeffs/channel_map_band2.memh \
  fpga/coeffs/channel_modulated_q17.memh \
  fpga/coeffs/audio_q17.memh]

set source_paths {}
foreach rel $rtl_rel {
  set path [file join $repo_root $rel]
  if {![file exists $path]} { error "Missing FRS RTL file: $path" }
  lappend source_paths $path
}
set coeff_paths {}
foreach rel $coeff_rel {
  set path [file join $repo_root $rel]
  if {![file exists $path]} { error "Missing FRS coefficient file: $path" }
  lappend coeff_paths $path
}

add_files -norecurse -fileset sources_1 $source_paths
add_files -norecurse -fileset sources_1 $coeff_paths
set existing_include_dirs [get_property include_dirs [get_filesets sources_1]]
set_property include_dirs [lsort -unique [concat $existing_include_dirs $repo_root]] \
  [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "Added FRS RTL and coefficients to sources_1. No BD/constraints/datapath were changed."
