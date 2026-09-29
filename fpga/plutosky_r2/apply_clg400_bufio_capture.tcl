# Create a private ADI IP catalog overlay for the CLG400 source-synchronous RX
# capture experiment. The pinned/staged source catalog is never modified.
#
# Vivado calls this before update_ip_catalog. It splits RX capture clocking:
# BUFIO drives the AD9361 IDDRs, while BUFG continues to drive fabric logic.
#
# This Tcl file intentionally has no Vivado dependencies so its transformations
# can be exercised with tclsh against a disposable copy of the catalog.

proc frs_replace_exact {path old_text new_text expected_count} {
  if {![file isfile $path]} { error "Required ADI source is missing: $path" }
  set input [open $path r]
  set contents [read $input]
  close $input

  set count 0
  set offset 0
  while {1} {
    set found [string first $old_text $contents $offset]
    if {$found < 0} { break }
    incr count
    set offset [expr {$found + [string length $old_text]}]
  }
  if {$count != $expected_count} {
    error "Expected $expected_count occurrence(s) of a pinned ADI source fragment in $path; found $count"
  }

  set rewritten [string map [list $old_text $new_text] $contents]
  set temporary "${path}.frs-tmp-[pid]"
  set output [open $temporary w]
  puts -nonewline $output $rewritten
  close $output
  file rename -force $temporary $path
}

proc frs_make_clg400_bufio_catalog {adi_repo work_root} {
  set adi_repo [file normalize $adi_repo]
  set work_root [file normalize $work_root]
  if {![file isdirectory $adi_repo]} { error "ADI IP catalog not found: $adi_repo" }
  if {![string match "${work_root}/*" $adi_repo]} {
    error "Refusing to modify or copy an ADI catalog outside the disposable work tree: $adi_repo"
  }

  set source_clock_file [file join $adi_repo xilinx common ad_data_clk.v]
  set source_lvds_file [file join $adi_repo axi_ad9361 xilinx axi_ad9361_lvds_if.v]
  foreach required_file [list $source_clock_file $source_lvds_file] {
    if {![file isfile $required_file]} {
      error "Required ADI source is missing: $required_file"
    }
  }

  set overlay [file join $work_root "adi_ip_bufio_[clock seconds]_[pid]"]
  if {[file exists $overlay]} { error "Refusing to overwrite existing ADI overlay: $overlay" }
  file copy $adi_repo $overlay

  set clock_file [file join $overlay xilinx common ad_data_clk.v]
  set lvds_file [file join $overlay axi_ad9361 xilinx axi_ad9361_lvds_if.v]

  frs_replace_exact $clock_file \
    "  output              clk);" \
    "  output              clk,\n  output              clk_io);" 1
  frs_replace_exact $clock_file \
    "  IBUFG i_rx_clk_ibuf (" "  IBUF i_rx_clk_ibuf (" 1
  frs_replace_exact $clock_file \
    "  IBUFGDS i_rx_clk_ibuf (" "  IBUFDS i_rx_clk_ibuf (" 1
  frs_replace_exact $clock_file \
    "  BUFG i_clk_gbuf (" \
    "  // Dedicated regional path for the RX input IDDRs.\n  BUFIO i_rx_clk_bufio (\n    .I (clk_ibuf_s),\n    .O (clk_io));\n\n  BUFG i_clk_gbuf (" 1

  frs_replace_exact $lvds_file \
    "  wire                locked_s;" \
    "  wire                locked_s;\n  wire                l_clk_io;" 1
  frs_replace_exact $lvds_file \
    "    .rx_clk (l_clk)," "    .rx_clk (l_clk_io)," 2
  frs_replace_exact $lvds_file \
    "    .clk (l_clk));" "    .clk (l_clk),\n    .clk_io (l_clk_io));" 1
  frs_replace_exact $lvds_file \
    "    assign l_clk = clk;" \
    "    assign l_clk = clk;\n    assign l_clk_io = clk;" 1

  return $overlay
}
