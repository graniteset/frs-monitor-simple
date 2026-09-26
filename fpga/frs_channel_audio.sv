// Complete one-channel audio path from channelized complex IQ to tagged audio.
// A system-level serialized processor can reuse these component blocks while
// keeping per-channel power/discriminator/de-emphasis/FIR state in arrays.
module frs_channel_audio #(
    parameter [4:0] CHANNEL_ID = 5'd1,
    parameter signed [15:0] CHANNEL_GAIN_Q15 = 16'sd8192
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire signed [15:0]   s_i,
    input  wire signed [15:0]   s_q,
    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [32:0]          threshold_q30,
    output wire [20:0]          m_data, // {channel[4:0], audio[15:0]}
    output wire                 m_valid,
    input  wire                 m_ready,
    output wire [32:0]          channel_power_q30
);
    wire signed [15:0] squelched_i;
    wire signed [15:0] squelched_q;
    wire squelch_valid;
    wire squelch_ready;

    wire signed [15:0] demod_audio_q15;
    wire demod_valid;
    wire demod_ready;
    wire signed [15:0] deemph_audio_q15;
    wire deemph_valid;
    wire deemph_ready;
    wire signed [15:0] output_audio_q15;
    wire signed [31:0] gain_product = output_audio_q15 * CHANNEL_GAIN_Q15;
    wire signed [32:0] gain_rounded = (gain_product >= 0) ?
                                        ($signed(gain_product) + 33'sd16384) :
                                        ($signed(gain_product) - 33'sd16384);
    wire signed [17:0] gain_scaled = 18'($signed(gain_rounded) >>> 15);
    wire signed [15:0] scaled_audio = (gain_scaled > 18'sd32767) ? 16'sd32767 :
                                      (gain_scaled < -18'sd32768) ? -16'sd32768 :
                                      gain_scaled[15:0];

    complex_squelch squelch (
        .aclk(aclk), .aresetn(aresetn), .s_i(s_i), .s_q(s_q),
        .s_valid(s_valid), .s_ready(s_ready),
        .threshold_q30(threshold_q30),
        .m_i(squelched_i), .m_q(squelched_q), .m_valid(squelch_valid),
        .m_ready(squelch_ready), .average_power_q30(channel_power_q30)
    );

    quadrature_demod discriminator (
        .aclk(aclk), .aresetn(aresetn), .s_i(squelched_i), .s_q(squelched_q),
        .s_valid(squelch_valid), .s_ready(squelch_ready),
        .m_demod_q15(demod_audio_q15), .m_valid(demod_valid),
        .m_ready(demod_ready)
    );

    fm_deemphasis deemphasis (
        .aclk(aclk), .aresetn(aresetn), .s_audio_q15(demod_audio_q15),
        .s_valid(demod_valid), .s_ready(demod_ready),
        .m_audio_q15(deemph_audio_q15), .m_valid(deemph_valid),
        .m_ready(deemph_ready)
    );

    audio_fir_decimator audio_filter (
        .aclk(aclk), .aresetn(aresetn), .s_audio_q15(deemph_audio_q15),
        .s_valid(deemph_valid), .s_ready(deemph_ready),
        .m_audio_q15(output_audio_q15), .m_valid(m_valid),
        .m_ready(m_ready)
    );

    assign m_data = {CHANNEL_ID, scaled_audio};
endmodule
