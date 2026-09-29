# Upgrade the Vivado IP in a disposable copy of the CLG400 vendor project.
# This script refuses to touch the staged vendor archive or an arbitrary XPR.
# Required environment:
#   FRS_VENDOR_XPR   path to work/.../frs_clg400_probe.xpr
#   FRS_ADI_IP_REPO  local ADI IP catalog root

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {![info exists ::env(FRS_VENDOR_XPR)] || ![info exists ::env(FRS_ADI_IP_REPO)]} {
  error "Set FRS_VENDOR_XPR and FRS_ADI_IP_REPO to run this scratch-copy upgrade."
}
set xpr [file normalize $::env(FRS_VENDOR_XPR)]
set work_root [file normalize [file join $repo_root work]]
if {![string match "${work_root}/*" $xpr] || [file tail $xpr] ne "frs_clg400_probe.xpr"} {
  error "Refusing to upgrade anything except a frs_clg400_probe.xpr under work/: $xpr"
}
set project_dir [file dirname $xpr]
set ip_repo [file normalize $::env(FRS_ADI_IP_REPO)]
if {![file isdirectory $ip_repo]} {
  error "ADI IP repository not found: $ip_repo"
}

open_project $xpr
set part [get_property PART [current_project]]
if {![string match -nocase "xc7z020clg400-*" $part]} {
  error "Expected XC7Z020 CLG400, got '$part'"
}
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog -rebuild
report_ip_status -file [file join $project_dir ip_status_before_upgrade.rpt]

# With no object list, Vivado upgrades project IP. Avoid `get_ips -all`:
# that also returns subcores which can be removed while their parent upgrades.
upgrade_ip [get_ips] -log [file join $project_dir ip_upgrade.log]
report_ip_status -file [file join $project_dir ip_status_after_upgrade.rpt]

set bd_file ""
foreach candidate [get_files -all -filter {FILE_TYPE == "Block Designs"}] {
  set candidate_name [get_property NAME $candidate]
  if {[file tail $candidate_name] eq "system.bd" &&
      [string match "*/sources_1/bd/system/system.bd" $candidate_name]} {
    set bd_file $candidate_name
    break
  }
}
if {$bd_file eq ""} {
  error "Scratch project has no primary system.bd"
}
open_bd_design $bd_file
validate_bd_design
puts "BD_VALIDATION_STATUS=[get_property VALIDATION_STATUS [current_bd_design]]"
save_bd_design
close_project
puts "Scratch vendor IP upgrade and BD validation complete: $project_dir"
