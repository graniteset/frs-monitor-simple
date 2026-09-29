# Generate the vendor BD products and synthesize its existing top in a scratch copy.
# Required environment:
#   FRS_VENDOR_XPR   work/.../frs_clg400_probe.xpr
#   FRS_ADI_IP_REPO  local ADI IP catalog root

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {![info exists ::env(FRS_VENDOR_XPR)] || ![info exists ::env(FRS_ADI_IP_REPO)]} {
  error "Set FRS_VENDOR_XPR and FRS_ADI_IP_REPO to run this scratch-copy synthesis."
}
set xpr [file normalize $::env(FRS_VENDOR_XPR)]
set work_root [file normalize [file join $repo_root work]]
if {![string match "${work_root}/*" $xpr] || [file tail $xpr] ne "frs_clg400_probe.xpr"} {
  error "Refusing to build anything except a frs_clg400_probe.xpr under work/: $xpr"
}
set project_dir [file dirname $xpr]
set ip_repo [file normalize $::env(FRS_ADI_IP_REPO)]
open_project $xpr
set part [get_property PART [current_project]]
if {![string match -nocase "xc7z020clg400-*" $part]} {
  error "Expected XC7Z020 CLG400, got '$part'"
}
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog -rebuild

# The vendor project disables these two legacy board-wrapper sources by
# default even though its selected board XDC describes the external pins.
set board_sources [get_files -all -quiet -filter {NAME =~ "*system_top.v" || NAME =~ "*ad_iobuf.v"}]
if {[llength $board_sources] != 2} {
  error "Expected system_top.v and ad_iobuf.v, found: $board_sources"
}
set_property IS_ENABLED 1 $board_sources

set bd_file ""
foreach candidate [get_files -all -filter {FILE_TYPE == "Block Designs"}] {
  set candidate_name [get_property NAME $candidate]
  if {[file tail $candidate_name] eq "system.bd" &&
      [string match "*/sources_1/bd/system/system.bd" $candidate_name]} {
    set bd_file $candidate_name
    break
  }
}
if {$bd_file eq ""} { error "Scratch project has no primary system.bd" }
open_bd_design $bd_file
validate_bd_design
reset_target all [get_files $bd_file]
generate_target all [get_files $bd_file]
set wrapper [make_wrapper -files [get_files $bd_file] -top]
add_files -norecurse $wrapper
update_compile_order -fileset sources_1
set_property top system_top [get_filesets sources_1]

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "VENDOR_SYNTH_STATUS=$synth_status"
if {![string match "*Complete!*" $synth_status]} {
  error "Vendor synthesis did not complete successfully: $synth_status"
}
open_run synth_1
report_utilization -file [file join $project_dir vendor_synth_utilization.rpt]
report_timing_summary -file [file join $project_dir vendor_synth_timing.rpt]
close_project
puts "Vendor scratch synthesis passed: $project_dir"
