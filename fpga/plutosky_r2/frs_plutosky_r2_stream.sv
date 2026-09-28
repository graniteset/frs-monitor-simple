// Board-facing *stream seam*, not an AD9363 pin/interface wrapper.
// `radio_*` must be driven by an elastic FIFO/adapter in the axi_ad9361 l_clk
// domain. Do NOT connect the non-backpressurable AD9361 adc_enable/data ports
// directly here: `radio_ready` can deassert when the DSP stalls.
module frs_plutosky_r2_stream #(
    parameter integer TEST_ON_SAMPLES = 8000,
    parameter integer TEST_OFF_SAMPLES = 2000,
    parameter DDC_TAPS = "fpga/coeffs/subband_q17.memh",
    parameter NCO_TAPS = "fpga/coeffs/nco_q15_quarter.memh",
    parameter BAND1_MAP = "fpga/coeffs/channel_map_band1.memh",
    parameter BAND2_MAP = "fpga/coeffs/channel_map_band2.memh",
    parameter PFB_TAPS = "fpga/coeffs/channel_modulated_q17.memh",
    parameter AUDIO_TAPS = "fpga/coeffs/audio_q17.memh"
) (
    input  wire               aclk,
    input  wire               aresetn,
    input  wire               test_enable,
    input  wire [31:0]        test_phase_step,
    input  wire signed [11:0] radio_i,
    input  wire signed [11:0] radio_q,
    input  wire               radio_valid,
    output wire               radio_ready,
    input  wire [32:0]        threshold_q30,
    output wire [20:0]        audio_data,
    output wire               audio_valid,
    input  wire               audio_ready,
    output wire               band1_overrun,
    output wire               band2_overrun,
    output wire               invalid_channel
);
    wire [31:0] test_data;
    wire test_valid;
    wire test_ready;
    wire [31:0] radio_q15 = {
        radio_i, 4'b0000,
        radio_q, 4'b0000
    };
    // Intentional truncation from Q1.15 into the core's signed 12-bit ADC
    // domain; the discarded low four bits are fractional precision.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] selected_q15;
    /* verilator lint_on UNUSEDSIGNAL */
    wire selected_valid;
    wire selected_ready;

    iq_test_source #(
        .ON_SAMPLES(TEST_ON_SAMPLES),
        .OFF_SAMPLES(TEST_OFF_SAMPLES)
    ) test_source (
        .aclk(aclk), .aresetn(aresetn), .enable(test_enable),
        .phase_step(test_phase_step), .m_axis_tdata(test_data),
        .m_axis_tvalid(test_valid), .m_axis_tready(test_ready)
    );

    axis_iq_mux source_mux (
        .aclk(aclk), .aresetn(aresetn), .select(test_enable),
        .a_tdata(radio_q15), .a_tvalid(radio_valid), .a_tready(radio_ready),
        .b_tdata(test_data), .b_tvalid(test_valid), .b_tready(test_ready),
        .m_tdata(selected_q15), .m_tvalid(selected_valid),
        .m_tready(selected_ready)
    );

    // The core accepts signed ADC-domain 12-bit samples and applies <<4 to
    // obtain Q1.15. Both sources above are Q1.15, so take their upper 12 bits.
    frs_receive_core #(
        .DDC_TAPS(DDC_TAPS), .NCO_TAPS(NCO_TAPS),
        .BAND1_MAP(BAND1_MAP), .BAND2_MAP(BAND2_MAP),
        .PFB_TAPS(PFB_TAPS), .AUDIO_TAPS(AUDIO_TAPS)
    ) receive_core (
        .aclk(aclk), .aresetn(aresetn),
        .s_adc_i($signed(selected_q15[31:20])),
        .s_adc_q($signed(selected_q15[15:4])),
        .s_valid(selected_valid), .s_ready(selected_ready),
        .threshold_q30(threshold_q30),
        .m_audio_data(audio_data), .m_audio_valid(audio_valid),
        .m_audio_ready(audio_ready),
        .band1_overrun(band1_overrun), .band2_overrun(band2_overrun),
        .invalid_channel(invalid_channel)
    );
endmodule
