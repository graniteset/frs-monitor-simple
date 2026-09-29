# Inspect the CLG400 vendor project without modifying its source archive.
# By default, make a unique project copy under work/. To inspect an existing
# scratch copy, set FRS_VENDOR_XPR to that copy and FRS_ADI_IP_REPO to a local
# ADI IP catalog. No IP is upgraded/generated and the SD card is untouched.
# Run from the repository root with:
#   vivado -mode batch -source fpga/plutosky_r2/inspect_vendor_project.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {[info exists ::env(FRS_VENDOR_XPR)]} {
  set xpr [file normalize $::env(FRS_VENDOR_XPR)]
} else {
  set xpr [file join $repo_root work vendor plutosky_7020_legacy pl_unpacked \
    projects fmcomms2 zc702 zc702.xpr]
}
if {![file exists $xpr]} {
  error "Vendor project not found: $xpr (set FRS_VENDOR_XPR to its .xpr path)"
}

puts "FRS_VENDOR_PROJECT=$xpr"
set scratch_root [file normalize [file join $repo_root work]]
set xpr_is_scratch [string match "${scratch_root}/*" $xpr]
if {$xpr_is_scratch} {
  if {[file tail $xpr] ne "frs_clg400_probe.xpr"} {
    error "Scratch inspection only accepts a frs_clg400_probe.xpr under work/: $xpr"
  }
  open_project $xpr
  set probe_dir [file dirname $xpr]
} else {
  open_project -read_only $xpr
}
set part [get_property PART [current_project]]
set top [get_property TOP [current_fileset]]
puts "PROJECT_PART=$part"
puts "PROJECT_TOP=$top"
if {![string match -nocase "xc7z020clg400-*" $part]} {
  error "Expected the board's CLG400 package; vendor project reports '$part'"
}

# The archived XPR refers to its original MyCore_7010_V3 checkout. Save a
# separate working copy before changing project properties. The vendor archive
# remains untouched, and a unique destination avoids overwriting earlier work.
set vendor_root [file normalize [file join [file dirname $xpr] .. .. ..]]
if {[info exists ::env(FRS_ADI_IP_REPO)]} {
  set local_ip_repo [file normalize $::env(FRS_ADI_IP_REPO)]
} else {
  set local_ip_repo [file join $vendor_root library]
}
if {![file isdirectory $local_ip_repo]} {
  error "Staged ADI IP repository is missing: $local_ip_repo"
}
if {!$xpr_is_scratch} {
  if {[info exists ::env(FRS_VENDOR_PROBE_DIR)]} {
    set probe_dir [file normalize $::env(FRS_VENDOR_PROBE_DIR)]
  } else {
    set probe_dir [file join $scratch_root frs_vendor_probe_[clock seconds]_[pid]]
  }
  if {[file exists $probe_dir]} {
    error "Refusing to overwrite existing vendor probe directory: $probe_dir"
  }
  puts "VENDOR_PROBE_COPY=$probe_dir"
  save_project_as -exclude_run_results frs_clg400_probe $probe_dir
}

set_property ip_repo_paths [list $local_ip_repo] [current_project]
update_ip_catalog -rebuild
puts "IP_REPOSITORY=$local_ip_repo"
report_ip_status -file [file join $probe_dir ip_status.rpt]
puts "IP_STATUS_REPORT=[file join $probe_dir ip_status.rpt]"

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
  error "The copied project does not contain its primary system.bd file."
}
puts "BLOCK_DESIGN=$bd_file"
open_bd_design $bd_file

foreach cell [get_bd_cells -hier] {
  set name [get_property NAME $cell]
  set vlnv ""
  set ip_status ""
  catch {set vlnv [get_property VLNV $cell]}
  catch {set ip_status [get_property IP_STATUS $cell]}
  if {[regexp -nocase {ad9361|adc|fifo|dma|cpack|clock|processing_system|axi_hp} "$name $vlnv"]} {
    puts "CELL name=$name vlnv=$vlnv ip_status=$ip_status"
  }
}

foreach pin_name {adc_data_i0 adc_data_q0 adc_valid_i0 adc_valid_q0 \
    adc_enable_i0 adc_enable_q0 adc_clk adc_dovf} {
  set pins [get_bd_pins -quiet -hier -filter "NAME =~ *$pin_name*"]
  foreach pin $pins {
    set net [get_bd_nets -quiet -of_objects $pin]
    set attached [get_bd_pins -quiet -of_objects $net]
    set dirs ""
    foreach other $attached {
      append dirs " [get_property NAME $other]([get_property DIR $other])"
    }
    puts "PIN name=[get_property NAME $pin] dir=[get_property DIR $pin] net=$net connected=$dirs"
  }
}

puts "CLOCK_PINS_BEGIN"
foreach pin [get_bd_pins -hier -filter {TYPE == clk}] {
  set net [get_bd_nets -quiet -of_objects $pin]
  set freq ""
  catch {set freq [get_property CONFIG.FREQ_HZ $pin]}
  puts "CLOCK_PIN name=[get_property NAME $pin] dir=[get_property DIR $pin] freq_hz=$freq net=$net"
}
puts "CLOCK_PINS_END"

close_project
puts "Vendor project inspection complete; scratch copy: $probe_dir"
