# Re-run place/route/bitgen after editing constraints on an existing disposable
# FRS candidate; reuses its completed synthesis run.
if {![info exists ::env(FRS_CANDIDATE_XPR)]} {
  error "Set FRS_CANDIDATE_XPR to a disposable frs_clg400_frs.xpr under work/."
}
set candidate_xpr [file normalize $::env(FRS_CANDIDATE_XPR)]
set repo_root [file normalize [file join [file dirname [file normalize [info script]]] ../..]]
set work_root [file normalize [file join $repo_root work]]
if {![string match "${work_root}/*" $candidate_xpr] ||
    [file tail $candidate_xpr] ne "frs_clg400_frs.xpr"} {
  error "Refusing to reimplement anything except a frs_clg400_frs.xpr under work/."
}

open_project $candidate_xpr
set bd_files [get_files -all -quiet -filter {NAME =~ "*/system.bd"}]
if {[llength $bd_files] != 1} { error "Expected one block design in the disposable FRS candidate." }
open_bd_design [lindex $bd_files 0]
set ad9361_cell [get_bd_cells -quiet axi_ad9361]
if {[llength $ad9361_cell] != 1} { error "Expected one axi_ad9361 block-design cell." }
foreach {parameter expected} {ADC_INIT_DELAY 23 USE_SSI_CLK 1} {
  set actual [get_property CONFIG.$parameter $ad9361_cell]
  if {$actual ne $expected} {
    error "CLG400 profile mismatch: axi_ad9361 CONFIG.$parameter=$actual, expected $expected."
  }
}
close_bd_design [lindex $bd_files 0]
set timing_xdc [file join [file dirname [file normalize [info script]]] clg400_ad936x_provisional_io_timing.xdc]
set timing_files [get_files -all -quiet $timing_xdc]
if {[llength $timing_files] != 1} { error "Expected one provisional timing XDC." }
set_property IS_ENABLED true $timing_files
set_property PROCESSING_ORDER LATE $timing_files
reset_run impl_1
# Physical optimization repairs actual data-path hold timing. It does not
# change timing exceptions or external timing budgets.
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithAggressiveHoldFix [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set status [get_property STATUS [get_runs impl_1]]
puts "FRS_IMPL_STATUS=$status"
if {![string match "*Complete!*" $status]} { error "FRS implementation failed." }
open_run impl_1
set reports [file join [file dirname $candidate_xpr] reports]
file mkdir $reports
report_timing_summary -check_timing_verbose -report_unconstrained -max_paths 50 \
  -file [file join $reports frs_impl_timing.rpt]
report_drc -file [file join $reports frs_impl_drc.rpt]
report_utilization -file [file join $reports frs_impl_utilization.rpt]
report_power -file [file join $reports frs_impl_power.rpt]
close_design
puts "FRS_BITSTREAM=[file join [get_property DIRECTORY [get_runs impl_1]] system_top.bit]"
close_project
