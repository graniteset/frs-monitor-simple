# Provisional CLG400 AD9363 source-synchronous timing constraints.
#
# The inherited CLG400 system_constr.xdc supplies the verified package pins
# and a primary clock on rx_clk_in_p. This file supplements it for timing
# analysis; it is not a replacement pin map.
#
# Assumptions for this first hardware experiment:
#   * This is the locked FRS profile: 6.4 MS/s complex sample rate in 2R2T
#     LVDS mode. ADI's 2R2T interface ratio is DATA_CLK=4*sample-rate, so the
#     input clock is 25.6 MHz (39.0625 ns nominal period; rounded to the
#     1 ps XDC quantum). This intentionally replaces
#     the inherited maximum-rate 250 MHz clock constraint for this profile.
#   * AD9363 Rev.D, Table 12 (LVDS): RX data tDDRX is 0..1.5 ns and
#     RX_FRAME tDDDV is 0..1.0 ns.  Keep RX_FRAME's distinct, tighter range.
#   * The matching Linux DT programs RX data delay=4, TX FB-clock delay=7, and
#     TX data delay=9. AN-1441 describes ~0.3 ns/LSB, so these are modeled as
#     explicit source/sink phase offsets below (RX +1.2 ns; TX relative +0.6ns).
#   * The CLG400 BD sets ADC_INIT_DELAY=23. The ADI design loads this value into
#     the FPGA IDELAYE2 after IDELAYCTRL locks, and exposes the delay to software
#     for later tuning. The primitive is VAR_LOAD with IDELAY_VALUE=0 in RTL,
#     so ordinary static timing may model the tap-0 arc even though runtime
#     CNTVALUEIN is 23. Provisionally account for the startup setting in the
#     input delay budget; the reported timing must be checked against the actual
#     per-tap delay and runtime setting before signoff.
#   * Unmeasured board data-vs-clock route skew is provisionally bounded at
#     +/-0.25 ns. Replace this with PCB extraction or measured margin later.
#   * Only positive differential ports are timed; Vivado treats the paired
#     negative port as the other leg of the same LVDS input/output buffer.
#
# This does not model package/board PVT uncertainty, clock jitter, or the
# AD9363's programmable per-lane delay calibration. Do not treat positive
# slack here as final signoff.

set assumed_board_skew_ns 0.250

# The board project inherited a 4 ns rx_clk constraint from its 250 MHz
# maximum-rate profile. Creating a clock with the same name on the same port
# replaces that clock in Vivado's XDC constraint set.
create_clock -name rx_clk -period 39.063 [get_ports rx_clk_in_p]

# The ADI receive clock and PS FCLK0 are independent domains. The custom RX
# bridge crosses them only through a Gray-pointer dual-clock FIFO and its
# synchronized control flags, so do not analyze datapath paths between these
# clocks as synchronous paths. The FIFO CDC structure and synchronizer
# placement still require review; this is not a substitute for that check.
set_clock_groups -asynchronous \
  -group [get_clocks rx_clk] \
  -group [get_clocks clk_fpga_0]

set rx_data_ports [get_ports {rx_data_in_p[*] rx_frame_in_p}]
# Account for AD9363's configured RX data phase and the runtime-loaded FPGA
# input IDELAY. The timing engine cannot infer the value written through DRP.
set ad936x_delay_lsb_ns 0.300
set fpga_idelay_tap_ns 0.078
set rx_data_delay_reg 4
set rx_fpga_init_taps 23
set rx_chip_phase_ns [expr {$rx_data_delay_reg * $ad936x_delay_lsb_ns}]
set rx_fpga_init_ns [expr {$rx_fpga_init_taps * $fpga_idelay_tap_ns}]
# AD9363 Rev.D Table 12, LVDS tDDRX: min 0 ns, max 1.5 ns.
set rx_data_max_ns [expr {1.500 + $rx_chip_phase_ns + $rx_fpga_init_ns + $assumed_board_skew_ns}]
set rx_data_min_ns [expr {0.000 + $rx_chip_phase_ns + $rx_fpga_init_ns - $assumed_board_skew_ns}]
set rx_frame_ports [get_ports {rx_frame_in_p}]
# AD9363 Rev.D Table 12, LVDS tDDDV: min 0 ns, max 1.0 ns.
set rx_frame_max_ns [expr {1.000 + $rx_fpga_init_ns + $assumed_board_skew_ns}]
set rx_frame_min_ns [expr {0.000 + $rx_fpga_init_ns - $assumed_board_skew_ns}]

# DATA_CLK is source-synchronous and the AD9363 interface is DDR. Constrain
# data launched from both clock edges. RX_FRAME gets its tighter datasheet tCO.
set_input_delay -clock rx_clk -max $rx_data_max_ns $rx_data_ports
set_input_delay -clock rx_clk -min $rx_data_min_ns $rx_data_ports
set_input_delay -clock rx_clk -clock_fall -add_delay -max $rx_data_max_ns $rx_data_ports
set_input_delay -clock rx_clk -clock_fall -add_delay -min $rx_data_min_ns $rx_data_ports

# Override the data-bus delay on RX_FRAME with its specified LVDS tDDDV range.
set_input_delay -clock rx_clk -max $rx_frame_max_ns $rx_frame_ports
set_input_delay -clock rx_clk -min $rx_frame_min_ns $rx_frame_ports
set_input_delay -clock rx_clk -clock_fall -add_delay -max $rx_frame_max_ns $rx_frame_ports
set_input_delay -clock rx_clk -clock_fall -add_delay -min $rx_frame_min_ns $rx_frame_ports

# The vendor core returns FB_CLK from the RX clock domain. With the project's
# DAC_CLK_EDGE_SEL=0, its ODDR mapping emits the inverted RX clock at FB_CLK.
# Model that source-synchronous relationship at the package output for TX
# timing checks. This is based on the current IP parameter; runtime changes
# to the edge selection would require updating this generated-clock model.
create_generated_clock -name tx_fb_clk -source [get_ports rx_clk_in_p] \
  -divide_by 1 -invert [get_ports tx_clk_out_p]

set tx_data_ports [get_ports {tx_data_out_p[*] tx_data_out_n[*] tx_frame_out_p tx_frame_out_n}]
# ADI AN-1441 specifies TX setup/hold relative to FB_CLK's falling edge for
# TX_DATA and TX_FRAME (tSTX=1 ns, tHTX=0 ns); do not add a duplicate rising-edge
# constraint. TX_DATA_DELAY=9 exceeds FB_CLK_DELAY=7 by 2 LSBs, so data is
# delayed relative to the capture clock by approximately +0.6 ns. In the
# output-delay equations, the minimum uses data-min minus clock-max (opposite
# board-skew sign to the maximum), while this chip phase is positive for both.
# Revisit if Linux changes these registers or board skew is measured.
set tx_phase_ns [expr {(9 - 7) * $ad936x_delay_lsb_ns}]
set tx_out_max_ns [expr {1.000 + $assumed_board_skew_ns + $tx_phase_ns}]
set tx_out_min_ns [expr {0.000 - $assumed_board_skew_ns + $tx_phase_ns}]
set_output_delay -clock tx_fb_clk -clock_fall -max $tx_out_max_ns $tx_data_ports
set_output_delay -clock tx_fb_clk -clock_fall -min $tx_out_min_ns $tx_data_ports
