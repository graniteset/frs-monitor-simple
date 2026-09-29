# Apply the provisional CLG400/AD9363 timing XDC to a disposable vendor project
# copy, excluding unrelated ZC702 board constraints. This intentionally leaves
# the board-specific CLG400 pin XDC enabled.
#
# Required environment:
#   FRS_VENDOR_XPR=work/.../frs_clg400_probe.xpr

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {![info exists ::env(FRS_VENDOR_XPR)]} {
  error "Set FRS_VENDOR_XPR to a disposable frs_clg400_probe.xpr under work/."
}
set xpr [file normalize $::env(FRS_VENDOR_XPR)]
set work_root [file normalize [file join $repo_root work]]
if {![string match "${work_root}/*" $xpr] || [file tail $xpr] ne "frs_clg400_probe.xpr"} {
  error "Refusing to modify anything except a frs_clg400_probe.xpr under work/: $xpr"
}

open_project $xpr
if {![string match -nocase "xc7z020clg400-*" [get_property PART [current_project]]]} {
  error "Expected an XC7Z020 CLG400 project."
}

# The generic ZC702 XDC contains pin assignments for unrelated HDMI/IIC/etc.
# ports. Disable that file only in this disposable copy; keep the CLG400 board
# pin XDC and all block-design PS constraints intact.
set zc702_xdcs [get_files -all -quiet -filter {NAME =~ "*projects/common/zc702/zc702_system_constr.xdc"}]
if {[llength $zc702_xdcs] != 1} {
  error "Expected exactly one generic ZC702 XDC, found: $zc702_xdcs"
}
set_property IS_ENABLED false $zc702_xdcs

set board_xdcs [get_files -all -quiet -filter {NAME =~ "*projects/fmcomms2/zc702/system_constr.xdc"}]
if {[llength $board_xdcs] != 1} {
  error "Expected exactly one CLG400 board XDC, found: $board_xdcs"
}
set timing_xdc [file join $script_dir clg400_ad936x_provisional_io_timing.xdc]
if {![file exists $timing_xdc]} { error "Missing timing XDC: $timing_xdc" }
set existing [get_files -all -quiet $timing_xdc]
if {[llength $existing] == 0} {
  add_files -fileset constrs_1 -norecurse $timing_xdc
  set existing [get_files -all -quiet $timing_xdc]
}
set_property IS_ENABLED true $existing
set_property PROCESSING_ORDER LATE $existing

update_compile_order -fileset sources_1
set candidate_dir [file join $work_root frs_clg400_timing_candidate_[clock seconds]_[pid]]
save_project_as frs_clg400_timing_candidate $candidate_dir
puts "PROVISIONAL_IO_TIMING_XDC=$timing_xdc"
puts "DISABLED_GENERIC_XDC=$zc702_xdcs"
puts "ENABLED_CLG400_BOARD_XDC=$board_xdcs"
set timing_candidate_xpr [file join $candidate_dir frs_clg400_timing_candidate.xpr]
puts "TIMING_CANDIDATE_XPR=$timing_candidate_xpr"
close_project

# Re-synthesize and run full implementation only in the new disposable copy.
open_project $timing_candidate_xpr
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "PROVISIONAL_SYNTH_STATUS=$synth_status"
if {![string match "*Complete!*" $synth_status]} {
  error "Synthesis failed with provisional I/O constraints: $synth_status"
}
open_run synth_1
report_io -file [file join $candidate_dir provisional_synth_io.rpt]
report_timing_summary -check_timing_verbose -file [file join $candidate_dir provisional_synth_timing.rpt]
close_design

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "PROVISIONAL_IMPL_STATUS=$impl_status"
if {![string match "*Complete!*" $impl_status]} {
  error "Implementation/bitstream failed with provisional constraints: $impl_status"
}
open_run impl_1
report_timing_summary -check_timing_verbose -file [file join $candidate_dir provisional_impl_timing.rpt]
report_drc -file [file join $candidate_dir provisional_impl_drc.rpt]
close_design
puts "PROVISIONAL_BITSTREAM=[get_property DIRECTORY [get_runs impl_1]]/system_top.bit"
close_project
