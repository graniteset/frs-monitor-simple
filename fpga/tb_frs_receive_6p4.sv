`timescale 1ns/1ps
// Run the full burst/isolation/stall regression at the actual 6.4 MS/s
// input cadence (8 accepted samples in exactly 125 fabric clocks).
module tb_frs_receive_6p4;
    tb_frs_receive_bursts #(.EXACT_6P4_RATE(1)) exact_rate_test ();
endmodule
