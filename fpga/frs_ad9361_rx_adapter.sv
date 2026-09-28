// Adapter for the ADI axi_ad9361 RX user ports.
//
// The ADI core receives 12-bit converter samples and exposes 16-bit user-port
// words. The least-significant 12 bits are the ADC code; the optional ADI data
// format block can sign-extend the top four bits, but it does not change those
// low 12 bits (except converting offset-binary to two's-complement when
// enabled). The FRS core consumes signed 12-bit I/Q, so only the low ADC bits
// cross this seam.
//
// This module is intentionally a format/valid adapter only. It does not add
// buffering or clock-domain crossing, and the ADI stream cannot be
// backpressured. `drop_event` reports a simultaneous valid sample when the
// downstream core is not ready. Integrators must connect the input and core
// in a proven common clock domain and show zero drops at the selected sample
// rate, or add/test suitable buffering and CDC separately.
/* verilator lint_off UNUSEDSIGNAL */
module frs_ad9361_rx_adapter #(
    parameter integer OFFSET_BINARY_INPUT = 0
) (
    input  wire        rx_clk,
    input  wire [15:0] adc_data_i,
    input  wire [15:0] adc_data_q,
    input  wire        adc_valid_i,
    input  wire        adc_valid_q,
    input  wire        adc_enable_i,
    input  wire        adc_enable_q,
    input  wire        core_ready,
    output wire signed [11:0] sample_i,
    output wire signed [11:0] sample_q,
    output wire        sample_valid,
    output wire        pair_mismatch,
    output wire        drop_event
);
    wire [11:0] raw_i = adc_data_i[11:0];
    wire [11:0] raw_q = adc_data_q[11:0];

    // Flipping the sign bit converts unsigned offset-binary to signed
    // two's-complement while preserving the remaining ADC bits.
    localparam [11:0] FORMAT_SIGN_XOR =
        (OFFSET_BINARY_INPUT != 0) ? 12'h800 : 12'h000;
    wire [11:0] decoded_i = raw_i ^ FORMAT_SIGN_XOR;
    wire [11:0] decoded_q = raw_q ^ FORMAT_SIGN_XOR;

    assign sample_i = $signed(decoded_i);
    assign sample_q = $signed(decoded_q);
    assign sample_valid = adc_valid_i && adc_valid_q &&
                          adc_enable_i && adc_enable_q;
    assign pair_mismatch = (adc_valid_i != adc_valid_q) ||
                           (adc_enable_i != adc_enable_q);
    assign drop_event = sample_valid && !core_ready;

    // Clock is deliberately present in the interface to make the intended
    // ADI receive clock domain explicit; this adapter is combinational.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_rx_clk = rx_clk;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on UNUSEDSIGNAL */
