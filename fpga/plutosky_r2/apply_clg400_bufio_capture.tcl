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

proc frs_count_matches {pattern contents} {
  return [regexp -all -- $pattern $contents]
}

proc frs_add_clock_io_port {path} {
  if {![file isfile $path]} { error "Required ADI source is missing: $path" }
  set input [open $path r]
  fconfigure $input -translation auto
  set contents [read $input]
  close $input

  # A staged catalog may already contain the complete BUFIO rewrite. Validate
  # the topology and preserve it instead of attempting the legacy edit again.
  set clk_io_ports [frs_count_matches {(?m)^[ \t]*output[ \t]+clk_io[ \t]*(?:\);|$)} $contents]
  if {$clk_io_ports > 0} {
    set bufio_instances [frs_count_matches {\mBUFIO[ \t]+i_rx_clk_bufio[ \t]*\(} $contents]
    set old_input_buffers [frs_count_matches {\mIBUFG(DS)?[ \t]+i_rx_clk_ibuf[ \t]*\(} $contents]
    set clk_io_connections [frs_count_matches {\.O[ \t]*\([ \t]*clk_io[ \t]*\)} $contents]
    if {$clk_io_ports != 1 || $bufio_instances != 1 || $old_input_buffers != 0 || $clk_io_connections != 1} {
      error "ADI ad_data_clk.v has a partial or unsupported clk_io/BUFIO rewrite: $path"
    }
    return 1
  }

  # Support both pinned source layouts: `output clk);` and the same port with
  # the closing `);` on the following line. Match exactly one declaration.
  set pattern {(?m)^([ \t]*output[ \t]+clk)([ \t]*\);)?[ \t]*$}
  set matches [regexp -all -- $pattern $contents]
  if {$matches != 1} {
    error "Expected one ADI output clk declaration (or a complete BUFIO rewrite) in $path; found $matches"
  }
  set replacement "\\1,\n  output              clk_io\\2"
  set rewritten [regsub -- $pattern $contents $replacement]
  set temporary "${path}.frs-tmp-[pid]"
  set output [open $temporary w]
  puts -nonewline $output $rewritten
  close $output
  file rename -force $temporary $path
  return 0
}

proc frs_replace_rx_clock_input_buffers {path} {
  set input [open $path r]
  set contents [read $input]
  close $input
  set ibufg_count [frs_count_matches {\mIBUFG[ \t]+i_rx_clk_ibuf[ \t]*\(} $contents]
  set ibufgds_count [frs_count_matches {\mIBUFGDS[ \t]+i_rx_clk_ibuf[ \t]*\(} $contents]
  if {$ibufg_count + $ibufgds_count < 1} {
    error "Expected at least one ADI RX clock input buffer in $path"
  }
  if {$ibufg_count > 0} {
    frs_replace_exact $path "  IBUFG i_rx_clk_ibuf (" "  IBUF i_rx_clk_ibuf (" $ibufg_count
  }
  if {$ibufgds_count > 0} {
    frs_replace_exact $path "  IBUFGDS i_rx_clk_ibuf (" "  IBUFDS i_rx_clk_ibuf (" $ibufgds_count
  }
}

proc frs_ensure_lvds_io_clock_port {path} {
  if {![file isfile $path]} { error "Required ADI source is missing: $path" }
  set input [open $path r]
  fconfigure $input -translation auto
  set contents [read $input]
  close $input

  set io_clock_wire [frs_count_matches {(?m)^[ \t]*wire[ \t]+l_clk_io;[ \t]*$} $contents]
  set io_clock_inputs [frs_count_matches {\.rx_clk[ \t]*\([ \t]*l_clk_io[ \t]*\)} $contents]
  set io_clock_connection [frs_count_matches {\.clk_io[ \t]*\([ \t]*l_clk_io[ \t]*\)} $contents]
  set bypass_assignment [frs_count_matches {assign[ \t]+l_clk_io[ \t]*=[ \t]*clk[ \t]*;} $contents]
  if {$io_clock_wire || $io_clock_inputs || $io_clock_connection || $bypass_assignment} {
    if {$io_clock_wire == 1 && $io_clock_inputs == 2 &&
        $io_clock_connection == 1 && $bypass_assignment == 1} {
      return
    }
    error "ADI axi_ad9361_lvds_if.v has a partial or unsupported l_clk_io rewrite: $path"
  }

  # Validate the expected original topology before editing the disposable copy.
  set old_rx_inputs [frs_count_matches {\.rx_clk[ \t]*\([ \t]*l_clk[ \t]*\)} $contents]
  set old_clk_connection [frs_count_matches {(?m)^[ \t]*\.clk[ \t]*\([ \t]*l_clk\)\);[ \t]*$} $contents]
  set old_bypass [frs_count_matches {assign[ \t]+l_clk[ \t]*=[ \t]*clk[ \t]*;} $contents]
  if {$old_rx_inputs != 2 || $old_clk_connection != 1 || $old_bypass != 1} {
    error "Expected the pinned ADI LVDS RX clock topology in $path; found rx=$old_rx_inputs clk=$old_clk_connection bypass=$old_bypass"
  }

  frs_replace_exact $path \
    "  wire                locked_s;" \
    "  wire                locked_s;\n  wire                l_clk_io;" 1
  frs_replace_exact $path \
    "    .rx_clk (l_clk)," "    .rx_clk (l_clk_io)," 2
  frs_replace_exact $path \
    "    .clk (l_clk));" "    .clk (l_clk),\n    .clk_io (l_clk_io));" 1
  frs_replace_exact $path \
    "    assign l_clk = clk;" \
    "    assign l_clk = clk;\n    assign l_clk_io = clk;" 1
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

  set clock_is_patched [frs_add_clock_io_port $clock_file]
  if {!$clock_is_patched} {
    frs_replace_rx_clock_input_buffers $clock_file
    frs_replace_exact $clock_file \
      "  BUFG i_clk_gbuf (" \
      "  // Dedicated regional path for the RX input IDDRs.\n  BUFIO i_rx_clk_bufio (\n    .I (clk_ibuf_s),\n    .O (clk_io));\n\n  BUFG i_clk_gbuf (" 1
  }
  frs_ensure_lvds_io_clock_port $lvds_file

  return $overlay
}
