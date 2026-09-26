// Portable two-band FRS receive DSP core.
// Boundary assumption: radio transport presents sign-extended 12-bit ADC I/Q
// samples in 16-bit words; this wrapper receives the effective signed 12-bit
// values and converts them to normalized Q1.15 by shifting left four bits.
// Confirm the exact ADI ad_datafmt configuration before board hookup.
module frs_receive_core #(
    parameter DDC_TAPS = "fpga/coeffs/subband_q17.memh",
    parameter NCO_TAPS = "fpga/coeffs/nco_q15_quarter.memh",
    parameter BAND1_MAP = "fpga/coeffs/channel_map_band1.memh",
    parameter BAND2_MAP = "fpga/coeffs/channel_map_band2.memh",
    parameter PFB_TAPS = "fpga/coeffs/channel_modulated_q17.memh",
    parameter AUDIO_TAPS = "fpga/coeffs/audio_q17.memh"
) (
    input  wire                aclk,
    input  wire                aresetn,
    input  wire signed [11:0]  s_adc_i,
    input  wire signed [11:0]  s_adc_q,
    input  wire                s_valid,
    output wire                s_ready,
    input  wire [32:0]         threshold_q30,
    output wire [20:0]         m_audio_data, // {FRS channel 1..22, audio Q1.15}
    output wire                m_audio_valid,
    input  wire                m_audio_ready,
    output wire                band1_overrun,
    output wire                band2_overrun,
    output wire                invalid_channel
);
    wire signed [15:0] iq_i_q15 = {s_adc_i, 4'b0000};
    wire signed [15:0] iq_q_q15 = {s_adc_q, 4'b0000};

    wire ddc1_ready;
    wire ddc2_ready;
    wire ddc1_i_valid;
    wire ddc2_i_valid;
    wire signed [15:0] ddc1_i;
    wire signed [15:0] ddc1_q;
    wire signed [15:0] ddc2_i;
    wire signed [15:0] ddc2_q;
    wire ddc1_o_valid;
    wire ddc2_o_valid;
    wire unused_ddc1_overrun;
    wire unused_ddc2_overrun;

    // Both band branches accept precisely the same raw input sample.
    assign s_ready = ddc1_ready && ddc2_ready;
    wire common_valid = s_valid && s_ready;

    band_ddc_decimator #(
        .PHASE_STEP(9'd199), .INITIAL_PHASE(9'd330),
        .TAPS_FILE(DDC_TAPS), .NCO_FILE(NCO_TAPS)
    ) band1_ddc (
        .aclk(aclk), .aresetn(aresetn), .s_i(iq_i_q15), .s_q(iq_q_q15),
        .s_valid(common_valid), .s_ready(ddc1_ready),
        .m_i(ddc1_i), .m_q(ddc1_q), .m_valid(ddc1_o_valid),
        .m_ready(ddc1_i_valid), .overrun(unused_ddc1_overrun)
    );

    band_ddc_decimator #(
        .PHASE_STEP(9'd311), .INITIAL_PHASE(9'd490),
        .TAPS_FILE(DDC_TAPS), .NCO_FILE(NCO_TAPS)
    ) band2_ddc (
        .aclk(aclk), .aresetn(aresetn), .s_i(iq_i_q15), .s_q(iq_q_q15),
        .s_valid(common_valid), .s_ready(ddc2_ready),
        .m_i(ddc2_i), .m_q(ddc2_q), .m_valid(ddc2_o_valid),
        .m_ready(ddc2_i_valid), .overrun(unused_ddc2_overrun)
    );

    wire [36:0] band1_channel_data;
    wire [36:0] band2_channel_data;
    wire band1_channel_valid;
    wire band2_channel_valid;
    wire band1_channel_ready;
    wire band2_channel_ready;

    sparse_channelizer #(
        .CHANNELS(15), .MAP_FILE(BAND1_MAP), .COEFF_FILE(PFB_TAPS)
    ) band1_channelizer (
        .aclk(aclk), .aresetn(aresetn), .s_i(ddc1_i), .s_q(ddc1_q),
        .s_valid(ddc1_o_valid), .s_ready(ddc1_i_valid),
        .m_data(band1_channel_data), .m_valid(band1_channel_valid),
        .m_ready(band1_channel_ready), .overrun(band1_overrun)
    );

    sparse_channelizer #(
        .CHANNELS(7), .MAP_FILE(BAND2_MAP), .COEFF_FILE(PFB_TAPS)
    ) band2_channelizer (
        .aclk(aclk), .aresetn(aresetn), .s_i(ddc2_i), .s_q(ddc2_q),
        .s_valid(ddc2_o_valid), .s_ready(ddc2_i_valid),
        .m_data(band2_channel_data), .m_valid(band2_channel_valid),
        .m_ready(band2_channel_ready), .overrun(band2_overrun)
    );

    wire [36:0] tagged_iq;
    wire tagged_iq_valid;
    wire tagged_iq_ready;
    axis_rr_merge2_iq merge_bands (
        .aclk(aclk), .aresetn(aresetn),
        .s0_data(band1_channel_data), .s0_valid(band1_channel_valid),
        .s0_ready(band1_channel_ready),
        .s1_data(band2_channel_data), .s1_valid(band2_channel_valid),
        .s1_ready(band2_channel_ready),
        .m_data(tagged_iq), .m_valid(tagged_iq_valid), .m_ready(tagged_iq_ready)
    );

    frs_multi_channel_audio #(.AUDIO_TAPS_FILE(AUDIO_TAPS)) audio_engine (
        .aclk(aclk), .aresetn(aresetn), .s_data(tagged_iq),
        .s_valid(tagged_iq_valid), .s_ready(tagged_iq_ready),
        .threshold_q30(threshold_q30), .m_data(m_audio_data),
        .m_valid(m_audio_valid), .m_ready(m_audio_ready),
        .invalid_channel(invalid_channel)
    );
endmodule
