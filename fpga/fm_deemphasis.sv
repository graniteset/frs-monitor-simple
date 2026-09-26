// GNU Radio fm_deemph-compatible 75 us bilinear de-emphasis, Q1.15 in/out.
// Coefficients are rounded to Q1.17: b0=0.21456065 and feedback=0.57087870.
module fm_deemphasis #(
    parameter signed [17:0] B0_Q17 = 18'sd28123,
    parameter signed [17:0] FEEDBACK_Q17 = 18'sd74826
) (
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire signed [15:0]   s_audio_q15,
    input  wire                 s_valid,
    output wire                 s_ready,
    output wire signed [15:0]   m_audio_q15,
    output wire                 m_valid,
    input  wire                 m_ready
);
    reg signed [15:0] previous_input;
    reg signed [15:0] previous_output;
    wire signed [33:0] current_product = s_audio_q15 * B0_Q17;
    wire signed [33:0] previous_input_product = previous_input * B0_Q17;
    wire signed [33:0] feedback_product = previous_output * FEEDBACK_Q17;
    wire signed [37:0] current_ext = {{4{current_product[33]}}, current_product};
    wire signed [37:0] input_ext = {{4{previous_input_product[33]}}, previous_input_product};
    wire signed [37:0] feedback_ext = {{4{feedback_product[33]}}, feedback_product};
    wire signed [37:0] accumulator = $signed(current_ext) + $signed(input_ext) +
                                      $signed(feedback_ext);

    function signed [15:0] q32_to_q15;
        input signed [37:0] value;
        reg signed [38:0] rounded;
        reg signed [22:0] scaled;
        begin
            rounded = (value >= 0) ? (value + 39'sd65536) :
                                      (value - 39'sd65536);
            scaled = 23'($signed(rounded) >>> 17);
            if (scaled > 23'sd32767)
                q32_to_q15 = 16'sd32767;
            else if (scaled < -23'sd32768)
                q32_to_q15 = -16'sd32768;
            else
                q32_to_q15 = scaled[15:0];
        end
    endfunction

    assign s_ready = m_ready;
    assign m_valid = s_valid;
    assign m_audio_q15 = q32_to_q15(accumulator);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            previous_input <= 16'sd0;
            previous_output <= 16'sd0;
        end else if (s_valid && s_ready) begin
            previous_input <= s_audio_q15;
            previous_output <= q32_to_q15(accumulator);
        end
    end
endmodule
