# Reproducible out-of-context synthesis of the portable FRS DSP core for the
# PlutoSky R2 Zynq-7020. Run from the repository root with:
#   /opt/Xilinx/2026.1/Vivado/bin/vivado -mode batch -nolog -nojournal \
#     -source fpga/plutosky_r2/ooc_synth.tcl
# Reports/checkpoint are written only to ignored work/ (or FRS_OOC_OUT).
# This is not a board build: there is no pinout, PS/BD, I/O timing, routing,
# bitstream, or hardware validation in this flow.

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

if {[info exists ::env(FRS_OOC_OUT)]} {
  set out_dir [file normalize $::env(FRS_OOC_OUT)]
} else {
  set out_dir [file join $repo_root work frs_plutosky_r2_ooc]
}
file mkdir $out_dir

set part xc7z020clg484-2
if {[llength [get_parts -quiet $part]] == 0} {
  error "Target part '$part' is not present in this Vivado installation. Install Zynq-7000 device support (Vivado Help > Add Design Tools or Devices), then rerun. The part name matches the vendor PlutoSky R2 project; do not silently substitute a different speed grade."
}
set rtl_files [list \
  fpga/band_ddc_decimator.sv \
  fpga/sparse_channelizer.sv \
  fpga/axis_rr_merge2_iq.sv \
  fpga/complex_squelch.sv \
  fpga/quadrature_demod.sv \
  fpga/fm_deemphasis.sv \
  fpga/audio_fir_decimator.sv \
  fpga/frs_channel_audio.sv \
  fpga/frs_multi_channel_audio.sv \
  fpga/frs_receive_core.sv]

foreach path $rtl_files {
  if {![file exists [file join $repo_root $path]]} {
    error "Required RTL source not found: $path"
  }
  read_verilog -sv $path
}

# The core's simulation/test contract accepts one IQ beat per 15.625 fabric
# clocks (6.4 MS/s at 100 MHz). The core clock itself is 100 MHz. This top has
# no explicit rate parameter; source pacing is represented by s_valid at its
# integration boundary and must be preserved by the system wrapper.
read_xdc [file join $script_dir ooc_100mhz.xdc]
set coefficient_params [list \
  DDC_TAPS fpga/coeffs/subband_q17.memh \
  NCO_TAPS fpga/coeffs/nco_q15_quarter.memh \
  BAND1_MAP fpga/coeffs/channel_map_band1.memh \
  BAND2_MAP fpga/coeffs/channel_map_band2.memh \
  PFB_TAPS fpga/coeffs/channel_modulated_q17.memh \
  AUDIO_TAPS fpga/coeffs/audio_q17.memh]
set generic_args {}
foreach {name rel_path} $coefficient_params {
  set absolute_path [file normalize [file join $repo_root $rel_path]]
  if {![file exists $absolute_path]} { error "Missing coefficient memory: $absolute_path" }
  # Preserve the quotes so Vivado treats the parameter override as a string.
  lappend generic_args -generic "${name}=\"${absolute_path}\""
}
synth_design -top frs_receive_core -part $part -mode out_of_context \
  -flatten_hierarchy none {*}$generic_args

report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained \
  -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 \
  -file [file join $out_dir timing_paths.rpt]
report_clock_utilization -file [file join $out_dir clock_utilization.rpt]
write_checkpoint -force [file join $out_dir frs_receive_core_ooc.dcp]

puts "FRS OOC synthesis complete. Reports: $out_dir"
puts "Reminder: OOC synthesis estimates mapping only; no placement, route, bitstream, or board validation."
