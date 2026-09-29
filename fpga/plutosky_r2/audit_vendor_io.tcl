# Read-only reports for the synthesized CLG400 vendor-project scratch copy.
# Required environment: FRS_VENDOR_XPR=work/.../frs_clg400_probe.xpr
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
if {![info exists ::env(FRS_VENDOR_XPR)]} {
  error "Set FRS_VENDOR_XPR to a synthesized frs_clg400_probe.xpr under work/."
}
set xpr [file normalize $::env(FRS_VENDOR_XPR)]
set work_root [file normalize [file join $repo_root work]]
if {![string match "${work_root}/*" $xpr] || [file tail $xpr] ne "frs_clg400_probe.xpr"} {
  error "Refusing to inspect anything except a frs_clg400_probe.xpr under work/: $xpr"
}
set out_dir [file dirname $xpr]
open_project $xpr
if {![string match -nocase "xc7z020clg400-*" [get_property PART [current_project]]]} {
  error "Expected XC7Z020 CLG400 project."
}
open_run synth_1
report_io -file [file join $out_dir vendor_synth_io.rpt]
report_drc -file [file join $out_dir vendor_synth_drc.rpt]
close_project
puts "Read-only vendor I/O/DRC reports written under $out_dir"
